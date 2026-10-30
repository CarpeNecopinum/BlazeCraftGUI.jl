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
layer) — and, for every selected shape, its marching-dash outline and a
dashed bounding box; a single selection also gets the transform handles.

`processes` carries the per-layer process assignment: layers whose mode is
`fill` or `offset_fill` render their closed geometry as an **even-odd**
region fill (§3 Fill mode semantics — same-layer overlaps erase) beneath the
strokes. The fills are painted into per-layer software textures cached in
`fill_cache` (a plain `Dict`; provided by the Workspace as hook state), so
the redraw-per-dash-frame of the marching selection never re-scans an
unchanged fill.

`preview` = `((x0, y0), (x1, y1))` (world millimetres), the rectangle
tool's in-progress drag, drawn dashed in `preview_color` above the document.
"""
function draw_workspace(ctx, camera, doc, selection, dash_phase;
                        processes = Dict{Int,Process}(),
                        fill_cache = Dict{Int,Any}(),
                        preview = nothing,
                        preview_color = (0.1, 0.1, 0.1))
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

    for (idx, obj) in enumerate(doc)
        selected = idx in selection
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

    # The selection decoration: a marching-dash outline and dashed bounding
    # box per selected shape; a single selection also gets the transform
    # handles.
    if !isempty(selection)
        for idx in selection
            bbox = selection_bbox(m, doc, idx)
            bbox === nothing && continue
            (x0, y0, x1, y1) = bbox
            draw_dashed_polyline(ctx, [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)];
                                 color = (0.15, 0.35, 0.9), width = 1.0,
                                 dash = 4.0, gap = 3.0, phase = dash_phase)
        end
        if length(selection) == 1
            bbox = selection_bbox(m, doc, selection[1])
            if bbox !== nothing
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
by the app and `selection` an `Observable{Union{Nothing,Int}}` (the selected
shape's index). Clicking one of a shape's lines selects it; the selection
shows a marching-dash outline, a dashed bounding box and transform handles
(corner squares scale, the center square translates, the outside rotation
handles rotate). The workspace also supports pan (drag on empty space) and
wheel-zoom-at-cursor, and refits the view when a new import changes the
object count. Layout props (`flex`, `fill`, `height`, …) given to the
component are forwarded onto the `MouseArea` — inside a `Form`'s scroll
column the component needs `flex = 1, fill = true, height = "100%"` to fill
the client area, because the scroll content never gives `flex` extra space
to grow into.
"""
function Workspace(; doc = Observable(ArtObject[]),
                   selection = Observable(Int[]),
                   processes = Observable(Dict{Int,Process}()),
                   tool = Observable(:mouse),
                   active_layer = Observable(0), props...)
    doc_obs = @use doc
    selection_obs = @use selection
    processes_obs = @use processes
    tool_obs = @use tool
    active_obs = @use active_layer

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
    # The active drag: the mode (:translate/:scale_N/:rotate_N/:rect), the
    # dragged shape's original geometry, its original world bbox and the
    # start point.
    drag_mode = @use Ref(:none)
    drag_art = @use Ref{Any}(nothing)
    drag_bbox = @use Ref{Any}(nothing)
    drag_start = @use Ref((0.0, 0.0))
    # Rectangle tool: the world-space corner dragged so far, re-rendered as
    # an observable (the preview must draw on every motion event). The drag
    # start lives in `drag_start`.
    rect_drag = @use Observable{Union{Nothing,Tuple{Float64,Float64}}}(nothing)

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

    "Write a modified copy of the shape at `idx` back into the document."
    function replace_art!(idx, art)
        d = copy(doc_obs[])
        d[idx] = art
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
                               preview_color = layer_color(active_obs[]))
            end,
            # The bed tone distinguishes the canvas from the desktop gray
            # that Tools panels use in Rocks' Enterprise theme.
            background = (0.86, 0.87, 0.89), fill = true);
        on_down = (x, y, _) -> begin
            # Rectangle tool: start a creation drag; no selection changes.
            if tool_obs[] === :rect
                w = inv(matrix(view[])) * SVector(x, y, 1.0)
                drag_mode[] = :rect
                drag_start[] = (w[1], w[2])
                rect_drag[] = (w[1], w[2])
                return nothing
            end
            sel = selection_obs[]
            # 1. Transform handles of a single selection (multi-selection
            # draws dashes only; per-shape transform comes later).
            if length(sel) == 1 && 1 <= sel[1] <= length(doc_obs[])
                bbox = selection_bbox(matrix(view[]), doc_obs[], sel[1])
                if bbox !== nothing
                    handle = handle_at(selection_handles(bbox), x, y)
                    if handle !== nothing
                        drag_mode[] = handle
                        drag_art[] = doc_obs[][sel[1]]
                        drag_bbox[] = bbox
                        drag_start[] = (x, y)
                        return nothing
                    end
                end
            end
            # 2. Click a shape: Shift adds it to (or removes it from) the
            # multi-selection; a plain click selects just it; empty space
            # clears the selection.
            idx = hit_shape(matrix(view[]), doc_obs[], x, y,
                            8.0 / view[].scale)
            if idx === nothing
                selection_obs[] = Int[]
            elseif Rocks.LAST_KEYMODS[] & 0x0003 != 0      # either Shift held
                s = copy(sel)
                if idx in s
                    deleteat!(s, findfirst(==(idx), s))
                else
                    push!(s, idx)
                end
                selection_obs[] = sort!(s)
            else
                selection_obs[] = [idx]
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
            if mode == :rect
                # The preview updates the observable → a re-render (and a
                # redraw) on every motion event.
                w = inv(matrix(view[])) * SVector(x, y, 1.0)
                rect_drag[] = (w[1], w[2])
                return nothing
            end
            sel = selection_obs[]
            length(sel) != 1 && return nothing
            sel = sel[1]
            inv_m = inv(matrix(view[]))
            if mode == :translate
                sw = inv_m * SVector(drag_start[][1], drag_start[][2], 1.0)
                cw = inv_m * SVector(x, y, 1.0)
                replace_art!(sel, translate(drag_art[], cw[1] - sw[1],
                                            cw[2] - sw[2]))
            elseif startswith(string(mode), "scale_")
                # The dragged corner moves to the cursor; the opposite corner
                # of the original bbox stays fixed.
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
                replace_art!(sel, scale(drag_art[], sx, sy,
                                        SVector(ow0[1], ow0[2])))
            elseif startswith(string(mode), "rotate_")
                # Rotate around the selection's bbox center by the angle
                # between the drag start and the cursor.
                bbox = drag_bbox[]
                cc = inv_m * SVector((bbox[1] + bbox[3]) / 2,
                                     (bbox[2] + bbox[4]) / 2, 1.0)
                sw = inv_m * SVector(drag_start[][1], drag_start[][2], 1.0)
                cw = inv_m * SVector(x, y, 1.0)
                a0 = atan(sw[2] - cc[2], sw[1] - cc[1])
                a1 = atan(cw[2] - cc[2], cw[1] - cc[1])
                replace_art!(sel, rotate(drag_art[], a1 - a0,
                                         SVector(cc[1], cc[2])))
            end
            return nothing
        end,
        on_up = (_, _, _) -> begin
            # Rectangle tool: commit the drag as a new rectangle on the
            # active layer and select it (creation tools stay active, the
            # mouse tool is switched back with its toolbar button).
            if drag_mode[] == :rect
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
            drag_mode[] = :none
            drag_art[] = nothing
            return nothing
        end,
        on_wheel = (dx, dy, x, y) -> (view[] = zoom_at(view[], x, y, 1.15^dy)),
        props...,
        # Inside a Form's scroll column `flex` has no height to grow into:
        # the caller passes `fill = true, height = "100%"` via `props` for
        # the full client area. The open grab hand hovers here, the closed
        # hand shows while pressed — a crosshair while a creation tool is
        # active.
        cursor = tool_obs[] === :rect ? :crosshair : :grab)
end
