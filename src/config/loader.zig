// Compositor config: TOML load/save, defaults, and hot-reload apply.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const xkb = @import("xkbcommon");

const theme_mod = @import("ui").theme;
const Theme = theme_mod.Theme;
const keybinds = @import("keybinds.zig");
const Action = keybinds.Action;
const Keybind = keybinds.Keybind;
const default_file = @import("default.zig");
const types = @import("types.zig");
pub const window_rules = @import("window_rules.zig");
pub const WindowRule = window_rules.WindowRule;
pub const sandbox_allow = @import("sandbox_allow.zig");
pub const SandboxAllowRule = sandbox_allow.SandboxAllowRule;
const anim = @import("ui").anim;
const anim_cfg = @import("animations.zig");
const output_transform = @import("output_transform.zig");
pub const schedule_mod = @import("schedule.zig");
pub const ScheduleMode = schedule_mod.ScheduleMode;
pub const NightLightConfig = schedule_mod.NightLightConfig;
pub const AccelProfile = types.AccelProfile;
pub const PanModifier = types.PanModifier;
pub const AccelCurve = types.AccelCurve;
const loader_edit = @import("loader_edit.zig");
const loader_fields = @import("loader_fields.zig");
const loader_compare = @import("loader_compare.zig");
pub const resolvePath = loader_edit.resolvePath;
pub const replaceThemeSection = loader_edit.replaceThemeSection;
pub const replaceThemeOverrides = loader_edit.replaceThemeOverrides;
pub const replaceTaskbarThemeSection = loader_edit.replaceTaskbarThemeSection;
pub const rewriteSection = loader_edit.rewriteSection;
pub const spliceSection = loader_edit.spliceSection;
pub const FieldRule = loader_fields.FieldRule;
pub const input_rules = loader_fields.input_rules;
pub const region_rules = loader_fields.region_rules;
pub const compositor_rules = loader_fields.compositor_rules;
pub const idle_rules = loader_fields.idle_rules;
pub const desktop_rules = loader_fields.desktop_rules;
pub const ipc_rules = loader_fields.ipc_rules;
pub const output_rules = loader_fields.output_rules;
pub const ruleHint = loader_fields.ruleHint;
pub const enumHint = loader_fields.enumHint;
pub const fieldHint = loader_fields.fieldHint;
pub const applyField = loader_fields.applyField;
pub const applyInputKey = loader_fields.applyInputKey;
pub const applyCompositorKey = loader_fields.applyCompositorKey;
pub const applyPolkitKey = loader_fields.applyPolkitKey;
pub const applyIdleKey = loader_fields.applyIdleKey;
pub const applyDesktopKey = loader_fields.applyDesktopKey;
pub const applyIpcKey = loader_fields.applyIpcKey;
pub const applyNightLightKey = loader_fields.applyNightLightKey;
pub const applyNotificationsKey = loader_fields.applyNotificationsKey;
pub const applyNotificationRuleKey = loader_fields.applyNotificationRuleKey;
pub const parseZoomSteps = loader_fields.parseZoomSteps;
pub const parseEnum = loader_fields.parseEnum;
pub const parseAccelProfile = loader_fields.parseAccelProfile;
pub const parseVec2 = loader_fields.parseVec2;
pub const parseBool = loader_fields.parseBool;
pub const parseU32Range = loader_fields.parseU32Range;
pub const parseI32Range = loader_fields.parseI32Range;
pub const parseOutputScale = loader_fields.parseOutputScale;
pub const parseString = loader_fields.parseString;
pub const unquoteKey = loader_fields.unquoteKey;
pub const outputsLayoutEql = loader_compare.outputsLayoutEql;
pub const outputsColorEql = loader_compare.outputsColorEql;
pub const outputsEql = loader_compare.outputsEql;
pub const nightLightEql = loader_compare.nightLightEql;
pub const wheelAccel = loader_compare.wheelAccel;
pub const inputEql = loader_compare.inputEql;
pub const themeEql = loader_compare.themeEql;

pub const log = std.log.scoped(.config);

pub const max_zoom_steps: u8 = 8;
pub const drag_scale_min: f32 = 1.0;
pub const drag_scale_max: f32 = 1.10;
pub const default_zoom_percents = [_]u8{ 100, 85, 70, 55 };

/// Browsers smooth wheel scrolling themselves (prefixes also cover their
/// installed web apps, e.g. `brave-<id>-Default`).
pub const default_smooth_scroll_exclude = [_][]const u8{
    "brave",   "chromium",  "google-chrome", "microsoft-edge", "vivaldi", "opera",
    "firefox", "librewolf", "floorp",        "zen",
};

