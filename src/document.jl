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

# Unique art ids: groups reference their members through ids, not indices,
# so the hierarchy survives every document edit that shifts indices
# (imports, deletes). Grouped art keeps its id through geometry edits
# (translate/scale/… rebuild the entry but preserve `id`).
const NEXT_ART_ID = Ref(UInt(0))
art_next_id() = (NEXT_ART_ID[] += UInt(1))

"""
    ArtObject(name, paths, layer)

One entry of the document (§4: colour = layer): either a **shape** — its
outline geometry flattened once into `PolyLine`s (millimetres, y-up) — or a
**group**, a container whose `children` are the ids of its members (shapes
and/or other groups, i.e. groups nest). Groups hold no geometry and never
appear on the laser output. `translate`/`scale`/… edits preserve `id`,
`kind` and `children` through `ArtObject(entry; paths = …)`.
"""
struct ArtObject
    id::UInt
    kind::Symbol                 # :shape or :group
    name::String
    paths::Vector{PolyLine}
    layer::Int
    children::Vector{UInt}
end

# The plain constructor every import/creation path uses: a fresh id, a shape.
ArtObject(name::AbstractString, paths::Vector{PolyLine}, layer::Int) =
    ArtObject(art_next_id(), :shape, String(name), paths, layer, UInt[])

"Copy of one document entry with selected fields replaced; identity is kept
(`id`, `kind`, `children`, `name`, `layer` survive unless overridden) so
group membership over ids is unaffected by edits."
function ArtObject(art::ArtObject; name::AbstractString = art.name,
                   paths = art.paths, layer = art.layer,
                   kind = art.kind, children = art.children)
    return ArtObject(art.id, Symbol(kind), String(name), paths, Int(layer),
                     collect(UInt, children))
end

"""
    is_group(art) -> Bool

True when the document entry is a group container (its members are other
entries' ids); a shape has real outline geometry.
"""
is_group(art::ArtObject) = art.kind === :group

"""
    art_index(doc, id) -> Union{Int,Nothing}

The document index of the entry holding id `id`, or `nothing`. Group links
are ids precisely so this lookup is the only thing an edit needs.
"""
function art_index(doc::AbstractVector{ArtObject}, id::UInt)
    for (i, a) in enumerate(doc)
        a.id == id && return i
    end
    return nothing
end

"""
    child_indices(doc, art) -> Vector{Int}

The doc indices of `art`'s member ids, ascending (dangling ids dropped).
"""
function child_indices(doc::AbstractVector{ArtObject}, art::ArtObject)
    return [i for (i, a) in enumerate(doc) if a.id in art.children]
end

"""
    leaves_of(doc, idx) -> Vector{Int}

The shape indices under entry `idx`'s subtree, ascending doc order (deeper
groups recurse; a shape yields itself). A group's outlines *are* its
leaves' outlines — fitting, transforms, fills all act on the leaf shapes.
"""
function leaves_of(doc::AbstractVector{ArtObject}, idx::Int)
    (1 <= idx <= length(doc)) || return Int[]
    is_group(doc[idx]) || return [idx]
    out = Int[]
    for c in child_indices(doc, doc[idx])
        append!(out, leaves_of(doc, c))
    end
    return out
end

"""
    resolve_leaves(doc, selection) -> Vector{Int}

Selection indices resolved to the shape entries they cover: a group index
expands into its whole subtree, a shape index passes through. Ascending
doc order, deduped — this is the "what geometry does my selection own"
helper every consumer (frame, transforms, recolour) goes through.
"""
function resolve_leaves(doc::AbstractVector{ArtObject}, selection::AbstractVector{Int})
    out = Int[]
    for i in selection
        append!(out, leaves_of(doc, i))
    end
    return sort!(unique!(out))
end

"""
    parent_group(doc, idx) -> Union{Int,Nothing}

The index of the *outermost* group in entry `idx`'s ancestor chain (the
group no other group of the document holds), or `nothing` for a top-level
entry. Clicking a shape selects this group — "selecting one shape of a
group selects the whole group" resolves to the outermost level, which is
also what makes a group act like a single shape for the marquee units.
"""
function parent_group(doc::AbstractVector{ArtObject}, idx::Int)
    (1 <= idx <= length(doc)) || return nothing
    holder = nothing
    gid = doc[idx].id
    for a in doc
        is_group(a) && gid in a.children && (holder = a; break)
    end
    holder === nothing && return nothing
    # Walk up the ancestor chain to the outermost group (a seen guard so a
    # hand-built cyclic document cannot spin).
    seen = Set{UInt}([holder.id])
    while true
        next = nothing
        for a in doc
            is_group(a) && !(a.id in seen) &&
                holder.id in a.children && (next = a; break)
        end
        next === nothing && break
        holder = next
        push!(seen, holder.id)
    end
    return art_index(doc, holder.id)
