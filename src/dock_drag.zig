//! Dragging an application out of the start menu onto the dock pins it there,
//! and dragging a pinned icon along the dock moves its pin.
//!
//! The menu and the dock are both drawn by the compositor, so this is not a
//! wl_data_device drag (`desktop_drop.zig` is that): a press on an application
//! row or card, or on a pinned dock icon, arms it, moving `threshold` pixels
//! starts it, and the release over a dock drops. Starting a menu drag makes the
//! menu forget the press, so its release is no click and nothing launches. A
//! pinned icon acts on release instead (`Dock.clickPin`): pressed and released
//! in place it is a click, dragged it moves. The dock under the pointer shows
//! the gap the application would take; Escape and closing the menu abandon the
//! drag.
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("node.zig");
const ui = @import("ui");
const Input = @import("Input.zig");
const Output = @import("Output.zig");
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const geometry = @import("geometry.zig");
const Self = @This();

/// Logical pixels the pointer travels before a press becomes a drag.
const threshold = 8;
const Source = enum { menu, dock };
/// The dragged icon: a tile of `tile` px around an image of `image` px.
const tile = 48;
const image = 38;

/// Where the drag began: an application in the start menu, or a pinned icon.
source: Source = .menu,
id_bytes: [512]u8 = undefined,
id_len: usize = 0,
icon_bytes: [256]u8 = undefined,
icon_len: usize = 0,
has_icon: bool = false,
scale: f32 = 1,
origin_x: f64 = 0,
origin_y: f64 = 0,
/// A press on an application is held, and may still turn out to be a click.
armed: bool = false,
dragging: bool = false,
node: ?*sn.Buffer = null,

fn ignoreInput(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

/// The press that just reached the menu went down on `app_id`'s row or card.
pub fn arm(self: *Self, input: *const Input, app_id: []const u8, icon: ?[]const u8, scale: f32) void {
    self.armFrom(.menu, input, app_id, icon, scale);
}

/// The press that just reached the dock went down on a pinned icon.
pub fn armReorder(self: *Self, input: *const Input, app_id: []const u8, icon: ?[]const u8, scale: f32) void {
    self.armFrom(.dock, input, app_id, icon, scale);
}

fn armFrom(self: *Self, source: Source, input: *const Input, app_id: []const u8, icon: ?[]const u8, scale: f32) void {
    self.* = .{ .source = source, .scale = scale, .origin_x = input.cursor.x, .origin_y = input.cursor.y };
    if (app_id.len == 0 or app_id.len > self.id_bytes.len) return;
    @memcpy(self.id_bytes[0..app_id.len], app_id);
    self.id_len = app_id.len;
    if (icon) |name| if (name.len <= self.icon_bytes.len) {
        @memcpy(self.icon_bytes[0..name.len], name);
        self.icon_len = name.len;
        self.has_icon = true;
    };
    self.armed = true;
}

pub fn active(self: *const Self) bool {
    return self.dragging;
}

/// A pinned icon is being dragged along the dock.
pub fn reordering(self: *const Self) bool {
    return self.dragging and self.source == .dock;
}

fn appId(self: *const Self) []const u8 {
    return self.id_bytes[0..self.id_len];
}

/// Pointer motion with the button down. True while the drag owns the pointer.
pub fn motion(self: *Self, input: *Input) bool {
    if (!self.armed) return false;
    if (input.active_buttons == 0) {
        // The release never reached us (a grab ended it): nothing is held.
        self.finish();
        return false;
    }
    if (!self.dragging) {
        const dx = input.cursor.x - self.origin_x;
        const dy = input.cursor.y - self.origin_y;
        if (dx * dx + dy * dy < threshold * threshold) return false;
        switch (self.source) {
            .menu => {
                const menu = input.open_start_menu orelse {
                    self.* = .{};
                    return false;
                };
                menu.cancelPress();
            },
            // The tile stands for the icon now: nothing on the dock stays hovered
            // (its tooltip would come up under the tile).
            .dock => {
                var docks = input.server.outputs.iterator(.forward);
                while (docks.next()) |output| output.dock.leave();
            },
        }
        self.dragging = true;
        self.createIcon(input);
    }
    if (self.node) |node| node.node.setPosition(
        @intFromFloat(@floor(input.cursor.x - tile / 2)),
        @intFromFloat(@floor(input.cursor.y - tile / 2)),
    );
    input.setNamedCursor("grabbing");
    input.seat.pointerClearFocus();
    self.markDocks(input, false);
    return true;
}

/// A button went up. True when it ended a drag, which the menu must not see.
pub fn release(self: *Self, input: *Input, button: u32) bool {
    if (!self.armed or button != Input.btn_left) return false;
    const held = self.*;
    self.markDocks(input, true);
    self.finish();
    if (held.dragging) {
        // `held` is the drag as it was; `self` is clear again before the dock acts.
        if (held.dropTarget(input)) |drop| switch (held.source) {
            .menu => drop.output.dock.pinApp(held.appId(), drop.slot),
            .dock => drop.output.dock.movePin(held.appId(), drop.slot),
        };
    } else if (held.source == .dock) {
        var docks = input.server.outputs.iterator(.forward);
        while (docks.next()) |output| output.dock.clickPin(input.cursor.x, input.cursor.y, held.appId());
    }
    return held.dragging;
}

/// Abandons a drag in progress, or a press that might have become one.
pub fn cancel(self: *Self, input: *Input) void {
    if (self.dragging) self.markDocks(input, true);
    self.finish();
}

fn finish(self: *Self) void {
    if (self.node) |node| node.node.destroy();
    self.* = .{};
}

const Drop = struct { output: *Output, slot: usize };

/// The dock under the pointer, unless the menu itself is.
fn dropTarget(self: *const Self, input: *const Input) ?Drop {
    if (input.open_start_menu) |menu| if (menu.containsPoint(input.cursor.x, input.cursor.y)) return null;
    var it = input.server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const slot = output.dock.dropSlotAt(input.cursor.x, input.cursor.y) orelse continue;
        // A pin dropped back where it is has nowhere new to go: no marker.
        if (self.source == .dock and output.dock.staysPut(self.appId(), slot)) continue;
        return .{ .output = output, .slot = slot };
    }
    return null;
}

