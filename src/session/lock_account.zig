//! Accounts: the shown account, its login appearance and avatar, status text and greeter events.

const i18n = @import("i18n");
const std = @import("std");
const Server = @import("../Server.zig");
const gpa = @import("../main.zig").gpa;
const ui = @import("ui");
const text = @import("ui").text;
const png = @import("../png.zig");
const anim = @import("ui").anim;
const greeter_mod = @import("greeter.zig");
const login_appearance = @import("login_appearance.zig");
const ImageBuffer = @import("../ImageBuffer.zig");
const Lock = @import("lock.zig").Lock;

/// Greeter: shows the selected account's name and picture.
pub fn showAccount(self: *Lock) void {
    const greeter = self.greeter orelse return;
    self.applyAccountAppearance(if (greeter.selectedUser()) |user| user.uid else null);
    if (self.avatar) |avatar| avatar.deinit(gpa);
    self.avatar = null;
    @memset(&self.user, 0);
    @memset(&self.name, 0);
    const user = greeter.selectedUser() orelse return;
    const n = @min(user.name.len, self.user.len - 1);
    @memcpy(self.user[0..n], user.name[0..n]);
    const m = @min(user.real.len, self.name.len - 1);
    @memcpy(self.name[0..m], user.real[0..m]);
    // Home directories are usually private to their owner; AccountsService
    // pictures are the ones a greeter can normally read.
    self.loadAvatar(user.home);
}

pub fn applyAccountAppearance(self: *Lock, uid: ?u32) void {
    // Reset first: an account without a snapshot must not inherit the
    // preceding account's palette, fonts or wallpaper.
    self.clearAccountAppearance();
    if (uid) |id| if (self.greeter_appearance_root.len > 0) {
        self.greeter_appearance = login_appearance.load(gpa, self.greeter_appearance_root, id) catch null;
    };
    if (self.greeter_appearance) |*saved| {
        ui.theme.global = saved.tokens;
        if (saved.wallpaper) |image| {
            self.greeter_wallpaper = ImageBuffer.createFromDecoded(image) catch null;
            if (self.greeter_wallpaper != null) saved.wallpaper = null; // buffer owns pixels
        }
    }
    text.setPreferredFamilies(ui.theme.global.font, ui.theme.global.mono_font);
    self.themeChanged();
}

pub fn clearAccountAppearance(self: *Lock) void {
    ui.theme.global = self.greeter_default_theme;
    text.setPreferredFamilies(ui.theme.global.font, ui.theme.global.mono_font);
    if (self.greeter_wallpaper) |image| image.base.drop();
    self.greeter_wallpaper = null;
    if (self.greeter_appearance) |*saved| saved.deinit(gpa);
    self.greeter_appearance = null;
}

pub fn idleStatus(self: *const Lock) []const u8 {
    const greeter = self.greeter orelse return i18n.tr("Press Enter to unlock");
    if (greeter.users.len == 0) return i18n.tr("No user accounts found");
    if (greeter.sessions.len == 0) return i18n.tr("No sessions installed");
    return i18n.tr("Press Enter to log in");
}

pub fn busy(self: *const Lock) bool {
    if (self.greeter) |greeter| return greeter.busy();
    return self.auth != null;
}

pub fn prompting(self: *const Lock) bool {
    const greeter = self.greeter orelse return false;
    return greeter.phase == .prompting;
}

pub fn greeterEvent(owner: ?*anyopaque, event: greeter_mod.Event) void {
    const self: *Lock = @ptrCast(@alignCast(owner.?));
    switch (event) {
        .status => |message| self.status = message,
        .prompt => |p| {
            self.clear();
            self.status = p.text;
            self.reveal = p.visible;
            self.focus = 0;
        },
        .rejected => {
            self.status = i18n.tr("Incorrect password. Try again.");
            self.retry_at = anim.nowMs() + 1500;
        },
        .failed => |message| {
            self.status = message;
            self.retry_at = anim.nowMs() + 1500;
        },
        .started => {
            self.status = i18n.tr("Starting session…");
            std.log.info("greeter: rediwm-dm accepted the session; exiting", .{});
            // Out to black, as the session comes in from it.
            self.server.reveal.cover(self.server, Server.terminate);
        },
        .disconnected => {
            self.status = i18n.tr("Lost contact with login service. Try again.");
            std.log.info("greeter: lost the rediwm-dm connection; exiting so it starts a new greeter", .{});
            self.server.terminate();
        },
    }
    self.changed();
}

pub fn loadAvatar(self: *Lock, home: []const u8) void {
    var path: [4352]u8 = undefined;
    if (home.len > 0) for ([_][]const u8{ ".face", ".face.png" }) |file| {
        const p = std.fmt.bufPrint(&path, "{s}/{s}", .{ home, file }) catch continue;
        if (self.readAvatar(p)) return;
    };
    const p = std.fmt.bufPrint(&path, "/var/lib/AccountsService/icons/{s}", .{std.mem.sliceTo(&self.user, 0)}) catch return;
    _ = self.readAvatar(p);
}

pub fn readAvatar(self: *Lock, path: []const u8) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(self.server.io, path, gpa, .limited(4 * 1024 * 1024)) catch return false;
    defer gpa.free(bytes);
    // Bound decoded allocation as well as file size before using the PNG decoder.
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return false;
    if (std.mem.readInt(u32, bytes[16..20], .big) > 2048 or std.mem.readInt(u32, bytes[20..24], .big) > 2048) return false;
    self.avatar = png.decode(gpa, bytes) catch return false;
    return true;
}
