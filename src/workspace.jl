# The Workspace: the interactive drawing surface showing the document.
#
# Rendering strategy stays inside SDL (§2.11 of the analysis): a Rocks native
# `Canvas` draws the flattened `PolyLine`s directly into the window
# renderer — no bitmap round-trip per frame. The `Canvas` is wrapped in a
# `MouseArea` (§2.12): the canvas is a pure drawing surface and all pointer
# interaction (pan, wheel-zoom) lives on the wrapper. The canvas is the
# wrapper's single `fill = true` child, so the area-local callback
# coordinates equal the canvas-local draw coordinates.
#
# The view is a `Camera` (see `camera.jl`): translation, rotation and scale,
# constructible as a StaticArrays matrix. The world-space geometry — the bed
# rectangle and the grid segments — is constant and built once; per frame it
# is transformed by the camera matrix (`draw_segment`), so panning/zooming
# never touches the geometry itself. Axis-aligned transformed lines snap to
# whole pixels: a sub-pixel SDL line rasterizes unreliably (vertical lines
# vanish or flicker between raster rows while panning), while snapped lines
# move cleanly in whole-pixel steps. Non-axis-aligned lines (a rotated
# camera) are drawn as-is.
#
# State placement (project convention): the document Observable is owned by
# the app and *received* here as a property (subscribed with `@use`); the
# camera is hook state of this component — `@use` keeps the instance across
# re-renders (Rocks re-runs every component body on each dirty frame, so
# plain locals would reset the view every frame). Draw functions receive
# their state as arguments resolved by the caller — nothing reaches into
# module globals.
#
# Initial-view policy: the view starts with a fit. `useEffect` on the
# document sets a pending flag, and the next draw (which knows the canvas
# pixel size through `ctx.rect`) computes and applies it. The fit covers the
# union of the 300×300 mm work area and the document, so an empty document
# shows the whole grid.

using StaticArrays: SVector, @SMatrix, inv

# Grid: 10 mm minor lines, thicker 100 mm majors, over the work area
# (`WORK_AREA_MM` in document.jl).
const GRID_MM = 10.0
const GRID_MAJOR_MM = 100.0

# The work-area geometry in world coordinates, built once: the bed rectangle
# corners and the grid segments. Constant — the camera transforms them.
const BED_CORNERS = (SVector(0.0, 0.0), SVector(WORK_AREA_MM, 0.0),
                     SVector(WORK_AREA_MM, WORK_AREA_MM), SVector(0.0, WORK_AREA_MM))

const BED_SEGMENTS = ((BED_CORNERS[1], BED_CORNERS[2]),
                      (BED_CORNERS[2], BED_CORNERS[3]),
                      (BED_CORNERS[3], BED_CORNERS[4]),
                      (BED_CORNERS[4], BED_CORNERS[1]))

const GRID_SEGMENTS = let
    minor = Tuple{SVector{2,Float64},SVector{2,Float64}}[]
    major = Tuple{SVector{2,Float64},SVector{2,Float64}}[]
    for x in 0.0:GRID_MM:WORK_AREA_MM
        segment = (SVector(x, 0.0), SVector(x, WORK_AREA_MM))
        push!(mod(x, GRID_MAJOR_MM) == 0.0 ? major : minor, segment)
    end
    for y in 0.0:GRID_MM:WORK_AREA_MM
        segment = (SVector(0.0, y), SVector(WORK_AREA_MM, y))
        push!(mod(y, GRID_MAJOR_MM) == 0.0 ? major : minor, segment)
    end
    (minor = Tuple(minor), major = Tuple(major))
end

"""
    draw_segment(ctx, m, segment; color, width)

Transform one world-space line segment through the camera matrix and draw
it. When the transformed segment is axis-aligned, it snaps to whole pixels:
a sub-pixel SDL line rasterizes unreliably (vertical lines vanish or
flicker between raster rows while panning), while snapped lines move
cleanly in whole-pixel steps.
"""
function draw_segment(ctx, m, segment; color, width)
    pa, pb = apply(m, segment[1]), apply(m, segment[2])
    if pa[1] == pb[1]                 # vertical on screen
        x = round(pa[1])
        ctx.line(x, pa[2], x, pb[2]; color = color, width = width)
    elseif pa[2] == pb[2]             # horizontal on screen
        y = round(pa[2])
        ctx.line(pa[1], y, pb[1], y; color = color, width = width)
    else
        ctx.line(pa[1], pa[2], pb[1], pb[2]; color = color, width = width)
    end
    return nothing
end

