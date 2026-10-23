//! Pointer and keyboard input, pasting and find.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const input = @import("ui").input;
const a = std.heap.c_allocator;
const app_mod = @import("app.zig");
const App = app_mod.App;
const top = app_mod.top;
const status_h = app_mod.status_h;
const tab_w = app_mod.tab_w;
const labels = app_mod.labels;

/// The byte offset nearest a point given relative to the text origin.
pub fn indexAt(self: *App, x: f64, y: f64) usize {
    return self.port().indexAt(x, y);
}

pub fn handleMotion(self: *App, x: f64, y: f64) void {
    const changed_hover = ((self.py < top or y < top) and @divFloor(self.px, 76) != @divFloor(x, 76)) or (self.py < top) != (y < top);
    self.px = x;
    self.py = y;
    if (self.menu_open) {
        const hovered = self.menuHit(x, y);
        if (hovered != self.menu_selected) {
            self.menu_selected = hovered;
            self.dirty = true;
        }
        return;
    }
    if (self.dragging) {
        const t = self.current();
        if (y < self.viewTop()) self.port().scrollBy(-18) else if (y > self.viewTop() + self.viewHeight()) self.port().scrollBy(18);
        const pos = self.indexAt(x - 16 + t.scroll_x, y - self.viewTop());
        if (self.drag_word) |initial| {
            const range = t.doc.wordRange(self.port().characterAt(x - 16 + t.scroll_x, y - self.viewTop()));
            const backwards = pos < initial[0];
            t.doc.anchor = if (backwards) initial[1] else initial[0];
            t.doc.cursor = if (backwards) range[0] else @max(initial[1], range[1]);
        } else t.doc.move(pos, true);
        self.changed();
    }
    if (self.scroll_drag.active) {
        if (self.scrollbarGeometry()) |bar| self.seekScroll(self.scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y)));
        self.dirty = true;
    }
    if (changed_hover) self.dirty = true;
}

pub fn handleButton(self: *App, code: u32, pressed: bool) void {
    if (code != 0x110) return;
    if (pressed) self.caret_activity +%= 1;
    if (!pressed) {
        self.cancelDrag();
        return;
    }
    const last_click = self.last_text_click;
    self.last_text_click = null;
    self.caret_snap = true;
    if (self.close_tab != null) {
        const x = (@as(f64, @floatFromInt(self.w)) - 420) / 2;
        const y = (@as(f64, @floatFromInt(self.h)) - 170) / 2;
        if (self.py >= y + 112 and self.py <= y + 150 and self.operation == null) {
            if (self.px >= x + 20 and self.px < x + 135) {
                self.close_tab = null;
                self.close_all = false;
            } else if (self.px >= x + 145 and self.px < x + 270) self.finishClose() else if (self.px >= x + 280 and self.px < x + 400) self.save(false);
            self.dirty = true;
        }
        return;
    }
    if (self.menu_open) {
        const row = self.menuHit(self.px, self.py);
        self.dismissMenu();
        if (row) |i| self.act(@enumFromInt(i));
        return;
    }
    if (self.py < 0) return;
    if (self.py < top) {
        if (!self.has_titlebar and self.px >= @as(f64, @floatFromInt(self.w)) - 34) {
            self.toggleMenu(@as(f64, @floatFromInt(self.w)) - 8);
            return;
        }
        if (self.px >= self.tabRight()) {
            self.act(.new);
            return;
        }
        const i = self.first_tab + @as(usize, @intFromFloat(@max(0, self.px) / tab_w));
        if (i < self.tabs.items.len) {
            self.selected = i;
            self.changed();
            if (@mod(self.px, tab_w) > tab_w - 28) self.closeSelected();
        }
    } else if (self.find_open and self.py < self.viewTop()) {
        if (self.px > @as(f64, @floatFromInt(self.w)) - 90) self.findNext(self.shift);
    } else if (self.py < @as(f64, @floatFromInt(self.h)) - status_h) {
        if (self.px > @as(f64, @floatFromInt(self.w)) - scrollbar.gutter(theme.global.scrollbar_width)) {
            if (self.scrollbarGeometry()) |bar| {
                const scroll = self.scrollOffset();
                if (scrollbar.press(bar, @floatCast(self.px), @floatCast(self.py), scroll)) |action| {
                    switch (action) {
                        .grab => self.scroll_drag.begin(bar, @floatCast(self.px), @floatCast(self.py), scroll),
                        .page => |offset| self.seekScroll(offset),
                    }
                    self.dirty = true;
                }
            }
            return;
        }
        self.find_open = false;
        const t = self.current();
        const pos = self.indexAt(self.px - 16 + t.scroll_x, self.py - self.viewTop());
        const now = @import("ui").key_repeat.nowMs();
        const double = if (last_click) |last| last.tab == t.id and now - last.time <= input.multi_click_ms and
            @abs(self.px - last.x) <= input.multi_click_slop and @abs(self.py - last.y) <= input.multi_click_slop else false;
        if (double and !self.shift) {
            const range = t.doc.wordRange(self.port().characterAt(self.px - 16 + t.scroll_x, self.py - self.viewTop()));
            t.doc.anchor = range[0];
            t.doc.cursor = range[1];
            self.drag_word = range;
        } else {
            t.doc.move(pos, self.shift);
            self.last_text_click = .{ .time = now, .x = self.px, .y = self.py, .tab = t.id };
        }
        self.dragging = true;
        self.changed();
    }
}