pub const InputConfig = struct {
    xkb_layout: []const u8 = "",
    xkb_variant: []const u8 = "",
    xkb_options: []const u8 = "",
    xkb_model: []const u8 = "",
    natural_scroll: bool = true,
    // Compositor-side flip applied to every scroll axis event regardless of
    // device/backend support, unlike `natural_scroll` which only takes
    // effect when libinput's per-device natural-scroll toggle is available
    // (many plain mice report it unsupported). See `Input.processAxis`.
    invert_scroll: bool = true,
    pointer_speed: f32 = -0.3,
    pointer_speed_touchpad: f32 = -0.3,
    accel_profile: AccelProfile = .bezier,
    accel_p1: [2]f32 = .{ 0.0, 0.0 },
    accel_p2: [2]f32 = .{ 0.15, 1.0 },
    accel_max_speed: f32 = 10.0,
    // Multiplies camera-pan distance for modifier-drag and middle-drag panning;
    // 1.0 keeps the canvas glued 1:1 under the cursor (see Input.startPan).
    pan_speed: f32 = 2.0,
    // Modifiers that, held while the pointer moves, pan the canvas
    // (`Input.isPanModifierHeld`). Super+Alt+wheel zooms the whole desktop
    // whichever is chosen.
    pan_modifier: PanModifier = .super_alt,
    // Middle-mouse-button drag pans the canvas when true. Modifier-drag panning
    // is unaffected; disabling this only stops the middle button itself from
    // starting a pan, so it goes back to acting as an ordinary client button
    // (e.g. middle-click paste). See Input.processButton.
    middle_button_pan: bool = true,
    // Mouse-wheel acceleration, in shell panels and apps alike: fast runs of
    // notches move further per notch. 0 disables; see `ui/wheel.zig`.
    wheel_acceleration: f32 = 1.0,
    wheel_acceleration_max: f32 = 5.0,
    // App ids (prefix match) whose wheel notches are forwarded unscaled.
    wheel_acceleration_exclude: []const []const u8 = &.{},
    // Glide each wheel notch into apps as a run of small high-resolution
    // steps (`input/client_wheel.zig`). Apps that already smooth their own
    // wheel scrolling are excluded, so it is not smoothed twice.
    smooth_scroll: bool = false,
    smooth_scroll_exclude: []const []const u8 = &default_smooth_scroll_exclude,
    // A wheel click against the run this soon after its last click is held
    // as a likely encoder bounce (`input/wheel_debounce.zig`). 0 disables.
    wheel_debounce_ms: u32 = 60,
    tap_to_click: bool = true,
    tap_drag: bool = true,
    disable_while_typing: bool = true,
    disable_while_typing_touchpad: bool = true,
    key_repeat_delay: u32 = 400,
    key_repeat_rate: u32 = 25,
    cursor_theme: []const u8 = "default",
    cursor_size: u32 = 32,
    /// Text-caret behaviour, beside the other typing settings. Appearance
    /// (`caret`, `caret_width`) is in `[theme]`. Applied through
    /// `ui.input.caret_config`; see its doc comment for the semantics of 0.
    caret_blink_ms: u32 = 1060,
    caret_blink_timeout: u32 = 10,
    caret_motion_ms: u32 = 80,
};

/// Personal session preferences. Empty strings inherit the login environment.
pub const RegionConfig = struct {
    timezone: []const u8 = "",
    language: []const u8 = "",
    formats: []const u8 = "",
    clock_24h: bool = false,
    clock_show_seconds: bool = false,
    clock_show_day: bool = true,
    first_day_of_week: enum { sunday, monday, tuesday, wednesday, thursday, friday, saturday } = .sunday,

    pub fn timeFormat(self: RegionConfig) [:0]const u8 {
        return if (self.clock_24h) "%H:%M" else "%l:%M %p";
    }

    pub fn taskbarTimeFormat(self: RegionConfig) [:0]const u8 {
        if (!self.clock_show_seconds) return self.timeFormat();
        return if (self.clock_24h) "%H:%M:%S" else "%l:%M:%S %p";
    }
};

pub const TaskbarItems = @import("taskbar_items.zig").Config;

pub const DesktopMode = enum { canvas, workspaces };
pub const dock_height_min: u32 = 48;
pub const dock_height_max: u32 = 96;
pub const dock_height_default: u32 = 68;
pub const dock_hover_zoom_max: f32 = 1.5;

