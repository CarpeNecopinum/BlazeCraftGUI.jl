# The Laser section: the right pane's second tabber (§5.9's laser window).
# Device controls: the Start/Autofocus/framing/GCode buttons up top, the jog
# pad and the head readout, and the Laser Setup entry point. v1 runs against
# a virtual head — jog/home move it within the bed (the machine's settings),
# and the device-dependent buttons report through the status line until a
# sink is wired.

# The machine's settings, editable through the Laser Setup dialog: the
# device host (a Moonraker/Kalico URL), the bed size and the jog step.
const DEFAULT_MACHINE = (host = "", bed_w = 400.0, bed_h = 300.0, jog = 10.0)

"""
    LaserTab(; doc, selection, laser_pos, machine, laser_status, setup_open,
             frame, fill = false)

The Laser tab: big buttons up top — Start, Autofocus, the selection's
rectangle and convex hull outlines, Save GCode, Run GCode file — then the
jog pad (four arrows and Home around a centre button) with the head
position readout and the status line, and the Laser Setup entry point.

The framing buttons compute the selection's bounding rectangle / convex
hull outline (a real path — the framing move the laser would trace) into
`frame`, which the workspace draws as an overlay. Jog/home move the
(virtual) head within the machine's bed by the machine's jog step. The
device-dependent buttons report through `laser_status` — no device yet.
"""
function LaserTab(; doc = Observable(ArtObject[]),
                  selection = Observable(Int[]),
                  laser_pos = Observable(Point(0.0, 0.0)),
                  machine = Observable(DEFAULT_MACHINE),
                  laser_status = Observable("disconnected — open Laser Setup"),
                  setup_open = Observable(false),
                  frame = Observable(PolyLine[]),
                  fill = false)
    doc_obs = @use doc
    selection_obs = @use selection
    pos_obs = @use laser_pos
    machine_obs = @use machine
    status_obs = @use laser_status
    setup_obs = @use setup_open
    t = E.theme()
    (x, y) = pos_obs[]

    "The bounding rectangle outline of the selected roots — the framing
    path the laser traces around the job."
    function rect_outline!()
        b = nothing
        for li in resolve_leaves(doc_obs[], selection_obs[])
            bb = document_bounds([doc_obs[][li]])
            bb === nothing && continue
            b = b === nothing ? bb :
                (Point(min.(b[1], bb[1])), Point(max.(b[2], bb[2])))
        end
        b === nothing && return
        frame[] = [PolyLine([b[1], Point(b[2][1], b[1][2]), b[2],
                             Point(b[1][1], b[2][2])], true)]
        return nothing
    end

    "The convex hull outline of the selected roots' geometry."
    function hull_outline!()
        pts = Point[]
        for li in resolve_leaves(doc_obs[], selection_obs[])
            for pl in doc_obs[][li].paths, p in pl.points
                push!(pts, p)
            end
        end
        isempty(pts) && return
        frame[] = [BlazeCraft.convex_hull(pts)]
        return nothing
    end

    # Jog the (virtual) head within the machine's bed; Home returns to the
    # work origin. Both read the current state at press time, so repeated
    # jogs compound and a Laser Setup change applies immediately.
    jog!(dx, dy) = begin
        m = machine_obs[]
        p = pos_obs[]
        laser_pos[] = Point(clamp(p[1] + dx, 0.0, m.bed_w),
                            clamp(p[2] + dy, 0.0, m.bed_h))
    end
    home!() = (laser_pos[] = Point(0.0, 0.0))

    "The device-dependent actions report through the status line until a
    sink is wired."
    device_status(msg) = begin
        m = machine_obs[]
        laser_status[] = m.host == "" ?
                         string(msg, ": no device — open Laser Setup") :
                         string(msg, ": sent to ", m.host)
        return nothing
    end

    "A big labelled button: the icon above the caption. A fixed 62 px width
    keeps three per row inside the pane."
    function big_button(icon_name, label, action)
        @rock Pressable(
            @rock Column(
                @rock Font(font = MDI_FONT, size = 20, weight = "medium",
                           variant = "normal";
                           @rock E.Icon(name = MDI_GLYPHS[icon_name];
                                        size = 20, color = t.colors.text)),
                E.Label(; text = label, size = t.metrics.font_size - 4);
                gap = 2, align = :center);
            on_press = action,
            width = 62, height = 44,
            direction = :column, align = :center, justify = :center,
            background = t.colors.control,
            hover_background = t.gradients.button_hover,
            pressed_background = t.gradients.button_pressed,
            border_color = t.colors.border, border_width = 1,
            radius = t.metrics.control_radius)
    end

    "A jog-pad button: the arrow glyph; a fixed 22 px square."
    function jog_button(icon_name, action)
        @rock Pressable(
            @rock Font(font = MDI_FONT, size = 14, weight = "medium",
                       variant = "normal";
                       @rock E.Icon(name = MDI_GLYPHS[icon_name]; size = 14,
                                    color = t.colors.text));
            on_press = action,
            width = 22, height = 22,
            direction = :column, align = :center, justify = :center,
            background = t.colors.control,
            hover_background = t.gradients.button_hover,
            pressed_background = t.gradients.button_pressed,
            border_color = t.colors.border, border_width = 1,
            radius = t.metrics.control_radius)
    end
    # The plus arrangement: up/left/right/down around the centre Home. The
    # jog step is the machine's — read at press time, so a Laser Setup
    # change applies without a re-mount.
    jogstep() = machine_obs[].jog

    big = @rock Column(
        @rock Row(big_button("play", "Start", () -> device_status("Start")),
                  big_button("focus-auto", "Autofocus",
                             () -> device_status("Autofocus")),
                  big_button("rectangle-outline", "Rect outline",
                             () -> rect_outline!());
                  gap = 4, align = :center),
        @rock Row(big_button("vector-polygon", "Hull outline",
                             () -> hull_outline!()),
                  big_button("save", "Save GCode",
                             () -> device_status("Save GCode")),
                  big_button("run", "Run GCode file",
                             () -> device_status("Run GCode file"));
                  gap = 4, align = :center);
        gap = 8, align = :center)

    jog = @rock Column(
        @rock Row((@rock Box(; width = 22, height = 22)),
                  jog_button("arrow_up", () -> jog!(0.0, jogstep())),
                  (@rock Box(; width = 22, height = 22)); gap = 1),
        @rock Row(jog_button("arrow_back", () -> jog!(-jogstep(), 0.0)),
                  jog_button("home", home!),
                  jog_button("arrow_forward", () -> jog!(jogstep(), 0.0));
                  gap = 1),
        @rock Row((@rock Box(; width = 22, height = 22)),
                  jog_button("arrow_down", () -> jog!(0.0, -jogstep())),
                  (@rock Box(; width = 22, height = 22)); gap = 1);
        gap = 1, align = :center)

    readout = @rock Column(
        E.Label(; text = string("X ", round(x, digits = 1),
                                "   Y ", round(y, digits = 1)),
                size = t.metrics.font_size),
        E.Label(; text = status_obs[], size = t.metrics.font_size - 2,
                color = t.colors.disabled_text);
        gap = 4, align = :start)

    setup_btn = @rock Mechanics.Button(
        @rock Font(font = MDI_FONT, size = 14, weight = "medium",
                   variant = "normal";
                   @rock E.Icon(name = MDI_GLYPHS["tune"]; size = 14,
                                color = t.colors.text)),
        E.Label(; text = "Laser Setup", size = t.metrics.font_size - 2);
        on_press = () -> (setup_obs[] = true),
        gap = 4, padding = 4, width = 110, height = t.metrics.button_height,
        size = t.metrics.font_size - 2, font = t.font, bevel = :raised,
        border_color = t.colors.border, border_width = 1)

    body = @rock Box(
        @rock ScrollView(
            big,
            @rock Row(jog, readout;
                      gap = 14, align = :center),
            setup_btn;
            position = :absolute, fill = true,
            scrollbar = true, scrollbar_width = t.metrics.scrollbar,
            scrollbar_track = t.colors.scrollbar_track,
            scrollbar_thumb = t.gradients.scrollbar_thumb,
            scrollbar_border = t.colors.scrollbar_border,
            scrollbar_radius = 2,
            padding = 4, gap = 10, direction = :column, align = :center);
        direction = :column, gap = 0,
        background = t.colors.document, fill = fill)
    return body
