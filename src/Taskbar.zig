// The bottom taskbar: one CPU-rasterized strip per output, laid out and
// exclusive-zoned the way a wlr-layer-shell bottom panel would be, but drawn
// directly into the scene like the wallpaper and window chrome rather than
// through an actual layer-shell client (there is no external client here).
//
// Geometry is mapped from the taskbar spec: bar 64, chip 42 tall, icon tile 23,
// tray hit target 34, tray/tile gap 6, edge gutter 20 (all logical px @1x).
// Chips fit their icon and title, capped at 280px and sharing available space
// when crowded. Focus is indicated by a subtle neutral fill and border.
const std = @import("std");
const glass = @import("glass.zig");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("node.zig");
const col = @import("color.zig");

const c_time = @import("taskbar/c_time.zig").c;

const gpa = @import("main.zig").gpa;
const anim = @import("ui").anim;
const geometry = @import("geometry.zig");
const icon_service = @import("icon_service.zig");
const scene_data = @import("scene_data.zig");
const battery = @import("taskbar/battery.zig");
const taskbar_items = @import("config").taskbar_items;
const battery_highlight = @import("taskbar/battery_highlight.zig");
const battery_badge = @import("ui").widgets.battery;
const start_button = @import("taskbar/start_button.zig");
const text = @import("ui").text;
const ui_theme = @import("ui").theme;
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const taskbar_metrics = @import("taskbar/metrics.zig");
const taskbar_clock = @import("taskbar/clock.zig");
const taskbar_layout = @import("taskbar/layout.zig");
const taskbar_reconcile = @import("taskbar/reconcile.zig");
const taskbar_tick = @import("taskbar/tick.zig");
const taskbar_pointer = @import("taskbar/pointer.zig");
const taskbar_classify = @import("taskbar/classify.zig");
const taskbar_paint_util = @import("taskbar/paint_util.zig");
const taskbar_paint = @import("taskbar/paint.zig");
const taskbar_chip_text = @import("taskbar/chip_text.zig");
const taskbar_app_tray = @import("taskbar/app_tray.zig");

pub const Anim = anim.Anim;
pub const nowMs = anim.nowMs;

const Taskbar = @This();

const log = std.log.scoped(.taskbar);

pub const default_bar_height: i32 = 54;
pub const bar_height: i32 = default_bar_height;
// taskbar/metrics.zig
pub const barHeight = taskbar_metrics.barHeight;
pub const edgeGap = taskbar_metrics.edgeGap;
pub const reservedHeight = taskbar_metrics.reservedHeight;
pub const barRadius = taskbar_metrics.barRadius;
pub const chipGap = taskbar_metrics.chipGap;
pub const chipVerticalMargin = taskbar_metrics.chipVerticalMargin;
pub const chipSize = taskbar_metrics.chipSize;
pub const tileSize = taskbar_metrics.tileSize;
pub const chipPad = taskbar_metrics.chipPad;
pub const trayHit = taskbar_metrics.trayHit;
pub const buttonSize = taskbar_metrics.buttonSize;
pub const startButtonGap = taskbar_metrics.startButtonGap;
pub const startButtonLeft = taskbar_metrics.startButtonLeft;
pub const endInset = taskbar_metrics.endInset;
pub const rightPad = taskbar_metrics.rightPad;
pub const startButtonBox = taskbar_metrics.startButtonBox;
pub const startIconSize = taskbar_metrics.startIconSize;
pub const firstChipX = taskbar_metrics.firstChipX;

/// Logical px between the bar and the output edge it sits on, kept small
/// enough that a bad theme can't push the bar off the screen.
pub const max_edge_gap: f32 = 64;
pub const edge_pad: i32 = 20;
// Anchor sizes at the original 54px bar / 8px item gap (a
// 42px-tall chip with a 23px icon tile). Every other taskbar-item size below
// is a function of the live bar height and item gap, scaled from these two
// anchors, so shrinking `taskbar_size` (down to `min_bar_height`) or growing
// `chip_gap` shrinks the pills/tiles/tray targets together instead of
// clipping or leaving them floating in oversized empty space.
pub const min_bar_height: i32 = 36;
pub const base_chip_size: i32 = 42;
pub const icon_scale: f32 = 0.8 * 1.1;
pub const base_tile_size: f32 = 26 * icon_scale;
pub const tile_radius: f32 = 4;

// Top/bottom breathing room around each chip pill. Tied to the same
// "Window item gap" slider that spaces pills horizontally (chipGap above),
// so one control changes both at once; capped so a large gap can't collapse
// the pill down to nothing.
pub const default_chip_vertical_margin: f32 = (@as(f32, @floatFromInt(default_bar_height)) - @as(f32, @floatFromInt(base_chip_size))) / 2;
pub const max_chip_vertical_margin: f32 = 16.0;
pub const min_chip_size: i32 = 18;
pub const min_tile_size: i32 = 10;
pub const icon_text_gap: i32 = 9;
pub const title_pad_right: i32 = 16;

