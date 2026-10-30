using Test
using BlazeCraftGUI
import Rocks
using BlazeCraftGUI: fit_camera, matrix, apply, zoom_at, pan, Camera,
                    doc_summary, document_bounds, center_on_workarea,
                    translate, scale, rotate, hit_shape,
                    layer_color, ArtObject
using BlazeCraft.Shapes: PolyLine, Point
using StaticArrays: SVector
using StaticArrays: SVector

@testset "document model" begin
    @testset "import_art: svg" begin
        art = only(import_art(joinpath(@__DIR__, "assets", "shapes.svg")))
        @test art.name == "shapes.svg"
        # SVG carries no layer information: everything on the default layer.
        @test art.layer == 0
        @test length(art.paths) == 3
        # Coordinates are millimetres, y-up (importer flips SVG's y-down).
        ys = [p[2] for pl in art.paths for p in pl.points]
        @test maximum(ys) <= 0  # the file sits below the origin after the flip
    end

    @testset "import_art: dxf layers split" begin
        arts = import_art(joinpath(@__DIR__, "..", "example.dxf"))
        @test length(arts) >= 2
        # One palette layer per DXF source layer, assigned in sorted name
        # order (`00` on), named "file/layer".
        @test [a.layer for a in arts] == collect(0:length(arts) - 1)
        @test all(a -> occursin('/', a.name), arts)
    end

    @testset "import_art: errors" begin
        @test_throws ErrorException import_art("/nonexistent/file.svg")
        @test_throws ErrorException import_art(joinpath(@__DIR__, "runtests.jl"))
    end

    @testset "document_bounds" begin
        @test document_bounds(ArtObject[]) === nothing
        art = only(import_art(joinpath(@__DIR__, "assets", "shapes.svg")))
        b = document_bounds([art])
        @test b !== nothing
        (pmin, pmax) = b
        @test pmin[1] < pmax[1] && pmin[2] < pmax[2]
    end

    @testset "layer_color" begin
        # LightBurn palette: 00 black, 01 blue, 02 red (analysis/02 §4.1).
        @test layer_color(0) == (0.0, 0.0, 0.0)
        @test layer_color(1) == (0.0, 0.0, 1.0)
        @test layer_color(2) == (1.0, 0.0, 0.0)
        @test layer_color(99) == (0.0, 0.0, 0.0)
    end

    @testset "doc_summary" begin
        @test occursin("File", doc_summary(ArtObject[]))
        art = only(import_art(joinpath(@__DIR__, "assets", "shapes.svg")))
        @test doc_summary([art]) == "shapes.svg: 3 outlines"
    end

    @testset "center_on_workarea" begin
        @testset "single object centers its bounds on the work area" begin
            art = only(import_art(joinpath(@__DIR__, "assets", "shapes.svg")))
            (pmin, pmax) = document_bounds([art])
            before_w = pmax[1] - pmin[1]
            before_h = pmax[2] - pmin[2]
            centered = center_on_workarea([art])
            (pmin, pmax) = document_bounds(centered)
            # The union center sits on the work-area center (150, 150).
            @test (pmin[1] + pmax[1]) / 2 ≈ 150.0
            @test (pmin[2] + pmax[2]) / 2 ≈ 150.0
            # The geometry is only translated, not scaled.
            @test pmax[1] - pmin[1] ≈ before_w
            @test pmax[2] - pmin[2] ≈ before_h
        end

        @testset "multiple objects center together, keeping relative positions" begin
            box = ArtObject("box", [PolyLine([Point(0.0, 0.0), Point(40.0, 0.0),
                                              Point(40.0, 20.0), Point(0.0, 20.0)],
                                             true)], 0)
            tri = ArtObject("tri", [PolyLine([Point(60.0, 30.0), Point(80.0, 30.0),
                                              Point(70.0, 50.0)], false)], 0)
            gap_before = 60.0 - 40.0   # x distance between the two bounds
            centered = center_on_workarea([box, tri])
            (pmin, pmax) = document_bounds(centered)
            # The union center is the work-area center...
            @test (pmin[1] + pmax[1]) / 2 ≈ 150.0
            @test (pmin[2] + pmax[2]) / 2 ≈ 150.0
            # ...and the two objects kept their relative placement.
            box_bounds = document_bounds([centered[1]])
            tri_bounds = document_bounds([centered[2]])
            gap_after = tri_bounds[1][1] - box_bounds[2][1]
            @test gap_after ≈ gap_before
        end

        @testset "empty list is unchanged" begin
            @test center_on_workarea(ArtObject[]) == ArtObject[]
        end
    end
