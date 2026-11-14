//! Document keyboard edits and clipboard shortcuts.
const std = @import("std");
const c = @import("../files/c.zig").api;
const tr = @import("i18n").tr;
const App = @import("app.zig").App;
const a = std.heap.c_allocator;

pub fn editKey(self: *App, sym: u32, utf8: []const u8) void {
    const d = self.document();
    const sel = d.selection();
    if (self.ctrl) switch (sym) {
        c.XKB_KEY_a, c.XKB_KEY_A => {
            d.anchor = 0;
            d.cursor = d.text.items.len;
            self.reveal();
            return;
        },
        c.XKB_KEY_c, c.XKB_KEY_C, c.XKB_KEY_x, c.XKB_KEY_X => {
            if (sel[0] == sel[1]) return;
            if (sel[1] - sel[0] > @import("../files/transfer.zig").limit) {
                self.message(tr("Clipboard selections are limited to 1 MiB."));
                return;
            }
            self.clipboard.clearRetainingCapacity();
            self.clipboard.appendSlice(a, d.text.items[sel[0]..sel[1]]) catch return;
            self.clipboard_revision += 1;
            if (sym == c.XKB_KEY_x or sym == c.XKB_KEY_X) {
                d.insert("") catch |err| self.failure(err);
                self.reveal();
            }
            return;
        },
        c.XKB_KEY_v, c.XKB_KEY_V => {
            self.paste_requested = true;
            return;
        },
        c.XKB_KEY_z, c.XKB_KEY_Z, c.XKB_KEY_y, c.XKB_KEY_Y => {
            d.undo(self.shift or sym == c.XKB_KEY_y or sym == c.XKB_KEY_Y) catch |err| self.failure(err);
            self.reveal();
            return;
        },
        else => {},
    };
    switch (sym) {
        c.XKB_KEY_Left, c.XKB_KEY_Right => {
            const right = sym == c.XKB_KEY_Right;
            d.move(if (!self.shift and !self.ctrl and sel[0] != sel[1]) (if (right) sel[1] else sel[0]) else d.boundary(right, self.ctrl), self.shift);
        },
        c.XKB_KEY_Home => d.move(if (self.ctrl) 0 else d.lineStart(d.cursor), self.shift),
        c.XKB_KEY_End => d.move(if (self.ctrl) d.text.items.len else d.lineEnd(d.cursor), self.shift),
        c.XKB_KEY_Up, c.XKB_KEY_Down, c.XKB_KEY_Page_Up, c.XKB_KEY_Page_Down => {
            const r = self.caretRectNear();
            const down = sym == c.XKB_KEY_Down or sym == c.XKB_KEY_Page_Down;
            const distance = if (sym == c.XKB_KEY_Page_Up or sym == c.XKB_KEY_Page_Down) self.viewHeight() else @as(f64, @floatFromInt(r.height)) / 1024;
            d.move(self.indexAt(@as(f64, @floatFromInt(r.x)) / 1024, @as(f64, @floatFromInt(r.y)) / 1024 + @as(f64, @floatFromInt(r.height)) / 2048 + (if (down) distance else -distance)), self.shift);
        },
        c.XKB_KEY_BackSpace, c.XKB_KEY_Delete => {
            if (sel[0] == sel[1]) d.anchor = d.boundary(sym == c.XKB_KEY_Delete, self.ctrl);
            d.insert("") catch |err| self.failure(err);
        },
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
            if (!self.ctrl and !self.alt) d.insert(if (d.crlf) "\r\n" else "\n") catch |err| self.failure(err);
        },
        c.XKB_KEY_Tab => {
            if (!self.ctrl and !self.alt) d.insert("\t") catch |err| self.failure(err);
        },
        c.XKB_KEY_F3 => self.findNext(self.shift),
        else => {
            if (!self.ctrl and !self.alt and utf8.len > 0 and utf8[0] >= 32) d.insert(utf8) catch |err| self.failure(err);
        },
    }
    self.reveal();
}
