//! Optional output-local launcher. Retained rasters; animation uses output frames.
//! The last raster is kept (`retained`): an icon that animates repaints only its
//! own cell over it (`itemCell`, `changedCells`) and publishes only that damage.
//! Anything the dock draws outside every item's cell must key `base_key` instead.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("node.zig");
const ui = @import("ui");
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const IconEntry = @import("icon_service.zig").Entry;
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const SceneData = @import("scene_data.zig").SceneData;
const glass = @import("glass.zig");
const apps = @import("start_menu/applications.zig");
const default_apps = @import("config_runtime/default_apps.zig");
const config = @import("config").loader;
const anim = ui.anim;
const gpa = @import("main.zig").gpa;
const Self = @This();
const max_items = 64;
/// Applications pinned to the dock by dragging them from the start menu.
pub const max_pins = 16;
/// `trash` follows `dock_show_trash`; the others `dock_hidden_shortcuts`.
pub const Shortcut = enum { applications, files, terminal, settings, trash };
const shortcut_count = std.enums.values(Shortcut).len;
/// The gap between the dock and its output edge, and the one between it and the
/// windows when it reserves its strip.
const edge_margin = 5;
const window_margin = 10;
/// Auto-hide: the outermost pixels of the edge that reveal the dock, how long
/// the pointer must stay (so a pass over the edge shows nothing) or stay away
/// (so a slip off the dock hides nothing), and how far the dock travels while
/// it fades.
const edge_band = 2;
const reveal_delay_ms = 120;
const hide_delay_ms = 400;
const slide_distance = 20;
/// How long the pointer rests on an icon before its tooltip (the window title)
/// shows.
const tooltip_delay_ms = 1500;

/// Scale the original 68px layout in logical pixels, independently of output scale.
const Metrics = struct {
    height: i32,

    fn size(self: Metrics, reference: f32) f32 {
        return reference * @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(config.dock_height_default));
    }

    fn length(self: Metrics, reference: f32) i32 {
        return @max(1, @as(i32, @intFromFloat(@round(self.size(reference)))));
    }

    fn itemStep(self: Metrics) i32 {
        return self.length(56);
    }

    fn padding(self: Metrics) i32 {
        return self.length(12);
    }
};

/// A pinned application as the last rebuild resolved it. Strings are copies
/// (`pin_arena`), so they outlive the catalogue snapshot they came from.
const PinnedApp = struct {
    id: []const u8,
    name: []const u8,
    icon: []const u8,
    wm_class: ?[]const u8,
    /// Never 0: animations use 0 for "not a pin".
    hash: u64,
    /// Index in `dock_pinned_apps`, which also lists apps no longer installed.
    config_index: usize,

    fn match(self: PinnedApp) AppMatch {
        return .{ .id = self.id, .wm_class = self.wm_class };
    }
};

const ItemAnimation = struct {
    shortcut: ?Shortcut = null,
    pin: u64 = 0,
    id: u64 = 0,
    width: anim.Anim = .{},
    opacity: anim.Anim = .{ .property = .opacity },
    zoom: anim.Anim = .{ .from = 1, .to = 1 },
};

output: ?*Output = null,
tree: ?*sn.Tree = null,
node: ?*sn.Buffer = null,
/// Transparent, fixed-size anchor: glass follows the dock background, while
/// the painted buffer may extend inward to fit a fully enlarged icon.
glass_anchor: ?*sn.Buffer = null,
tooltip: ?*sn.Buffer = null,
glass_effect: ?*glass.Effect = null,
/// The glass corner radius of the last paint; its opacity follows `reveal`.
glass_radius: f32 = 0,
data: SceneData = undefined,
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = config.dock_height_default },
position: @import("config").types.DockPosition = .bottom,
scale: f32 = 0,
dirty: bool = true,
/// The dock could be on screen: sized to fit, no lock, no fullscreen window.
/// With auto-hide it still shows only while `reveal` is above zero.
visible: bool = false,
/// Auto-hide. `pointer_near` is where the pointer wants the dock (at the edge,
/// or on a shown dock); `shown` is what the reveal heads for, which follows it
/// after a delay (`timer`, armed for `timer_target`). `reveal` runs 0 (away) to
/// 1 and drives the fade and slide; `parked` is hidden and settled, so nothing
/// is rebuilt or painted.
pointer_near: bool = false,
shown: bool = false,
timer: ?*wl.EventSource = null,
timer_target: ?bool = null,
/// The tooltip waits on `tip_timer` after the pointer moves onto an icon;
/// `tip_ready` is set once the delay has passed and held until it moves off.
tip_timer: ?*wl.EventSource = null,
tip_ready: bool = false,
tip_armed: bool = false,
reveal: anim.Anim = .{ .property = .opacity },
parked: bool = false,
root: ui.layout.Widget = .{ .kind = .container },
input_root: ui.layout.Widget = .{ .kind = .container },
buttons: [max_items]ui.layout.Widget = undefined,
ids: [max_items]u64 = @splat(0),
window_counts: [max_items]usize = @splat(0),
shortcuts: [max_items]?Shortcut = @splat(null),
/// Index into `pins` for the buttons that show a pinned application.
pin_of: [max_items]?u8 = @splat(null),
pins: [max_pins]PinnedApp = undefined,
pin_count: usize = 0,
pin_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
/// Button index the first pin occupies, where a drop at slot 0 lands.
pin_base: usize = 0,
/// Where a dragged application would be pinned: the gap before this pin.
drop_slot: ?usize = null,
animations: [max_items]ItemAnimation = @splat(.{}),
animating: bool = false,
count: usize = 0,
offset: usize = 0,
windows: usize = 0,
dispatcher: ui.input.Dispatcher = .{},
arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
/// Digests of what the dock and its tooltip show. Every window event rebuilds
/// the dock, but most (a title change) alter neither raster: then nothing is
/// repainted.
drawn: u64 = 0,
tip_drawn: u64 = 0,
/// The last complete raster (`gpa`-owned) and the keys it was painted from. An
/// animating icon repaints only its own cell on top of it, and only that cell is
/// published as damage; anything dock-wide repaints the lot.
retained: []u32 = &.{},
base_drawn: u64 = 0,
item_drawn: [max_items]u64 = @splat(0),
items_drawn: usize = 0,

pub fn deinit(self: *Self) void {
    if (self.timer) |timer| timer.remove();
    if (self.tip_timer) |timer| timer.remove();
    if (self.output) |output| if (output.server.input.window_menu.dock == self) output.server.input.window_menu.close();
    self.dispatcher.reset();
    if (self.tree) |tree| tree.node.destroy();
    self.arena.deinit();
    self.pin_arena.deinit();
    gpa.free(self.retained);
    self.* = .{};
}

fn ensureNodes(self: *Self, output: *Output) !void {
    if (self.tree != null) return;
    const tree = try output.server.taskbar_tree.createSceneTree();
    errdefer tree.node.destroy();
    const anchor_buffer = try PanelBuffer.create(1, 1, 1);
    defer anchor_buffer.base.drop();
    const anchor = try tree.createSceneBuffer(&anchor_buffer.base);
    anchor.point_accepts_input = ignoreInput;
    const node = try tree.createSceneBuffer(null);
    const tooltip = try tree.createSceneBuffer(null);
    node.setFilterMode(.bilinear);
    tooltip.setFilterMode(.bilinear);
    tooltip.point_accepts_input = ignoreInput;
    self.output = output;
    self.data = .{ .role = .{ .dock = self } };
    self.data.attach(&node.node);
    node.point_accepts_input = acceptsInput;
    self.tree = tree;
    self.node = node;
    self.glass_anchor = anchor;
    self.tooltip = tooltip;
    self.glass_effect = glass.Engine.attach(output.server.glass_engine, anchor, &anchor.node, .taskbar);
    // A dock that auto-hides starts away; one that does not, in place.
    self.reveal.cancel(if (output.server.config.compositor.dock_auto_hide) 0 else 1);
}