end

@testset "editing helpers" begin
    art = ArtObject("s", [PolyLine([Point(0.0, 0.0), Point(10.0, 0.0)], false)],
                    0)
    # translate moves every point
    moved = translate(art, 5.0, -2.0)
    @test moved.paths[1].points == [Point(5.0, -2.0), Point(15.0, -2.0)]
    # scale about an anchor keeps the anchor fixed
    scaled = scale(art, 2.0, 2.0, Point(0.0, 0.0))
    @test scaled.paths[1].points == [Point(0.0, 0.0), Point(20.0, 0.0)]
    scaled2 = scale(art, 2.0, 2.0, Point(10.0, 0.0))
    # The anchor (10, 0) stays fixed; the other point stretches away.
    @test scaled2.paths[1].points == [Point(-10.0, 0.0), Point(10.0, 0.0)]
    # rotate by 90° about (0,0) maps +x to +y
    rotated = rotate(art, π / 2, Point(0.0, 0.0))
    @test rotated.paths[1].points[2][1] ≈ 0.0 atol = 1e-12
    @test rotated.paths[1].points[2][2] ≈ 10.0 atol = 1e-12
end

@testset "hit_shape" begin
    box = ArtObject("box", [PolyLine([Point(10.0, 10.0), Point(50.0, 10.0),
                                      Point(50.0, 50.0), Point(10.0, 50.0)],
                                     true)], 0)
    tri = ArtObject("tri", [PolyLine([Point(200.0, 200.0), Point(240.0, 200.0),
                                      Point(220.0, 240.0)], true)], 0)
    m = matrix(Camera((0.0, 0.0), 0.0, 2.0))
    # 2 px/mm: world (220, 200) is canvas (440, -400)
    @test hit_shape(m, [box, tri], 440.0, -400.0, 4.0) == 2
    @test hit_shape(m, [box, tri], 30.0, -20.0, 4.0) == 1
    @test hit_shape(m, [box, tri], 150.0, -150.0, 4.0) === nothing
end

@testset "camera" begin
    @testset "matrix: identity-like camera maps world to screen" begin
        m = matrix(Camera((10.0, 20.0), 0.0, 2.0))
        @test apply(m, Point(0.0, 0.0)) == (10.0, 20.0)
        @test apply(m, Point(5.0, 3.0)) == (20.0, 14.0)   # y-flip baked in
    end

    @testset "matrix: 90° rotation" begin
        m = matrix(Camera((0.0, 0.0), π / 2, 1.0))
        x, y = apply(m, Point(10.0, 0.0))
        @test isapprox(x, 0.0; atol = 1e-12) && y ≈ -10.0   # +x (y-up) → -y
    end

    @testset "zoom_at keeps the world point under the cursor" begin
        cam = Camera((40.0, 210.0), 0.0, 4.0)
        x, y = 300.0, 200.0
        w_before = inv(matrix(cam)) * SVector(x, y, 1.0)
        cam2 = zoom_at(cam, x, y, 2.0)
        @test cam2.scale ≈ 8.0
        w_after = inv(matrix(cam2)) * SVector(x, y, 1.0)
        @test w_after[1] ≈ w_before[1] && w_after[2] ≈ w_before[2]
    end

    @testset "pan moves the translation" begin
        cam = Camera((40.0, 210.0), 0.0, 4.0)
        cam2 = pan(cam, 15.0, -10.0)
        @test cam2.translation == SVector(55.0, 200.0)
        @test cam2.scale == 4.0 && cam2.rotation == 0.0
    end
