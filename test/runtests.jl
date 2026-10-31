using Test
using BlazeCraftGUI
import Rocks
using BlazeCraftGUI: fit_camera, matrix, apply, zoom_at, pan, Camera,
                    doc_summary, document_bounds, center_on_workarea,
                    translate, scale, rotate, hit_shape,
                    selection_handles, selection_union_bbox, shapes_in_rect,
                    layer_color, ArtObject
using BlazeCraft.Shapes: PolyLine, Point
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
        # Shift+click on the first rectangle's top edge adds it. The mods
        # ride on the click itself (dispatch refreshes them from SDL, so
        # only a Shift held right now multi-selects).
        c1 = pt(SVector(150.0, 100.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                          c1...; mod = 0x0001)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, c1...)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [1, 2]
        # The Shift is long gone: a plain click must select just the
        # clicked shape again (the stale-mods bug kept multi-selecting).
        c2 = pt(SVector(40.0, 215.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, c2...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, c2...)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [2]
        # Shift+click the first rectangle again: back to the multi-selection
        # for the delete step below.
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                          c1...; mod = 0x0001)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, c1...)
        Rocks.drain_events!()
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

@testset "camera pan with the middle button" begin
    # The camera moves with a middle-button drag (a gripping hand while
    # grabbed); hovering keeps the plain arrow, and left/right clicks stay
    # selection-only.
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
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        Rocks.draw_window!(main)             # fit the (empty) view

        # Hovering the workspace must not change the cursor: the surface
        # asks for the plain arrow (`:pan` — only grabbing changes it).
        area = Rocks.find_fiber(main) do f
            f.kind === Rocks.Pressable &&
                haskey(f.props, :on_wheel) && haskey(f.props, :on_down) &&
                haskey(f.props, :on_move)
        end
        @test area !== nothing
        @test get(area.props, :cursor, nothing) === :pan

        canvas = Rocks.find_kind(main, Rocks.Canvas)
        @test canvas !== nothing
        cam = fit_camera(canvas.rect[3], canvas.rect[4], doc[])
        pt(p) = begin
            s = apply(matrix(cam), p)
            (round(Int, canvas.rect[1] + s[1]),
             round(Int, canvas.rect[2] + s[2]))
        end

        # Draw a rectangle with the creation tool (left drag; the active
        # view was fit to the empty document, so `pt` keeps matching).
        rect_btn = Rocks.find_fiber(main) do f
            f.kind === Rocks.Pressable &&
                any(k -> get(k.props, :icon, nothing) ==
                            BlazeCraftGUI.MDI_GLYPHS["rectangle"],
                    Rocks.fibers(f))
        end
        @test rect_btn !== nothing
        Rocks.click!(rect_btn)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test tool[] == :rect
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
        @test selection[] == [1]

        # The drag ends with the button that started it: a stray
        # right-button press/release during the left drag must not cut the
        # rectangle creation short.
        @test tool[] == :rect                # creation tools stay active
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        canvas = Rocks.find_kind(main, Rocks.Canvas)
        a, b = pt(SVector(110.0, 110.0)), pt(SVector(210.0, 170.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, a...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_MOTION, b...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, b...;
                          button = 3)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, b...;
                          button = 3)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, b...)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test length(doc[]) == 2             # the rect still committed

        # Switch back to the select tool (creation tools stay active).
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        select_btn = Rocks.find_fiber(main) do f
            f.kind === Rocks.Pressable &&
                any(k -> get(k.props, :icon, nothing) ==
                            BlazeCraftGUI.MDI_GLYPHS["select"],
                    Rocks.fibers(f))
        end
        @test select_btn !== nothing
        Rocks.click!(select_btn)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test tool[] == :mouse

        # A middle press is a grab, not a click: grab the camera over
        # empty space and drag it 120 px right, 90 px down — nothing is
        # selected and nothing is edited.
        pan0 = pt(SVector(250.0, 100.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                          pan0...; button = 2)
        Rocks.drain_events!()
        Rocks.push_motion!(canvas, pan0[1] + 120, pan0[2] + 90)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                          pan0[1] + 120, pan0[2] + 90; button = 2)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test length(doc[]) == 2             # panning never edits
        @test selection[] == [2]             # ...and never selects/clears

        # The shapes moved with the camera by exactly the drag distance:
        # the screen spot of world (210, 140) — on the second rectangle's
        # right edge — now selects it.
        spot = pt(SVector(210.0, 140.0))
        moved = (spot[1] + 120, spot[2] + 90)
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, moved...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, moved...)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [2]

        # The former screen spot of the same world point now misses (the
        # world point under it moved with the camera).
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, spot...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, spot...)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == Int[]

        # Drag the camera back: the original screen spot selects again.
        pan0 = pt(SVector(250.0, 100.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                          pan0...; button = 2)
        Rocks.drain_events!()
        Rocks.push_motion!(canvas, pan0[1] - 120, pan0[2] - 90)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                          pan0[1] - 120, pan0[2] - 90; button = 2)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, spot...)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, spot...)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [2]

        # A right press is no action: it must not clear the selection.
        blank = pt(SVector(250.0, 100.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                          blank...; button = 3)
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                          blank...; button = 3)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [2]
    end
