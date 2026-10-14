//! The taskbar's window actions. Input owns one menu across all outputs.
const std = @import("std");
const wlr = @import("wlroots");
const Taskbar = @import("../Taskbar.zig");
const Toplevel = @import("../Toplevel.zig");
const Output = @import("../Output.zig");
const Dock = @import("../Dock.zig");
const Buffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");

pub const Menu = struct {
    bar: ?*Taskbar = null,
    output: ?*Output = null,
    dock: ?*Dock = null,
    shortcut: ?Dock.Shortcut = null,
    target: ?*Toplevel = null,
    /// The pinned app a dock button stands for, copied: the dock's own strings
    /// are replaced by a rebuild while the menu is open.
    pin_bytes: [512]u8 = undefined,
    pin_len: usize = 0,
    pinned: bool = false,
    node: ?*wlr.SceneBuffer = null,
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    selected: ?usize = null,

    const padding = 6;
    const row_height = 32;
    const separator = 7;
    const Action = enum {
        close,
        force_close,
        remove,
        unpin,

        fn label(action: Action) []const u8 {
            return switch (action) {
                .close => "Close",
                .force_close => "Force Close",
                .remove => "Remove from dock",
                .unpin => "Unpin from dock",
            };
        }
    };

    fn actions(self: *const Menu) []const Action {
        if (self.pinned) return if (self.target == null) &.{.unpin} else &.{ .close, .force_close, .unpin };
        // Only a shortcut can be removed; a running app always stays.
        if (self.shortcut != null and self.dock != null) return if (self.target == null) &.{.remove} else &.{ .close, .force_close, .remove };
        return &.{ .close, .force_close };
    }

    pub fn open(self: *Menu, bar: *Taskbar, target: *Toplevel, x: i32) void {
        const output = Output.fromWlr(bar.wlr_output) orelse return;
        self.openOn(output, bar, null, target, null, null, x, 0);
    }

    pub fn openDock(self: *Menu, dock: *Dock, target: ?*Toplevel, shortcut: ?Dock.Shortcut, pin: ?[]const u8, x: i32, y: i32) void {
        self.openOn(dock.output orelse return, null, dock, target, shortcut, pin, x, y);
    }

    fn openOn(self: *Menu, output: *Output, bar: ?*Taskbar, dock: ?*Dock, target: ?*Toplevel, shortcut: ?Dock.Shortcut, pin: ?[]const u8, x: i32, pointer_y: i32) void {
        self.close();
        const server = output.server;
        const input = &server.input;
        if (input.open_start_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closeStartMenu();
        if (input.open_power_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closePowerMenu();
        if (input.open_wifi) |other| other.output.closeWifi();
        if (input.open_battery) |other| other.output.closeBattery();
        if (input.open_calendar) |other| other.output.closeCalendar();
        if (server.tray) |tray| tray.closeMenu();
        const bounds = output.dockAreaBox();
        const width = @min(216, bounds.width);
        self.node = server.overlay_tree.createSceneBuffer(null) catch return;
        self.bar = bar;
        self.output = output;
        self.dock = dock;
        self.shortcut = shortcut;
        self.target = target;
        if (pin) |id| {
            self.pin_len = @min(id.len, self.pin_bytes.len);
            @memcpy(self.pin_bytes[0..self.pin_len], id[0..self.pin_len]);
            self.pinned = true;
        }
        const count: i32 = @intCast(self.actions().len);
        const height = padding * 2 + row_height * count + separator * (count - 1);
        var menu_x = x;
        var y = output.taskbarPopupY(height, 4);
        if (dock) |d| switch (d.position) {
            .top => y = d.box.y + d.box.height + 4,
            .bottom => y = d.box.y - height - 4,
            .left => {
                menu_x = d.box.x + d.box.width + 4;
                y = pointer_y;
            },
            .right => {
                menu_x = d.box.x - width - 4;
                y = pointer_y;
            },
        };
        self.box = .{
            .x = std.math.clamp(menu_x, bounds.x, bounds.x + bounds.width - width),
            .y = std.math.clamp(y, bounds.y, @max(bounds.y, bounds.y + bounds.height - height)),
            .width = width,
            .height = height,
        };
        if (bar) |b| b.pointerLeave();
        if (dock) |d| d.leave();
        input.hovered_taskbar = null;
        input.seat.pointerClearFocus();
        input.setDefaultCursor();
        input.pointer_constraints.sync();
        self.paint();
    }

    pub fn close(self: *Menu) void {
        if (self.node) |node| node.node.destroy();
        self.* = .{};
    }

    fn rowY(index: usize) i32 {
        return padding + @as(i32, @intCast(index)) * (row_height + separator);
    }

    fn hit(self: *const Menu, x: f64, y: f64) ?usize {
        const lx = x - @as(f64, @floatFromInt(self.box.x));
        const ly = y - @as(f64, @floatFromInt(self.box.y));
        if (lx < padding or lx >= @as(f64, @floatFromInt(self.box.width - padding))) return null;
        for (0..self.actions().len) |i| {
            const top: f64 = @floatFromInt(rowY(i));
            if (ly >= top and ly < top + row_height) return i;
        }
        return null;
    }

    pub fn motion(self: *Menu, x: f64, y: f64) void {
        const next = self.hit(x, y);
        if (self.selected == next) return;
        self.selected = next;
        self.paint();
    }

    pub fn press(self: *Menu, x: f64, y: f64, button: u32) void {
        if (x < @as(f64, @floatFromInt(self.box.x)) or x >= @as(f64, @floatFromInt(self.box.x + self.box.width)) or
            y < @as(f64, @floatFromInt(self.box.y)) or y >= @as(f64, @floatFromInt(self.box.y + self.box.height)))
        {
            self.close();
            return;
        }
        if (button != 0x110) return;
        self.selected = self.hit(x, y);
        self.activate();
    }

    pub fn key(self: *Menu, sym: u32) void {
        switch (sym) {
            0xff1b => self.close(), // Escape
            0xff0d, 0xff8d, 0x20 => self.activate(), // Return, keypad Enter, Space
            0xff52, 0xff54 => { // Up / Down skip the separator.
                const count = self.actions().len;
                self.selected = if (self.selected) |i| (i + if (sym == 0xff54) @as(usize, 1) else count - 1) % count else if (sym == 0xff54) 0 else count - 1;
                self.paint();
            },
            else => {},
        }
    }

    fn activate(self: *Menu) void {
        const index = self.selected orelse return;
        const action = self.actions()[index];
        const target = self.target;
        const dock = self.dock;
        const shortcut = self.shortcut;
        const pin_bytes = self.pin_bytes;
        const pin = pin_bytes[0..self.pin_len];
        // Shell windows can destroy themselves synchronously when closed.
        self.close();
        switch (action) {
            .close => if (target) |t| t.sendClose(),
            .force_close => if (target) |t| t.forceClose(),
            .remove => if (dock) |d| if (shortcut) |s| d.removeShortcut(s),
            .unpin => if (dock) |d| d.unpinApp(pin),
        }
    }

    fn paint(self: *Menu) void {
        const output = self.output orelse return;
        const node = self.node orelse return;
        const scale = output.wlr_output.scale;
        const buf = Buffer.create(self.box.width, self.box.height, scale) catch return;
        defer buf.base.drop();
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        const t = ui.theme.global;
        const width: f32 = @floatFromInt(self.box.width);
        renderer.fillRect(0, 0, width, @floatFromInt(self.box.height), .{ .color = t.window_bg, .radius = 12, .border_width = 1, .border_color = t.border });
        for (self.actions(), 0..) |action, i| {
            const y: f32 = @floatFromInt(rowY(i));
            if (i > 0) renderer.fillRect(12, y - 4, @max(0, width - 24), 1, .{ .color = t.border_soft });
            const row: ui.layout.Widget = .{
                .kind = .{ .row = .{ .state = if (self.selected == i) .hover else .idle } },
                .computed_x = padding,
                .computed_y = y,
                .computed_width = @max(0, width - 2 * padding),
                .computed_height = row_height,
            };
            ui.paint.paint(&row, &renderer);
            renderer.drawText(18, y, @max(0, width - 36), row_height, .{ .content = action.label(), .font_size = t.font_size, .color = if (action == .force_close) t.danger else t.window_fg });
        }
        node.setBuffer(&buf.base);
        node.setDestSize(self.box.width, self.box.height);
        node.setFilterMode(.bilinear);
        node.node.setPosition(self.box.x, self.box.y);
        node.node.raiseToTop();
    }
};