pub const CompositorConfig = struct {
    desktop_mode: DesktopMode = .canvas,
    floating_apps: []const []const u8 = &.{},
    default_file_manager: []const u8 = "",
    default_terminal: []const u8 = "",
    dock_enabled: bool = false,
    dock_position: types.DockPosition = .bottom,
    dock_height: u32 = dock_height_default,
    dock_hover_zoom: f32 = 1.05,
    dock_auto_hide: bool = false,
    /// Alpha of the dock's background. Unset keeps the theme's own (`dock_bg`).
    dock_opacity: ?f32 = null,
    /// A rectangle behind the focused application's icon; the running pill shows regardless.
    dock_active_highlight: bool = false,
    /// A Trash icon at the dock's far end (right, or bottom on a side dock).
    dock_show_trash: bool = true,
    dock_hidden_shortcuts: []const []const u8 = &.{},
    dock_pinned_apps: []const []const u8 = &.{},
    taskbar_items: TaskbarItems = .{},
    taskbar_position: types.TaskbarPosition = .bottom,
    /// App identities opted into compositor tabs. Only + launches join a group.
    window_tab_apps: []const []const u8 = &.{},
    focus_follows_mouse: bool = false,
    // Legacy pixel settings remain parseable; canvas dimensions now use screens.
    canvas_columns: u32 = 3,
    canvas_rows: u32 = 3,
    // Super+arrow desktop slide; see `anim.desktopSwitchCurve`.
    desktop_switch_ms: u32 = anim.default_desktop_switch_ms,
    desktop_icons_fixed: bool = true,
    mini_map_enabled: bool = true,
    mini_map_position: types.MiniMapPosition = .bottom_right,
    mini_map_hide_ms: u32 = 1500,
    canvas_width: u32 = 7680,
    canvas_height: u32 = 4320,
    zoom_steps: [max_zoom_steps]f32 = .{ 1.0, 0.85, 0.70, 0.55, 0, 0, 0, 0 },
    zoom_step_count: u8 = 4,
    zoom_percents: []const u8 = &default_zoom_percents,
    camera_zoom_min: f32 = 0.25,
    camera_zoom_max: f32 = 1.0,
    /// How explicit window switching brings a small window into focus.
    focus_zoom: types.FocusZoom = .boost,
    /// Explicit space around/between tiles. Unset uses the active mode's default.
    window_gap: ?u32 = null,
    /// Dragging a window to an open screen edge tiles or maximizes it.
    snap_to_edges: bool = true,
    /// Soft presentation-only lift while moving a window.
    drag_feedback: bool = true,
    drag_scale: f32 = 1.002,
    /// A file manager slides aside while a file is dragged out of it; see
    /// `input/drag_dodge.zig`.
    dodge_file_drags: bool = true,
    /// Files opens an item with one click on its icon; names still select.
    files_single_click_open: bool = true,
    inactive_opacity: f32 = 1.0,
    /// Background alpha handed to Foot, kitty, Alacritty, Ghostty and WezTerm at launch (`config/terminal_theme.zig`).
    /// Unset keeps the `alpha` of the user's own Foot configuration.
    terminal_opacity: ?f32 = null,
    /// A window that is not the focus loses `inactive_dim_amount` of its
    /// brightness and of its colour (`Toplevel.applyDim`).
    inactive_dim: bool = true,
    inactive_dim_amount: f32 = 0.08,
    switcher_opacity: f32 = 1.0,
    border_radius: u32 = 10,
    allow_tearing: bool = false,
    xwayland: bool = true,
    xwayland_native_scaling: bool = false,
    /// 0 follows the native-scaling policy; explicit factors require restart.
    xwayland_scale: f64 = 0,
    /// Colour scheme apps are told to prefer through the Settings portal
    /// (`session/settings_portal.zig`): dark when true, light when false.
    dark_mode: bool = false,
    /// Delay before showing a placeholder frame for an unmapped launch (ms).
    /// 0 disables the placeholder frame.
    placeholder_delay_ms: u32 = 0,
    /// Empty for RediWM's own, a file name in the wallpaper directories, or a
    /// path; see `wallpapers.zig`.
    wallpaper: []const u8 = "",
    icon_theme: []const u8 = "",
    sound_theme: []const u8 = "freedesktop",
    sound_enabled: bool = true,
    sound_disabled_events: []const []const u8 = &.{},
    /// What closing the laptop lid does; see `input/lid.zig`.
    lid_close: LidAction = .display_off,
    /// Lock before the system sleeps, however sleep was requested; logind
    /// waits until the lock is on screen (`session/power.zig`).
    lock_on_suspend: bool = true,

    pub fn windowGap(self: CompositorConfig) u32 {
        return self.window_gap orelse if (self.desktop_mode == .workspaces) 8 else 0;
    }
};

pub const LidAction = types.LidAction;

/// Per-output overrides matched against wlr_output.name. Omitted coordinates
/// retain automatic placement; scale-only entries do not pin an origin.
pub const OutputConfig = struct {
    width: ?i32 = null,
    height: ?i32 = null,
    refresh_mhz: ?i32 = null,
    name: []const u8 = "",
    x: ?i32 = null,
    y: ?i32 = null,
    /// null selects automatic density detection.
    scale: ?f32 = null,
    /// Keep the connector in the saved layout without enabling it.
    enabled: bool = true,
    /// Preferred fallback output for placement and desktop ownership.
    primary: bool = false,
    transform: output_transform.Transform = .normal,
    night_light: bool = true,
    gamma: f32 = 1.0,
};

pub const PolkitConfig = struct {
    enable: bool = true,
    helper_socket: []const u8 = "/run/polkit/agent-helper.socket",
};

pub const IdleConfig = struct {
    enabled: ?bool = null,
    blank_after_seconds: u32 = 600,
    suspend_after_seconds: u32 = 0,
};

pub const NotificationsConfig = struct {
    daemon: []const u8 = "", // Empty selects the built-in daemon; changes require restart.
    dnd: bool = false,
    default_timeout_ms: u32 = 5000,
};

pub const DesktopConfig = struct {
    /// Desktop icons and wallpaper drawn by the compositor. Unset follows
    /// `desktopEnabled`: configs from before this section enabled the
    /// desktop by autostarting the retired rediwm-desktop client.
    enabled: ?bool = null,
};

pub const IpcConfig = struct {
    /// Synthetic input, pixel reads, buffer dumps and screenshots over the IPC
    /// socket. Off by default so ordinary clients get Wayland's usual
    /// isolation; test setups turn it on. Read once at startup.
    automation: bool = false,
};

/// Whether the compositor draws the desktop. An empty config draws none, as
/// before: the old client only ran from the default template's autostart.
pub fn desktopEnabled(cfg: *const Config) bool {
    if (cfg.desktop.enabled) |enabled| return enabled;
    for (cfg.autostart) |cmd| if (isDesktopClient(cmd)) return true;
    return false;
}

