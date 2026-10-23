//! Pinned apps: drop slots, reordering, pinning and unpinning, and saving the pin list.

const std = @import("std");
const ui = @import("ui");
const IconEntry = @import("../icon_service.zig").Entry;
const default_apps = @import("../config_runtime/default_apps.zig");
const anim = ui.anim;
const gpa = @import("../main.zig").gpa;
const Self = @import("../Dock.zig");
const max_pins = Self.max_pins;
const Shortcut = Self.Shortcut;
const hidden = Self.hidden;

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
pub fn reachable(self: *const Self) bool {
    return self.visible and !self.parked and self.reveal.value(anim.nowMs()) >= 0.5;
}

/// The nearest gap between buttons, as a pin position: icons sit one `step`
/// apart after `padding`, the first pin at button `base`.
pub fn slotFor(along: f64, padding: i32, step: i32, base: usize, pins: usize) usize {
    const gap = @round((along - @as(f64, @floatFromInt(padding))) / @as(f64, @floatFromInt(step)));
    return @intFromFloat(std.math.clamp(gap - @as(f64, @floatFromInt(base)), 0, @as(f64, @floatFromInt(pins))));
}

pub fn pinIndex(self: *const Self, app_id: []const u8) ?usize {
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

pub fn savePinned(self: *Self, items: []const []const u8) void {
    const server = self.output.?.server;
    @import("config").setting_save.saveCompositor(gpa, server.io, server.config.path, "dock_pinned_apps", items) catch |err| {
        std.log.warn("could not save pinned dock apps: {}", .{err});
        return;
    };
    server.config.compositor.dock_pinned_apps = items;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
}