"""
    draw_dashed_polyline(ctx, pts; color, width, dash, gap, phase, closed)

Draw a polyline as dashes of `dash` px separated by `gap` px gaps, shifted by
`phase` px along the path (the marching-dashes animation). `closed` draws the
closing segment back to the first point.
"""
function draw_dashed_polyline(ctx, pts; color = (0.0, 0.0, 0.0), width = 1.0,
                              dash = 6.0, gap = 4.0, phase = 0.0, closed = false)
    period = dash + gap
    travelled = 0.0
    n = length(pts)
    for i in 1:(closed ? n : n - 1)
        a, b = pts[i], pts[mod1(i + 1, n)]
        len = hypot(b[1] - a[1], b[2] - a[2])
        len == 0 && continue
        ux, uy = (b[1] - a[1]) / len, (b[2] - a[2]) / len
        pos = 0.0
        while pos < len
            offset = mod(travelled + pos - phase, period)
            if offset < dash
                # The 1e-6 floor guarantees progress: when the pattern
                # boundary lands exactly on `pos`, a zero advance would spin
                # forever on paths with many tiny segments.
                stop = min(len, pos + max(dash - offset, 1e-6))
                ctx.line(a[1] + ux * pos, a[2] + uy * pos,
                         a[1] + ux * stop, a[2] + uy * stop;
                         color = color, width = width)
                pos = stop
            else
                pos = min(len, pos + max(period - offset, 1e-6))
            end
        end
        travelled += len
    end
    return nothing
end

"""
    _segment_distance(p, a, b)

Distance from point `p` to the segment `a`–`b` (world millimetres).
"""
function _segment_distance(p, a, b)
    ab = b - a
    len2 = ab[1]^2 + ab[2]^2
    len2 == 0 && return hypot(p[1] - a[1], p[2] - a[2])
    t = clamp(((p[1] - a[1]) * ab[1] + (p[2] - a[2]) * ab[2]) / len2, 0.0, 1.0)
    return hypot(p[1] - (a[1] + t * ab[1]), p[2] - (a[2] + t * ab[2]))
end

"""
    hit_shape(m, doc, x, y, threshold)

The index of the shape whose outline passes within `threshold` millimetres of
the canvas-local point `(x, y)` (unprojected through the camera matrix), or
`nothing`. Later shapes win.
"""
function hit_shape(m, doc, x, y, threshold)
    w = inv(m) * SVector(x, y, 1.0)
    p = SVector(w[1], w[2])
    for (idx, obj) in enumerate(doc)
        for pl in obj.paths
            for i in 1:(length(pl.points) - 1)
                _segment_distance(p, pl.points[i], pl.points[i + 1]) <= threshold &&
                    return idx
            end
            if pl.closed && length(pl.points) > 2 &&
               _segment_distance(p, pl.points[end], pl.points[1]) <= threshold
                return idx
            end
        end
    end
    return nothing
end

"""
    shapes_in_rect(doc, rect, mode) -> Vector{Int}

The doc indices the **marquee** rectangle `rect` (two world-mm corners)
selects, ascending. Selection units are the *top-level* entries (`top_level_indices`
— ungrouped shapes and outermost groups): a group acts like a single shape,
so its whole unit joins via its combined bounds (`art_bounds` over all its
subtree shapes) and a partially covered group falls out entirely either way:

  - `mode = :contained` — only units entirely inside the rect (the red
    marquee, started at one of its left corners),
  - `mode = :overlapping` — every unit whose combined bounding box
    intersects the rect (the green marquee, started at one of its right
    corners). The selected indices may be group entries (the group joins
    whole, then behaves like any other selection).
"""
function shapes_in_rect(doc, rect, mode)
    (a, b) = rect
    r = (min(a[1], b[1]), min(a[2], b[2]), max(a[1], b[1]), max(a[2], b[2]))
    out = Int[]
    for idx in top_level_indices(doc)
        bo = art_bounds(doc, idx)
        bo === nothing && continue
        ok = mode === :contained ?
             (bo[1][1] >= r[1] && bo[2][1] <= r[3] &&
              bo[1][2] >= r[2] && bo[2][2] <= r[4]) :
             !(bo[2][1] < r[1] || bo[1][1] > r[3] ||
               bo[2][2] < r[2] || bo[1][2] > r[4])
        ok && push!(out, idx)
    end
    return out
end

"""
    selection_bbox(m, doc, idx) -> (x0, y0, x1, y1)

The selected shape's bounding rectangle in canvas-local pixels (y-down), or
`nothing`.
"""
function selection_bbox(m, doc, idx)
    1 <= idx <= length(doc) || return nothing
    bounds = document_bounds([doc[idx]])
    bounds === nothing && return nothing
    c1 = apply(m, SVector(bounds[1][1], bounds[1][2]))
    c2 = apply(m, SVector(bounds[2][1], bounds[2][2]))
    return (min(c1[1], c2[1]), min(c1[2], c2[2]),
            max(c1[1], c2[1]), max(c1[2], c2[2]))
end

"""
    selection_union_bbox(m, doc, selection) -> (x0, y0, x1, y1)

The bounding rectangle (canvas-local pixels, y-down) of *all* selected
content — selection indices resolve through `resolve_leaves`, so a selected
group contributes the union of all shapes under it (the group frame encloses
its subtree like a shapes' frame encloses one shape). The selection frame
and its handles enclose this union, so with several shapes selected every
operation applies relative to the combined centre of bounds. The result is
snapped to **pixel corners** (`square_px`): endpoints sitting on pixel
centres make SDL's line raster spill into the neighbouring row/column and
the frame's 1 px lines draw 2 px wide (shapes' own outlines keep float
precision — this snapping is render-pixel only, never world geometry).
"""
function selection_union_bbox(m, doc, selection)
    bounds = nothing
    for idx in resolve_leaves(doc, selection)
        b = document_bounds([doc[idx]])
        b === nothing && continue
        bounds = bounds === nothing ? b :
                 (min.(bounds[1], b[1]), max.(bounds[2], b[2]))
    end
    bounds === nothing && return nothing
    c1 = apply(m, SVector(bounds[1][1], bounds[1][2]))
    c2 = apply(m, SVector(bounds[2][1], bounds[2][2]))
    bbox = (min(c1[1], c2[1]), min(c1[2], c2[2]),
            max(c1[1], c2[1]), max(c1[2], c2[2]))
    return snap_px.(bbox)