end

# Marquee selection with the cursor tool: the drag on empty space selects
# what it covers — green (started at a right corner, overlap) or red
# (started at a left corner, fully contained); a click-shaped drag clears.
@testset "marquee selection with the cursor tool" begin
    import SDL3
    doc = Observable(ArtObject[])
    selection = Observable(Int[])
    processes = Observable(Dict{Int,Process}())
    tool = Observable(:mouse)
    active_layer = Observable(0)

    ring(x0, y0, x1, y1) = PolyLine([Point(x0, y0), Point(x1, y0),
                                     Point(x1, y1), Point(x0, y1)], true)
    doc[] = [ArtObject("a", [ring(100.0, 100.0, 200.0, 160.0)], 0),
             ArtObject("b", [ring(40.0, 190.0, 140.0, 240.0)], 2)]

    Rocks.with_tree(() -> App(doc = doc, selection = selection,
                              processes = processes, tool = tool,
                              active_layer = active_layer)) do root
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        Rocks.draw_window!(main)             # fit the refit to the now-only doc
        canvas = Rocks.find_kind(main, Rocks.Canvas)
        cam = fit_camera(canvas.rect[3], canvas.rect[4], doc[])
        pt(p) = begin
            s = apply(matrix(cam), p)
            (canvas.rect[1] + s[1], canvas.rect[2] + s[2])
        end
        drag(pt_from, pt_to) = begin
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                              Float32(pt_from[1]), Float32(pt_from[2]))
            Rocks.drain_events!()
            Rocks.push_motion!(canvas, pt_to[1], pt_to[2])
            Rocks.drain_events!()
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                              Float32(pt_to[1]), Float32(pt_to[2]))
            Rocks.drain_events!()
            Rocks.flush_dirty!()
            Rocks.run_effects!()
        end

        # No tool needed: the cursor tool is the default and the marquee
        # starts on empty space. Green marquee (dragged leftward, from the
        # bottom-right of its rect): selects everything overlapping — both.
        drag(pt(SVector(250.0, 260.0)), pt(SVector(60.0, 60.0)))
        @test selection[] == [1, 2]

        # Red marquee (dragged rightward, from the top-left): only shapes
        # entirely inside — the second rectangle, but not the clipped first.
        drag(pt(SVector(30.0, 180.0)), pt(SVector(170.0, 270.0)))
        @test selection[] == [2]

        # Red marquee over a part of both: nobody is fully inside, the
        # selection empties.
        drag(pt(SVector(90.0, 90.0)), pt(SVector(175.0, 175.0)))
        @test isempty(selection[])

        # A click without a drag (the hairline rect) clears, like any click
        # on empty space.
        selection[] = [1, 2]
        drag(pt(SVector(250.0, 260.0)), pt(SVector(250.0, 260.0)))
        @test isempty(selection[])
        drag(pt(SVector(250.0, 260.0)), pt(SVector(60.0, 60.0)))
        @test selection[] == [1, 2]          # re-set for the group frame test
    end
end