end

"""
    top_level_indices(doc) -> Vector{Int}

Indices no group holds — ungrouped shapes and *outermost* groups. The
marquee's selection units: "a group acts like a single shape" means the
top-level entries are compared against the selection rect as units.
"""
function top_level_indices(doc::AbstractVector{ArtObject})
    members = Set{UInt}()
    for a in doc
        is_group(a) && union!(members, a.children)
    end
    return [i for (i, a) in enumerate(doc) if !(a.id in members)]
end

"""
    art_bounds(doc, idx) -> (pmin, pmax)

World bounding box (millimetres, y-up) of one document entry: its own
geometry for a shape, the union over all shapes under it for a group (the
group bbox is what makes a group act like a single shape for marquee and
groups-as-shapes selection), `nothing` for empty geometry.
"""
function art_bounds(doc::AbstractVector{ArtObject}, idx::Int)
    (1 <= idx <= length(doc)) || return nothing
    idxs = leaves_of(doc, idx)
    isempty(idxs) && return nothing
    return document_bounds([doc[i] for i in idxs])
end

"""
    holder_group(doc, id) -> Union{Int,Nothing}

The doc index of the group whose `children` holds id `id` — the membership
link that shows the entry indented under that group in the outline — or
`nothing` for a top-level entry.

    ancestor_chain(doc, id) -> Vector{UInt}

The ids of the groups along id's ancestor chain, innermost first (held with
a seen guard so a hand-built cyclic document cannot spin).
"""
function holder_group(doc::AbstractVector{ArtObject}, id::UInt)
    for (i, a) in enumerate(doc)
        is_group(a) && id in a.children && return i
    end
    return nothing
end

function ancestor_chain(doc::AbstractVector{ArtObject}, id::UInt)
    chain = UInt[]
    seen = Set{UInt}([id])
    while true
        h = holder_group(doc, id)
        h === nothing && break
        push!(chain, doc[h].id)
        doc[h].id in seen && break
        push!(seen, doc[h].id)
        id = doc[h].id
    end
    return chain
end

"""
    common_group(doc, ids) -> Union{UInt,Nothing}

The id of the innermost group that lies in every id's ancestor chain — the
group a new group over these ids belongs in (None when some id is top
level, i.e. no group covers them all).
"""
function common_group(doc::AbstractVector{ArtObject}, ids)
    isempty(ids) && return nothing
    sets = [Set(ancestor_chain(doc, id)) for id in ids]
    for g in ancestor_chain(doc, ids[1])
        all(s -> g in s, sets) && return g
    end
    return nothing
end

"""
    prune_empty_groups(doc) -> doc

Drop every group entry that holds no members — a group emptied by
regrouping has no representation (LightBurn behaviour) — and strip the
dangling references to the dropped nodes; recurses until stable so a chain
of emptied groups goes too.
"""
function prune_empty_groups(doc::AbstractVector{ArtObject})
    out = doc
    while true
        gone = Set(UInt(a.id) for a in out if is_group(a) && isempty(a.children))
        isempty(gone) && break
        out = [a for a in out if !(is_group(a) && a.id in gone)]
        out = [is_group(a) ?
               ArtObject(a; children = UInt[c for c in a.children
                                              if !(c in gone)]) : a
               for a in out]
    end
    return out
end