end

"""
    snap_px(p) -> Float64

Snap a projected coordinate to the **corner** of the pixel it falls in
(`floor(p) + 0.5`): SDL's renderer covers both endpoint pixels (and spills
one further at whole-integer endpoints), so only corner-aligned endpoints
keep an orthogonal 1 px line on every renderer.
"""
snap_px(p) = floor(Float64(p)) + 0.5

"The handle square size in px."
const HANDLE_PX = 9.0
"The offset of the rotation handles outside the bbox corners, in px."
const ROTATE_OFFSET_PX = 18.0

"""
    selection_handles(bbox) -> NamedTuple

Screen-space positions of the selection handles: four corner scale handles,
the center translate handle and four rotation handles outside the corners.
"""
function selection_handles(bbox)
    (x0, y0, x1, y1) = bbox
    dlen = hypot(x1 - x0, y1 - y0)
    ux, uy = dlen == 0 ? (0.0, 0.0) : ((x1 - x0) / dlen, (y1 - y0) / dlen)
    return (corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)],
            center = ((x0 + x1) / 2, (y0 + y1) / 2),
            rotate = [(x0 - ux * ROTATE_OFFSET_PX, y0 - uy * ROTATE_OFFSET_PX),
                      (x1 + ux * ROTATE_OFFSET_PX, y0 - uy * ROTATE_OFFSET_PX),
                      (x1 + ux * ROTATE_OFFSET_PX, y1 + uy * ROTATE_OFFSET_PX),
                      (x0 - ux * ROTATE_OFFSET_PX, y1 + uy * ROTATE_OFFSET_PX)])
end

"The handle under the canvas-local point, or `nothing`."
function handle_at(handles, x, y)
    s = HANDLE_PX / 2 + 1.0
    for (i, (hx, hy)) in enumerate(handles.corners)
        abs(x - hx) <= s && abs(y - hy) <= s && return Symbol("scale_$i")
    end
    (hx, hy) = handles.center
    abs(x - hx) <= s && abs(y - hy) <= s && return :translate
    for (i, (hx, hy)) in enumerate(handles.rotate)
        abs(x - hx) <= s && abs(y - hy) <= s && return Symbol("rotate_$i")
    end
    return nothing
end

"A square transform handle drawn at a screen position."
function draw_handle(ctx, x, y; fill = (1.0, 1.0, 1.0), border = (0.1, 0.1, 0.1))
    s = HANDLE_PX / 2
    ctx.polygon([(x - s, y - s), (x + s, y - s), (x + s, y + s), (x - s, y + s)];
                color = fill)
    for (a, b, c, d) in [(x - s, y - s, x + s, y - s), (x - s, y + s, x + s, y + s),
                         (x - s, y - s, x - s, y + s), (x + s, y - s, x + s, y + s)]
        ctx.line(a, b, c, d; color = border, width = 1.0)
    end
    return nothing
end

# One cached layer fill: the software texture and the key it was painted for.
mutable struct LayerFillTexture
    tex::Any                    # SDL3.Texture
    key::Tuple
    w::Int
    h::Int
end

