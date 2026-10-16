//! text-input-v3 for terminal input. Terminal output is never surrounding
//! editable text: commits go to the PTY and preedit stays local until done.
const std = @import("std");
const wl = @import("wayland").client.wl;
const zwp = @import("wayland").client.zwp;
const App = @import("../app.zig").App;
const tc = @import("model.zig").c;
pub const Ime = struct {
    app: *App,
    manager: ?*zwp.TextInputManagerV3 = null,
    input: ?*zwp.TextInputV3 = null,
    entered: bool = false,
    enabled: bool = false,
    serial: u32 = 0,
    revision: usize = 0,
    session: ?*tc.FT = null,
    rectangle: [4]i32 = @splat(0),
    commit_text: std.ArrayList(u8) = .empty,
    preedit_text: std.ArrayList(u8) = .empty,
    has_preedit: bool = false,
    invalid: bool = false,

    pub fn setup(self: *Ime, seat: *wl.Seat) !void {
        if (self.manager) |manager| {
            self.input = try manager.getTextInput(seat);
            self.input.?.setListener(*Ime, event, self);
        }
    }
    pub fn deinit(self: *Ime) void {
        if (self.input) |input| input.destroy();
        if (self.manager) |manager| manager.destroy();
        self.commit_text.deinit(self.app.allocator);
        self.preedit_text.deinit(self.app.allocator);
    }
    fn clear(self: *Ime) void {
        self.commit_text.clearRetainingCapacity();
        self.preedit_text.clearRetainingCapacity();
        self.has_preedit = false;
        self.invalid = false;
    }
    fn event(_: *zwp.TextInputV3, ev: zwp.TextInputV3.Event, self: *Ime) void {
        switch (ev) {
            .enter => self.entered = true,
            .leave => {
                self.entered = false;
                self.enabled = false;
                self.clear();
                self.app.terminal.preedit.clearRetainingCapacity();
                self.app.terminalDamage();
            },
            .preedit_string => |e| {
                self.preedit_text.clearRetainingCapacity();
                self.has_preedit = true;
                if (e.text) |s| {
                    const bytes = std.mem.span(s);
                    if (bytes.len <= 4096 and std.unicode.utf8ValidateSlice(bytes)) self.preedit_text.appendSlice(self.app.allocator, bytes) catch {} else self.invalid = true;
                }
            },
            .commit_string => |e| {
                if (e.text) |s| {
                    const bytes = std.mem.span(s);
                    if (bytes.len + self.commit_text.items.len <= 4096 and std.unicode.utf8ValidateSlice(bytes)) self.commit_text.appendSlice(self.app.allocator, bytes) catch {} else self.invalid = true;
                }
            },
            .delete_surrounding_text => |e| {
                if (e.before_length != 0 or e.after_length != 0) self.invalid = true;
            },
            .done => |e| {
                defer self.clear();
                if (self.invalid or e.serial != self.serial or !self.enabled or self.app.dialog != null or self.app.menu != null or self.app.focus != .terminal or !self.app.terminal.visible or self.session != self.app.terminal.session or self.revision != self.app.edit_revision) return;
                if (self.commit_text.items.len > 0) {
                    // An IME commit is typed text, never paste or shell syntax.
                    if (self.session) |session| tc.ft_key(session, 0, self.commit_text.items.ptr, self.commit_text.items.len, 0);
                }
                self.app.terminal.preedit.clearRetainingCapacity();
                if (self.has_preedit) self.app.terminal.preedit.appendSlice(self.app.allocator, self.preedit_text.items) catch {};
                self.app.terminalDamage();
            },
        }
    }
    pub fn sync(self: *Ime, titlebar: i32) void {
        const input = self.input orelse return;
        const enabled = self.entered and self.app.focus == .terminal and self.app.terminal.visible and self.app.dialog == null and self.app.menu == null and self.app.terminal.session != null;
        if (!enabled) {
            if (self.enabled) {
                input.disable();
                input.commit();
                self.serial +%= 1;
                self.clear();
                self.app.terminal.preedit.clearRetainingCapacity();
                self.app.terminalDamage();
            }
            self.enabled = false;
            return;
        }
        const session = self.app.terminal.session.?;
        var row: c_int = 0;
        var col: c_int = 0;
        var shape: c_int = 0;
        _ = tc.ft_cursor(session, &row, &col, &shape);
        const body = self.app.terminalBody();
        const rect: [4]i32 = .{ @intFromFloat(body.x + @as(f64, @floatFromInt(col)) * self.app.terminal.cell_w), @as(i32, @intFromFloat(body.y + @as(f64, @floatFromInt(row)) * self.app.terminal.cell_h)) + titlebar, @intFromFloat(self.app.terminal.cell_w), @intFromFloat(self.app.terminal.cell_h) };
        if (self.enabled and self.session == session and self.revision == self.app.edit_revision and std.meta.eql(rect, self.rectangle)) return;
        if (!self.enabled or self.session != session) {
            input.enable();
            self.clear();
        }
        self.enabled = true;
        self.revision = self.app.edit_revision;
        self.session = session;
        self.rectangle = rect;
        input.setSurroundingText("", 0, 0);
        input.setContentType(.{ .multiline = true }, .terminal);
        input.setCursorRectangle(rect[0], rect[1], @max(1, rect[2]), @max(1, rect[3]));
        input.commit();
        self.serial +%= 1;
    }
};