fn ignoreInput(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

fn acceptsInput(node: *sn.Buffer, x: *f64, y: *f64) callconv(.c) bool {
    const self = SceneData.fromNode(&node.node).?.role.dock;
    const raster = self.rasterBox();
    const lx: f32 = @floatCast(x.* + @as(f64, @floatFromInt(raster.x)));
    const ly: f32 = @floatCast(y.* + @as(f64, @floatFromInt(raster.y)));
    return self.root.contains(lx, ly) or self.buttonAt(lx, ly) != null;
}

pub fn tick(self: *Self, output: *Output, now_ms: i64) bool {
    const server = output.server;
    if (!server.config.compositor.dock_enabled or server.greeter_mode or !output.isAvailable() or output.idle_blanked) {
        if (self.tree != null) self.deinit();
        return false;
    }
    self.ensureNodes(output) catch return false;
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(server);
    // The dock sits beside the taskbar, not beside its own reserved strip.
    const area = output.dockAreaBox();
    const m: Metrics = .{ .height = @intCast(server.config.compositor.dock_height) };
    const position = server.config.compositor.dock_position;
    const visible = server.locker == null and fits(&server.config.compositor, area) and
        !(if (focused) |top| top.fullscreen and top.currentOutput() == output else false);
    if (self.visible != visible) {
        self.visible = visible;
        self.leave();
        self.dirty = true;
    }
    if (!visible) {
        self.tree.?.node.setEnabled(false);
        // Coming back (fullscreen ended, unlocked) starts from rest, not from a
        // reveal the pointer asked for before: it must not flash in.
        self.parked = false;
        self.pointer_near = false;
        self.shown = false;
        self.disarm();
        self.reveal.cancel(if (server.config.compositor.dock_auto_hide) 0 else 1);
        if (server.input.window_menu.dock == self) server.input.window_menu.close();
        return false;
    }
    const revealing = self.syncReveal(now_ms);
    if (self.parked) {
        // Away: the next reveal rebuilds and paints before the first frame it shows.
        self.tree.?.node.setEnabled(false);
        self.leave();
        return false;
    }
    if (self.dirty) self.resolvePins();
    const fixed_count = self.fixedCount();
    const available_length = if (position.vertical()) area.height else area.width;
    if (self.scale != output.wlr_output.scale) self.dirty = true;
    if (self.position != position or self.metrics().height != m.height) self.dirty = true;
    // Output geometry can change without a window or theme notification.
    const capacity: usize = @intCast(@min(max_items - fixed_count, @max(0, @divTrunc(available_length - m.padding() * 2 - 16, m.itemStep()) - @as(i32, @intCast(fixed_count)))));
    const wanted = @min(capacity, self.windows) + fixed_count;
    if ((if (position.vertical()) self.box.height else self.box.width) != @as(i32, @intCast(wanted)) * m.itemStep() + m.padding() * 2) self.dirty = true;
    const rebuilt = self.dirty;
    if (rebuilt) self.rebuild(capacity, area) catch return false;
    self.tree.?.node.setEnabled(self.count > 0);
    if (self.count == 0) {
        self.animating = false;
        return revealing;
    }
    self.place(area);
    if (rebuilt or self.animating) {
        self.paint(now_ms) catch return false;
    } else self.paintTooltip() catch {};
    self.applyReveal(now_ms);
    return self.animating or revealing;
}

/// What a dock reserves along `area`'s edge for windows: its thickness and the
/// gap on either side. Nothing when it floats over them (auto-hide), is off, or
/// does not fit and so shows nothing.
pub fn reservedStrip(server: *const Server, area: wlr.Box) i32 {
    if (!reserves(&server.config.compositor)) return 0;
    const reach = footprint(server, area);
    return if (reach == 0) 0 else reach + window_margin;
}

/// How far a resting dock reaches in from its edge of `area`: its thickness and
/// the gap to the edge, whether it reserves that strip or auto-hides. Read from
/// the configuration alone, like `reservedStrip`, so what keeps clear of it (the
/// OSD) stays put while an auto-hiding dock comes and goes.
pub fn footprint(server: *const Server, area: wlr.Box) i32 {
    const c = &server.config.compositor;
    if (server.greeter_mode or !c.dock_enabled or !fits(c, area)) return 0;
    return @as(i32, @intCast(c.dock_height)) + edge_margin;
}

/// Whether the dock, as configured, keeps windows out of its strip. A change
/// to this (or to the dock's edge or size while it holds) moves the work area:
/// refit windows with `Server.applyTaskbarPosition`.
pub fn reserves(c: *const config.CompositorConfig) bool {
    return c.dock_enabled and !c.dock_auto_hide;
}

/// Whether the dock shows at all in `area` (the output less the taskbar). Read
/// from the configuration alone, so it agrees with what `reservedStrip` holds
/// back wherever it is asked.
fn fits(c: *const config.CompositorConfig, area: wlr.Box) bool {
    const m: Metrics = .{ .height = @intCast(c.dock_height) };
    const length = if (c.dock_position.vertical()) area.height else area.width;
    const thickness = if (c.dock_position.vertical()) area.width else area.height;
    const min_length = @max(260, @as(i32, @intCast(configuredFixedCount(c))) * m.itemStep() + m.padding() * 2 + 12);
    return length >= min_length and thickness >= @max(140, m.height + 72);
}

/// `fixedCount` from the configuration alone: an uninstalled pin counts.
fn configuredFixedCount(c: *const config.CompositorConfig) usize {
    var count: usize = @min(c.dock_pinned_apps.len, max_pins);
    for (std.enums.values(Shortcut)) |shortcut| {
        if (shownIn(c, shortcut)) count += 1;
    }
    return count;
}

/// Auto-hide: lets `reveal` follow the pointer's wish, and parks the dock once
/// it has gone. True while the reveal still moves.
fn syncReveal(self: *Self, now_ms: i64) bool {
    const server = self.output.?.server;
    var target: f32 = 1;
    if (server.config.compositor.dock_auto_hide) {
        self.retime();
        if (!self.shown) target = 0;
    } else {
        self.disarm();
        self.pointer_near = false;
        self.shown = false;
    }
    if (self.reveal.to != target) self.reveal.retargetTo(now_ms, target, anim.curveFor(.taskbar_hover));
    const moving = !self.reveal.settled(now_ms);
    self.parked = target == 0 and !moving;
    return moving;
}

/// The dock fades and slides toward its edge as `reveal` falls. The raster does
/// not change: only the node's position and opacity. Glass follows the position
/// as part of the tree, but its opacity is its own and is given here, or the
/// blurred backdrop would stay solid until the dock parks.
fn applyReveal(self: *Self, now_ms: i64) void {
    const t = std.math.clamp(self.reveal.value(now_ms), 0, 1);
    var x = self.box.x;
    var y = self.box.y;
    if (t < 1 and !anim.reducedMotion()) {
        const away: i32 = @intFromFloat(@round((1 - t) * slide_distance));
        switch (self.position) {
            .top => y -= away,
            .bottom => y += away,
            .left => x -= away,
            .right => x += away,
        }
    }
    self.tree.?.node.setPosition(x, y);
    self.node.?.setOpacity(t);
    glass.Effect.configure(self.glass_effect, self.glass_radius, t);
}

fn menuOpen(self: *const Self) bool {
    return self.output.?.server.input.window_menu.dock == self;
}

/// Whether the pointer at layout position `x`, `y` wants the dock: it is at the
/// output edge the dock is on, or on the dock (and the gap beside it) once shown.
fn nearPointer(self: *const Self, output: *Output, x: f64, y: f64) bool {
    const c = &output.server.config.compositor;
    if (!c.dock_auto_hide or !self.visible) return false;
    const full = output.cached_box;
    const px: i32 = @intFromFloat(@floor(x));
    const py: i32 = @intFromFloat(@floor(y));
    if (px < full.x or py < full.y or px >= full.x + full.width or py >= full.y + full.height) return false;
    const at_edge = switch (c.dock_position) {
        .top => py < full.y + edge_band,
        .bottom => py >= full.y + full.height - edge_band,
        .left => px < full.x + edge_band,
        .right => px >= full.x + full.width - edge_band,
    };
    if (at_edge) return true;
    // Only a dock that is out can be pointed at: where it would be is windows.
    if (!self.shown) return false;
    return (px >= self.box.x - edge_margin and px < self.box.x + self.box.width + edge_margin and
        py >= self.box.y - edge_margin and py < self.box.y + self.box.height + edge_margin) or
        self.buttonAt(@floatCast(x - @as(f64, @floatFromInt(self.box.x))), @floatCast(y - @as(f64, @floatFromInt(self.box.y)))) != null;
}

/// Every pointer motion. `engaged` is false while a window is moved or resized
/// or a button is held for a client, none of which should raise the dock.
pub fn pointerAt(self: *Self, x: f64, y: f64, engaged: bool) void {
    const output = self.output orelse return;
    const near = engaged and self.nearPointer(output, x, y);
    if (near == self.pointer_near) return;
    self.pointer_near = near;
    self.retime();
}

/// Starts (or drops) the delay before `shown` follows what the pointer wants.
fn retime(self: *Self) void {
    const wanted = self.pointer_near or self.menuOpen();
    if (wanted == self.shown) return self.disarm();
    if (self.timer_target == wanted) return;
    self.timer_target = wanted;
    const delay: i32 = if (wanted) reveal_delay_ms else hide_delay_ms;
    const output = self.output.?;
    if (self.timer == null) self.timer = output.server.wl_server.getEventLoop().addTimer(*Self, onTimer, self) catch null;
    if (self.timer) |timer| {
        if (timer.timerUpdate(delay)) return else |_| {}
    }
    // No timer: follow at once.
    _ = onTimer(self);
}

fn disarm(self: *Self) void {
    if (self.timer_target == null) return;
    self.timer_target = null;
    if (self.timer) |timer| timer.timerUpdate(0) catch {};
}

fn onTimer(self: *Self) c_int {
    if (self.timer_target) |wanted| self.shown = wanted;
    self.timer_target = null;
    if (self.output) |output| output.wlr_output.scheduleFrame();
    return 0;
}

fn hidden(items: []const []const u8, name: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn shownIn(c: *const config.CompositorConfig, shortcut: Shortcut) bool {
    if (shortcut == .trash) return c.dock_show_trash;
    return !hidden(c.dock_hidden_shortcuts, @tagName(shortcut));
}

fn shortcutShown(self: *const Self, shortcut: Shortcut) bool {
    return shownIn(&self.output.?.server.config.compositor, shortcut);
}

fn shortcutCount(self: *const Self) usize {
    var count: usize = 0;
    for (std.enums.values(Shortcut)) |shortcut| if (self.shortcutShown(shortcut)) {
        count += 1;
    };
    return count;
}

/// Buttons that always show, whatever windows are open.
fn fixedCount(self: *const Self) usize {
    return self.shortcutCount() + self.pin_count;
}

/// Looks the configured pins up in the catalogue; apps that are no longer
/// installed stay in the config but are not shown.
fn resolvePins(self: *Self) void {
    _ = self.pin_arena.reset(.retain_capacity);
    self.pin_count = 0;
    const server = self.output.?.server;
    const configured = server.config.compositor.dock_pinned_apps;
    if (configured.len == 0) return;
    const snapshot = server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    const a = self.pin_arena.allocator();
    for (configured, 0..) |id, config_index| {
        if (self.pin_count == max_pins) break;
        const entry = default_apps.find(snapshot.entries, id) orelse continue;
        self.pins[self.pin_count] = .{
            .id = a.dupe(u8, entry.id) catch return,
            .name = a.dupe(u8, entry.name) catch return,
            .icon = a.dupe(u8, entry.icon orelse entry.id) catch return,
            .wm_class = if (entry.startup_wm_class) |class| a.dupe(u8, class) catch return else null,
            .hash = std.hash.Wyhash.hash(0, entry.id) | 1,
            .config_index = config_index,
        };
        self.pin_count += 1;
    }
}

fn pinFor(self: *const Self, top: *Toplevel) ?usize {
    for (self.pins[0..self.pin_count], 0..) |pin, i| if (pin.match().matches(top)) return i;
    return null;
}

/// The window standing for an app on its dock button: the focused one, then a
/// visible one, then the most recent.
fn prefer(current: ?*Toplevel, top: *Toplevel, focused: ?*Toplevel) bool {
    const held = current orelse return true;
    return held != focused and (top == focused or (held.minimized and !top.minimized));
}

fn showsWindow(self: *const Self, top: *Toplevel) bool {
    const output = self.output.?;
    return top.in_world and !top.closing and !top.backend_gone and !top.tab_hidden and
        @import("workspaces.zig").visible(top) and !(top.live_rules.skip_taskbar orelse false) and
        (!output.server.world.workspaces.active or top.currentOutput() == output);
}

/// Use the same membership as the badge, including minimized windows.
fn openWindowPicker(self: *Self, index: usize) bool {
    const output = self.output.?;
    const target = self.topAt(index) orelse return false;
    if (self.pin_of[index] == null and self.shortcuts[index] == null and target.appId().len == 0) return false;
    const snapshot = output.server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const matches = self.shortcutApps(snapshot.entries, scratch.allocator());
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(gpa);
    var it = output.server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (!self.showsWindow(top)) continue;
        const same = if (self.pin_of[index]) |pin|
            self.pinFor(top) == pin
        else if (self.shortcuts[index]) |shortcut|
            self.pinFor(top) == null and matches[@intFromEnum(shortcut)].matches(top)
        else
            std.mem.eql(u8, @import("window_tabs.zig").identity(top.appId()), @import("window_tabs.zig").identity(target.appId()));
        if (same) ids.append(gpa, top.id) catch return false;
    }
    if (ids.items.len < 2) return false;
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    const button = &self.buttons[index];
    output.server.input.window_menu.openDockWindows(self, ids.items, self.shortcuts[index], self.box.x + @as(i32, @intFromFloat(button.computed_x + button.computed_width / 2)), self.box.y + @as(i32, @intFromFloat(button.computed_y + button.computed_height / 2)));
    return output.server.input.window_menu.node != null;
}

/// Where the dock rests in `area`: centred along its edge, `edge_margin` in.
fn place(self: *Self, area: wlr.Box) void {
    self.box.x = area.x + @divTrunc(area.width - self.box.width, 2);
    self.box.y = area.y + @divTrunc(area.height - self.box.height, 2);
    switch (self.position) {
        .top => self.box.y = area.y + edge_margin,
        .bottom => self.box.y = area.y + area.height - self.box.height - edge_margin,
        .left => self.box.x = area.x + edge_margin,
        .right => self.box.x = area.x + area.width - self.box.width - edge_margin,
    }
}

fn metrics(self: *const Self) Metrics {
    return .{ .height = if (self.position.vertical()) self.box.width else self.box.height };
}

/// Put the running indicator on the output-edge side of each upright icon.
fn buttonCross(self: *const Self) i32 {
    const m = self.metrics();
    return if (self.position == .top or self.position == .left) m.height - m.length(8) - m.length(48) else m.length(8);
}

const AppMatch = struct {
    id: []const u8 = "",
    wm_class: ?[]const u8 = null,

    fn fromEntry(entry: *const apps.AppEntry) AppMatch {
        return .{ .id = entry.id, .wm_class = entry.startup_wm_class };
    }

    fn matches(self: AppMatch, top: *Toplevel) bool {
        return @import("placeholder_match.zig").matchesAppId(@import("window_tabs.zig").identity(top.appId()), self.wm_class, self.id);
    }
};

/// Resolve the same preferred applications and fallbacks as launchPreferred.
/// Snapshot strings stay alive for this rebuild; parsed argv lives in scratch.
fn shortcutApps(self: *Self, entries: []const apps.AppEntry, scratch: std.mem.Allocator) [shortcut_count]AppMatch {
    const server = self.output.?.server;
    var matches: [shortcut_count]AppMatch = .{ .{}, .{ .id = "rediwm-files" }, .{ .id = "foot" }, .{ .id = Toplevel.settings_app_id }, .{} };
    if (default_apps.find(entries, server.config.compositor.default_file_manager)) |entry| matches[@intFromEnum(Shortcut.files)] = .fromEntry(entry);
    if (default_apps.find(entries, server.config.compositor.default_terminal)) |entry| {
        matches[@intFromEnum(Shortcut.terminal)] = .fromEntry(entry);
    } else {
        const parseExec = @import("start_menu/launch.zig").parseExec;
        const argv = parseExec(scratch, server.environ.getPosix("TERMINAL") orelse "foot", null) catch return matches;
        if (argv.len == 0) return matches;
        const executable = std.fs.path.basename(argv[0]);
        matches[@intFromEnum(Shortcut.terminal)] = .{ .id = executable };
        for (entries) |*entry| {
            if (!default_apps.matches(entry.*, .terminal)) continue;
            const command = parseExec(scratch, entry.exec, entry) catch continue;
            if (command.len > 0 and std.mem.eql(u8, std.fs.path.basename(command[0]), executable)) {
                matches[@intFromEnum(Shortcut.terminal)] = .fromEntry(entry);
                break;
            }
        }
    }
    return matches;
}

fn rebuild(self: *Self, capacity: usize, area: wlr.Box) !void {
    const output = self.output.?;
    const previous_animations = self.animations;
    const previous_count = self.count;
    const snapshot = output.server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const matches = self.shortcutApps(snapshot.entries, scratch.allocator());
    var targets: [shortcut_count]?*Toplevel = @splat(null);
    var pin_targets: [max_pins]?*Toplevel = @splat(null);
    var shortcut_counts: [shortcut_count]usize = @splat(0);
    var pin_counts: [max_pins]usize = @splat(0);
    var app_counts = std.StringHashMap(usize).init(scratch.allocator());
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(output.server);
    var tops: std.ArrayList(*Toplevel) = .empty;
    defer tops.deinit(gpa);
    var it = output.server.world.toplevels.iterator(.forward);
    windows: while (it.next()) |top| {
        if (!self.showsWindow(top)) continue;
        // Every running app shows: on its pin, on its shortcut, or as a window.
        if (self.pinFor(top)) |pin| {
            pin_counts[pin] += 1;
            if (prefer(pin_targets[pin], top, focused)) pin_targets[pin] = top;
            continue;
        }
        for ([_]Shortcut{ .files, .terminal, .settings }) |shortcut| {
            // A removed shortcut is only a launcher gone: its app, once
            // running, is an ordinary window button.
            if (!self.shortcutShown(shortcut) or !matches[@intFromEnum(shortcut)].matches(top)) continue;
            shortcut_counts[@intFromEnum(shortcut)] += 1;
            const target = &targets[@intFromEnum(shortcut)];
            if (prefer(target.*, top, focused)) target.* = top;
            continue :windows;
        }
        try tops.append(gpa, top);
        const app_id = @import("window_tabs.zig").identity(top.appId());
        if (app_id.len > 0) {
            const entry = try app_counts.getOrPut(app_id);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }
    std.mem.sort(*Toplevel, tops.items, {}, struct {
        fn less(_: void, a: *Toplevel, b: *Toplevel) bool {
            return a.id < b.id;
        }
    }.less);
    self.windows = tops.items.len;
    self.offset = @min(self.offset, self.windows -| capacity);
    const window_count = @min(capacity, self.windows);
    self.count = window_count + self.fixedCount();
    self.position = output.server.config.compositor.dock_position;
    const m: Metrics = .{ .height = @intCast(output.server.config.compositor.dock_height) };
    const length = @as(i32, @intCast(self.count)) * m.itemStep() + m.padding() * 2;
    self.box.width = if (self.position.vertical()) m.height else length;
    self.box.height = if (self.position.vertical()) length else m.height;
    self.scale = output.wlr_output.scale;
    const hovered = self.dispatcher.hovered != null;
    self.dispatcher.reset();
    _ = self.arena.reset(.retain_capacity);
    self.root = .{ .kind = .container, .children = self.buttons[0..self.count], .computed_width = @floatFromInt(self.box.width), .computed_height = @floatFromInt(self.box.height) };
    const raster = self.rasterBox();
    self.input_root = .{ .kind = .container, .children = self.buttons[0..self.count], .computed_x = @floatFromInt(raster.x), .computed_y = @floatFromInt(raster.y), .computed_width = @floatFromInt(raster.width), .computed_height = @floatFromInt(raster.height) };
    var index: usize = 0;
    self.pin_of = @splat(null);
    self.window_counts = @splat(0);
    for ([_]Shortcut{ .applications, .files, .terminal }) |shortcut| {
        if (!self.shortcutShown(shortcut)) continue;
        self.setButton(index, shortcut, if (targets[@intFromEnum(shortcut)]) |top| top.id else 0);
        self.window_counts[index] = shortcut_counts[@intFromEnum(shortcut)];
        index += 1;
    }
    self.pin_base = index;
    for (pin_targets[0..self.pin_count], 0..) |target, pin| {
        self.pin_of[index] = @intCast(pin);
        self.setButton(index, null, if (target) |top| top.id else 0);
        self.window_counts[index] = pin_counts[pin];
        index += 1;
    }
    for (tops.items[self.offset .. self.offset + window_count]) |top| {
        self.setButton(index, null, top.id);
        self.window_counts[index] = app_counts.get(@import("window_tabs.zig").identity(top.appId())) orelse 1;
        index += 1;
    }
    if (self.shortcutShown(.settings)) {
        self.setButton(index, .settings, if (targets[@intFromEnum(Shortcut.settings)]) |top| top.id else 0);
        self.window_counts[index] = shortcut_counts[@intFromEnum(Shortcut.settings)];
        index += 1;
    }
    // The trash is the dock's last item, past a divider; no window is its.
    if (self.shortcutShown(.trash)) self.setButton(index, .trash, 0);
    for (self.animations[0..self.count], 0..) |*pill, i| {
        const shortcut = self.shortcuts[i];
        const id = self.ids[i];
        const pin: u64 = if (self.pin_of[i]) |p| self.pins[p].hash else 0;
        pill.* = .{ .shortcut = shortcut, .pin = pin, .id = id };
        // Widget indexes move as windows open or items are removed. A
        // shortcut or pin keeps its animation when its representative window changes.
        for (previous_animations[0..previous_count]) |previous| {
            if (previous.shortcut == shortcut and previous.pin == pin and (shortcut != null or pin != 0 or previous.id == id)) {
                pill.* = previous;
                break;
            }
        }
        const range = self.zoomRange();
        self.setButtonZoom(i, std.math.clamp(pill.zoom.value(anim.nowMs()), range.min, range.max));
    }
    // The pointer rests on a replaced button: hover it before painting, so
    // the rebuild paints once.
    if (hovered) {
        self.place(area);
        const cursor = output.server.input.cursor;
        self.dispatcher.pointerMotion(&self.input_root, @floatCast(cursor.x - @as(f64, @floatFromInt(self.box.x))), @floatCast(cursor.y - @as(f64, @floatFromInt(self.box.y))));
    }
    self.dirty = false;
}

fn setButton(self: *Self, index: usize, shortcut: ?Shortcut, id: u64) void {
    const m = self.metrics();
    self.ids[index] = id;
    self.shortcuts[index] = shortcut;
    self.buttons[index] = .{
        .name = if (shortcut) |s| @tagName(s) else if (self.pin_of[index]) |p|
            std.fmt.allocPrint(self.arena.allocator(), "pin_{s}", .{self.pins[p].id}) catch "pin"
        else
            std.fmt.allocPrint(self.arena.allocator(), "window_{d}", .{id}) catch "window",
        .kind = .{ .button = .{ .label = self.arena.allocator().dupe(u8, self.label(index)) catch "Application", .variant = .ghost, .owner = self, .id = index, .on_click = clicked } },
        .computed_x = @floatFromInt(if (self.position.vertical()) self.buttonCross() else @as(i32, @intCast(index)) * m.itemStep() + m.padding()),
        .computed_y = @floatFromInt(if (self.position.vertical()) @as(i32, @intCast(index)) * m.itemStep() + m.padding() else self.buttonCross()),
        .computed_width = @floatFromInt(m.length(48)),
        .computed_height = @floatFromInt(m.length(48)),
    };
}

fn topAt(self: *Self, index: usize) ?*Toplevel {
    const id = self.ids[index];
    if (id == 0) return null;
    var it = self.output.?.server.world.toplevels.iterator(.forward);
    while (it.next()) |top| if (top.id == id and top.in_world and !top.backend_gone and !top.closing) return top;
    return null;
}

fn setButtonZoom(self: *Self, index: usize, zoom: f32) void {
    const m = self.metrics();
    const base: f32 = @floatFromInt(m.length(48));
    const icon = self.iconBox(index, zoom, 36);
    const button = &self.buttons[index];
    const along: f32 = @floatFromInt(@as(i32, @intCast(index)) * m.itemStep() + m.padding());
    const cross: f32 = @floatFromInt(self.buttonCross());
    const x = if (self.position.vertical()) cross else along;
    const y = if (self.position.vertical()) along else cross;
    button.computed_x = @min(x, icon.x);
    button.computed_y = @min(y, icon.y);
    button.computed_width = @max(x + base, icon.x + icon.w) - button.computed_x;
    button.computed_height = @max(y + base, icon.y + icon.h) - button.computed_y;
}

/// How far a hovered icon's zoom may go while its spring overshoots past
/// `dock_hover_zoom` or dips under rest on the way back. Rasters and cells are
/// sized for `max`, so a bounce never needs a larger buffer or upsamples icons.
fn zoomRange(self: *const Self) struct { min: f32, max: f32 } {
    const hover_zoom = self.output.?.server.config.compositor.dock_hover_zoom;
    const headroom = (hover_zoom - 1) * 0.3;
    return .{ .min = 1 - headroom, .max = hover_zoom + headroom };
}

/// Keep the icon's screen-edge side fixed as it grows toward the desktop.
fn iconBox(self: *const Self, index: usize, zoom: f32, reference: f32) ui.layout.Widget.PaintBounds {
    const m = self.metrics();
    const base: f32 = @floatFromInt(m.length(reference));
    const side = base * zoom;
    const along = @as(f32, @floatFromInt(@as(i32, @intCast(index)) * m.itemStep() + m.padding())) + @as(f32, @floatFromInt(m.length(48))) / 2;
    const inward: f32 = if (self.position == .bottom or self.position == .right) -1 else 1;
    const cross = @as(f32, @floatFromInt(self.buttonCross())) + @as(f32, @floatFromInt(m.length(48))) / 2 + inward * (side - base) / 2;
    return .{ .x = (if (self.position.vertical()) cross else along) - side / 2, .y = (if (self.position.vertical()) along else cross) - side / 2, .w = side, .h = side };
}

/// Only the foreground raster extends beyond the background at large zooms.
fn rasterBox(self: *const Self) wlr.Box {
    const icon = self.iconBox(0, self.zoomRange().max, 36);
    const m = self.metrics();
    const cross = if (self.position.vertical()) icon.x else icon.y;
    const before: i32 = @intFromFloat(@ceil(@max(0, -cross)));
    const after: i32 = @intFromFloat(@ceil(@max(0, cross + icon.w - @as(f32, @floatFromInt(m.height)))));
    return if (self.position.vertical())
        .{ .x = -before, .y = 0, .width = self.box.width + before + after, .height = self.box.height }
    else
        .{ .x = 0, .y = -before, .width = self.box.width, .height = self.box.height + before + after };
}

fn label(self: *Self, index: usize) []const u8 {
    if (self.shortcuts[index]) |shortcut| return switch (shortcut) {
        .applications => @import("i18n").tr("Applications"),
        .files => @import("i18n").tr("Files"),
        .terminal => @import("i18n").tr("Terminal"),
        .settings => @import("i18n").tr("Settings"),
        .trash => @import("i18n").tr("Trash"),
    };
    if (self.pin_of[index]) |p| return self.pins[p].name;
    return if (self.topAt(index)) |top| top.title() else @import("i18n").tr("Application");
}

/// Hashes a value field by field; floats by their bits, slices by contents.
fn hashValue(hasher: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |v| {
            hasher.update(&.{1});
            hashValue(hasher, v);
        } else hasher.update(&.{0}),
        .@"struct" => |info| inline for (info.fields) |field| hashValue(hasher, @field(value, field.name)),
        .pointer => {
            hasher.update(std.mem.asBytes(&value.len));
            hasher.update(std.mem.sliceAsBytes(value));
        },
        else => hasher.update(std.mem.asBytes(&value)),
    }
}

/// What one button shows.
const Look = struct {
    focused: bool,
    window_count: usize,
    icon: ?IconEntry,
    pill_width: f32,
    pill_opacity: f32,
    zoom: f32,
};

fn paint(self: *Self, now_ms: i64) !void {
    const output = self.output.?;
    const m = self.metrics();
    const pal = ui.theme.shellPalette();
    const bg = background(&output.server.config.compositor, pal);
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(output.server);
    var looks: [max_items]Look = undefined;
    var item_keys: [max_items]u64 = undefined;
    self.animating = false;
    // Dock-wide state: a change repaints the whole raster. Each item's own look is
    // keyed apart, so a hover repaints only the icons it moves.
    var base_hasher = std.hash.Wyhash.init(0);
    hashValue(&base_hasher, .{ pal, bg, self.scale, self.position, self.box.width, self.box.height, self.count, self.offset, self.windows, self.pin_base, self.drop_slot, output.server.config.compositor.dock_hover_zoom, output.server.config.compositor.dock_active_highlight });
    const base_key = base_hasher.final();
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&base_key));
    for (self.buttons[0..self.count], looks[0..self.count], 0..) |button, *look, index| {
        const top = self.topAt(index);
        const icon_name = if (self.shortcuts[index]) |shortcut| switch (shortcut) {
            .applications => "builtin:redi-logo",
            .files => "rediwm-files",
            .terminal => "utilities-terminal",
            .settings => ui.shell_icons.settings_icon_name,
            .trash => "user-trash",
        } else if (self.pin_of[index]) |p| self.pins[p].icon else if (top) |t| t.appId() else "";
        // Retain one raster at the largest zoom, not a new size each frame.
        const hover_zoom = output.server.config.compositor.dock_hover_zoom;
        const range = self.zoomRange();
        const lookup = output.server.iconLookup(icon_name, self.iconRaster(m));
        const active = top != null and top == focused;
        const width: f32 = if (top == null) 0 else if (active) 22 else 10;
        const opacity: f32 = if (top) |t| if (t.minimized) 0.4 else 1 else 0;
        const pill = &self.animations[index];
        const zoom: f32 = if (self.dispatcher.hovered == &self.buttons[index]) hover_zoom else 1;
        if (hover_zoom == 1) {
            pill.zoom.cancel(1);
        } else if (pill.zoom.to != zoom) pill.zoom.retargetTo(now_ms, zoom, anim.curveFor(.dock_hover));
        if (pill.width.to != width) pill.width.retargetTo(now_ms, width, anim.curveFor(.taskbar_hover));
        if (pill.opacity.to != opacity) pill.opacity.retargetTo(now_ms, opacity, anim.curveFor(.taskbar_hover));
        _ = pill.width.sampleChanged(now_ms, anim.rasterPixelQuantum(self.scale) / (4 * m.size(1)));
        _ = pill.opacity.sampleChanged(now_ms, anim.rasterAlphaQuantum());
        _ = pill.zoom.sampleChanged(now_ms, anim.rasterPixelQuantum(self.scale) / (4 * m.size(36)));
        self.animating = self.animating or !pill.width.settled(now_ms) or !pill.opacity.settled(now_ms) or !pill.zoom.settled(now_ms);
        look.* = .{
            .focused = active,
            .window_count = self.window_counts[index],
            .icon = if (lookup == .ready) lookup.ready else null,
            .pill_width = @max(0, pill.width.last_quantised),
            .pill_opacity = std.math.clamp(pill.opacity.last_quantised, 0, 1),
            .zoom = std.math.clamp(pill.zoom.last_quantised, range.min, range.max),
        };
        // Input covers both the resting button and the growing icon. Centres
        // along the row stay fixed when moving between neighbours.
        self.setButtonZoom(index, look.zoom);
        const icon_id: ?u64 = if (look.icon) |icon| icon.id else null;
        var item_hasher = std.hash.Wyhash.init(0);
        hashValue(&item_hasher, .{ self.shortcuts[index], self.pin_of[index], button.kind.button.state, look.focused, look.window_count, icon_id, look.pill_width, look.pill_opacity, look.zoom });
        item_keys[index] = item_hasher.final();
        hasher.update(std.mem.asBytes(&item_keys[index]));
    }
    const key = hasher.final();
    if (key != self.drawn) try self.paintDock(pal, bg, looks[0..self.count], base_key, item_keys[0..self.count]);
    self.drawn = key;
    try self.paintTooltip();
}

