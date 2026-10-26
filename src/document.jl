# The document model: files the user imported, cached as flattened outlines.
#
# LightBurn keeps one "object" per imported file; the BlazeCraft importers
# return a `MultiShape` that we flatten into `PolyLine`s once at import time
# (§2.11 of the analysis: the Workspace draw callback must not re-flatten
# every frame). The document is a list of `ArtObject`s held in an Observable
# owned by the app shell (`App`); components subscribe to it with `@use`.
#
# Coordinates: everything here is in laser work coordinates — millimetres,
# y-up — matching BlazeCraft's `PolyLine`s (the SVG importer flips y by
# default). The `Workspace` maps them onto the canvas.

const DEFAULT_LAYER = 0

# The work area: LightBurn shows the laser bed from the device profile; v1
# uses a fixed 300×300 mm work area. Newly imported art is centered on it.
const WORK_AREA_MM = 300.0

# The LightBurn layer palette (analysis/02 §4.1): thirty cut layers `00`–`29`
# plus the two tool layers `T1`/`T2` (indices 30/31), whose colors never
# reach the laser — they mark material boundaries and guidelines. Colour =
# the layer the shape belongs to, not a product colour.
const LAYER_COLORS_HEX = Dict{Int,String}(
    0 => "#000000", 1 => "#0000FF", 2 => "#FF0000", 3 => "#00E000",
    4 => "#D0D000", 5 => "#FF8000", 6 => "#00E0E0", 7 => "#FF00FF",
    8 => "#B4B4B4", 9 => "#0000A0", 10 => "#A00000", 11 => "#00A000",
    12 => "#A0A000", 13 => "#C08000", 14 => "#00A0FF", 15 => "#A000A0",
    16 => "#808080", 17 => "#7D87B9", 18 => "#BB7784", 19 => "#4A6FE3",
    20 => "#D33F6A", 21 => "#8CD78C", 22 => "#F0B98D", 23 => "#F6C4E1",
    24 => "#FA9ED4", 25 => "#500A78", 26 => "#B45A00", 27 => "#004754",
    28 => "#86FA88", 29 => "#FFDB66", 30 => "#F36926", 31 => "#0C96D9",
)

# The number of cut layers in the palette; `30`+ are the two tool layers.
const CUT_LAYERS = 30

"The palette label for a layer index: `00`–`29`, then the tool layers."
function layer_label(n::Int)
    n < CUT_LAYERS && return string(lpad(n, 2, '0'))
    return n == 30 ? "T1" : n == 31 ? "T2" : string(n)
end

"A layer is a tool layer (never output to the laser) when its index is `≥ CUT_LAYERS`."
is_tool_layer(n::Int) = n >= CUT_LAYERS

"Rocks color (tuple on 0–1) for a LightBurn layer number."
function layer_color(n::Int)
    hex = get(LAYER_COLORS_HEX, n, "#000000")
    return (parse(UInt8, hex[2:3]; base = 16) / 255,
            parse(UInt8, hex[4:5]; base = 16) / 255,
            parse(UInt8, hex[6:7]; base = 16) / 255)
end

"""
    ArtObject(name, paths, layer)

One imported design file (or one source layer of a layered file): its outline
geometry flattened once into `PolyLine`s (millimetres, y-up), plus the
LightBurn palette index it belongs to — the palette colour is the shape's
display colour and its cut attribution (§4: colour = layer).
"""
struct ArtObject
    name::String
    paths::Vector{PolyLine}
    layer::Int
end

"Union bounding box (millimetres, y-up) of the document's art; `nothing` for an empty document."
function document_bounds(objs::AbstractVector{ArtObject})
    isempty(objs) && return nothing
    pmin = Point(Inf, Inf)
    pmax = Point(-Inf, -Inf)
    for obj in objs, pl in obj.paths
        isempty(pl.points) && continue
        for p in pl.points
            pmin = Point(min.(pmin, p))
            pmax = Point(max.(pmax, p))
        end
    end
    return (pmin, pmax)
end