"""
    draw_layer_fills!(ctx, m, doc, processes, fill_caches)

Paint the region fills of all scan-mode (`fill`/`offset_fill`) layers, each
as one even-odd texture of the canvas size, blitted before the strokes.

The scan covers **all closed geometry of a layer in one pass** so the
even-odd rule sees the whole set: overlapping same-layer shapes erase each
other and interior holes appear (§3 Fill-mode semantics). Per-layer document
identity (object ids of the paths on the layer) and the camera are part of
the texture's cache key, so a document edit or a view change re-scans only
the affected layers — a still camera with animated selection dashes reuses
the cached texture.
"""
function draw_layer_fills!(ctx, m, doc, processes, fill_caches)
    w, h = round(Int, ctx.rect[3]), round(Int, ctx.rect[4])
    (w > 0 && h > 0) || return nothing
    # Group the closed rings of each layer, camera-transformed to canvas
    # coordinates, together with the layer's process mode and identity.
    rings = Dict{Int,Vector{Vector{Tuple{Float64,Float64}}}}()
    layer_ids = Dict{Int,Vector{UInt}}()
    layer_mode = Dict{Int,Symbol}()
    for obj in doc
        pmode = process_for(processes, obj.layer).mode
        (pmode == :fill || pmode == :offset_fill) || continue
        rs = get!(rings, obj.layer, Vector{Vector{Tuple{Float64,Float64}}}())
        ids = get!(layer_ids, obj.layer, UInt[])
        layer_mode[obj.layer] = pmode
        for pl in obj.paths
            pl.closed || continue              # fill mode: closed shapes only
            length(pl.points) < 3 && continue
            push!(rs, [Tuple(apply(m, p)) for p in pl.points])
            push!(ids, objectid(pl))
        end
    end
    for layer in sort!(collect(keys(rings)))
        key = (layer_mode[layer], w, h,
               Tuple(round.(vec(Matrix(m)), digits = 9)), layer_ids[layer])
        lf = get(fill_caches, layer, nothing)
        if !(lf isa LayerFillTexture) || lf.key != key
            lf === nothing || !(lf isa LayerFillTexture) || lf.w == w &&
                lf.h == h || (SDL3.DestroyTexture(lf.tex); nothing)
            tex = lf isa LayerFillTexture && lf.w == w && lf.h == h ? lf.tex :
                  SDL3.CreateTexture(ctx.renderer, SDL3.SDL_PIXELFORMAT_ARGB8888,
                                     SDL3.SDL_TEXTUREACCESS_STREAMING, w, h)
            pixels = zeros(UInt32, w * h)
            runs = even_odd_runs(rings[layer], 0:(h - 1))
            paint_even_odd!(pixels, runs, w; rows = 0:(h - 1),
                            color = layer_color(layer))
            SDL3.UpdateTexture(tex, nothing, reinterpret(UInt8, pixels),
                               Int32(4w))
            lf = LayerFillTexture(tex, key, w, h)
            fill_caches[layer] = lf
        end
        ctx.texture(lf.tex, 0.0, 0.0; w = float(w), h = float(h))
    end
    return nothing
end

"""
    draw_workspace(ctx, camera, doc, selection, dash_phase)

Draw one frame: the 300×300 mm work area (filled bed, border), the 10 mm grid
with thicker 100 mm majors, the document's outlines (one stroke color per
layer), the selected shapes' marching-dash outlines — and **one** selection
frame with transform handles that encloses the *union* of the selection (a
single selected shape gets its own bbox; several shapes share the frame
around them all, and each operation applies relative to the combined centre
of bounds).

`processes` carries the per-layer process assignment: layers whose mode is
`fill` or `offset_fill` render their closed geometry as an **even-odd**
region fill (§3 Fill mode semantics — same-layer overlaps erase) beneath the
strokes. The fills are painted into per-layer software textures cached in
`fill_cache` (a plain `Dict`; provided by the Workspace as hook state), so
the redraw-per-dash-frame of the marching selection never re-scans an
unchanged fill.

`preview` = `((x0, y0), (x1, y1))` (world millimetres), the rectangle
tool's in-progress drag, drawn dashed in `preview_color` above the document.

`marquee` = `((sx, sy), (cx, cy))` (world millimetres), the cursor tool's
in-progress selection drag, drawn dashed; its colour encodes the mode —
green when the drag started at one of the rect's right corners (selects
everything *overlapping* the rect) and red when it started at a left corner
(selects only shapes fully *contained* in it). Both selection decorations
(marquee and selection frame) snap to pixel corners before drawing
(`snap_px`), so their 1 px lines never widen to 2 px; the document geometry
itself keeps float precision.
"""
function draw_workspace(ctx, camera, doc, selection, dash_phase;
                        processes = Dict{Int,Process}(),
                        fill_cache = Dict{Int,Any}(),
                        preview = nothing,
                        preview_color = (0.1, 0.1, 0.1),
                        marquee = nothing)
    _, _, cw, ch = ctx.rect
    m = matrix(camera)
    ctx.clear((0.86, 0.87, 0.89))          # tone outside the work area

    # The bed: filled rectangle.
    corners = [apply(m, p) for p in BED_CORNERS]
    ctx.polygon(corners; color = (0.94, 0.95, 0.96))

    # The grid: 10 mm minors (thin) and 100 mm majors (thicker).
    minor = (0.86, 0.87, 0.90)
    major = (0.78, 0.81, 0.84)
    for segment in GRID_SEGMENTS.minor
        draw_segment(ctx, m, segment; color = minor, width = 1.0)
    end
    for segment in GRID_SEGMENTS.major
        draw_segment(ctx, m, segment; color = major, width = 2.0)
    end

    # The bed border doubles as the work-origin axes through (0, 0).
    for segment in BED_SEGMENTS
        draw_segment(ctx, m, segment; color = (0.55, 0.60, 0.65), width = 1.0)
    end

    # Scan-mode layers paint their region fill first: the strokes still read
    # on top, and same-layer overlaps erase through the even-odd rule.
    draw_layer_fills!(ctx, m, doc, processes, fill_cache)

    # The selection highlights: selection indices resolve to the leaf shapes
    # they cover (a selected group's members run the marching dashes).
    selected_leaves = Set(resolve_leaves(doc, selection))
    for (idx, obj) in enumerate(doc)
        selected = idx in selected_leaves
        for (path_index, pl) in enumerate(obj.paths)
            length(pl.points) < 2 && continue
            pts = [apply(m, p) for p in pl.points]
            if selected
                # Each curve starts at its own position in the dash pattern
                # (spread by the golden-ratio modulus, stable across frames),
                # so short curves don't all flash in sync as the phase moves.
                draw_dashed_polyline(ctx, pts; color = (0.15, 0.35, 0.9),
                                     width = 2.0,
                                     phase = dash_phase + mod(path_index * 2.399963, 10.0),
                                     closed = pl.closed)
            else
                ctx.polyline(pts; color = layer_color(obj.layer), width = 1,
                             closed = pl.closed)
            end
        end
    end

    # The rectangle tool's in-progress drag: a dashed preview above the
    # document, in the active layer's colour.
    if preview !== nothing
        ((sx, sy), (ex, ey)) = preview
        a = apply(m, SVector(sx, sy))
        b = apply(m, SVector(ex, ey))
        draw_dashed_polyline(ctx, [(a[1], a[2]), (b[1], a[2]),
                                   (b[1], b[2]), (a[1], b[2])];
                             color = preview_color, width = 1.5,
                             dash = 5.0, gap = 3.0, closed = true)
    end

    # The cursor tool's in-progress marquee: dashed, green for an overlap
    # marquee (started at a right corner) and red for a containment marquee
    # (started at a left corner). Selection boxes snap to pixel corners
    # (`snap_px`) — endpoints on pixel centres or sub-pixel floats spill
    # the line into the neighbouring row and it draws 2 px wide (document
    # geometry stays float).
    if marquee !== nothing
        (a, b) = marquee
        pa = apply(m, a)
        pb = apply(m, b)
        color = pa[1] > pb[1] ? (0.15, 0.75, 0.25) : (0.9, 0.25, 0.2)
        pa = snap_px.(pa)
        pb = snap_px.(pb)
        draw_dashed_polyline(ctx, [(pa[1], pa[2]), (pb[1], pa[2]),
                                   (pb[1], pb[2]), (pa[1], pb[2]),
                                   (pa[1], pa[2])];
                             color = color, width = 1.5,
                             dash = 5.0, gap = 3.0, closed = true)
    end

    # The selection decor: the selected shapes' outlines already run the
    # marching dashes (above); one frame with transform handles encloses
    # the union of the selection (a multi-selection shares the frame and
    # its operations act on all of the shapes relative to the combined
    # centre of bounds). The frame comes pre-snapped to pixel corners from
    # `selection_union_bbox`; the handle squares ride on the snapped
    # corners (their ±4.5 size keeps square edges aligned to one grid,
    # corner or centre).
    if !isempty(selection)
        bbox = selection_union_bbox(m, doc, selection)
        if bbox !== nothing
            (x0, y0, x1, y1) = bbox
            draw_dashed_polyline(ctx, [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)];
                                 color = (0.15, 0.35, 0.9), width = 1.0,
                                 dash = 4.0, gap = 3.0, phase = dash_phase)
            handles = selection_handles(bbox)
            # Thin lines from the corners out to the rotation handles.
            for (corner, rot) in zip(handles.corners, handles.rotate)
                ctx.line(corner[1], corner[2], rot[1], rot[2];
                         color = (0.15, 0.35, 0.9), width = 1.0)
            end
            for (hx, hy) in handles.rotate
                draw_handle(ctx, hx, hy; fill = (0.85, 0.9, 1.0))
            end
            for (hx, hy) in handles.corners
                draw_handle(ctx, hx, hy)
            end
            (hx, hy) = handles.center
            draw_handle(ctx, hx, hy; fill = (0.15, 0.35, 0.9))
        end
    end
    return nothing
