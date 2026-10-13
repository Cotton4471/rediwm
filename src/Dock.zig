//! Optional output-local launcher. Retained rasters; animation uses output frames.
const std = @import("std");
const wlr = @import("wlroots");
const ui = @import("ui");
const Output = @import("Output.zig");
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
pub const Shortcut = enum { applications, files, terminal, settings };

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

const Pill = struct {
    shortcut: ?Shortcut = null,
    id: u64 = 0,
    width: anim.Anim = .{},
    opacity: anim.Anim = .{ .property = .opacity },
};

output: ?*Output = null,
tree: ?*wlr.SceneTree = null,
node: ?*wlr.SceneBuffer = null,
tooltip: ?*wlr.SceneBuffer = null,
glass_effect: ?*glass.Effect = null,
data: SceneData = undefined,
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = config.dock_height_default },
scale: f32 = 0,
dirty: bool = true,
visible: bool = false,
root: ui.layout.Widget = .{ .kind = .container },
buttons: [max_items]ui.layout.Widget = undefined,
ids: [max_items]u64 = @splat(0),
shortcuts: [max_items]?Shortcut = @splat(null),
pills: [max_items]Pill = @splat(.{}),
pills_animating: bool = false,
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

pub fn deinit(self: *Self) void {
    if (self.output) |output| if (output.server.input.window_menu.dock == self) output.server.input.window_menu.close();
    self.dispatcher.reset();
    if (self.tree) |tree| tree.node.destroy();
    self.arena.deinit();
    self.* = .{};
}

fn ensureNodes(self: *Self, output: *Output) !void {
    if (self.tree != null) return;
    const tree = try output.server.taskbar_tree.createSceneTree();
    errdefer tree.node.destroy();
    const node = try tree.createSceneBuffer(null);
    const tooltip = try tree.createSceneBuffer(null);
    node.setFilterMode(.bilinear);
    tooltip.setFilterMode(.bilinear);
    tooltip.point_accepts_input = ignoreInput;
    self.output = output;
    self.data = .{ .role = .{ .dock = self } };
    self.data.attach(&node.node);
    self.tree = tree;
    self.node = node;
    self.tooltip = tooltip;
    self.glass_effect = glass.Engine.attach(output.server.glass_engine, node, &node.node, .taskbar);
}