/// An autostart command for the retired rediwm-desktop client.
pub fn isDesktopClient(cmd: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, cmd, " \t");
    const program = words.next() orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(program), "rediwm-desktop");
}

pub const NotificationRule = struct {
    app_name: ?[]const []const u8 = null,
    desktop_entry: ?[]const []const u8 = null,
    mute: ?bool = null,
    urgency: ?u8 = null,
    dnd_bypass: ?bool = null,
};

pub const Config = struct {
    theme: Theme = .{},
    theme_base: []const u8 = "",
    theme_defaults: Theme = .{},
    /// Effective config layer before REDIWM_THEME, for saving a small overlay.
    theme_config: Theme = .{},
    theme_pack: ?@import("theme_pack.zig").Pack = null,
    /// `[taskbar_theme]`: the taskbar's own colours over the main theme's.
    /// Null (no section) follows the main theme. Only taskbar tokens are set.
    taskbar_theme: ?Theme = null,
    input: InputConfig = .{},
    input_method: struct { env: types.InputMethod = .none } = .{},
    keyboard_keymap: ?*xkb.Keymap = null,
    compositor: CompositorConfig = .{},
    region: RegionConfig = .{},
    polkit: PolkitConfig = .{},
    idle: IdleConfig = .{},
    night_light: NightLightConfig = .{},
    notifications: NotificationsConfig = .{},
    desktop: DesktopConfig = .{},
    ipc: IpcConfig = .{},
    outputs: []OutputConfig = &.{},
    keybinds: []Keybind = &.{},
    workspace_keybinds: []Keybind = &.{},
    workspace_lookup: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    lookup: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    autostart: [][]const u8 = &.{},
    window_rules: []WindowRule = &.{},
    notification_rules: []NotificationRule = &.{},
    sandbox_allow: []SandboxAllowRule = &.{},
    animations: anim.Settings = .{},
    path: []const u8 = "",
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        if (self.keyboard_keymap) |map| map.unref();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn lookupKeybind(self: *const Config, mods: anytype, sym: xkb.Keysym) ?Action {
        if (self.compositor.desktop_mode == .workspaces) return keybinds.lookupKey(self.workspace_keybinds, self.workspace_lookup, mods, sym);
        return keybinds.lookupKey(self.keybinds, self.lookup, mods, sym);
    }

    pub fn activeKeybinds(self: *const Config) []Keybind {
        return if (self.compositor.desktop_mode == .workspaces) self.workspace_keybinds else self.keybinds;
    }

    pub fn sandboxAllowGroups(self: *const Config, app_id: ?[]const u8, engine: ?[]const u8) sandbox_allow.GroupSet {
        if (app_id == null) return sandbox_allow.GroupSet.initEmpty();
        var set = sandbox_allow.GroupSet.initEmpty();
        for (self.sandbox_allow) |rule| {
            if (rule.app_id.len > 0 and std.mem.eql(u8, rule.app_id, app_id.?)) {
                if (rule.engine == null or engine == null or std.mem.eql(u8, rule.engine.?, engine.?)) {
                    set.setUnion(rule.allow);
                }
            }
        }
        return set;
    }
};

pub fn default(allocator: Allocator) !Config {
    var cfg = try initEmpty(allocator);
    errdefer cfg.deinit();
    cfg.keyboard_keymap = try @import("keymap.zig").compile(allocator, cfg.input);
    try applyDefaultKeybinds(&cfg);
    try applyWorkspaceKeybinds(&cfg, .empty);
    return cfg;
}

pub fn generateDefault(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try Io.Dir.cwd().createDirPath(io, dir);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = default_file.source });
}

pub fn loadDefault(allocator: Allocator, io: Io, environ: std.process.Environ) !Config {
    const path = resolvePath(environ, allocator) catch |err| {
        log.warn("config path: {}, using built-in defaults", .{err});
        return default(allocator);
    };
    defer allocator.free(path);

    if (!fileExists(io, path)) {
        generateDefault(io, path) catch |err| {
            log.warn("could not write default config '{s}': {}", .{ path, err });
            return loadFromBytes(allocator, "", path, environ, io);
        };
        log.info("Generated default config at {s}", .{path});
    }

    return load(path, allocator, io, environ);
}

pub fn load(path: []const u8, allocator: Allocator, io: Io, environ: std.process.Environ) !Config {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| {
        log.warn("failed to read '{s}': {}", .{ path, err });
        return err;
    };
    defer allocator.free(bytes);
    return loadFromBytes(allocator, bytes, path, environ, io);
}

