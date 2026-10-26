# Even-odd region fill for scan-mode layers (Fill / Offset Fill).
#
# LightBurn renders fills by scanning a region: overlapping shapes on the
# same layer mutually erase (§3 "same layer ⇒ overlap is not engraved"), and
# holes are skipped — exactly the even-odd fill rule. All closed geometry of
# a layer is therefore scanned in one pass: every edge of every polygon
# contributes crossings, and the interior alternates fill/erase per
# crossing on each scan row.
#
# The scan produces per-row fill runs in canvas coordinates; the workspace
# paints the runs into a per-layer software texture (ARGB8888) that is
# blitted before the strokes. Texture recomputation is driven by cache keys
# (camera, canvas size, mode, per-layer document identity) so the marching-
# dashes animation — which redraws the canvas every frame — never re-scans
# an unchanged fill.

"Crossing edge of a polygon: the segment between vertical extremes, kept as
`(xa, ya, xb, yb)` with `ya <= yb`."
const Edge = NTuple{4,Float64}

"""
    even_odd_runs(polys, rows) -> Vector{Vector{Pair{Float64,Float64}}}

Per-scanline fill runs (semi-open x ranges) of a set of closed canvas-space
polygons under the even-odd rule, for the given `rows` (canvas rows; each
scanline samples its vertical centre at `y + 0.5`).

`polys` is a vector of rings, each a vector of `(x, y)` points; rings are
closed implicitly (a returning segment is added when the last point differs
from the first). Horizontal edges contribute nothing.
"""
function even_odd_runs(polys, rows::UnitRange{Int})
    lo, hi = first(rows), last(rows)
    edges = Edge[]
    for ring in polys
        n = length(ring)
        n < 3 && continue
        first_pt = ring[1]
        last_pt = ring[end]
        ring_closed = first_pt[1] == last_pt[1] && first_pt[2] == last_pt[2]
        for i in 1:(ring_closed ? n - 1 : n)
            p1 = ring[i]
            p2 = ring[mod1(i + 1, n)]
            p1[2] == p2[2] && continue  # horizontal edges cross no scanline
            if p1[2] <= p2[2]
                push!(edges, (p1[1], p1[2], p2[1], p2[2]))
            else
                push!(edges, (p2[1], p2[2], p1[1], p1[2]))
            end
        end
    end
    # Bucket the edges by the first row that samples them.
    buckets = Dict{Int,Vector{Edge}}()
    for e in edges
        y0 = ceil(Int, e[2] - 0.5)      # first scan centre at or above ymin
        (y0 > hi || e[4] < lo + 0.5) && continue
        push!(get!(buckets, max(y0, lo), Edge[]), e)
    end
    active = Edge[]
    runs = [Pair{Float64,Float64}[] for _ in lo:hi]
    for y in lo:hi
        yc = y + 0.5
        # Drop edges whose last sampling row is behind us; add the ones that
        # become active on this row.
        filter!(e -> e[4] > yc, active)
        append!(active, get(buckets, y, ()))
        if isempty(active)
            continue
        end
        xs = Float64[e[1] + (yc - e[2]) * (e[3] - e[1]) / (e[4] - e[2])
                     for e in active]
        sort!(xs)
        runs[y - lo + 1] = [xs[i] => xs[i + 1] for i in 1:2:(length(xs) - 1)]
    end
    return runs
end

"""
    paint_even_odd!(pixels, runs, w; rows, color)

Paint fill runs into an ARGB8888 `UInt32` buffer of width `w` (row-major,
little-endian canvas-local pixels). `color` is an `(r, g, b)` tuple packed
opaque. Runs are clamped to the buffer's width; empty spans are skipped.
"""
function paint_even_odd!(pixels::AbstractVector{UInt32}, runs, w::Int;
                         rows::UnitRange{Int},
                         color::Tuple{Float64,Float64,Float64})
    r = round(UInt32, clamp(255color[1], 0, 255))
    g = round(UInt32, clamp(255color[2], 0, 255))
    b = round(UInt32, clamp(255color[3], 0, 255))
    pixel32 = (UInt32(255) << 24) | (r << 16) | (g << 8) | b
    for (i, rowruns) in enumerate(runs)
        y = first(rows) + i - 1
        (y < 0 || y * w >= length(pixels)) && continue
        for (a, bb) in rowruns
            left = ceil(Int, a)
            right = floor(Int, bb)
            (left >= right || left >= w || right <= 0) && continue
            left = max(left, 0)
            right = min(right, w)
            base = y * w
            @inbounds @simd for x in (1 + base + left):(base + right)
                pixels[x] = pixel32
            end
        end
    end
    return nothing
end
