# The app shell: menu, workspace, status bar, error dialogs.
#
# Shell = `Enterprise.Form` (analysis §4.2): LightBurn's regions map onto the
# form — the workspace canvas is the client area, the menu bar sits on top
# and the status bar stays pinned to the bottom edge. The pane layout (Cuts &
# Layers panel, tool docks) arrives in later phases.
#
# State placement: the document (`Observable{Vector{ArtObject}}`) is app-level
# state — it is the common ancestor state of the workspace, the status bar
# and the open action. Every consumer receives it as a prop and subscribes
# with `@use` itself; the shell's own state (the native-dialog result and the
# error feedback) is `@use` hook state of the shell.
#
# File opening goes through SDL3's native OS dialog (`show_open_file_dialog!`):
# the dialog is asynchronous and its callback may fire on another thread, so
# it only fills the `pending_open` observable; the shell consumes it on the
# main thread during the next render pass, where the import runs.
#
# NOTE (parse gotcha): a bare spaced `@rock X(...)` followed by a comma and a
# keyword parses as a chained tuple assignment, so every macro application
# followed by more call arguments is wrapped in parentheses.

const SHELL_WIDTH = 1100
const SHELL_HEIGHT = 700

"A one-line summary for the status bar, e.g. `unicorn.svg: 37 outlines`.
Group entries hold no geometry of their own (their members are listed by
their own files) — the summary counts shapes only."
function doc_summary(objs::AbstractVector{ArtObject})
    shapes = [obj for obj in objs if !is_group(obj)]
    isempty(shapes) && return "no design imported — use File → Open…"
    parts = [string(obj.name, ": ", length(obj.paths),
                    length(obj.paths) == 1 ? " outline" : " outlines")
             for obj in shapes]
    return join(parts, "   ·   ")
end

# The bottom status bar: the live document summary. `@use` subscribes it to
# the document so it refreshes exactly when the document changes; workspace
# drag/zoom cycles (draw-only events) never re-run it. Layout props fed by
# `Form` (e.g. `fill`) are forwarded into the bar, which stretches it across
# the window inside Form's bottom wrap.
function DocStatus(; doc = Observable(ArtObject[]), fill = false)
    doc = @use doc
    return E.StatusBar(grip = false, fill = fill,
                       panels = Any[E.StatusPanel(text = doc_summary(doc[]))])
end

