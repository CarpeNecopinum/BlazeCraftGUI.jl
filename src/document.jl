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

# The LightBurn layer palette, in panel order (analysis/02 §4.1). v1 assigns
# every imported file to layer 0; per-file/layer mapping arrives with the
# Cuts & Layers panel.
const LAYER_COLORS_HEX = Dict{Int,String}(
    0 => "#000000", 1 => "#0000FF", 2 => "#FF0000", 3 => "#00E000",
    4 => "#F0F000", 5 => "#FF8000", 6 => "#00E0E0", 7 => "#FF00FF",
    8 => "#B4B4B4", 9 => "#0000A0",
)

"Rocks color (tuple on 0–1) for a LightBurn layer number."
function layer_color(n::Int)
    hex = get(LAYER_COLORS_HEX, n, "#000000")
    return (parse(UInt8, hex[2:3]; base = 16) / 255,
            parse(UInt8, hex[4:5]; base = 16) / 255,
            parse(UInt8, hex[6:7]; base = 16) / 255)
end

"""
    ArtObject(name, paths, color)

One imported design file: its outline geometry flattened once into
`PolyLine`s (millimetres, y-up), plus the attribution (v1: a single layer
color per file).
"""
struct ArtObject
    name::String
    paths::Vector{PolyLine}
    color::Any
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
    import_art(path) -> ArtObject

Read a design file and return its `ArtObject` (flattened outlines). SVG is
read through BlazeCraft's importer (y-up laser coordinates, curves flattened
at the importer's tolerance); DXF per-layer `POLYLINE`s are merged. Anything
else is rejected with an error the caller turns into a status message.
"""
function import_art(path::AbstractString)
    isfile(path) || error("file not found: \"$path\"")
    ext = lowercase(splitext(path)[2])
    shape = if ext == ".svg"
        # SVG is authored y-down; the importer's flip_y default maps it into
        # laser coords (y-up), which is what the workspace displays.
        BlazeCraft.Importers.load_svg(read(path, String))
    elseif ext == ".dxf"
        layers = open(path) do io
            instructions = BlazeCraft.Importers.load_dxf_instructions(io)
            BlazeCraft.Importers.extract_polys(instructions)
        end
        isempty(layers) && error("no supported geometry found in \"$path\"")
        BlazeCraft.Shapes.MultiShape(vcat(collect(values(layers))...))
    else
        error("unsupported design format \"$ext\" (supported: .svg, .dxf)")
    end
    paths = flatten(shape)
    isempty(paths) && error("no geometry found in \"$path\"")
    return ArtObject(basename(path), paths, layer_color(DEFAULT_LAYER))
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
                      obj.color)
            for obj in arts]
end
