# Dependency Usage Notes — BlazeCraft.jl + Rocks.jl

> Practical developer reference for building **BlazeCraftGUI.jl** on the two checked-out dependencies.
> Written after reading both codebases (not just their READMEs). This is a *how to use* guide — it complements the
> LightBurn feature analysis in `00`–`09` by explaining the exact machinery available to build the app.
>
> **Stack fact:** the two dependencies split the problem cleanly:
> * **BlazeCraft.jl** — the *headless domain*: laserable geometry (`Shapes`), tool-path generation (`Processes`),
>   file parsing (`Importers`), machine I/O (`Sinks`). No GUI.
> * **Rocks.jl** — the *presentation*: a React(Native)-style GUI toolkit on SDL3 with components, hooks, context,
>   flexbox layout, and two themed component sets (`Material3` and — most relevant here — `Enterprise`).

---

## 1. The two-lane architecture

```
         ┌────────────────────────── Loser GUI (Rocks) ──────────────────────────┐
         │  E.Form + E.MenuBar + E.ToolBar + E.StatusBar (the LightBurn shell)    │
         │  Panels: TabControl, ListView, GroupBox, TextBox, ComboBox, CheckBox…   │
         │  Dialogs: MessageBox, ContextMenu                                        │
         │  State: Observable store (the live Document)                            │
         └───────────────▲───────────────────────────────────────────────▲────────┘
                         │ @rock re-renders on Observable change          │ reads shapes/state
         ┌───────────────┴───────────────────────────────────────────────┴────────┐
         │                          BLAZECRAFT (headless)                          │
         │  Shapes: PolyLine/Rectangle/MultiShape + lazy transforms (Pos/Rot/Scale)│
         │  Importers: DXF / SVG → MultiShape                                       │
         │  Processes: OutlineCut / ScanlineFill / offset_fill → Vector{Move}       │
         │  (Sinks: Moonraker — currently not wired into the module)                │
         └──────────────────────────────────────────────────────────────────────────┘
                 │ generate moves
                 ▼
              G-code / machine
```

The glue is **Observables**. Rocks state *is* `Observable`s (from `Observables.jl`, re-exported by Rocks). The
natural design: keep the current **Document** (the domain model from `01-application-architecture.md`) in one or
more `Observable`s; a component `@use`s it (or a derived view of it) so it re-renders whenever geometry or cut
settings change; and call into BlazeCraft's `Processes` to materialize tool-paths on demand (for the Preview or
for output).

---

## 2. Rocks.jl — how to use it

### 2.1 Project wiring

```toml
[deps]
BlazeCraft = "b762ea48-c64f-410f-89e7-acff101548cf"
Rocks      = "4be72d32-6d9d-40bc-abe6-d593b8af2f05"
SDL3       = "d6436c51-22c4-47c5-9af2-69281707dbc3"

[sources]
BlazeCraft = {path = "../BlazeCraft.jl"}
Rocks      = {path = "../Rocks.jl"}
SDL3       = {rev = "master", url = "https://github.com/CarpeNecopinum/SDL3.jl"}
```

System deps: `libsdl3-dev` + `libsdl3-ttf-dev`. Headless/CI: `SDL_VIDEO_DRIVER=dummy`; ttf via
`SDL3_TTF_LIBRARY_PATH`. Possible ALSA env: `ALSA_CONFIG_PATH=/usr/share/alsa/alsa.conf`.

### 2.2 Rendering model (the mental model)

* A **component** is any Julia function taking props as keywords and returning an element/tuple/`nothing`/string.
* `@rock Kind(children...; props...)` builds an element (the role of `createElement`). `kind` is a known *host*
  kind (`Window, Box, Text, Pressable, ScrollView, Image, Split, Slider`) or a component function.
* Children are values: strings/numbers become text, `nothing`/`false` are skipped (→ `cond && @rock …`).
* `render(App)` runs the main loop: block on events/timers → dispatch → if **dirty**, re-run components, reconcile
  fibers, run effects, lay out, redraw. Idle app neither redraws nor burns CPU. `request_render()` marks dirty.
* `quit!()` closes windows and returns from `render`.

### 2.3 State & lifecycle (hooks)

| Hook | Purpose |
|---|---|
| `x = @use Observable(v)` | State. Returns the *Observable* itself. Setting it (`x[] = new` or `x[] += 1`) re-renders (identical values do not). |
| `x = @use Ref(v)` | Mutable ref, *silent* (React `useRef`); call `request_render()` to redraw. |
| `x = @use someObservable` / `@use someProp` | Subscribe to any observable (global, prop, or derived via `map(...)`). |
| `x = @use SomeContext` | Form 3: read a context value (see below). |
| `useEffect(f, deps)` | Side effects after commit. `nothing`=every render, `()`=once on mount, `(x,)`=when x changes. Return a cleanup from `f`. |
| `useMemo(f, deps)` / `useCallback(f, deps)` | Memoization. |
| `use_fiber()` | The current component's **fiber** — used in callbacks to look up *laid-out* geometry (rects, measured sizes). |
| `useInterval(f, ms)` / `useTimeout(f, ms)` | Timers, auto-cleaned on unmount. |