# The selection frame encloses the union of all selected shapes and its
# handles transform the group relative to the combined centre of bounds.
@testset "group selection frame and transforms" begin
    import SDL3
    doc = Observable(ArtObject[])
    selection = Observable(Int[])
    processes = Observable(Dict{Int,Process}())
    tool = Observable(:mouse)
    active_layer = Observable(0)

    ring(x0, y0, x1, y1) = PolyLine([Point(x0, y0), Point(x1, y0),
                                     Point(x1, y1), Point(x0, y1)], true)
    doc[] = [ArtObject("a", [ring(100.0, 100.0, 200.0, 160.0)], 0),
             ArtObject("b", [ring(40.0, 190.0, 140.0, 240.0)], 2)]

    Rocks.with_tree(() -> App(doc = doc, selection = selection,
                              processes = processes, tool = tool,
                              active_layer = active_layer)) do root
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        Rocks.draw_window!(main)
        canvas = Rocks.find_kind(main, Rocks.Canvas)
        cam = fit_camera(canvas.rect[3], canvas.rect[4], doc[])
        m = matrix(cam)
        pt(p) = begin
            s = apply(m, p)
            (canvas.rect[1] + s[1], canvas.rect[2] + s[2])
        end
        # Window-absolute screen px → world mm (handle positions are
        # canvas-local px; pushes need window coords).
        to_world(s) = begin
            w = inv(m) * SVector(s[1] - canvas.rect[1], s[2] - canvas.rect[2], 1.0)
            SVector(w[1], w[2])
        end
        scr(h) = (canvas.rect[1] + h[1], canvas.rect[2] + h[2])
        press_drag(press_at, move_to) = begin
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                              Float32(press_at[1]), Float32(press_at[2]))
            Rocks.drain_events!()
            Rocks.push_motion!(canvas, move_to[1], move_to[2])
            Rocks.drain_events!()
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                              Float32(move_to[1]), Float32(move_to[2]))
            Rocks.drain_events!()
            Rocks.flush_dirty!()
            Rocks.run_effects!()
        end

        # Select both with a green marquee.
        press_drag(pt(SVector(250.0, 260.0)), pt(SVector(60.0, 60.0)))
        @test selection[] == [1, 2]

        handles = selection_handles(
            selection_union_bbox(m, doc[], selection[]))
        # The frame centre sits over the union's world centre.
        centre = to_world(scr(handles.center))
        @test isapprox(centre[1], (40.0 + 200.0) / 2; atol = 0.5)
        @test isapprox(centre[2], (100.0 + 240.0) / 2; atol = 0.5)

        # Translate the group by its center handle: every selected shape
        # carries the same world delta, so relative positions survive.
        c = scr(handles.center)
        press_drag(c, (c[1] + 30, c[2] + 15))
        @test selection[] == [1, 2]          # the drag keeps the selection
        world_dx = (to_world((c[1] + 30, c[2] + 15)) - to_world(c))[1]
        world_dy = (to_world((c[1] + 30, c[2] + 15)) - to_world(c))[2]
        b1 = document_bounds(doc[])
        @test isapprox(b1[1][1], 40.0 + world_dx; atol = 0.6)
        @test isapprox(b1[2][1], 200.0 + world_dx; atol = 0.6)
        @test isapprox(b1[2][2], 240.0 + world_dy; atol = 0.6)
        # Relative positions survive: the two shapes keep their offset.
        off_x = document_bounds([doc[][2]])[1][1] -
                document_bounds([doc[][1]])[1][1]
        @test isapprox(off_x, 40.0 - 100.0; atol = 0.3)

        # Scale the group: corner 3 (bottom right of the union) drags, the
        # opposite union corner stays fixed, and both shapes scale about it
        # (so the group and each member shrink/grow by the same factors).
        ub = selection_union_bbox(m, doc[], selection[])
        handles = selection_handles(ub)
        p0 = scr(handles.corners[1])         # the fixed opposite corner
        p3 = scr(handles.corners[3])         # the dragged corner
        fixed = to_world(p0)
        cw0 = to_world(p3)
        cw1 = to_world((p3[1] + 60, p3[2] + 30))
        sx = (cw1[1] - fixed[1]) / (cw0[1] - fixed[1])
        sy = (cw1[2] - fixed[2]) / (cw0[2] - fixed[2])
        pre = document_bounds(doc[])
        press_drag(p3, (p3[1] + 60, p3[2] + 30))
        @test selection[] == [1, 2]                # the drag keeps the selection
        post = document_bounds(doc[])
        @test isapprox(post[1][1], fixed[1] + sx * (pre[1][1] - fixed[1]);
                       atol = 0.6)
        @test isapprox(post[2][1], fixed[1] + sx * (pre[2][1] - fixed[1]);
                       atol = 0.6)
        @test isapprox(post[1][2], fixed[2] + sy * (pre[1][2] - fixed[2]);
                       atol = 0.6)
        @test isapprox(post[2][2], fixed[2] + sy * (pre[2][2] - fixed[2]);
                       atol = 0.6)
    end
end