pub const base_tray_hit: i32 = 34;
pub const min_tray_hit: i32 = 20;
pub const tray_radius: f32 = 5;
pub const tray_gap: i32 = 6;

pub const clock_gap: i32 = 16;
pub const chip_clock_gap: i32 = 16;
pub const paint_start: u8 = 1 << 0;
pub const paint_chips: u8 = 1 << 1;
pub const paint_tray: u8 = 1 << 2;
pub const paint_clock: u8 = 1 << 3;
pub const paint_hover: u8 = 1 << 4;
pub const paint_press: u8 = 1 << 5;
pub const paint_audio: u8 = 1 << 6;
pub const paint_capture: u8 = 1 << 7;
pub const capture_label = "Stop sharing";

pub const press_scale: f32 = 0.92;
pub const volume_scroll_step: f32 = 0.05;

server: *Server,
wlr_output: *wlr.Output,
tree: *sn.Tree,
// The background remains the taskbar's full-width glass anchor. Foreground
// controls are separate scene buffers above it so their replacement damages
// only their own bounds.
buffer_node: *sn.Buffer,
start_node: *sn.Buffer,
clock_node: *sn.Buffer,
tray_nodes: [tray_count]*sn.Buffer,
app_tray_node: *sn.Buffer,
app_tray_generation: u64 = 0,
capture_node: *sn.Buffer,
battery_node: *sn.Buffer,
battery_state: battery.State = .{},
battery_dirty: bool = true,
battery_shimmer: battery_highlight.Highlight = .{},
node_data: scene_data.SceneData = undefined,
timer: *wl.EventSource,
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = default_bar_height },
// The strip it claims from the output edge, as last laid out: `box.height`
// plus the gap. Beside a short bar the strip stays whole.
reserved: i32 = default_bar_height,
// The original look: edge to edge, on the output's edge, square.
flush: bool = true,
// How far the background raster reaches past the output's far edges.
bleed: Bleed = .{},
glass_effect: ?*glass.Effect = null,
item_layout: taskbar_items.Layout = .{},
dirty: bool = true,
paint_causes: u8 = 0,
background_dirty: bool = true,
start_dirty: bool = true,
clock_dirty: bool = true,
tray_dirty: [tray_count]bool = @splat(true),
capture_dirty: bool = true,
capture_sessions: usize = 0,

start: start_button.State = .{},
start_logo: ?icon_service.Entry = null,
chips: std.ArrayList(ChipState) = .empty,
tray: [tray_count]TrayState = .{ .{ .kind = .volume }, .{ .kind = .wifi }, .{ .kind = .power }, .{ .kind = .wired } },
capture_hover: Anim = .{},
capture_press: Anim = .{ .to = 1 },
hover_target: Target = .none,

// Cached master-volume display state, refreshed from `server.audio` only
// when its `generation` counter has moved since we last looked (see
// audio/pipewire.zig's module doc comment) — checked once per `tick()`
// rather than reaching into the AudioManager lock during every pixel of
// `render()`.
audio_generation_seen: u32 = 0,
audio_volume: f32 = 0,
audio_muted: bool = false,
// NetworkManager reports no connection: the wifi icon is drawn in the danger
// colour, like a muted speaker. Pushed by `network.Manager`, never polled.
network_offline: bool = false,
// Whether a wireless adapter exists and a cable is connected: decides the
// automatic Wi-Fi and Ethernet items. Pushed by `network.Manager`.
network_presence: taskbar_items.Presence = .{},
// While offline the wifi icon also blinks (one cycle a second) so a dropped
// connection stands out. A real deadline only while offline: the timer is
// created on first need, disarmed on reconnect, and each tick repaints just
// that icon. Reduced motion keeps the icon solid.
blink_timer: ?*wl.EventSource = null,
blink_dim: bool = false,

clock_time: [16]u8 = [_]u8{0} ** 16,
clock_date: [128]u8 = [_]u8{0} ** 128,
clock_locale: c_time.locale_t = null,
clock_minute: c_time.time_t = 0,
// Layout and every tick ask for these; shaping them each time showed up in
// idle profiles. The clock column only ever grows while its settings stay the
// same (see `updateClockStrings`), so a ticking clock never moves its neighbours.
clock_width: MeasuredWidth = .{},
clock_digit: MeasuredWidth = .{},
clock_style: u8 = 0,
capture_width: MeasuredWidth = .{},

pub const MeasuredWidth = struct {
    width: f32 = 0,
    scale: f32 = 0,
    font_generation: u32 = 0,
    valid: bool = false,

    pub fn get(self: *const MeasuredWidth, scale: f32) ?f32 {
        if (!self.valid or self.scale != scale or self.font_generation != text.font_generation) return null;
        return self.width;
    }

    pub fn put(self: *MeasuredWidth, scale: f32, width: f32) f32 {
        self.* = .{ .width = width, .scale = scale, .font_generation = text.font_generation, .valid = true };
        return width;
    }
};