**Rules (React's rules):** hooks only from component functions, same order/count every render, top-level only.

### 2.4 Context

```julia
const Theme = createContext((dark = false,))

function Toolbar()
    theme = @use Theme            # receive nearest-provided value
    ...
end

function App()
    theme = @use Observable((dark = true,))
    @rock Theme.provider(          # provide down the tree
        @rock Toolbar();
        value = theme)             # an Observable → consumers re-render on change
end
```

Foundation for the theme switching (LightBurn dark/light, hotkey map, units, and the "capability set" idea in
`09-implementation-roadmap.md` §2.4).

### 2.5 Layout — Flexbox (React-Native)

Containers have a **main axis** (`direction = :row`/`:column`) and a **cross axis**. Key props:

| Prop | Meaning |
|---|---|
| `flex = 1` | grow/shrink/basis-0 shorthand — fills the free space |
| `flex_grow` / `flex_shrink` / `flex_basis` | weighted share of free space (basis can be `%`) |
| `justify` | along main axis: `:start :end :center :between :around :evenly` |
| `align` | across cross axis: `:start :end :center :stretch` (default here is `:start`, *not* RN's `:stretch`) |
| `align_self`, `flex_wrap`, `margin`, `min/max_width/height`, `overflow = :hidden` | standard |
| `width/height = "50%"` | percentage of parent's content box |
| `position = :absolute, x, y, anchor` | manual placement (anchor :top_left/:center/:bottom/…); `fill = true` to fill the parent |

Works on **components** too without them declaring it: `@rock MyCard(; flex = 1)` sizes it in its parent. This is
the entire basis of the dockable LightBurn layout: use flexbox + absolutes + `Split` for panes.

### 2.6 Host elements

| Element | Notes |
|---|---|
| `Window` | An OS window. Props: `title, width, height, resizable, background`, positioning `position` (`:cascade`/`:centered`/`:manual`/`:mouse`), `display`, `x,y`, layout props, and callbacks `on_key(key)`, `on_text_input(text)`, `on_close()` (return `false` to keep open). Multi-window = several `Window`s in the tree. |
| `Box` | Rect container: `background` (incl. `LinearGradient`), `border_color/width`, `radius` (4-corner tuple possible), `direction`, `gap`, `padding` (number or `(hw,v)`), `align`, `justify`, `width/height`, `position=:absolute`, `scroll`, `bevel` (`:raised/:sunken/:etched/:none`), `overflow=:visible`, `pointer_events=:none`. `Row`/`Column` = directional convenience wrappers. |
| `ScrollView` | Box that clips + wheel-scrolls. `direction=:column` (vertical, default) or `:row`; `scroll_step` (48); `on_scroll(offset)`; `scrollbar=true` + styling props. Needs a bounded size (`width/height` or `position=:absolute, fill=true`). Absolute children pin to the viewport. |
| `Text` | stringified children, TTF. `size, color, font`; `"\n"` for newline. Font via `Rocks.set_default_font!(path)`, `ROCKS_FONT`, or `font` prop. |
| `Pressable` | Box + pointer events: `on_press, on_press_in, on_press_out, on_hover_in, on_hover_out, disabled, cursor` (`:hand`/`:text`), and `background/hover_background/pressed_background`. |
| `Image` | A PNG/BMP (`src` path or URL). `width/height` (keep aspect if only one). |
| `Split` | Resizable divider between first two children. `direction=:horizontal/:vertical`, `ratio` (an `Observable`→draggable, or a number→initial), `handle` (thickness), `handle_color`. |
| `Slider` | `value::Observable, min, max, on_change`. |

**Pre-styled (Material-UI-style):** `Button, Checkbox, Toggle, RadioGroup, DropDownMenu, Tabber, ProgressBar`.

### 2.7 Enterprise — the set to use for a LightBurn-like UI

LightBurn's UI is Winforms-style; `Rocks.Enterprise` is a faithful Win7/Winforms component set and is the
**best match**. API (all built on the primitives; theme via `E.ThemeContext.provider` with an `Observable{E.Theme}`):

| Component | Signature highlights |
|---|---|
| `Button` | `label, on_press, default=false, disabled, icon, width, height` — raised gradient / default border |
| `Label` / `LinkLabel` | text; link is blue underlined + on_press |
| `TextBox` | `text::Observable{String}` (**required**), `read_only, password, placeholder, on_submit, on_change`. Full caret/selection/clipboard editing, right-click edit menu. **Needs an Observable.** |
| `CheckBox` | `checked::Observable{Bool}` (required), `label, on_change, disabled` |
| `RadioButton` | `selected::Observable{Int}, value, label, on_change` |
| `GroupBox` | etched frame + caption in a notch; `title, padding` |
| `Panel` | plain container; `background, border, padding, bevel` |
| `ProgressBar` | `value::Observable` (0–1), `width, height` |
| `Slider` | `value::Observable, min, max, width, ticks` |
| `SplitContainer` | themed `Split`; `direction, ratio, handle` |
| `TabControl` | `tabs::Vector{String}, selected::Observable{Int}, children` (one child per tab), `on_change` — like the Cuts/Layers+sub tabs |
| `ListView` | `items, selected::Observable{Int}` (or `{Vector{Int}}` if multi), `multi, checkboxes, icons` |
| `GridView` | `columns=[(name,width[,:right]),…], rows=Vector of row-tuples, selected`; `fill=true` stretches last column |
| `ComboBox` | `items, selected::Observable{Int}` (popup painted by the control — leave vertical room) |
| `MenuItem`/`Menu`/`MenuSeparator` | `MenuItem(label, on_press, shortcut, checked, enabled, submenu)`; `label="-"` for separator |
| `MenuBar` | `menus` vector; 22px; opens as **own borderless OS windows** pinned under titles |
| `ContextMenu` | `open::Observable{Bool}, x, y, items`; own OS window; Escape/outside click dismisses |
| `ToolBar` / `ToolButton` / `ToolSeparator` / `ToolGrip` | 28px; `ToolButton(icon,label,on_press,toggle::Observable{Bool},disabled,tooltip)` |
| `StatusBar` / `StatusPanel` | `StatusBar(panels=[StatusPanel(text,width,spring),…])`; sunken cells + grip |
| `ToolTip` | wrap any control: `@rock E.ToolTip(@rock E.Button(...); text="…")` |
| `MessageBox` | `open::Observable{Bool}, title, message, icon, buttons (:ok/:okcancel/:yesno/:yesnocancel), result::Observable, on_result`; own OS window |
| `Form` | **The app scaffold**: `menu, toolbar, status, children(, overlay=MessageBox)` → pins bars, scrolls only the client area. Title/width/height/resizable. |

Themes: `E.light_theme()` (Aero, default), `E.classic_theme()`, `E.high_contrast_theme()`; `E.ThemeContext.provider`.

**The complete Form + MenuBar + ToolBar + StatusBar + TabControl pattern is `examples/enterprise.jl`** — read it
as the template for the LightBurn shell. Menus/toolbar/status are built into variables and passed as props (a
`@rock` element cannot be inlined into a prop value).

### 2.8 Material3 (alternative)

`Rocks.Material3` implements Material Design 3: `Button, FAB, IconButton, SegmentedButton, Checkbox, Switch,
RadioGroup, Slider, Chips, Badge, Snackbar, Card, Dialog, Divider, List, Tooltip, NavigationBar/Rail/Drawer,
Tabs, TopAppBar, TextField, LinearProgress`. Theming via `M3.ThemeContext.provider` + `M3.light_theme()` /
`M3.dark_theme()`; `M3.ICONS` dict of Unicode glyphs. Use if a modern UI is preferred; **Enterprise is the closer
match to LightBurn** and is recommended.

### 2.9 Headless testing & screenshots

```julia
root = render(App; frames = 3, screenshot = "app.png")   # bounded + captured
screenshot(window, path)                                  # capture at any time
```
With `SDL_VIDEO_DRIVER=dummy` this produces real pixels from the software renderer, no display needed. The Rocks
test suite uses `png_pixel` (in `test/runtests.jl`) to pixel-verify screenshots — copy that pattern for UI tests.

### 2.10 Rocks limitations relevant to this project (read carefully)

1. ~~**No general custom drawing / canvas escape hatch yet.**~~ **Resolved 2026-10-23** — Rocks now has a native
   `Canvas` host element (added during this project; see §2.11). The Workspace draws vector geometry directly
   into the SDL renderer, no bitmap round-trip. This was the **single most important integration risk** and it is
   closed. See §2.11 for the API and the verified headless demo.
2. **Keyed list reconciliation** — only index-slot guarding so far (full reordering support pending). For long
   reordered lists (Cuts/Layers rows, History) prefer `Observable{Vector{...}}` + full re-render, which is fine.
3. **Text wrapping** pending; breadth is by explicit `"\n"`.
4. `ComboBox` popups are painted by the control — reserve vertical space under them.
5. Only **PNG and BMP** images load natively (via `Image`), and only for `Image src` can be an URL (cached via
   `Downloads`).
6. `render` is the entry point; `Rocks.run` and `Base.run` are ambiguous if both are `using`-ed with plain names.

### 2.11 The `Canvas` escape hatch (implemented 2026-10-23)

Rocks gained a native `Canvas` host element during this project (additions in `element.jl`,
`backend.jl`, `events.jl`, plus `examples/canvas.jl`). It is an
immediate-mode vector surface drawn **directly into the same SDL renderer as the rest of the UI** — no
offscreen bitmap, no texture upload per frame. Later the same day the pointer handling was lifted out of
the canvas into a dedicated [`MouseArea`](@ref) primitive — see §2.12 first, this section is about
drawing.

**Design decision (and answer to "Cairo/Luxor in the loop?"):** stay within SDL for interactive drawing.
The interactive Workspace re-renders every pan/zoom/node-drag frame; a Cairo/Luxor path would re-rasterize a
full-resolution bitmap and re-upload it as a texture each frame, which is the bottleneck at high DPI and
large designs. Cairo cannot draw "between" SDL calls anyway — two different pixel pipelines — it can only
round-trip through a texture, which is exactly what the existing `Image` element already does. So:

* **Interactive Workspace → `Canvas`** (SDL primitives, zero copy, clipped and composited by Rocks itself).
* **Offscreen high-quality output → Luxor/Cairo → `Image`** for the Preview window, exports and thumbnails
  (non-interactive, so a full-frame raster is natural there).

BlazeCraft's geometry model is `PolyLine` (already flattened at Curve Tolerance), so Cairo's superior curve
rasterisation buys little here — the same flattened polylines would be fed to either backend. Where smooth
curves matter visually, Rocks' own `RenderGeometry` alpha-fringe antialiasing (the technique its rounded
rects already use) can be extended to canvas fills later; SDL `RenderTexture` bilinear downsampling
("render big, blit small" supersampling) is the cheapest AA win for strokes.

**API** (all drawing in canvas-local coordinates; `(0,0)` = canvas top-left, y-down; colours use the normal
Rocks forms — tuples on 0–1/0–255 scale, hex strings, ColorTypes):

```julia
using Rocks
import Rocks: Canvas   # `Canvas` is exported, but qualify to avoid any doubt

@rock Canvas(
    @rock Box(overlay_child...);        # children are laid out & drawn on top, like a Box
    draw = ctx -> begin
        ctx.clear((0.97, 0.97, 0.97))                    # fill canvas
        ctx.line(x1, y1, x2, y2; color, width)           # width > 1 → filled 2-px+ quad
        ctx.polyline(pts; color, width, closed = false)  # iterable of (x, y); closed loops to pts[1]
        ctx.polygon(pts; color)                          # filled, triangle fan (convex/fan-ok)
        ctx.points(pts; color, size)                     # square dots
        ctx.text("label", x, y; size, color, font)       # TTF text, top-left anchor
        ctx.texture(sdl_texture, x, y; w, h)             # blit caller-owned texture
    end,
    # pointer interaction has moved to the `MouseArea` wrapper (§2.12); the
    # canvas itself is a pure drawing surface and takes no pointer props
    flex = 1, fill = true)
```

**Always pass `closed = true` for closed shapes** — `ctx.polyline` draws an open path otherwise, and a
"rectangle" silently misses its fourth edge (this actually bit us: the demo rect looked closed only
because a grid line happened to run along the missing edge). BlazeCraft `PolyLine(closed = true)` shapes
must map to `closed` polylines or the outline is broken.

`ctx.rect` is the canvas rect `(x, y, w, h)` in window coordinates, for local⇄window conversion.

**Behaviour worth knowing:**

* The canvas lays out and clips like a `Box`: it draws `background`/`border`/`radius`, its `draw` callback
  runs inside the content box (respecting any parent `overflow = :hidden` clip), and children draw **on top**
  (used for selection handles / overlay widgets that stay declarative).
* Repaint granularity: pointer events mark the window `needs_draw`, so a drag only re-runs the *draw pass*
  (components do not re-run). Frame-by-frame, the `draw` callback re-issues every primitive — keep the
  geometry flattening cheap (BlazeCraft `flatten` results should be cached in the document, not recomputed
  inside `draw`).
* Keyboard focus works like any pressable (`on_key`/`on_text_input` follow press).
* **Wheel**: `on_wheel(dx, dy, x, y)` lives on the `MouseArea` *wrapper* (see §2.12) and receives the raw
  wheel deltas — positive `dy` is wheel away/up, no step multiplication, already adjusted for
  `SDL_MOUSEWHEEL_FLIPPED` — and the pointer in area-local coords, enabling zoom-at-cursor. An `:on_wheel`
  consumer **takes precedence over scrollable ancestors** (innermost handler wins), so a canvas zooms
  inside a `ScrollView` instead of scrolling it; wheels over fibers without the prop still scroll normally
  (regression-tested both ways).
* **Initial view gotcha**: with the world→canvas map `local = world*zoom + pan` (y-flipped) and `pan = 0`,
  the world origin sits on the canvas's top-left corner — everything at world `y > 0` is clipped away. Give
  the workspace an initial `pan`/`zoom` that center the scene (the example starts at zoom 4, pan
  `(40, 210)` mm for a ~100×50 mm scene).
* `polygon` is a triangle fan from vertex 0 — fine for convex or fan-decomposable input; concave fills must
  be decomposed first (BlazeCraft's Clipper output or an earcut call).
* Thick lines beyond a few px are filled quads without joins — for wide strokes prefer `polygon` against the
  offset geometry (Clipper `ClipperOffset`) instead.
* No AA on `ctx.line`/`ctx.points` yet (SDL aliased primitives); acceptable for tool-path display (crisp
  pixels = honest preview of where the beam goes), and supersampling is the planned cure.
* **Cursors**: `cursor = :grab` on a `MouseArea` (§2.12) shows the open grab hand on hover and the
  closed grabbing hand while the pointer is held down (even outside the area); `cursor = :text` keeps the
  TextBox I-beam behavior; the default hoverable cursor is the pointing hand. Rocks requests SDL's
  `SDL_SYSTEM_CURSOR_GRAB`/`GRABBING` (enum ids 21/22, newer than the SDL3.jl binding's constants —
  appended enums are ABI-stable) and falls back to the pointing hand on old SDL builds.
* Implementation note (fixed 2026-10-23): the thick-line quad splitter initially reused the gradient
  helper's triangle indices `(0,1,2,2,1,3)` with a different vertex order, leaving a diagonal half of every
  quad unpainted — thick strokes randomly lost pixels where grid/other lines overpainted the gap. Correct
  ring-order indices are `(0,1,2,0,2,3)`; quadrilateral fills must always split along their own
  (v0–v2) diagonal.
* **Layout lessons from the two-column demo** (`examples/canvas.jl`, canvas left + control panel right):
  - A plain flow child of the Window does **not** stretch to fill it (`flex = 1` on the container itself is
    not enough — the container then shrink-wraps to its content and a `flex = 1` child inside it collapses
    to width 0). The proven pattern for a full-bleed region is `position = :absolute, fill = true` on the
    container; inside it, `flex = 1` children divide the remaining main axis normally.
  - `Column`/`Row` are plain `Box` wrappers; `width = 220` on a `fill = true` flex child pins the main-axis
    extent and the other child grows into the remainder (canvas measured exactly `720 − 220 − gap`).
  - Widget accent colors can collide with application drawing colors: Rocks' `:secondary` accent is a
    violet `(153,89,240)` (used by `:outlined` buttons) that a naive "purple leak" detector cannot
    distinguish from canvas strokes. Choose app drawing colors no widget uses — the clip-verification
    sentinels were magenta `(204,38,191)` and the layer colors, and the "purple leak" seen in an early
    scan turned out to be exactly this accent, not a canvas bleed.
  - `Text` has no wrapping — long caption strings overflow their column; split lines manually.
  - **Quirk (observed 2026-10-23, root cause not chased):** a `Box`/`Column` carrying *both* `padding` and a
    fixed `width` inside a flex row drew its background offset by the padding (origin `x+px, y+py`,
    unpadded size) instead of the border box, although `measure!` reports the correct `(x, y, w, h)` and a
    minimal standalone case paints correctly. Workaround, used in `examples/canvas.jl`: keep `background`
    and `padding` on separate elements — background on the outer flexible column, padding on an inner
    `Box`. Worth checking in Rocks if it recurs.
  - **Reactivity lesson**: component re-renders happen only through `@use` subscriptions. Event callbacks
    that arrive through the *draw* path (`on_drag` calls only `mark_window_draw!`) redraw the canvas with
    fresh observable values but never re-run component functions — so `$(observable[])`-interpolated labels
    fed by the same state stay frozen, and only refresh "on the next click" (a press sets other `@use`-owned
    state, which re-renders). Verified with a faithful replay of `render()`'s loop: pre-fix, pressing
    re-ran the app once and five drag moves re-ran it zero times; after adding
    `zoom = @use view_zoom; panx = @use view_panx; pany = @use view_pany` in the app, each drag move
    re-runs it. The fix pattern: subscribe the owning component to the same observable it derives labels
    from (`@use someGlobalObservable` is explicitly supported).
  - Don't write `zoom = @use zoom` — assigning a *new local* with the same name as the module-level
    observable makes the macro's RHS closure resolve the name to the (not yet assigned) local →
    `UndefVarError` at first render. Name the module-level state differently (`view_zoom`) or qualify the
    RHS (`@use Main.zoom`).

**Verified (headless, `SDL_VIDEO_DRIVER=dummy`):** `examples/canvas.jl` is a two-column app fragment: canvas
left (grid, hatched region, closed thick red rectangle outline, filled triangle, canvas text with the live
zoom factor) and a padded control panel right ("Reset Zoom", "Focus Rectangle", ±zoom buttons,
zoom/pan/origin labels, all padded via an inner Box) — see
`analysis/images/screenshots/Rocks-Canvas-Demo.png`. Containment is stress-tested: the grid spans far
beyond the viewport in all directions; during the magenta-overshoot era of the demo, dedicated strokes
extending 40 px past the canvas on every side mirrored the grid test, and pixel-scans of the panel region
found **0** app-color pixels outside the canvas, for both the default view and a
`zoom = 40 / pan = (100, 3000)` stress view. Those dedicated strokes were removed once verified (they read
as visual clutter); the pixel-scan methodology (exact app colors channel-strict, panel region `x ≥ boundary`)
stays the containment regression check for the Workspace — note neutral dark-on-light text antialiasing
looks like `g ≈ r, b ≈ r + 4`, so app-specific hues, not pale neutrals, make unambiguous sentinels. Current
stress screenshots: `Rocks-Canvas-Demo.png` (default view) and
`Rocks-Canvas-Zoom40-ClipTest.png` (`zoom = 40 / pan = (100, 3000)`). Reproduce with:

```julia
SDL_VIDEO_DRIVER=dummy ROCKS_SCREENSHOT=out.png julia --project=. examples/canvas.jl
# stress variant: ROCKS_CANVAS_ARGS="40,100,3000" (zoom 40, pan (100, 3000))
```

**Integration blueprint for the BlazeCraftGUI Workspace:**

1. **State placement (project convention):** keep state as close to the leaves of the component tree as
   possible, and use global state only when it then stays simple. The view state (zoom, pan) is therefore
   owned by the smallest component that is a common ancestor of all its consumers via `@use` — in the demo
   that is `App` itself (canvas callbacks + control panel); in BlazeCraftGUI it will be the `Workspace`
   component, seeded from keyword arguments. The `draw` callback receives state as *arguments* resolved by
   the caller (`(ctx) -> draw_workspace(ctx, zoom[], panx[], pany[])`), never by reaching into module
   globals. Module scope holds only constants (scene geometry, layout constants).
2. The `Workspace` component holds the `Observables` for pan (x, y) and zoom; the `draw` callback maps world
   (laser, y-up, mm) → canvas-local (screen, y-down, px) per frame: `local = world * zoom + pan`,
   `y` flipped. Cache flattened shapes outside the callback.
3. The owning component must subscribe to the view observables (`zoom = @use view_zoom`) so that
   `$(observable[])`-derived labels update live during drag/wheel — without a subscription those events
   only mark the window for redraw (the canvas updates, labels freeze until the next click).
4. Interactivity: wrap the drawing canvas in a `MouseArea` carrying
   `on_down` (record the pan at drag start, set a dragging flag), `on_move`
   (move pan while pressed — it also fires on plain hover, so the flag gates
   it), `on_up` (clear the flag) and `on_wheel` (zoom-at-cursor by solving
   `pan` so the world point under the pointer stays fixed). The `dragging`
   flag and the drag-start store are silent `@use Ref(...)` state (React's
   `useRef`): hook-stable identity across re-renders, no re-renders on
   writes.
5. Hit-testing (node/shape picking) is done by BlazeCraftGUI itself in closed form (transform pointer into
   world space, distance to PolyLine segments / bbox test) — Rocks only reports canvas-local coordinates.
6. The color bookkeeping mirrors the palette table (`02-` §4.1): one stroke color per layer.
7. **Headless-testing seam:** `render(App; kw...)` forwards the keyword arguments to the root component
   (`create_root(app, kw)` → the app is called with them; only `frames`/`screenshot` are consumed), so an
   app can accept seeding kwargs (`initial_zoom`, …) and tests can drive it directly without exposing any
   state, e.g. `render(App; initial_zoom = 40, screenshot = …)`. `examples/canvas.jl` also accepts
   `ROCKS_CANVAS_ARGS="zoom,panx,pany"` for shell-driven test runs.

---

### 2.12 `MouseArea` — the single interaction primitive (refactor 2026-10-23)

After living with the `Canvas`-as-pressable design, Rocks was restructured: **all mouse interaction now
belongs to one `MouseArea` host kind**, and the `Canvas` is a pure drawing surface again. This removes the
per-control pointer special cases (canvas pressability, wheel precedence, cursor branching) and makes
controls composable instead of atomic.

**What changed (API view):**

* New exported primitive **`MouseArea`** — lays out like a neutral `Box`, renders its children with *no
  styling of its own*, and takes all mouse callbacks plus `disabled` and `cursor`.
* **`Pressable` is a legacy synonym** of `MouseArea` (`MouseArea === Pressable`), so every existing
  control, Material3/Mechanics/Enterprise widget and test keeps working unchanged; prefer `MouseArea`
  in new code. The fiber kind is `_MouseAreaKind` — tests that matched `kind === Pressable` still match.
* **`Canvas` lost all pointer props** (`on_press*`, `on_drag`, cursor defaults). Hit-testing aa canvas
  returns the canvas fiber, but `find_pressable` walks up to the enclosing `MouseArea`. To make a canvas
  interactive: `MouseArea(Canvas(...); on_*, cursor)` — with a single child the wrapper **buffers the
  canvas exactly** (see layout rule below), so the area-local callback coordinates equal the
  canvas-local draw coordinates, and pan/zoom handlers reuse the draw transform unchanged.
* **All mouse coordinates are area-local** (`0,0` = area top-left). This is a *semantics change* for the
  legacy press callbacks (they used to see window coordinates): `TextBox` was adapted to convert
  local→window with its own fiber offset, so it keeps its caret/right-click-menu behavior.

**Callbacks** (verified by the new "mouse area" testset, 18 tests):

| prop | fires when | args |
| --- | --- | --- |
| `on_down` | button pressed in the area | `(x, y, button)` |
| `on_up` | pressed button released — on the area the press *started* in, even off-area | `(x, y, button)` |
| `on_click` | press released inside the area (legacy `on_press` fires identically) | `(x, y, button)` |
| `on_move` | pointer moves while hovering **and** during a press capture (even outside) | `(x, y)` |
| `on_enter` / `on_leave` | hover enters/leaves (alias `on_hover_in`/`on_hover_out`) | none |
| `on_wheel` | wheel; innermost `:on_wheel` beats scrollable ancestors | `(dx, dy, x, y)` |

Press capture: a press on the area records it in `ACTIVE_PRESS`; motion then goes to *that* area
(area-local coordinates keep accumulating even across its edge — this is what makes pan-drag work), until
the matching button-up pops it. All callbacks accept the 0-arg/2-arg/3-arg arity that fits (the 3-arg
form sees the button; right-clicks arrive on `button = 3`).

**Layout rule** (new `place_mouse_area!` in `layout.jl`): the default path is the ordinary Box flex flow
(`align`/`justify`/`gap` honored — styled controls keep centering their labels). The one special case is
the wrapper use: a single `fill = true` child receives the area's content box **exactly**, so
`MouseArea(Canvas(fill = true))` is visually a no-op wrapper and the child's rect == area rect. With
several children, or a non-fill single child, behavior is plain flow. Absolute children keep normal
overlay placement.

**Composition over magic:** pre-styled controls are unchanged in shape (`Button` performs identical
press styling/tooltips) because they were already `Pressable`-shaped — which now *is* MouseArea. New
controls should be plain function components of `MouseArea` + styled children, e.g.
`MouseArea(Box(Text(...); background = ...); on_click = ..., cursor = :hand)`. Styling props
(`background`, `hover_background`, `pressed_background`, `bevel`, …) remain opt-in on `MouseArea` so the
hover/press state can style the area itself; a bare `MouseArea` stays invisible.

**Gotchas learned:**

* `on_move` fires on plain hover *before* any press — a pan handler must be gated by a dragging flag
  (`on_down` sets it, `on_up` clears it). The flag (and the pan-at-drag-start store) is **silent
  `@use Ref(false)` state** — Rocks' React-`useRef`-equivalent: `@use` creates any `Ref` *or* `Observable`
  once per component instance (the hook keeps it across re-renders, so re-created closures share it) and
  mutating a `Ref` never schedules a re-render. Using an Observable for the flag would cost one spurious
  re-render per press (the toggle itself re-renders the app).
* The canvas demo (`examples/canvas.jl`) needed `flex = 1, fill = true` on the **MouseArea** (the row's
  flex item is now the wrapper, not the canvas) and `fill = true` on the **canvas** (that is what makes
  it exact-fill the area — the single-child-without-`fill` case stays plain flow, because every styled
  control is also a MouseArea and must keep its flex centering). No other layout change.
* Suite is at **481 tests, all passing**; the headless renders of the demo are **byte-identical** to the
  pre-refactor verified screenshots (`Rocks-Canvas-Demo.png`, `Rocks-Canvas-Zoom40-ClipTest.png`),
  including the 5-drag-move live-label replay (5/5 component re-runs, `ACTIVE_PRESS` entries now
  `_MouseAreaKind`).
* **Popup-overflow hit-test rule (found while chasing "ComboBox not clickable"):** `E.ComboBox`'s dropdown
  popup is an absolutely-positioned Box *outside* the component's own rect (`overflow = :visible` on the
  output box). `hit_test` used the *call-site* props to decide clipping, and component fibers carry no
  `overflow` prop, so the default `:hidden` blocked descent into the popup — clicks (and hover) on
  dropdown **entries** were unreachable, on both MouseArea and Pressable code. Pre-existing bug, fully
  reproducible on git history; verified not introduced by the refactor. Fix now applied in
  `events.jl::hit_test`: **non-host fibers (components) default to `:visible`**, host fibers keep
  `:hidden` + explicit `:visible` punch-through — matching how rendering descends through the output.
  Regression tests added: a generic component-overflow popup click and an end-to-end
  ComboBox pointer-click test (synthetic down/up → arrow opens, entry selects + closes). Probe lesson:
  the generated suite's own control tests call `props[:on_press]()` directly, so they skip `hit_test`
  entirely; any popup/dropdown behavior needs the synthetic-event path (`push_mouse!`/`drain_events!`).
  Warning: a testset that drives `sync_windows!` on a component whose root is not a `Window` (e.g.
  `E.Column(...)` with no `@rock Window(...)`) gets an *empty* window list — wrap pointer-driven tests
  in a `Window`.
* **ComboBox dropdown is now a borderless OS popup window** (same mechanism as `MenuBar`/`ContextMenu`,
  `menu_popup`-style: `Window(...; position = :manual, x, y, popup = true, menu_open = open)`). The
  inline `overflow = :visible` popup inside the field's output box was cut off by the owner window
  ("Fix box overflow issues" made overflow clip aggressively); the OS popup is never clipped by owner,
  ancestors, or the window edge. Implementation facts:
  - **Anchor at event time**: the toggle callback resolves the field's placed rect through
    `use_fiber()` (`self.children` → output box → first `_PRESSABLE` child) and writes `popup_x/pop_y`
    `@use Ref`s *before* setting `open[] = true` — render specs have no geometry, and the popup window
    reads the Refs when it mounts on the re-render.
  - **Toggle with `was_open`**: `close_open_menus!` flips the popup's `menu_open` (`= open`) between
    press and release (DOWN closes, UP toggles), so a naive `open[] = !open[]` instantly reopens a
    just-clicked-shut dropdown. Capture `was_open = open[]` at render time and decide on that.
  - **Long lists**: popup height caps at 300 px; when capped, the rows box gets `scroll = true,
    scrollbar = true` (rows shrink by `t.metrics.scrollbar` so text stays clear of the scrollbar).
  - **Popup-window tests**: entries live in the popup's OS window — `push_mouse!` must be called on the
    entry fiber (it resolves its own window, not the main one); DOWN and UP must go to the *same*
    window, else `ACTIVE_PRESS` keys `wid × button` don't match and the click silently does nothing.
  - Verified end-to-end headlessly: open → close (arrow again) → reopen → outside-click closes →
    entry select; long list caps at 300 px with one scrollable box. Suite: **484/484**.


---

## 3. BlazeCraft.jl — how to use it

> The module (`src/BlazeCraft.jl`) currently includes only: `transform.jl`, `shapes/`, `importers/`, `processes/`,
> `arrange.jl`. **`gcode_recorder.jl` and `sinks/` are commented out from the module** — the `Sinks.Moonraker`
> submodule exists on disk but is not yet `include`d.

### 3.1 Shapes & transforms

```julia
using BlazeCraft
using BlazeCraft.Shapes: PolyLine, Rectangle, RegularPolygon, MultiShape, Point, BoundingBox, flatten
using BlazeCraft: Rot, Pos, Scale, align

r  = Rectangle(20, 10)
pl = PolyLine([Point(0,0), Point(1,1), Point(2,0)], false)   # points::Vector{SVector{2,Float64}}, closed::Bool

composed = Pos(5, 5) * Rot(45) * r          # lazy transform (CoordinateTransformations), applied with *
flat    = flatten(composed)                 # → Vector{PolyLine}, materialises lazy transforms, unwraps MultiShape
bb      = BoundingBox([r, pl])              # min::Point, max::Point
aligned = align([r, pl]; x = :center, y = :max)   # shifts to :min/:center/:max (aliases left/right/top/bottom)
```

* **Lazy by design** — a `TransformedShape` wraps the original; `flatten` is where it becomes real. Compose freely.
* **Clipper-based booleans** (100× integer scaling via `asInts`/`asFloats`): `a ∪ b` (union), `a - b` (difference),
  `intersect(a, b)`. Result is a `MultiShape` of `PolyLine`s.
* `offset_fill(shapes, line_width; include_original=true)` — inward contour fill (Clipper `ClipperOffset`, round
  joins) → underlying *offset fill*-style geometry. **This is the seed of "Offset Fill mode".**
* `zigzag_slice(polygons, interval)` — scanline hatch generation (already serpentine: even rows right-to-left).
* `PolyText("Hi")` — text → vector outlines (Luxor).
* Shapes are `PlotUtils`/Makie-plottable via a recipe (not wired into the GUI here, but available for the canvas).

### 3.2 Processes (tool-path generation)

```julia
using BlazeCraft.Processes: OutlineCut, ScanlineFill, offset_fill, Move, generateMoves, generateCutMoves

cut  = OutlineCut([rect], Dict(:power => 1000, :cut_speed => 20, :travel_speed => 200, :z => 0))
fill = ScanlineFill([rect], Dict(:hatch_angle => 0.0, :hatch_spacing => 0.1,
                                 :overscan_length => 1.0, :z => 0.0,
                                 :power => 1000, :cut_speed => 20, :travel_speed => 200))
moves = generateMoves(cut)     # Vector{Move} — hand-inserts overscan + travel moves
```

* `Move(from::SVector{3}, to::SVector{3}, power::Float64, speed::Float64)` — the atomic unit.
* `AbstractProcess` interface: `generateCutMoves(p)` (the laser-on moves) + `generateMoves(p)` = cuts +
  `fillTravelMoves` (travel + overscan between non-adjacent cut ends).
* `ScanlineFill` already implements **hatch angle** (rotate → `zigzag_slice` → rotate back) and **overscan length**.
* Settings are `Dict{Symbol,Any}` — matches the "settings bag" idea in `09-` §2.3 but note these are per-process
  now, not a general cut-settings model. The full LightBurn cut-settings model (per-mode parameter tables in
  `03-cut-settings-model.md`) has **many more** fields (passes, tabs, kerf, lead-in/out, PPI, PWM, Z ramp…); these
  need to be layered onto the `AbstractProcess`/`generateCutMoves` pipeline.
* `plot(process)` gives a Makie recipe showing cuts + travel colored by power (a quick preview outside Rocks).

### 3.3 Importers

```julia
using BlazeCraft.Importers: load_dxf_instructions, extract_structured,
                            extract_polys, weld_contours, load_svg

inst   = load_dxf_instructions(io)                 # raw DXF entities
units  = extract_structured(inst; tol = 1e-3)      # Vector{DXFUnit}: :layer/:block/:group units
polys  = extract_polys(inst)                       # Dict{layer_name, Vector{PolyLine}} — flat, welded view
welded = weld_contours(layer_poly_pairs; tol = 1e-3)  # endpoint chains → one poly each
ms     = load_svg(str_or_io; flip_y = true, tolerance = 0.01)   # path/polygon/polyline/rect + transform; XML.jl
```

* SVG importer handles `path/polygon/polyline/rect` with `transform`, groups → nested `MultiShape`, and **adaptively
  subdivides curves to a `tolerance`** (already the right shape for LightBurn's Curve-Tolerance model — default the
  resolution up for output vs. display as needed).
* DXF importer is instruction-level + **structured** extraction (`extract_structured`): layer buckets, exploded
  `INSERT` instances (affine placement, nested recursion, `MINSERT` arrays) and `ACAD_GROUP` memberships, each a
  `DXFUnit`; `extract_polys` is its flat layer-keyed collapse. **Contour welding** (`weld_contours`, default
  tolerance a µm) runs per layer bucket / per exploded instance: chains of endpoint-sharing primitives become one
  poly each — closed when the chain's ends meet. No exporter exists yet (DXF/SVG/AI export, machine-file
  export, and the `.lbrn2`-equivalent format are all to be built — see `08-file-formats.md`).

