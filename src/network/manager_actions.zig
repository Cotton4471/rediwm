//! Scanning, the Wi-Fi switch, wired connections, joining networks with passwords, and generic actions.

const i18n = @import("i18n");
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const gpa = @import("../main.zig").gpa;
const secure = @import("secure_allocator.zig").allocator;
const eq = std.mem.eql;
const manager_mod = @import("manager.zig");
const Manager = manager_mod.Manager;
const nm = manager_mod.nm;
const root = manager_mod.root;
const wireless = manager_mod.wireless;
const device_iface = manager_mod.device_iface;
const settings_iface = manager_mod.settings_iface;
const properties = manager_mod.properties;
const Path = manager_mod.Path;
const Network = manager_mod.Network;
const Request = manager_mod.Request;
const PasswordUpdate = manager_mod.PasswordUpdate;
const writeWiredSettings = manager_mod.writeWiredSettings;
const writeSettings = manager_mod.writeSettings;
const replacePassword = manager_mod.replacePassword;

pub fn searching(self: *const Manager) bool {
    return self.fetching or self.scanning;
}

pub fn stopScan(self: *Manager) void {
    self.scanning = false;
    if (self.scan_timer) |timer| timer.timerUpdate(0) catch {};
}

pub fn scanTimeout(self: *Manager) c_int {
    self.stopScan();
    self.refresh();
    return 0;
}

pub fn scanRequested(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Request = @ptrCast(@alignCast(owner.?));
    defer gpa.destroy(req);
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch) return;
    const msg = result catch {
        self.stopScan();
        self.refresh();
        return;
    };
    if (!self.fromOwner(msg) or msg.kind != .method_return) {
        self.stopScan();
        self.refresh();
    }
    // Acceptance is not completion: LastScan changes when results arrive.
}

pub fn scan(self: *Manager) void {
    if (!self.available or !self.enabled or !self.hardware or self.device.len == 0 or self.scanning) return;
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    const a = b.beginArray(8) catch return;
    b.endArray(a) catch return;
    if (self.scan_timer == null) self.scan_timer = self.server.wl_server.getEventLoop().addTimer(*Manager, scanTimeout, self) catch return;
    const req = gpa.create(Request) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = self.device };
    _ = self.conn.?.call(self.owner.slice(), self.device.slice(), wireless, "RequestScan", "a{sv}", &b, req, scanRequested, 5000) catch {
        gpa.destroy(req);
        return;
    };
    self.scanning = true;
    // Bound the indicator if a driver never reports scan completion.
    self.scan_timer.?.timerUpdate(15000) catch self.stopScan();
}

pub fn toggle(self: *Manager) void {
    if (!self.available or !self.hardware or self.busy) return;
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    b.string(nm) catch return;
    b.string("WirelessEnabled") catch return;
    b.variant("b") catch return;
    b.boolean(!self.enabled) catch return;
    self.action(root, properties, "Set", "ssv", &b);
}

pub fn setEthernet(self: *Manager, path: Path, on: bool) void {
    if (!self.available or self.wired_pending != null) return;
    const eth = for (self.ethernet[0..self.ethernet_count]) |eth| {
        if (eq(u8, eth.path.slice(), path.slice())) break eth;
    } else return;
    if (!eth.managed or (on and !eth.carrier)) return;
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    if (on) {
        if (eth.has_profile) {
            // Let NetworkManager choose the best existing profile; do not
            // replace the user's static addresses, DNS or authentication.
            b.objectPath("/") catch return;
        } else {
            writeWiredSettings(&b, eth.name.slice()) catch return;
        }
        b.objectPath(path.slice()) catch return;
        b.objectPath("/") catch return;
    }
    if (self.wired_timer == null) self.wired_timer = self.server.wl_server.getEventLoop().addTimer(*Manager, wiredTimeout, self) catch return;
    const req = gpa.create(Request) catch return;
    self.wired_generation +%= 1;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = path, .wired_generation = self.wired_generation };
    _ = self.conn.?.callWithFlags(self.owner.slice(), if (on) root else path.slice(), if (on) nm else device_iface, if (!on) "Disconnect" else if (eth.has_profile) "ActivateConnection" else "AddAndActivateConnection", if (!on) "" else if (eth.has_profile) "ooo" else "a{sa{sv}}oo", &b, req, wiredDone, 15000, wire.flag_allow_interactive_authorization) catch {
        gpa.destroy(req);
        self.wired_message = i18n.tr("Could not send the Ethernet request.");
        self.refresh();
        return;
    };
    self.wired_pending = path;
    self.wired_want_connected = on;
    self.wired_accepted = false;
    self.wired_message = if (on) i18n.tr("Connecting Ethernet…") else i18n.tr("Disconnecting Ethernet…");
    self.wired_timer.?.timerUpdate(45000) catch {};
    self.refresh();
}