end

@testset "workspace math" begin
    @testset "fit_camera: empty document fits the work area" begin
        cam = fit_camera(720, 500, ArtObject[])
        # The 300×300 mm work area fits within (720-48, 500-48) px.
        @test cam.scale ≈ (500 - 48) / 300  # height-limited
        # The work-area center (150, 150) maps to the canvas center.
        lx, ly = apply(matrix(cam), Point(150.0, 150.0))
        @test lx ≈ 360.0 && ly ≈ 250.0
    end

    @testset "fit_camera: small content keeps the work area visible" begin
        pl = PolyLine([Point(0.0, 0.0), Point(100.0, 0.0), Point(100.0, 50.0),
                       Point(0.0, 50.0)], true)
        art = ArtObject("box", [pl], 0)
        cam = fit_camera(720, 500, [art])
        # The union of the bed and the 100×50 box is the bed itself.
        @test cam.scale ≈ (500 - 48) / 300
        # The whole box is inside the canvas.
        for p in pl.points
            x, y = apply(matrix(cam), p)
            @test 0 <= x <= 720 && 0 <= y <= 500
        end
    end

    @testset "fit_camera: oversized content zooms out past the work area" begin
        pl = PolyLine([Point(0.0, 0.0), Point(600.0, 0.0), Point(600.0, 50.0),
                       Point(0.0, 50.0)], true)
        art = ArtObject("wide", [pl], 0)
        cam = fit_camera(720, 500, [art])
        # The union of the bed (300×300) and the 600 mm wide box is
        # 600×300 mm, width-limited.
        @test cam.scale ≈ (720 - 48) / 600
        for p in pl.points
            x, y = apply(matrix(cam), p)
            @test 0 <= x <= 720 && 0 <= y <= 500
        end
        # The bed's far corner is inside the canvas, too.
        x, y = apply(matrix(cam), Point(300.0, 300.0))
        @test 0 <= x <= 720 && 0 <= y <= 500
    end
end

@testset "even-odd fill (fills.jl)" begin
    sqring(a, b, c, d) = [(a, b), (c, b), (c, d), (a, d)]
    rows = 0:49

    # A single square: one run spanning it inside, nothing outside.
    runs = even_odd_runs([sqring(10.0, 10.0, 40.0, 40.0)], rows)
    @test length(runs) == length(rows)
    @test isempty(runs[1])                      # scan centre y = 0.5
    @test isempty(runs[50])                     # scan centre y = 49.5
    inner = runs[31]                            # scan centre y = 30.5
    @test length(inner) == 1
    @test inner[1][1] ≈ 10.0 && inner[1][2] ≈ 40.0

    # Two overlapping squares: the shared area erases (§3 same-layer
    # semantics) — the overlap split reads as two disjoint runs.
    runs = even_odd_runs([sqring(10.0, 10.0, 40.0, 40.0),
                          sqring(25.0, 10.0, 55.0, 40.0)], rows)
    mid = runs[31]
    @test length(mid) == 2
    @test mid[1][1] ≈ 10.0 && mid[1][2] ≈ 25.0
    @test mid[2][1] ≈ 40.0 && mid[2][2] ≈ 55.0

    # A hole: nested rings — the interior of the inner one stays empty.
    ringrows = 0:99
    runs = even_odd_runs([sqring(0.0, 0.0, 100.0, 100.0),
                          sqring(40.0, 30.0, 60.0, 70.0)], ringrows)
    center = runs[41]                           # scan centre y = 40.5
    @test length(center) == 2                   # crossed the hole, not through
    # A row below the hole is one solid run again.
    @test runs[21][1][1] ≈ 0.0 && runs[21][1][2] ≈ 100.0

    # Painting: the runs mark exactly the even-odd interior pixels.
    pixels = zeros(UInt32, 110 * 100)
    paint_even_odd!(pixels, runs, 110; rows = ringrows, color = (1.0, 0.0, 0.0))
    red = (UInt32(255) << 24) | UInt32(255) << 16
    @test pixels[40 * 110 + 12] == red          # x=11: inside the outer ring
    @test pixels[40 * 110 + 51] == 0x00000000   # x=50: inside the hole
    @test pixels[40 * 110 + 106] == 0x00000000  # x=105: right of the ring
    @test pixels[40 * 110 + 71] == red          # x=70: right of the hole
