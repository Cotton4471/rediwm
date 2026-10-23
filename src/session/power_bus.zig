//! The logind connection: Hello, the signal owner, subscriptions, PrepareForSleep/PrepareForShutdown and API introspection.

const i18n = @import("i18n");
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const log = std.log.scoped(.power);
const power_mod = @import("power.zig");
const Manager = power_mod.Manager;
const bus_name = power_mod.bus_name;
const bus_path = power_mod.bus_path;
const bus_interface = power_mod.bus_interface;
const introspect_interface = power_mod.introspect_interface;
const call_timeout_ms = power_mod.call_timeout_ms;
const onDisconnect = Manager.onDisconnect;

pub fn connection(self: *Manager) !*dbus.Connection {
    if (self.conn) |c| {
        if (!c.closed) return c;
        c.destroy();
        self.conn = null;
        self.resetSignalOwner();
        self.owner_changed = false;
        self.hello_done = false;
        self.introspect_done = false;
        self.has_with_flags = false;
        self.has_list_inhibitors = false;
    }
    const loop = self.server.wl_server.getEventLoop();
    const conn = try dbus.Connection.openSystemWithFds(self.allocator, loop, self.server.environ);
    errdefer conn.destroy();
    _ = try conn.hello(self, onHello);
    conn.on_disconnect = .{ .owner = self, .callback = onDisconnect };
    self.conn = conn;
    return conn;
}

pub fn onHello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    _ = result catch |err| {
        conn.close();
        const req = self.pending orelse return;
        if (req.kind != .@"suspend") return;
        self.pending = null;
        self.failed(req.kind, i18n.tr("Could not reach the system's power service."), err);
        return;
    };
    self.hello_done = true;
    self.inspectApi(conn);
    self.watchSignalOwner(conn) catch return;
    _ = conn.addMatch("type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.login1'", null, null) catch return;
    var body: wire.Writer = .{ .allocator = self.allocator };
    defer body.deinit();
    body.string(bus_name) catch return;
    _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &body, self, onSignalOwner, call_timeout_ms) catch |err| {
        log.warn("could not resolve power signal sender: {}", .{err});
    };
}

pub fn onSignalOwner(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing or self.owner_changed) return;
    var msg = result catch return;
    if (msg.kind != .method_return) return;
    const sender = msg.body.string() catch return;
    self.signal_sender = self.allocator.dupe(u8, sender) catch return;
    self.subscribeSignals(conn);
    self.syncInhibitors();
    self.watchSession(conn);
}

pub fn subscribeSignals(self: *Manager, conn: *dbus.Connection) void {
    _ = conn.subscribe(.{
        .sender = self.signal_sender orelse return,
        .path = bus_path,
        .interface = bus_interface,
        .member = "PrepareForSleep",
        .owner = self,
        .callback = onPrepareForSleep,
    }, null, null) catch |err| {
        log.warn("could not subscribe to PrepareForSleep: {}", .{err});
    };
    _ = conn.subscribe(.{
        .sender = self.signal_sender orelse return,
        .path = bus_path,
        .interface = bus_interface,
        .member = "PrepareForShutdown",
        .owner = self,
        .callback = onPrepareForShutdown,
    }, null, null) catch |err| {
        log.warn("could not subscribe to PrepareForShutdown: {}", .{err});
    };
}

pub fn onPrepareForSleep(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    var reader = msg.body;
    const sleep_starting = reader.boolean() catch {
        log.warn("PrepareForSleep: invalid body", .{});
        return;
    };
    if (sleep_starting) {
        log.info("PrepareForSleep(true): system is suspending; preparing session", .{});
        self.lockForSleep();
        self.server.deactivateSession();
    } else {
        log.info("PrepareForSleep(false): system resumed from sleep; restoring session", .{});
        if (self.sleep_waiting) self.finishSleepWait();
        self.server.reactivateSession();
        // Delay the next sleep too.
        self.syncInhibitors();
    }
}

pub fn onPrepareForShutdown(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    var reader = msg.body;
    const shutdown_starting = reader.boolean() catch {
        log.warn("PrepareForShutdown: invalid body", .{});
        return;
    };
    if (shutdown_starting) {
        // Preparation runs while delay inhibitors are still active. An
        // early logout can make the display manager start a new greeter
        // while those services are preparing devices for poweroff. Like
        // labwc/niri, leave session termination to systemd's SIGTERM.
        log.info("PrepareForShutdown(true): waiting for session termination", .{});
    } else {
        log.info("PrepareForShutdown(false): shutdown canceled", .{});
    }
}

pub fn inspectApi(self: *Manager, conn: *dbus.Connection) void {
    const body: wire.Writer = .{ .allocator = self.allocator };
    _ = conn.call(bus_name, bus_path, introspect_interface, "Introspect", "", &body, self, onIntrospect, call_timeout_ms) catch {
        // If Introspect fails immediately, proceed with legacy methods
        self.introspect_done = true;
        self.maybeProbe();
        if (self.pending) |req| self.queryCapability(conn, req);
    };
}

pub fn onIntrospect(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (self.closing) return;
    self.introspect_done = true;
    if (result) |*msg| {
        if (msg.kind == .method_return) {
            var reader = msg.body;
            if (reader.string()) |xml| {
                self.has_with_flags = std.mem.indexOf(u8, xml, "SuspendWithFlags") != null;
                self.has_list_inhibitors = std.mem.indexOf(u8, xml, "ListInhibitors") != null;
            } else |_| {}
        }
    } else |_| {}
    self.maybeProbe();
    const req = self.pending orelse return;
    self.queryCapability(conn, req);
}
