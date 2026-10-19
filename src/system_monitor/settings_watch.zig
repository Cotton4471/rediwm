//! Theme changes wake the UI through inotify, including while sampling is
//! paused or suspended. Watch parent directories so atomic saves work too.
const std = @import("std");
const c = @import("../files/c.zig").api;
const settings = @import("../files/settings.zig");
const a = std.heap.c_allocator;
pub const Watch = struct {
    fd: c_int,
    settings: settings.Settings,
    io: std.Io,
    pub fn init(io: std.Io, env: std.process.Environ) !Watch {
        const fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
        if (fd < 0) return error.ThemeWatchFailed;
        errdefer _ = c.close(fd);
        var self: Watch = .{ .fd = fd, .settings = try settings.Settings.init(a, env), .io = io };
        self.arm();
        _ = self.apply();
        return self;
    }
    pub fn deinit(self: *Watch) void {
        self.settings.deinit(a);
        _ = c.close(self.fd);
    }
    fn arm(self: *Watch) void {
        self.settings.watch(self.fd);
    }
    fn apply(self: *Watch) bool {
        if (self.settings.reload(a, self.io)) |update| {
            update.apply();
            @import("ui").anim.applySettings(self.settings.animations);
            return true;
        }
        return false;
    }
    pub fn poll(self: *Watch) bool {
        var buf: [8192]u8 = undefined;
        var changed = false;
        while (c.read(self.fd, &buf, buf.len) > 0) changed = true;
        if (!changed) return false;
        self.arm();
        return self.apply();
    }
};