end

using Rocks: Observable

@testset "position toolbar" begin
    pl = PolyLine([Point(10.0, 10.0), Point(60.0, 10.0), Point(60.0, 40.0),
                   Point(10.0, 40.0)], true)
    art = ArtObject("box", [pl], 0)

    "Collect the pressable fibers of the subtree rooted at `f`."
    function pressables(f, out = Rocks.Fiber[])
        f.kind === Rocks.Pressable && push!(out, f)
        foreach(c -> pressables(c, out), f.children)
        out
    end

    "Render the toolbar with `sel_mm`; run `f` on the tree."
    function with_toolbar(f, selection)
        doc = Observable([art])
        app = () -> (Rocks.@rock PositionToolbar(
            doc = doc, selection = selection,
            origin = Observable((2, 2)), lock = Observable(false)))
        Rocks.RUNNING[] = true
        Rocks.DIRTY[] = true
        Rocks.init_backend()
        tree = Rocks.create_root(app, (;))
        Rocks.perform_render!(tree)
        Rocks.run_effects!()
        Rocks.flush_dirty!()
        try
            f(tree)
        finally
            Rocks.RUNNING[] = false
            Rocks.unmount!(tree)
            Rocks.shutdown_backend()
        end
    end

    @testset "nothing selected: inputs disabled" begin
        with_toolbar(Observable(Int[])) do tree
            ps = pressables(tree)
            # The spinner fields drop their keyboard-handler props, so no
            # pressable handles text input.
            fields = filter(p -> haskey(p.props, :on_text_input), ps)
            @test isempty(fields)
            # Editing input does nothing: apply writes are guarded too — the
            # spinner arrows must be no-ops.
            disabled = filter(p -> get(p.props, :disabled, false), ps)
            @test length(disabled) >= 4
        end
    end

    @testset "selection present: inputs enabled and synced" begin
        with_toolbar(Observable([1])) do tree
            ps = pressables(tree)
            fields = filter(p -> haskey(p.props, :on_text_input), ps)
            @test length(fields) == 4
            # No grayed out arrows with a live selection.
            @test !any(p -> get(p.props, :disabled, false), ps)
        end
    end
end