// `wired` comes last so the IPC tray indices of the other icons stay put.
pub const TrayKind = enum { volume, wifi, power, wired };
pub const tray_count = std.meta.fields(TrayKind).len;

pub const AppKind = enum { file_explorer, notes, terminal, settings, text_doc, browser, other };

pub const ChipState = struct {
    toplevel: *Toplevel,
    buffer_node: ?*sn.Buffer = null,
    dirty: bool = true,
    kind: AppKind = .other,
    // A real icon found via the XDG icon theme, when one exists; falls back
    // to the hand-drawn `tileStyle`/`glyphSd` tile below when null.
    icon: ?icon_service.Entry = null,
    target_x: f32 = 0,
    // Struct field defaults must be comptime; the anchor size is fine here
    // since `reconcile` always overwrites this with the live `chipSize()`
    // (via `sharedChipWidth`) right after construction.
    width: f32 = @floatFromInt(base_chip_size),
    flip: Anim = .{},
    hover: Anim = .{},
    press: Anim = .{ .to = 1 },
    // What the raster on screen was painted from; see `ChipMemo`.
    painted: ?ChipMemo = null,
    // That raster, still referenced here, and the sampled paint and placement
    // it used: a change of title alone copies it and repaints only the title.
    raster: ?*BarBuffer = null,
    raster_key: ?ChipRasterKey = null,

    pub fn renderX(self: ChipState, now_ms: i64) f32 {
        return self.target_x + self.flip.value(now_ms);
    }
};

// Inputs to a chip raster that `reconcile` can change, so a title change
// (terminal spinners, tab counters) repaints only its own chip. Hover and
// press curves mark chips dirty from `tick`, and `relayout` repaints
// everything. The theme fields are snapshotted because colour-only reskins
// arrive through here, like chrome.TitlebarMemo.
pub const ChipMemo = struct {
    x: f32,
    width: f32,
    active: bool,
    needs_attention: bool,
    kind: AppKind,
    icon: ?u64,
    title_hash: u64,
    scale: f32,
    bar_height: i32,
    chip_size: i32,
    tile_size: i32,
    chip_pad: i32,
    radius: f32,
    title_size: f32,
    font: []const u8,
    colors: [6][4]f32,

    pub fn capture(bar: *Taskbar, chip: *const ChipState, now_ms: i64) ChipMemo {
        const t = ui_theme.global;
        return .{
            .x = chip.renderX(now_ms),
            .width = chip.width,
            .active = chip.toplevel == bar.server.world.toplevels.first(),
            .needs_attention = chip.toplevel.needs_attention,
            .kind = chip.kind,
            .icon = if (chip.icon) |icon| icon.id else null,
            // Covers the monogram too: both fall back from title to app_id.
            .title_hash = std.hash.Wyhash.hash(0, chipTitle(chip.toplevel)),
            .scale = bar.wlr_output.scale,
            .bar_height = bar.box.height,
            .chip_size = chipSize(),
            .tile_size = tileSize(),
            .chip_pad = chipPad(),
            .radius = t.radius,
            .title_size = t.taskbar_title_size,
            .font = t.font,
            .colors = .{ ui_theme.taskbar(.taskbar_surface), ui_theme.taskbar(.taskbar_hover), ui_theme.taskbar(.surface_hover), ui_theme.taskbar(.taskbar_border), ui_theme.taskbar(.border_soft), ui_theme.taskbar(.window_fg) },
        };
    }
};

// Chip raster inputs that `ChipMemo` leaves to the hover/press curves and
// FLIP offset, sampled as `ChipPaint` does, plus the buffer placement. Chips
// without an icon draw a monogram taken from the title into their tile.
pub const ChipRasterKey = struct {
    left: i32,
    width: i32,
    scale: f32,
    x: f32,
    fill: Color,
    border: Color,
    monogram: [4]u8 = @splat(0),
    monogram_len: usize = 0,

    pub fn capture(bar: *Taskbar, now_ms: i64, chip: *const ChipState, left: i32, width: i32) ChipRasterKey {
        const paint = ChipPaint.init(bar, now_ms, chip);
        var key: ChipRasterKey = .{
            .left = left,
            .width = width,
            .scale = bar.wlr_output.scale,
            .x = paint.x,
            .fill = paint.fill,
            .border = paint.border,
        };
        if (chip.icon == null and chip.kind == .other) {
            var storage: [4]u8 = undefined;
            const label = monogramOf(chip.toplevel, &storage);
            @memcpy(key.monogram[0..label.len], label);
            key.monogram_len = label.len;
        }
        return key;
    }
};

pub const TrayState = struct {
    kind: TrayKind,
    hover: Anim = .{},
    press: Anim = .{ .to = 1 },
};

pub const Target = union(enum) { none, clock, battery, start_button, chip: *Toplevel, tray: usize, capture_indicator };