end

"""
    LaserSetupDialog(; open, machine, width = 340)

The Laser Setup dialog: the machine's settings as its own OS window — the
device host (a Moonraker/Kalico URL), the bed size and the jog step. The
edited copies live as hook state (the Process Editor's pattern); OK writes
them back into `machine`, Cancel and the window's close button discard.
"""
function LaserSetupDialog(; open = Observable(false),
                          machine = Observable(DEFAULT_MACHINE),
                          width = 340)
    open_obs = @use open
    machine_obs = @use machine
    t = E.theme()
    open_obs[] || return nothing
    small = t.metrics.font_size - 2

    host = @use Observable("")
    bed_w = @use Observable(400.0)
    bed_h = @use Observable(300.0)
    jog = @use Observable(10.0)
    # A re-open syncs the edited copies back to the stored machine.
    useEffect(() -> begin
        m = machine_obs[]
        host[] = m.host
        bed_w[] = m.bed_w
        bed_h[] = m.bed_h
        jog[] = m.jog
        nothing
    end, (open_obs, machine_obs))

    ok() = begin
        machine_obs[] = (host = host[], bed_w = bed_w[], bed_h = bed_h[],
                         jog = jog[])
        open_obs[] = false
        return nothing
    end
    cancel() = (open_obs[] = false)

    lrow(label, field) = @rock Row(
        (@rock Box(@rock E.Label(label); width = 88, align = :center,
                   direction = :row)),
        field;
        padding = 3, gap = 4, align = :center)
    fields = @rock Box(
        lrow("Host", E.TextBox(text = host, width = 180)),
        lrow("Bed width", E.Spinner(value = bed_w, step = 10.0, width = 180)),
        lrow("Bed height", E.Spinner(value = bed_h, step = 10.0, width = 180)),
        lrow("Jog step", E.Spinner(value = jog, step = 1.0, width = 180));
        direction = :column, align = :start)
    footer = @rock Box(
        Mechanics.Button(; label = "OK", on_press = ok, width = 70,
                         height = t.metrics.button_height, size = small,
                         font = t.font, bevel = :raised, border_width = 1,
                         border_color = t.colors.border),
        Mechanics.Button(; label = "Cancel", on_press = cancel, width = 70,
                         height = t.metrics.button_height, size = small,
                         font = t.font, bevel = :raised, border_width = 1,
                         border_color = t.colors.border);
        direction = :row, gap = 8, align = :center, justify = :end,
        padding = 10)
    body = @rock Box(
        fields, footer;
        direction = :column, gap = 10, padding = 14, align = :start,
        background = t.colors.control, fill = true)
    return Rocks.Element(
        Rocks.Window,
        Dict{Symbol,Any}(:title => "Laser Setup",
                         :width => width, :fit_content => true,
                         :background => t.colors.control,
                         :padding => 1, :direction => :column,
                         :position => :cascade, :resizable => false,
                         :on_close => cancel),
        Any[body],
    )
end