/// Device pixels of the icon raster the dock asks for: the largest size an icon
/// is drawn at, so hovering never needs another.
fn iconRaster(self: *const Self, m: Metrics) i32 {
    const zoom = self.zoomRange().max;
    return @import("geometry.zig").devicePixels(@intFromFloat(@ceil(@as(f32, @floatFromInt(m.length(36))) * zoom)), self.scale);
}

/// The dock's background: the theme's `dock_bg`, else the taskbar's with a
/// floor on its alpha. `dock_opacity`, when set, replaces the alpha of either.
pub fn background(c: *const config.CompositorConfig, pal: ui.theme.Theme) [4]f32 {
    var bg = pal.dock_bg orelse ui.theme.taskbar(.taskbar_bg);
    if (pal.dock_bg == null) bg[3] = @max(bg[3], 0.86);
    if (c.dock_opacity) |opacity| bg[3] = std.math.clamp(opacity, 0, 1);
    return bg;
}

/// The dock's corner radius: the theme's `dock_radius`, or the window frame's
/// (Appearance's Radius) while that is zero. Painting caps it at half the dock.
pub fn cornerRadius(pal: ui.theme.Theme) f32 {
    return if (pal.dock_radius > 0) pal.dock_radius else ui.window_chrome.frameRadius();
}