pub fn targetEql(a: Target, b: Target) bool {
    return switch (a) {
        .none => b == .none,
        .clock => b == .clock,
        .battery => b == .battery,
        .start_button => b == .start_button,
        .chip => |t| switch (b) {
            .chip => |t2| t == t2,
            else => false,
        },
        .tray => |i| switch (b) {
            .tray => |other| i == other,
            else => false,
        },
        .capture_indicator => b == .capture_indicator,
    };
}

pub fn create(server: *Server, wlr_output: *wlr.Output) !*Taskbar {
    const bar = try gpa.create(Taskbar);
    errdefer gpa.destroy(bar);

    const tree = try server.taskbar_tree.createSceneTree();
    errdefer tree.node.destroy();
    const buffer_node = try tree.createSceneBuffer(null);
    const start_node = try tree.createSceneBuffer(null);
    const clock_node = try tree.createSceneBuffer(null);
    var tray_nodes: [tray_count]*sn.Buffer = undefined;
    for (&tray_nodes) |*node| node.* = try tree.createSceneBuffer(null);
    const app_tray_node = try tree.createSceneBuffer(null);
    const capture_node = try tree.createSceneBuffer(null);
    const battery_node = try tree.createSceneBuffer(null);
    // Preserve glyph coverage when fractional-scale destination rounding
    // makes the scene box differ from the raster by a device pixel.
    buffer_node.setFilterMode(.bilinear);
    const glass_effect = glass.Engine.attach(server.glass_engine, buffer_node, &buffer_node.node, .taskbar);

    bar.* = .{
        .server = server,
        .wlr_output = wlr_output,
        .tree = tree,
        .buffer_node = buffer_node,
        .start_node = start_node,
        .clock_node = clock_node,
        .tray_nodes = tray_nodes,
        .app_tray_node = app_tray_node,
        .capture_node = capture_node,
        .battery_node = battery_node,
        .glass_effect = glass_effect,
        .battery_state = battery.read(server.io, gpa),
        .network_offline = if (server.network) |network| network.offline() else false,
        .network_presence = if (server.network) |network| network.presence() else .{},
        .clock_minute = @divFloor(c_time.time(null), 60),
        .timer = undefined,
    };
    bar.node_data = .{ .role = .{ .taskbar = bar } };
    scene_data.SceneData.attach(&bar.node_data, &buffer_node.node);
    scene_data.SceneData.attach(&bar.node_data, &start_node.node);
    scene_data.SceneData.attach(&bar.node_data, &clock_node.node);
    for (tray_nodes) |node| scene_data.SceneData.attach(&bar.node_data, &node.node);
    scene_data.SceneData.attach(&bar.node_data, &app_tray_node.node);
    app_tray_node.setFilterMode(.bilinear);
    scene_data.SceneData.attach(&bar.node_data, &capture_node.node);
    capture_node.setFilterMode(.bilinear);
    capture_node.node.setEnabled(false);
    scene_data.SceneData.attach(&bar.node_data, &battery_node.node);
    battery_node.setFilterMode(.bilinear);
    battery_node.node.setEnabled(false);
    bar.refreshStartLogo();
    bar.timer = try server.wl_server.getEventLoop().addTimer(*Taskbar, onTick, bar);
    errdefer bar.timer.remove();
    bar.updateClockLocale();
    _ = bar.updateClockStrings();
    bar.scheduleClockTick();
    bar.syncBlink();
    return bar;
}

pub fn destroy(bar: *Taskbar) void {
    if (bar.server.tray) |tray_mgr| tray_mgr.closeMenu();
    bar.server.input.detachTaskbar(bar);
    bar.timer.remove();
    if (bar.blink_timer) |timer| timer.remove();
    if (bar.clock_locale) |locale| c_time.freelocale(locale);
    if (bar.start_logo) |e| bar.server.iconRelease(e.id);
    for (bar.chips.items) |chip| {
        if (chip.raster) |raster| raster.base.drop();
        if (chip.icon) |e| bar.server.iconRelease(e.id);
    }
    bar.chips.deinit(gpa);
    bar.tree.node.destroy();
    gpa.destroy(bar);
}

/// Takes a fresh `battery.read` snapshot; only a change requests a frame.
pub fn applyBattery(bar: *Taskbar, next: battery.State) void {
    if (std.meta.eql(next, bar.battery_state)) return;
    const layout_changed = (next.percent == null) != (bar.battery_state.percent == null);
    bar.battery_shimmer.update(bar.battery_state, next, nowMs());
    bar.battery_state = next;
    if (Output.fromWlr(bar.wlr_output)) |output| {
        if (next.percent == null) output.closeBattery() else if (output.battery_popup) |popup| popup.refresh();
    }
    bar.battery_dirty = true;
    if (layout_changed) {
        _ = bar.reconcile(nowMs());
        bar.tray_dirty = @splat(true);
        bar.clock_dirty = true;
        bar.capture_dirty = true;
    }
    bar.markDirty(paint_tray);
    bar.wlr_output.scheduleFrame();
}

