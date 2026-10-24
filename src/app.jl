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

function App(; doc = nothing)
    # Hook state: every chunk of state the shell owns must survive re-renders
    # — plain `Observable(...)` locals are re-created whenever the shell
    # re-runs (any click re-renders the whole tree), so callbacks would write
    # into a dead instance. `doc` may be supplied by the caller (tests embed
    # their own); then the internal one is unused.
    doc_internal = @use Observable(ArtObject[])
    doc = doc === nothing ? doc_internal : doc
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
        status = (@rock DocStatus(doc = doc)),
        children = Any[
            (@rock Workspace(
                doc = doc;
                flex = 1, fill = true, height = "100%")),
            (@rock E.MessageBox(open = error_open, title = "Import failed",
                                message = last_error[], icon = :warning)),
        ])
end
