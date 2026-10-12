//! Optional output-local launcher. Retained rasters; no animation or polling timer.
const std = @import("std");
const wlr = @import("wlroots");
const ui = @import("ui");
const Output = @import("Output.zig");
const Toplevel = @import("Toplevel.zig");
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const SceneData = @import("scene_data.zig").SceneData;
const gpa = @import("main.zig").gpa;
const Self = @This();
const height = 68;
const step = 56;
const max_items = 64;

output: ?*Output = null,
tree: ?*wlr.SceneTree = null,
node: ?*wlr.SceneBuffer = null,
tooltip: ?*wlr.SceneBuffer = null,
data: SceneData = undefined,
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = height },
scale: f32 = 0,
dirty: bool = true,
visible: bool = false,
root: ui.layout.Widget = .{ .kind = .container },
buttons: [max_items]ui.layout.Widget = undefined,
ids: [max_items]u64 = @splat(0),
count: usize = 0,
offset: usize = 0,
windows: usize = 0,
dispatcher: ui.input.Dispatcher = .{},
arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

pub fn deinit(self: *Self) void {
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
    if (@import("glass.zig").Engine.attach(output.server.glass_engine, node, &node.node, .taskbar)) |effect| effect.configure(16, 1);
}

fn ignoreInput(_: *wlr.SceneBuffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

pub fn tick(self: *Self, output: *Output) void {
    const server = output.server;
    if (!server.config.compositor.dock_enabled or server.greeter_mode or !output.isAvailable() or output.idle_blanked) {
        if (self.tree != null) self.deinit();
        return;
    }
    self.ensureNodes(output) catch return;
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(server);
    const usable = output.usableBox();
    const visible = server.locker == null and usable.width >= 260 and usable.height >= 140 and
        !(if (focused) |top| top.fullscreen and top.currentOutput() == output else false);
    self.tree.?.node.setEnabled(visible);
    if (self.visible != visible) {
        self.visible = visible;
        self.leave();
        self.dirty = true;
    }
    if (!visible) return;
    if (self.scale != output.wlr_output.scale) self.dirty = true;
    // Output geometry can change without a window or theme notification.
    const capacity: usize = @intCast(@min(max_items - 4, @max(0, @divTrunc(usable.width - 40, step) - 4)));
    const wanted = @min(capacity, self.windows) + 4;
    if (self.box.width != @as(i32, @intCast(wanted)) * step + 24) self.dirty = true;
    const restore_hover = self.dirty and self.dispatcher.hovered != null;
    if (self.dirty) self.rebuild(capacity) catch return;
    self.box.x = usable.x + @divTrunc(usable.width - self.box.width, 2);
    self.box.y = usable.y + usable.height - height - 10;
    self.tree.?.node.setPosition(self.box.x, self.box.y);
    if (restore_hover) self.motion(server.input.cursor.x - @as(f64, @floatFromInt(self.box.x)), server.input.cursor.y - @as(f64, @floatFromInt(self.box.y)));
}

fn rebuild(self: *Self, capacity: usize) !void {
    const output = self.output.?;
    var tops: std.ArrayList(*Toplevel) = .empty;
    defer tops.deinit(gpa);
    var it = output.server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (!top.in_world or top.closing or top.backend_gone or top.tab_hidden or
            !@import("workspaces.zig").visible(top) or (top.live_rules.skip_taskbar orelse false) or
            (output.server.world.workspaces.active and top.currentOutput() != output)) continue;
        try tops.append(gpa, top);
    }
    std.mem.sort(*Toplevel, tops.items, {}, struct {
        fn less(_: void, a: *Toplevel, b: *Toplevel) bool {
            return a.id < b.id;
        }
    }.less);
    self.windows = tops.items.len;
    self.offset = @min(self.offset, self.windows -| capacity);
    self.count = @min(capacity, self.windows) + 4;
    self.box.width = @as(i32, @intCast(self.count)) * step + 24;
    self.scale = output.wlr_output.scale;
    self.dispatcher.reset();
    _ = self.arena.reset(.retain_capacity);
    self.tooltip.?.node.setEnabled(false);
    self.root = .{ .kind = .container, .children = self.buttons[0..self.count], .computed_width = @floatFromInt(self.box.width), .computed_height = height };
    for (self.buttons[0..self.count], 0..) |*button, index| {
        self.ids[index] = if (index >= 3 and index < self.count - 1) tops.items[self.offset + index - 3].id else 0;
        button.* = .{
            .name = if (index == 0) "applications" else if (index == 1) "files" else if (index == 2) "terminal" else if (index == self.count - 1) "settings" else std.fmt.allocPrint(self.arena.allocator(), "window_{d}", .{self.ids[index]}) catch "window",
            .kind = .{ .button = .{ .label = self.arena.allocator().dupe(u8, self.label(index)) catch "Application", .variant = .ghost, .owner = self, .id = index, .on_click = clicked } },
            .computed_x = @as(f32, @floatFromInt(index * step)) + 12,
            .computed_y = 8,
            .computed_width = 48,
            .computed_height = 48,
        };
    }
    try self.paint();
    self.dirty = false;
}

fn topAt(self: *Self, index: usize) ?*Toplevel {
    const id = self.ids[index];
    if (id == 0) return null;
    var it = self.output.?.server.world.toplevels.iterator(.forward);
    while (it.next()) |top| if (top.id == id and top.in_world and !top.backend_gone and !top.closing) return top;
    return null;
}

