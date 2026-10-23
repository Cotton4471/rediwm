//! Handlers and calls: method and signal registration, match rules, calls, replies (also deferred) and signals.

const std = @import("std");
const wire = @import("wire.zig");
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
const bus_name = connection_mod.bus_name;
const bus_path = connection_mod.bus_path;
const pending_limit = connection_mod.pending_limit;
const eq = connection_mod.eq;
const eqOpt = connection_mod.eqOpt;
const nowMs = connection_mod.nowMs;
const Callback = Connection.Callback;
const Deferred = Connection.Deferred;
const Handler = Connection.Handler;
const SignalHandler = Connection.SignalHandler;

/// Handler strings must outlive the connection (normally string literals).
pub fn register(self: *Connection, handler: Handler) !void {
    if (self.closed) return error.Disconnected;
    for (self.handlers.items) |h| if (eq(h.path, handler.path) and eq(h.interface, handler.interface) and eq(h.member, handler.member)) return error.DuplicateHandler;
    try self.handlers.append(self.allocator, handler);
}

/// Remove short-lived request objects before freeing their path and owner.
pub fn unregisterMethodsByOwner(self: *Connection, owner: ?*anyopaque) void {
    var i: usize = 0;
    while (i < self.handlers.items.len) {
        if (self.handlers.items[i].owner == owner) _ = self.handlers.orderedRemove(i) else i += 1;
    }
}

/// Handler strings must outlive the registration (normally string literals).
pub fn registerSignal(self: *Connection, handler: SignalHandler) !void {
    if (self.closed) return error.Disconnected;
    if (self.hasSignal(handler)) return error.DuplicateHandler;
    try self.signals.append(self.allocator, handler);
}

pub fn unregisterSignal(self: *Connection, handler: SignalHandler) bool {
    for (self.signals.items, 0..) |h, i| {
        if (eqOpt(h.sender, handler.sender) and
            eqOpt(h.path, handler.path) and
            eqOpt(h.interface, handler.interface) and
            eqOpt(h.member, handler.member) and
            h.owner == handler.owner and
            h.callback == handler.callback)
        {
            _ = self.signals.orderedRemove(i);
            return true;
        }
    }
    return false;
}

