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

"A one-line summary for the status bar, e.g. `unicorn.svg: 37 outlines`."
function doc_summary(objs::AbstractVector{ArtObject})
    isempty(objs) && return "no design imported — use File → Open…"
    parts = [string(obj.name, ": ", length(obj.paths),
                    length(obj.paths) == 1 ? " outline" : " outlines")
             for obj in objs]
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
                         selection = Observable{Union{Nothing,Int}}(nothing),
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
    useEffect(() -> begin
        sel = selection_obs[]
        if sel !== nothing && 1 <= sel <= length(doc_obs[])
            bounds = document_bounds([doc_obs[][sel]])
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
        sel = selection_obs[]
        (sel !== nothing && 1 <= sel <= length(doc_obs[])) || return
        art = doc_obs[][sel]
        bounds = document_bounds([art])
        bounds === nothing && return
        (ax, ay) = anchor_point(bounds)
        dx = axis == :x ? v - ax : 0.0
        dy = axis == :y ? v - ay : 0.0
        d = copy(doc_obs[])
        d[sel] = translate(art, dx, dy)
        doc_obs[] = d
        return nothing
    end

    "Scale the selection so its size along `axis` becomes `v`, anchored at
    the 9-dot anchor; the lock makes scaling uniform."
    function resize_to!(v, axis)
        sel = selection_obs[]
        (sel !== nothing && 1 <= sel <= length(doc_obs[])) || return
        art = doc_obs[][sel]
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
        d[sel] = scale(art, sx, sy, anchor)
        doc_obs[] = d
        return nothing
    end

    # The 3×3 origin grid.
    grid = origin_grid(origin_obs)

    # The lock button: highlighted while the aspect ratio is locked.
    lock_btn = Mechanics.Button(; label = "Lock",
                                on_press = () -> lock_obs[] = !lock_obs[],
                                width = 46, height = t.metrics.input_height,
                                padding = 4, gap = 0, radius = 0,
                                background = lock_obs[] ? t.colors.selection :
                                               t.colors.control,
                                text_color = t.colors.text,
                                border_color = t.colors.border, border_width = 1,
                                size = t.metrics.font_size - 2, font = t.font,
                                bevel = :raised)
    axis_label(text) = @rock Box(@rock E.Label(text);
                                 width = 16, align = :center, direction = :row)
    # The translate/scale inputs only act on a selection; with none they are
    # grayed out. (The toolbar re-renders on selection changes.)
    has_sel = selection_obs[] !== nothing &&
              1 <= selection_obs[] <= length(doc_obs[])
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

function App(; doc = nothing, selection = nothing, origin = nothing, lock = nothing)
    # Hook state: every chunk of state the shell owns must survive re-renders
    # — plain `Observable(...)` locals are re-created whenever the shell
    # re-runs (any click re-renders the whole tree), so callbacks would write
    # into a dead instance. `doc`/`selection` may be supplied by the caller
    # (tests embed their own); then the internal ones are unused.
    doc_internal = @use Observable(ArtObject[])
    doc = doc === nothing ? doc_internal : doc
    selection_internal = @use Observable{Union{Nothing,Int}}(nothing)
    selection = selection === nothing ? selection_internal : selection
    origin_internal = @use Observable((2, 2))
    origin = origin === nothing ? origin_internal : origin
    lock_internal = @use Observable(false)
    lock = lock === nothing ? lock_internal : lock
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
                    push!(arts, import_art(path))
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
        toolbar = (@rock PositionToolbar(doc = doc, selection = selection,
                                         origin = origin, lock = lock)),
        status = (@rock DocStatus(doc = doc)),
        children = Any[
            (@rock Workspace(doc = doc, selection = selection;
                flex = 1, fill = true, height = "100%")),
            (@rock E.MessageBox(open = error_open, title = "Import failed",
                                message = last_error[], icon = :warning)),
        ])
end