"""
    group_arts(doc, indices) -> doc

Wrap the entries at `indices` — a mix of shapes and groups: grouping a
group into a group (or into a group with shapes) is how nesting is built —
into a new group appended to the document. Membership is by id, so the
members keep their doc entries and nothing else moves. Returns the new
document vector (the group is its last entry; index `length(doc)`).

Placement: the new group goes into the **innermost common group** of all
members when they share one (grouping members of a group keeps the result
inside it — LightBurn levels), at the top level otherwise. The members
leave their previous holders at the same time — an entry is listed under
its group *and* the new group must not claim it twice (the outline would
duplicate the row). Members nested inside other selected members don't
join (a group and its own members aren't wrapped both). Groups emptied by
the move drop out.
"""
function group_arts(doc::AbstractVector{ArtObject}, indices::AbstractVector{Int};
                    name = nothing)
    idxs = unique(filter(i -> 1 <= i <= length(doc), collect(indices)))
    member_ids = UInt[doc[i].id for i in idxs]
    memberset = Set(member_ids)
    # A member nested inside another member stays put (its ancestor joins
    # the new group and carries the subtree along).
    idxs = [i for i in idxs if !any(g in memberset
                                    for g in ancestor_chain(doc, doc[i].id))]
    isempty(idxs) && return doc
    member_ids = UInt[doc[i].id for i in idxs]
    memberset = Set(member_ids)
    label = name === nothing ? string("Group ", count(is_group, doc) + 1) :
            string(name)
    newgroup = ArtObject(art_next_id(), :group, label,
                         PolyLine[], 0, member_ids)
    inner = common_group(doc, member_ids)
    out = ArtObject[]
    for a in doc
        if is_group(a) && !isempty(intersect(a.children, memberset))
            # The group releases every member it held; the innermost
            # common group additionally adopts the new group afterwards.
            kids = UInt[c for c in a.children if !(c in memberset)]
            a.id == inner && push!(kids, newgroup.id)
            push!(out, ArtObject(a; children = kids))
        else
            push!(out, a)
        end
    end
    push!(out, newgroup)
    return prune_empty_groups(out)
end

"""
    ungroup_arts(doc, indices) -> doc

Dissolve the group entries at `indices`, one grouping level each: the group
nodes go away and their members take the group's place — in their parent
group's children when the group was nested (LightBurn's ungroup promotes
into the parent), at the top level otherwise. Members keep their doc
entries and ids, so nothing else moves.
"""
function ungroup_arts(doc::AbstractVector{ArtObject}, indices::AbstractVector{Int})
    drop = Set(doc[i].id for i in indices
               if 1 <= i <= length(doc) && is_group(doc[i]))
    isempty(drop) && return doc
    dissolved = Dict{UInt,ArtObject}(a.id => a for a in doc if a.id in drop)
    # A dissolved member's children take its place; when several nested
    # groups dissolve at once the promotion runs through them (with a seen
    # guard so a hand-built cyclic document cannot spin).
    expand(ids, seen) = begin
        res = UInt[]
        for c in ids
            if c in drop && !(c in seen)
                append!(res, expand(dissolved[c].children, push!(copy(seen), c)))
            else
                push!(res, c)
            end
        end
        return res
    end
    out = ArtObject[]
    for a in doc
        a.id in drop && continue                 # the node dissolves
        if is_group(a) && any(c -> c in drop, a.children)
            push!(out, ArtObject(a; children = expand(a.children, Set{UInt}())))
        else
            push!(out, a)
        end
    end
    return out
end

"""
    delete_arts(doc, indices) -> doc

Remove the entries at `indices` from the document and prune the member
references that no longer resolve: a deleted shape leaves its group's
`children`; a deleted group node simply disappears (its members keep their
own doc entries — an explicitly deleted group is dissolved by this).
"""
function delete_arts(doc::AbstractVector{ArtObject}, indices::AbstractVector{Int})
    dead = Set(doc[i].id for i in indices if 1 <= i <= length(doc))
    isempty(dead) && return doc
    out = [a for a in doc if !(a.id in dead)]
    alive = Set(a.id for a in out)
    return [is_group(a) && !isempty(setdiff(a.children, dead)) ?
            ArtObject(a; children = UInt[c for c in a.children if c in alive]) : a
            for a in out]
end

"Union bounding box (millimetres, y-up) of the document's art; `nothing` for
an empty document or one without any outline geometry (a group entry holds
no paths of its own — its bounds come from its leaves via `art_bounds`)."
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
    pmin[1] == Inf && return nothing    # no geometry found
    return (pmin, pmax)
end