### 3.4 Sinks

`src/sinks/moonraker.jl` provides a Moonraker (Kalico) WebSocket sink with backpressure and whole-job upload — but
it is **not included in the module** (`#include("sinks/main.jl")` is commented out). Decide early whether to wire
it in (and whether the project targets Kalico/Moonraker, raw GRBL serial, or LightBurn Bridge). The driver layer in
`05-device-driver-architecture.md` will need a `Sink`-per-driver arrangement here.

### 3.5 BlazeCraft limitations relevant to this project

1. **`PolyLine` (point list) only — no bezier/arc/bulge segment model and no node/handle editing.** Every curve is
   flattened at import time (`tolerance`). The LightBurn model (`02-`/`04-`) is nodes-with-handles + arcs. Decide:
   keep BlazeCraft polygonal (flatten everything, fine for output, but editing fidelity suffers) or add a curve
   segment type. `09-implementation-roadmap.md` §2.2 discusses running both a `Path` and keeping `PolyLine`.
2. **No fill "even-odd within layer across shapes" beyond raw union/`zigzag_slice` on the raw shapes.** The geometry
   semantics in `07-` §1.1–1.2 (same-layer even-odd, cross-layer superposition) are **not** implemented yet — the
   GUI must resolve a layer's fill region (via Clipper `EvenOdd` on that layer's shapes) before calling `zigzag_slice`.
3. Processes cover only **outline + scanline + offset-fill**; passes, tabs, kerf, lead-in/out, image-mode raster,
   PWM/PPI, Z-ramp, and optimisation ordering are all yet to build (see `03-` and `09-`).
4. Kappel/Clipper is **integer** (100× scaling) — precision is `0.01` units at scale 100; fine at mm but be aware
   for very large or high-precision designs.
5. `import BlazeCraft; using BlazeCraft.Shapes` — exports are namespaced; `BlazeCraft` itself re-exports
   `Rot/Pos/Scale/align` at top level, plus the submodules.

---

## 4. Integration blueprint

### 4.1 The Observable Document store

```julia
# GUI-side: holds the live domain model.
struct BlazeDoc
    shapes::Vector{Any}          # BlazeCraft.Shape (PolyLine/MultiShape…)
    layers::Vector{BlazeLayer}   # colourIndex, mode, cutSettings
    origin::Tuple{Float64,Float64}
    # ...
end

const Document = Observable(BlazeDoc(...))   # or a handful of focused Observables
```

A component does `doc = @use Document` — any mutation (`Document[] = newdoc`) re-renders the whole app, keeping the
Cuts/Layers window, palette, and preview consistent. For finer granularity, `map(x -> x.layers, Document)` gives a
derived observable that re-renders only when layers change.

### 4.2 Shell = Enterprise.Form

Reproduce the LightBurn A–H layout (`02-ui-inventory.md` §1.1) with `E.Form`:

