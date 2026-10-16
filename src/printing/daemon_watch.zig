//! Socket-directory events complement CUPS subscriptions: a daemon can vanish
//! before sending an IPP notification. This watcher never opens the socket.
const std = @import("std");
const endpoint = @import("endpoint.zig");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("sys/inotify.h");
    @cInclude("unistd.h");
});
const A = std.mem.Allocator;

pub const Watch = struct {
    fd: c_int,
    basename: []u8,
    watch: c_int,

    /// No watcher is needed for a remote server. Missing/inaccessible parent
    /// directories retain explicit refresh rather than starting a retry timer.
    pub fn init(a: A, server: []const u8) !?Watch {
        const target = try endpoint.parseServer(server);
        const socket = target.unix orelse return null;
        const parent = std.fs.path.dirname(socket) orelse return null;
        const name = std.fs.path.basename(socket);
        if (name.len == 0 or std.mem.eql(u8, name, "/")) return null;
        const basename = try a.dupe(u8, name);
        errdefer a.free(basename);
        const directory = try a.dupeZ(u8, parent);
        defer a.free(directory);
        const fd = c.inotify_init1(c.IN_CLOEXEC | c.IN_NONBLOCK);
        if (fd < 0) {
            a.free(basename);
            return null;
        }
        const watch = c.inotify_add_watch(fd, directory, c.IN_CREATE | c.IN_DELETE | c.IN_MOVED_TO | c.IN_MOVED_FROM | c.IN_ATTRIB | c.IN_DELETE_SELF | c.IN_MOVE_SELF | c.IN_UNMOUNT);
        if (watch < 0) {
            _ = c.close(fd);
            a.free(basename);
            return null;
        }
        return .{ .fd = fd, .basename = basename, .watch = watch };
    }

    pub fn deinit(self: *Watch, a: A) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        a.free(self.basename);
        self.* = undefined;
    }

    /// Drain a bounded burst, coalescing all relevant events into one reload.
    /// Invalidated watches close immediately so poll cannot spin on an error.
    pub fn changed(self: *Watch) bool {
        if (self.fd < 0) return false;
        var changed_socket = false;
        var reads: usize = 0;
        while (reads < 8) : (reads += 1) {
            var bytes: [8192]u8 = undefined;
            const n = c.read(self.fd, &bytes, bytes.len);
            if (n < 0) {
                const err = std.posix.errno(n);
                if (err == .INTR) continue;
                if (err == .AGAIN) return changed_socket;
                self.close();
                return true;
            }
            if (n == 0) {
                self.close();
                return true;
            }
            var offset: usize = 0;
            const data = bytes[0..@intCast(n)];
            while (data.len - offset >= @sizeOf(c.struct_inotify_event)) {
                const event = std.mem.bytesToValue(c.struct_inotify_event, data[offset..][0..@sizeOf(c.struct_inotify_event)]);
                offset += @sizeOf(c.struct_inotify_event);
                if (event.len > data.len - offset) {
                    self.close();
                    return true;
                }
                if (event.mask & c.IN_Q_OVERFLOW != 0) changed_socket = true;
                if (event.wd == self.watch) {
                    if (event.mask & (c.IN_IGNORED | c.IN_DELETE_SELF | c.IN_MOVE_SELF | c.IN_UNMOUNT) != 0) {
                        self.close();
                        return true;
                    }
                    const name = std.mem.sliceTo(data[offset..][0..event.len], 0);
                    if (std.mem.eql(u8, name, self.basename)) changed_socket = true;
                }
                offset += event.len;
            }
            if (offset != data.len) {
                self.close();
                return true;
            }
        }
        return changed_socket;
    }

    fn close(self: *Watch) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

test "CUPS socket watcher coalesces exact-name create, rename, delete and parent loss" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(root);
    const socket = try std.fs.path.join(t.allocator, &.{ root, "cups.sock" });
    defer t.allocator.free(socket);
    var watcher = (try Watch.init(t.allocator, socket)).?;
    defer watcher.deinit(t.allocator);
    try t.expect(!watcher.changed());
    try tmp.dir.writeFile(io, .{ .sub_path = "unrelated", .data = "" });
    try t.expect(!watcher.changed());
    try tmp.dir.writeFile(io, .{ .sub_path = "cups.sock", .data = "" });
    try t.expect(watcher.changed());
    try t.expect(!watcher.changed());
    try tmp.dir.rename("cups.sock", tmp.dir, "old.sock", io);
    try t.expect(watcher.changed());
    try tmp.dir.rename("old.sock", tmp.dir, "cups.sock", io);
    try t.expect(watcher.changed());
    try tmp.dir.deleteFile(io, "cups.sock");
    try t.expect(watcher.changed());
    // Moving a watched directory invalidates this watcher; it closes the fd
    // and subsequent calls remain inert until the owner creates a new one.
    const moved = try std.fmt.allocPrint(t.allocator, "{s}-moved", .{root});
    defer t.allocator.free(moved);
    try std.Io.Dir.cwd().rename(root, .cwd(), moved, io);
    defer std.Io.Dir.cwd().rename(moved, .cwd(), root, io) catch {};
    try t.expect(watcher.changed());
    try t.expectEqual(@as(c_int, -1), watcher.fd);
    try t.expect(!watcher.changed());
}

test "CUPS socket watcher is absent for remote or unavailable parents" {
    const t = std.testing;
    try t.expectEqual(@as(?Watch, null), try Watch.init(t.allocator, "printer.example:631"));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const socket = try std.fs.path.join(t.allocator, &.{ root, "missing", "cups.sock" });
    defer t.allocator.free(socket);
    try t.expectEqual(@as(?Watch, null), try Watch.init(t.allocator, socket));
}