/// A device-pixel rectangle of the dock raster.
const DeviceRect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn area(self: DeviceRect) i64 {
        return @as(i64, self.x1 - self.x0) * @as(i64, self.y1 - self.y0);
    }

    fn overlaps(self: DeviceRect, other: DeviceRect) bool {
        return self.x0 < other.x1 and other.x0 < self.x1 and self.y0 < other.y1 and other.y0 < self.y1;
    }

    fn join(self: DeviceRect, other: DeviceRect) DeviceRect {
        return .{ .x0 = @min(self.x0, other.x0), .y0 = @min(self.y0, other.y0), .x1 = @max(self.x1, other.x1), .y1 = @max(self.y1, other.y1) };
    }
};

/// Everything item `index` can paint, at the largest hover zoom, across the dock's
/// thickness: the cell a repaint of that item must restore. Neighbours' cells
/// may overlap at the top of a large zoom's bounce; a partial repaint redraws
/// every item whose cell meets the dirty box, so that stays exact.
fn itemCell(self: *const Self, m: Metrics, index: usize, width: i32, height: i32) DeviceRect {
    const base: f32 = @floatFromInt(m.length(48));
    const side = @max(base, @as(f32, @floatFromInt(m.length(36))) * self.zoomRange().max);
    const centre = @as(f32, @floatFromInt(@as(i32, @intCast(index)) * m.itemStep() + m.padding())) + base / 2;
    const lo: i32 = @intFromFloat(@floor((centre - side / 2) * self.scale));
    const hi: i32 = @intFromFloat(@ceil((centre + side / 2) * self.scale));
    return if (self.position.vertical())
        .{ .x0 = 0, .y0 = @max(0, lo), .x1 = width, .y1 = @min(height, hi) }
    else
        .{ .x0 = @max(0, lo), .y0 = 0, .x1 = @min(width, hi), .y1 = height };
}

