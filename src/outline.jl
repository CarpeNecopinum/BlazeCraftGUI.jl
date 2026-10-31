# The document outline: the right panel's second tab (§8.15). An indented
# tree of the document's shapes with their (nested) groups: one row per doc
# entry, members indented under their group. The tree is virtual — it reads
# the flat document and walks `child_indices` — so the hierachy needs no
# state of its own.
#
# Outline-click selection is *exact* by default: a row selects precisely
# that doc entry without riding up (a shape selects only the shape, never
# its parent group) and without riding down in the doc sense (a group row
# selects the group node — its members come along by membership, which is
# what a group selection means everywhere else too). Ctrl/Shift+click
# toggles the row's entry into the multi-selection instead.
"""
    OutlinePanel(; doc, selection, fill = false)

The document outline: an indented tree of every shape and (nested) group.
Groups show an outlined box mark, shapes a square in their layer colour.
Clicking a row selects *exactly* that document entry — a shape row
selects only that shape (a parent group stays unselected), a group row
selects the group (its members follow by membership). Ctrl/Shift+click
toggles the row's entry into the multi-selection instead (the mods must be
held *while* clicking — Rocks refreshes them at click time). The row of the
selected entry (and rows selected as part of a larger selection) highlights.
"""
function OutlinePanel(; doc = Observable(ArtObject[]),
                      selection = Observable(Int[]), fill = false)
    doc_obs = @use doc
    selection_obs = @use selection
    t = E.theme()
    d = doc_obs[]

    rows = Any[]

    "One subtree preorder: the row, then a group's members deeper."
    function add_subtree(index, depth)
        (1 <= index <= length(d)) || return nothing
        art = d[index]
        selected = index in selection_obs[]
        fg = selected ? t.colors.selection_text : t.colors.text
        # Leading mark: layer-coloured square for shapes, outlined box for
        # groups (the container glyph, no geometry behind it).
        mark = is_group(art) ?
               (@rock Box(; width = 10, height = 10, radius = 2,
                          background = t.colors.document,
                          border_color = fg, border_width = 1)) :
               (@rock Box(; width = 10, height = 10,
                          background = layer_color(art.layer),
                          border_color = fg, border_width = 1))
        push!(rows, @rock Pressable(
            (@rock Box(; width = depth * 14, height = 1)),
            mark,
            E.text_element(art.name; color = fg, size = t.metrics.font_size,
                           font = t.font);
            on_press = () -> begin
                # Ctrl/Shift+click toggles the entry into the multi-selection
                # (the mods ride on the click — Rocks refreshes them at
                # click time); a plain click selects exactly this entry, a
                # shape never its parent group, a group never its parent.
                if Rocks.LAST_KEYMODS[] & 0x00C3 != 0   # either Shift or Ctrl
                    s = copy(selection_obs[])
                    if index in s
                        deleteat!(s, findfirst(==(index), s))
                    else
                        push!(s, index)
                    end
                    selection_obs[] = sort!(s)
                else
                    selection_obs[] = [index]
                end
                nothing
            end,
            background = selected ? t.colors.selection : nothing,
            hover_background = selected ? t.colors.selection : t.colors.hot,
            pressed_background = selected ? t.colors.selection : t.colors.hot_border,
            height = t.metrics.row_height,
            padding_x = 3, padding_y = 0,
            direction = :row, align = :center, gap = 6, fill = true))
        is_group(art) && for c in child_indices(d, art)
            add_subtree(c, depth + 1)
        end
        return nothing
    end
    for i in top_level_indices(d)
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
