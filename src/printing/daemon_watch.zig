//! Socket-directory events complement CUPS subscriptions: a daemon can vanish
//! before sending an IPP notification. This watcher never opens the socket.
const std = @import("std");
const platform = @import("platform");
const endpoint = @import("endpoint.zig");
const A = std.mem.Allocator;

pub const Watch = struct {
    watcher: platform.watch.Watcher,
    basename: []u8,
    watch: platform.watch.Watch,

    /// No watcher is needed for a remote server. Missing/inaccessible parent
    /// directories retain explicit refresh rather than starting a retry timer.
    pub fn init(a: A, server: []const u8) !?Watch {
        const target = try endpoint.parseServer(server);
        const socket = target.unix orelse return null;
        const parent = std.fs.path.dirname(socket) orelse return null;
        const name = std.fs.path.basename(socket);
        if (name.len == 0 or std.mem.eql(u8, name, "/")) return null;
        var watcher = platform.watch.Watcher.init() catch return null;
        const watch = watcher.add(parent, .{ .created = true, .deleted = true, .moved_to = true, .moved_from = true, .attrib = true }) orelse {
            watcher.deinit();
            return null;
        };
        const basename = a.dupe(u8, name) catch |err| {
            watcher.deinit();
            return err;
        };
        return .{ .watcher = watcher, .basename = basename, .watch = watch };
    }

    pub fn deinit(self: *Watch, a: A) void {
        self.watcher.deinit();
        a.free(self.basename);
        self.* = undefined;
    }

    /// The descriptor to poll; negative once the watch has been invalidated.
    pub fn fd(self: Watch) c_int {
        return self.watcher.fd;
    }

    const Scan = struct {
        watch: platform.watch.Watch,
        basename: []const u8,
        changed: bool = false,
        lost: bool = false,

        fn event(self: *Scan, ev: platform.watch.Event) void {
            if (ev.flags.overflow) self.changed = true;
            if (ev.watch != self.watch) return;
            if (ev.flags.lost()) {
                self.lost = true;
            } else if (std.mem.eql(u8, ev.name, self.basename)) {
                self.changed = true;
            }
        }
    };

    /// Drain a bounded burst, coalescing all relevant events into one reload.
    /// Invalidated watches close immediately so poll cannot spin on an error.
    pub fn changed(self: *Watch) bool {
        if (self.watcher.fd < 0) return false;
        var scan: Scan = .{ .watch = self.watch, .basename = self.basename };
        self.watcher.drainBounded(&scan, Scan.event, 8) catch {
            scan.lost = true;
        };
        if (scan.lost) {
            self.watcher.deinit();
            return true;
        }
        return scan.changed;
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
    try t.expectEqual(@as(c_int, -1), watcher.fd());
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