/// The cells whose items changed since the retained raster, or null when the whole
/// dock must be painted: nothing retained, dock-wide state moved, or the changed
/// cells cover most of it anyway.
fn changedCells(self: *const Self, m: Metrics, base_key: u64, item_keys: []const u64, width: i32, height: i32) ?DeviceRect {
    if (self.retained.len != @as(usize, @intCast(width)) * @as(usize, @intCast(height)) or
        self.base_drawn != base_key or self.items_drawn != item_keys.len) return null;
    var dirty: ?DeviceRect = null;
    for (item_keys, self.item_drawn[0..item_keys.len], 0..) |key, drawn, index| {
        if (key == drawn) continue;
        const cell = self.itemCell(m, index, width, height);
        dirty = if (dirty) |d| d.join(cell) else cell;
    }
    const box = dirty orelse return null;
    if (box.area() * 2 > @as(i64, width) * height) return null;
    return box;
}

fn paintDock(self: *Self, pal: ui.theme.Theme, bg: [4]f32, looks: []const Look, base_key: u64, item_keys: []const u64) !void {
    const m = self.metrics();
    const geometry = @import("geometry.zig");
    const raster = self.rasterBox();
    const ox: f32 = @floatFromInt(-raster.x);
    const oy: f32 = @floatFromInt(-raster.y);
    const width = geometry.devicePixels(raster.width, self.scale);
    const height = geometry.devicePixels(raster.height, self.scale);
    const dirty = self.changedCells(m, base_key, item_keys, width, height);
    const image = if (dirty != null)
        try PanelBuffer.createUninitialized(raster.width, raster.height, self.scale)
    else
        try PanelBuffer.create(raster.width, raster.height, self.scale);
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.scale);
    r.palette = pal;
    const stride: usize = @intCast(image.width);
    if (dirty) |box| {
        // Start from what is on screen and paint the changed cells again, from
        // clear, exactly as a whole paint would. A quarter pixel in from the cell
        // edge keeps every shape on whole device pixels.
        @memcpy(image.pixels, self.retained);
        for (@as(usize, @intCast(box.y0))..@as(usize, @intCast(box.y1))) |y| @memset(image.pixels[y * stride + @as(usize, @intCast(box.x0)) .. y * stride + @as(usize, @intCast(box.x1))], 0);
        const x0: f32 = @floatFromInt(box.x0);
        const y0: f32 = @floatFromInt(box.y0);
        r.damage_clip = .{
            .x = (x0 + 0.25) / self.scale,
            .y = (y0 + 0.25) / self.scale,
            .w = (@as(f32, @floatFromInt(box.x1)) - x0 - 0.5) / self.scale,
            .h = (@as(f32, @floatFromInt(box.y1)) - y0 - 0.5) / self.scale,
        };
    }
    var border = pal.accent;
    border[3] = 0.55;
    border = pal.dock_border orelse border;
    const radius = @min(cornerRadius(pal), @as(f32, @floatFromInt(m.height)) / 2);
    self.glass_radius = radius;
    glass.Effect.configure(self.glass_effect, radius, std.math.clamp(self.reveal.value(anim.nowMs()), 0, 1));
    r.fillRect(ox, oy, @floatFromInt(self.box.width), @floatFromInt(self.box.height), .{ .color = bg, .radius = radius, .border_width = 1, .border_color = border });
    for (looks, 0..) |look, index| {
        if (dirty) |box| if (!box.overlaps(self.itemCell(m, index, width, height))) continue;
        self.paintItem(&r, pal, m, index, look, ox, oy);
    }
    self.paintMarks(&r, pal, m, ox, oy);
    if (dirty) |box| {
        for (@as(usize, @intCast(box.y0))..@as(usize, @intCast(box.y1))) |y| {
            const row = y * stride;
            @memcpy(self.retained[row + @as(usize, @intCast(box.x0)) .. row + @as(usize, @intCast(box.x1))], image.pixels[row + @as(usize, @intCast(box.x0)) .. row + @as(usize, @intCast(box.x1))]);
        }
        var region: @import("pixman").Region32 = undefined;
        region.initRect(box.x0, box.y0, @intCast(box.x1 - box.x0), @intCast(box.y1 - box.y0));
        defer region.deinit();
        self.node.?.setBufferWithDamage(&image.base, &region);
    } else {
        self.retained = gpa.realloc(self.retained, image.pixels.len) catch blk: {
            // Without a copy the next paint is a whole one.
            gpa.free(self.retained);
            break :blk &.{};
        };
        if (self.retained.len == image.pixels.len) @memcpy(self.retained, image.pixels);
        self.node.?.setBuffer(&image.base);
    }
    self.base_drawn = base_key;
    self.items_drawn = item_keys.len;
    @memcpy(self.item_drawn[0..item_keys.len], item_keys);
    self.node.?.node.setPosition(raster.x, raster.y);
    self.node.?.setDestSize(raster.width, raster.height);
    self.glass_anchor.?.setDestSize(self.box.width, self.box.height);
}