end

"""
    fit_camera(cw, ch, doc) -> Camera

Initial view: fit the union of the work area and the document bounds into
the canvas with a margin, centered (§2.11 "Initial view gotcha"). An empty
document shows the whole 300×300 mm work area.
"""
function fit_camera(cw, ch, doc)
    pmin = SVector(0.0, 0.0)
    pmax = SVector(WORK_AREA_MM, WORK_AREA_MM)
    bounds = document_bounds(doc)
    if bounds !== nothing
        pmin = min.(pmin, bounds[1])
        pmax = max.(pmax, bounds[2])
    end
    bw = max(pmax[1] - pmin[1], 1e-3)
    bh = max(pmax[2] - pmin[2], 1e-3)
    pad = 24.0
    zoom = clamp(min((cw - 2pad) / bw, (ch - 2pad) / bh), 0.05, 500.0)
    cx = (pmin[1] + pmax[1]) / 2
    cy = (pmin[2] + pmax[2]) / 2
    return Camera((cw / 2 - cx * zoom, ch / 2 + cy * zoom), 0.0, zoom)
end

"""
    Workspace(; doc, selection, props...)

The interactive workspace. `doc` is an `Observable{Vector{ArtObject}}` owned
by the app and `selection` an `Observable{Vector{Int}}` (the selected
entries' indices — shapes and/or groups). A left click on a shape selects
**its group** (the innermost group holding it — "selecting one shape of a
group selects the whole group"; a top-level shape selects just itself),
Shift adds/removes of the multi-selection at unit level (the Shift has to
be held *while* clicking). Empty space starts a **marquee**: dragging
rightward (from a left corner) draws the red containment marquee, dragging
leftward (from a right corner) the green overlap marquee — selection units
are the top-level entries, so a group acts like a single shape either way
(partially covered group members select nothing); a click-shaped drag
without movement clears the selection. A **right click** opens the context
menu (Group / Ungroup) — the menu itself is the app's (`ctx_open` is an
`Observable{Bool}` prop this component flips; its items act on the
selection): Group wraps the selected entries into one new group (groups
into groups nest), Ungroup dissolves every selected group node one level.
The selection gets a marching-dash outline per shape and one frame with
transform handles around the *union* of the resolved shapes (corner
squares scale everything relative to the frame's fixed opposite corner,
the center square translates, the outside rotation handles rotate around
the combined centre of bounds). The camera moves with a **middle-button
drag**
— the pointer turns into the gripping hand while grabbed, plain hover keeps
the arrow — and zooms at the wheel cursor; the view refits when a new import
changes the object count. Layout props (`flex`, `fill`, `height`, …) given
to the component are forwarded onto the `MouseArea` — inside a `Form`'s
scroll column the component needs `flex = 1, fill = true, height = "100%"`
to fill the client area, because the scroll content never gives `flex`
extra space to grow into.
"""
function Workspace(; doc = Observable(ArtObject[]),
                   selection = Observable(Int[]),
                   processes = Observable(Dict{Int,Process}()),
                   tool = Observable(:mouse),
                   active_layer = Observable(0),
                   ctx_open = Observable(false), props...)
    doc_obs = @use doc
    selection_obs = @use selection
    processes_obs = @use processes
    tool_obs = @use tool
    active_obs = @use active_layer
    ctx_obs = @use ctx_open

    # Per-layer fill textures (fills.jl): canvas-local software textures,
    # recreated when their layer's geometry, mode or the camera changes.
    fill_caches = @use Ref(Dict{Int,Any}())

    # View state: the camera, as hook state, so it survives the per-frame
    # body re-runs. Writes trigger a (draw-marked) re-render.
    view = @use Observable(Camera((0.0, 0.0), 0.0, 2.0))

    # Silent hook state (stable across re-renders, no re-render on write).
    fit_pending = @use Ref(true)
    fit_count = @use Ref(-1)
    # Suppressor for the count-refit below: a created rectangle changes the
    # object count (like an import does) but must not refit the view.
    no_refit = @use Ref(false)
    # The active drag: the mode (:translate/:scale_N/:rotate_N/:rect/:pan/
    # :marquee), the dragged shapes (their indices in `drag_sel`, their
    # original geometry in `drag_art`), the frame bbox the drag started on
    # (screen px) and the start point.
    drag_mode = @use Ref(:none)
    drag_sel = @use Ref{Any}(Int[])
    drag_art = @use Ref{Any}(nothing)
    drag_bbox = @use Ref{Any}(nothing)
    drag_start = @use Ref((0.0, 0.0))
    # Pan drag: the camera at the moment the middle button was pressed; the
    # dragged camera position follows the screen delta (camera.jl `pan`).
    pan_cam = @use Ref(Camera((0.0, 0.0), 0.0, 1.0))
    # Rectangle tool: the world-space corner dragged so far, re-rendered as
    # an observable (the preview must draw on every motion event). The drag
    # start lives in `drag_start`.
    rect_drag = @use Observable{Union{Nothing,Tuple{Float64,Float64}}}(nothing)
    # Cursor tool: the in-progress marquee, `(start, current)` world corners,
    # re-rendered per motion like the rect preview.
    marquee = @use Observable{Union{Nothing,
                                    Tuple{SVector{2,Float64},
                                          SVector{2,Float64}}}}(nothing)

    # Refit when a new import changes the object count (an edit keeps the
    # count, so moving/scaling a shape never refits the view). A created
    # rectangle also changes the count — the `no_refit` suppressor set by
    # the tool's commit path keeps the view still.
    useEffect(() -> begin
        count = length(doc_obs[])
        if no_refit[]
            fit_count[] = count
            no_refit[] = false
        elseif count != fit_count[]
            fit_count[] = count
            fit_pending[] = true
        end
        nothing
    end, (doc_obs[],))

    # The marching-dashes animation: a 100 ms tick marks the windows for a
    # draw-only redraw (the draw callbacks re-issue their primitives, no
    # component re-runs) while a shape is selected. The dash phase is derived
    # from the clock in the draw callback — no state, no re-render.
    useInterval(() -> begin
        selection_obs[] !== nothing && Rocks.request_redraw()
        nothing
    end, 100)

    "Write transformed copies of the selected shapes back into the document
    (one document write per move event — every shape of the group at once)."
    function replace_arts!(idxs, arts)
        d = copy(doc_obs[])
        for (i, a) in zip(idxs, arts)
            1 <= i <= length(d) || continue
            d[i] = a
        end
        doc_obs[] = d
        return nothing
    end

    return @rock MouseArea(
        @rock Canvas(
            draw = (ctx) -> begin
                camera = view[]
                if fit_pending[]
                    _, _, cw, ch = ctx.rect
                    camera = fit_camera(cw, ch, doc_obs[])
                    view[] = camera
                    fit_pending[] = false
                end
                draw_workspace(ctx, camera, doc_obs[], selection_obs[],
                               mod(time() * 20.0, 10.0);
                               processes = processes_obs[],
                               fill_cache = fill_caches[],
                               preview = rect_drag[] === nothing ? nothing :
                                         (drag_start[], rect_drag[]),
                               preview_color = layer_color(active_obs[]),
                               marquee = marquee[])
            end,
            # The bed tone distinguishes the canvas from the desktop gray
            # that Tools panels use in Rocks' Enterprise theme.
            background = (0.86, 0.87, 0.89), fill = true);
        on_down = (x, y, button) -> begin
            # Middle button: start a pan — grab the camera and drag the view
            # around (the gripping hand shows while grabbed). A pan keeps the
            # active tool and the selection.
            if button == 2 && drag_mode[] === :none
                drag_mode[] = :pan
                drag_start[] = (x, y)
                pan_cam[] = view[]
                return nothing
            end
            # Right button: open the context menu (the app's Group/Ungroup
            # popup) at the click — the menu anchors itself at the pointer
            # this click just stored. The selection stays as it is; the
            # menu's items act on it. Not while a drag is running.
            if button == 3 && drag_mode[] === :none
                ctx_obs[] = true
                return nothing
            end
            button == 1 || return nothing      # other buttons: no action
            # Rectangle tool: start a creation drag; no selection changes.
            if tool_obs[] === :rect
                w = inv(matrix(view[])) * SVector(x, y, 1.0)
                drag_mode[] = :rect
                drag_start[] = (w[1], w[2])
                rect_drag[] = (w[1], w[2])
                return nothing
            end
            sel = selection_obs[]
            # 1. Transform handles of the selection frame: one frame encloses
            # the union of the whole selection, so its operations act on
            # every selected shape relative to the combined centre of bounds
            # (a single selection is the same frame around its own bbox).
            if !isempty(sel)
                bbox = selection_union_bbox(matrix(view[]), doc_obs[], sel)
                if bbox !== nothing
                    handle = handle_at(selection_handles(bbox), x, y)
                    if handle !== nothing
                        # The frame encloses the selection's resolved
                        # shapes; the drag transforms exactly those.
                        idxs = resolve_leaves(doc_obs[], sel)
                        drag_mode[] = handle
                        drag_sel[] = idxs
                        drag_art[] = [doc_obs[][i] for i in idxs]
                        drag_bbox[] = bbox
                        drag_start[] = (x, y)
                        return nothing
                    end
                end
            end
            # 2. Click a shape: Shift adds it to (or removes it from) the
            # multi-selection (the Shift has to be held right now — Rocks
            # refreshes the mods at click time); a plain click selects just
            # it; empty space starts a marquee with the cursor tool (or, for
            # a click without drag, clears the selection).
            idx = hit_shape(matrix(view[]), doc_obs[], x, y,
                            8.0 / view[].scale)
            if idx === nothing
                if tool_obs[] === :mouse
                    w = inv(matrix(view[])) * SVector(x, y, 1.0)
                    drag_mode[] = :marquee
                    drag_start[] = (w[1], w[2])
                    marquee[] = (SVector(w[1], w[2]), SVector(w[1], w[2]))
                else
                    selection_obs[] = Int[]
                end
            else
                # Selecting one shape of a group selects the whole group:
                # the click unit is the innermost group holding the hit
                # shape (the shape itself when it is top level). Shift
                # toggles at the unit level too (the Shift must be held
                # right now — Rocks refreshes the mods at click time).
                g = parent_group(doc_obs[], idx)
                unit = g === nothing ? idx : g
                if Rocks.LAST_KEYMODS[] & 0x0003 != 0      # either Shift held
                    s = copy(sel)
                    if unit in s
                        deleteat!(s, findfirst(==(unit), s))
                    else
                        push!(s, unit)
                    end
                    selection_obs[] = sort!(s)
                else
                    selection_obs[] = [unit]
                end
            end
            return nothing
        end,
        # `on_move` also fires on plain hover; the drag mode gates the work.
        # All drag math happens in world coordinates: the screen positions
        # (the drag start, the cursor, the handle corners) are unprojected
        # through the inverse camera matrix.
        on_move = (x, y) -> begin
            mode = drag_mode[]
            mode == :none && return nothing
            if mode == :pan
                # The grabbed camera follows the screen delta: dragging the
                # moved world by as many pixels as the pointer moved.
                view[] = pan(pan_cam[], x - drag_start[][1],
                             y - drag_start[][2])
                return nothing
            end
            if mode == :rect
                # The preview updates the observable → a re-render (and a
                # redraw) on every motion event.
                w = inv(matrix(view[])) * SVector(x, y, 1.0)
                rect_drag[] = (w[1], w[2])
                return nothing
            end
            if mode == :marquee
                # Same preview-per-motion as the rect drag.
                w = inv(matrix(view[])) * SVector(x, y, 1.0)
                marquee[] = (SVector(drag_start[][1], drag_start[][2]),
                             SVector(w[1], w[2]))
                return nothing
            end
            sel = drag_sel[]
            arts = drag_art[]
            (isempty(sel) || !isa(arts, AbstractVector)) && return nothing
            inv_m = inv(matrix(view[]))
            if mode == :translate
                sw = inv_m * SVector(drag_start[][1], drag_start[][2], 1.0)
                cw = inv_m * SVector(x, y, 1.0)
                replace_arts!(sel, [translate(a, cw[1] - sw[1],
                                              cw[2] - sw[2]) for a in arts])
            elseif startswith(string(mode), "scale_")
                # The dragged frame corner moves to the cursor; the opposite
                # corner of the union bbox stays fixed — the whole group
                # scales relative to it (each shape maps under the same
                # similarity about the fixed corner, so the group and every
                # member's bbox scale together).
                i = parse(Int, string(mode)[7:end])
                bbox = drag_bbox[]
                corners = [(bbox[1], bbox[2]), (bbox[3], bbox[2]),
                           (bbox[3], bbox[4]), (bbox[1], bbox[4])]
                (cx_s, cy_s) = corners[i]
                (ox_s, oy_s) = corners[mod1(i + 2, 4)]
                cw0 = inv_m * SVector(cx_s, cy_s, 1.0)   # dragged corner, world
                ow0 = inv_m * SVector(ox_s, oy_s, 1.0)   # opposite corner, world
                cw = inv_m * SVector(x, y, 1.0)          # cursor, world
                sx = abs(cw0[1] - ow0[1]) < 1e-9 ? 1.0 :
                     (cw[1] - ow0[1]) / (cw0[1] - ow0[1])
                sy = abs(cw0[2] - ow0[2]) < 1e-9 ? 1.0 :
                     (cw[2] - ow0[2]) / (cw0[2] - ow0[2])
                (abs(sx) > 1e-6 && abs(sy) > 1e-6) || return nothing
                replace_arts!(sel, [scale(a, sx, sy,
                                          SVector(ow0[1], ow0[2]))
                                    for a in arts])
            elseif startswith(string(mode), "rotate_")
                # Rotate the group around the union bbox centre by the angle
                # between the drag start and the cursor (each shape turns
                # under the same rotation about the combined centre).
                bbox = drag_bbox[]
                cc = inv_m * SVector((bbox[1] + bbox[3]) / 2,
                                     (bbox[2] + bbox[4]) / 2, 1.0)
                sw = inv_m * SVector(drag_start[][1], drag_start[][2], 1.0)
                cw = inv_m * SVector(x, y, 1.0)
                a0 = atan(sw[2] - cc[2], sw[1] - cc[1])
                a1 = atan(cw[2] - cc[2], cw[1] - cc[1])
                replace_arts!(sel, [rotate(a, a1 - a0,
                                           SVector(cc[1], cc[2]))
                                    for a in arts])
            end
            return nothing
        end,
        on_up = (x, y, button) -> begin
            # Rectangle tool: commit the drag as a new rectangle on the
            # active layer and select it (creation tools stay active, the
            # mouse tool is switched back with its toolbar button). Only the
            # left release ends a left press's drag.
            if drag_mode[] == :rect && button == 1
                (sx, sy) = drag_start[]
                (ex, ey) = rect_drag[] !== nothing ? rect_drag[] : (sx, sy)
                if abs(ex - sx) > 0.5 && abs(ey - sy) > 0.5    # ≥ 0.5 mm × 0.5 mm
                    no_refit[] = true
                    doc_obs[] = vcat(doc_obs[], [rect_art(
                        "rectangle", Float64(sx), Float64(sy),
                        Float64(ex), Float64(ey), active_obs[])])
                    selection_obs[] = [length(doc_obs[])]
                end
                rect_drag[] = nothing
            end
            # Cursor tool: commit the marquee. The drag's start corner
            # decides the mode — started at a right corner (dragged
            # leftward) everything overlapping the rect lands in the
            # selection, started at a left corner only shapes fully inside
            # it do. A click-shaped drag (never moved) clears the selection,
            # like a plain click on empty space always did.
            if drag_mode[] == :marquee && button == 1
                (a, b) = marquee[] !== nothing ?
                         marquee[] : (SVector(0.0, 0.0), SVector(0.0, 0.0))
                marquee[] = nothing
                if abs(b[1] - a[1]) > 0.5 || abs(b[2] - a[2]) > 0.5
                    selection_obs[] = sort(shapes_in_rect(
                        doc_obs[], (a, b),
                        a[1] > b[1] ? :overlapping : :contained))
                else
                    selection_obs[] = Int[]
                end
            end
            # A drag ends with the button that started it; a stray release of
            # another button must not cut an ongoing drag short.
            if button == 1 || (drag_mode[] == :pan && button == 2)
                drag_mode[] = :none
                pan_cam[] = Camera((0.0, 0.0), 0.0, 1.0)
                drag_sel[] = Int[]
                drag_art[] = nothing
            end
            return nothing
        end,
        on_wheel = (dx, dy, x, y) -> (view[] = zoom_at(view[], x, y, 1.15^dy)),
        props...,
        # The pointer keeps the plain arrow while hovering (the workspace is
        # a surface, not a button — only grabbing changes the cursor): the
        # gripping hand shows while the camera is grabbed, a crosshair while
        # the rectangle tool drags.
        cursor = drag_mode[] === :rect ? :crosshair : :pan)
end