# Layout: the layer palette left the app's status bar — it is a strip
# directly below the workspace, as wide as the canvas, with the document
# summary staying alone on the window's bottom edge.
@testset "layer bar sits below the workspace" begin
    doc = Observable(ArtObject[])
    selection = Observable(Int[])
    processes = Observable(Dict{Int,Process}())
    tool = Observable(:mouse)
    active_layer = Observable(0)

    Rocks.with_tree(() -> App(doc = doc, selection = selection,
                              processes = processes, tool = tool,
                              active_layer = active_layer)) do root
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        Rocks.draw_window!(main)
        canvas = Rocks.find_kind(main, Rocks.Canvas)
        @test canvas !== nothing

        # The palette chips: every 16×16 pressable of the status-bar style.
        chips = [f for f in Rocks.fibers(main)
                 if f.kind === Rocks.Pressable &&
                 get(f.props, :width, 0) == 16 && get(f.props, :height, 0) == 16
                 && haskey(f.props, :on_press)]
        @test length(chips) == CUT_LAYERS + 2      # palette 00–29 + T1/T2
        cx0 = minimum(f.rect[1] for f in chips)
        cx1 = maximum(f.rect[1] + f.rect[3] for f in chips)
        cy0 = minimum(f.rect[2] for f in chips)
        cy1 = maximum(f.rect[2] + f.rect[4] for f in chips)
        # The strip sits between the canvas bottom and the document summary.
        status_text = Rocks.find_fiber(main) do f
            f.kind === Rocks.Text &&
                any(s -> s isa AbstractString &&
                          occursin("no design imported", s),
                    get(f.props, :children, ()))
        end
        @test status_text !== nothing
        # The strip sits between the canvas bottom and the document summary.
        @test cy0 >= canvas.rect[2] + canvas.rect[4]
        @test cy1 <= status_text.rect[2]
        # ...and spans the canvas horizontally (not the whole window — the
        # status bar region's summary stays separate).
        @test cx0 >= canvas.rect[1] - 2
        @test cx1 <= canvas.rect[1] + canvas.rect[3] + 2
    end
end

@testset "groups: document model" begin
    ring(x0, y0, x1, y1) = PolyLine([Point(x0, y0), Point(x1, y0),
                                     Point(x1, y1), Point(x0, y1)], true)
    a = ArtObject("a", [ring(100.0, 100.0, 200.0, 160.0)], 0)
    b = ArtObject("b", [ring(40.0, 190.0, 140.0, 240.0)], 2)
    c = ArtObject("c", [ring(220.0, 100.0, 260.0, 140.0)], 1)

    @testset "group_arts: members by id, appended last" begin
        d = group_arts([a, b, c], [1, 2])
        @test length(d) == 4
        g = d[4]
        @test is_group(g)
        @test g.name == "Group 1"
        @test g.children == UInt64[a.id, b.id]
        # The members keep their doc entries untouched.
        @test d[1].paths == a.paths && d[2].paths == b.paths
        # Nesting: a group joining a group (or a group + shape) nests.
        d2 = group_arts(d, [4, 3])
        @test length(d2) == 5
        outer = d2[5]
        @test is_group(outer) && outer.name == "Group 2"
        @test outer.children == UInt64[g.id, c.id]
    end

    @testset "resolve_leaves / parent_group / top_level_indices" begin
        d = group_arts([a, b, c], [1, 2])
        d2 = group_arts(d, [4, 3])
        # A group index expands into its whole subtree; shapes pass through.
        @test resolve_leaves(d2, [5]) == [1, 2, 3]
        @test resolve_leaves(d2, [1, 5]) == [1, 2, 3]
        # The parent group is the *outermost* ancestor: a/b sit in the inner
        # group, c in the outer one — both resolve up to the outer group;
        # the outer group itself is top level.
        @test parent_group(d2, 1) == 5
        @test parent_group(d2, 3) == 5
        @test parent_group(d2, 5) === nothing
        @test parent_group(d, 1) == 4          # a single-level group
        # Top-level entries: the outermost group only.
        @test top_level_indices(d2) == [5]
        @test top_level_indices(group_arts([a, b, c], [1, 2])) == [3, 4]
    end

    @testset "art_bounds: a group bounds its subtree" begin
        d = group_arts([a, b, c], [1, 2])
        @test art_bounds(d, 4) == ((Point(40.0, 100.0), Point(200.0, 240.0)))
        @test art_bounds(d, 1) == ((Point(100.0, 100.0), Point(200.0, 160.0)))
        @test art_bounds(d, 0) === nothing
    end

    @testset "marquee units: a group acts like a single shape" begin
        d = group_arts([a, b, c], [1, 2])
        # Green (overlap) touching one member's corner selects the group.
        @test shapes_in_rect(d, ((195.0, 155.0), (210.0, 170.0)),
                             :overlapping) == [4]
        # Red (contained) holding the whole group selects it.
        @test shapes_in_rect(d, ((30.0, 90.0), (210.0, 250.0)),
                             :contained) == [4]
        # Red over part of the group selects nothing of it.
        @test shapes_in_rect(d, ((90.0, 90.0), (150.0, 250.0)),
                             :contained) == Int[]
        # The ungrouped shape still selects alone.
        @test shapes_in_rect(d, ((215.0, 90.0), (270.0, 150.0)),
                             :overlapping) == [3]
    end

    @testset "ungroup_arts: one level per dissolve" begin
        d = group_arts([a, b, c], [1, 2])
        d2 = group_arts(d, [4, 3])
        # Ungrouping the inner group promotes its members into the outer.
        d3 = ungroup_arts(d2, [4])
        @test length(d3) == 4
        outer = d3[art_index(d3, d2[5].id)]
        @test outer.children == UInt64[a.id, b.id, c.id]
        @test art_index(d3, d2[4].id) === nothing
        # Ungrouping the outer group only leaves the inner group top level.
        d4 = ungroup_arts(d2, [5])
        @test [x.name for x in d4] == ["a", "b", "c", "Group 1"]
        @test is_group(d4[4])
        # Both at once: everything promotes to the top level.
        d5 = ungroup_arts(d2, [4, 5])
        @test [x.name for x in d5] == ["a", "b", "c"]
        @test all(x -> !is_group(x), d5)
        # Ungrouping a non-group selection is a no-op.
        @test ungroup_arts(d2, [1]) === d2
    end

    @testset "delete_arts: prune member references" begin
        d = group_arts([a, b, c], [1, 2])
        # A deleted shape leaves its group's children.
        d2 = delete_arts(d, [1])
        g = d2[art_index(d2, d[4].id)]
        @test g.children == UInt64[b.id]
        # A deleted group node dissolves; the members keep their entries.
        d3 = delete_arts(d, [4])
        @test [x.name for x in d3] == ["a", "b", "c"]
        # Group + shape at once.
        d4 = delete_arts(d, [1, 4])
        @test [x.name for x in d4] == ["b", "c"]
    end

    @testset "edits keep identity: group membership survives" begin
        d = group_arts([a, b, c], [1, 2])
        moved = translate(d[1], 5.0, 5.0)
        @test moved.id == d[1].id
        recoloured = set_layer([d[1]], 3)
        @test recoloured[1].id == d[1].id
        # After moving a member, the group still resolves to it.
        d2 = [ArtObject(art; paths = translate(art, 5.0, 5.0).paths)
              for art in d]
        @test leaves_of(d2, 4) == [1, 2]
        @test d2[4].children == d[4].children
    end

    @testset "summary and layers skip groups" begin
        d = group_arts([a, b, c], [1, 2])
        @test occursin("a: 1 outline", doc_summary(d))
        @test !occursin("Group 1", doc_summary(d))
        @test document_layers(d) == [0, 1, 2]
    end