/// One button: its backdrop, icon, window count and running pill.
fn paintItem(self: *Self, r: *ui.paint.Renderer, pal: ui.theme.Theme, m: Metrics, index: usize, look: Look, ox: f32, oy: f32) void {
    const zooms = self.output.?.server.config.compositor.dock_hover_zoom > 1;
    const button = &self.buttons[index];
    const x = button.computed_x + ox;
    const y = button.computed_y + oy;
    const resting = self.iconBox(index, 1, 36);
    const cx = resting.x + resting.w / 2 + ox;
    const cy = resting.y + resting.h / 2 + oy;
    // An enlarging icon is the hover feedback: no rectangle behind it.
    const pointer: ui.layout.ButtonState = if (zooms) .idle else button.kind.button.state;
    ui.widgets.button.paintBackground(r, .{ .x = x, .y = y, .w = button.computed_width, .h = button.computed_height }, .{ .variant = .ghost, .radius = m.size(12) }, .{ .pointer = pointer, .selected = look.focused and self.output.?.server.config.compositor.dock_active_highlight });
    if (look.icon) |icon| {
        const rect = self.iconBox(index, look.zoom, 36);
        r.drawImageSmooth(rect.x + ox, rect.y + oy, rect.w, rect.h, 0, .{ .pixels = icon.pixels, .width = icon.size, .height = icon.size });
    } else {
        const rect = self.iconBox(index, look.zoom, 34);
        r.drawIcon(rect.x + ox, rect.y + oy, rect.w, rect.h, .{ .id = if (self.shortcuts[index]) |shortcut| switch (shortcut) {
            .applications => .grid,
            .files => .folder,
            .terminal => .terminal,
            .settings => .settings,
            .trash => .trash_can,
        } else .generic, .color = pal.window_fg });
    }
    if (look.window_count >= 2) {
        // Stay inside the icon's square, hence inside itemCell even at the
        // spring's largest overshoot. A count change only repaints this cell.
        const rect = self.iconBox(index, look.zoom, 36);
        const diameter = m.size(18) * look.zoom;
        const bx = rect.x + rect.w - diameter + ox;
        const by = rect.y + oy;
        var label_buf: [3]u8 = undefined;
        const count_text = if (look.window_count > 99) "99+" else std.fmt.bufPrint(&label_buf, "{d}", .{look.window_count}) catch unreachable;
        const font_size = m.size(if (count_text.len > 2) 8 else 10) * look.zoom;
        const text_width = ui.text.measureWidthF(count_text, .manrope_heavy, font_size, self.scale) catch diameter;
        const text_x = bx + @max(0, (diameter - text_width) / 2);
        r.fillRect(bx, by, diameter, diameter, .{ .color = pal.accent, .radius = diameter / 2 });
        r.drawText(text_x, by, bx + diameter - text_x, diameter, .{
            .content = count_text,
            .font_size = font_size,
            .weight = 700,
            .color = pal.on_accent,
        });
    }
    if (look.pill_width > 0 and look.pill_opacity > 0) {
        var accent = pal.accent;
        accent[3] *= look.pill_opacity;
        const width = m.size(look.pill_width);
        const thickness = @max(2, m.size(4));
        const cross: f32 = if (self.position == .top or self.position == .left) @as(f32, @floatFromInt(m.height - m.length(58))) - thickness else @floatFromInt(m.length(58));
        if (self.position.vertical()) {
            r.fillRect(cross + ox, cy - width / 2, thickness, width, .{ .color = accent, .radius = @min(width, thickness) / 2 });
        } else r.fillRect(cx - width / 2, cross + oy, width, thickness, .{ .color = accent, .radius = @min(width, thickness) / 2 });
    }
}

/// What lies between and beside the buttons: the drop gap, the divider after the
/// launcher and the scroll chevrons.
fn paintMarks(self: *Self, r: *ui.paint.Renderer, pal: ui.theme.Theme, m: Metrics, ox: f32, oy: f32) void {
    if (self.drop_slot) |slot| {
        // A dragged application lands in this gap between two buttons.
        const gap: f32 = @floatFromInt(m.itemStep() - m.length(48));
        const along = @as(f32, @floatFromInt(m.padding() + @as(i32, @intCast(self.pin_base + slot)) * m.itemStep())) - gap / 2;
        const thickness = @max(2, m.size(3));
        const length = m.size(36);
        const cross = (@as(f32, @floatFromInt(m.height)) - length) / 2;
        if (self.position.vertical()) {
            r.fillRect(cross + ox, along - thickness / 2 + oy, length, thickness, .{ .color = pal.accent, .radius = thickness / 2 });
        } else r.fillRect(along - thickness / 2 + ox, cross + oy, thickness, length, .{ .color = pal.accent, .radius = thickness / 2 });
    }
    var divider = pal.window_fg;
    divider[3] = 0.16;
    if (self.count > 1 and self.shortcuts[0] == .applications) {
        const along: f32 = @floatFromInt(m.itemStep() + m.padding() - m.length(4));
        if (self.position.vertical()) r.fillRect(m.size(18) + ox, along + oy, m.size(30), 1, .{ .color = divider }) else r.fillRect(along + ox, m.size(18) + oy, 1, m.size(30), .{ .color = divider });
    }
    if (self.count > 1 and self.shortcuts[self.count - 1] == .trash) {
        const along: f32 = @floatFromInt(@as(i32, @intCast(self.count - 1)) * m.itemStep() + m.padding() - m.length(4));
        if (self.position.vertical()) r.fillRect(m.size(18) + ox, along + oy, m.size(30), 1, .{ .color = divider }) else r.fillRect(along + ox, m.size(18) + oy, 1, m.size(30), .{ .color = divider });
    }
    if (self.offset > 0) {
        if (self.position.vertical()) r.drawIcon(m.size(28) + ox, 1 + oy, m.size(12), m.size(10), .{ .id = .chevron_up, .color = pal.accent }) else r.drawIcon(1 + ox, m.size(28) + oy, m.size(10), m.size(12), .{ .id = .chevron_left, .color = pal.accent });
    }
    if (self.offset + self.count - self.fixedCount() < self.windows) {
        if (self.position.vertical()) r.drawIcon(m.size(28) + ox, @as(f32, @floatFromInt(self.box.height)) - m.size(11) + oy, m.size(12), m.size(10), .{ .id = .chevron_down, .color = pal.accent }) else r.drawIcon(@as(f32, @floatFromInt(self.box.width)) - m.size(11) + ox, m.size(28) + oy, m.size(10), m.size(12), .{ .id = .chevron_right, .color = pal.accent });
    }
}

/// The pointer is on a new icon (or off every one): its tooltip waits out the
/// delay again.
fn restartTip(self: *Self) void {
    self.cancelTip();
    const hovered = self.dispatcher.hovered orelse return;
    if (hovered.kind != .button) return;
    if (self.tip_timer == null) self.tip_timer = self.output.?.server.wl_server.getEventLoop().addTimer(*Self, onTipTimer, self) catch null;
    if (self.tip_timer) |timer| {
        if (timer.timerUpdate(tooltip_delay_ms)) {
            self.tip_armed = true;
            return;
        } else |_| {}
    }
    // No timer: show at once.
    self.tip_ready = true;
}

fn cancelTip(self: *Self) void {
    self.tip_ready = false;
    if (!self.tip_armed) return;
    self.tip_armed = false;
    if (self.tip_timer) |timer| timer.timerUpdate(0) catch {};
}

fn onTipTimer(self: *Self) c_int {
    self.tip_armed = false;
    if (self.dispatcher.hovered == null or self.tooltip == null) return 0;
    self.tip_ready = true;
    self.paintTooltip() catch {};
    self.output.?.wlr_output.scheduleFrame();
    return 0;
}

