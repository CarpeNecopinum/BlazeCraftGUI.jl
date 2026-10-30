# The app's icon font: Material Design Icons (Pictogrammers Free License —
# see assets/fonts/LICENSE-MDI.txt). BlazeCraft registers nothing globally:
# every icon use site pairs `E.Icon` with a `Rocks.Font(font = MDI_FONT, ...)`
# so the Enterprise design in Rocks stays font-agnostic. Codepoints are from
# materialdesignicons.css (v7.4.47), pattern `\.mdi-<name>::before`.

const MDI_FONT = joinpath(@__DIR__, "..", "assets", "fonts",
                          "materialdesignicons-webfont.ttf")

# Semantic icon name -> MDI glyph. Names without an entry fall back to the
# built-in unicode set in Rocks.Enterprise.ICONS.
const MDI_GLYPHS = Dict{String,Char}(
    "check" => Char(0xf012c), "close" => Char(0xf0156), "menu" => Char(0xf035c),
    "more" => Char(0xf01d8), "arrow_back" => Char(0xf004d),
    "arrow_forward" => Char(0xf0054), "arrow_up" => Char(0xf005d),
    "arrow_down" => Char(0xf0045), "add" => Char(0xf0415),
    "remove" => Char(0xf0374), "home" => Char(0xf02dc),
    "settings" => Char(0xf0493), "folder" => Char(0xf024b),
    "file" => Char(0xf0214), "save" => Char(0xf0193),
    "open" => Char(0xf0770), "cut" => Char(0xf0190),
    "copy" => Char(0xf018f), "paste" => Char(0xf0192),
    "undo" => Char(0xf054c), "redo" => Char(0xf044e),
    "search" => Char(0xf0349), "help" => Char(0xf0625),
    "info" => Char(0xf02fd), "warning" => Char(0xf0026),
    "error" => Char(0xf0159), "person" => Char(0xf0004),
    "computer" => Char(0xf07c0), "drive" => Char(0xf02ca),
    "printer" => Char(0xf042a), "network" => Char(0xf0200),
    "refresh" => Char(0xf0450), "play" => Char(0xf040a),
    "stop" => Char(0xf04db), "separator" => Char(0xf035f),
    # creation tools
    "select" => Char(0xf01c0), "rectangle" => Char(0xf05c6),
    "delete" => Char(0xf01b4),
    # state toggles
    "lock" => Char(0xf033e), "lock-open" => Char(0xf033f),
)

# The glyph for a registered icon name, or `nothing` when unknown.
mdi_glyph(name::AbstractString) = get(MDI_GLYPHS, String(name), nothing)
