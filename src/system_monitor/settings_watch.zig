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
        for ([_]?[:0]const u8{ self.settings.config_path, self.settings.theme_path }) |maybe_path| {
            var parent = std.fs.path.dirname(maybe_path orelse continue) orelse continue;
            while (true) {
                var buf: [4096]u8 = undefined;
                const path = std.fmt.bufPrintZ(&buf, "{s}", .{parent}) catch break;
                if (c.inotify_add_watch(self.fd, path, c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_CREATE | c.IN_DELETE | c.IN_DELETE_SELF | c.IN_MOVE_SELF) >= 0) break;
                parent = std.fs.path.dirname(parent) orelse break;
            }
        }
    }
    fn apply(self: *Watch) bool {
        self.settings.last_second = -1;
        if (self.settings.poll(a, self.io)) |update| {
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