@testset "layers & layer bar" begin
    pl = PolyLine([Point(0.0, 0.0), Point(40.0, 0.0), Point(40.0, 20.0),
                   Point(0.0, 20.0)], true)

    @testset "palette" begin
        # 30 cut layers + the two tool layers, exact palette colours.
        @test layer_label(0) == "00" && layer_label(29) == "29"
        @test layer_label(30) == "T1" && layer_label(31) == "T2"
        @test is_tool_layer(30) && is_tool_layer(31)
        @test !is_tool_layer(0)
        # Layer `04` is rgb(208,208,0) — the analysis table's exact value.
        @test all(layer_color(4) .≈ (208 / 255, 208 / 255, 0.0))
        @test all(haskey(LAYER_COLORS_HEX, l) for l in 0:(CUT_LAYERS + 1))
    end

    @testset "set_layer" begin
        arts = [ArtObject("a", [pl], 0), ArtObject("b", [pl], 2)]
        assigned = set_layer(arts, 5)
        @test all(a -> a.layer == 5, assigned)
        @test [a.layer for a in arts] == [0, 2]   # the source list untouched
        # Geometry is shared, not copied: an alias of the paths.
        @test assigned[1].paths === arts[1].paths
    end

    @testset "layer bar: click behaviour" begin
        doc = Observable([ArtObject("a", [pl], 0)])
        selection = Observable(Int[])
        active = Observable(0)
        app = () -> (Rocks.@rock LayerBar(doc = doc, selection = selection,
                                          active_layer = active))
        Rocks.RUNNING[] = true
        Rocks.DIRTY[] = true
        Rocks.init_backend()
        tree = Rocks.create_root(app, (;))
        Rocks.perform_render!(tree)
        Rocks.run_effects!()
        Rocks.flush_dirty!()
        try
            # The chips, in palette order: 16×16 pressables with handlers.
            chip_pressables(f, out = Rocks.Fiber[]) = begin
                f.kind === Rocks.Pressable && push!(out, f)
                foreach(c -> chip_pressables(c, out), f.children)
                out
            end
            chips = [f for f in chip_pressables(tree)
                     if get(f.props, :width, 0) == 16 &&
                        get(f.props, :height, 0) == 16]
            @test length(chips) == CUT_LAYERS + 2
            # Nothing selected: the click only sets the colour for newly
            # created shapes; the document is untouched.
            chips[6].props[:on_press]()     # layer `05`
            @test active[] == 5
            @test doc[][1].layer == 0
            # With a selection: the objects are recoloured — and the click
            # also updates the active colour.
            selection[] = [1]
            Rocks.flush_dirty!(); Rocks.run_effects!()
            chips[3].props[:on_press]()     # layer `02` on the selection
            @test doc[][1].layer == 2
            @test active[] == 2
            # Multi-select: every layer holding selected shapes lights its
            # chip (the selection border); the others stay dim.
            doc[] = [ArtObject("a", [pl], 0), ArtObject("b", [pl], 2)]
            selection[] = [1, 2]
            Rocks.flush_dirty!(); Rocks.run_effects!()
            sel_color = Rocks.Enterprise.light_theme().colors.selection
            lit = [c for c in chips
                   if get(c.props, :border_color, nothing) == sel_color]
            @test length(lit) == 2
            # Syncs back into the spinner-free toolbar: the chip's border
            # highlight flips with `active`.
            Rocks.flush_dirty!(); Rocks.run_effects!()
        finally
            Rocks.RUNNING[] = false
            Rocks.unmount!(tree)
            Rocks.shutdown_backend()
        end
    end
end

