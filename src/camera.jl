# The workspace camera: translation, rotation and scale, constructible as a
# matrix (StaticArrays) so the world-space geometry stays constant and is
# transformed per frame when the user pans/zooms.

using StaticArrays: SVector, @SMatrix, inv
using StaticArrays

"""
    Camera(translation, rotation, scale)

The workspace view.

  - `translation`: `SVector{2,Float64}` — the screen position (px) of the
    world origin,
  - `rotation`: the angle (radians) of the world around the origin,
  - `scale`: the zoom in px per mm.

World coordinates are millimetres, y-up; canvas-local pixels are y-down —
the y-flip is baked into the scale columns of the matrix.
"""
struct Camera
    translation::SVector{2,Float64}
    rotation::Float64
    scale::Float64
end

Camera(translation::Tuple{Float64,Float64}, rotation::Real, scale::Real) =
    Camera(SVector{2,Float64}(translation), Float64(rotation), Float64(scale))

"""
    matrix(cam) -> SMatrix{3,3,Float64}

The 3×3 affine matrix mapping world coordinates onto canvas-local pixels:
`screen = matrix(cam) * [x, y, 1]`. Built as translate ∘ rotate ∘
(scale with the baked-in y-flip), so

    screen_x = tx + s·(cosθ·x − sinθ·y)
    screen_y = ty − s·(sinθ·x + cosθ·y)

Unproject with `inv(matrix(cam)) * [x, y, 1]`.
"""
function matrix(cam::Camera)
    co, si = cos(cam.rotation), sin(cam.rotation)
    k = cam.scale
    tx, ty = cam.translation
    @SMatrix [k*co  -k*si  tx;
              -k*si -k*co  ty;
              0.0    0.0   1.0]
end

"Apply a camera matrix to a world point (allocation-free)."
apply(m::SMatrix{3,3,Float64}, p) =
    (m[1, 1] * p[1] + m[1, 2] * p[2] + m[1, 3],
     m[2, 1] * p[1] + m[2, 2] * p[2] + m[2, 3])

"""
    zoom_at(camera, x, y, factor) -> Camera

Zoom by `factor` keeping the world point under the canvas-local cursor
`(x, y)` fixed: unproject the cursor through the current matrix, then solve
the translation so the same world point maps back onto the cursor with the
new scale.
"""
function zoom_at(camera::Camera, x, y, factor)
    m = matrix(camera)
    w = inv(m) * SVector(x, y, 1.0)      # world point under the cursor
    co, si = cos(camera.rotation), sin(camera.rotation)
    k = clamp(camera.scale * factor, 0.05, 500.0)
    tx = x - k * (co * w[1] - si * w[2])
    ty = y + k * (si * w[1] + co * w[2])
    return Camera(SVector(tx, ty), camera.rotation, k)
end

"""
    pan(camera, dx, dy) -> Camera

Pan by `dx`/`dy` canvas-local pixels.
"""
pan(camera::Camera, dx::Real, dy::Real) =
    Camera(camera.translation .+ SVector(dx, dy), camera.rotation, camera.scale)
