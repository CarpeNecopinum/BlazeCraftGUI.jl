# Native file-open dialog through SDL3 (SDL_dialog.h, wrapped by SDL3.jl).
#
# On Linux, SDL 3.4's dialogs go through the XDG desktop portal over DBus
# (zenity/kdialog support was dropped in SDL 3.4): the session bus and a
# running `xdg-desktop-portal` service are required, and SDL needs
# `PumpEvents` in the main loop. When the portal is unreachable the callback
# fires with an error and SDL's reason (surfaced below in the error box).
#
# `SDL_ShowOpenFileDialog` is asynchronous: `File → Open…` returns
# immediately and the dialog's callback fires later — possibly on another
# thread — with the chosen paths. The callback therefore only fills an
# Observable (the write is thread-safe: Rocks' hook just flips the dirty
# flag); the main thread consumes it during the next render pass, where the
# actual import runs.
#
# The filter strings must outlive the dialog — SDL does not copy them — so
# they live as module constants.

"Result of one native file-open dialog."
struct FileDialogResult
    ok::Bool          # true: the user chose files; false: canceled
    error::String     # non-empty when the dialog itself failed
    paths::Vector{String}
end

# LightBurn imports vector designs; the filter list mirrors the formats the
# v1 import pipeline reads. The strings are module constants (rooted); the
# SDL_DialogFileFilter array itself is built at *runtime* in
# `show_open_file_dialog!` — one built during precompilation would hold
# stale pointers into precompile-era memory.
const _FILTER_DEFS = [
    ("Laser design files", "svg;dxf"),
    ("SVG files", "svg"),
    ("DXF files", "dxf"),
    ("All files", "*"),
]

# The filter array of the dialog currently open; it must stay alive until
# SDL's callback fires (SDL does not copy the filters).
const _LIVE_FILTERS = Ref{Any}(nothing)

"""
    _dialog_result(userdata, filelist, filter)

The `@cfunction` target SDL invokes when the dialog finishes. `userdata` is
the `pending` Observable (passed as a raw pointer); `filelist` is `C_NULL` on
a dialog error, points to `C_NULL` when the user canceled, and otherwise is
a null-terminated list of chosen paths.
"""
function _dialog_result(userdata::Ptr{Cvoid}, filelist::Ptr{Cstring},
                        filter::Cint)
    obs = unsafe_pointer_to_objref(userdata)
    result = if filelist == C_NULL
        # SDL set the reason (e.g. "Failed to connect to DBus" — the portal
        # backend) before invoking the callback; surface it.
        FileDialogResult(false, "the OS file dialog failed: " * SDL3.GetError(),
                         String[])
    else
        paths = String[]
        for i in 1:typemax(Int)
            p = unsafe_load(filelist, i)
            p == C_NULL && break
            push!(paths, unsafe_string(p))
        end
        FileDialogResult(true, "", paths)
    end
    obs[] = result
    _LIVE_FILTERS[] = nothing   # the dialog is done; the filters can be freed
    return nothing
end

"""
    show_open_file_dialog!(pending, parent = C_NULL)

Launch the OS file-open dialog (multiple selection enabled, filtered to the
design formats). `pending` is an `Observable{Union{Nothing,FileDialogResult}}`
owned by the app: the callback fills it when the user chooses, cancels (an
empty list), or the dialog fails; the app consumes it on the main thread
during the next render pass. `parent` is the SDL window (`SDL3.Window`) the
dialog should be modal for, or `nothing`/`C_NULL` for an unowned dialog.
"""
function show_open_file_dialog!(pending::Observable, parent = nothing)
    # `SDL3.Window` is a *type alias* for `Ptr{SDL_Window}`: wrap once, not twice.
    window = parent === nothing ? SDL3.Window(C_NULL) : SDL3.Window(parent)
    # The @cfunction must be created at *runtime* — one evaluated during
    # precompilation produces a stale pointer that segfaults when SDL calls it.
    cb = @cfunction(_dialog_result, Cvoid, (Ptr{Cvoid}, Ptr{Cstring}, Cint))
    filters = [SDL_DialogFileFilter(pointer(name), pointer(pattern))
               for (name, pattern) in _FILTER_DEFS]
    _LIVE_FILTERS[] = filters
    GC.@preserve filters begin
        SDL3.ShowOpenFileDialog(cb, pointer_from_objref(pending);
                                window = window, filters = filters,
                                allow_many = true)
    end
    return nothing
end
