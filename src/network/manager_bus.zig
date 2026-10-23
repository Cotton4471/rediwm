//! The NetworkManager connection: connecting, Hello, the name owner and PropertiesChanged.

const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const secure = @import("secure_allocator.zig").allocator;
const eq = std.mem.eql;
const manager_mod = @import("manager.zig");
const Manager = manager_mod.Manager;
const nm = manager_mod.nm;
const objects_root = manager_mod.objects_root;
const device_iface = manager_mod.device_iface;
const settings_iface = manager_mod.settings_iface;

pub fn connect(self: *Manager) void {
    if (self.conn) |old| old.destroy();
    self.conn = null;
    self.reset();
    const conn = dbus.Connection.openSystem(secure, self.server.wl_server.getEventLoop(), self.server.environ) catch return;
    conn.wipe_buffers = true;
    self.conn = conn;
    conn.on_disconnect = .{ .owner = self, .callback = disconnected };
    _ = conn.hello(self, hello) catch conn.close();
}

pub fn disconnected(owner: ?*anyopaque) void {
    const self: *Manager = @ptrCast(@alignCast(owner.?));
    if (!self.closing) self.reset();
}

pub fn hello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner.?));
    if (self.closing) return;
    const msg = result catch return;
    if (msg.kind != .method_return) return;
    conn.registerSignal(.{ .sender = "org.freedesktop.DBus", .interface = "org.freedesktop.DBus", .member = "NameOwnerChanged", .owner = self, .callback = ownerChanged }) catch return;
    _ = conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ nm ++ "'", null, null) catch return;
    conn.registerSignal(.{ .owner = self, .callback = changed }) catch return;
    _ = conn.addMatch("type='signal',sender='" ++ nm ++ "',path_namespace='" ++ objects_root ++ "'", null, null) catch return;
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    b.string(nm) catch return;
    _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &b, self, gotOwner, 5000) catch return;
}

pub fn gotOwner(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Manager = @ptrCast(@alignCast(owner.?));
    if (self.closing or self.owner.len != 0) return;
    var msg = result catch return;
    if (msg.kind != .method_return) return;
    self.owner.set(msg.body.string() catch return);
    self.fetch();
}

pub fn ownerChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
    const self: *Manager = @ptrCast(@alignCast(owner.?));
    var b = msg.body;
    if (!eq(u8, try b.string(), nm)) return;
    _ = try b.string();
    const next = try b.string();
    self.reset();
    self.owner.set(next);
    self.fetch();
}

pub fn fromOwner(self: *Manager, msg: wire.Message) bool {
    return self.owner.len != 0 and eq(u8, self.owner.slice(), msg.headers.sender orelse "");
}

pub fn changed(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
    const self: *Manager = @ptrCast(@alignCast(owner.?));
    if (!self.fromOwner(msg)) return;
    // Saved profiles may change without changing their object path.
    if (eq(u8, msg.headers.interface orelse "", settings_iface)) {
        for (self.saved[0..self.saved_count]) |*saved| if (eq(u8, saved.path.slice(), msg.headers.path orelse "")) {
            saved.loaded = false;
        };
    }
    // The global state is one small signal: track it with no snapshot, so the
    // taskbar stays right while no popup is open.
    if (eq(u8, msg.headers.interface orelse "", nm) and eq(u8, msg.headers.member orelse "", "StateChanged") and eq(u8, msg.headers.signature, "u")) {
        var body = msg.body;
        self.state = try body.uint32();
        self.publishOffline();
    }
    const settings_open = if (self.server.input.open_control_center) |cc| cc.showingPage(.network) else false;
    // Adapters and cables coming and going decide which taskbar items show;
    // access-point churn does not, so it only matters while a page is open.
    const iface = msg.headers.interface orelse "";
    const member = msg.headers.member orelse "";
    var topology = (eq(u8, iface, nm) and (eq(u8, member, "StateChanged") or eq(u8, member, "DeviceAdded") or eq(u8, member, "DeviceRemoved"))) or
        (eq(u8, iface, device_iface) and eq(u8, member, "StateChanged"));
    if (eq(u8, member, "InterfacesAdded") or eq(u8, member, "InterfacesRemoved")) {
        var body = msg.body;
        topology = topology or std.mem.indexOf(u8, try body.objectPath(), "/AccessPoint/") == null;
    }
    if (topology or self.server.input.open_wifi != null or settings_open or self.busy or self.wired_pending != null) self.fetch();
}