| LightBurn region | Enterprise mapping |
|---|---|
| Menus (E) | `menu = @rock E.MenuBar(menus = […])` |
| Main + Arrange toolbars (C) | `toolbar = @rock E.ToolBar(children…)` with `E.ToolButton`/`E.ToolSeparator` |
| Workspace (A) | the native `Canvas` element between the panes (see §2.11) |
| Cuts / Layers (G) | `E.TabControl` or docked right pane with `E.ListView` rows + `E.GroupBox` |
| Laser window (H) | right-bottom docked pane |
| Color palette (F) | a bottom `Box`/status row of 30 `E` swatches (`Pressable`) |
| Status bar | `status = @rock E.StatusBar(panels=[StatusPanel(text=…), …])` |
| Dialogs | `E.MessageBox` passed as `overlay`; `E.ContextMenu` for right-click |

**Docking** is the one thing Enterprise does not ship (it has `SplitContainer` for panes but no draggable
dock/tab-strip system). The plan in `09-implementation-roadmap.md` §0.3 (declarative `PanelSpec` registry +
flexbox/absolutes + `Split`/`TabControl`) applies directly here.

### 4.3 Data flow on "Start"

1. GUI holds the Document (shapes + per-layer cut settings) as Observables.
2. On Start/Preview: `for layer in doc.layers` → pick `OutlineCut` (Line mode), `ScanlineFill` (Fill), `offset_fill`
   group (Offset Fill), or a future image rasteriser (Image mode); each with per-layer settings resolved from the
   layer's `Dict`.
3. `moves = vcat([generateMoves(p) for p in processes]...)` → hand to a BlazeCraft `Sink` (or GCode writer) for the
   machine, or to a Preview component that draws the moves.
4. Full-fidelity needs the `03-`/`09-` extensions (passes, tabs, kerf, ordering, optimisation) built as a layer on
   top of `AbstractProcess`.

### 4.4 Rendering split: native `Canvas` vs Luxor→`Image`

Since Rocks now has the native `Canvas` (§2.11), the **interactive Workspace** draws directly: the `draw`
callback maps world→canvas-local coordinates and emits `ctx.polyline`/`ctx.polygon` from cached flattened
`PolyLine`s. Keep Luxor for the **offscreen, non-interactive** renders (the Preview window, exports,
thumbnails) — the full-frame bitmap path is still the right tool there:

```julia
using Luxor
function render_scene(doc, w, h)
    Drawing(w, h, :png)          # or to a buffer
    origin(0, h)                 # Luxor origin bottom-left; y-up like G-code
    for (i, s) in enumerate(doc.shapes)
        setcolor(layer_colour(doc, i))  # from the palette table (02- §4.1)
        # draw flatten(s)
    end
    finish()
end
```

then feed the PNG to an `@rock Image(src = buffer)`. Re-render when `Document` changes. Rule of thumb:
**interactive → `Canvas` (SDL, per-frame vector); print-quality/offscreen → Luxor→PNG→`Image` (per-change
raster).** Preview move-display can use either; start with `Canvas` since `generateMoves` output is already
polylines.

---

## 5. Concrete Things To Build (mapped to the two libs)

| Feature (from analysis) | With BlazeCraft | With Rocks |
|---|---|---|
| Project + layers + palette | `BlazeDoc` / layer structs | `Observable` store; `E.ListView` Cuts/Layers; palette `Pressable` swatches |
| Line cut | `OutlineCut` + `generateMoves` | settings in `E.GroupBox`; params via `E.TextBox`(Observable) + `E.ComboBox` + `E.Slider` + `E.CheckBox` |
| Fill cut | `ScanlineFill` (+ resolve even-odd region first) | same settings UI |
| Offset Fill | `offset_fill(...)` | — |
| Preview | `generateMoves` → draw moves | `Canvas` (interactive) or Luxor→`Image` (see §4.4) |
| Import DXF / SVG | `Importers` | `E.MessageBox` + native file dialog (or a small file picker) |
| Booleans / arrays / offset | Clipper ops + loops | toolbar `E.ToolButton`s |
| Cut settings editor | extend settings dict per `03-` | `E.TabControl` (Common / Advanced) inside a dialog |
| Material test / focus / interval | grid generators → `ScanlineFill` | `E.Form`-based wizards, `E.ListView`/`E.GridView` output |
| Machine output | (wire in `Sinks`/Moonraker or new GCode writer) | `E.StatusBar` connection state; progress |
| Menus / toolbars / status | — | `E.MenuBar` / `E.ToolBar` / `E.StatusBar` |
| Dockable panels | — | custom `PanelSpec` registry + `Split`/`TabControl` |

---

## 6. Verified by running (2026-10-23)

Both libraries were loaded in **this** project (`BlazeCraftGUI.jl`) and exercised headlessly. Evidence:
`analysis/images/screenshots/BlazeCraftGUI-SmokeTest.png` is a real capture produced with
`SDL_VIDEO_DRIVER=dummy`.

| Check | Result |
|---|---|
| `Pkg.instantiate()` in `BlazeCraftGUI.jl` | Rocks + BlazeCraft + SDL3 precompile cleanly (deps present in the Manifest). |
| `generateMoves(OutlineCut([rect], Dict{Symbol,Any}(:power=>1000,:cut_speed=>20,:travel_speed=>200)))` | **4 moves** (the rectangle outline). |
| `generateMoves(ScanlineFill([rect], Dict{Symbol,Any}(:hatch_spacing=>1.0,:overscan_length=>0.5)))` | **37 moves** (hatch + overscan + travel). |
| `BoundingBox(Pos(5,5) * rect)` | transforms apply lazily & materialise. |
| `r ∪ r` → `flatten` | Clipper booleans produce `PolyLine`s. |
| Headless `E.Form(MenuBar + StatusBar + GroupBox)` via `render(Smoke; frames=3, screenshot=…)` | renders and writes a real PNG with no display. |

### Two gotchas discovered while verifying (worth remembering)

1. **Process constructors take `Dict{Symbol,Any}`**, not a narrower `Dict{Symbol,Float64}` etc. Passing a typed
   dict throws `MethodError`. Use `Dict{Symbol,Any}(...)` (or `Dict{Symbol,Any}(:k => v, …)`).
2. **A `@rock` element cannot be inlined directly as a prop value** — build menu/toolbar/status/dialogs into
   variables first, then pass them, e.g. `menu = menubar_el` (this is documented in `examples/enterprise.jl` and
   bites immediately). Purely numeric/string props are fine inline.

---

## 7. Quick sanity-run

```sh
# Rocks headless (no display):
cd Rocks.jl && SDL_VIDEO_DRIVER=dummy julia --project examples/enterprise.jl

# BlazeCraft tests:
cd BlazeCraft.jl && julia --project -e 'using Pkg; Pkg.test()'
```

---

## 8. BlazeCraftGUI v1 — import & display on the Workspace (implemented 2026-10-24)

Phase 0/1 start of the roadmap (`09-implementation-roadmap.md`): the app shell + the Workspace
`MouseArea(Canvas)` + file import, proven end to end (UI flow, pan, wheel-zoom, error path; 24/24 unit tests).

### 8.1 Files & roles