fn paintTooltip(self: *Self) !void {
    const hovered = self.dispatcher.hovered orelse {
        // A rebuild can leave nothing hovered without a motion.
        self.cancelTip();
        self.tooltip.?.node.setEnabled(false);
        return;
    };
    if (hovered.kind != .button or !self.tip_ready) {
        self.tooltip.?.node.setEnabled(false);
        return;
    }
    const index = hovered.kind.button.id;
    const pal = ui.theme.shellPalette();
    const value = self.label(index);
    var hasher = std.hash.Wyhash.init(0);
    const area = self.output.?.dockAreaBox();
    hashValue(&hasher, .{ pal, self.scale, self.position, self.box.width, area.width, value });
    const key = hasher.final();
    if (key == self.tip_drawn) {
        // Same text: only the button under it may differ.
        self.placeTooltip(hovered, self.tooltip.?.dst_width, area);
        self.tooltip.?.node.setEnabled(true);
        return;
    }
    const max_width = if (self.position.vertical()) area.width - self.box.width - 18 else self.box.width;
    const width: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(max_width)), @max(80, (ui.text.measureWidthF(value, .manrope, pal.font_size, 1) catch 100) + 24)));
    const image = try PanelBuffer.create(width, 30, self.scale);
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.scale);
    r.palette = pal;
    var bg = pal.window_bg;
    bg[3] = 0.98;
    r.fillRect(0, 0, @floatFromInt(width), 30, .{ .color = bg, .radius = 8, .border_width = 1, .border_color = pal.accent });
    r.drawText(10, 0, @floatFromInt(width - 20), 30, .{ .content = value, .font_size = pal.font_size, .color = pal.window_fg });
    self.tooltip.?.setBuffer(&image.base);
    self.tooltip.?.setDestSize(width, 30);
    self.placeTooltip(hovered, width, area);
    self.tooltip.?.node.setEnabled(true);
    self.tip_drawn = key;
}

fn placeTooltip(self: *Self, hovered: *ui.layout.Widget, width: i32, area: wlr.Box) void {
    var x = self.box.x + @as(i32, @intFromFloat(hovered.computed_x + hovered.computed_width / 2)) - @divTrunc(width, 2);
    var y = self.box.y + @as(i32, @intFromFloat(hovered.computed_y + hovered.computed_height / 2)) - 15;
    switch (self.position) {
        .top => y = self.box.y + self.box.height + 8,
        .bottom => y = self.box.y - 38,
        .left => x = self.box.x + self.box.width + 8,
        .right => x = self.box.x - width - 8,
    }
    x = std.math.clamp(x, area.x, @max(area.x, area.x + area.width - width));
    y = std.math.clamp(y, area.y, @max(area.y, area.y + area.height - 30));
    self.tooltip.?.node.setPosition(x - self.box.x, y - self.box.y);
}

pub fn motion(self: *Self, x: f64, y: f64) void {
    const old = self.dispatcher.hovered;
    self.dispatcher.pointerMotion(&self.input_root, @floatCast(x), @floatCast(y));
    if (old != self.dispatcher.hovered) {
        self.restartTip();
        self.repaint();
    }
}

pub fn leave(self: *Self) void {
    // `Dispatcher.pointerLeave` keeps a hovered button lit, and this runs on
    // every motion elsewhere: a motion outside the dock unhovers it once.
    if (self.dispatcher.hovered != null) self.motion(-1, -1);
}

fn repaint(self: *Self) void {
    if (self.node == null) return;
    self.paint(anim.nowMs()) catch {};
    self.output.?.wlr_output.scheduleFrame();
}

pub fn press(self: *Self, x: f64, y: f64) void {
    // A pinned icon can be dragged to another place among the pins, so it acts
    // when released in place (`clickPin`); the other launchers act on press, like
    // the taskbar.
    if (self.buttonAt(@floatCast(x), @floatCast(y))) |index| if (self.pin_of[index]) |p| {
        const input = &self.output.?.server.input;
        input.dock_drag.armReorder(input, self.pins[p].id, self.pins[p].icon, self.scale);
        return;
    };
    self.dispatcher.pointerButtonDown(&self.input_root, @floatCast(x), @floatCast(y));
    self.dispatcher.pointerButtonUp(&self.input_root, @floatCast(x), @floatCast(y));
    self.repaint();
}

fn buttonAt(self: *const Self, x: f32, y: f32) ?usize {
    for (self.buttons[0..self.count], 0..) |*button, index| {
        if (button.contains(x, y)) return index;
    }
    return null;
}

/// A pinned icon was pressed and released without being dragged: its click,
/// if the pointer (at layout position `x`, `y`) is still on that icon.
pub fn clickPin(self: *Self, x: f64, y: f64, app_id: []const u8) void {
    const local_x: f32 = @floatCast(x - @as(f64, @floatFromInt(self.box.x)));
    const local_y: f32 = @floatCast(y - @as(f64, @floatFromInt(self.box.y)));
    const index = self.buttonAt(local_x, local_y) orelse return;
    const p = self.pin_of[index] orelse return;
    if (!std.mem.eql(u8, self.pins[p].id, app_id)) return;
    clicked(self, index);
    self.repaint();
}

pub fn contextMenu(self: *Self, x: f64, y: f64, screen_x: i32) bool {
    self.dispatcher.pointerMotion(&self.input_root, @floatCast(x), @floatCast(y));
    const button = self.dispatcher.hovered orelse return false;
    if (button.kind != .button) return false;
    const index = button.kind.button.id;
    const target = self.topAt(index);
    const shortcut = self.shortcuts[index];
    const pin: ?[]const u8 = if (self.pin_of[index]) |p| self.pins[p].id else null;
    if (target == null and shortcut == null and pin == null) return false;
    const input = &self.output.?.server.input;
    input.window_menu.openDock(self, target, shortcut, pin, screen_x, self.box.y + @as(i32, @intFromFloat(y)));
    return input.window_menu.node != null;
}

/// Removes a shortcut's launcher. Its app still shows while it runs.
pub fn removeShortcut(self: *Self, shortcut: Shortcut) void {
    const server = self.output.?.server;
    if (shortcut == .trash) {
        @import("config").setting_save.saveCompositor(gpa, server.io, server.config.path, "dock_show_trash", false) catch |err| {
            std.log.warn("could not remove the dock's trash: {}", .{err});
            return;
        };
        server.config.compositor.dock_show_trash = false;
    } else self.saveHidden("dock_hidden_shortcuts", @tagName(shortcut)) catch |err| {
        std.log.warn("could not remove dock shortcut: {}", .{err});
        return;
    };
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
}

fn saveHidden(self: *Self, comptime key: []const u8, name: []const u8) !void {
    const server = self.output.?.server;
    const old = @field(server.config.compositor, key);
    if (hidden(old, name)) return;
    const a = server.config.arena.allocator();
    const items = try a.alloc([]const u8, old.len + 1);
    @memcpy(items[0..old.len], old);
    items[old.len] = try a.dupe(u8, name);
    try @import("config").setting_save.saveCompositor(gpa, server.io, server.config.path, key, @as([]const []const u8, items));
    @field(server.config.compositor, key) = items;
}

/// Where a dragged application would be pinned for a pointer at layout
/// position `x`, `y`: the gap before that pin. Null when it is not over the dock.
pub fn dropSlotAt(self: *const Self, x: f64, y: f64) ?usize {
    if (!self.reachable() or self.count == 0) return null;
    const local_x = x - @as(f64, @floatFromInt(self.box.x));
    const local_y = y - @as(f64, @floatFromInt(self.box.y));
    if (local_x < 0 or local_y < 0 or local_x >= @as(f64, @floatFromInt(self.box.width)) or local_y >= @as(f64, @floatFromInt(self.box.height))) return null;
    const m = self.metrics();
    return slotFor(if (self.position.vertical()) local_y else local_x, m.padding(), m.itemStep(), self.pin_base, self.pin_count);
}

/// The dock is on screen enough to be pointed at: an auto-hidden one is not
/// there until it has mostly faded in.
fn reachable(self: *const Self) bool {
    return self.visible and !self.parked and self.reveal.value(anim.nowMs()) >= 0.5;
}

/// The nearest gap between buttons, as a pin position: icons sit one `step`
/// apart after `padding`, the first pin at button `base`.
fn slotFor(along: f64, padding: i32, step: i32, base: usize, pins: usize) usize {
    const gap = @round((along - @as(f64, @floatFromInt(padding))) / @as(f64, @floatFromInt(step)));
    return @intFromFloat(std.math.clamp(gap - @as(f64, @floatFromInt(base)), 0, @as(f64, @floatFromInt(pins))));
}

fn pinIndex(self: *const Self, app_id: []const u8) ?usize {
    for (self.pins[0..self.pin_count], 0..) |pin, i| if (std.mem.eql(u8, pin.id, app_id)) return i;
    return null;
}

/// Whether dropping `app_id`'s pin in the gap before pin `slot` changes
/// nothing: the gaps on either side of the pin itself, or it is gone.
pub fn staysPut(self: *const Self, app_id: []const u8, slot: usize) bool {
    const from = self.pinIndex(app_id) orelse return true;
    return slot == from or slot == from + 1;
}