/// A flip of `network.Manager.offline` recolours the network icons; nothing
/// else about the tray changes, so only those icons repaint.
pub fn applyNetwork(bar: *Taskbar, offline: bool) void {
    if (offline == bar.network_offline) return;
    bar.network_offline = offline;
    bar.blink_dim = false;
    bar.syncBlink();
    bar.tray_dirty[@intFromEnum(TrayKind.wifi)] = true;
    bar.tray_dirty[@intFromEnum(TrayKind.wired)] = true;
    bar.markDirty(paint_tray);
    bar.wlr_output.scheduleFrame();
}

/// An adapter or a cable appearing or going shows or hides the automatic
/// items, which moves their neighbours like a battery coming or going.
pub fn applyNetworkPresence(bar: *Taskbar, next: taskbar_items.Presence) void {
    if (std.meta.eql(next, bar.network_presence)) return;
    bar.network_presence = next;
    _ = bar.reconcile(nowMs());
    bar.tray_dirty = @splat(true);
    bar.clock_dirty = true;
    bar.capture_dirty = true;
    bar.markDirty(paint_tray | paint_clock | paint_capture);
    bar.wlr_output.scheduleFrame();
}

pub const blink_half_ms = 500;

/// Arm the blink timer while offline, disarm it otherwise.
pub fn syncBlink(bar: *Taskbar) void {
    if (bar.network_offline and !anim.reducedMotion()) {
        if (bar.blink_timer == null) {
            bar.blink_timer = bar.server.wl_server.getEventLoop().addTimer(*Taskbar, onBlink, bar) catch |err| {
                log.err("syncBlink: could not create blink timer: {}", .{err});
                return;
            };
        }
        bar.blink_timer.?.timerUpdate(blink_half_ms) catch {};
    } else if (bar.blink_timer) |timer| {
        timer.timerUpdate(0) catch {};
    }
}

pub fn onBlink(bar: *Taskbar) c_int {
    if (!bar.network_offline or anim.reducedMotion()) {
        // Settle on a solid icon; the timer stays disarmed.
        if (bar.blink_dim) bar.repaintWifi();
        bar.blink_dim = false;
        return 0;
    }
    bar.blink_dim = !bar.blink_dim;
    bar.repaintWifi();
    bar.blink_timer.?.timerUpdate(blink_half_ms) catch {};
    return 0;
}

pub fn repaintWifi(bar: *Taskbar) void {
    if (!bar.itemShown(.wifi) and !bar.itemShown(.wired)) return;
    bar.tray_dirty[@intFromEnum(TrayKind.wifi)] = true;
    bar.tray_dirty[@intFromEnum(TrayKind.wired)] = true;
    bar.markDirty(paint_tray);
    bar.wlr_output.scheduleFrame();
}

pub fn onTick(bar: *Taskbar) c_int {
    // Seconds only repaint the clock. Keep expensive sysfs reads and the
    // calendar on their minute cadence; plug events have their own uevent.
    const minute = @divFloor(c_time.time(null), 60);
    if (minute != bar.clock_minute) {
        bar.clock_minute = minute;
        bar.applyBattery(battery.read(bar.server.io, gpa));
        if (Output.fromWlr(bar.wlr_output)) |output| {
            if (output.calendar) |calendar| calendar.refresh();
        }
    }
    bar.refreshClock(false);
    bar.scheduleClockTick();
    return 0;
}

pub fn markPaintCauseFromTarget(target: Target) u8 {
    return switch (target) {
        .none => 0,
        .clock => paint_clock,
        .battery => paint_tray,
        .start_button => paint_start,
        .chip => paint_chips,
        .tray => paint_tray,
        .capture_indicator => paint_capture,
    };
}

pub fn markDirty(bar: *Taskbar, cause: u8) void {
    bar.dirty = true;
    bar.paint_causes |= cause;
}

// taskbar/clock.zig
pub const scheduleClockTick = taskbar_clock.scheduleClockTick;
pub const updateClockLocale = taskbar_clock.updateClockLocale;
pub const refreshClockSettings = taskbar_clock.refreshClockSettings;
pub const refreshClock = taskbar_clock.refreshClock;
pub const updateClockStrings = taskbar_clock.updateClockStrings;

// taskbar/layout.zig
pub const placement = taskbar_layout.placement;
pub const bleedFor = taskbar_layout.bleedFor;
pub const boxesOverlap = taskbar_layout.boxesOverlap;
pub const isPlaced = taskbar_layout.isPlaced;
pub const relayout = taskbar_layout.relayout;
pub const notifyToplevelsChanged = taskbar_layout.notifyToplevelsChanged;

/// Logical px the bar's background reaches past the far edges of its output.
pub const Bleed = struct { x: i32 = 0, y: i32 = 0 };

pub const clock_time_size: f32 = 14;
pub const clock_date_size: f32 = 11;