# The layer bar: LightBurn's Color Palette along the bottom (analysis 02 §4).
# The swatches are the palette layers `00`–`29` plus the `T1`/`T2` tool
# layers. Clicking a swatch assigns its layer to the selected objects — with
# nothing selected it becomes the colour for newly created shapes.
function LayerBar(; doc = Observable(ArtObject[]),
                  selection = Observable(Int[]),
                  active_layer = Observable(0), fill = false)    doc_obs = @use doc
    selection_obs = @use selection
    active_obs = @use active_layer
    t = E.theme()

    "Recolour all selected shapes to layer `l` and make it the colour for
    newly created shapes (LightBurn's palette click behaviour)."
    set_layer!(l) = begin
        sel = selection_obs[]
        if !isempty(sel)
            d = copy(doc_obs[])
            for i in sel
                1 <= i <= length(d) || continue
                d[i] = first(set_layer([d[i]], l))
            end
            doc_obs[] = d
        end
        active_obs[] = l
        return nothing
    end

    # The layers of the selected shapes — every one of them lights its chip
    # (a multi-selection spanning layers lights them all).
    selected_layers() = Set(doc_obs[][i].layer for i in selection_obs[]
                            if 1 <= i <= length(doc_obs[]))

    # A palette chip: the layer colour as a raised square; the active one
    # (colour for new shapes) and every layer holding selected shapes carry
    # the selection-colour border. Tool layers get a tiny T1/T2 caption
    # since they act differently.
    chip(l) = begin
        lit = active_obs[] == l || l in selected_layers()
        Mechanics.Button(;
            label = is_tool_layer(l) ? layer_label(l) : "",
            on_press = () -> set_layer!(l),
            width = 16, height = 16, padding = 0, gap = 0, radius = 4,
            background = layer_color(l),
            text_color = (0.05, 0.05, 0.05), size = 6, font = t.font,
            border_color = lit ? t.colors.selection : t.colors.border,
            border_width = lit ? 2 : 1, bevel = :raised)
    end

    chips = Any[chip(l) for l in 0:(CUT_LAYERS + 1)]
    return E.StatusBar(grip = false, fill = fill, panels = chips)
end

# The Cuts/Layers panel: LightBurn's docked right window (analysis 03 §5).
# One entry per layer that has geometry in the document; the abbreviated
# settings block shows the mode and the speed/power pair. Double-clicking an
# entry opens the process editor for that layer.
function CutsLayersPanel(; doc = Observable(ArtObject[]),
                         processes = Observable(Dict{Int,Process}()),
                         editor_open = Observable(false),
                         edit_layer = Observable(0),
                         width = 240, fill = false)
    doc_obs = @use doc
    processes_obs = @use processes
    editor_open_obs = @use editor_open
    edit_layer_obs = @use edit_layer
    t = E.theme()
    small = t.metrics.font_size - 3
    weaker = t.colors.disabled_text

    header = @rock Box(
        @rock E.Text("Cuts / Layers"; size = small, color = t.colors.text);
        fill = true, background = t.colors.control, height = 22,
        direction = :row, align = :center, padding = 6)
    rows = Any[]
    for l in document_layers(doc_obs[])
        p = process_for(processes_obs[], l)
        inner = @rock Row(
            @rock Box(; width = 14, height = 14, radius = 3,
                      background = layer_color(l),
                      border_color = t.colors.border, border_width = 1),
            @rock E.Text(layer_label(l); size = small, width = 30,
                         color = t.colors.text),
            @rock E.Text(mode_label(p.mode); color = weaker, size = small,
                         width = 66),
            @rock E.Text(quick_cuts(p); color = weaker, size = small, width = 74);
            gap = 8, padding = 4, align = :center)
        push!(rows, @rock Pressable(inner;
                                    fill = true,
                                    on_double_press = () -> begin
                                        edit_layer_obs[] = l
                                        editor_open_obs[] = true
                                        nothing
                                    end))
    end
    isempty(rows) && push!(rows, (@rock E.Text(
        "no layers yet — import art";
        color = t.colors.disabled_text, size = small)))
    return @rock Box(header, rows...;
                     direction = :column, gap = 0, width = width,
                     height = "100%", fill = fill,
                     background = t.colors.control,
                     border_color = t.colors.border, border_width = 1)
end

# The left tool strip: LightBurn's creation toolbar (§5.9). For v1 two
# tools: the mouse (select) tool and the rectangle tool. The strip is a
# narrow column of icon buttons; the active tool shows a recessed
# (item-hot) background until another tool is picked.
function ToolsPanel(; tool = Observable(:mouse), width = 44, fill = false)
    tool_obs = @use tool
    t = E.theme()
    function tool_button(icon_name, mode)
        active = tool_obs[] === mode
        glyph = MDI_GLYPHS[icon_name]
        @rock Pressable(
            @rock Font(font = MDI_FONT, size = 20, weight = "medium",
                       variant = "normal";
                       @rock E.Icon(name = glyph; size = 20, color = t.colors.text));
            on_press = () -> (tool_obs[] = mode),
            width = "100%", height = 32,
            direction = :column, align = :center, justify = :center,
            background = active ? t.gradients.item_hot : nothing,
            hover_background = active ? t.gradients.item_hot :
                                       t.gradients.button_hover,
            pressed_background = t.gradients.item_hot,
            border_color = active ? t.colors.hot_border : nothing,
            border_width = active ? 1 : 0,
            radius = t.metrics.control_radius)
    end
    return @rock Box(
        (tool_button("select", :mouse)),
        (tool_button("rectangle", :rect));
        direction = :column, gap = 4, padding = 4, align = :start,
        width = width, height = "100%", fill = fill,
        background = t.colors.window,
        border_color = t.colors.border, border_width = 1)
end

# The process editor: the Cut Settings Editor window for one layer
# (analysis 03 §3/§4). Mounted as its own OS window like `MessageBox` — it
# opens via the panel's double-click. The editor edits hook-state copies and
# writes them back to the layer's stored process on OK; Cancel discards.
function ProcessEditor(; open = Observable(false), layer = Observable(0),
                       processes = Observable(Dict{Int,Process}()),
                       width = 340)
    open_obs = @use open
    layer_obs = @use layer
    processes_obs = @use processes
    t = E.theme()
    small = t.metrics.font_size - 3
    open_obs[] || return nothing

    # The edited copies live as hook state; a re-open syncs them back to the
    # stored process (the effect owns nothing else, so mid-editing typing is
    # safe — the fields don't write to `processes`).
    mode = @use Observable(:line)
    speed = @use Observable(6000.0)
    max_power = @use Observable(20.0)
    passes = @use Observable(1.0)
    interval = @use Observable(0.100)
    scan_angle = @use Observable(0.0)
    kerf = @use Observable(0.0)
    # §3 `Mode`: a dropdown over the three vector modes.
    sel = @use Observable(1)
    useEffect(() -> begin
        base = process_for(processes_obs[], layer_obs[])
        s = base.settings
        mode[] = base.mode
        sel[] = findfirst(==(base.mode), MODES)
        speed[] = s.speed
        max_power[] = s.max_power
        passes[] = s.passes
        interval[] = s.interval
        scan_angle[] = s.scan_angle
        kerf[] = s.kerf
        nothing
    end, (open_obs, layer_obs, processes_obs))

    ok() = begin
        processes_obs[] = with_process(processes_obs[], layer_obs[],
            Process(mode = mode[],
                    settings = CutSettings(speed = speed[],
                                           max_power = max_power[],
                                           passes = passes[],
                                           interval = interval[],
                                           scan_angle = scan_angle[],
                                           kerf = kerf[])))
        open_obs[] = false
        return nothing
    end
    cancel() = (open_obs[] = false)

    # §3 `Mode`: the dropdown drives `mode`, which drives the field slots.
    mode_row = @rock Row(
        (@rock Box(@rock E.Label("Mode"); width = 88, align = :center,
                   direction = :row)),
        (@rock E.ComboBox(
            items = [mode_label(m) for m in MODES], selected = sel,
            on_change = () -> mode[] = MODES[sel[]], width = 100));
        gap = 4, align = :center)
    # A labelled value row (same pattern as the position toolbar's spinners).
    frow(label, obs, step) = @rock Row(
        (@rock Box(@rock E.Label(label); width = 88, align = :center,
                   direction = :row)),
        (@rock E.Spinner(value = obs, step = step, width = 100));
        padding = 3, gap = 4, align = :center)
    # Only the mode-relevant parameters get slots (§3/§5.3: Speed/Power/
    # Passes for every mode; Interval + Scan Angle for the scan modes; Kerf
    # Offset for Line mode). Hidden slots render as a zero-height empty
    # `Box` — a different kind than the `Row` — so the reconciler replaces
    # the fiber instead of rebinding (statefully) a live row into it; see
    # gotcha 31. Per-row padding (not column gap) keeps collapsed slots at
    # zero size. Ternary arms stay parenthesized: a bare `@rock` next to a
    # comma swallows the following list items (gotcha 34).
    fhidden() = (@rock Box())
    scans = mode[] == :fill || mode[] == :offset_fill
    fields = (@rock Box(
        frow("Speed", speed, 100.0),
        frow("Power", max_power, 1.0),
        frow("Passes", passes, 1.0),
        (scans ? frow("Interval", interval, 0.050) : fhidden()),
        (scans ? frow("Scan angle", scan_angle, 1.0) : fhidden()),
        (scans ? fhidden() : frow("Kerf", kerf, 0.010));
        direction = :column, align = :start))
    footer = @rock Box(
        Mechanics.Button(; label = "OK", on_press = ok, width = 70,
                         height = t.metrics.button_height, size = small,
                         font = t.font, bevel = :raised, border_width = 1,
                         border_color = t.colors.border),
        Mechanics.Button(; label = "Cancel", on_press = cancel, width = 70,
                         height = t.metrics.button_height, size = small,
                         font = t.font, bevel = :raised, border_width = 1,
                         border_color = t.colors.border);
        direction = :row, gap = 8, align = :center, justify = :end,
        padding = 10)
    body = @rock Box(
        mode_row, fields, footer;
        direction = :column, gap = 10, padding = 14, align = :start,
        background = t.colors.control, fill = true)
    return Rocks.Element(
        Rocks.Window,
        Dict{Symbol,Any}(:title => "Process — layer " *
                                    layer_label(layer_obs[]),
                         :width => width, :fit_content => true,
                         :background => t.colors.control,
                         :padding => 1, :direction => :column,
                         :position => :cascade, :resizable => false,
                         :on_close => cancel),
        Any[body],
    )
end

# The Position toolbar: LightBurn's Numeric Edits toolbar (analysis 02 §3.6).
# The 3×3 origin grid determines the anchor point of the selection's bounding
# rectangle; X/Y move the selection so the anchor lands on the typed values;
# W/H scale about the anchor; the lock button makes scaling uniform.

"The 3×3 origin grid: nine small buttons; the active one is highlighted."
function origin_grid(origin::Observable)
    t = E.theme()
    cells = Any[]
    for row in 1:3, col in 1:3
        active = origin[] == (col, row)
        push!(cells, Mechanics.Button(; label = "",
                                      on_press = () -> origin[] = (col, row),
                                      width = 12, height = 12, padding = 0,
                                      gap = 0, radius = 0,
                                      background = active ? t.colors.selection :
                                                     t.colors.control,
                                      border_color = t.colors.border,
                                      border_width = 1, bevel = :raised))
    end
    return @rock Column(
        @rock Row(cells[1], cells[2], cells[3]; gap = 1),
        @rock Row(cells[4], cells[5], cells[6]; gap = 1),
        @rock Row(cells[7], cells[8], cells[9]; gap = 1);
        gap = 1, align = :center)
end

function PositionToolbar(; doc = Observable(ArtObject[]),
                         selection = Observable(Int[]),
                         origin = Observable((2, 2)),
                         lock = Observable(false),
                         fill = false)
    doc_obs = @use doc
    selection_obs = @use selection
    origin_obs = @use origin
    lock_obs = @use lock
    t = E.theme()

    # The spinner values, kept in sync with the selection (the anchor point
    # per the 9-dot grid and the bounding rectangle's size).
    x_pos = @use Observable(0.0)
    y_pos = @use Observable(0.0)
    w_size = @use Observable(0.0)
    h_size = @use Observable(0.0)

    "The anchor point of `bounds` per the 9-dot grid (row 1 = top)."
    function anchor_point(bounds)
        (pmin, pmax) = bounds
        (col, row) = origin_obs[]
        x = pmin[1] + (col - 1) / 2 * (pmax[1] - pmin[1])
        y = row == 1 ? pmax[2] : row == 2 ? (pmin[2] + pmax[2]) / 2 : pmin[2]
        return Point(x, y)
    end

    # Keep the spinners in sync when the selection or the document changes.
    # The selection resolves to its leaf shapes first: a selected group
    # shows (and moves/scales) its whole subtree's union.
    useEffect(() -> begin
        idxs = resolve_leaves(doc_obs[], selection_obs[])
        if length(idxs) == 1
            bounds = document_bounds([doc_obs[][idxs[1]]])
            if bounds !== nothing
                (ax, ay) = anchor_point(bounds)
                x_pos[] = ax
                y_pos[] = ay
                w_size[] = bounds[2][1] - bounds[1][1]
                h_size[] = bounds[2][2] - bounds[1][2]
            end
        end
        nothing
    end, (doc_obs[], selection_obs[], origin_obs[]))

    "Move the selection so its anchor point lands on `(v, other)`."
    function move_to!(v, axis)
        idxs = resolve_leaves(doc_obs[], selection_obs[])
        (length(idxs) == 1) || return
        art = doc_obs[][idxs[1]]
        bounds = document_bounds([art])
        bounds === nothing && return
        (ax, ay) = anchor_point(bounds)
        dx = axis == :x ? v - ax : 0.0
        dy = axis == :y ? v - ay : 0.0
        d = copy(doc_obs[])
        d[idxs[1]] = translate(art, dx, dy)
        doc_obs[] = d
        return nothing
    end

    "Scale the selection so its size along `axis` becomes `v`, anchored at
    the 9-dot anchor; the lock makes scaling uniform."
    function resize_to!(v, axis)
        idxs = resolve_leaves(doc_obs[], selection_obs[])
        (length(idxs) == 1) || return
        art = doc_obs[][idxs[1]]
        bounds = document_bounds([art])
        bounds === nothing && return
        anchor = anchor_point(bounds)
        old_w = max(bounds[2][1] - bounds[1][1], 1e-6)
        old_h = max(bounds[2][2] - bounds[1][2], 1e-6)
        sx = axis == :w ? v / old_w : 1.0
        sy = axis == :h ? v / old_h : 1.0
        if lock_obs[]
            axis == :w ? (sy = sx) : (sx = sy)
        end
        d = copy(doc_obs[])
        d[idxs[1]] = scale(art, sx, sy, anchor)
        doc_obs[] = d
        return nothing
    end

    # The 3×3 origin grid.
    grid = origin_grid(origin_obs)

    # The lock button: a closed padlock while the aspect ratio is locked,
    # an open one when it is not; highlighted while locked.
    locked = lock_obs[]
    glyph = locked ? MDI_GLYPHS["lock"] : MDI_GLYPHS["lock-open"]
    lock_btn = (@rock Mechanics.Button(
        @rock Font(font = MDI_FONT, size = 16, weight = "medium",
                   variant = "normal";
                   @rock E.Icon(name = glyph; size = 16, color = t.colors.text));
        on_press = () -> (lock_obs[] = !lock_obs[]),
        width = t.metrics.input_height, height = t.metrics.input_height,
        padding = 2, gap = 0, radius = 0,
        background = locked ? t.colors.selection : t.colors.control,
        text_color = t.colors.text,
        border_color = t.colors.border, border_width = 1,
        size = t.metrics.font_size - 2, font = t.font, bevel = :raised))
    axis_label(text) = @rock Box(@rock E.Label(text);
                                 width = 16, align = :center, direction = :row)
    # The translate/scale inputs only act on a single selection; with none
    # (or a multi-selection) they are grayed out. (The toolbar re-renders on
    # selection changes.)
    has_sel = length(resolve_leaves(doc_obs[], selection_obs[])) == 1
    # A labelled spinner: the label to its left; edits apply to the selection.
    spinner_row(label, obs, apply, step = 1.0) = @rock Row(
        axis_label(label),
        (@rock E.Spinner(value = obs, step = step, width = 90,
                         on_change = apply, disabled = !has_sel));
        gap = 4, align = :center)
    # X/Y and W/H stacked vertically; the lock button right of the W/H column.
    xy_column = @rock Column(
        spinner_row("X", x_pos, v -> move_to!(v, :x)),
        spinner_row("Y", y_pos, v -> move_to!(v, :y)); gap = 2)
    wh_column = @rock Column(
        spinner_row("W", w_size, v -> resize_to!(v, :w)),
        spinner_row("H", h_size, v -> resize_to!(v, :h)); gap = 2)
    return @rock Box(
        grid,
        xy_column,
        wh_column,
        @rock Box(lock_btn; align = :center, direction = :row);
        direction = :row, gap = 10, padding = 3, align = :center,
        background = t.gradients.toolbar, fill = fill)
end

# The workspace context menu (§8.15): the Group / Ungroup popup the
# workspace's right click opens. A component of its own so the items'
# enablement is click-current: it subscribes to the document and the
# selection (the shell body would only see a stale snapshot — Rocks
# re-renders the fibers that read a change, and the shell doesn't read
# either), so the items rebuild exactly when the selection moves.
function WorkspaceContextMenu(; doc = Observable(ArtObject[]),
                              selection = Observable(Int[]),
                              ctx_open = Observable(false))
    doc_obs = @use doc
    selection_obs = @use selection

    "Group action: wrap the selected entries (shapes and/or groups — a
    selected group joining a new group is how nesting is built) in one new
    group appended to the document; the selection becomes the new group."
    function context_group!()
        idxs = filter(i -> 1 <= i <= length(doc_obs[]), selection_obs[])
        isempty(idxs) && return nothing
        d = group_arts(doc_obs[], idxs)
        doc_obs[] = d
        selection_obs[] = [length(d)]
        return nothing
    end

    "Ungroup action: dissolve every selected group node one level — members
    promote into the parent group (or to the top level); the selection
    follows the dissolved groups' members (selected shapes stay selected)."
    function context_ungroup!()
        d = doc_obs[]
        idxs = filter(i -> 1 <= i <= length(d), selection_obs[])
        isempty(idxs) && return nothing
        keep_ids = UInt[]
        gidx = Int[]
        for i in idxs
            if is_group(d[i])
                push!(gidx, i)
                for c in child_indices(d, d[i])   # the direct member units
                    push!(keep_ids, d[c].id)
                end
            else
                push!(keep_ids, d[i].id)
            end
        end
        isempty(gidx) && return nothing
        d1 = ungroup_arts(d, gidx)
        doc_obs[] = d1
        sel = Int[]
        for id in keep_ids
            i = art_index(d1, id)
            i !== nothing && push!(sel, i)
        end
        selection_obs[] = sort!(sel)
        return nothing
    end

    sel_entries = filter(i -> 1 <= i <= length(doc_obs[]), selection_obs[])
    return @rock E.ContextMenu(
        open = ctx_open,
        items = [
            E.MenuItem(label = "Group", enabled = !isempty(sel_entries),
                       on_press = context_group!),
            E.MenuItem(label = "Ungroup",
                       enabled = any(i -> is_group(doc_obs[][i]), sel_entries),
                       on_press = context_ungroup!),
        ])