pub fn unregisterSignalsByOwner(self: *Connection, owner: ?*anyopaque) void {
    var i: usize = 0;
    while (i < self.signals.items.len) {
        if (self.signals.items[i].owner == owner) {
            _ = self.signals.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn hasSignal(self: *Connection, handler: SignalHandler) bool {
    for (self.signals.items) |h| {
        if (eqOpt(h.sender, handler.sender) and
            eqOpt(h.path, handler.path) and
            eqOpt(h.interface, handler.interface) and
            eqOpt(h.member, handler.member) and
            h.owner == handler.owner and
            h.callback == handler.callback)
        {
            return true;
        }
    }
    return false;
}

pub fn formatMatchRule(buf: []u8, handler: SignalHandler) ![]const u8 {
    var offset: usize = 0;
    const prefix = "type='signal'";
    if (buf.len < prefix.len) return error.NoSpaceLeft;
    @memcpy(buf[0..prefix.len], prefix);
    offset += prefix.len;
    if (handler.sender) |s| {
        const part = try std.fmt.bufPrint(buf[offset..], ",sender='{s}'", .{s});
        offset += part.len;
    }
    if (handler.interface) |i| {
        const part = try std.fmt.bufPrint(buf[offset..], ",interface='{s}'", .{i});
        offset += part.len;
    }
    if (handler.member) |m| {
        const part = try std.fmt.bufPrint(buf[offset..], ",member='{s}'", .{m});
        offset += part.len;
    }
    if (handler.path) |p| {
        const part = try std.fmt.bufPrint(buf[offset..], ",path='{s}'", .{p});
        offset += part.len;
    }
    return buf[0..offset];
}

pub fn addMatch(self: *Connection, rule: []const u8, owner: ?*anyopaque, callback: ?Callback) !u32 {
    var body: wire.Writer = .{ .allocator = self.allocator };
    defer body.deinit();
    try body.string(rule);
    return self.call(bus_name, bus_path, bus_name, "AddMatch", "s", &body, owner, callback, 5000);
}

pub fn removeMatch(self: *Connection, rule: []const u8, owner: ?*anyopaque, callback: ?Callback) !u32 {
    var body: wire.Writer = .{ .allocator = self.allocator };
    defer body.deinit();
    try body.string(rule);
    return self.call(bus_name, bus_path, bus_name, "RemoveMatch", "s", &body, owner, callback, 5000);
}

pub fn subscribe(self: *Connection, handler: SignalHandler, owner: ?*anyopaque, callback: ?Callback) !u32 {
    try self.registerSignal(handler);
    errdefer _ = self.unregisterSignal(handler);
    var rule_buf: [512]u8 = undefined;
    const rule = try formatMatchRule(&rule_buf, handler);
    return self.addMatch(rule, owner, callback);
}

pub fn unsubscribe(self: *Connection, handler: SignalHandler, owner: ?*anyopaque, callback: ?Callback) !u32 {
    _ = self.unregisterSignal(handler);
    var rule_buf: [512]u8 = undefined;
    const rule = try formatMatchRule(&rule_buf, handler);
    return self.removeMatch(rule, owner, callback);
}

pub fn hello(self: *Connection, owner: ?*anyopaque, callback: Callback) !u32 {
    if (self.hello_sent) return error.AlreadyRegistered;
    const body: wire.Writer = .{ .allocator = self.allocator };
    const serial = try self.callInternal(bus_name, bus_path, bus_name, "Hello", "", &body, owner, callback, 5000, true, 0);
    self.hello_sent = true;
    return serial;
}

pub fn requestName(self: *Connection, name: []const u8, flags: u32, owner: ?*anyopaque, callback: Callback) !u32 {
    var body: wire.Writer = .{ .allocator = self.allocator };
    defer body.deinit();
    try body.string(name);
    try body.uint32(flags);
    return self.call(bus_name, bus_path, bus_name, "RequestName", "su", &body, owner, callback, 5000);
}

pub fn call(self: *Connection, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer, owner: ?*anyopaque, callback: ?Callback, timeout_ms: u32) !u32 {
    return self.callWithFlags(destination, path, interface, member, signature, body, owner, callback, timeout_ms, 0);
}

pub fn callWithFlags(self: *Connection, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer, owner: ?*anyopaque, callback: ?Callback, timeout_ms: u32, flags: u8) !u32 {
    if (self.unique_name == null) return error.NotRegistered;
    return self.callInternal(destination, path, interface, member, signature, body, owner, callback, timeout_ms, false, flags);
}

pub fn callInternal(self: *Connection, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer, owner: ?*anyopaque, callback: ?Callback, timeout_ms: u32, is_hello: bool, flags: u8) !u32 {
    if (self.closed) return error.Disconnected;
    const serial = self.allocateSerial();
    if (callback) |cb| {
        if (self.pending.items.len == pending_limit) return error.TooManyPendingCalls;
        try self.pending.append(self.allocator, .{ .serial = serial, .deadline = nowMs() + @as(i64, @max(1, timeout_ms)), .owner = owner, .callback = cb, .hello = is_hello });
        errdefer _ = self.pending.pop();
        try self.armTimer();
        try self.send(.method_call, flags, serial, .{ .destination = destination, .path = path, .interface = interface, .member = member, .signature = signature }, body);
    } else {
        try self.send(.method_call, flags | wire.flag_no_reply_expected, serial, .{ .destination = destination, .path = path, .interface = interface, .member = member, .signature = signature }, body);
    }
    return serial;
}

pub fn reply(self: *Connection, request: wire.Message, signature: []const u8, body: *const wire.Writer) !void {
    if (request.kind != .method_call) return error.InvalidRequest;
    if (request.flags & 1 != 0) return;
    try self.send(.method_return, 0, self.allocateSerial(), .{ .destination = request.headers.sender orelse return error.MissingSender, .reply_serial = request.serial, .signature = signature }, body);
}

/// Return successfully from the handler after deferring: dispatch sends
/// nothing automatically. Any other request data needed later must be copied.
pub fn deferReply(self: *Connection, request: wire.Message) !Deferred {
    if (self.closed) return error.Disconnected;
    if (request.kind != .method_call) return error.InvalidRequest;
    return .{
        .serial = request.serial,
        .sender = try self.allocator.dupe(u8, request.headers.sender orelse return error.MissingSender),
        .connection = self,
        .no_reply = request.flags & wire.flag_no_reply_expected != 0,
    };
}

/// Success consumes the handle. On failure it remains owned by the caller
/// for retry or release; close makes every outstanding handle unusable.
pub fn replyDeferred(self: *Connection, deferred: *Deferred, signature: []const u8, body: *const wire.Writer) !void {
    try self.checkDeferred(deferred);
    if (!deferred.no_reply) try self.send(.method_return, 0, self.allocateSerial(), .{ .destination = deferred.sender, .reply_serial = deferred.serial, .signature = signature }, body);
    self.releaseDeferred(deferred);
}

pub fn replyErrorDeferred(self: *Connection, deferred: *Deferred, name: []const u8, description: []const u8) !void {
    try self.checkDeferred(deferred);
    if (!deferred.no_reply) {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try body.string(description);
        try self.send(.error_reply, 0, self.allocateSerial(), .{ .destination = deferred.sender, .reply_serial = deferred.serial, .error_name = name, .signature = "s" }, &body);
    }
    self.releaseDeferred(deferred);
}

pub fn checkDeferred(self: *Connection, deferred: *const Deferred) !void {
    if (deferred.connection != self) return error.InvalidRequest;
    if (self.closed) return error.Disconnected;
}

/// Abandon without replying. Idempotent, including after close; must run
/// before destroy. A handle belongs only to the connection that created it.
pub fn releaseDeferred(self: *Connection, deferred: *Deferred) void {
    if (deferred.connection == null) return;
    std.debug.assert(deferred.connection == self);
    self.allocator.free(deferred.sender);
    deferred.sender = &.{};
    deferred.connection = null;
}

pub fn replyError(self: *Connection, request: wire.Message, name: []const u8, description: []const u8) !void {
    if (request.kind != .method_call) return error.InvalidRequest;
    if (request.flags & 1 != 0) return;
    var body: wire.Writer = .{ .allocator = self.allocator };
    defer body.deinit();
    try body.string(description);
    try self.send(.error_reply, 0, self.allocateSerial(), .{ .destination = request.headers.sender orelse return error.MissingSender, .reply_serial = request.serial, .error_name = name, .signature = "s" }, &body);
}

pub fn signal(self: *Connection, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer) !void {
    if (self.unique_name == null) return error.NotRegistered;
    try self.send(.signal, 0, self.allocateSerial(), .{ .path = path, .interface = interface, .member = member, .signature = signature }, body);
}