end

@testset "context menu: group and ungroup" begin
    # The right-click path through the real event pipeline: the click opens
    # the app's context menu as its own popup window anchored at the
    # pointer; Group wraps the selection, Ungroup dissolves the group nodes
    # one level. A disabled item ignores presses (the menu stays open); the
    # first click elsewhere dismisses the menu (swallowed).
    import SDL3
    doc = Observable(ArtObject[])
    selection = Observable(Int[])
    ctx_open = Observable(false)

    ring(x0, y0, x1, y1) = PolyLine([Point(x0, y0), Point(x1, y0),
                                     Point(x1, y1), Point(x0, y1)], true)
    doc[] = [ArtObject("a", [ring(100.0, 100.0, 200.0, 160.0)], 0),
             ArtObject("b", [ring(40.0, 190.0, 140.0, 240.0)], 2)]

    Rocks.with_tree(() -> App(doc = doc, selection = selection,
                              ctx_open = ctx_open)) do root
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        Rocks.draw_window!(main)
        canvas = Rocks.find_kind(main, Rocks.Canvas)
        cam = fit_camera(canvas.rect[3], canvas.rect[4], doc[])
        m = matrix(cam)
        pt(p) = begin
            s = apply(m, p)
            (round(Int, canvas.rect[1] + s[1]),
             round(Int, canvas.rect[2] + s[2]))
        end
        item(f, label) = Rocks.find_fiber(f) do fib
            fib.kind === Rocks.Pressable &&
                Rocks.find_by_label(fib, label) !== nothing
        end
        popups(wins) = filter(w -> Bool(get(w.props, :popup, false)), wins)
        right_click(p) = begin
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                              Float32(p[1]), Float32(p[2]); button = 3)
            Rocks.drain_events!()
            Rocks.flush_dirty!()
            Rocks.run_effects!()
        end
        marquee(from, to) = begin
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                              Float32(from[1]), Float32(from[2]))
            Rocks.drain_events!()
            Rocks.push_motion!(canvas, to[1], to[2])
            Rocks.drain_events!()
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                              Float32(to[1]), Float32(to[2]))
            Rocks.drain_events!()
            Rocks.flush_dirty!()
            Rocks.run_effects!()
        end
        p = pt(SVector(260.0, 60.0))

        # Right-click on empty space opens the menu at the click (the
        # popup is its own window; the flag the click flipped drove it).
        right_click(p)
        @test ctx_open[]
        windows = Rocks.sync_windows!(root)
        @test length(windows) == 2
        popup = only(popups(windows))
        @test get(popup.props, :menu_open, nothing) === ctx_open
        # Anchored at the pointer (+ the nudge): the popup's own x/y.
        @test get(popup.props, :x, 0) == p[1] + 2
        @test get(popup.props, :y, 0) == p[2] + 2

        # Nothing is selected yet: Group is disabled and ignores the press
        # (the menu stays open).
        group_item = item(popup, "Group")
        @test group_item !== nothing
        @test Bool(get(group_item.props, :disabled, false))
        Rocks.click!(group_item)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test length(doc[]) == 2
        @test ctx_open[]

        # A click elsewhere dismisses the open menu (swallowed).
        c0 = pt(SVector(50.0, 210.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                          Float32(c0[1]), Float32(c0[2]))
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test !ctx_open[]
        @test selection[] == Int[]

        # Select both shapes with a marquee, then Group via the menu.
        marquee(pt(SVector(250.0, 260.0)), pt(SVector(60.0, 60.0)))
        @test selection[] == [1, 2]
        right_click(p)
        windows = Rocks.sync_windows!(root)
        popup = only(popups(windows))
        group_item = item(popup, "Group")
        @test !Bool(get(group_item.props, :disabled, false))
        Rocks.click!(group_item)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test length(doc[]) == 3
        @test is_group(doc[][3])
        @test doc[][3].children == UInt64[doc[][1].id, doc[][2].id]
        @test selection[] == [3]
        # The menu closed with the item's action.
        windows = Rocks.sync_windows!(root)
        @test isempty(popups(windows))

        # Clicking a member now selects the whole group (canvas click on
        # a's outline).
        c1 = pt(SVector(150.0, 100.0))
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                          Float32(c1[1]), Float32(c1[2]))
        Rocks.drain_events!()
        Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                          Float32(c1[1]), Float32(c1[2]))
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [3]

        # Ungroup dissolves the group; the selection follows the members.
        right_click(p)
        windows = Rocks.sync_windows!(root)
        popup = only(popups(windows))
        ungroup_item = item(popup, "Ungroup")
        @test ungroup_item !== nothing
        @test !Bool(get(ungroup_item.props, :disabled, false))
        Rocks.click!(ungroup_item)
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test length(doc[]) == 2
        @test selection[] == [1, 2]
        windows = Rocks.sync_windows!(root)
        @test isempty(popups(windows))
    end