@testset "cut processes" begin
    pl = PolyLine([Point(0.0, 0.0), Point(40.0, 0.0), Point(40.0, 20.0),
                   Point(0.0, 20.0)], true)

    @testset "process model" begin
        # The three vector modes; Image mode has no use in a vector-only v1.
        @test MODES == (:line, :fill, :offset_fill)
        @test mode_label(:line) == "Line"
        @test mode_label(:fill) == "Fill"
        @test mode_label(:offset_fill) == "Offset Fill"
        # Universal defaults (§3): 6000 mm/min, 20% power, a single pass.
        p = Process()
        @test p.mode == :line
        s = p.settings
        @test s.speed == 6000.0 && s.max_power == 20.0
        @test s.passes == 1.0 && s.interval == 0.1
        @test s.scan_angle == 0.0 && s.kerf == 0.0
        # Abbreviated Cuts/Layers readout: whole numbers, `%` on the power.
        @test quick_cuts(p) == "6000 / 20%"
        p2 = Process(mode = :fill,
                     settings = CutSettings(speed = 3000.0, max_power = 40.0))
        @test quick_cuts(p2) == "3000 / 40%"
    end

    @testset "document_layers" begin
        arts = [ArtObject("a", [pl], 0), ArtObject("b", [pl], 3),
                ArtObject("c", [pl], 0)]
        # Every layer with at least one object, sorted, duplicates collapsed.
        @test document_layers(arts) == [0, 3]
        # Tool layers have no cut parameters and never get an entry.
        @test document_layers([ArtObject("t", [pl], 30)]) == Int[]
        @test document_layers(ArtObject[]) == Int[]
    end

    @testset "process_for / with_process" begin
        procs = Dict{Int,Process}()
        # A layer with no stored process runs its mode's default.
        @test process_for(procs, 2).mode == :line
        # Storing is immutable-style: the source dict is untouched.
        stored = with_process(procs, 2, Process(mode = :fill))
        @test process_for(stored, 2).mode == :fill
        @test process_for(stored, 3).mode == :line
        @test haskey(stored, 2)
        @test procs == Dict{Int,Process}()
    end

    @testset "cuts panel" begin
        doc = Observable([ArtObject("a", [pl], 0), ArtObject("b", [pl], 2)])
        processes = Observable(Dict{Int,Process}())
        editor_open = Observable(false)
        edit_layer = Observable(0)
        bar = () -> (Rocks.@rock CutsLayersPanel(
            doc = doc, processes = processes,
            editor_open = editor_open, edit_layer = edit_layer))
        Rocks.RUNNING[] = true
        Rocks.DIRTY[] = true
        Rocks.init_backend()
        tree = Rocks.create_root(bar, (;))
        Rocks.perform_render!(tree)
        Rocks.run_effects!()
        Rocks.flush_dirty!()
        try
            pressables = Rocks.Fiber[]
            collect_press(f) = begin
                f.kind === Rocks.Pressable && push!(pressables, f)
                foreach(collect_press, f.children)
            end
            collect_press(tree)
            # One row per layer with geometry.
            @test length(pressables) == 2
            # Rows all carry the double-press opener.
            @test all(p -> haskey(p.props, :on_double_press), pressables)
            # Double-clicking an entry opens the editor for that layer.
            pressables[2].props[:on_double_press]()
            @test edit_layer[] == 2
            @test editor_open[] == true
        finally
            Rocks.RUNNING[] = false
            Rocks.unmount!(tree)
            Rocks.shutdown_backend()
        end
    end

    @testset "process editor" begin
        processes = Observable(Dict{Int,Process}())
        open = Observable(true)
        layer = Observable(1)
        ed = () -> (Rocks.@rock ProcessEditor(open = open, layer = layer,
                                              processes = processes))
        Rocks.RUNNING[] = true
        Rocks.DIRTY[] = true
        Rocks.init_backend()
        tree = Rocks.create_root(ed, (;))
        Rocks.perform_render!(tree)
        Rocks.run_effects!()
        Rocks.flush_dirty!()
        # A mechanics Button is a pressable whose label is a child `Text`
        # carrying the name as its rendered string (the fiber's child holds
        # the label value).
        function find_button(f, name)
            f.kind === Rocks.Text &&
                any(==(name), string.(get(f.props, :children, ()))) &&
                return f.parent
            for c in f.children
                hit = find_button(c, name)
                hit === nothing || return hit
            end
            return nothing
        end
        try
            # A closed editor renders nothing and mints no window.
            open[] = false
            Rocks.flush_dirty!()
            closed = Rocks.collect_windows!(Rocks.Fiber[], tree)
            @test isempty(closed)
            open[] = true
            Rocks.flush_dirty!()

            ok = find_button(tree, "OK")
            cancel = find_button(tree, "Cancel")
            @test ok !== nothing && cancel !== nothing
            # OK writes the layer's process (mode from effect sync: `line`,
            # the defaults).
            ok.props[:on_press]()
            @test open[] == false
            @test haskey(processes[], 1)
            @test processes[][1].mode == :line
            @test processes[][1].settings.speed == 6000.0
            # Cancel never writes.
            processes2 = Observable(Dict{Int,Process}())
            open2 = Observable(true)
            layer2 = Observable(1)
            tree2 = Rocks.create_root(() -> (Rocks.@rock ProcessEditor(
                open = open2, layer = layer2, processes = processes2)), (;))
            Rocks.perform_render!(tree2)
            Rocks.run_effects!()
            Rocks.flush_dirty!()
            cancel2 = find_button(tree2, "Cancel")
            cancel2.props[:on_press]()
            @test open2[] == false
            @test processes2[] == Dict{Int,Process}()
            Rocks.unmount!(tree2)

            # Only the mode-relevant parameters get slots: a Fill process
            # shows Interval/Scan angle and no Kerf; a Line process the
            # reverse.
            labels(f, acc = String[]) = begin
                f.kind === Rocks.Text &&
                    append!(acc, string.(get(f.props, :children, ())))
                foreach(c -> labels(c, acc), f.children)
                acc
            end
            for (mode, want, absent) in
                ((:fill, ["Interval", "Scan angle"], ["Kerf"]),
                 (:line, ["Kerf"], ["Interval", "Scan angle"]))
                procs3 = Observable(Dict{Int,Process}(1 => Process(mode = mode)))
                open3 = Observable(true)
                tree3 = Rocks.create_root(() -> (Rocks.@rock ProcessEditor(
                    open = open3, layer = Observable(1),
                    processes = procs3)), (;))
                Rocks.perform_render!(tree3)
                Rocks.run_effects!()
                Rocks.flush_dirty!()
                names = labels(tree3)
                @test all(w -> w in names, want)
                @test all(a -> a ∉ names, absent)
                Rocks.unmount!(tree3)
            end
        finally
            Rocks.RUNNING[] = false
            Rocks.unmount!(tree)
            Rocks.shutdown_backend()
        end
    end
