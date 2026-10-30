module BlazeCraftGUI

import Rocks
import Rocks: Enterprise as E
import Rocks.Enterprise: Font
using Rocks
# PolyLine, Point and flatten come from BlazeCraft.Shapes; the app-level
# `Observable` is Rocks' re-export of Observables.
import SDL3
import SDL3: SDL_DialogFileFilter
import BlazeCraft
import BlazeCraft.Shapes: PolyLine, Point, flatten
include("document.jl")
include("camera.jl")
include("cuts.jl")
include("fills.jl")
include("filedialog.jl")
include("icons.jl")
include("workspace.jl")
include("outline.jl")
include("app.jl")

"Run the app window (headless runs accept `frames = n, screenshot = \"…\"`)."
run_gui(; kw...) = render(App; kw...)

export App, PositionToolbar, LayerBar, CutsLayersPanel, OutlinePanel, ProcessEditor,
       ToolsPanel,
       rect_art, ArtObject, is_group, import_art, center_on_workarea,
       group_arts, ungroup_arts, delete_arts, resolve_leaves, parent_group,
       top_level_indices, leaves_of, child_indices, art_index, art_bounds,
       translate, scale, rotate, set_layer, layer_color, layer_label,
       is_tool_layer, CUT_LAYERS, LAYER_COLORS_HEX, MODES, mode_label,
       CutSettings, Process, document_layers, process_for, with_process,
       quick_cuts, even_odd_runs, paint_even_odd!,
       run_gui, FileDialogResult, show_open_file_dialog!

end # module