end

@testset "group selection: clicks and marquee units" begin
    # With a group in the document, a canvas click on a member selects the
    # group, Shift toggles at unit level, and the marquee compares the
    # top-level entries (a group acts like a single shape).
    import SDL3
    doc = Observable(ArtObject[])
    selection = Observable(Int[])

    ring(x0, y0, x1, y1) = PolyLine([Point(x0, y0), Point(x1, y0),
                                     Point(x1, y1), Point(x0, y1)], true)
    doc[] = group_arts([ArtObject("a", [ring(100.0, 100.0, 200.0, 160.0)], 0),
                        ArtObject("b", [ring(40.0, 190.0, 140.0, 240.0)], 2),
                        ArtObject("c", [ring(220.0, 100.0, 260.0, 140.0)], 1)],
                       [1, 2])   # [a, b, c, Group 1(a, b)]

    Rocks.with_tree(() -> App(doc = doc, selection = selection)) do root
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        Rocks.draw_window!(main)
        canvas = Rocks.find_kind(main, Rocks.Canvas)
        cam = fit_camera(canvas.rect[3], canvas.rect[4], doc[])
        m = matrix(cam)
        pt(p) = begin
            s = apply(m, p)
            (round(Int, canvas.rect[1] + s[1]),
             round(Int, canvas.rect[2] + s[2]))
        end
        click_at(p; mod = UInt16(0)) = begin
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                              Float32(p[1]), Float32(p[2]); mod = mod)
            Rocks.drain_events!()
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                              Float32(p[1]), Float32(p[2]); mod = mod)
            Rocks.drain_events!()
            Rocks.flush_dirty!()
            Rocks.run_effects!()
        end
        marquee(from, to) = begin
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                              Float32(from[1]), Float32(from[2]))
            Rocks.drain_events!()
            Rocks.push_motion!(canvas, to[1], to[2])
            Rocks.drain_events!()
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                              Float32(to[1]), Float32(to[2]))
            Rocks.drain_events!()
            Rocks.flush_dirty!()
            Rocks.run_effects!()
        end

        # Clicking a member selects the group (a's outline).
        click_at(pt(SVector(150.0, 100.0)))
        @test selection[] == [4]
        # Shift+click the ungrouped shape adds it at unit level.
        click_at(pt(SVector(240.0, 100.0)); mod = 0x0001)
        @test sort(selection[]) == [3, 4]
        # Shift+click again removes it.
        click_at(pt(SVector(240.0, 100.0)); mod = 0x0001)
        @test selection[] == [4]

        # The selection frame encloses the group's subtree union.
        bbox = selection_union_bbox(m, doc[], selection[])
        want = selection_union_bbox(m, doc[], [1, 2])
        @test bbox == want

        # Green marquee touching only the group selects it as a unit (the
        # ungrouped shape stays out).
        marquee(pt(SVector(195.0, 250.0)), pt(SVector(150.0, 60.0)))
        @test selection[] == [4]
        # Green over everything selects both units.
        marquee(pt(SVector(270.0, 260.0)), pt(SVector(30.0, 60.0)))
        @test sort(selection[]) == [3, 4]
        # Red over part of the group selects nothing of it.
        marquee(pt(SVector(90.0, 60.0)), pt(SVector(150.0, 250.0)))
        @test isempty(selection[])
        # Red fully containing the group selects it.
        marquee(pt(SVector(30.0, 60.0)), pt(SVector(210.0, 250.0)))
        @test selection[] == [4]
    end