/// One piece of the time line: a single digit in a fixed cell, or a run of
/// everything between digits (":", " PM"). `x` is its offset from the line's
/// start and `w` the width of its own text.
pub const ClockPiece = struct { text: []const u8, x: i32, w: i32 };
pub const clock_pieces_max = 16;
pub const ClockLine = struct { pieces: [clock_pieces_max]ClockPiece = undefined, count: usize = 0, width: i32 = 0 };

// taskbar/clock.zig
pub const clockFont = taskbar_clock.clockFont;
pub const clockStyleChanged = taskbar_clock.clockStyleChanged;
pub const clockDigitCell = taskbar_clock.clockDigitCell;
pub const clockLine = taskbar_clock.clockLine;
pub const measureClockColumn = taskbar_clock.measureClockColumn;
pub const clockColumnWidth = taskbar_clock.clockColumnWidth;

// taskbar/layout.zig
pub const rightLayout = taskbar_layout.rightLayout;
pub const startX = taskbar_layout.startX;
pub const calculateLayout = taskbar_layout.calculateLayout;
pub const itemBox = taskbar_layout.itemBox;
pub const batteryX = taskbar_layout.batteryX;
pub const clockX = taskbar_layout.clockX;
pub const trayItem = taskbar_layout.trayItem;
pub const itemShown = taskbar_layout.itemShown;
pub const capturing = taskbar_layout.capturing;
pub const captureWidth = taskbar_layout.captureWidth;
pub const captureLabelWidth = taskbar_layout.captureLabelWidth;
pub const captureX = taskbar_layout.captureX;
pub const captureIndicatorBox = taskbar_layout.captureIndicatorBox;
pub const sharedChipWidth = taskbar_layout.sharedChipWidth;

pub const battery_width = battery_badge.width;

// taskbar/reconcile.zig
pub const refreshStartLogo = taskbar_reconcile.refreshStartLogo;
pub const updateIcon = taskbar_reconcile.updateIcon;
pub const taskbarOrderLessThan = taskbar_reconcile.taskbarOrderLessThan;
pub const reconcile = taskbar_reconcile.reconcile;

// taskbar/tick.zig
pub const tick = taskbar_tick.tick;
pub const captureAnimations = taskbar_tick.captureAnimations;
pub const appendAnimations = taskbar_tick.appendAnimations;
pub const appendLive = taskbar_tick.appendLive;
pub const trayPositions = taskbar_tick.trayPositions;

// taskbar/pointer.zig
pub const hitTest = taskbar_pointer.hitTest;
pub const pointerMotion = taskbar_pointer.pointerMotion;
pub const pointerLeave = taskbar_pointer.pointerLeave;
pub const setHover = taskbar_pointer.setHover;
pub const pointerPress = taskbar_pointer.pointerPress;
pub const scrollVolume = taskbar_pointer.scrollVolume;

// taskbar/classify.zig
pub const containsIgnoreCase = taskbar_classify.containsIgnoreCase;
pub const matchesAny = taskbar_classify.matchesAny;
pub const classify = taskbar_classify.classify;
pub const chipTitle = taskbar_classify.chipTitle;
pub const monogramOf = taskbar_classify.monogramOf;

// ---- Colors (design-system tokens shared with chrome.zig where noted) ----
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    // Exact CSS tints; glass.c supplies the filtered backdrop underneath.
    pub fn bar_fill() Color {
        return fromRgba(ui_theme.taskbar(.taskbar_bg));
    }
    pub fn hairline() Color {
        return fromRgba(ui_theme.taskbar(.border_soft));
    }
    // The bar's own outline; unset it is the hairline `border_soft` always drew.
    pub fn outline() Color {
        return fromRgba(ui_theme.taskbar(.taskbar_outline) orelse ui_theme.taskbar(.border_soft));
    }
    pub fn chip_idle() Color {
        return fromRgba(ui_theme.taskbar(.taskbar_surface));
    }
    pub fn hover_fill() Color {
        return fromRgba(ui_theme.taskbar(.surface_hover));
    }
    pub fn active_fill() Color {
        return fromRgba(ui_theme.taskbar(.taskbar_hover)).scaled(2.8);
    }
    pub fn fromRgba(c: [4]f32) Color {
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    }
    pub fn chip_title_idle() text.Color {
        return textColor(fromRgba(ui_theme.taskbar(.window_fg)));
    }
    pub fn tray_icon() Color {
        return fromRgba(ui_theme.taskbar(.window_fg));
    }
    pub fn tray_icon_hover() Color {
        return fromRgba(ui_theme.taskbar(.window_fg));
    }
    pub const glyph = Color{ .r = 1, .g = 1, .b = 1, .a = 0.96 };
    pub fn clock_time() text.Color {
        return textColor(fromRgba(ui_theme.taskbar(.window_fg)));
    }
    pub fn clock_date() text.Color {
        return textColor(fromRgba(ui_theme.taskbar(.window_dim)));
    }

    pub fn over(source: Color, destination: Color) Color {
        const alpha = source.a + destination.a * (1 - source.a);
        if (alpha == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .r = (source.r * source.a + destination.r * destination.a * (1 - source.a)) / alpha,
            .g = (source.g * source.a + destination.g * destination.a * (1 - source.a)) / alpha,
            .b = (source.b * source.a + destination.b * destination.a * (1 - source.a)) / alpha,
            .a = alpha,
        };
    }

    pub fn lerp(from: Color, to: Color, t: f32) Color {
        const ct = clamp01(t);
        return .{
            .r = from.r + (to.r - from.r) * ct,
            .g = from.g + (to.g - from.g) * ct,
            .b = from.b + (to.b - from.b) * ct,
            .a = from.a + (to.a - from.a) * ct,
        };
    }

    pub fn scaled(color: Color, alpha: f32) Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = clamp01(color.a * alpha) };
    }

    // Unpacks a premultiplied 0xAARRGGBB sample (icon_cache.Entry.pixels'
    // format) back to this struct's straight alpha, so it can go through the
    // existing `.over()` blend unchanged.
    pub fn fromPremultiplied(sample: u32) Color {
        const a: f32 = @as(f32, @floatFromInt((sample >> 24) & 0xff)) / 255.0;
        if (a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const r: f32 = @as(f32, @floatFromInt((sample >> 16) & 0xff)) / 255.0;
        const g: f32 = @as(f32, @floatFromInt((sample >> 8) & 0xff)) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(sample & 0xff)) / 255.0;
        return .{ .r = r / a, .g = g / a, .b = b / a, .a = a };
    }

    pub fn argb(color: Color) u32 {
        return (col.Straight{ .r = color.r, .g = color.g, .b = color.b, .a = color.a }).argb();
    }
};