/// The icon a pinned application's button shows, once it is loaded.
pub fn pinIcon(self: *const Self, app_id: []const u8) ?IconEntry {
    const output = self.output orelse return null;
    const pin = self.pins[self.pinIndex(app_id) orelse return null];
    const lookup = output.server.iconLookup(pin.icon, self.iconRaster(self.metrics()));
    return if (lookup == .ready) lookup.ready else null;
}

/// Moves a pinned application to the gap before pin `slot` (`pin_count` is the
/// end). Pins no longer installed keep their places around it.
pub fn movePin(self: *Self, app_id: []const u8, slot: usize) void {
    if (self.staysPut(app_id, slot)) return;
    const from = self.pinIndex(app_id).?;
    const server = self.output.?.server;
    const old = server.config.compositor.dock_pinned_apps;
    const moving = self.pins[from].config_index;
    const items = server.config.arena.allocator().alloc([]const u8, old.len) catch return;
    var len: usize = 0;
    var placed = false;
    for (old, 0..) |id, i| {
        if (i == moving) continue;
        if (!placed and slot < self.pin_count and i == self.pins[slot].config_index) {
            items[len] = old[moving];
            len += 1;
            placed = true;
        }
        items[len] = id;
        len += 1;
    }
    if (!placed) {
        items[len] = old[moving];
        len += 1;
    }
    self.savePinned(items[0..len]);
}

/// Shows (or clears) the drop marker of a drag in progress.
pub fn setDropSlot(self: *Self, slot: ?usize) void {
    if (self.drop_slot == slot) return;
    self.drop_slot = slot;
    self.repaint();
}

/// Pins an application, from the start menu, at `slot` among the pins. Quietly
/// ignores one that is already pinned, is not installed, is a shortcut's own
/// app, or does not fit.
pub fn pinApp(self: *Self, app_id: []const u8, slot: usize) void {
    const server = self.output.?.server;
    const old = server.config.compositor.dock_pinned_apps;
    if (old.len >= max_pins or hidden(old, app_id)) return;
    {
        const snapshot = server.start_menu_catalog.retainSnapshot();
        defer snapshot.release();
        const entry = default_apps.find(snapshot.entries, app_id) orelse return;
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const matches = self.shortcutApps(snapshot.entries, scratch.allocator());
        for ([_]Shortcut{ .files, .terminal }) |shortcut| {
            if (self.shortcutShown(shortcut) and std.mem.eql(u8, matches[@intFromEnum(shortcut)].id, entry.id)) return;
        }
    }
    const at = if (slot < self.pin_count) self.pins[slot].config_index else old.len;
    const a = server.config.arena.allocator();
    const items = a.alloc([]const u8, old.len + 1) catch return;
    @memcpy(items[0..at], old[0..at]);
    items[at] = a.dupe(u8, app_id) catch return;
    @memcpy(items[at + 1 ..], old[at..]);
    self.savePinned(items);
}

pub fn unpinApp(self: *Self, app_id: []const u8) void {
    const server = self.output.?.server;
    const old = server.config.compositor.dock_pinned_apps;
    const a = server.config.arena.allocator();
    const items = a.alloc([]const u8, old.len) catch return;
    var len: usize = 0;
    for (old) |id| {
        if (std.mem.eql(u8, id, app_id)) continue;
        items[len] = id;
        len += 1;
    }
    if (len == old.len) return;
    self.savePinned(items[0..len]);
}

fn savePinned(self: *Self, items: []const []const u8) void {
    const server = self.output.?.server;
    @import("config").setting_save.saveCompositor(gpa, server.io, server.config.path, "dock_pinned_apps", items) catch |err| {
        std.log.warn("could not save pinned dock apps: {}", .{err});
        return;
    };
    server.config.compositor.dock_pinned_apps = items;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
}

/// Windows, theme or icons changed: rebuild on the output's next frame. A
/// hidden dock rebuilds when it is shown again.
pub fn invalidate(self: *Self) void {
    self.dirty = true;
    if (self.visible and !self.parked) self.output.?.wlr_output.scheduleFrame();
}

pub fn scroll(self: *Self, delta: f64) void {
    // A pending rebuild may add windows; it clamps the offset.
    if (delta == 0 or (!self.dirty and self.windows + self.fixedCount() <= self.count)) return;
    if (delta > 0) self.offset +|= 1 else self.offset -|= 1;
    self.invalidate();
}

pub fn captureAnimations(self: *Self, allocator: std.mem.Allocator, list: *std.ArrayList(anim.LiveCapture), now_ms: i64) !void {
    for (self.animations[0..self.count]) |*pill| {
        try anim.captureIfLive(allocator, list, &pill.width, .taskbar_hover, now_ms);
        try anim.captureIfLive(allocator, list, &pill.opacity, .taskbar_hover, now_ms);
        try anim.captureIfLive(allocator, list, &pill.zoom, .dock_hover, now_ms);
    }
}

pub fn appendAnimations(self: *const Self, allocator: std.mem.Allocator, list: *std.ArrayList(@import("ipc/protocol.zig").AnimationData), now_ms: i64) !void {
    const output = self.output orelse return;
    const inspector = @import("ipc/animations.zig");
    for (self.animations[0..self.count], self.buttons[0..self.count]) |pill, button| {
        const prefix = try std.fmt.allocPrint(allocator, "dock.{s}.{s}", .{ std.mem.span(output.wlr_output.name), button.name orelse "item" });
        defer allocator.free(prefix);
        try inspector.appendLive(allocator, list, try std.fmt.allocPrint(allocator, "{s}.pill_width", .{prefix}), pill.width, now_ms);
        try inspector.appendLive(allocator, list, try std.fmt.allocPrint(allocator, "{s}.pill_opacity", .{prefix}), pill.opacity, now_ms);
        try inspector.appendLive(allocator, list, try std.fmt.allocPrint(allocator, "{s}.hover_zoom", .{prefix}), pill.zoom, now_ms);
    }
}

fn clicked(owner: ?*anyopaque, index: usize) void {
    const self: *Self = @ptrCast(@alignCast(owner.?));
    const output = self.output.?;
    const server = output.server;
    if (server.locker != null) return;
    if (self.openWindowPicker(index)) return;
    if (self.topAt(index)) |top| {
        const focused = @import("ipc/handlers.zig").findFocusedToplevel(server) == top;
        if (!top.minimized and focused and server.world.isWindowVisible(top, output)) {
            top.minimize();
        } else {
            if (top.minimized) top.restore() else server.world.focus(top);
            server.world.navigateTo(top, output);
        }
    } else if (self.pin_of[index]) |pin_index| {
        const snapshot = server.start_menu_catalog.retainSnapshot();
        defer snapshot.release();
        const id = self.pins[pin_index].id;
        const entry = default_apps.find(snapshot.entries, id) orelse return;
        server.launch_feedback.setOrigin(self.launchOrigin(index));
        defer server.launch_feedback.clearOrigin();
        @import("start_menu/launch.zig").launch(gpa, server, entry) catch |err| std.log.warn("could not launch pinned app {s}: {}", .{ id, err });
    } else if (self.shortcuts[index]) |shortcut| switch (shortcut) {
        .applications => output.toggleAppLauncher(),
        .files, .terminal => {
            server.launch_feedback.setOrigin(self.launchOrigin(index));
            defer server.launch_feedback.clearOrigin();
            @import("config_runtime/actions.zig").executeAction(server, .{ .spawn = if (shortcut == .files) "default-file-manager" else "default-terminal" });
        },
        .settings => output.toggleControlCenter(),
        .trash => {
            server.launch_feedback.setOrigin(self.launchOrigin(index));
            defer server.launch_feedback.clearOrigin();
            openTrash(server);
        },
    };
}

/// Opens the trash (`$XDG_DATA_HOME/Trash/files`) in the default file manager,
/// as the desktop's Trash icon does.
fn openTrash(server: *Server) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const home = server.environ.getPosix("HOME") orelse return;
    const data_home = server.environ.getPosix("XDG_DATA_HOME") orelse (std.fmt.allocPrint(a, "{s}/.local/share", .{home}) catch return);
    const trash = std.fmt.allocPrint(a, "{s}/Trash/files", .{data_home}) catch return;
    // Files browses the trash by path; it must exist before the first deletion.
    std.Io.Dir.cwd().createDirPath(server.io, trash) catch {};
    const id = server.config.compositor.default_file_manager;
    if (id.len > 0) {
        const snapshot = server.start_menu_catalog.retainSnapshot();
        defer snapshot.release();
        if (default_apps.find(snapshot.entries, id)) |entry| {
            const uris = @import("desktop/dnd.zig").uriList(a, &.{trash}) catch return;
            const uri = std.mem.trimEnd(u8, uris, "\r\n");
            @import("start_menu/launch.zig").launchUris(gpa, server, entry, &.{uri}) catch |err| std.log.warn("could not open the trash in {s}: {}", .{ id, err });
            return;
        }
    }
    @import("config_runtime/actions.zig").spawnArgv(server, &.{ "rediwm-files", trash });
}

/// The layout-space square of item `index`'s icon, which a window it launches
/// grows out of.
fn launchOrigin(self: *const Self, index: usize) @import("launch_feedback.zig").Origin {
    const button = &self.buttons[index];
    const side: f64 = @min(button.computed_width, button.computed_height);
    return .{
        .x = @as(f64, @floatFromInt(self.box.x)) + button.computed_x + (button.computed_width - side) / 2,
        .y = @as(f64, @floatFromInt(self.box.y)) + button.computed_y + (button.computed_height - side) / 2,
        .width = side,
        .height = side,
    };
}