pub fn wiredDone(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Request = @ptrCast(@alignCast(owner.?));
    defer gpa.destroy(req);
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch or self.wired_generation != req.wired_generation) return;
    const pending = self.wired_pending orelse return;
    if (!eq(u8, pending.slice(), req.path.slice())) return;
    const msg = result catch {
        self.finishWired(i18n.tr("Ethernet request failed. Check permissions and try again."));
        return;
    };
    if (!self.fromOwner(msg) or msg.kind != .method_return) {
        self.finishWired(i18n.tr("Ethernet request failed. Check permissions and try again."));
        return;
    }
    self.wired_accepted = true;
    self.fetch();
}

pub fn checkWired(self: *Manager) void {
    const pending = self.wired_pending orelse return;
    for (self.ethernet[0..self.ethernet_count]) |eth| {
        if (!eq(u8, eth.path.slice(), pending.slice())) continue;
        if (!self.wired_accepted) return;
        if (self.wired_want_connected and (!eth.carrier or eth.state == 120 or !eth.managed)) {
            self.finishWired(i18n.tr("Ethernet could not connect. Check the cable and connection settings."));
        } else if ((self.wired_want_connected and eth.connected()) or (!self.wired_want_connected and !eth.active() and eth.state != 110)) self.finishWired("");
        return;
    }
    self.finishWired(i18n.tr("Ethernet adapter was removed."));
}

pub fn finishWired(self: *Manager, message: []const u8) void {
    self.wired_pending = null;
    self.wired_message = message;
    if (self.wired_timer) |timer| timer.timerUpdate(0) catch {};
    self.refresh();
}

pub fn wiredTimeout(self: *Manager) c_int {
    self.finishWired(i18n.tr("Ethernet connection timed out. Check the cable and try again."));
    return 0;
}

pub fn join(self: *Manager, net: Network, password: []const u8, autojoin: bool, hidden: bool) void {
    if (!self.available or !self.enabled or !self.hardware or self.device.len == 0 or self.busy) return;
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    if (net.saved.len != 0 and password.len != 0) {
        const update = secure.create(PasswordUpdate) catch return;
        update.* = .{ .manager = self, .epoch = self.epoch, .net = net, .len = password.len };
        @memcpy(update.password[0..password.len], password);
        _ = self.conn.?.call(self.owner.slice(), net.saved.slice(), settings_iface, "GetSettings", "", &b, update, passwordSettings, 5000) catch {
            secure.destroy(update);
            return;
        };
        self.busy = true;
    } else if (net.saved.len != 0) {
        b.objectPath(net.saved.slice()) catch return;
        b.objectPath(self.device.slice()) catch return;
        b.objectPath(if (hidden) "/" else net.path.slice()) catch return;
        self.action(root, nm, "ActivateConnection", "ooo", &b);
    } else {
        writeSettings(&b, net, password, autojoin, hidden) catch return;
        b.objectPath(self.device.slice()) catch return;
        b.objectPath(if (hidden) "/" else net.path.slice()) catch return;
        self.action(root, nm, "AddAndActivateConnection", "a{sa{sv}}oo", &b);
    }
    if (self.busy) {
        self.joining = net;
        if (self.join_timer == null) self.join_timer = self.server.wl_server.getEventLoop().addTimer(*Manager, joinTimeout, self) catch null;
        if (self.join_timer) |timer| timer.timerUpdate(45000) catch {};
        self.message = i18n.tr("Connecting…");
        self.refresh();
    }
}