/// Shows the drop gap on the dock under the pointer and clears every other.
fn markDocks(self: *const Self, input: *Input, clear: bool) void {
    const target = if (clear) null else self.dropTarget(input);
    var it = input.server.outputs.iterator(.forward);
    while (it.next()) |output| {
        output.dock.setDropSlot(if (target) |drop| if (drop.output == output) drop.slot else null else null);
    }
}

/// The tile that follows the pointer: the application's icon on a themed backing.
fn createIcon(self: *Self, input: *Input) void {
    const server = input.server;
    const buffer = PanelBuffer.create(tile, tile, self.scale) catch return;
    defer buffer.base.drop();
    const pal = ui.theme.shellPalette();
    var r = ui.paint.Renderer.init(buffer.pixels, buffer.width, buffer.height, self.scale);
    r.palette = pal;
    var bg = pal.window_bg;
    bg[3] = 0.94;
    r.fillRect(0, 0, tile, tile, .{ .color = bg, .radius = 12, .border_width = 1, .border_color = pal.accent });
    const inset: f32 = (tile - image) / 2;
    var drawn = false;
    if (self.source == .dock) {
        // The dock already holds the icon it shows for this pin.
        var docks = server.outputs.iterator(.forward);
        while (docks.next()) |output| {
            const icon = output.dock.pinIcon(self.appId()) orelse continue;
            r.drawImageSmooth(inset, inset, image, image, 0, .{ .pixels = icon.pixels, .width = icon.size, .height = icon.size });
            drawn = true;
            break;
        }
    }
    if (!drawn and self.has_icon) {
        // The menu showed it at one of these sizes, so it is usually cached.
        for ([_]i32{ 48, image }) |logical| {
            const lookup = server.iconLookup(self.icon_bytes[0..self.icon_len], geometry.devicePixels(logical, self.scale));
            if (lookup != .ready) continue;
            const icon = lookup.ready;
            r.drawImageCover(inset, inset, image, image, 0, .{ .pixels = icon.pixels, .width = icon.size, .height = icon.size });
            drawn = true;
            break;
        }
    }
    if (!drawn) r.drawIcon(inset, inset, image, image, .{ .id = .generic, .color = pal.window_fg });
    const node = server.overlay_tree.createSceneBuffer(null) catch return;
    node.point_accepts_input = ignoreInput;
    node.setFilterMode(.bilinear);
    node.setBuffer(&buffer.base);
    node.setDestSize(tile, tile);
    node.node.raiseToTop();
    self.node = node;
}