// ---- Tile fills, straight from the App Fills table (135deg gradients) ----
pub const Fill = union(enum) { solid: Color, gradient: struct { a: Color, b: Color } };

// taskbar/paint_util.zig
pub const hex = taskbar_paint_util.hex;
pub const tileStyle = taskbar_paint_util.tileStyle;
pub const textColor = taskbar_paint_util.textColor;
pub const gradientColor = taskbar_paint_util.gradientColor;
pub const sdCircle = taskbar_paint_util.sdCircle;
pub const glyphSd = taskbar_paint_util.glyphSd;
pub const edgeCoverage = taskbar_paint_util.edgeCoverage;
pub const clamp01 = taskbar_paint_util.clamp01;

pub const TileStyle = struct { fill: Fill, hairline: bool };

// ---- The buffer itself: same data-pointer wlr.Buffer technique as
// chrome.ChromeBuffer, recreated wholesale on every repaint. ----
pub const BarBuffer = struct {
    base: wlr.Buffer,
    width: i32,
    height: i32,
    logical_width: i32,
    scale: f32,
    pixels: []u32,

    pub const drm_format_argb8888: u32 = 0x34325241;

    pub const impl = wlr.Buffer.Impl{
        .destroy = destroyBuffer,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginDataPtrAccess,
        .end_data_ptr_access = endDataPtrAccess,
    };

    pub fn create(logical_width: i32, logical_height: i32, scale: f32) !*BarBuffer {
        const buf = try gpa.create(BarBuffer);
        errdefer gpa.destroy(buf);

        const width = geometry.devicePixels(logical_width, scale);
        const height = geometry.devicePixels(logical_height, scale);
        const length: usize = @intCast(width * height);
        const pixels = try gpa.alloc(u32, length);
        errdefer gpa.free(pixels);

        buf.* = .{ .base = undefined, .width = width, .height = height, .logical_width = logical_width, .scale = scale, .pixels = pixels };
        buf.base.init(&impl, width, height);
        return buf;
    }

    pub fn destroyBuffer(base: *wlr.Buffer) callconv(.c) void {
        const buf: *BarBuffer = @fieldParentPtr("base", base);
        gpa.free(buf.pixels);
        gpa.destroy(buf);
    }

    pub fn beginDataPtrAccess(base: *wlr.Buffer, _: u32, data: **anyopaque, format: *u32, stride: *usize) callconv(.c) bool {
        const buf: *BarBuffer = @fieldParentPtr("base", base);
        data.* = @ptrCast(buf.pixels.ptr);
        format.* = drm_format_argb8888;
        stride.* = @as(usize, @intCast(buf.width)) * @sizeOf(u32);
        return true;
    }

    pub fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}
};

pub const Part = union(enum) { background, start, clock, chip: *const ChipState, tray: usize, capture, battery };

// taskbar/paint.zig
pub const render = taskbar_paint.render;
pub const renderPart = taskbar_paint.renderPart;
pub const sampleIcon = taskbar_paint.sampleIcon;
pub const paintPartPixel = taskbar_paint.paintPartPixel;
pub const paintBatteryPixel = taskbar_paint.paintBatteryPixel;
pub const paintCapturePixel = taskbar_paint.paintCapturePixel;
pub const chipPixelArgb = taskbar_paint.chipPixelArgb;
pub const paintChipPixel = taskbar_paint.paintChipPixel;
pub const paintTrayPixel = taskbar_paint.paintTrayPixel;