pub fn loadFromBytes(
    allocator: Allocator,
    bytes: []const u8,
    path: []const u8,
    environ: std.process.Environ,
    io: Io,
) !Config {
    var cfg = parse(allocator, bytes, path) catch |err| {
        log.warn("config '{s}': parse failed ({s}), keeping caller fallback", .{ path, @errorName(err) });
        return err;
    };
    errdefer cfg.deinit();

    if (cfg.theme_base.len > 0) {
        const a = cfg.arena.allocator();
        cfg.theme_pack = @import("theme_pack.zig").find(a, io, environ, path, cfg.theme_base) catch null;
        if (cfg.theme_pack) |p| {
            cfg.theme_defaults = p.tokens;
            cfg.theme = p.tokens;
            try theme_mod.overlay(a, &cfg.theme, bytes);
            if (cfg.taskbar_theme == null) cfg.taskbar_theme = p.taskbar;
            p.layout.apply(&cfg.compositor);
            if (p.color_scheme) |dark| cfg.compositor.dark_mode = dark;
            if (p.cursor_theme.len > 0) {
                cfg.input.cursor_theme = if (std.mem.eql(u8, p.cursor_theme, "pack"))
                    try std.fmt.allocPrint(a, "rediwm-{s}-cursors", .{p.id})
                else
                    p.cursor_theme;
            }
        } else log.warn("theme pack '{s}' is missing or invalid; using defaults", .{cfg.theme_base});
    }
    cfg.theme_config = cfg.theme;
    if (theme_mod.resolvePath(environ)) |theme_path| {
        overlayThemeFile(cfg.arena.allocator(), io, &cfg.theme, theme_path) catch |err| {
            log.warn("REDIWM_THEME overlay '{s}': {}", .{ theme_path, err });
        };
    }
    if (cfg.theme_pack != null) {
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = theme_mod.stripComment(std.mem.trim(u8, raw, " \t\r"));
            if (line.len == 0) continue;
            if (line[0] == '[') {
                section = line;
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, section, "[compositor]") and std.mem.eql(u8, key, "dark_mode")) cfg.compositor.dark_mode = std.mem.eql(u8, value, "true");
            if (std.mem.eql(u8, section, "[compositor]")) {
                inline for (@import("theme_pack.zig").Layout.keys) |layout_key| {
                    if (std.mem.eql(u8, key, layout_key)) try applyCompositorKey(&cfg.compositor, cfg.arena.allocator(), key, value);
                }
            }
            if (std.mem.eql(u8, section, "[input]") and std.mem.eql(u8, key, "cursor_theme")) cfg.input.cursor_theme = try cfg.arena.allocator().dupe(u8, try theme_mod.unquote(value));
        }
    }
    finishCompositor(&cfg);
    return cfg;
}