end

@testset "rectangle tool and editor click-through" begin
    # The full user path through the real event pipeline (Rocks src/driver.jl):
    # pick the rectangle tool, drag a rectangle on the workspace, then
    # double-press the process row that appears. The editor opens as its own
    # window and the main window's layout stays intact — a mounted window
    # must not join the flow (it used to squish the workspace).
    import SDL3
    doc = Observable(ArtObject[])
    selection = Observable(Int[])
    processes = Observable(Dict{Int,Process}())
    tool = Observable(:mouse)
    active_layer = Observable(0)

    Rocks.with_tree(() -> App(doc = doc, selection = selection,
                              processes = processes, tool = tool,
                              active_layer = active_layer)) do root
        windows = Rocks.sync_windows!(root)
        @test length(windows) == 1
        main = windows[1]
        Rocks.draw_window!(main)             # the first draw applies the view fit

        # 1. Pick the rectangle tool: the strip button carrying the
        # `rectangle` MDI glyph (tests address it by the glyph char via the
        # `icon` prop that `Icon` carries).
        tool_button(glyph) = Rocks.find_fiber(main) do f
            f.kind === Rocks.Pressable &&
                any(k -> get(k.props, :icon, nothing) == glyph, Rocks.fibers(f))
        end
        rect_btn = tool_button(BlazeCraftGUI.MDI_GLYPHS["rectangle"])
        @test rect_btn !== nothing
        Rocks.click!(rect_btn)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test tool[] == :rect

        # 2. Drag a rectangle: press at world (100, 100), drag to (200, 160).
        canvas = Rocks.find_kind(main, Rocks.Canvas)
        @test canvas !== nothing
        cam = fit_camera(canvas.rect[3], canvas.rect[4], doc[])
        pt(p) = begin
            s = apply(matrix(cam), p)
            (round(Int, canvas.rect[1] + s[1]),
             round(Int, canvas.rect[2] + s[2]))
        end
        a, b = pt(SVector(100.0, 100.0)), pt(SVector(200.0, 160.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, a...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_MOTION, b...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, b...)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test length(doc[]) == 1
        @test doc[][1].name == "rectangle"
        @test doc[][1].layer == 0
        @test selection[] == [1]
        # The created rectangle spans the dragged corners (world mm, y-up);
        # the drag lands on pixel centres, so allow the rounding slack.
        bounds = document_bounds(doc[])
        @test isapprox(bounds[1][1], 100.0; atol = 0.5)
        @test isapprox(bounds[1][2], 100.0; atol = 0.5)
        @test isapprox(bounds[2][1], 200.0; atol = 0.5)
        @test isapprox(bounds[2][2], 160.0; atol = 0.5)

        # 3. Multi-select: a second rectangle on layer 02 (the active
        # colour), then switch to the select tool and Shift+click the first —
        # the selection spans both layers and both layer chips light up.
        active_layer[] = 2
        a2, b2 = pt(SVector(40.0, 190.0)), pt(SVector(140.0, 240.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, a2...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_MOTION, b2...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, b2...)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test length(doc[]) == 2
        @test doc[][2].layer == 2
        @test selection[] == [2]

        select_btn = tool_button(BlazeCraftGUI.MDI_GLYPHS["select"])
        @test select_btn !== nothing
        Rocks.click!(select_btn)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test tool[] == :mouse
        # Shift+click on the first rectangle's top edge adds it.
        Rocks.LAST_KEYMODS[] = 0x0001            # Shift held
        c1 = pt(SVector(150.0, 100.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, c1...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, c1...)
        Rocks.drain_events!()
        Rocks.LAST_KEYMODS[] = 0x0000
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [1, 2]
        # Every layer holding selected shapes lights its chip; exactly two
        # of the 32 palette chips are lit.
        sel_color = Rocks.Enterprise.light_theme().colors.selection
        lit = [f for f in Rocks.fibers(main)
               if f.kind === Rocks.Pressable && get(f.props, :width, 0) == 16 &&
                  get(f.props, :height, 0) == 16 &&
                  get(f.props, :border_color, nothing) == sel_color]
        @test length(lit) == 2

        # 4. Escape resets the tool to the mouse; Delete removes every
        # selected shape.
        Rocks.click!(rect_btn)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test tool[] == :rect
        Rocks.push_key!(main, SDL3.SDLK_ESCAPE)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test tool[] == :mouse
        Rocks.push_key!(main, SDL3.SDLK_DELETE)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test isempty(doc[])
        @test isempty(selection[])

        # 5. Draw again (the view refits on the now-empty document) and open
        # the editor: the process row shows up on layer 00; double-pressing
        # it opens the editor as its own window. The doc change re-laid-out
        # the panel — sync first, or the fresh row has no placed rect and
        # the click would land at the window origin (the menu bar).
        active_layer[] = 0
        Rocks.click!(rect_btn)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test tool[] == :rect
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing,
                                 windows)]
        Rocks.draw_window!(main)                 # applies the refit
        canvas = Rocks.find_kind(main, Rocks.Canvas)
        cam = fit_camera(canvas.rect[3], canvas.rect[4], doc[])
        a, b = pt(SVector(100.0, 100.0)), pt(SVector(200.0, 160.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, a...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_MOTION, b...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, b...)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test length(doc[]) == 1
        split = Rocks.find_kind(main, Rocks.Split)
        @test split !== nothing
        split_h = split.rect[4]
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing,
                                 windows)]
        row = Rocks.find_fiber(main) do f
            f.kind === Rocks.Pressable &&
                Rocks.find_by_label(f, "00") !== nothing
        end
        @test row !== nothing
        @test row.rect[3] > 0 && row.rect[4] > 0
        Rocks.click!(row; clicks = 2)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        windows = Rocks.sync_windows!(root)
        @test length(windows) == 2           # the editor is its own window
        main = windows[findfirst(w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing,
                                 windows)]
        editor = windows[findfirst(w -> Rocks.find_kind(w, Rocks.Canvas) === nothing,
                                   windows)]
        @test Bool(get(editor.props, :fit_content, false))
        # The workspace split is exactly as tall as before (no squish).
        @test Rocks.find_kind(main, Rocks.Split).rect[4] == split_h
    end
end
