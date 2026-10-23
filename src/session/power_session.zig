//! Following the login session: its Lock signal, LockedHint, disconnects and the logind name owner.

const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const Lock = @import("lock.zig").Lock;
const log = std.log.scoped(.power);
const power_mod = @import("power.zig");
const Manager = power_mod.Manager;
const bus_name = power_mod.bus_name;
const bus_path = power_mod.bus_path;
const bus_interface = power_mod.bus_interface;
const session_interface = power_mod.session_interface;
const call_timeout_ms = power_mod.call_timeout_ms;
const OwnerRequest = Manager.OwnerRequest;

/// Resolves REDIWM_LOGIN_SESSION, set only for a login rediwm-session
/// verified with logind; nested and test sessions have none.
pub fn watchSession(self: *Manager, conn: *dbus.Connection) void {
    if (self.server.greeter_mode or self.session_path != null or self.session_pending) return;
    const id = self.server.environ.getPosix("REDIWM_LOGIN_SESSION") orelse return;
    if (id.len == 0) return;
    var body: wire.Writer = .{ .allocator = self.allocator };
    defer body.deinit();
    body.string(id) catch return;
    const sender = self.signal_sender orelse return;
    const ctx = self.allocator.create(OwnerRequest) catch return;
    ctx.* = .{ .manager = self, .generation = self.owner_generation };
    _ = conn.call(sender, bus_path, bus_interface, "GetSession", "s", &body, ctx, onSession, call_timeout_ms) catch |err| {
        self.allocator.destroy(ctx);
        log.warn("could not look up the logind session: {}", .{err});
        return;
    };
    self.session_pending = true;
}

pub fn onSession(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const ctx: *OwnerRequest = @ptrCast(@alignCast(owner orelse return));
    const self = ctx.manager;
    defer self.allocator.destroy(ctx);
    if (ctx.generation != self.owner_generation) return;
    self.session_pending = false;
    if (self.closing) return;
    var msg = result catch |err| {
        log.warn("could not look up the logind session: {}", .{err});
        return;
    };
    if (msg.kind != .method_return or !std.mem.eql(u8, msg.headers.signature, "o")) {
        log.warn("logind has no session for this login: {s}", .{msg.headers.error_name orelse "invalid reply"});
        return;
    }
    const path = msg.body.objectPath() catch return;
    self.session_path = self.allocator.dupe(u8, path) catch return;
    // Every session's Lock comes from the same sender; ours is picked out
    // by path in the handler, so the registration owns no strings.
    _ = conn.subscribe(.{
        .sender = self.signal_sender orelse return,
        .interface = session_interface,
        .member = "Lock",
        .owner = self,
        .callback = onSessionLock,
    }, null, null) catch |err| log.warn("could not follow logind lock requests: {}", .{err});
    self.syncLockedHint();
}

pub fn forgetSession(self: *Manager) void {
    if (self.session_path) |path| self.allocator.free(path);
    self.session_path = null;
    self.session_pending = false;
    self.locked_hint = null;
}

pub fn onSessionLock(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    const ours = self.session_path orelse return;
    if (!std.mem.eql(u8, msg.headers.path orelse return, ours)) return;
    log.info("logind asked to lock the session", .{});
    Lock.start(self.server);
}

pub fn syncLockedHint(self: *Manager) void {
    const path = self.session_path orelse return;
    const conn = self.conn orelse return;
    const sender = self.signal_sender orelse return;
    if (conn.closed or self.locked_hint == self.locked) return;
    var body: wire.Writer = .{ .allocator = self.allocator };
    defer body.deinit();
    body.boolean(self.locked) catch return;
    _ = conn.call(sender, path, session_interface, "SetLockedHint", "b", &body, null, null, call_timeout_ms) catch |err| {
        log.warn("could not update the session's LockedHint: {}", .{err});
        return;
    };
    self.locked_hint = self.locked;
}

pub fn onDisconnect(owner: ?*anyopaque) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    self.resetSignalOwner();
    self.hello_done = false;
}

pub fn onOwnerChanged(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    var body = msg.body;
    if (!std.mem.eql(u8, try body.string(), bus_name)) return;
    _ = try body.string();
    const next = try body.string();
    self.owner_changed = true;
    conn.unregisterSignalsByOwner(self);
    try self.watchSignalOwner(conn);
    self.resetSignalOwner();
    if (next.len == 0) return;
    self.signal_sender = try self.allocator.dupe(u8, next);
    self.subscribeSignals(conn);
    self.syncInhibitors();
    self.watchSession(conn);
}

pub fn watchSignalOwner(self: *Manager, conn: *dbus.Connection) !void {
    try conn.registerSignal(.{
        .sender = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "NameOwnerChanged",
        .owner = self,
        .callback = onOwnerChanged,
    });
}