pub fn pasteText(self: *App, bytes: []const u8) void {
    self.caret_activity +%= 1;
    if (self.close_tab != null or self.menu_open) return;
    if (self.find_open) {
        self.query.insert(a, bytes) catch |err| self.failure(err);
        self.dirty = true;
        return;
    }
    self.document().insert(bytes) catch |err| {
        self.failure(err);
        return;
    };
    self.notice_len = 0;
    self.reveal();
}

pub fn findNext(self: *App, backwards: bool) void {
    const q = self.query.text.items;
    if (q.len == 0) return;
    const d = self.document();
    const sel = d.selection();
    const found = if (backwards) std.mem.lastIndexOf(u8, d.text.items[0..sel[0]], q) orelse std.mem.lastIndexOf(u8, d.text.items, q) else std.mem.indexOfPos(u8, d.text.items, sel[1], q) orelse std.mem.indexOf(u8, d.text.items, q);
    if (found) |pos| {
        d.anchor = pos;
        d.cursor = pos + q.len;
        self.reveal();
    } else self.message(tr("Text not found"));
}

pub fn keyRepeats(self: *App, sym: u32, utf8: []const u8) bool {
    if (self.close_tab != null or self.menu_open or self.alt) return false;
    if (self.ctrl) return switch (sym) {
        c.XKB_KEY_Left, c.XKB_KEY_Right, c.XKB_KEY_BackSpace, c.XKB_KEY_Delete => !self.find_open,
        else => false,
    };
    if (!self.find_open) switch (sym) {
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_Tab, c.XKB_KEY_Home, c.XKB_KEY_End, c.XKB_KEY_Page_Up, c.XKB_KEY_Page_Down => return true,
        else => {},
    };
    return @import("ui").key_repeat.editingKey(switch (sym) {
        c.XKB_KEY_Left, c.XKB_KEY_Right, c.XKB_KEY_Up, c.XKB_KEY_Down, c.XKB_KEY_BackSpace, c.XKB_KEY_Delete => true,
        else => false,
    }, utf8);
}

pub fn handleKey(self: *App, sym: u32, utf8: []const u8) void {
    self.caret_activity +%= 1;
    self.last_text_click = null;
    if (self.close_tab != null) {
        if (sym == c.XKB_KEY_Escape and self.operation == null) {
            self.close_tab = null;
            self.close_all = false;
            self.dirty = true;
        }
        if (self.operation == null) {
            if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab or sym == c.XKB_KEY_Left or sym == c.XKB_KEY_Right) {
                self.close_choice = (self.close_choice + @as(usize, if (self.shift or sym == c.XKB_KEY_Left) 2 else 1)) % 3;
                self.dirty = true;
            }
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) switch (self.close_choice) {
                0 => {
                    self.close_tab = null;
                    self.close_all = false;
                    self.dirty = true;
                },
                1 => self.finishClose(),
                else => self.save(false),
            };
        }
        return;
    }
    if (sym == c.XKB_KEY_F10 and !self.ctrl and !self.alt) {
        self.toggleMenu(self.menu_anchor);
        return;
    }
    if (self.menu_open) {
        switch (sym) {
            c.XKB_KEY_Escape => self.dismissMenu(),
            c.XKB_KEY_Down => self.menu_selected = if (self.menu_selected) |i| (i + 1) % labels.len else 0,
            c.XKB_KEY_Up => self.menu_selected = if (self.menu_selected) |i| (i + labels.len - 1) % labels.len else labels.len - 1,
            c.XKB_KEY_Home => self.menu_selected = 0,
            c.XKB_KEY_End => self.menu_selected = labels.len - 1,
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_space => if (self.menu_selected) |i| {
                self.dismissMenu();
                self.act(@enumFromInt(i));
            },
            else => {},
        }
        self.dirty = true;
        if (!self.ctrl) return;
        self.dismissMenu();
    }
    if (self.ctrl) switch (sym) {
        c.XKB_KEY_n, c.XKB_KEY_N, c.XKB_KEY_t, c.XKB_KEY_T => {
            self.act(.new);
            return;
        },
        c.XKB_KEY_o, c.XKB_KEY_O => {
            self.act(.open);
            return;
        },
        c.XKB_KEY_s, c.XKB_KEY_S => {
            self.save(self.shift);
            return;
        },
        c.XKB_KEY_w, c.XKB_KEY_W => {
            self.closeSelected();
            return;
        },
        c.XKB_KEY_q, c.XKB_KEY_Q => {
            self.requestClose();
            return;
        },
        c.XKB_KEY_f, c.XKB_KEY_F => {
            self.find_open = true;
            self.query.select_all = true;
            self.dirty = true;
            return;
        },
        c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab, c.XKB_KEY_Page_Up, c.XKB_KEY_Page_Down => {
            self.selected = if (self.shift or sym == c.XKB_KEY_Page_Up) (self.selected + self.tabs.items.len - 1) % self.tabs.items.len else (self.selected + 1) % self.tabs.items.len;
            self.changed();
            return;
        },
        else => {},
    };
    if (sym == c.XKB_KEY_Escape) {
        self.find_open = false;
        self.notice_len = 0;
        self.dirty = true;
        return;
    }
    if (self.find_open) {
        if (sym == c.XKB_KEY_Return) self.findNext(self.shift) else if (self.ctrl and (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V)) self.paste_requested = true else self.query.key(a, sym, utf8, self.ctrl, self.shift, self.alt);
        self.dirty = true;
        return;
    }
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
