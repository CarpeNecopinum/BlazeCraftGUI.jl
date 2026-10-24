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
    draw_workspace(ctx, camera, doc)

Draw one frame: the 300×300 mm work area (filled bed, border), the 10 mm
grid with thicker 100 mm majors, and the document's outlines, one stroke
color per layer. `doc` is the list of `BlazecraftGUI.ArtObject`s; `camera`
is the `BlazecraftGUI.Camera` for this frame.
"""
function draw_workspace(ctx, camera, doc)
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

    for obj in doc
        for pl in obj.paths
            length(pl.points) < 2 && continue
            ctx.polyline([apply(m, p) for p in pl.points];
                         color = obj.color, width = 1, closed = pl.closed)
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
    Workspace(; doc, props...)

The interactive workspace. `doc` is an `Observable{Vector{ArtObject}}` owned
by the app; the workspace refits the view whenever the document changes and
supports pan (drag) and wheel-zoom-at-cursor. Layout props (`flex`, `fill`,
`height`, …) given to the component are forwarded onto the `MouseArea` —
inside a `Form`'s scroll column the component needs
`flex = 1, fill = true, height = "100%"` to fill the client area, because the
scroll content never gives `flex` extra space to grow into.
"""
function Workspace(; doc = Observable(ArtObject[]), props...)
    doc_obs = @use doc

    # View state: the camera, as hook state, so it survives the per-frame
    # body re-runs. Writes trigger a (draw-marked) re-render.
    view = @use Observable(Camera((0.0, 0.0), 0.0, 2.0))

    # Silent hook state (stable across re-renders, no re-render on write).
    fit_pending = @use Ref(true)
    dragging = @use Ref(false)
    drag_start = @use Ref((0.0, 0.0))

    # Refit whenever the document changes (the effect re-runs with a new
    # doc list). The flag is then consumed by the first following draw,
    # where the canvas size is known.
    useEffect(() -> begin
        fit_pending[] = true
        nothing
    end, (doc_obs[],))

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
                draw_workspace(ctx, camera, doc_obs[])
            end,
            # The bed tone distinguishes the canvas from the desktop gray
            # that Tools panels use in Rocks' Enterprise theme.
            background = (0.86, 0.87, 0.89), fill = true);
        on_down = (x, y, _) -> begin
            drag_start[] = (view[].translation[1] - x,
                            view[].translation[2] - y)
            dragging[] = true
        end,
        # `on_move` also fires on plain hover; the dragging flag gates pan.
        # The drag stores the grab offset, so the new translation is
        # `start + (x, y)` — set directly, not as a delta.
        on_move = (x, y) -> begin
            dragging[] || return nothing
            view[] = Camera(SVector(drag_start[][1] + x, drag_start[][2] + y),
                            view[].rotation, view[].scale)
        end,
        on_up = (_, _, _) -> (dragging[] = false),
        on_wheel = (dx, dy, x, y) -> (view[] = zoom_at(view[], x, y, 1.15^dy)),
        props...,
        # Inside a Form's scroll column `flex` has no height to grow into:
        # the caller passes `fill = true, height = "100%"` via `props` for
        # the full client area. The open grab hand hovers here, the closed
        # hand shows while pressed.
        cursor = :grab)
end