| File | Role |
|---|---|
| `src/BlazeCraftGUI.jl` | module; re-exports `App`, `ArtObject`, `import_art`, `run_gui`, `FileDialogResult`, `show_open_file_dialog!`; `run_gui(; kw…) = render(App; kw…)` |
| `src/document.jl` | `ArtObject` (one document entry: unique `id`, `kind` `:shape`/`:group`, name, flattened `PolyLine`s, layer color, group `children` ids), `import_art(path)` (SVG via `BlazeCraft.Importers.load_svg`, DXF via `load_dxf_instructions` + `extract_polys`, merged+`flatten`ed once at import), `center_on_workarea`, `document_bounds`, the group helpers (`is_group`, `art_index`, `child_indices`, `leaves_of`, `resolve_leaves`, `parent_group`, `top_level_indices`, `art_bounds`, `group_arts`/`ungroup_arts`/`delete_arts`, §8.15), `layer_color` (LightBurn palette `00`=black, `01`=blue, `02`=red…), `WORK_AREA_MM` |
| `src/camera.jl` | `Camera(translation, rotation, scale)` — StaticArrays `SVector`/`SMatrix`; `matrix(cam)` builds the 3×3 affine (translate ∘ rotate ∘ scale with the baked-in y-flip), `apply(m, p)`, `zoom_at` (unprojects the cursor through `inv(matrix)` so the world point under it stays fixed), `pan` |
| `src/workspace.jl` | the `Workspace` component: `MouseArea(Canvas)` with pan, wheel-zoom, **selection** (clicking a shape's line selects *its group* — `hit_shape` point-to-segment distance in world mm, the click unit mapped through `parent_group`; Shift toggles at unit level), group-aware marquee (`shapes_in_rect` on the top-level entries: a group acts like a single shape), the marching-dash selection outline in each shape's **layer colour** (a selected shape keeps its own colour — `draw_dashed_polyline`, phase-advanced by a 100 ms `useInterval`, resolved through `resolve_leaves`), the dashed union bounding box and the transform handles (corner squares scale about the opposite corner, the center square translates, the outside rotation handles rotate about the bbox center), the right-click `ctx_open` flip (§8.15); the world-space geometry (bed corners + grid segments) is constant and transformed per frame through the camera matrix; `fit_camera` fits the union of the 300×300 mm work area and the document |
| `src/filedialog.jl` | `show_open_file_dialog!` — SDL3's native OS dialog (async: the callback only fills an Observable; the main thread consumes it during the next render, where the import runs) |
| `src/app.jl` | `E.Form` shell: menu bar, the **Position toolbar** (the 3×3 origin grid, X/Y position and W/H size spinners via `E.Spinner`, the aspect lock — spinners resolve groups to their subtree union), `DocStatus` status bar, the Workspace with the **LayerBar strip below the canvas** (§8.14), the right dock as a **TabControl** ("Cuts / Layers" page + "Outline" page, §8.15), `WorkspaceContextMenu` (Group/Ungroup over the selection) and the error MessageBox; app-level `doc`/`selection`/`origin`/`lock`/`panel_tab`/`ctx_open` Observables (may be passed in by tests) |
| `src/outline.jl` | `OutlinePanel` (§8.15): the document outline — an indented tree of every entry with members under their group (shapes a layer-coloured square, groups an outlined box mark); a row click selects exactly that entry; rows scroll in a `ScrollView` |
| `examples/blazecraft.jl` | entry point; `ROCKS_SCREENSHOT=… SDL_VIDEO_DRIVER=dummy …` headless runs |
| `test/runtests.jl` | unit tests (import, bounds, palette, summary, camera matrix/zoom_at/pan, `fit_camera`) — 34/34 |
| **SDL3.jl** (`~/Development/SDL3.jl`) | **new `src/dialog.jl`**: the SDL_dialog.h wrapping — `SDL_DialogFileFilter`, `ShowOpenFileDialog`/`ShowSaveFileDialog`/`ShowOpenFolderDialog`/`ShowFileDialogWithProperties` (892/896 tests pass, 4 broken pre-existing). BlazeCraftGUI's `[sources]` points SDL3 at the local checkout. |

### 8.2 Verified end to end (2026-10-24, headless probes in `/tmp/opencode/`)

| Probe | Result |
|---|---|
| `blzc_dialog_probe.jl` — native dialog: the callback-shaped result set into `pending_open`, then the real async `SDL_ShowOpenFileDialog` cbind | consume path imports and displays (`shapes.svg: 3 outlines`); the real cbind fires the callback headlessly (error → `filelist=NULL` → "Import failed" MessageBox). Live (zenity present) the dialog is the real OS one. |
| `blzc_pan_probe.jl` — drag + wheel-zoom on the Workspace | content pans; zoom-at-cursor keeps the world point under the cursor fixed (`blazecraft-pan.png`, `blazecraft-zoom.png`) |
| Seeded import (`blazecraft-import-fitted.png`) | rect + arc-path circle + triangle **centered on the work area** (`center_on_workarea`), fit covers the union of the bed and the content |
| `blazecraft-empty-shell.png` | the 300×300 mm work area with 10 mm grid lines and thicker 100 mm majors |

### 8.3 New gotchas discovered while building this (all verified empirically)

1. **Spaced `@rock X(...)` followed by a comma + keyword parses as a *chained tuple assignment***:
   `f(@m g(x), y = 3)` parses as `@m((g(x), y) = ((3, z) = 4))` — the macro swallows the whole tail. Any
   `@rock X(...)` that is followed by more call arguments must be wrapped in its own parentheses:
   `(@rock Workspace(doc = doc))`. This is what "a `@rock` element cannot be inlined as a prop value" (§7)
   actually meant. Pure `@m g(x); k = v` semicolons and macrocall-comma-macrocall lists are fine.
2. **`E.Form` is keyword-only**: children go through `children = Any[…]`, *not* positionally; menu/toolbar/status
   are props. Also: **`Form` unconditionally sets `props[:fill] = true` on `status`/`toolbar` when they are
   Elements** — a status *component* therefore receives `fill = true` as a kwarg and must accept + forward it
   (`DocStatus(; doc, fill = false)` → `E.StatusBar(; fill = fill, …)`).
3. **Inside a `Form`'s ScrollView the client column never gives `flex` space to grow into**: a workspace
   component needs `flex = 1, fill = true, height = "100%"` (percent of the scroll viewport) — plain `flex = 1`
   collapses to zero height and the Canvas draws nothing.
4. **Rocks re-runs EVERY component body on each dirty render** (`update!` → `perform_render!` cascades the whole
   tree on every reconciliation). Consequences:
   - any state a component must keep across frames **has to be hook state** (`@use Observable`/`@use Ref`);
     plain `Observable(...)` locals are re-created per render and callbacks would write into a dead instance.
     This bit twice: dialog `open` flags in `App` (dialogs never appeared until they became `@use` state) and
     the Workspace view Refs (pan/zoom silently reset).
   - a leftover plain assignment *shadowing* the hook binding (`open_dialog = Observable(false)` after
     `open_dialog = @use Observable(false)`) silently splits the state in two. Beware when editing.
   - "did this run happen because of mount or because of a doc change?" cannot be answered in the body — use
     **`useEffect` with deps** (`useEffect(() -> fit_pending[] = true, (doc[],))` refits exactly when the
     document changes; body-run logic cannot distinguish).
   - plain-`Ref` view state only works for *draw-only* updates (mouse events mark the window for redraw
     without re-render); the moment any other re-render happens the values are gone.
5. **`@use` returns the FIRST instance** on later renders ("the expression is evaluated exactly once"), so
   `x = @use x` works, but any *other* re-binding of `x` afterwards breaks it (gotcha 4's shadow trap).
6. **`sprint(showerror, err; context = :compact)` is invalid** — `sprint`'s `context` kwarg takes
   `IOContext` pairs (`:compact => true`), not a `Symbol`. It throws inside callbacks and silently kills the
   action (events.jl only logs a warning). Plain `sprint(showerror, err)` is fine.
7. **BlazeCraft's SVG importer handles `g/path/polygon/polyline/rect` only** — no `circle`/`ellipse`/`line`.
   Arc-circle test art must be written as a `path`. (Roadmap §1 lists curve generalisation as an extension.)
   The **DXF importer (extended 2026-10-24) handles `POLYLINE`, `LWPOLYLINE`, `LINE`, `CIRCLE`, `ARC` and
   `SPLINE`** (flattened through de Boor's algorithm, rational weights honoured) — modern ezdxf/AutoCAD files
   use those entities, not the legacy `POLYLINE`. Two pitfalls fixed with it:
   - the group-code parser must accumulate **repeated codes as vectors** (`Dict{Int,Vector{String}}`) — a
     plain `Dict{Int,String}` silently keeps only the last control point/vertex;
   - the NURBS Book's A2.3 basis-function loop, translated 1-based, reads `right[r+2]` (the book's 0-based
     `right[r+1]`) — using `right[r+1]` reads an *unassigned* array slot (garbage memory → NaN curves), which
     `undef` allocation surfaces where a zero-initialised language would silently pass.
   LWPOLYLINE bulges (code 42) are not evaluated yet.
8. **`E.Form`'s status panel: `E.StatusBar(grip = false, fill = fill, panels = …)`** — the bar stretches across
   the window through the forwarded `fill`, panels are `E.StatusPanel(text = …)`.

### 8.4 Gotchas from the SDL3-dialog / camera round (2026-10-24, later)

9. **Rocks cached system cursors across SDL sessions**: `shutdown_backend` invalidated fonts/surfaces but not the
   cursor Refs — `SDL_QuitMouse` destroys them, so a second `run_gui()` in one session reused dangling pointers
   and SDL 3.4's `SDL_SetCursor` (which validates the cursor against the current mouse) threw *"Cursor not
   associated with the current mouse"*, killing the event loop on canvas hover. Fixed in Rocks: the cursor Refs
   reset on shutdown, and `update_cursor` tolerates a failed `SetCursor` (warn once, mark cursors unavailable).
10. **An `@cfunction` created during precompilation produces a stale pointer**: a module-level
    `const CB = @cfunction(…)` in a package segfaults when C calls it at runtime (SDL invoked the dialog
    callback synchronously after zenity failed). Create the `@cfunction` *inside the function that uses it*.
11. **`SDL3.Window` is a type alias for `Ptr{SDL_Window}`** — wrapping again (`Ptr{SDL3.Window}`) makes a double
    pointer; SDL then dereferences a garbage "window" and segfaults. Wrap once: `SDL3.Window(C_NULL)`.
12. **`Observable(nothing)` infers `Observable{Nothing}`** — a state that later holds other values must be typed
    explicitly: `Observable{Union{Nothing,FileDialogResult}}(nothing)`.
13. **Deltas vs absolutes**: a `pan(camera, dx, dy)` helper takes *deltas* — passing an absolute drag target
    re-adds the old translation every move and the view runs away. Set the translation directly for
    drag-from-grab-offset.
14. **Sub-pixel SDL lines rasterize unreliably**: a 1 px `RenderLine` at a fractional x vanishes or flickers
    between raster rows while panning (verticals are the visible case). Snap axis-aligned transformed lines to
    whole pixels; draw non-axis-aligned lines as-is.
15. **Julia probe gotchas**: soft-scope in top-level `for`/`while` loops silently splits the variable (use
    functions or explicit `global`); `isapprox(x, 0.0)` needs an explicit `atol` (rtol alone compares against
    x itself); `sprint(f, …; context = :compact)` is invalid (see 6).

### 8.5 Gotchas from the live-run round (2026-10-24, later still)

16. **A `Vector` of *mutable* structs stores pointers to boxed objects** — a C API expecting an array of
    *inline* structs reads a pointer as the first field and garbage after it. SDL's filter validation then
    fails with "Invalid character in pattern" (or worse). `SDL_DialogFileFilter` is therefore an *immutable*
    (isbits) struct: a `Vector` stores the data inline. (The "mutable structs use the same padding rules" note
    in SDL3.jl's `filesystem.jl` applies to a *single* struct passed by `pointer_from_objref`, not to arrays.)
17. **Never capture C pointers at precompile time**: a module-level const array built with `pointer(string)`
    during precompilation holds pointers into precompile-era memory — stale at runtime (segfault in SDL).
    Build pointer-holding structs at *runtime*; root the Julia strings as module constants; keep the array
    alive until the callback fires (a module `Ref` cleared by the callback).
18. **Rocks' hardcoded cursor ids**: `_SDL_SYSTEM_CURSOR_GRAB`/`GRABBING` were 21/22, but SDL 3.4's
    `SDL_SYSTEM_CURSOR_COUNT` is 20 — `SDL_CreateSystemCursor` with an out-of-range id reads out of bounds and
    corrupts SDL's cursor list, after which `SDL_SetCursor` rejects *every* cursor ("Cursor not associated with
    the current mouse"). Rocks now uses `SDL_SYSTEM_CURSOR_MOVE` for pan.
19. **SDL 3.4's Unix file dialogs use the XDG desktop portal over DBus** — zenity/kdialog support was dropped.
    A session bus and a running `xdg-desktop-portal` are required, and SDL needs `PumpEvents` in the main loop.
    When it fails, the callback fires with `filelist = NULL` and the reason in `SDL_GetError()` (surfaced in
    the app's error box).

### 8.6 The targeted re-render + the dash-loop hang (2026-10-25)

**Rocks re-renders are now targeted** (the architecture the user asked for): changing an Observable
re-renders only the fiber(s) that subscribed to it (React-style: the component that "uses" the state, plus
its subtree) instead of the whole application.

- `@use`'s subscription captures the owning fiber (`CURRENT_FIBER` at subscribe time) and calls
  `mark_dirty!(fiber)` — the fiber lands in `Rocks.DIRTY_FIBERS` — instead of the global `request_render()`.
- The runtime loop processes the dirty fibers (`flush_dirty!()`): `perform_render!(fiber)` per fiber subtree
  (the component function + its children reconciled — the whole subtree, React-like), the window marked for
  redraw, until the values settle (a body may write another observable). Fibers covered by an already-flushed
  ancestor are skipped.
- `request_render()` remains the global escape hatch (the whole tree).
- The selection screenshot earlier in this file was taken *before* this change; the behavior is unchanged,
  only the re-render scope.

**The dash-loop hang**: `draw_dashed_polyline`'s emission loop could advance by ~0 when the pattern boundary
landed exactly on a segment position (`dash - offset ≈ 0` or `period - offset ≈ 0` in Float64) — an
effectively infinite loop on paths with many tiny segments (the example.dxf engraving). Fixed with a 1e-6
minimum advance. The animation is now also **draw-only**: a 100 ms `useInterval` calls
`Rocks.request_redraw()` (new: marks every live window `needs_draw`, no component re-runs), and the dash
phase is derived from the clock in the draw callback — no state, no re-render.

**The GPU/shader question**: the user proposed drawing the dashes with a shader so the geometry is uploaded
once and only the offset changes. SDL3's `SDL_Renderer` (which Rocks uses) has no custom fragment shaders —
that path means SDL_GPU (a device, swapchain, render pipelines and shader binaries), a major Rocks feature.
The current implementation re-emits the dashes from the cached transformed points each redraw (CPU-side,
O(segments)); SDL_GPU remains the follow-up if the throughput ever demands it.

### 8.7 Gotchas from the selection/toolbar round (2026-10-24)

**The Form is now a column flow (2026-10-25)**: the bars auto-size to their
contents (+padding) unless a fixed size is set — the toolbar wrap no longer
forces `metrics.toolbar_height`, the ToolBar's own height is optional, and
the scroll view grows (`flex = 1`) to fill the rest. The `MenuBar` defaults
to `position = :absolute` for standalone use — a Form must override it to
`:relative`, or the flow layout excludes the bar and the scroll view
overlaps it. **The MenuBar's own output box keeps a fixed height**: its bar
row is absolutely positioned inside (so the dropdown anchors to the box), so
the auto-size sees no flow children and would collapse the box to zero —
the "fixed size is set" case of the auto-size rule. The Position toolbar's
tools (the 9-dot grid, labelled spinners) fit because of this.

20. **Rocks re-runs every component body per dirty frame — and effects queue in creation order**: a parent's
    effect runs *before* a child's mount effect, so a parent effect that writes a child's `value` before the
    child subscribes is missed. `E.Spinner` therefore keeps its field in sync in the *body* (guarded by
    `has_focus()` so a re-render never clobbers in-progress typing) instead of a mount subscription.
21. **A bare `Canvas` (no `MouseArea` wrapper) inside a bare `Window` does not render** in Rocks' flow layout —
    the minimal-script probes that draw on a canvas must use the demo's `MouseArea`-wrapped pattern (the real
    app uses the Form + Workspace, which renders). Pixel checks through `SDL3.ReadSurfacePixel` on a
    `LoadPNG`d screenshot also proved unreliable — verify through the image itself.
22. **`draw_dashed_polyline` must honour the `closed` flag** — without the closing segment, closed shapes
    (triangles, rectangles) lose their last edge in the dashed outline. Short curves (a dot) sit entirely
    inside one dash-or-gap, so they flash wholesale as the pattern marches — each curve therefore starts at
    its own position in the pattern (spread by the golden-ratio modulus `n·2.399963 mod period`, stable
    across frames, so the curves desynchronize).
23. **The 9-dot anchor grid semantics** (analysis 02 §3.6): the grid determines (a) which point the X/Y
    coordinates are relative to, (b) the rescale anchor, (c) the rotation pivot. Row 1 = top = the world
    `pmax` y (y-up coordinates).

### 8.9 The overflow-check mechanism + the handle drag fixes (2026-10-25)

**`Rocks.overflowing(root)`** walks the placed fiber tree and reports every `(child, parent)` pair where the
child's rect extends beyond its parent's content box — the layout-bug detector for screenshot tests: render
the app and assert `isempty(Rocks.overflowing(root))` instead of checking layouts by hand. Scrollable
parents (a `ScrollView`, a `Box` with `scroll`) are skipped (their children legitimately overflow);
absolutely-positioned children are skipped by default (they are placed intentionally); component fibers are
skipped as parents (their own rect is meaningless — the output element is the container).

**The transform-handle drag math must stay in one coordinate system**: the first version mixed screen-pixel
handle corners with world-millimetre cursor positions in the scale/rotate ratios — the handles "didn't work
properly". All drag math now unprojects through `inv(matrix(camera))`: the drag start, the cursor and the
handle corners are world points, and the scale/rotate ratios are world-to-world.

### 8.8 BlazeCraftGUI state conventions that emerged (project rules)

- **App shell**: owns the document Observable (app-level, common ancestor of workspace/status/open-action);
  every consumer receives it as a prop and subscribes with `@use` itself. The shell's own state (dialog flags,
  last error) is `@use` hook state.
- **Workspace**: owns view state (zoom/pan, drag gates) as hook state; receives `doc` as a prop. Draw functions
  take the state as parameters resolved by the caller; nothing reads module globals.
- **Import pipeline**: files are flattened to `PolyLine`s once at import (`ArtObject` caches them); the draw
  callback never re-flattens (§2.11 rule).
- **Native dialogs later**: `OpenDialog` is the single seam to swap for `SDL_ShowOpenFileDialog` when SDL3.jl
  grows a binding.

### 8.10 Layers feature round (2026-10-26)

**Data model** (`src/document.jl`): the full §4 palette now lives in `LAYER_COLORS_HEX` (30 cut layers
`00`–`29` + tool layers `T1`/`T2` at indices 30/31; `layer_label`, `is_tool_layer`, `CUT_LAYERS`).
`ArtObject` carries `layer::Int` instead of a colour tuple — the display colour is derived
(`layer_color(obj.layer)` in the workspace stroke, §4 "colour = layer"). `set_layer(arts, layer)` is the
bulk-recolor helper used by the palette clicks. `import_art` now returns `Vector{ArtObject}`, one object
**per source layer**: SVG = one object on `00`; DXF layer names each become their own object on successive
palette layers (sorted by name, `mod(i-1, CUT_LAYERS)`), named `"file.dxf/layername"`.

**LayerBar** (`src/app.jl`): a `ProgressBar`-free `StatusBar` variant along the bottom next to the doc
summary — 32 raised `Mechanics.Button` chips (16×16, background = palette colour; tool layers carry a tiny
T1/T2 caption). Click behaviour per §4: with a selection recolour it (and set the active colour), without a
selection only set the `active_layer` hook state (the colour for newly created shapes — v1 shows it as the
highlighted chip border). The App glues `Row(DocStatus, Box(flex=1), LayerBar)` as the Form's `status`
(the wrap's forced `fill=true` lands on the Row).

**New gotchas (verified empirically)**:

24. **`0:CUT_LAYERS` means 31 chips** — the tool layers need `0:(CUT_LAYERS + 1)`. Found because the
    LayerBar's own measured width (560px) disagreed with the visible chip arithmetic (pitch 18) — widen the
    range, then the row fit exactly and T2 stopped clipping.
25. **A Row inside a measured/container cell clamps children to the leftover width** — the (former) 31-chip
    bar was squeezed by the doc summary's panel rather than overflowing visibly; isolated probes (a Window
    with the bar alone) measured the bar at its own content width, so compare "isolated measure" vs "nested
    clamp" when a bottom bar clips.
26. **`isapprox` has no tuple method** — `layer_color(4) ≈ (…)` fails with MethodError even with same
    tuple types; use `all(c1 .≈ c2)`.
27. **`@testset` bodies are function scopes** — `import Rocks` inside a testset doesn't create the global
    the testset's helper closures resolve to; imports belong at the top of `test/runtests.jl`.
28. **List comp sizes**: `panels = Any[chips..., extra]` vs `vcat` — prefer plain vectors; wrong ranges show
    up as quietly-missing panels (T2), not errors.

### 8.11 Cuts/Layers panel round (2026-10-26)

**Process model** (`src/cuts.jl`): `MODES = (:line, :fill, :offset_fill)` with `mode_label`; `CutSettings`
(Base.@kwdef: speed 6000 mm/min, max_power 20%, min_power 0, passes 1.0, interval 0.1, scan_angle 0°,
kerf 0 — the §3 universal defaults); `Process(mode, settings)`; `quick_cuts(p)` renders the §5.2
`Spd/Pwr` readout (`"6000 / 20%"`, whole numbers); `document_layers(arts)` = sorted unique non-tool
layers with ≥1 object (§5.1 — every such layer gets a panel entry); `process_for(procs, layer)` falls
back to the default for not-yet-stored layers; `with_process` is the immutable-style store.

**CutsLayersPanel** (`src/app.jl`): a docked right column in a **`Split`** (`ratio` hook starts at 0.78)
— the panes wrap each side in a `Box(fill = true)`; the panel side adds `padding = 8`. One `Pressable` row
per document layer (chip, `layer_label`, `mode_label`, `quick_cuts`), empty state text when no geometry.
Rows carry `on_double_press` opening the editor.

**ProcessEditor** (`src/app.jl`): mounts as its **own OS window** via
`Rocks.Element(Rocks.Window, Dict{Symbol,Any}(...), Any[body])` — the MessageBox pattern (position
`= :cascade`, `on_close` = cancel; closed = return `nothing`, no window). Editing is on hook-state
copies (`mode`, `speed`, `max_power`, `passes`, `interval`, `scan_angle`, `kerf`); a `useEffect` on
`(open, layer, processes)` syncs copies from the stored process; **OK** writes back via `with_process`,
**Cancel** just closes (copies die with the render). **Mode is an `E.ComboBox`** (items = mode labels,
1-based `selected` observable; `on_change` maps the index to `mode`); only mode-relevant parameters get
field slots (Speed/Power/Passes always; +Interval/Scan angle for the scan modes; Kerf for Line mode),
with hidden slots as zero-height `Box` placeholders — see gotcha 31.

**Rocks: `on_double_press`** (`src/events.jl`): SDL counts consecutive clicks (`mouse_button_event.clicks`);
button-up with `clicks >= 2` routes to `on_double_press` instead of the `on_press`/`on_click` pair, only when
the handler is present (zero impact on existing UIs). Test helper `push_mouse!` grew a `clicks` kwarg.

**New gotchas (verified empirically)**:

29. **Component fibers stack output like a gap-less column — they don't stretch unless told** — the App
    placed `CutsLayersPanel` next to the Workspace with `height = "100%"` alone; the panel stayed at content
    height (66px) because the child *component* fiber of the Row is not stretched (the Row stretches only
    children that carry `fill = true` themselves). Fix: pass `fill = true` to the component, whose top
    `Box` forwards it (the same pattern the Workspace's wrapper Box uses). Diagnosed with the headless
    geometry probe (`measure!/place!` then walk `f.rect` + `props`).
30. **`Text` defaults to white** — `text_props` falls back to `(1,1,1)`; on the light theme headline texts
    ("Cuts / Layers", "Layer 01") were near-invisible until `color = t.colors.text` was passed explicitly.
    `E.Label` wraps Text with the right default; raw `E.Text`/bare `Text` must always get `color`.
31. **Never let a child list's *length* depend on interaction state without a kind change** — the editor
    first showed only mode-relevant fields (Interval/Scan angle for fill modes, Kerf for Line). Switching
    mode grew/shrank the row list; the reconciler matches children **positionally**, so row 4 ("Interval")
    kept the old "Kerf" spinner fiber's displayed text while its props were swapped (Interval showed 0.0
    with the observable at 0.1). Safe pattern: keep a fixed slot count and render hidden slots as a
    **zero-height empty `Box`** — a *different kind* than the `Row` — so the reconciler replaces the fiber
    (fresh component state) instead of rebinding a live one. The mode dropdown now drives such slots; the
    window height follows the visible rows (superseded by the `fit_content` windows below).
32. **`Split` needs `fill = true` to span the Form's scroll column and an explicit `ratio` observable** —
    without `fill` it measured its 400×300 default (right pane clipped at x=400); without `ratio` the
    seeded default gave a cramped left pane. Panes fill their sides exactly; wrap each side in a plain
    `Box(fill = true)` (+ `padding` for the docked panel) and give the side components `fill = true` so
    their own internals stretch.
33. **Mechanics buttons in tests**: find a `Mechanics.Button` by its label — the pressable fiber's label is
    a child fiber with `kind === Rocks.Text` and the string inside `fiber.props[:children]` (mounted text
    fibers carry empty `children`; the values live in props).
34. **A bare `@rock` next to a comma swallows the rest of the arg list** — `scan ? row : @rock Box(),
    next_child, …` made the `Box` end up with 4 children instead of 6: the space-spliced macro call
    parsed the following arguments as its own. Parenthesize every ternary arm (and prefer a tiny
    `fhidden()` helper over a shared element).

**Rocks: `fit_content` windows** (`src/backend.jl`, `src/layout.jl`): a window created with
`fit_content = true` measures its own child fibers (`fit_window_size`: Σ main-axis sizes + gaps +
2×padding, cross = max + 2×padding) instead of reading `width`/`height` props; explicit `width`/`height`
props act as **per-axis overrides**. Every layout pass re-checks the natural size (the `measure!` window
branch) and resizes the OS window via `SetWindowSize` when it drifted — so a mode switch in the editor
that adds/removes a field row grows/shrinks the window automatically. Verified: the editor renders
340×261 in Fill mode (Interval + Scan angle rows) and 340×232 in Line mode (Kerf row).
Gotcha **35**: the *re-fit* path must apply the `width`/`height` overrides too — the first version used the
raw `fit_window_size` value in `measure!` and overrode the editor's explicit 340 px width with the
content's natural cross size (228 px) on the first layout pass; both paths now go through one
`window_size(fiber)`. Popups are excluded from re-fitting.

**Fill/Offset-Fill preview** (`src/fills.jl`, workspace): scan-mode layers render their closed geometry
as a region fill with the **even-odd rule** (§3: same-layer overlaps erase, holes empty) — all closed
rings of a layer are collected first (`PolyLine.closed` only; open paths have no interior) and scanned in
one pass (`even_odd_runs`: per scan row `y + 0.5`, crossings of every edge, sorted, filled between
pairs; edges bucketed by first sampled row keep the active list small). The runs are painted into a
per-layer ARGB8888 software texture (`paint_even_odd!` → `SDL_UpdateTexture`) and blitted beneath the
strokes via `ctx.texture`. Textures live in Workspace hook state (`Ref(Dict{Int,LayerFillTexture})`),
keyed by (mode, canvas size, camera matrix, per-layer path ids) — the marching-dashes redraw never
re-scans an unchanged fill. `offset_fill` previews as the same region fill (the real offset is a machine
path computed later). `App`/`Workspace` accept a `processes` observable for tests and probes; the panel
and workspace share it. Verified with `fills_probe.jl`: overlapping rectangles erase their shared strip,
nested squares leave a hole, an octagon fills solid.

**New gotchas (fills round)**:

36. **`App` injection kwargs are read *after* all `@use` declarations rebind them** — adding a
    `processes` kwarg is not enough if an old unconditional `processes = processes_internal` line
    survives below it (the injected observable was overwritten and the panel kept showing defaults).
    The conditional-rebind block and the legacy assignment must be the same statement; when a probe
    shows stale state, grep for a second assignment of the injected name.

### 8.12 Tool strip, rectangle tool, and the window-flow fix (2026-10-26)

**Left tool strip** (`ToolsPanel` in `src/app.jl`): LightBurn's creation toolbar for v1 — two icon
buttons (select ↖ / rectangle ▭; both glyphs added to Rocks' `ICONS`), the active one in the item-hot
gradient. One shared `tool` observable (`:mouse`/`:rect`) connects the strip and the Workspace
(injectable for tests like every App prop).

**Rectangle tool** (`src/workspace.jl`, `rect_art` in `document.jl`): pressing starts a creation drag
(no selection changes in rect mode), motion updates a `rect_drag` observable drawn as a **dashed
preview** in the active layer's colour (`draw_workspace(preview = …)`), release commits an
`ArtObject("rectangle", …)` when the drag spans ≥ 0.5 mm — corners normalized, so any drag direction
works. The new shape is selected; **the tool stays active** (the mouse button switches back), and a
`no_refit` Ref suppresses the count-refit so creating never refits the view. The canvas shows a
crosshair while a creation tool is active.

**Rocks: windows stay out of the flow layout** (`src/layout.jl`): `flow_children` now skips **window
fibers** — a nested window element (the Cuts/Layers editor, a MessageBox, a menu popup) is a screen
surface positioned by the window manager, never a layout box. Before, the editor window mounted in the
Form's `children` list joined the scroll flow and its pixel size ate the row heights: the workspace
Split collapsed 586 → 0 px ("opening the cut options window squishes the main window"). Regression
test: a host window with a mounted dialog keeps its content sized exactly (gotcha 39).

**Rocks: headless driver module** (`src/driver.jl`, new): the test harness moved into the package —
`push_event!`/`push_mouse!`/`push_motion!`/`push_wheel!`/`push_key!`/`push_window_event!`,
`drain_events!`, `with_tree`, `sync_windows!`, plus **tree addressing** (`fibers`, `find_fiber`,
`find_fibers`, `find_kind`, `collect_kind`, `find_by_key`, `find_by_label` — content matched with the
renderer's own `text_content`) and **`click!(fiber; clicks, button, at)`** — a full press+release at the
fiber's center through the real event pipeline (rects are window-absolute, so no coordinate math).
Tests and probes can now "click through the UI" instead of hand-walking trees; the suite demonstrates
it end to end (pick the rect tool by its glyph, drag via `push_mouse!`, double-press the process row,
assert the editor opened and the split kept its height).

**New gotchas**:

37. **`@rock` paren balance in hand-written nested calls** — one `)` too many in a nested
    `@rock Window(...)` arg list made the `;`-kwargs dangle at function top level ("invalid assignment
    location "0"", "Expected `end`"), reported against the *macro site* (`element.jl`) instead of the
    call. Diagnosed with `Meta.parseall` + the JuliaSyntax diagnostics list, mapped to lines via
    `head -c <byte> | wc -l`. Count parens when a call mixes child elements and `;`-kwargs.
38. **`click!` on a freshly re-rendered but not re-placed fiber lands at (0, 0)** — the window origin,
    i.e. the menu bar: rects come from `place!`, not from the reconciler, so a fiber created by a
    re-render (a new panel row after a doc change) has no placed rect until the next
    `sync_windows!`/layout pass. After any doc change, sync before clicking.
39. **`Row`/`Column` are wrapper *components* rendering a `Box`** — the fiber tree is
    `Column → Box → children`, so tests must not assume a component fiber's children are the written
    elements (reach one level deeper, or use `find_kind`).
40. **Drag-created geometry lands on pixel centres** — the tool unprojects rounded canvas pixels, so a
    dragged rectangle is off by up to 0.5 px / zoom (≈ 0.27 mm at the default fit). Tests assert with
    `atol ≈ 0.5`; a "snap to grid" option can come later.

### 8.13 MDI icons, selection keys, and multi-select (2026-10-26)

**Icons: a `Font` component, not a global font** (2026-10-28): the Enterprise design stays
font-agnostic — its built-in `ICONS` are unicode approximations. Rocks gained the generic
**`Enterprise.Font(; font, weight, variant, size, children...)`** component: it walks its element
children and applies `font` (a TTF/OTF path) and `size` (px) to every `Text` in the subtree, recursing
through host containers, and passes them to **component** elements only when the component declares
them as keywords (`kwprops` reads `Base.kwarg_decl` — undeclared keywords would fail the component
call). `weight`/`variant` describe the face and ride along as `font_weight`/`font_variant` props
(SDL_ttf renders one face per file, so the app picks the file for the weight it wants). An
icon-bearing button is a button containing a `Font` that contains the icon:

```julia
@rock Pressable(
    @rock Font(font = MDI_FONT, size = 20, weight = "medium";
               @rock E.Icon(name = glyph; size = 20, color = t.colors.text));
    on_press = ...)
```

`Icon` no longer resolves a global icon font: it renders `name` (a semantic unicode glyph from
`ICONS`, or a glyph char such as an MDI codepoint) and carries the name as an `icon` prop for
tests/probes (`get(f.props, :icon, nothing)`). BlazeCraftGUI owns the taste: `src/icons.jl` bundles
the MDI 7.x webfont (`assets/fonts/`, Pictogrammers Free License — `LICENSE-MDI.txt`) plus the
`MDI_GLYPHS` name → codepoint map and the `MDI_FONT` path; use sites wrap icons in `Font(font =
MDI_FONT, ...)`. Codepoints were extracted from the MDI css with `grep -A2 "\.mdi-<name>::before"`.

**Tool strip and lock button**: tool buttons are 32px tall with 20px glyphs, `justify = :center` +
`align = :center` (bigger icon, smaller button, properly centred). The position toolbar's lock button
is a square `input_height` button whose icon shows the actual state: **`lock`** (closed padlock,
selection-blue background) while scaling is uniform, **`lock-open`** (open shackle) when not.

**Selection is a vector** (`Observable{Vector{Int}}`, sorted): a plain click selects one shape,
**Shift+click** (either Shift) toggles a shape in/out of the multi-selection, empty space starts a
**marquee** with the cursor tool (§8.14). Consumers updated: PositionToolbar (spinners sync/act on a
single selection only, disabled otherwise), LayerBar (`set_layer!` recolours *all* selected shapes),
and the rect tool's commit path (selects the new shape).

**Layer chips light up**: a chip carries the selection-colour border when it is the active colour *or*
its layer holds any selected shape — a multi-selection spanning layers lights them all.

**Keyboard shortcuts** (App `on_key` via the new `Form(on_key = …)` forwarding — keys reach the window
when no field holds focus): **Delete** removes every selected shape (`deleteat!` on a sorted copy,
selection cleared), **Escape** resets the tool to the mouse. Escape still dismisses open popup menus
first (Rocks consumes it before fields see it).

**Gotchas**:

41. **`Icon` text content is the glyph, not the name** — with MDI codepoints, `find_by_label` cannot
    match icon buttons by their old unicode glyph; address them through the `icon` prop instead. The
    prop holds the glyph char passed as `name`, so compare against `MDI_GLYPHS[name]` (a `Char`), not
    the semantic string.
42. **Writes into a typed `Observable{Vector{Int}}` must be vectors everywhere** — the rect commit
    path still wrote `selection[] = length(doc)` (scalar) and `LAST_KEYMODS` needed the `Rocks.`
    qualifier from BlazeCraftGUI; the suite caught both via `convert` MethodErrors.
43. **`(a; b)` is a Julia block, not a children list** — children after `;` only work *inside* an
    `@rock` call: `@rock Font(props...; @rock Icon(...))`. Writing `@rock Parent((@rock Font(...);
    @rock Icon(...)))` evaluates the block (returning only the last expression), silently dropping
    the `Font` element — the icon rendered with no font while the tree looked plausible.
44. **Positional args of `@rock Component(x; ...)` become children, not a parameter** — `@rock
    E.Icon(glyph; ...)` stringified the glyph child into `name`, so the `icon` prop was a `String`;
    pass `name = glyph` when the identity must stay a `Char`.
45. **`Method.kwargs` is gone in Julia 1.13** — inspect keyword names with `Base.kwarg_decl(m)`
    (`Symbol[...]`; varargs-keyword methods report `Symbol("kwargs...")`, which must be ignored when
    deciding what a component really accepts, or a forwarding wrapper like `Icon(name; kwargs...)`
    makes everything look supported).
46. **Direct (non-`@rock`) component calls are keyword-only** — `Mechanics.Button(element; props...)`
    is a `MethodError`; wrap the call in `@rock` (children after `;`) or pass `children =
    Any[...]` explicitly.

### 8.14 Panning, click-time mods, group frame, marquee, layer-bar move (2026-10-30)

**Camera pan** (middle-button drag): the Workspace's `on_down` starts a `:pan` mode on **button 2**
(storing the pressed camera and the screen anchor), `on_move` re-sets the camera via `pan(cam, dx, dy)`
(screen delta, grab-the-world feel), `on_up` ends it with the button that started it (a stray other
button's release must not cut a drag short — the rect commit is likewise gated to the left release).
Rocks gained two semantics for it:

- **`cursor = :pan`** — the plain arrow while hovering (no pointing hand: the workspace is a surface,
  not a button) and the **closed grabbing hand while a non-left button is held**. `update_cursor`
  decides from `ACTIVE_PRESS` per button: `:grab` grabs with any button (open hand on hover as
  before), `:pan` grabs only with a non-left press, `:crosshair` (newly real — it was never
  implemented) shows during creation-tool drags; hovered `:text`/`:grab`/`:crosshair` keep their
  pointers, `:pan`/`:arrow` (new) keep the plain arrow.
- **Press-captured motion for any button** — mouse-motion dispatch used to feed `on_move`/`on_drag`
  only when the *left* button's press was active, so a middle-button drag stopped tracking outside
  the area (or never got moves inside it via the hover path). It now feeds every pressed fiber of
  the window (left behaviour unchanged).

**Click-time keymods**: `LAST_KEYMODS` was only refreshed on `SDL_EVENT_KEY_DOWN`, so a Shift that
was pressed and released long before kept multi-selecting every subsequent click. Rocks now
refreshes `LAST_KEYMODS[] = SDL3.GetModState()` on every **mouse-button-down** dispatch (and on
`KEY_UP`, replacing the stale keydown value) — a click sees the modifiers held *right now*. The
headless driver keeps SDL's state in sync: `push_key!(…; mod)` and the new `push_mouse!(…; mod)`
call `SDL_SetModState`, so tests carry click mods on the event (`push_mouse!(canvas, DOWN, x, y;
mod = 0x0001)`), never by poking `LAST_KEYMODS`.

**One selection frame around the union** (`selection_union_bbox`): every selection draws one dashed
frame + transform handles enclosing the *union of all selected shapes* (a single shape is its own
bbox as before). The drag state became group state: `drag_sel` (indices) + `drag_art` (the original
arts) with `replace_arts!` writing **one document copy per move event**. Translate moves the delta to
every shape; scaling maps every shape under the same similarity about the union's fixed opposite
corner; rotation turns every shape about the union centre — so the group and each member transform
together and relative positions survive.

**Marquee selection** (cursor tool): a left press on empty space starts a drag; the *horizontal*
direction decides the mode — started at a right corner (dragged leftward) the dashed rect draws
**green** and selects everything **overlapping**, started at a left corner it draws **red** and
selects only shapes **fully contained** (`shapes_in_rect` on the shapes' world bboxes). A
click-shaped drag (never moved ≥ 0.5 mm) clears the selection like any empty-space click.

**Selection boxes snap to pixel corners**: SDL's line raster spills into the neighbouring row/column
when endpoints sit between or on pixel centres — first seen as width-2 lines that followed exact
mouse movement (sub-pixel endpoints), then as *always* 2 px once the frame was rounded to whole
pixels (integer endpoints look the same on the GPU renderer). `selection_union_bbox` and the
marquee now land endpoints on pixel corners (`snap_px = floor(p) + 0.5`), which keeps orthogonal
1 px lines; the snapping touches render pixels only, never the world-space interaction math
(document geometry keeps float precision).

![Group selection: union frame with handles, marquee multi-selection, layer bar below the workspace](analysis/images/screenshots/blazecraft-group-selection.png)

**Layer bar relocated**: the palette left the Form's status row — it is now a strip **directly below
the workspace** (inside the split's left pane: `Column(Workspace(flex = 1, fill); LayerBar(fill))`),
exactly as wide as the canvas, while the doc summary stays alone on the window's bottom edge.

**Gotchas**:

47. **Click mods live on the event, not the check** — with `dispatch_event!` refreshing
    `LAST_KEYMODS` from the SDL state at button-down (the point of the fix), a test that sets
    `Rocks.LAST_KEYMODS[]` directly is clobbered by the very next dispatch. Synthetic input carries
    mods via `push_mouse!(…; mod)` / `push_key!(…; mod)` (both keep `SDL_SetModState` in sync).
48. **Frame/handle coordinates are canvas-local px; pushes are window-absolute** —
    `selection_union_bbox`/`selection_handles` output (and the draw's rect coordinates) are
    canvas-local; feeding them to `push_mouse!` as-is lands the click offset by the canvas origin
    (the press silently missed the handle and fell through to a marquee). Offset by
    `canvas.rect[1..2]` on the way in, subtract the same on the way out (`scr`/`to_world` helpers in
    the test; gotcha 38's stale-rect rule applies equally to these re-reads).

### 8.15 Groups, context menu, and the outline tab (2026-10-30)

**Document model — groups as entries** (`src/document.jl`): `ArtObject` gained identity and a
container kind — `id::UInt` (unique, `art_next_id()` counter), `kind::Symbol` (`:shape`/`:group`),
and `children::Vector{UInt}` (the member ids of a group; shapes and/or other groups, i.e. groups
nest). The document stays **flat**: a group is one appended entry referencing its members by id —
the tree is virtual, so grouping moves nothing and un-grouping only removes the node. The plain
constructor `ArtObject(name, paths, layer)` still builds a fresh-id shape (every import/creation
path unchanged); edits copy identity through `ArtObject(entry; paths = …)` so a grouped shape keeps
its membership when translated/scaled/rotated/recoloured. Membership by *id* (never indices) is
what makes the hierarchy survive every index-shuffling edit.

Derived helpers, all in `document.jl`: `is_group`, `art_index(doc, id)`, `child_indices`,
`leaves_of(doc, idx)` (a group's outlines *are* its leaves' outlines), `resolve_leaves(doc,
selection)` (the "what geometry does my selection own" helper every consumer goes through),
`parent_group` (the *outermost* group in the entry's ancestor chain — "selecting one shape selects
the whole group" resolves to the outermost level, which is also what makes the click unit and the
marquee's top-level units agree), `top_level_indices` (the marquee's selection units),
`art_bounds(doc, idx)` (a group's bbox = the union over its subtree — what makes a group act like a
single shape), `group_arts` / `ungroup_arts` / `delete_arts`. Grouping **places the new group into
the innermost common group** of all members when they share one (`holder_group`/`ancestor_chain`/
`common_group` walk the id-based ancestor chains — with the members' *previous holders releasing
them* at the same time, so an entry lists under exactly one group: the outline would otherwise
duplicate every row under both the old and the new node). With no common group (some member is top
level) the new group lands there and still pulls the members out of their holders; a holder emptied
by the move is pruned (`prune_empty_groups`, cascading). Members nested inside other selected
members don't join — the ancestor carries their subtree. The new group is still the **last doc
entry** either way, so "the selection becomes the new group" is `length(doc)`. Ungrouping dissolves
**one level**: the members take the group's place — in the parent group's children when nested
(LightBurn's ungroup promotes into the parent), at the top level otherwise. Deleting a shape prunes
it from its group's `children`; deleting a group node dissolves it.

**Group-aware selection and marquee** (`src/workspace.jl`): a canvas click maps the hit leaf
through `parent_group` — the click unit is the *outermost* group in the shape's ancestor chain (the
shape itself when top level), matching the marquee's top-level units; Shift toggles at unit level
in the workspace. The marquee (`shapes_in_rect`) now compares the
*top-level entries* against the rect — a group acts like a single shape: green (overlap) joins the
whole unit via its combined bounds, red (containment) needs the whole unit inside; a partially
covered group falls out entirely either way. `selection_union_bbox` and the marching dashes
resolve through `resolve_leaves`, so a selected group frames and dashes its whole subtree. The
frame-drag handlers resolve the selection to leaves (`drag_sel`/`drag_art`), so the transforms act
on exactly the geometry the selection owns.

**Right-click context menu** (`WorkspaceContextMenu` in `src/app.jl`): the workspace's
`on_down(button 3)` flips a `ctx_open` Observable prop (not while a drag runs; the selection stays
as it is and the menu's items act on it). Rocks' `E.ContextMenu` gained **pointer anchoring**:
`x`/`y` omitted (or `nothing`) defer to the owning window's last pointer position — the click that
flipped `open` was dispatched before the render, so `LAST_POINTER` already holds its coordinates
(+2 nudge keeps the cursor hot pixel off the first row). The menu is the app's own component
(doc-level actions, like Delete), rendering `Group` / `Ungroup` items whose *enablement follows the
selection*: Group is off with nothing selected, Ungroup is off when the selection holds no group
node. A disabled item ignores presses entirely (the menu stays open); the first click elsewhere
dismisses the menu and is swallowed as the gesture.

![Context menu: Group enabled, Ungroup disabled for an ungrouped selection](analysis/images/screenshots/blazecraft-context-menu.png)

**Right panel → tabber with a document outline** (`src/outline.jl`): the Cuts/Layers panel and the
new `OutlinePanel` are pages of an `E.TabControl` (`tabs = ["Cuts / Layers", "Outline"]`, selected
= an injectable Observable). The outline is an indented tree of every entry with members indented
under their group (shapes carry a square in their layer colour, groups an outlined box mark); the
tree is virtual — it reads the flat document and walks `child_indices`, so it needs no state;
**subgroups list at the top of their super-group** (containers before their sibling shapes, both
top level and inside groups — the outline order is `outline_children`'s: groups first, doc order
within each class, and the row order is preordered into `row_order` so ranges read visually). A
plain row click selects **exactly** that entry: a shape row selects only the shape (never a parent
group), a group row selects the group (its members follow by membership); **Ctrl+click toggles the
row's entry into the multi-selection (individual)** while **Shift+click selects the row range**
between the anchor row — the last plain-/Ctrl-clicked one, carried in the `anchor` Observable prop
— and the clicked one, in visible row order (the mods ride on the click — Rocks refreshes them at
click time). **Right-clicking a row** selects it (unless it is already part of the
selection — a multi-selection survives) and opens the same context menu the workspace's right
click uses (`ctx_open` is shared; the menu's Group/Ungroup act on the selection — grouping a row's
entry from the outline works end to end). Rows live in a `ScrollView` so long documents scroll.

![Outline tab: nested groups, indented members, exact-entry selection](analysis/images/screenshots/blazecraft-outline.png)

**Gotchas**:

49. **`document_bounds` on a group entry poisoned every consumer** — the loop never executes for
    an entry with no paths, so it returned `(Inf…, -Inf…)` instead of `nothing` and the Position
    toolbar's effect happily wrote `NaN`/`-Inf` into the spinners. It now returns `nothing` when no
    geometry was found; a group's bounds must go through `art_bounds` (the union over its leaves).
49a. **Two nodes claiming one member duplicates the outline** — the virtual tree is opinionated:
     an entry is shown under *every* group whose `children` holds it. `group_arts` once just
     appended the new group beside the existing holder, so regrouping alpha+beta out of Group 1
     showed alpha and beta under **both** nodes ("grouping copies the shapes into the new group").
     Any writer of `children` must keep the single-holder invariant: `group_arts` releases members
     from their previous holders and prunes emptied ones; keep it that way in future edits.
50. **The shell body does not re-render on selection changes** — Rocks re-renders the *fibers that
    read a change* (`@use` subscribers); a plain `selection[]` read in the `App` body builds a
    stale snapshot, and the context menu's items stayed disabled after the selection moved. State
    that must be click-current belongs in its own small component that `@use`s what it needs
    (`WorkspaceContextMenu`), not in the shell body.
51. **`MouseArea` stretches a *single* `fill = true` child over the whole area** — mounting the
    context menu as a second child of the workspace's `MouseArea` collapsed the canvas to 0 height
    (the special case requires exactly one fill child). Window-level overlays (a context menu, a
    message box) are siblings in the app's tree, not siblings of the canvas.
52. **`fill` on a flow child stretches the *cross* axis only** — in a column container a `fill`
    child gets the container's width and its own natural height. A docked tab control needs
    `flex = 1` (the parent consumes it and grows the child's height; the component function never
    sees it), and the tab *page* needs `height = "100%"` (a percentage resolves against the
    container at placement) so the page fills the control. Component fibers size their output
    element by the size the parent gave *the component* — a `height = "100%"` on the returned
    element resolves against nothing; the component call itself carries the flex prop.
53. **The renderer of SDL's override-redirect popup aborts the process** — the first right-click
    crashed the GUI with an X `BadValue` in `X_GLXCreateContext`: Rocks' popup windows used
    `SDL_WINDOW_POPUP_MENU` (override-redirect on X11), and `create_window!` creates a renderer for
    *every* window — GLX on the popup's override-redirect drawable kills the process (headless
    never sees it: `CreatePopupWindow` fails there and the fallback path was exercised instead;
    the isolated SDL call `CreatePopupWindow` itself is fine, the *renderer* is not). Popup windows
    are now plain `BORDERLESS | ALWAYS_ON_TOP` windows positioned relative to their owner — the
    renderer works on those, and the menu's dismissal is in-app (`close_open_menus!`) anyway.

### 8.16 Anti-aliased canvas lines (2026-10-31)

SDL's line raster has no anti-aliasing, so the workspace's grid, borders, shape outlines and
marching dashes rendered as hard-edged pixels. Rocks' `canvas_line` now draws every segment as a
**feathered strip of three quads** through `SDL_RenderGeometry` with per-vertex alpha
(`geometry_color(color, coverage)`): the core of `width` px at full alpha, fading to transparent
over `LINE_FEATHER_PX` (0.75 px) on each side — the two feathers, the core and the two fades are
one 8-vertex triangle strip, so diagonals read smooth on every renderer. The strip's *ends* stay
square (segments meet other lines at corners; a fading end would open gaps in the grid and at
shape joints). `ctx.polyline`/`draw_dashed_polyline` inherit this through `ctx.line`; polygon
fills stay hard-edged (a feather there needs a stroke pass). Verified by a pixel-level Rocks test
(a diagonal line's feather pixels blend part-way to the background, where the old raster painted
hard pixels).

The pixel-corner snapping (`snap_px`) stays: with the feather, a snapped axis-aligned line reads as
a crisp 1 px core with soft edges, and the snap also keeps the grid stable while panning.

### 8.17 Batched, cached line geometry (2026-10-31)

Drawing every AA line as its own geometry call cost one draw call per segment — the grid alone is
~120 calls per frame. Rocks' `CanvasContext` gained `ctx.lines(key; deps, build)`: `build` returns
an iterable of `(x1, y1, x2, y2, color, width)` tuples; the built vertex/index buffers are cached
**per canvas** (a `CanvasState` dict on the Canvas fiber's host state) under `key`, and while the
caller's `deps` are `===` to the cached ones the batch re-issues the cached geometry — **one
RenderGeometry call, no rebuild**. `deps` compare by identity, so app-side the natural key is the
shape's art `id` with `deps = (obj, camera)`: a shape that didn't move (same immutable doc entry,
same camera instance) is re-drawn from the cache; an edit or a camera change rebuilds exactly the
affected batches. Returns whether the batch was (re)built.

The Workspace batches everything: the grid and the bed border under the camera instance (a still
camera re-issues them, no rebuild), each unselected shape under its art id, each selected shape's
marching dashes and the selection frame/rotation lines per redraw (their dash phase animates —
still one call each instead of dozens). The dash math moved into `dash_segments` (pure function)
and the per-shape strokes into `stroke_segments`, both feeding the batches.

**Gotchas while building this**:

54. **The batched grid must be projected through the camera** — the first version passed the raw
    world-space `GRID_SEGMENTS` to the strip builder (which takes canvas-local px), so the grid
    rendered at 0..300 px in the workspace's upper-left corner and never moved with the bed while
    the shapes (whose `stroke_segments` *did* project) panned correctly. `projected_segments` now
    applies the camera matrix — and keeps the old `draw_segment` behaviour of snapping
    axis-aligned segments to whole pixels (a crisp grid; arbitrary-angle shapes stay float).
55. **The AA feather must not outgrow the line** — the first ramp (0.75 px per side on a full-width
    core) made every line read ~75 % thicker. The ramp is now 0.4 px per side on a core of the
    nominal `width`: thin again, with the ramps sub-pixel on a pixel-centre rasterizer and visible
    where a line lands between pixels. Shrinking the *core* instead (the textbook 50 %-contour
    trick) is not an option: a sub-pixel-wide core quad gets missed entirely by pixel-centre
    sampling — the line's centre pixel silently vanishes.

Stale cache entries (deleted shapes) stay in the per-canvas dict until the canvas is destroyed —
harmless (ids are never reused); periodic pruning can come later if a long session makes it
matter.

56. **One-line strings have a texture ceiling** — importing a DXF (one `ArtObject` per primitive)
    made `doc_summary` join hundreds of names into a single status-bar line, and the Text fiber's
    TTF surface came out wider than SDL's 32768 px texture limit — `CreateTextureFromSurface`
    aborted the draw. Two fixes: the summary now lists the top-level structure (groups as
    `name (N primitives)`) and folds beyond `SUMMARY_MAX_PARTS` entries into `… (N more)`; and
    Rocks' text rendering clamps every line to `MAX_TEXT_LINE_PX` (16000 px) with an ellipsis
    (`clamp_text_line`, measured via `TTF_GetStringSize` — the SDL2-era `TTF_SizeUTF8` symbol no
    longer exists), so no string can crash a draw again.

### 8.18 DXF structure + contour welding (2026-11-03)

**Import grouping** (§8.15's model): `import_art` returns **one `ArtObject` per primitive**
(each flattened `PolyLine`, named `"file N"` — `"file/layer N"` for DXF layers, the palette layer
assigned per primitive) with a **group entry around the whole file's contents named after the
file** — so the outline shows `unicorn.svg` with its primitives indented below. A
single-primitive file imports as-is (no group around one entry); `group_arts` gained an optional
`name` kwarg for it (the context menu's Group action still names groups `"Group N"`).

**DXF containers** (round of 2026-11-01): a DXF carries its own structure, and the import
uses it instead of the flat per-layer view. `BlazeCraft.Importers.extract_structured`
(*new API*) yields `Vector{DXFUnit}` — `DXFUnit(name, kind, poly_layers, polys)` with
`kind = :layer` (entities of no other container), `:block` (one `INSERT`, exploded through an
affine `DxfTransform` — nested blocks recurse with composed transforms, `MINSERT` arrays keep
all their cells in one unit, `*`-prefixed system blocks and unresolvable references drop with a
`@warn`) and `:group` (the file's `ACAD_GROUP` objects, members claimed **first-claim-wins** by
handle; a claimed instance or entity lists under its group *only*). `extract_polys` stays the
flat layer-keyed collapse over the units — the old contract, now informed by the structure
(block geometry comes through instead of landing twice). The GUI maps each multi-shape unit to
a `[file/name]` group: layer buckets first (sorted — the palette structure), then block
instances and named groups in file order (repeats get ` #k`); the palette layer per DXF layer
(sorted names, `00` on, wrap at 30). Result on the test file: `plate.dxf → cut (8 arcs),
engraving (422 shapes)` as 3 tree rows.

**Contour welding** (round of 2026-11-03): those 8 cut arcs are not 8 cuts — they are one
closed plate outline cut by 8 primitives sharing endpoints. `BlazeCraft.Importers` gained
`weld_contours(pairs; tol = 1e-3)`: open primitives whose endpoints coincide (within `tol`, a
µm by default) chain into **one** poly each, and a chain whose ends meet comes out **closed** —
the laser gets one closed cut path instead of 8 open ones. Design:

* per-layer welds only (a contour is endpoint contact in one drawing context); the weld lives
  in `extract_structured` (λ layer buckets and exploded block instances, `tol` kwarg) — **named
  group members stay unwelded** (the file's explicit grouping is not a weld context);
* endpoint matching is a **quantized-grid lookup**: tips register in the nearest grid cell of
  size `tol`, lookups scan the 3×3 cell neighbourhood — no O(n²) distance wall, no missed
  near-cell match;
* **ambiguous tips never weld**: a tip meeting more than one other tip (or meeting both its own
  chain's far end *and* a third piece) stays open — tangent contours don't merge; closed polys
  (circles, closed polylines) pass through untouched;
* chains grow from either tip (extension order is the piece list, not the file's drawing
  order); the traversal direction of each piece is free.

Verified: plate.dxf's 8 cut arcs (R 200.5 mm alternating with R 16.75 mm) weld into **one
closed 37-point shape** at the µm default; the engraving layer's 422 primitives chain into 48
closed shapes (glyphs and knots); the file imports as `plate.dxf → cut 1 (shape),
engraving (48 shapes)` — 51 entries, down from 433, and the whole cut outline selects with a
single box. Suite impact: BlazeCraft 121 tests (weld testset: triangle close, neighbour-cell
match, flipped traversal, open chain, self-touching close, circle passthrough, Y-junction
no-merge, cross-layer non-merge, through-`extract_structured`), GUI suite green with the new
counts (`import_art: dxf layers pre-group` became the weld-count test).

**Gotchas of this round**:

57. **A chain seed is not a consumed piece** — the first weld grew every seed in one pass and
    marked it used; when a *later* seed then reached a *finished* chain and consumed it, the
    finished chain was skipped by the output pass (its geometry lived in the consumer, whose
    own used-flag was set at seed time — so everything the chain had absorbed vanished). The
    fix separates `consumed` (absorbed into another chain — skipped on output) from the seed
    pass: a finalized chain keeps its registration until another chain absorbs it.
58. **The closing joint point is a duplicate** — when a chain's far end reaches back to its
    start, the last appended piece already delivered a point ≈ the chain's first. Closed
    polys don't repeat their first point (see `RegularPolygon`/`_circle`), so the closure
    `pop!`s the joint copy; without it every welded ring gains one near-zero-length segment
    that later offsets/hatching must tolerate.
59. **`@view` inside a docstring'd function fails the package precompile** (Julia 1.13 + 
    DocStringExtensions' `@doc` hook): `Invalid use of @view macro` on plain, valid
    `@view x[2:end]` slices — only in that module-load context. Plain slices (`x[2:end]`,
    `vcat(x[1:2], y)`) cost a copy on these small vectors and compile everywhere; left that
    way (not chased further).

### 8.19 Outline collapse/expand (2026-11-03)

Groups collapse and expand in the outline: **the square in front of a group is the toggle** —
`[-]` expanded, `[+]` collapsed (a text glyph inside the 10 px square mark; shape rows keep
their layer-coloured square). Clicking the toggle zone — everything left of a group row's
name (`x < 25 + depth*14` in the row's local coords, the indent gutter plus the square) —
flips the group without touching the selection; clicking right of it selects as before.
**Groups with 5+ members start collapsed**, small ones expanded, so a fresh import presents
its structure (`plate.dxf → engraving [+]`) instead of hundreds of rows. The state is panel
state (`@use Observable(Dict{UInt,Bool}())` keyed by group id, user clicks only — the default
recomputes from the member count): renaming keeps the state, regrouping (new ids) resets to
the default, and a collapsed group's members are simply not walked — `row_order` (and with it
Shift-ranges) sees only visible rows, hidden members stay selected in the workspace.

**Gotchas of this round**:

60. **A rebuilt row carries no rect until the window is re-drawn** — after a toggle the
    outline re-renders and the member rows are new fibers; a test that clicks a fresh row
    right after `drain_events!/flush_dirty!/run_effects!` hits a fiber whose `rect` is still
    `(0,0,0,0)` (the click lands at window (0,0) — the File menu). The real event flow is
    fine (hits resolve by position over the laid-out tree); tests must `sync_windows!` +
    `draw_window!` after any re-render before `find_fiber`+`click!`.
61. **`group_arts` appends the new group last** — in a doc of 7 entries, grouping members
    `[1..5]` puts Group 1 at index 8 and a second group over `[6,7]` at index 9: the member
    indices are pre-append positions, the group indices post-append. Test docs built by
    chained `group_arts` calls must count both.

### 8.20 Alignment tools (2026-11-05)

The **top toolbar** gained the align family next to the placement inputs (origin grid, X/Y,
W/H, lock, a separator): **6 buttons, 3 per axis**, each aligning at the negative, centre or
positive edge of the selection's bounding rectangle (row 1: x axis left/centre/right, row 2:
y axis top/centre/bottom in y-up world; raised-bevel `Mechanics.Button`s to match the
toolbar). The model lives in `align_arts(doc, selection; x, y)` (`src/document.jl`): each
selected entry is one alignment **root** — a directly selected group is one root (its members
translate together, relative offsets preserved), selected shapes are roots of their own
(several members of one group selected together still move individually). Per axis
(`:min`/`:center`/`:max`, `:none` keeps it) every root translates so its own bounding box's
edge/centre lands on the roots' rectangle's; one root alone *is* the rectangle — a no-op; a
leaf claimed by an earlier root (a group and its own member both selected) never moves twice.
The buttons gray out below two selected roots and write one `align_arts` result per click.

**Gotchas of this round**:

62. **`width = "100%"` buttons in a Row overflow their panel** — the first align grid gave
    both columns "100%" of the Row and each measured 34 px wide: the right column landed at
    x 41..75, outside the 44 px strip, where the workspace's hit-test swallowed the clicks
    (the button *drew* — overflow `:visible` — but never received one). Fixed-size buttons
    (16 px) keep both columns inside the strip; the same rule as the outline's fixed 10 px
    chevron box.
63. **MDI codepoints are off by a family** — the align icons are **F11C2–F11C7**
    (`materialdesignicons.css` v7.4.47), not F00C1–F00C6 (which render bookmark glyphs —
    plausible-looking, silently wrong). Verify icon codepoints against the shipped font's
    CSS, or by screenshot, before trusting them.
64. **Each align recomputes the rectangle** — the clicks compound: after x-min, the
    rectangle's left edge is the aligned edge, so a following x-centre centres on the *new*
    rectangle. Tests must chain expectations through the compound sequence (the per-click
    math is pinned by the `align_arts` testset on fresh docs).

### 8.21 The Laser section (2026-11-05)

The right pane gained a **second tabber** south of the document tabber: the **Laser** tab
(`src/laser.jl`). Big buttons up top — Start, Autofocus, the selection's rectangle and convex
hull outlines, Save GCode, Run GCode file (2 per row; 96×44 with icon + caption) — then the
jog pad (four arrows around a centre Home) with the head readout and the status line, and the
**Laser Setup** entry. v1 runs against a *virtual head*: jog/home move it within the bed by
the machine's jog step (`machine` NamedTuple: host, bed_w, bed_h, jog — editable through the
dialog), the framing buttons compute the selection's bounding rectangle / `convex_hull`
outline (*new BlazeCraft API*, Andrew's monotone chain) into `frame`, which the workspace
draws as a red dashed overlay, and the device-dependent buttons report through the status
line until a sink is wired. The dialog opens from the tab's button *or* the menu bar's
**Settings → Machine Setup**.

**Gotchas of this round**:

65. **A tabber's content must fit its viewport — the status bar waits underneath** — the
    first Laser tab was taller than the right pane's share and the overflow slid under the
    app's status bar, whose 1100×22 rect then *won the hit-test* (`hit_test` clips host
    Boxes by their rect; the buttons *drew* but never received a click). Compact buttons and
    a `ScrollView` keep the controls inside the client area.
66. **Rows overflow their pane horizontally too** — pad + readout + setup button measured
    ~290 px in a ~206 px pane: the setup button landed outside the window. Stack what
    doesn't fit (the setup button got its own row).
67. **MDI icon names mix conventions** — the older entries use underscores (`arrow_up`),
    the align/laser families hyphens (`align-horizontal-left`): a hyphenated jog icon
    KeyError'd the dict. `mdi_glyph(name)` (the `get` fallback) is the safer lookup.
68. **`E.Label` is keyword-only** (`text =`), `Mechanics.Button` takes no layout kwargs
    (no `direction`/`align`/`justify`), and `E.TabControl` requires a `selected` Observable.
69. **The menu bar's titles are narrow Pressables inside the bar's row wrapper** — a label
    finder matching the wrapper (1100 px wide, `on_press = close`) clicks the bar itself and
    never opens the dropdown; filter by width (< 100 px) to address the title button.
70. **Probe idiom: effect writes need a second round** — a `useEffect` that writes an
    Observable during `run_effects!` marks fibers dirty *again*; headless tests must flush +
    run effects a second time before the re-draw (the live loop does this implicitly).