// Replace only the secret, preserving saved IP, DNS, identity and routing
// settings. The temporary context is locked and wiped when the call ends.
pub fn passwordSettings(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const update: *PasswordUpdate = @ptrCast(@alignCast(owner.?));
    const self = update.manager;
    if (self.closing or self.epoch != update.epoch) {
        secure.destroy(update);
        return;
    }
    var msg = result catch {
        secure.destroy(update);
        self.failed();
        return;
    };
    if (!self.fromOwner(msg) or msg.kind != .method_return or !eq(u8, msg.headers.signature, "a{sa{sv}}")) {
        secure.destroy(update);
        self.failed();
        return;
    }
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    replacePassword(&msg.body, &b, update.password[0..update.len]) catch {
        secure.destroy(update);
        self.failed();
        return;
    };
    _ = conn.callWithFlags(self.owner.slice(), update.net.saved.slice(), settings_iface, "Update", "a{sa{sv}}", &b, update, passwordUpdated, 15000, wire.flag_allow_interactive_authorization) catch {
        secure.destroy(update);
        self.failed();
        return;
    };
    std.crypto.secureZero(u8, &update.password);
}

pub fn passwordUpdated(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const update: *PasswordUpdate = @ptrCast(@alignCast(owner.?));
    defer secure.destroy(update);
    const self = update.manager;
    if (self.closing or self.epoch != update.epoch) return;
    const msg = result catch {
        self.failed();
        return;
    };
    if (!self.fromOwner(msg) or msg.kind != .method_return) {
        self.failed();
        return;
    }
    var b: wire.Writer = .{ .allocator = secure };
    defer b.deinit();
    b.objectPath(update.net.saved.slice()) catch {
        self.failed();
        return;
    };
    b.objectPath(self.device.slice()) catch {
        self.failed();
        return;
    };
    b.objectPath(update.net.path.slice()) catch {
        self.failed();
        return;
    };
    self.action(root, nm, "ActivateConnection", "ooo", &b);
    if (self.busy) self.message = i18n.tr("Connecting…");
}

pub fn action(self: *Manager, path: []const u8, iface: []const u8, method: []const u8, sig: []const u8, b: *wire.Writer) void {
    const req = gpa.create(Request) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = .{} };
    _ = self.conn.?.callWithFlags(self.owner.slice(), path, iface, method, sig, b, req, actionDone, 15000, wire.flag_allow_interactive_authorization) catch {
        gpa.destroy(req);
        self.message = i18n.tr("Could not send the Wi-Fi request");
        self.refresh();
        return;
    };
    self.busy = true;
    self.message = i18n.tr("Updating Wi-Fi…");
    self.refresh();
}

pub fn actionDone(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Request = @ptrCast(@alignCast(owner.?));
    defer gpa.destroy(req);
    const self = req.manager;
    if (self.closing or self.epoch != req.epoch) return;
    const msg = result catch {
        self.failed();
        return;
    };
    if (!self.fromOwner(msg) or msg.kind != .method_return) {
        self.failed();
        return;
    }
    // The method accepts activation; the device state confirms completion.
    if (self.joining == null) {
        self.busy = false;
        self.message = "";
    }
    self.fetch();
    self.refresh();
}

pub fn joinTimeout(self: *Manager) c_int {
    self.failed();
    return 0;
}

pub fn failed(self: *Manager) void {
    if (self.join_timer) |timer| timer.timerUpdate(0) catch {};
    self.busy = false;
    self.joining = null;
    self.message = i18n.tr("Wi-Fi request failed. Check credentials and permissions.");
    self.refresh();
}
