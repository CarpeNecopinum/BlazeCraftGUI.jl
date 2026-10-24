#!/usr/bin/env julia
# BlazeCraft GUI — run the app. Usage:
#
#   julia --project=. examples/blazecraft.jl
#
# Headless verification (used by the analysis notes):
#
#   SDL_VIDEO_DRIVER=dummy ROCKS_SCREENSHOT=out.png julia --project=. examples/blazecraft.jl
#
import BlazeCraftGUI

function main()
    if haskey(ENV, "ROCKS_SCREENSHOT")
        # Headless run: two frames, then screenshot and quit.
        BlazeCraftGUI.run_gui(frames = 2, screenshot = ENV["ROCKS_SCREENSHOT"])
    else
        BlazeCraftGUI.run_gui()
    end
end

main()
