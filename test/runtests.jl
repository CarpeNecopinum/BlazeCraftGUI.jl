using Test
using BlazecraftGUI
using BlazecraftGUI: fit_camera, matrix, apply, zoom_at, pan, Camera,
                    doc_summary, document_bounds, center_on_workarea,
                    layer_color, ArtObject
using BlazeCraft.Shapes: PolyLine, Point
using StaticArrays: SVector

@testset "document model" begin
    @testset "import_art: svg" begin
        art = import_art(joinpath(@__DIR__, "assets", "shapes.svg"))
        @test art.name == "shapes.svg"
        @test length(art.paths) == 3
        # Coordinates are millimetres, y-up (importer flips SVG's y-down).
        ys = [p[2] for pl in art.paths for p in pl.points]
        @test maximum(ys) <= 0  # the file sits below the origin after the flip
    end

    @testset "import_art: errors" begin
        @test_throws ErrorException import_art("/nonexistent/file.svg")
        @test_throws ErrorException import_art(joinpath(@__DIR__, "runtests.jl"))
    end

    @testset "document_bounds" begin
        @test document_bounds(ArtObject[]) === nothing
        art = import_art(joinpath(@__DIR__, "assets", "shapes.svg"))
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
        art = import_art(joinpath(@__DIR__, "assets", "shapes.svg"))
        @test doc_summary([art]) == "shapes.svg: 3 outlines"
    end

    @testset "center_on_workarea" begin
        @testset "single object centers its bounds on the work area" begin
            art = import_art(joinpath(@__DIR__, "assets", "shapes.svg"))
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
                                             true)], layer_color(0))
            tri = ArtObject("tri", [PolyLine([Point(60.0, 30.0), Point(80.0, 30.0),
                                              Point(70.0, 50.0)], false)], layer_color(0))
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
        art = ArtObject("box", [pl], layer_color(0))
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
        art = ArtObject("wide", [pl], layer_color(0))
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
