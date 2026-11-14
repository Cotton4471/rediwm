//! Adapter for the private native libcups worker. The validated helper-shaped
//! arguments are an internal command format, not a D-Bus dependency.
const std = @import("std");
const wire = @import("dbus").wire;
const wl = @import("wayland").server.wl;
const a = std.heap.c_allocator;
const Native = opaque {};
extern fn rediwm_cups_create() ?*Native;
extern fn rediwm_cups_destroy(*Native) void;
extern fn rediwm_cups_fd(*Native) c_int;
extern fn rediwm_cups_submit(*Native, [*:0]const u8, c_int, [*]const [*:0]const u8, c_int) c_int;
extern fn rediwm_cups_state(*Native) c_int;
extern fn rediwm_cups_result(*Native) c_int;
extern fn rediwm_cups_device(*Native, c_int, c_int) ?[*:0]const u8;
extern fn rediwm_cups_credentials(*Native, [*:0]const u8, [*]const u8, c_ulong) void;
extern fn rediwm_cups_cancel(*Native) void;
extern fn rediwm_cups_finish(*Native) void;
extern "c" fn read(c_int, *anyopaque, usize) isize;

pub const Worker = struct {
    native: *Native,
    source: *wl.EventSource,
    owner: *anyopaque,
    callback: *const fn (*anyopaque) void,
    discovery: bool = false,

    pub fn create(loop: *wl.EventLoop, owner: *anyopaque, callback: *const fn (*anyopaque) void) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        const native = rediwm_cups_create() orelse return error.WorkerFailed;
        errdefer rediwm_cups_destroy(native);
        self.* = .{ .native = native, .source = undefined, .owner = owner, .callback = callback };
        self.source = try loop.addFd(*Worker, rediwm_cups_fd(native), .{ .readable = true }, ready, self);
        return self;
    }
    pub fn destroy(self: *Worker) void {
        self.source.remove();
        rediwm_cups_destroy(self.native);
        a.destroy(self);
    }
    fn ready(fd: c_int, _: wl.EventMask, self: *Worker) c_int {
        var value: u64 = 0;
        _ = read(fd, &value, @sizeOf(u64));
        self.callback(self.owner);
        return 0;
    }
    pub fn state(self: *Worker) c_int {
        return rediwm_cups_state(self.native);
    }
    pub fn result(self: *Worker) c_int {
        return rediwm_cups_result(self.native);
    }
    pub fn cancel(self: *Worker) void {
        rediwm_cups_cancel(self.native);
    }
    pub fn finish(self: *Worker) void {
        rediwm_cups_finish(self.native);
    }
    pub fn credentials(self: *Worker, user: []const u8, password: []const u8) !void {
        if (user.len == 0 or user.len > 255 or password.len >= 4096) return error.InvalidCredentials;
        for (user) |ch| if (ch < 0x21 or ch == 0x7f) return error.InvalidCredentials;
        if (std.mem.indexOfScalar(u8, password, 0) != null) return error.InvalidCredentials;
        const name = try a.dupeSentinel(u8, user, 0);
        defer a.free(name);
        rediwm_cups_credentials(self.native, name, password.ptr, password.len);
    }
    pub fn submit(self: *Worker, method: []const u8, signature: []const u8, bytes: []const u8, reset: bool) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const mem = arena.allocator();
        var args: std.ArrayList([*:0]const u8) = .empty;
        var reader: wire.Reader = .{ .bytes = bytes };
        self.discovery = std.mem.eql(u8, method, "DevicesGet");
        if (!self.discovery) {
            var i: usize = 0;
            while (i < signature.len) : (i += 1) switch (signature[i]) {
                's' => try args.append(mem, try mem.dupeSentinel(u8, try reader.string(), 0)),
                'b' => try args.append(mem, if (try reader.boolean()) "true" else "false"),
                'a' => {
                    i += 1;
                    if (i >= signature.len or signature[i] != 's') return error.InvalidSignature;
                    var values = try reader.array(4);
                    while (values.offset < values.bytes.len) try args.append(mem, try mem.dupeSentinel(u8, try values.string(), 0));
                },
                else => return error.InvalidSignature,
            };
            try reader.done();
        }
        if (rediwm_cups_submit(self.native, try mem.dupeSentinel(u8, method, 0), @intCast(args.items.len), args.items.ptr, @intFromBool(reset)) != 0) return error.OutOfMemory;
    }
    pub fn devices(self: *Worker, writer: *wire.Writer) !void {
        const dict = try writer.beginArray(8);
        const names = [_][]const u8{ "device-uri", "device-info", "device-make-and-model", "device-id", "device-class" };
        for (0..128) |i| {
            if (rediwm_cups_device(self.native, @intCast(i), 0) == null) break;
            for (names, 0..) |name, j| {
                const value = rediwm_cups_device(self.native, @intCast(i), @intCast(j)) orelse return error.InvalidReply;
                var key: [64]u8 = undefined;
                try writer.alignTo(8);
                try writer.string(try std.fmt.bufPrint(&key, "{s}:{d}", .{ name, i }));
                try writer.string(std.mem.span(value));
            }
        }
        try writer.endArray(dict);
    }
};