"""
    import_art(path) -> Vector{ArtObject}

Read a design file and return its art as flattened `PolyLine`s (millimetres,
y-up), one `ArtObject` per source layer. SVG carries no layer information —
a single object on the default layer; a DXF's layer names each become their
own object on successive palette layers (sorted by name, `00` on). Anything
else is rejected with an error the caller turns into a status message.
"""
function import_art(path::AbstractString)
    isfile(path) || error("file not found: \"$path\"")
    ext = lowercase(splitext(path)[2])
    base = basename(path)
    arts = ArtObject[]
    paths = PolyLine[]
    if ext == ".svg"
        # SVG is authored y-down; the importer's flip_y default maps it into
        # laser coords (y-up), which is what the workspace displays. SVG has
        # no layer concept in our importer — everything lands on layer `00`.
        push!(paths, flatten(BlazeCraft.Importers.load_svg(read(path, String)))...)
    elseif ext == ".dxf"
        layers = open(path) do io
            instructions = BlazeCraft.Importers.load_dxf_instructions(io)
            BlazeCraft.Importers.extract_polys(instructions)
        end
        isempty(layers) && error("no supported geometry found in \"$path\"")
        # One palette layer per DXF layer (sorted by name, `00` on; past the
        # 30 cut layers the assignment wraps around).
        for (i, lname) in enumerate(sort!(collect(keys(layers))))
            paths = flatten(layers[lname])
            isempty(paths) && continue
            push!(arts, ArtObject(string(base, '/', lname), paths,
                                  mod(i - 1, CUT_LAYERS)))
        end
        isempty(arts) && error("no geometry found in \"$path\"")
        return arts
    else
        error("unsupported design format \"$ext\" (supported: .svg, .dxf)")
    end
    isempty(paths) && error("no geometry found in \"$path\"")
    return [ArtObject(base, paths, DEFAULT_LAYER)]
end

"""
    rect_art(name, x0, y0, x1, y1, layer) -> ArtObject

An axis-aligned closed rectangle from two opposite world corners (the
rectangle tool's product). Corners are normalized, so a drag in any
direction yields valid geometry; callers gate degenerate (near-zero area)
drags before creating.
"""
function rect_art(name::AbstractString, x0::Float64, y0::Float64,
                  x1::Float64, y1::Float64, layer::Int)
    pl = PolyLine([Point(min(x0, x1), min(y0, y1)),
                   Point(max(x0, x1), min(y0, y1)),
                   Point(max(x0, x1), max(y0, y1)),
                   Point(min(x0, x1), max(y0, y1))], true)
    return ArtObject(String(name), [pl], layer)
end

"""
    translate(art, dx, dy) -> ArtObject

Move an art object by `dx`/`dy` millimetres.
"""
function translate(art::ArtObject, dx::Float64, dy::Float64)
    return ArtObject(art.name,
                     [PolyLine([Point(p[1] + dx, p[2] + dy) for p in pl.points],
                               pl.closed) for pl in art.paths],
                     art.layer)
end

"""
    scale(art, sx, sy, anchor) -> ArtObject

Scale an art object by `sx`/`sy` about `anchor` (which stays fixed).
"""
function scale(art::ArtObject, sx::Float64, sy::Float64, anchor::Point)
    return ArtObject(art.name,
                     [PolyLine([Point(anchor[1] + (p[1] - anchor[1]) * sx,
                                      anchor[2] + (p[2] - anchor[2]) * sy)
                                for p in pl.points], pl.closed)
                      for pl in art.paths],
                     art.layer)
end

"""
    rotate(art, angle, center) -> ArtObject

Rotate an art object by `angle` radians (counterclockwise in world
coordinates) about `center`.
"""
function rotate(art::ArtObject, angle::Float64, center::Point)
    co, si = cos(angle), sin(angle)
    return ArtObject(art.name,
                     [PolyLine([begin
                                    dx = p[1] - center[1]
                                    dy = p[2] - center[2]
                                    Point(center[1] + dx * co - dy * si,
                                          center[2] + dx * si + dy * co)
                                end for p in pl.points], pl.closed)
                      for pl in art.paths],
                     art.layer)
end

"""
    set_layer(arts, layer) -> Vector{ArtObject}

Assign every art object in `arts` to the palette layer `layer` (§4: with a
selection, clicking a palette swatch recolours the selected objects).
"""
function set_layer(arts::AbstractVector{ArtObject}, layer::Int)
    return [ArtObject(obj.name, obj.paths, layer) for obj in arts]
end

"""
    center_on_workarea(arts) -> Vector{ArtObject}

Translate newly imported art so the union of its bounds sits centered on the
work area, keeping the relative positioning of everything imported together
(one dialog selection may contain several files — they move as a group).
Previously imported art is left alone.
"""
function center_on_workarea(arts::AbstractVector{ArtObject})
    bounds = document_bounds(arts)
    bounds === nothing && return arts
    (pmin, pmax) = bounds
    dx = WORK_AREA_MM / 2 - (pmin[1] + pmax[1]) / 2
    dy = WORK_AREA_MM / 2 - (pmin[2] + pmax[2]) / 2
    return [ArtObject(obj.name,
                      [PolyLine([Point(p[1] + dx, p[2] + dy) for p in pl.points],
                                pl.closed) for pl in obj.paths],
                      obj.layer)
            for obj in arts]
end