fn label(self: *Self, index: usize) []const u8 {
    if (index == 0) return "Applications";
    if (index == 1) return "Files";
    if (index == 2) return "Terminal";
    if (index == self.count - 1) return "Settings";
    return if (self.topAt(index)) |top| top.title() else "Application";
}

fn paint(self: *Self) !void {
    const output = self.output.?;
    const pal = ui.theme.shellPalette();
    const image = try PanelBuffer.create(self.box.width, height, self.scale);
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.scale);
    r.palette = pal;
    var bg = ui.theme.taskbar(.taskbar_bg);
    bg[3] = @max(bg[3], 0.86);
    var border = pal.accent;
    border[3] = 0.55;
    r.fillRect(0, 0, @floatFromInt(self.box.width), height, .{ .color = bg, .radius = 16, .border_width = 1, .border_color = border });
    for (self.buttons[0..self.count], 0..) |button, index| {
        const x = button.computed_x;
        const top = self.topAt(index);
        ui.widgets.button.paintBackground(&r, .{ .x = x, .y = 8, .w = 48, .h = 48 }, .{ .variant = .ghost, .radius = 12 }, .{ .pointer = button.kind.button.state, .selected = if (top) |t| @import("ipc/handlers.zig").findFocusedToplevel(output.server) == t else false });
        const icon_name = if (top) |t| t.appId() else if (index == 0) "builtin:redi-logo" else if (index == 1) "rediwm-files" else if (index == 2) "utilities-terminal" else "preferences-system";
        const lookup = output.server.iconLookup(icon_name, @import("geometry.zig").devicePixels(36, self.scale));
        if (lookup == .ready) {
            const icon = lookup.ready;
            r.drawImageCover(x + 6, 14, 36, 36, 0, .{ .pixels = icon.pixels, .width = icon.size, .height = icon.size });
        } else {
            r.drawIcon(x + 7, 15, 34, 34, .{ .id = if (index == 0) .grid else if (index == 1) .folder else if (index == 2) .terminal else if (index == self.count - 1) .settings else .generic, .color = pal.window_fg });
        }
        if (top) |t| {
            const focused = @import("ipc/handlers.zig").findFocusedToplevel(output.server) == t;
            var accent = pal.accent;
            accent[3] *= if (t.minimized) @as(f32, 0.4) else 1;
            const width: f32 = if (focused) 22 else 10;
            r.fillRect(x + 24 - width / 2, 58, width, 4, .{ .color = accent, .radius = 2 });
        }
    }
    var divider = pal.window_fg;
    divider[3] = 0.16;
    r.fillRect(64, 18, 1, 30, .{ .color = divider });
    if (self.offset > 0) r.drawIcon(1, 28, 10, 12, .{ .id = .chevron_left, .color = pal.accent });
    if (self.offset + self.count - 4 < self.windows) r.drawIcon(@floatFromInt(self.box.width - 11), 28, 10, 12, .{ .id = .chevron_right, .color = pal.accent });
    self.node.?.setBuffer(&image.base);
    self.node.?.setDestSize(self.box.width, height);
    try self.paintTooltip();
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
    self.tooltip.?.node.setPosition(std.math.clamp(@as(i32, @intFromFloat(hovered.computed_x + 24)) - @divTrunc(width, 2), 0, self.box.width - width), -38);
    self.tooltip.?.node.setEnabled(true);
}

pub fn motion(self: *Self, x: f64, y: f64) void {
    const old = self.dispatcher.hovered;
    self.dispatcher.pointerMotion(&self.root, @floatCast(x), @floatCast(y));
    if (old != self.dispatcher.hovered) self.repaint();
}

pub fn leave(self: *Self) void {
    if (self.dispatcher.hovered == null) return;
    self.dispatcher.pointerLeave(&self.root);
    self.repaint();
}

fn repaint(self: *Self) void {
    if (self.node == null) return;
    self.paint() catch {};
    self.output.?.wlr_output.scheduleFrame();
}

pub fn press(self: *Self, x: f64, y: f64) void {
    // Shell launchers activate on press, like the taskbar.
    self.dispatcher.pointerButtonDown(&self.root, @floatCast(x), @floatCast(y));
    self.dispatcher.pointerButtonUp(&self.root, @floatCast(x), @floatCast(y));
    self.repaint();
}

pub fn scroll(self: *Self, delta: f64) void {
    if (delta == 0 or self.windows + 4 <= self.count) return;
    if (delta > 0) self.offset +|= 1 else self.offset -|= 1;
    self.dirty = true;
    self.output.?.wlr_output.scheduleFrame();
}

fn clicked(owner: ?*anyopaque, index: usize) void {
    const self: *Self = @ptrCast(@alignCast(owner.?));
    const output = self.output.?;
    const server = output.server;
    if (server.locker != null) return;
    if (index == 0) output.toggleStartMenu() else if (index == 1 or index == 2) {
        @import("config_runtime/actions.zig").executeAction(server, .{ .spawn = if (index == 1) "default-file-manager" else "default-terminal" });
    } else if (index == self.count - 1) output.toggleControlCenter() else if (self.topAt(index)) |top| {
        const focused = @import("ipc/handlers.zig").findFocusedToplevel(server) == top;
        if (!top.minimized and focused and server.world.isWindowVisible(top, output)) {
            top.minimize();
        } else {
            if (top.minimized) top.restore() else server.world.focus(top);
            server.world.navigateTo(top, output);
        }
    }
}