end

@testset "right panel tabs and outline" begin
    # The right dock is a tab control: the layer settings first, the
    # document outline second. Outline rows list every entry with members
    # indented under their group; a row click selects exactly that entry.
    import SDL3
    doc = Observable(ArtObject[])
    selection = Observable(Int[])
    panel_tab = Observable(1)

    ring(x0, y0, x1, y1) = PolyLine([Point(x0, y0), Point(x1, y0),
                                     Point(x1, y1), Point(x0, y1)], true)
    doc[] = group_arts(group_arts(
        [ArtObject("alpha", [ring(100.0, 100.0, 200.0, 160.0)], 0),
         ArtObject("beta", [ring(40.0, 190.0, 140.0, 240.0)], 2),
         ArtObject("gamma", [ring(220.0, 100.0, 260.0, 140.0)], 1)],
        [1, 2]), [4, 3])
    # [alpha, beta, gamma, Group 1(alpha, beta), Group 2(Group 1, gamma)]

    Rocks.with_tree(() -> App(doc = doc, selection = selection,
                              panel_tab = panel_tab)) do root
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        Rocks.draw_window!(main)

        # Page 1: the layers list (the doc has geometry); no outline rows.
        @test Rocks.find_by_label(main, "00") !== nothing
        @test Rocks.find_by_label(main, "alpha") === nothing

        # Switch to the outline tab: the tree shows every entry.
        panel_tab[] = 2
        Rocks.perform_render!(root)
        Rocks.run_effects!()
        Rocks.flush_dirty!()
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        @test Rocks.find_by_label(main, "no layers yet") === nothing
        @test Rocks.find_by_label(main, "alpha") !== nothing
        @test Rocks.find_by_label(main, "beta") !== nothing
        @test Rocks.find_by_label(main, "gamma") !== nothing
        @test Rocks.find_by_label(main, "Group 1") !== nothing
        @test Rocks.find_by_label(main, "Group 2") !== nothing

        # A shape row selects exactly that shape — never its parent group.
        row(f, label) = Rocks.find_fiber(f) do fib
            fib.kind === Rocks.Pressable &&
                Rocks.find_by_label(fib, label) !== nothing
        end
        Rocks.click!(row(main, "alpha"))
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [1]

        # A group row selects the group (its members follow by membership).
        Rocks.click!(row(main, "Group 1"))
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [4]

        # The outermost group row selects the whole outer group.
        Rocks.click!(row(main, "Group 2"))
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [5]
    end
end