pub const ChipPaint = struct {
    chip: *const ChipState,
    x: f32,
    fill: Color,
    border: Color,
    bar_height: i32,
    flat: ChipFlat = .{},

    pub fn init(bar: *Taskbar, now_ms: i64, chip: *const ChipState) ChipPaint {
        const active = chip.toplevel == bar.server.world.toplevels.first();
        const hover = chip.hover.value(now_ms);
        const press_strength = std.math.clamp((1 - chip.press.value(now_ms)) / (1 - press_scale), 0, 1);
        const style = @import("taskbar/chip_style.zig").lookFrom(Color, .taskbar, active, chip.toplevel.needs_attention, hover, press_strength);
        var paint: ChipPaint = .{
            .chip = chip,
            .x = chip.renderX(now_ms),
            .fill = style.fill,
            .border = style.border,
            .bar_height = bar.box.height,
        };
        paint.flat = .init(&paint, bar.wlr_output.scale);
        return paint;
    }
};

// Most of a chip is empty or flat fill. Pixels at least one logical pixel
// from every edge and from the icon tile get exactly what `paintChipPixel`
// computes there, without its three SDFs, which were most of the raster
// time. One pixel of distance saturates coverage only from scale 0.75 up.
pub const ChipFlat = struct {
    enabled: bool = false,
    outer: Rect = undefined,
    // The inner rounded box, shrunk by the margin, minus its corners.
    band_h: Rect = undefined,
    band_v: Rect = undefined,
    tile: Rect = undefined,
    fill: u32 = 0,

    pub const Rect = struct {
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,

        pub fn contains(r: Rect, x: f32, y: f32) bool {
            return x >= r.x0 and x <= r.x1 and y >= r.y0 and y <= r.y1;
        }
    };

    pub fn init(paint: *const ChipPaint, scale: f32) ChipFlat {
        const x = paint.x;
        const y: f32 = @floatFromInt(@divTrunc(paint.bar_height - chipSize(), 2));
        const w = paint.chip.width;
        const h: f32 = @floatFromInt(chipSize());
        // `paintChipPixel`'s inner box, with sdRoundedBox's radius clamp.
        const iw = w - 2;
        const ih = h - 2;
        const corner = @max(1, @min(@max(0, ui_theme.global.radius - 1), @min(iw, ih) / 2));
        const tile_x = x + @as(f32, @floatFromInt(chipPad()));
        const tile_y = y + @as(f32, @floatFromInt(chipPad()));
        const tile: f32 = @floatFromInt(tileSize());
        const clear: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .enabled = scale >= 0.75,
            .outer = .{ .x0 = x - 1, .y0 = y - 1, .x1 = x + w + 1, .y1 = y + h + 1 },
            .band_h = .{ .x0 = x + 1 + corner, .y0 = y + 2, .x1 = x + 1 + iw - corner, .y1 = y + ih },
            .band_v = .{ .x0 = x + 2, .y0 = y + 1 + corner, .x1 = x + iw, .y1 = y + 1 + ih - corner },
            .tile = .{ .x0 = tile_x - 1, .y0 = tile_y - 1, .x1 = tile_x + tile + 1, .y1 = tile_y + tile + 1 },
            // The same expression `paintChipPixel` evaluates at full coverage.
            .fill = Color.lerp(paint.border, paint.fill, 1).scaled(1).over(clear).argb(),
        };
    }
};

// taskbar/chip_text.zig
pub const fillChipColumns = taskbar_chip_text.fillChipColumns;
pub const chipTitleRect = taskbar_chip_text.chipTitleRect;
pub const chipTitleColor = taskbar_chip_text.chipTitleColor;
pub const drawChipTitle = taskbar_chip_text.drawChipTitle;
pub const paintChipTitleColumns = taskbar_chip_text.paintChipTitleColumns;
pub const repaintChipTitle = taskbar_chip_text.repaintChipTitle;
pub const drawCenteredText = taskbar_chip_text.drawCenteredText;
pub const drawPartText = taskbar_chip_text.drawPartText;

// Theme-driven item sizing must reproduce the default 38/21/31px layout
// at the defaults, then scale down as the bar shrinks or the item
// gap grows, staying at or above the floors that keep pills/tiles/targets
// legible and non-overlapping.

// taskbar/app_tray.zig
pub const appTrayCount = taskbar_app_tray.appTrayCount;
pub const appTrayLeft = taskbar_app_tray.appTrayLeft;
pub const appTrayBox = taskbar_app_tray.appTrayBox;
pub const appTrayAt = taskbar_app_tray.appTrayAt;
pub const renderAppTray = taskbar_app_tray.renderAppTray;

test {
    _ = @import("taskbar/tests.zig");
}
