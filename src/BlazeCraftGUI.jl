module BlazeCraftGUI

import Rocks
import Rocks: Enterprise as E
using Rocks
# PolyLine, Point and flatten come from BlazeCraft.Shapes; the app-level
# `Observable` is Rocks' re-export of Observables.
import SDL3
import SDL3: SDL_DialogFileFilter
import BlazeCraft
import BlazeCraft.Shapes: PolyLine, Point, flatten

include("document.jl")
include("camera.jl")
include("filedialog.jl")
include("workspace.jl")
include("app.jl")

"Run the app window (headless runs accept `frames = n, screenshot = \"…\"`)."
run_gui(; kw...) = render(App; kw...)

export App, PositionToolbar, ArtObject, import_art, center_on_workarea,
       translate, scale, rotate,
       run_gui, FileDialogResult, show_open_file_dialog!

end # module