"""
    import_art(path) -> Vector{ArtObject}

Read a design file and return its art: **one `ArtObject` per primitive**
(each flattened `PolyLine`, millimetres, y-up) with a **group entry around
the whole file's contents** named after the file — a single-primitive file
imports as-is, no group. SVG carries no layer information — every primitive
lands on the default layer. A DXF's own containers build the tree's middle
level (`file → unit → shapes`): each layer becomes its own palette layer
(sorted by name, `00` on) and a `file/layer` subgroup; `INSERT` block
instances explode into `file/blockname` subgroups (transforms applied,
`MINSERT` arrays as one unit) and `ACAD_GROUP` objects keep their name; the
contour weld chains endpoint-sharing primitives into one shape each (the
8 arcs of a rounded plate arrive as one closed shape), so a 430-primitive
drawing presents as
`plate.dxf → cut 1 (shape), engraving (48 shapes)`. Any unit with
one shape skips its extra level. Anything else is rejected with an
error the caller turns into a status message.
"""
function import_art(path::AbstractString)
    isfile(path) || error("file not found: \"$path\"")
    ext = lowercase(splitext(path)[2])
    base = basename(path)
    arts = ArtObject[]                     # the file's primitives
    if ext == ".svg"
        # SVG is authored y-down; the importer's flip_y default maps it into
        # laser coords (y-up), which is what the workspace displays. SVG has
        # no layer concept in our importer — everything lands on layer `00`.
        paths = flatten(BlazeCraft.Importers.load_svg(read(path, String)))
        isempty(paths) && error("no supported geometry found in \"$path\"")
        for (i, pl) in enumerate(paths)
            push!(arts, ArtObject(string(base, ' ', i), [pl], DEFAULT_LAYER))
        end
    elseif ext == ".dxf"
        instructions = open(path) do io
            BlazeCraft.Importers.load_dxf_instructions(io)
        end
        units = BlazeCraft.Importers.extract_structured(instructions)
        isempty(units) && error("no supported geometry found in \"$path\"")
        # One palette layer per DXF layer (sorted by name, `00` on; past the
        # 30 cut layers the assignment wraps around), assigned per primitive.
        used = sort!(unique([l for u in units for l in u.poly_layers]))
        palette_of = Dict(n => mod(i - 1, CUT_LAYERS)
                          for (i, n) in enumerate(used))
        # The units build the tree's middle level: layer buckets first
        # (the palette structure), then block instances / named groups in
        # file order (the CAD author's own containers). A repeated
        # container name (two instances of one block) gets ` #k`.
        seen_names = Dict{String,Int}()
        ordered = vcat(sort!([u for u in units if u.kind === :layer];
                              by = u -> u.name),
                       [u for u in units if u.kind !== :layer])
        for u in ordered
            repeat = u.kind === :layer ? 0 :
                     get!(seen_names, u.name, 0) + 1
            u.kind !== :layer && (seen_names[u.name] = repeat)
            label = repeat > 1 ? string(base, '/', u.name, " #", repeat) :
                    string(base, '/', u.name)
            idxs = Int[]
            for (j, pl) in enumerate(u.polys)
                push!(arts, ArtObject(string(label, ' ', j), [pl],
                                      palette_of[u.poly_layers[j]]))
                push!(idxs, length(arts))
            end
            # A multi-primitive unit becomes its own group: a layer that is
            # the DXF's own grouping, a block instance or named group the
            # container the file's own structure implies — the outline
            # shows `file → unit → shapes` instead of hundreds of rows.
            length(idxs) > 1 && (arts = group_arts(arts, idxs; name = label))
        end
        isempty(arts) && error("no geometry found in \"$path\"")
    else
        error("unsupported design format \"$ext\" (supported: .svg, .dxf)")
    end
    # A group around the whole file's contents; a single primitive imports
    # as-is (no group around one entry).
    length(arts) <= 1 && return arts
    return group_arts(arts, eachindex(arts); name = base)
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
    root_bounds(doc, idx) -> (Point, Point)

The bounding rectangle (millimetres, y-up) of one alignment root: the union
of the resolved member leaves' bounds (a group's bounds come from its
subtree, a shape's from its own paths); `nothing` without geometry.
"""
function root_bounds(doc::AbstractVector{ArtObject}, idx::Int)
    bounds = nothing
    for li in resolve_leaves(doc, [idx])
        b = document_bounds([doc[li]])
        b === nothing && continue
        bounds = bounds === nothing ? b :
                 (Point(min.(bounds[1], b[1])), Point(max.(bounds[2], b[2])))
    end
    return bounds
end

"""
    align_arts(doc, selection; x = :none, y = :none) -> Vector{ArtObject}