pub fn parse(allocator: Allocator, bytes: []const u8, path: []const u8) !Config {
    var cfg = try initEmpty(allocator);
    errdefer cfg.deinit();
    cfg.path = try cfg.arena.allocator().dupe(u8, path);

    var seen_keybinds = false;
    var seen_frame_radius = false;
    var autostart_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var bind_list: std.ArrayListUnmanaged(Keybind) = .empty;
    var workspace_binds: std.ArrayListUnmanaged(Keybind) = .empty;
    var outputs_list: std.ArrayListUnmanaged(OutputConfig) = .empty;
    var current_output: OutputConfig = .{};
    var have_current_output = false;
    var rule_list: std.ArrayListUnmanaged(WindowRule) = .empty;
    var current_rule: WindowRule = .{};
    var have_current_rule = false;
    var notif_rule_list: std.ArrayListUnmanaged(NotificationRule) = .empty;
    var current_notif_rule: NotificationRule = .{};
    var have_current_notif_rule = false;
    var sandbox_allow_list: std.ArrayListUnmanaged(SandboxAllowRule) = .empty;
    var current_sandbox_allow: SandboxAllowRule = .{};
    var have_current_sandbox_allow = false;
    var section: Section = .none;
    var target_flags: [anim.Target.count]anim_cfg.TargetFlags = [_]anim_cfg.TargetFlags{.{}} ** anim.Target.count;
    var line_no: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = theme_mod.stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;

        if (line[0] == '[') {
            try flushArrayTables(&cfg, path, line_no, section, &outputs_list, &current_output, &have_current_output, &rule_list, &current_rule, &have_current_rule, &notif_rule_list, &current_notif_rule, &have_current_notif_rule, &sandbox_allow_list, &current_sandbox_allow, &have_current_sandbox_allow);
            section = parseSection(line) catch |err| {
                if (err == error.UnknownAnimationTarget) {
                    const close = std.mem.indexOfScalar(u8, line, ']') orelse line.len;
                    const name = if (line.len > 1 and close > 1) line[1..close] else line;
                    const target = if (std.mem.startsWith(u8, name, "animations.")) name["animations.".len..] else name;
                    fail(path, line_no, "unknown animation target '{s}'", .{target});
                } else {
                    fail(path, line_no, "invalid section header", .{});
                }
                return error.InvalidConfig;
            };
            if (section == .keybinds) seen_keybinds = true;
            // Its presence alone chooses a taskbar theme, even with no keys.
            if (section == .taskbar_theme and cfg.taskbar_theme == null) cfg.taskbar_theme = .{};
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            fail(path, line_no, "expected key = value", .{});
            return error.InvalidConfig;
        };
        const key = unquoteKey(std.mem.trim(u8, line[0..eq], " \t"));
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        switch (section) {
            .none => {},
            .theme => {
                if (std.mem.eql(u8, key, "base")) {
                    const id = try theme_mod.unquote(value);
                    if (id.len > 0 and !@import("theme_pack.zig").validId(id)) return error.InvalidConfig;
                    cfg.theme_base = try cfg.arena.allocator().dupe(u8, id);
                    continue;
                }
                theme_mod.applyKey(cfg.arena.allocator(), &cfg.theme, key, value) catch |err| {
                    fail(path, line_no, "invalid theme field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
                if (std.mem.eql(u8, key, "radius_lg")) seen_frame_radius = true;
            },
            .taskbar_theme => {
                // Other theme keys are ignored, so a whole theme file's body can be pasted in.
                _ = theme_mod.applyTaskbarKey(cfg.arena.allocator(), &cfg.taskbar_theme.?, key, value) catch |err| {
                    fail(path, line_no, "invalid taskbar_theme field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .input_method => {
                if (!std.mem.eql(u8, key, "env")) return error.InvalidConfig;
                const text = theme_mod.unquote(value) catch return error.InvalidConfig;
                cfg.input_method.env = std.meta.stringToEnum(types.InputMethod, text) orelse return error.InvalidConfig;
            },
            .input => applyInputKey(&cfg.input, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid input field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .compositor => applyCompositorKey(&cfg.compositor, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid compositor field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .region => {
                const known = applyField(&cfg.region, cfg.arena.allocator(), region_rules, key, value) catch return error.InvalidConfig;
                if (!known) return error.InvalidConfig;
            },
            .autostart => {
                if (std.mem.eql(u8, key, "cmd")) {
                    const cmd = parseString(cfg.arena.allocator(), value) catch {
                        fail(path, line_no, "autostart cmd must be a quoted string", .{});
                        return error.InvalidConfig;
                    };
                    autostart_list.append(cfg.arena.allocator(), cmd) catch {
                        return error.OutOfMemory;
                    };
                }
            },
            .outputs => {
                have_current_output = true;
                const known = applyField(&current_output, cfg.arena.allocator(), output_rules, key, value) catch {
                    fail(path, line_no, "outputs {s} must be {s}", .{ key, fieldHint(OutputConfig, output_rules, key) });
                    return error.InvalidConfig;
                };
                if (!known) {
                    fail(path, line_no, "unknown outputs field '{s}'", .{key});
                    return error.InvalidConfig;
                }
            },
            .window_rules => {
                have_current_rule = true;
                window_rules.applyRuleKey(&current_rule, cfg.arena.allocator(), key, value) catch |err| {
                    fail(path, line_no, "invalid window_rules field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .sandbox_allow => {
                have_current_sandbox_allow = true;
                sandbox_allow.applyKey(&current_sandbox_allow, cfg.arena.allocator(), key, value, path, line_no) catch |err| {
                    fail(path, line_no, "invalid sandbox_allow field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .polkit => applyPolkitKey(&cfg.polkit, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid polkit field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .idle => applyIdleKey(&cfg.idle, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid idle field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .desktop => applyDesktopKey(&cfg.desktop, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid desktop field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .ipc => applyIpcKey(&cfg.ipc, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid ipc field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .night_light => applyNightLightKey(&cfg.night_light, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid night_light field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .keybinds, .workspace_keybinds => {
                const spec = keybinds.parseKeybind(key) catch {
                    fail(path, line_no, "invalid keybind '{s}'", .{key});
                    return error.InvalidConfig;
                };
                const action_str = theme_mod.unquote(value) catch {
                    fail(path, line_no, "keybind action must be a quoted string", .{});
                    return error.InvalidConfig;
                };
                const action = keybinds.parseAction(action_str, cfg.arena.allocator()) catch {
                    fail(path, line_no, "invalid action '{s}'", .{action_str});
                    return error.InvalidConfig;
                };
                const list = if (section == .workspace_keybinds) &workspace_binds else &bind_list;
                list.append(cfg.arena.allocator(), .{
                    .modifiers = spec.modifiers,
                    .sym = spec.sym,
                    .action = action,
                }) catch return error.OutOfMemory;
            },
            .notifications => applyNotificationsKey(&cfg.notifications, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid notifications field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .notification_rules => {
                have_current_notif_rule = true;
                applyNotificationRuleKey(&current_notif_rule, cfg.arena.allocator(), key, value) catch |err| {
                    fail(path, line_no, "invalid notification_rules field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .animations => anim_cfg.applyGlobalKey(&cfg.animations, key, value) catch |err| {
                fail(path, line_no, "invalid animations field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .animation_target => |target| {
                anim_cfg.applyTargetKey(&cfg.animations, target, &target_flags[@intFromEnum(target)], key, value) catch |err| {
                    fail(path, line_no, "invalid animations.{s} field '{s}': {s}", .{ @tagName(target), key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
        }
    }

    // Legacy frame geometry is a fallback; theme numbers take precedence,
    // including a REDIWM_THEME overlay applied after this parse.
    if (!seen_frame_radius) cfg.theme.radius_lg = @floatFromInt(cfg.compositor.border_radius);

    try flushArrayTables(&cfg, path, line_no, section, &outputs_list, &current_output, &have_current_output, &rule_list, &current_rule, &have_current_rule, &notif_rule_list, &current_notif_rule, &have_current_notif_rule, &sandbox_allow_list, &current_sandbox_allow, &have_current_sandbox_allow);

    if (cfg.idle.blank_after_seconds > 0 and cfg.idle.suspend_after_seconds > 0 and cfg.idle.suspend_after_seconds <= cfg.idle.blank_after_seconds) {
        fail(path, line_no, "suspend_after_seconds must be greater than blank_after_seconds", .{});
        return error.InvalidConfig;
    }

    if (cfg.night_light.start == cfg.night_light.end) {
        fail(path, line_no, "night_light start cannot equal end", .{});
        return error.InvalidConfig;
    }

    const nl_night_span = @mod(@as(i32, cfg.night_light.end) - @as(i32, cfg.night_light.start) + 1440, 1440);
    const nl_day_span = 1440 - nl_night_span;
    if (cfg.night_light.transition_minutes >= nl_night_span or cfg.night_light.transition_minutes >= nl_day_span) {
        fail(path, line_no, "night_light transition_minutes must be shorter than both night and day spans", .{});
        return error.InvalidConfig;
    }

    if (cfg.night_light.schedule == .sun) {
        if (cfg.night_light.latitude == null or cfg.night_light.longitude == null) {
            fail(path, line_no, "night_light schedule 'sun' requires both latitude and longitude", .{});
            return error.InvalidConfig;
        }
    }

    if (seen_keybinds) {
        // Keep laptop controls, nested-session switching and the way out of
        // an inhibiting client available in existing configs too. Explicit
        // bindings (including noop) always take precedence over these defaults.
        const defaults = try parseKeybindsOnly(cfg.arena.allocator(), default_file.source);
        for (defaults) |bind| {
            const nested_switcher = bind.modifiers.ctrl and (bind.action == .focus_next or bind.action == .focus_prev);
            if (!keybinds.isHardwareAction(bind.action) and !nested_switcher and bind.action != .restore_shortcuts) continue;
            const key = keybinds.pack(bind.modifiers, bind.sym);
            var overridden = false;
            for (bind_list.items) |custom| {
                if (keybinds.pack(custom.modifiers, custom.sym) == key) {
                    overridden = true;
                    break;
                }
            }
            if (!overridden) try bind_list.append(cfg.arena.allocator(), bind);
        }
        cfg.keybinds = bind_list.items;
    } else {
        try applyDefaultKeybinds(&cfg);
    }
    try applyWorkspaceKeybinds(&cfg, workspace_binds);
    cfg.autostart = autostart_list.items;
    cfg.outputs = outputs_list.items;
    var have_primary = false;
    for (cfg.outputs) |output| {
        if (!output.primary) continue;
        if (have_primary) {
            fail(path, line_no, "outputs may contain only one primary monitor", .{});
            return error.InvalidConfig;
        }
        have_primary = true;
    }
    cfg.window_rules = rule_list.items;
    cfg.notification_rules = notif_rule_list.items;
    cfg.sandbox_allow = sandbox_allow_list.items;
    try rebuildLookup(&cfg);
    finishCompositor(&cfg);
    // An explicit [animations.camera_desktop] table wins over the settings value.
    if (std.meta.eql(target_flags[@intFromEnum(anim.Target.camera_desktop)], anim_cfg.TargetFlags{})) {
        cfg.animations.targets[@intFromEnum(anim.Target.camera_desktop)].curve = anim.desktopSwitchCurve(cfg.compositor.desktop_switch_ms);
    }
    cfg.keyboard_keymap = @import("keymap.zig").compile(allocator, cfg.input) catch return error.InvalidConfig;
    return cfg;
}

pub const Section = union(enum) {
    none,
    theme,
    taskbar_theme,
    input,
    input_method,
    compositor,
    region,
    autostart,
    outputs,
    keybinds,
    workspace_keybinds,
    polkit,
    idle,
    window_rules,
    sandbox_allow,
    night_light,
    notifications,
    notification_rules,
    desktop,
    ipc,
    animations,
    animation_target: anim.Target,
};

pub fn flushArrayTables(
    cfg: *Config,
    path: []const u8,
    line_no: usize,
    section: Section,
    outputs_list: *std.ArrayListUnmanaged(OutputConfig),
    current_output: *OutputConfig,
    have_current_output: *bool,
    rule_list: *std.ArrayListUnmanaged(WindowRule),
    current_rule: *WindowRule,
    have_current_rule: *bool,
    notif_rule_list: *std.ArrayListUnmanaged(NotificationRule),
    current_notif_rule: *NotificationRule,
    have_current_notif_rule: *bool,
    sandbox_allow_list: *std.ArrayListUnmanaged(SandboxAllowRule),
    current_sandbox_allow: *SandboxAllowRule,
    have_current_sandbox_allow: *bool,
) !void {
    if (section == .outputs and have_current_output.*) {
        if ((current_output.width == null) != (current_output.height == null) or
            (current_output.refresh_mhz != null and current_output.width == null)) return error.InvalidConfig;
        outputs_list.append(cfg.arena.allocator(), current_output.*) catch return error.OutOfMemory;
        current_output.* = .{};
        have_current_output.* = false;
    } else if (section == .window_rules and have_current_rule.*) {
        if (rule_list.items.len >= window_rules.max_rules) {
            fail(path, line_no, "too many window rules (max {d})", .{window_rules.max_rules});
            return error.InvalidConfig;
        }
        if (current_rule.hasMatchers() and !current_rule.hasProperties()) {
            log.warn("{s}:{d}: (warn): window rule has matchers but no properties", .{ path, line_no });
        }
        rule_list.append(cfg.arena.allocator(), current_rule.*) catch return error.OutOfMemory;
        current_rule.* = .{};
        have_current_rule.* = false;
    } else if (section == .notification_rules and have_current_notif_rule.*) {
        notif_rule_list.append(cfg.arena.allocator(), current_notif_rule.*) catch return error.OutOfMemory;
        current_notif_rule.* = .{};
        have_current_notif_rule.* = false;
    } else if (section == .sandbox_allow and have_current_sandbox_allow.*) {
        if (current_sandbox_allow.app_id.len == 0) {
            fail(path, line_no, "sandbox_allow requires app_id", .{});
            return error.InvalidConfig;
        }
        sandbox_allow_list.append(cfg.arena.allocator(), current_sandbox_allow.*) catch return error.OutOfMemory;
        current_sandbox_allow.* = .{};
        have_current_sandbox_allow.* = false;
    }
}

pub fn parseSection(line: []const u8) !Section {
    if (std.mem.startsWith(u8, line, "[[")) {
        inline for (.{ .autostart, .outputs, .window_rules, .notification_rules, .sandbox_allow }) |tag| {
            if (std.mem.eql(u8, line, "[[" ++ @tagName(tag) ++ "]]")) return tag;
        }
        return error.InvalidConfig;
    }
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.InvalidConfig;
    const name = line[1..close];
    if (std.mem.eql(u8, name, "keybinds.workspace")) return .workspace_keybinds;
    // Array tables and internal tags are deliberately not accepted here.
    inline for (.{ .theme, .taskbar_theme, .input, .input_method, .compositor, .region, .keybinds, .polkit, .idle, .night_light, .notifications, .desktop, .ipc, .animations }) |tag| {
        if (std.mem.eql(u8, name, @tagName(tag))) return tag;
    }
    if (std.mem.startsWith(u8, name, "animations.")) {
        const rest = name["animations.".len..];
        return .{ .animation_target = anim.Target.parse(rest) orelse return error.UnknownAnimationTarget };
    }
    return .none;
}

pub fn initEmpty(allocator: Allocator) !Config {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn applyDefaultKeybinds(cfg: *Config) !void {
    const parsed = try parseKeybindsOnly(cfg.arena.allocator(), default_file.source);
    cfg.keybinds = parsed;
    try rebuildLookup(cfg);
}

pub fn parseKeybindsOnly(allocator: Allocator, bytes: []const u8) ![]Keybind {
    var list: std.ArrayListUnmanaged(Keybind) = .empty;
    var in_keybinds = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = theme_mod.stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_keybinds = std.mem.eql(u8, line, "[keybinds]");
            continue;
        }
        if (!in_keybinds) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = unquoteKey(std.mem.trim(u8, line[0..eq], " \t"));
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const spec = try keybinds.parseKeybind(key);
        const action_str = try theme_mod.unquote(value);
        const action = try keybinds.parseAction(action_str, allocator);
        try list.append(allocator, .{
            .modifiers = spec.modifiers,
            .sym = spec.sym,
            .action = action,
        });
    }
    return list.items;
}

pub fn applyWorkspaceKeybinds(cfg: *Config, overrides: std.ArrayListUnmanaged(Keybind)) !void {
    const a = cfg.arena.allocator();
    var list = overrides;
    const defaults = try parseKeybindsOnly(a, @import("workspace_defaults.zig").source);
    const canvas = try parseKeybindsOnly(a, default_file.source);
    for ([_][]Keybind{ defaults, canvas }, 0..) |binds, source| for (binds) |bind| {
        if (source == 1 and !keybinds.isHardwareAction(bind.action) and bind.action != .restore_shortcuts) continue;
        const key = keybinds.pack(bind.modifiers, bind.sym);
        const overridden = for (list.items) |custom| {
            if (keybinds.pack(custom.modifiers, custom.sym) == key) break true;
        } else false;
        if (!overridden) try list.append(a, bind);
    };
    cfg.workspace_keybinds = list.items;
    cfg.workspace_lookup = .empty;
    for (list.items, 0..) |bind, i| try cfg.workspace_lookup.put(a, keybinds.pack(bind.modifiers, bind.sym), i);
}

pub fn rebuildLookup(cfg: *Config) !void {
    cfg.lookup = .empty;
    const a = cfg.arena.allocator();
    for (cfg.keybinds, 0..) |bind, i| {
        const packed_key = keybinds.pack(bind.modifiers, bind.sym);
        try cfg.lookup.put(a, packed_key, i);
    }
}

pub fn finishCompositor(cfg: *Config) void {
    const count = @min(cfg.compositor.zoom_step_count, max_zoom_steps);
    cfg.compositor.zoom_step_count = @max(1, count);
    var percents: [max_zoom_steps]u8 = undefined;
    var i: u8 = 0;
    while (i < cfg.compositor.zoom_step_count) : (i += 1) {
        const step = std.math.clamp(cfg.compositor.zoom_steps[i], 0.01, 4.0);
        percents[i] = @intFromFloat(@round(step * 100.0));
        if (percents[i] == 0) percents[i] = 1;
    }
    cfg.compositor.zoom_percents = cfg.arena.allocator().dupe(u8, percents[0..cfg.compositor.zoom_step_count]) catch {
        cfg.compositor.zoom_percents = &default_zoom_percents;
        cfg.compositor.zoom_step_count = 4;
        return;
    };
}

pub fn overlayThemeFile(allocator: Allocator, io: Io, t: *Theme, path: []const u8) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(bytes);
    try theme_mod.overlay(allocator, t, bytes);
}

pub fn fileExists(io: Io, path: []const u8) bool {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(1)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    std.heap.page_allocator.free(bytes);
    return true;
}

pub fn fail(path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    log.warn("{s}:{d}: {s}", .{ path, line, msg });
}

test {
    _ = @import("loader_tests.zig");
}