fn ignoreInput(_: *wlr.SceneBuffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

pub fn tick(self: *Self, output: *Output, now_ms: i64) bool {
    const server = output.server;
    if (!server.config.compositor.dock_enabled or server.greeter_mode or !output.isAvailable() or output.idle_blanked) {
        if (self.tree != null) self.deinit();
        return false;
    }
    self.ensureNodes(output) catch return false;
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(server);
    const usable = output.usableBox();
    const m: Metrics = .{ .height = @intCast(server.config.compositor.dock_height) };
    const shortcut_count = self.shortcutCount();
    const min_width = @max(260, @as(i32, @intCast(shortcut_count)) * m.itemStep() + m.padding() * 2 + 12);
    const visible = server.locker == null and usable.width >= min_width and usable.height >= @max(140, m.height + 72) and
        !(if (focused) |top| top.fullscreen and top.currentOutput() == output else false);
    self.tree.?.node.setEnabled(visible);
    if (self.visible != visible) {
        self.visible = visible;
        self.leave();
        self.dirty = true;
    }
    if (!visible) {
        if (server.input.window_menu.dock == self) server.input.window_menu.close();
        return false;
    }
    if (self.scale != output.wlr_output.scale) self.dirty = true;
    if (self.box.height != m.height) self.dirty = true;
    // Output geometry can change without a window or theme notification.
    const capacity: usize = @intCast(@min(max_items - shortcut_count, @max(0, @divTrunc(usable.width - m.padding() * 2 - 16, m.itemStep()) - @as(i32, @intCast(shortcut_count)))));
    const wanted = @min(capacity, self.windows) + shortcut_count;
    if (self.box.width != @as(i32, @intCast(wanted)) * m.itemStep() + m.padding() * 2) self.dirty = true;
    const rebuilt = self.dirty;
    if (rebuilt) self.rebuild(capacity, usable) catch return false;
    self.tree.?.node.setEnabled(self.count > 0);
    if (self.count == 0) {
        self.pills_animating = false;
        return false;
    }
    if (rebuilt or self.pills_animating) self.paint(now_ms) catch return false;
    self.place(usable);
    self.tree.?.node.setPosition(self.box.x, self.box.y);
    return self.pills_animating;
}

fn hidden(items: []const []const u8, name: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn shortcutShown(self: *Self, shortcut: Shortcut) bool {
    return !hidden(self.output.?.server.config.compositor.dock_hidden_shortcuts, @tagName(shortcut));
}

fn shortcutCount(self: *Self) usize {
    var count: usize = 0;
    for (std.enums.values(Shortcut)) |shortcut| if (self.shortcutShown(shortcut)) {
        count += 1;
    };
    return count;
}

fn place(self: *Self, usable: wlr.Box) void {
    self.box.x = usable.x + @divTrunc(usable.width - self.box.width, 2);
    self.box.y = usable.y + usable.height - self.box.height - 10;
}

fn metrics(self: *const Self) Metrics {
    return .{ .height = self.box.height };
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
fn shortcutApps(self: *Self, entries: []const apps.AppEntry, scratch: std.mem.Allocator) [4]AppMatch {
    const server = self.output.?.server;
    var matches: [4]AppMatch = .{ .{}, .{ .id = "rediwm-files" }, .{ .id = "foot" }, .{ .id = Toplevel.settings_app_id } };
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

fn rebuild(self: *Self, capacity: usize, usable: wlr.Box) !void {
    const output = self.output.?;
    const previous_pills = self.pills;
    const previous_count = self.count;
    const snapshot = output.server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const matches = self.shortcutApps(snapshot.entries, scratch.allocator());
    var targets: [4]?*Toplevel = @splat(null);
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(output.server);
    var tops: std.ArrayList(*Toplevel) = .empty;
    defer tops.deinit(gpa);
    var it = output.server.world.toplevels.iterator(.forward);
    windows: while (it.next()) |top| {
        if (!top.in_world or top.closing or top.backend_gone or top.tab_hidden or top.dock_hidden or
            hidden(output.server.config.compositor.dock_hidden_apps, top.appId()) or
            !@import("workspaces.zig").visible(top) or (top.live_rules.skip_taskbar orelse false) or
            (output.server.world.workspaces.active and top.currentOutput() != output)) continue;
        for ([_]Shortcut{ .files, .terminal, .settings }) |shortcut| {
            if (!matches[@intFromEnum(shortcut)].matches(top)) continue;
            const target = &targets[@intFromEnum(shortcut)];
            // A removed shortcut also hides the app it represents. Keep the
            // focused window, then a visible window, then the most recent one.
            if (self.shortcutShown(shortcut) and (target.* == null or
                (target.*.? != focused and (top == focused or (target.*.?.minimized and !top.minimized))))) target.* = top;
            continue :windows;
        }
        try tops.append(gpa, top);
    }
    std.mem.sort(*Toplevel, tops.items, {}, struct {
        fn less(_: void, a: *Toplevel, b: *Toplevel) bool {
            return a.id < b.id;
        }
    }.less);
    self.windows = tops.items.len;
    self.offset = @min(self.offset, self.windows -| capacity);
    const window_count = @min(capacity, self.windows);
    self.count = window_count + self.shortcutCount();
    self.box.height = @intCast(output.server.config.compositor.dock_height);
    const m = self.metrics();
    self.box.width = @as(i32, @intCast(self.count)) * m.itemStep() + m.padding() * 2;
    self.scale = output.wlr_output.scale;
    const hovered = self.dispatcher.hovered != null;
    self.dispatcher.reset();
    _ = self.arena.reset(.retain_capacity);
    self.root = .{ .kind = .container, .children = self.buttons[0..self.count], .computed_width = @floatFromInt(self.box.width), .computed_height = @floatFromInt(self.box.height) };
    var index: usize = 0;
    for ([_]Shortcut{ .applications, .files, .terminal }) |shortcut| {
        if (!self.shortcutShown(shortcut)) continue;
        self.setButton(index, shortcut, if (targets[@intFromEnum(shortcut)]) |top| top.id else 0);
        index += 1;
    }
    for (tops.items[self.offset .. self.offset + window_count]) |top| {
        self.setButton(index, null, top.id);
        index += 1;
    }
    if (self.shortcutShown(.settings)) self.setButton(index, .settings, if (targets[@intFromEnum(Shortcut.settings)]) |top| top.id else 0);
    for (self.pills[0..self.count], 0..) |*pill, i| {
        const shortcut = self.shortcuts[i];
        const id = self.ids[i];
        pill.* = .{ .shortcut = shortcut, .id = id };
        // Widget indexes move as windows open or items are removed. A
        // shortcut keeps its animation when its representative window changes.
        for (previous_pills[0..previous_count]) |previous| {
            if (previous.shortcut == shortcut and (shortcut != null or previous.id == id)) {
                pill.* = previous;
                break;
            }
        }
    }
    // The pointer rests on a replaced button: hover it before painting, so
    // the rebuild paints once.
    if (hovered) {
        self.place(usable);
        const cursor = output.server.input.cursor;
        self.dispatcher.pointerMotion(&self.root, @floatCast(cursor.x - @as(f64, @floatFromInt(self.box.x))), @floatCast(cursor.y - @as(f64, @floatFromInt(self.box.y))));
    }
    self.dirty = false;
}

fn setButton(self: *Self, index: usize, shortcut: ?Shortcut, id: u64) void {
    const m = self.metrics();
    self.ids[index] = id;
    self.shortcuts[index] = shortcut;
    self.buttons[index] = .{
        .name = if (shortcut) |s| @tagName(s) else std.fmt.allocPrint(self.arena.allocator(), "window_{d}", .{id}) catch "window",
        .kind = .{ .button = .{ .label = self.arena.allocator().dupe(u8, self.label(index)) catch "Application", .variant = .ghost, .owner = self, .id = index, .on_click = clicked } },
        .computed_x = @floatFromInt(@as(i32, @intCast(index)) * m.itemStep() + m.padding()),
        .computed_y = @floatFromInt(m.length(8)),
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

fn label(self: *Self, index: usize) []const u8 {
    if (self.shortcuts[index]) |shortcut| return switch (shortcut) {
        .applications => "Applications",
        .files => "Files",
        .terminal => "Terminal",
        .settings => "Settings",
    };
    return if (self.topAt(index)) |top| top.title() else "Application";
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
    icon: ?IconEntry,
    pill_width: f32,
    pill_opacity: f32,
};

fn paint(self: *Self, now_ms: i64) !void {
    const output = self.output.?;
    const m = self.metrics();
    const pal = ui.theme.shellPalette();
    var bg = pal.dock_bg orelse ui.theme.taskbar(.taskbar_bg);
    if (pal.dock_bg == null) bg[3] = @max(bg[3], 0.86);
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(output.server);
    var looks: [max_items]Look = undefined;
    self.pills_animating = false;
    var hasher = std.hash.Wyhash.init(0);
    hashValue(&hasher, .{ pal, bg, self.scale, self.box.width, self.box.height, self.count, self.offset, self.windows });
    for (self.buttons[0..self.count], looks[0..self.count], 0..) |button, *look, index| {
        const top = self.topAt(index);
        const icon_name = if (self.shortcuts[index]) |shortcut| switch (shortcut) {
            .applications => "builtin:redi-logo",
            .files => "rediwm-files",
            .terminal => "utilities-terminal",
            .settings => "preferences-system",
        } else if (top) |t| t.appId() else "";
        const lookup = output.server.iconLookup(icon_name, @import("geometry.zig").devicePixels(m.length(36), self.scale));
        const active = top != null and top == focused;
        const width: f32 = if (top == null) 0 else if (active) 22 else 10;
        const opacity: f32 = if (top) |t| if (t.minimized) 0.4 else 1 else 0;
        const pill = &self.pills[index];
        if (pill.width.to != width) pill.width.retargetTo(now_ms, width, anim.curveFor(.taskbar_hover));
        if (pill.opacity.to != opacity) pill.opacity.retargetTo(now_ms, opacity, anim.curveFor(.taskbar_hover));
        _ = pill.width.sampleChanged(now_ms, anim.rasterPixelQuantum(self.scale) / (4 * m.size(1)));
        _ = pill.opacity.sampleChanged(now_ms, anim.rasterAlphaQuantum());
        self.pills_animating = self.pills_animating or !pill.width.settled(now_ms) or !pill.opacity.settled(now_ms);
        look.* = .{
            .focused = active,
            .icon = if (lookup == .ready) lookup.ready else null,
            .pill_width = @max(0, pill.width.last_quantised),
            .pill_opacity = std.math.clamp(pill.opacity.last_quantised, 0, 1),
        };
        const icon_id: ?u64 = if (look.icon) |icon| icon.id else null;
        hashValue(&hasher, .{ self.shortcuts[index], button.kind.button.state, look.focused, icon_id, look.pill_width, look.pill_opacity });
    }
    const key = hasher.final();
    if (key != self.drawn) try self.paintDock(pal, bg, looks[0..self.count]);
    self.drawn = key;
    try self.paintTooltip();
}

fn paintDock(self: *Self, pal: ui.theme.Theme, bg: [4]f32, looks: []const Look) !void {
    const m = self.metrics();
    const image = try PanelBuffer.create(self.box.width, self.box.height, self.scale);
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.scale);
    r.palette = pal;
    var border = pal.accent;
    border[3] = 0.55;
    border = pal.dock_border orelse border;
    const radius = @min(if (pal.dock_radius > 0) pal.dock_radius else ui.window_chrome.frameRadius(), @as(f32, @floatFromInt(self.box.height)) / 2);
    glass.Effect.configure(self.glass_effect, radius, 1);
    r.fillRect(0, 0, @floatFromInt(self.box.width), @floatFromInt(self.box.height), .{ .color = bg, .radius = radius, .border_width = 1, .border_color = border });
    for (self.buttons[0..self.count], looks, 0..) |button, look, index| {
        const x = button.computed_x;
        const cx = x + button.computed_width / 2;
        const cy = button.computed_y + button.computed_height / 2;
        ui.widgets.button.paintBackground(&r, .{ .x = x, .y = button.computed_y, .w = button.computed_width, .h = button.computed_height }, .{ .variant = .ghost, .radius = m.size(12) }, .{ .pointer = button.kind.button.state, .selected = look.focused });
        if (look.icon) |icon| {
            const size: f32 = @floatFromInt(m.length(36));
            r.drawImageCover(cx - size / 2, cy - size / 2, size, size, 0, .{ .pixels = icon.pixels, .width = icon.size, .height = icon.size });
        } else {
            const size: f32 = @floatFromInt(m.length(34));
            r.drawIcon(cx - size / 2, cy - size / 2, size, size, .{ .id = if (self.shortcuts[index]) |shortcut| switch (shortcut) {
                .applications => .grid,
                .files => .folder,
                .terminal => .terminal,
                .settings => .settings,
            } else .generic, .color = pal.window_fg });
        }
        if (look.pill_width > 0 and look.pill_opacity > 0) {
            var accent = pal.accent;
            accent[3] *= look.pill_opacity;
            const width = m.size(look.pill_width);
            const thickness = @max(2, m.size(4));
            r.fillRect(cx - width / 2, @floatFromInt(m.length(58)), width, thickness, .{ .color = accent, .radius = @min(width, thickness) / 2 });
        }
    }
    var divider = pal.window_fg;
    divider[3] = 0.16;
    if (self.count > 1 and self.shortcuts[0] == .applications) r.fillRect(@floatFromInt(m.itemStep() + m.padding() - m.length(4)), m.size(18), 1, m.size(30), .{ .color = divider });
    if (self.offset > 0) r.drawIcon(1, m.size(28), m.size(10), m.size(12), .{ .id = .chevron_left, .color = pal.accent });
    if (self.offset + self.count - self.shortcutCount() < self.windows) r.drawIcon(@as(f32, @floatFromInt(self.box.width)) - m.size(11), m.size(28), m.size(10), m.size(12), .{ .id = .chevron_right, .color = pal.accent });
    self.node.?.setBuffer(&image.base);
    self.node.?.setDestSize(self.box.width, self.box.height);
}

fn paintTooltip(self: *Self) !void {
    const hovered = self.dispatcher.hovered orelse {
        self.tooltip.?.node.setEnabled(false);
        return;
    };
    if (hovered.kind != .button) {
        self.tooltip.?.node.setEnabled(false);
        return;
    }
    const index = hovered.kind.button.id;
    const pal = ui.theme.shellPalette();
    const value = self.label(index);
    var hasher = std.hash.Wyhash.init(0);
    hashValue(&hasher, .{ pal, self.scale, self.box.width, value });
    const key = hasher.final();
    if (key == self.tip_drawn) {
        // Same text: only the button under it may differ.
        const width = self.tooltip.?.dst_width;
        self.tooltip.?.node.setPosition(std.math.clamp(@as(i32, @intFromFloat(hovered.computed_x + hovered.computed_width / 2)) - @divTrunc(width, 2), 0, self.box.width - width), -38);
        self.tooltip.?.node.setEnabled(true);
        return;
    }
    const width: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(self.box.width)), @max(80, (ui.text.measureWidthF(value, .manrope, pal.font_size, 1) catch 100) + 24)));
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
    self.tooltip.?.node.setPosition(std.math.clamp(@as(i32, @intFromFloat(hovered.computed_x + hovered.computed_width / 2)) - @divTrunc(width, 2), 0, self.box.width - width), -38);
    self.tooltip.?.node.setEnabled(true);
    self.tip_drawn = key;
}

pub fn motion(self: *Self, x: f64, y: f64) void {
    const old = self.dispatcher.hovered;
    self.dispatcher.pointerMotion(&self.root, @floatCast(x), @floatCast(y));
    if (old != self.dispatcher.hovered) self.repaint();
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
    // Shell launchers activate on press, like the taskbar.
    self.dispatcher.pointerButtonDown(&self.root, @floatCast(x), @floatCast(y));
    self.dispatcher.pointerButtonUp(&self.root, @floatCast(x), @floatCast(y));
    self.repaint();
}

pub fn contextMenu(self: *Self, x: f64, y: f64, screen_x: i32) bool {
    self.dispatcher.pointerMotion(&self.root, @floatCast(x), @floatCast(y));
    const button = self.dispatcher.hovered orelse return false;
    if (button.kind != .button) return false;
    const index = button.kind.button.id;
    const target = self.topAt(index);
    const shortcut = self.shortcuts[index];
    if (target == null and shortcut == null) return false;
    const input = &self.output.?.server.input;
    input.window_menu.openDock(self, target, shortcut, screen_x);
    return input.window_menu.node != null;
}

pub fn remove(self: *Self, shortcut: ?Shortcut, target: ?*Toplevel) void {
    const server = self.output.?.server;
    if (shortcut) |s| {
        self.saveHidden("dock_hidden_shortcuts", @tagName(s)) catch |err| {
            std.log.warn("could not remove dock shortcut: {}", .{err});
            return;
        };
    } else if (target) |top| {
        const id = top.appId();
        if (id.len == 0) {
            top.dock_hidden = true;
        } else self.saveHidden("dock_hidden_apps", id) catch |err| {
            std.log.warn("could not remove dock app: {}", .{err});
            return;
        };
    } else return;
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

/// Windows, theme or icons changed: rebuild on the output's next frame. A
/// hidden dock rebuilds when it is shown again.
pub fn invalidate(self: *Self) void {
    self.dirty = true;
    if (self.visible) self.output.?.wlr_output.scheduleFrame();
}

pub fn scroll(self: *Self, delta: f64) void {
    // A pending rebuild may add windows; it clamps the offset.
    if (delta == 0 or (!self.dirty and self.windows + self.shortcutCount() <= self.count)) return;
    if (delta > 0) self.offset +|= 1 else self.offset -|= 1;
    self.invalidate();
}

pub fn captureAnimations(self: *Self, allocator: std.mem.Allocator, list: *std.ArrayList(anim.LiveCapture), now_ms: i64) !void {
    for (self.pills[0..self.count]) |*pill| {
        try anim.captureIfLive(allocator, list, &pill.width, .taskbar_hover, now_ms);
        try anim.captureIfLive(allocator, list, &pill.opacity, .taskbar_hover, now_ms);
    }
}

pub fn appendAnimations(self: *const Self, allocator: std.mem.Allocator, list: *std.ArrayList(@import("ipc/protocol.zig").AnimationData), now_ms: i64) !void {
    const output = self.output orelse return;
    const inspector = @import("ipc/animations.zig");
    for (self.pills[0..self.count], self.buttons[0..self.count]) |pill, button| {
        const prefix = try std.fmt.allocPrint(allocator, "dock.{s}.{s}", .{ std.mem.span(output.wlr_output.name), button.name orelse "item" });
        defer allocator.free(prefix);
        try inspector.appendLive(allocator, list, try std.fmt.allocPrint(allocator, "{s}.pill_width", .{prefix}), pill.width, now_ms);
        try inspector.appendLive(allocator, list, try std.fmt.allocPrint(allocator, "{s}.pill_opacity", .{prefix}), pill.opacity, now_ms);
    }
}

fn clicked(owner: ?*anyopaque, index: usize) void {
    const self: *Self = @ptrCast(@alignCast(owner.?));
    const output = self.output.?;
    const server = output.server;
    if (server.locker != null) return;
    if (self.topAt(index)) |top| {
        const focused = @import("ipc/handlers.zig").findFocusedToplevel(server) == top;
        if (!top.minimized and focused and server.world.isWindowVisible(top, output)) {
            top.minimize();
        } else {
            if (top.minimized) top.restore() else server.world.focus(top);
            server.world.navigateTo(top, output);
        }
    } else if (self.shortcuts[index]) |shortcut| switch (shortcut) {
        .applications => output.toggleStartMenu(),
        .files, .terminal => @import("config_runtime/actions.zig").executeAction(server, .{ .spawn = if (shortcut == .files) "default-file-manager" else "default-terminal" }),
        .settings => output.toggleControlCenter(),
    };
}