end

function App(; doc = nothing, selection = nothing, origin = nothing, lock = nothing,
             active_layer = nothing, processes = nothing,
             editor_open = nothing, edit_layer = nothing, tool = nothing,
             panel_tab = nothing, ctx_open = nothing)
    # Hook state: every chunk of state the shell owns must survive re-renders
    # — plain `Observable(...)` locals are re-created whenever the shell
    # re-runs (any click re-renders the whole tree), so callbacks would write
    # into a dead instance. `doc`/`selection` may be supplied by the caller
    # (tests embed their own); then the internal ones are unused.
    doc_internal = @use Observable(ArtObject[])
    doc = doc === nothing ? doc_internal : doc
    selection_internal = @use Observable(Int[])
    selection = selection === nothing ? selection_internal : selection
    origin_internal = @use Observable((2, 2))
    origin = origin === nothing ? origin_internal : origin
    lock_internal = @use Observable(false)
    lock = lock === nothing ? lock_internal : lock
    # The active palette layer: the colour for newly created shapes (§4). v1
    # has no creation tools yet — the state and the bar highlight exist now.
    active_internal = @use Observable(0)
    active_layer = active_layer === nothing ? active_internal : active_layer
    # The per-layer processes (analysis 03) and the editor's open state.
    processes_internal = @use Observable(Dict{Int,Process}())
    processes = processes === nothing ? processes_internal : processes
    editor_open_internal = @use Observable(false)
    edit_layer_internal = @use Observable(0)
    editor_open = editor_open === nothing ? editor_open_internal : editor_open
    edit_layer = edit_layer === nothing ? edit_layer_internal : edit_layer
    # The active tool (:mouse select / :rect rectangle), shared between the
    # tool strip and the workspace; injectable for tests.
    tool_internal = @use Observable(:mouse)
    tool = tool === nothing ? tool_internal : tool
    # The right panel's tab: the layer settings page first, the document
    # outline second; injectable for tests.
    panel_tab_internal = @use Observable(1)
    panel_tab = panel_tab === nothing ? panel_tab_internal : panel_tab
    # The workspace context menu (Group / Ungroup): the open flag only —
    # the workspace's right click flips it and the menu anchors itself at
    # the click. Injected into the Workspace as a prop; injectable for
    # tests.
    ctx_open_internal = @use Observable(false)
    ctx_open = ctx_open === nothing ? ctx_open_internal : ctx_open
    # The workspace/panel split: LightBurn's right dock starts out ~80% of
    # the window; the handle is draggable.
    split_ratio = @use Observable(0.78)
    pending_open = @use Observable{Union{Nothing,FileDialogResult}}(nothing)
    error_open = @use Observable(false)
    last_error = @use Observable("")

    # Consume the native file dialog's result on the main thread. The dialog
    # callback (which may run on another thread) only fills `pending_open`;
    # the per-file import and the error feedback run here, during the render.
    pending = pending_open[]
    if pending !== nothing
        pending_open[] = nothing
        if pending.error != ""
            last_error[] = pending.error
            error_open[] = true
        elseif !isempty(pending.paths)
            arts = ArtObject[]
            errs = String[]
            for path in pending.paths
                try
                    append!(arts, import_art(path))
                catch err
                    push!(errs, string(basename(path), ": ",
                                       sprint(showerror, err)))
                end
            end
            # Center everything imported in this action on the work area,
            # keeping the relative positioning of the group.
            isempty(arts) || (doc[] = vcat(doc[], center_on_workarea(arts)))
            if !isempty(errs)
                last_error[] = join(errs, "\n")
                error_open[] = true
            end
        end
    end

    menu = (@rock E.MenuBar(menus = [
        E.Menu("File", items = [
            E.MenuItem(label = "Open…",
                       on_press = () -> show_open_file_dialog!(pending_open)),
        ]),
    ]))

    return E.Form(
        title = "BlazeCraft",
        width = SHELL_WIDTH, height = SHELL_HEIGHT, padding = 0,
        menu = menu,
        # Keyboard shortcuts (no field focused): Delete removes the selected
        # shapes, Escape resets the tool to the mouse.
        on_key = (key) -> begin
            if key == "Delete"
                idxs = filter(i -> 1 <= i <= length(doc[]), selection[])
                if !isempty(idxs)
                    # Groups delete as entries: a deleted shape is pruned
                    # from its group's children, a deleted group node
                    # dissolves (delete_arts in document.jl).
                    doc[] = delete_arts(doc[], idxs)
                    selection[] = Int[]
                end
            elseif key == "Escape"
                tool[] = :mouse
            end
            return nothing
        end,
        toolbar = (@rock PositionToolbar(doc = doc, selection = selection,
                                         origin = origin, lock = lock)),
        status = (@rock Row(DocStatus(doc = doc), (@rock Box(; flex = 1));
                            gap = 6, align = :center)),
        children = Any[
            (@rock Row(
                (@rock ToolsPanel(tool = tool; fill = true)),
                (@rock Split(
                    (@rock Column(
                        (@rock Workspace(doc = doc, selection = selection,
                                         processes = processes, tool = tool,
                                         active_layer = active_layer,
                                         ctx_open = ctx_open;
                                         flex = 1, fill = true)),
                        # The layer palette sits as a strip directly below
                        # the workspace — same width as the canvas, outside
                        # the app's status bar.
                        (@rock LayerBar(doc = doc, selection = selection,
                                        active_layer = active_layer;
                                        fill = true));
                        fill = true));
                    (@rock Box(
                        (@rock E.TabControl(
                            tabs = ["Cuts / Layers", "Outline"],
                            selected = panel_tab,
                            children = Any[
                                (@rock CutsLayersPanel(doc = doc,
                                                       processes = processes,
                                                       editor_open = editor_open,
                                                       edit_layer = edit_layer,
                                                       fill = true;
                                                       flex = 1)),
                                (@rock OutlinePanel(doc = doc,
                                                    selection = selection;
                                                    fill = true, flex = 1)),
                            ];
                            flex = 1, fill = true));
                        fill = true));
                    direction = :horizontal, ratio = split_ratio,
                    flex = 1, fill = true));
                gap = 2, fill = true, height = "100%")),
            (@rock ProcessEditor(open = editor_open, layer = edit_layer,
                                 processes = processes)),
            # The workspace context menu (right click): Group / Ungroup over
            # the current selection. Anchors at the pointer by default.
            (@rock WorkspaceContextMenu(doc = doc, selection = selection,
                                        ctx_open = ctx_open)),
            (@rock E.MessageBox(open = error_open, title = "Import failed",
                                message = last_error[], icon = :warning)),
        ])
end
