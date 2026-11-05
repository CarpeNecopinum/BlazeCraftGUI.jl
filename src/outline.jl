# The document outline: the right panel's second tab (§8.15). An indented
# tree of the document's shapes with their (nested) groups: one row per doc
# entry, members indented under their group. The tree is virtual — it reads
# the flat document and walks `child_indices` — so the hierarchy needs no
# state of its own; subgroups are listed at the top of their super-group
# (containers first), doc order within each class. Groups collapse/expand:
# the square in front of a group is the toggle — `[-]` expanded, `[+]`
# collapsed — and groups with 5+ members start collapsed so a fresh import
# presents its structure, not hundreds of rows; small ones start expanded.
#
# Outline-click selection is *exact* by default: a row selects precisely
# that doc entry without riding up (a shape selects only the shape, never
# its parent group) and without riding down in the doc sense (a group row
# selects the group node — its members come along by membership, which is
# what a group selection means everywhere else too). Ctrl+click toggles the
# row's entry into the multi-selection (individual), Shift+click selects
# the *range* of rows between the anchor row (the last plain-/Ctrl-clicked
# one) and the clicked one, in visible row order; right-click opens the
# context menu (Group / Ungroup) on the row.
"""
    OutlinePanel(; doc, selection, ctx_open, anchor, fill = false)

The document outline: an indented tree of every shape and (nested) group —
subgroups listed at the top of their super-group, shapes a square in their
layer colour, groups a square collapse toggle (`[-]` expanded, `[+]`
collapsed). Clicking the square (the zone left of a group row's name)
expands or collapses that group — a collapsed group's members are not
listed; big groups (5+ members) start collapsed so a fresh import presents
its structure, not hundreds of rows; small ones start expanded. The toggle
lives in panel state keyed by group id — regrouping (new ids) resets to
the default. Clicking the row (anywhere right of the square) selects
*exactly* that document entry — a shape row selects only that shape (a
parent group stays unselected), a group row selects the group (its members
follow by membership). Ctrl+click toggles the row's entry into the
multi-selection (individual add/remove); Shift+click selects the range of
rows between the anchor row — the last plain- or Ctrl-clicked one (the
`anchor` Observable prop carries it) — and the clicked row, in *visible*
row order (the mods must be held *while* clicking — Rocks refreshes them
at click time). Right-clicking a row selects it (unless it is already part
of the selection) and opens the context menu (`ctx_open` is an
`Observable{Bool}` prop — the app's Group/Ungroup popup acts on the
selection). The row of the selected entry (and rows selected as part of a
larger selection) highlights.
"""
function OutlinePanel(; doc = Observable(ArtObject[]),
                      selection = Observable(Int[]),
                      ctx_open = Observable(false),
                      anchor = Observable{Union{Nothing,Int}}(nothing),
                      fill = false)
    doc_obs = @use doc
    selection_obs = @use selection
    ctx_obs = @use ctx_open
    anchor_obs = @use anchor
    collapse_ov = @use Observable(Dict{UInt,Bool}())  # group id → expanded
    t = E.theme()
    d = doc_obs[]

    rows = Any[]
    row_order = Int[]     # the doc indices of the rows, in visible order

    "A group's children for the outline: subgroups first (the nested
    containers list at the top of their parent), doc order within each
    class."
    function outline_children(art)
        cs = child_indices(d, art)
        return vcat([i for i in cs if is_group(d[i])],
                    [i for i in cs if !is_group(d[i])])
    end

    "One subtree preorder: the row, then a group's members deeper."
    function add_subtree(index, depth)
        (1 <= index <= length(d)) || return nothing
        art = d[index]
        push!(row_order, index)
        selected = index in selection_obs[]
        fg = selected ? t.colors.selection_text : t.colors.text
        open = true
        toggle_zone = 25 + depth * 14
        if is_group(art)
            open = get(collapse_ov[], art.id,
                       length(outline_children(art)) < 5)
        end
        # Leading mark: layer-coloured square for shapes; for groups the
        # square is the collapse toggle — `[-]` expanded, `[+]` collapsed.
        mark = is_group(art) ?
               (@rock Box(E.text_element(open ? "-" : "+";
                          color = fg, size = t.metrics.font_size - 4);
                          width = 10, height = 10, radius = 2,
                          background = t.colors.document,
                          border_color = fg, border_width = 1,
                          overflow = :visible,
                          direction = :row, align = :center,
                          justify = :center)) :
               (@rock Box(; width = 10, height = 10,
                          background = layer_color(art.layer),
                          border_color = fg, border_width = 1))
        push!(rows, @rock Pressable(
            (@rock Box(; width = depth * 14, height = 1)),
            mark,
            E.text_element(art.name; color = fg, size = t.metrics.font_size,
                           font = t.font);
            on_press = (x, y, button) -> begin
                # The square (the indent gutter plus the mark) toggles the
                # group — no selection change.
                if button == 1 && is_group(art) && x < toggle_zone
                    ov = copy(collapse_ov[])
                    ov[art.id] = !open
                    collapse_ov[] = ov
                    return nothing
                end
                # Right-click: select the entry unless it is already part of
                # the selection (a multi-selection survives), then open the
                # context menu on it — the menu's Group/Ungroup act on the
                # selection.
                if button == 3
                    index in selection_obs[] ||
                        (selection_obs[] = [index])
                    ctx_obs[] = true
                    return nothing
                end
                mods = Rocks.LAST_KEYMODS[]
                # Ctrl+click: toggle the entry into the multi-selection
                # (individual). The anchor follows the click so a following
                # Shift+click ranges from here.
                if mods & 0x00C0 != 0                     # either Ctrl key
                    s = copy(selection_obs[])
                    pos = findfirst(==(index), s)
                    pos === nothing ? push!(s, index) : deleteat!(s, pos)
                    anchor_obs[] = index
                    selection_obs[] = sort!(s)
                elseif mods & 0x0003 != 0                 # either Shift key
                    # Shift+click: the range of rows between the anchor and
                    # this one, in visible row order (subgroups first). The
                    # anchor stays where it was (the range grows from it).
                    a = anchor_obs[]
                    p1 = a === nothing ? nothing :
                         findfirst(==(a), row_order)
                    p2 = findfirst(==(index), row_order)
                    if p1 === nothing || p2 === nothing
                        selection_obs[] = [index]
                        anchor_obs[] = index
                    else
                        lo, hi = minmax(p1, p2)
                        selection_obs[] = sort!(row_order[lo:hi])
                    end
                else
                    # A plain click selects exactly this entry, a shape
                    # never its parent group, a group never its parent —
                    # and re-seats the range anchor.
                    selection_obs[] = [index]
                    anchor_obs[] = index
                end
                nothing
            end,
            background = selected ? t.colors.selection : nothing,
            hover_background = selected ? t.colors.selection : t.colors.hot,
            pressed_background = selected ? t.colors.selection : t.colors.hot_border,
            height = t.metrics.row_height,
            padding_x = 3, padding_y = 0,
            direction = :row, align = :center, gap = 6, fill = true))
        is_group(art) && open && for c in outline_children(art)
            add_subtree(c, depth + 1)
        end
        return nothing
    end
    # The top level walks in the same order as a group's members: outermost
    # groups first, then the loose shapes.
    tl = top_level_indices(d)
    for i in vcat([i for i in tl if is_group(d[i])],
                  [i for i in tl if !is_group(d[i])])
        add_subtree(i, 0)
    end
    isempty(rows) && push!(rows, (@rock E.Text(
        "no shapes yet — import art";
        color = t.colors.disabled_text, size = t.metrics.font_size - 3)))

    body = @rock ScrollView(
        rows...;
        position = :absolute, fill = true,
        scrollbar = true, scrollbar_width = t.metrics.scrollbar,
        scrollbar_track = t.colors.scrollbar_track,
        scrollbar_thumb = t.gradients.scrollbar_thumb,
        scrollbar_border = t.colors.scrollbar_border,
        scrollbar_radius = 2,
        padding = 2, gap = 0, direction = :column, align = :start)
    return @rock Box(
        body;
        direction = :column, gap = 0,
        background = t.colors.document,
        border_color = t.colors.input_border,
        border_width = 1, bevel = :sunken,
        padding = 0, height = "100%", fill = fill)
end
