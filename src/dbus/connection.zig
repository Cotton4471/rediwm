//! Single-threaded Wayland-loop D-Bus connection. Opening authenticates with a
//! bounded startup wait; Hello and all subsequent messages are asynchronous.
//! No implicit connection to a host bus and no name is acquired automatically.
const std = @import("std");
const wl = @import("wayland").server.wl;
const c = std.posix.system;
const wire = @import("wire.zig");
const address = @import("address.zig");
const connection_calls = @import("connection_calls.zig");
const connection_io = @import("connection_io.zig");
const log = std.log.scoped(.dbus);
pub const bus_name = "org.freedesktop.DBus";
pub const bus_path = "/org/freedesktop/DBus";
pub const queue_limit = 8 * 1024 * 1024;
pub const pending_limit = 256;

pub const Connection = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    receive_fds: bool = false,
    read_fds: [16]c_int = undefined,
    read_fd_count: usize = 0,
    source: ?*wl.EventSource = null,
    timer: ?*wl.EventSource = null,
    read_buf: std.ArrayList(u8) = .empty,
    write_buf: std.ArrayList(u8) = .empty,
    write_offset: usize = 0,
    /// Set for connections carrying secrets, alongside a locked allocator.
    wipe_buffers: bool = false,
    pending: std.ArrayList(Pending) = .empty,
    handlers: std.ArrayList(Handler) = .empty,
    signals: std.ArrayList(SignalHandler) = .empty,
    next_serial: u32 = 1,
    unique_name: ?[]const u8 = null,
    closed: bool = false,
    hello_sent: bool = false,
    callback_depth: usize = 0,
    /// Invoked once on close, before destroy; may clean up consumer work but
    /// must not destroy this connection or recursively dispatch the loop.
    on_disconnect: ?struct { owner: ?*anyopaque, callback: *const fn (?*anyopaque) void } = null,

    pub const Failure = error{ Disconnected, Timeout, InvalidReply, OutOfMemory };
    /// Message, slices and received FDs are borrowed only during the callback.
    /// Duplicate an FD with CLOEXEC to retain it after dispatch.
    /// Callbacks may enqueue calls/replies or close, but must not destroy or
    /// recursively dispatch the event loop. Destroy after dispatch returns.
    pub const Callback = *const fn (?*anyopaque, *Connection, Failure!wire.Message) void;
    pub const Method = *const fn (?*anyopaque, *Connection, wire.Message) anyerror!void;
    /// Owned reply address, not a copy of the request body. Do not copy this
    /// value; release it before destroying its connection, even after close.
    pub const Deferred = struct {
        serial: u32,
        sender: []u8,
        connection: ?*Connection,
        no_reply: bool,
    };
    pub const Handler = struct { path: []const u8, interface: []const u8, member: []const u8, owner: ?*anyopaque = null, callback: Method };
    pub const Signal = *const fn (?*anyopaque, *Connection, wire.Message) anyerror!void;
    pub const SignalCallback = Signal;
    pub const SignalHandler = struct {
        sender: ?[]const u8 = null,
        path: ?[]const u8 = null,
        interface: ?[]const u8 = null,
        member: ?[]const u8 = null,
        owner: ?*anyopaque = null,
        callback: Signal,
    };
    const Pending = struct { serial: u32, deadline: i64, owner: ?*anyopaque, callback: Callback, hello: bool = false };

    pub fn openSession(allocator: std.mem.Allocator, loop: *wl.EventLoop, environ: std.process.Environ) !*Connection {
        return open(allocator, loop, environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoSessionBus);
    }
    /// `DBUS_SYSTEM_BUS_ADDRESS` overrides the well-known socket per the D-Bus
    /// spec; tests use this to point a consumer at a private bus instead of
    /// the host's real system bus.
    pub fn openSystem(allocator: std.mem.Allocator, loop: *wl.EventLoop, environ: std.process.Environ) !*Connection {
        return open(allocator, loop, environ.getPosix("DBUS_SYSTEM_BUS_ADDRESS") orelse "unix:path=/var/run/dbus/system_bus_socket");
    }
    /// Opt in to receiving UNIX_FDs; sending descriptors remains unsupported.
    pub fn openSystemWithFds(allocator: std.mem.Allocator, loop: *wl.EventLoop, environ: std.process.Environ) !*Connection {
        return openWithFds(allocator, loop, environ.getPosix("DBUS_SYSTEM_BUS_ADDRESS") orelse "unix:path=/var/run/dbus/system_bus_socket", true);
    }
    pub fn open(allocator: std.mem.Allocator, loop: *wl.EventLoop, addresses: []const u8) !*Connection {
        return openWithFds(allocator, loop, addresses, false);
    }
    fn openWithFds(allocator: std.mem.Allocator, loop: *wl.EventLoop, addresses: []const u8, receive_fds: bool) !*Connection {
        var it: address.Iterator = .{ .remaining = addresses };
        var last_error: anyerror = error.NoSupportedAddress;
        while (try it.next()) |addr| {
            const fd = connectAuth(addr, receive_fds) catch |err| {
                last_error = err;
                continue;
            };
            errdefer _ = c.close(fd);
            const self = try allocator.create(Connection);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .fd = fd, .receive_fds = receive_fds };
            self.source = try loop.addFd(*Connection, fd, .{ .readable = true }, onFd, self);
            errdefer self.source.?.remove();
            // Armed only while a call awaits its reply; see armTimer.
            self.timer = try loop.addTimer(*Connection, onTimer, self);
            return self;
        }
        return last_error;
    }
    pub fn destroy(self: *Connection) void {
        std.debug.assert(self.callback_depth == 0);
        self.close();
        self.read_buf.deinit(self.allocator);
        self.write_buf.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.handlers.deinit(self.allocator);
        self.signals.deinit(self.allocator);
        if (self.unique_name) |name| self.allocator.free(name);
        self.allocator.destroy(self);
    }
    /// Completes every pending call exactly once. Idempotent; retains storage
    /// until destroy so closing from inside a callback is safe.
    pub fn close(self: *Connection) void {
        if (self.closed) return;
        self.closed = true;
        if (self.source) |s| s.remove();
        self.source = null;
        if (self.timer) |s| s.remove();
        self.timer = null;
        _ = c.close(self.fd);
        self.closeReadFds();
        if (self.wipe_buffers) {
            std.crypto.secureZero(u8, self.write_buf.allocatedSlice());
            std.crypto.secureZero(u8, self.read_buf.allocatedSlice());
        }
        while (self.pending.items.len > 0) self.complete(self.pending.orderedRemove(0), error.Disconnected);
        if (self.on_disconnect) |handler| {
            self.callback_depth += 1;
            defer self.callback_depth -= 1;
            handler.callback(handler.owner);
        }
    }
    pub fn complete(self: *Connection, p: Pending, result: Failure!wire.Message) void {
        self.callback_depth += 1;
        defer self.callback_depth -= 1;
        p.callback(p.owner, self, result);
    }

    pub const register = connection_calls.register;
    pub const unregisterMethodsByOwner = connection_calls.unregisterMethodsByOwner;
    pub const registerSignal = connection_calls.registerSignal;
    pub const unregisterSignal = connection_calls.unregisterSignal;
    pub const unregisterSignalsByOwner = connection_calls.unregisterSignalsByOwner;
    pub const hasSignal = connection_calls.hasSignal;
    pub const formatMatchRule = connection_calls.formatMatchRule;
    pub const addMatch = connection_calls.addMatch;
    pub const removeMatch = connection_calls.removeMatch;
    pub const subscribe = connection_calls.subscribe;
    pub const unsubscribe = connection_calls.unsubscribe;
    pub const hello = connection_calls.hello;
    pub const requestName = connection_calls.requestName;
    pub const call = connection_calls.call;
    pub const callWithFlags = connection_calls.callWithFlags;
    pub const callInternal = connection_calls.callInternal;
    pub const reply = connection_calls.reply;
    pub const deferReply = connection_calls.deferReply;
    pub const replyDeferred = connection_calls.replyDeferred;
    pub const replyErrorDeferred = connection_calls.replyErrorDeferred;
    pub const checkDeferred = connection_calls.checkDeferred;
    pub const releaseDeferred = connection_calls.releaseDeferred;
    pub const replyError = connection_calls.replyError;
    pub const signal = connection_calls.signal;

    pub const allocateSerial = connection_io.allocateSerial;
    pub const send = connection_io.send;
    pub const compactWrites = connection_io.compactWrites;
    pub const interest = connection_io.interest;
    pub const dispatch = connection_io.dispatch;
    pub const closeReadFds = connection_io.closeReadFds;
    pub const readWithFds = connection_io.readWithFds;
    pub const read = connection_io.read;
    pub const flush = connection_io.flush;
    pub const write = connection_io.write;
    pub const onFd = connection_io.onFd;
    pub const onTimer = connection_io.onTimer;
    pub const armTimer = connection_io.armTimer;
};
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn eqOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return eq(a.?, b.?);
}
pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
fn waitFd(fd: c_int, events: i16, deadline: i64) !void {
    while (true) {
        const left = deadline - nowMs();
        if (left <= 0) return error.AuthTimeout;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const n = c.poll(&fds, 1, @intCast(left));
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.ConnectFailed;
        }
        if (n == 0) return error.AuthTimeout;
        if (fds[0].revents & events != 0) return;
        return error.Disconnected;
    }
}
fn authWrite(fd: c_int, bytes: []const u8, deadline: i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try waitFd(fd, std.posix.POLL.OUT, deadline);
        const n = c.send(fd, bytes[offset..].ptr, bytes.len - offset, std.posix.MSG.NOSIGNAL);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .AGAIN or err == .INTR) continue;
            return error.AuthFailed;
        }
        if (n == 0) return error.Disconnected;
        offset += @intCast(n);
    }
}
fn connectAuth(addr: address.Address, receive_fds: bool) !c_int {
    const fd = c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    const deadline = nowMs() + 2000;
    const rc = c.connect(fd, @ptrCast(&addr.socket), addr.len);
    if (rc < 0) {
        const err = std.posix.errno(rc);
        if (err != .INPROGRESS and err != .AGAIN and err != .INTR) return error.ConnectFailed;
        try waitFd(fd, std.posix.POLL.OUT, deadline);
        var socket_error: c_int = 0;
        var len: std.posix.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&socket_error), &len) != 0 or socket_error != 0) return error.ConnectFailed;
    }
    var uid_buf: [20]u8 = undefined;
    const uid = try std.fmt.bufPrint(&uid_buf, "{d}", .{c.getuid()});
    var auth: [80]u8 = undefined;
    const prefix = "\x00AUTH EXTERNAL ";
    @memcpy(auth[0..prefix.len], prefix);
    const hex = "0123456789abcdef";
    for (uid, 0..) |ch, i| {
        auth[prefix.len + i * 2] = hex[ch >> 4];
        auth[prefix.len + i * 2 + 1] = hex[ch & 15];
    }
    const end = prefix.len + uid.len * 2;
    @memcpy(auth[end..][0..2], "\r\n");
    try authWrite(fd, auth[0 .. end + 2], deadline);
    var line: [1024]u8 = undefined;
    var count: usize = 0;
    while (count < line.len) {
        try waitFd(fd, std.posix.POLL.IN, deadline);
        const n = c.read(fd, line[count..].ptr, 1);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .AGAIN or err == .INTR) continue;
            return error.AuthFailed;
        }
        if (n == 0) return error.Disconnected;
        count += 1;
        if (count >= 2 and eq(line[count - 2 .. count], "\r\n")) break;
    }
    if (count != 37 or !eq(line[0..3], "OK ") or !eq(line[count - 2 .. count], "\r\n")) return error.AuthFailed;
    for (line[3..35]) |ch| if (!std.ascii.isHex(ch)) return error.AuthFailed;
    if (addr.guid) |guid| if (!std.ascii.eqlIgnoreCase(&guid, line[3..35])) return error.GuidMismatch;
    if (receive_fds) {
        try authWrite(fd, "NEGOTIATE_UNIX_FD\r\n", deadline);
        const expected = "AGREE_UNIX_FD\r\n";
        for (expected) |ch| {
            var byte: [1]u8 = undefined;
            while (true) {
                try waitFd(fd, std.posix.POLL.IN, deadline);
                const n = c.read(fd, &byte, 1);
                if (n < 0 and (std.posix.errno(n) == .AGAIN or std.posix.errno(n) == .INTR)) continue;
                if (n != 1 or byte[0] != ch) return error.AuthFailed;
                break;
            }
        }
    }
    try authWrite(fd, "BEGIN\r\n", deadline);
    return fd;
}

test {
    _ = @import("connection_tests.zig");
}