The alignment tools: each selected entry is one alignment **root** — a
selected group is one root (its members move together), selected shapes are
roots of their own (several members of one group selected together still
move individually). The roots' overall bounding rectangle is the target;
per axis (`:min`, `:center`, `:max` — `:none` keeps the axis) every root
translates so its own bounding box's negative/centre/positive edge lands on
the rectangle's edge/centre. One root alone is the rectangle — a no-op. A
leaf claimed by an earlier root (a group and its own member both selected)
does not move twice.
"""
function align_arts(doc::AbstractVector{ArtObject},
                    selection::AbstractVector{Int};
                    x::Symbol = :none, y::Symbol = :none)
    roots = filter(i -> 1 <= i <= length(doc), selection)
    isempty(roots) && return doc
    (x in (:none, :min, :center, :max) &&
     y in (:none, :min, :center, :max)) || return doc
    bbs = Tuple{Point,Point}[]
    for r in roots
        b = root_bounds(doc, r)
        b === nothing && return doc
        push!(bbs, b)
    end
    pmin = Point(Inf, Inf)
    pmax = Point(-Inf, -Inf)
    for (a, b) in bbs
        pmin = Point(min.(pmin, a))
        pmax = Point(max.(pmax, b))
    end
    d = copy(doc)
    claimed = UInt[]
    for (r, b) in zip(roots, bbs)
        dx = x == :none ? 0.0 :
             x == :center ? (pmin[1] + pmax[1]) / 2 - (b[1][1] + b[2][1]) / 2 :
             x == :max ? pmax[1] - b[2][1] : pmin[1] - b[1][1]
        dy = y == :none ? 0.0 :
             y == :center ? (pmin[2] + pmax[2]) / 2 - (b[1][2] + b[2][2]) / 2 :
             y == :max ? pmax[2] - b[2][2] : pmin[2] - b[1][2]
        (dx == 0.0 && dy == 0.0) && continue
        for li in resolve_leaves(doc, [r])
            d[li].id in claimed && continue
            push!(claimed, d[li].id)
            d[li] = translate(d[li], dx, dy)
        end
    end
    return d
end

"""
    translate(art, dx, dy) -> ArtObject

Move an art object by `dx`/`dy` millimetres.
"""
function translate(art::ArtObject, dx::Float64, dy::Float64)
    return ArtObject(art; paths = [PolyLine([Point(p[1] + dx, p[2] + dy)
                                             for p in pl.points],
                                            pl.closed)
                                   for pl in art.paths])
end

"""
    scale(art, sx, sy, anchor) -> ArtObject

Scale an art object by `sx`/`sy` about `anchor` (which stays fixed).
"""
function scale(art::ArtObject, sx::Float64, sy::Float64, anchor::Point)
    return ArtObject(art; paths = [PolyLine([Point(anchor[1] +
                                                       (p[1] - anchor[1]) * sx,
                                                   anchor[2] +
                                                       (p[2] - anchor[2]) * sy)
                                             for p in pl.points], pl.closed)
                                   for pl in art.paths])
end

"""
    rotate(art, angle, center) -> ArtObject

Rotate an art object by `angle` radians (counterclockwise in world
coordinates) about `center`.
"""
function rotate(art::ArtObject, angle::Float64, center::Point)
    co, si = cos(angle), sin(angle)
    return ArtObject(art; paths = [PolyLine([begin
                                                 dx = p[1] - center[1]
                                                 dy = p[2] - center[2]
                                                 Point(center[1] + dx * co - dy * si,
                                                       center[2] + dx * si + dy * co)
                                             end for p in pl.points],
                                            pl.closed)
                                   for pl in art.paths])
end

"""
    set_layer(arts, layer) -> Vector{ArtObject}

Assign every art object in `arts` to the palette layer `layer` (§4: with a
selection, clicking a palette swatch recolours the selected objects).
"""
function set_layer(arts::AbstractVector{ArtObject}, layer::Int)
    return [ArtObject(obj; layer = layer) for obj in arts]
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
    return [ArtObject(obj; paths = [PolyLine([Point(p[1] + dx, p[2] + dy)
                                              for p in pl.points], pl.closed)
                                    for pl in obj.paths])
            for obj in arts]
end
