# Per-layer processes: LightBurn's "Mode" plus the cut settings of the Cut
# Settings Editor (analysis/03 §3–§5). A layer with at least one object in the
# document shows an entry in the Cuts/Layers panel even before it has stored
# settings — the lookup falls back to sane per-mode defaults.
#
# Units follow the §3 values: Speed in mm/min (LightBurn's default control
# unit — the universal default layer is 6000 mm/min), power in percent,
# distance in millimetres (Line Interval, Kerf Offset), angles in degrees.

"Cut modes (§3 `Mode`): `Line`, `Fill`, `Offset Fill` — Image mode has no use
in a vector-only v1."
const MODES = (:line, :fill, :offset_fill)

"The LightBurn label for a mode."
function mode_label(m::Symbol)
    m === :line && return "Line"
    m === :fill && return "Fill"
    m === :offset_fill && return "Offset Fill"
    return string(m)
end

"""
    CutSettings(; speed, max_power, min_power, passes, interval,
                 scan_angle, kerf)

The Cut Settings Editor's parameter block (§3–§5). Only the mode-appropriate
fields are shown in the editor: `interval`/`scan_angle` belong to the scan
modes, `kerf` to Line mode; `speed`, `max_power`, `passes` apply to all.
"""
Base.@kwdef struct CutSettings
    speed::Float64 = 6000.0      # mm/min — universal default layer (§3)
    max_power::Float64 = 20.0    # % — universal default layer (§3)
    min_power::Float64 = 0.0     # % — DSP/corner power (§3); shown for filled
    passes::Float64 = 1.0        # Number of Passes (§4) / Pass Count (§5.3)
    interval::Float64 = 0.100    # Line Interval default .100 (§5.3)
    scan_angle::Float64 = 0.0    # ° — scans at the given angle (§5.3)
    kerf::Float64 = 0.0          # Kerf Offset in mm (§4: + outside, − inside)
end

"""
    Process(; mode, settings)

One layer's process assignment: how the laser treats the layer's geometry
(`mode`) and with which parameters (`settings`).
"""
Base.@kwdef struct Process
    mode::Symbol = :line         # one of `MODES`
    settings::CutSettings = CutSettings()
end

"""
    quick_cuts(process) -> String

The Cuts/Layers panel's abbreviated per-row settings block (§5.2 `Spd/Pwr`):
Speed and Max Power shown in one column.
"""
quick_cuts(p::Process) = string(round(Int, p.settings.speed), " / ",
                                round(Int, p.settings.max_power), "%")

"""
    document_layers(arts) -> Vector{Int}

The palette layers present in the document — every layer with at least one
piece of geometry gets an entry in the Cuts/Layers panel (§5.1); tool layers
have no cut parameters and never appear.
"""
function document_layers(arts::AbstractVector{ArtObject})
    layers = Int[]
    for art in arts
        is_tool_layer(art.layer) && continue
        art.layer in layers || push!(layers, art.layer)
    end
    return sort!(layers)
end

"The process a layer runs: the stored one, or `mode`'s default when the
layer has no entry yet."
process_for(processes::AbstractDict, layer::Int; mode = :line) =
    get(processes, layer, Process(mode = mode))

"Store `process` for `layer`, returning a new dictionary (immutable style:
callers copy the document's dicts before writing like the doc helpers do)."
function with_process(processes::AbstractDict, layer::Int, process::Process)
    d = typeof(processes)(processes)
    d[layer] = process
    return d
end