@testset "group selection: outermost group from a nested click" begin
    # Clicking a shape of a nested group selects the *outermost* group in
    # its ancestor chain.
    import SDL3
    doc = Observable(ArtObject[])
    selection = Observable(Int[])

    ring(x0, y0, x1, y1) = PolyLine([Point(x0, y0), Point(x1, y0),
                                     Point(x1, y1), Point(x0, y1)], true)
    doc[] = group_arts(group_arts(
        [ArtObject("alpha", [ring(100.0, 100.0, 200.0, 160.0)], 0),
         ArtObject("beta", [ring(40.0, 190.0, 140.0, 240.0)], 2),
         ArtObject("gamma", [ring(210.0, 100.0, 260.0, 140.0)], 1)],
        [1, 2]), [4, 3])
    # [alpha, beta, gamma, Group 1(alpha, beta), Group 2(Group 1, gamma)]

    Rocks.with_tree(() -> App(doc = doc, selection = selection)) do root
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        Rocks.draw_window!(main)
        canvas = Rocks.find_kind(main, Rocks.Canvas)
        cam = fit_camera(canvas.rect[3], canvas.rect[4], doc[])
        m = matrix(cam)
        pt(p) = begin
            s = apply(m, p)
            (round(Int, canvas.rect[1] + s[1]),
             round(Int, canvas.rect[2] + s[2]))
        end
        click_at(p; mod = UInt16(0)) = begin
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                              Float32(p[1]), Float32(p[2]); mod = mod)
            Rocks.drain_events!()
            Rocks.push_mouse!(canvas, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                              Float32(p[1]), Float32(p[2]); mod = mod)
            Rocks.drain_events!()
            Rocks.flush_dirty!()
            Rocks.run_effects!()
        end

        # Clicking alpha's outline (a member of the inner group) selects the
        # outermost group.
        click_at(pt(SVector(150.0, 100.0)))
        @test selection[] == [5]
        # Clicking gamma (a direct member of the outer group) — same unit.
        click_at(pt(SVector(240.0, 100.0)))
        @test selection[] == [5]
        # Shift+click toggles the unit: the outermost group drops out.
        click_at(pt(SVector(240.0, 100.0)); mod = 0x0001)
        @test selection[] == Int[]
        # Shift+click again brings it back.
        click_at(pt(SVector(240.0, 100.0)); mod = 0x0001)
        @test selection[] == [5]
    end
end

@testset "outline: ctrl-click toggles into the multi-selection" begin
    import SDL3
    doc = Observable(ArtObject[])
    selection = Observable(Int[])
    panel_tab = Observable(2)   # the outline page from the start

    ring(x0, y0, x1, y1) = PolyLine([Point(x0, y0), Point(x1, y0),
                                     Point(x1, y1), Point(x0, y1)], true)
    doc[] = group_arts(group_arts(
        [ArtObject("alpha", [ring(100.0, 100.0, 200.0, 160.0)], 0),
         ArtObject("beta", [ring(40.0, 190.0, 140.0, 240.0)], 2),
         ArtObject("gamma", [ring(210.0, 100.0, 260.0, 140.0)], 1)],
        [1, 2]), [4, 3])

    Rocks.with_tree(() -> App(doc = doc, selection = selection,
                              panel_tab = panel_tab)) do root
        windows = Rocks.sync_windows!(root)
        main = windows[findfirst(
            w -> Rocks.find_kind(w, Rocks.Canvas) !== nothing, windows)]
        Rocks.draw_window!(main)

        row(f, label) = Rocks.find_fiber(f) do fib
            fib.kind === Rocks.Pressable &&
                Rocks.find_by_label(fib, label) !== nothing
        end

        # A plain click selects exactly that entry (the shape, no parent).
        Rocks.click!(row(main, "alpha"))
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [1]

        # Ctrl+click the group row toggles it into the multi-selection.
        ctrl_click(f) = begin
            x, y = Rocks.fiber_center(f)
            Rocks.push_mouse!(f, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, x, y;
                              mod = 0x0040)   # left button, Ctrl held
            Rocks.drain_events!()
            Rocks.push_mouse!(f, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, x, y;
                              mod = 0x0040)
            Rocks.drain_events!()
            Rocks.flush_dirty!()
            Rocks.run_effects!()
        end
        ctrl_click(row(main, "Group 1"))
        @test sort(selection[]) == [1, 4]
        # Ctrl+click again removes it.
        ctrl_click(row(main, "Group 1"))
        @test selection[] == [1]
        # Ctrl+click the outer group too: both units at once.
        ctrl_click(row(main, "Group 2"))
        @test sort(selection[]) == [1, 5]
        # A plain click collapses back to exactly that entry.
        Rocks.click!(row(main, "gamma"))
        Rocks.drain_events!()
        Rocks.flush_dirty!()
        Rocks.run_effects!()
        @test selection[] == [3]
    end
end
