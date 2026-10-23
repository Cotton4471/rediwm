//! Asynchronous NetworkManager client. Snapshots are fetched on menu open and
//! service signals, never from a polling timer. No shell commands or argv secrets.
const i18n = @import("i18n");
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("../Server.zig");
const gpa = @import("../main.zig").gpa;
const secure = @import("secure_allocator.zig").allocator;
pub const nm = "org.freedesktop.NetworkManager";
pub const root = "/org/freedesktop/NetworkManager";
// NetworkManager exports ObjectManager above its manager and device objects.
pub const objects_root = "/org/freedesktop";
pub const wireless = nm ++ ".Device.Wireless";
pub const wired = nm ++ ".Device.Wired";
pub const device_iface = nm ++ ".Device";
pub const ip4_iface = nm ++ ".IP4Config";
pub const ap_iface = nm ++ ".AccessPoint";
pub const settings_iface = nm ++ ".Settings.Connection";
pub const properties = "org.freedesktop.DBus.Properties";
const eq = std.mem.eql;
const Presence = @import("config").taskbar_items.Presence;
const manager_bus = @import("manager_bus.zig");
const manager_objects = @import("manager_objects.zig");
const manager_actions = @import("manager_actions.zig");

pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) void {
            self.len = @min(value.len, capacity);
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn init(value: []const u8) @This() {
            var t: @This() = .{};
            t.set(value);
            return t;
        }
    };
}
pub const Path = Text(256);
pub const Security = enum { open, personal, sae, unsupported };
pub const Network = struct {
    path: Path = .{},
    ssid: Text(32) = .{},
    strength: u8 = 0,
    security: Security = .open,
    connected: bool = false,
    saved: Path = .{},
};
pub const Ethernet = struct {
    path: Path = .{},
    name: Text(64) = .{},
    driver: Text(64) = .{},
    mac: Text(64) = .{},
    ip4: Path = .{},
    address: Text(256) = .{},
    gateway: Text(64) = .{},
    dns: Text(256) = .{},
    state: u32 = 0,
    managed: bool = false,
    carrier: bool = false,
    speed: u32 = 0,
    has_profile: bool = false,

    pub fn connected(self: Ethernet) bool {
        return self.state == 100;
    }
    pub fn active(self: Ethernet) bool {
        return self.state >= 40 and self.state <= 100;
    }
    pub fn status(self: Ethernet) []const u8 {
        if (!self.managed) return i18n.tr("Unmanaged");
        if (!self.carrier) return i18n.tr("Cable unplugged");
        return switch (self.state) {
            40...90 => i18n.tr("Connecting…"),
            100 => i18n.tr("Connected"),
            110 => i18n.tr("Disconnecting…"),
            120 => i18n.tr("Connection failed"),
            else => i18n.tr("Disconnected"),
        };
    }
};
pub const Ip4 = struct { path: Path, address: Text(256) = .{}, gateway: Text(64) = .{}, dns: Text(256) = .{} };
pub const Device = struct {
    path: Path = .{},
    active: Path = .{},
    state: u32 = 0,
    aps: [256]Path = @splat(.{}),
    count: usize = 0,
    last_scan: i64 = -1,
};
pub const Saved = struct { path: Path = .{}, ssid: Text(32) = .{}, security: Security = .open, loaded: bool = false };
pub const Request = struct { manager: *Manager, epoch: u64, path: Path, wired_generation: u64 = 0 };
pub const PasswordUpdate = struct {
    manager: *Manager,
    epoch: u64,
    net: Network,
    password: [128]u8 = @splat(0),
    len: usize,
};

pub const Manager = struct {
    server: *Server,
    conn: ?*dbus.Connection = null,
    owner: Path = .{},
    epoch: u64 = 0,
    closing: bool = false,
    fetching: bool = false,
    again: bool = false,
    available: bool = false,
    enabled: bool = false,
    hardware: bool = true,
    device: Path = .{},
    networks: [256]Network = @splat(.{}),
    count: usize = 0,
    saved: [128]Saved = @splat(.{}),
    saved_count: usize = 0,
    busy: bool = false,
    joining: ?Network = null,
    join_timer: ?*@import("wayland").server.wl.EventSource = null,
    scan_pending: bool = false,
    scanning: bool = false,
    last_scan: i64 = -1,
    scan_timer: ?*@import("wayland").server.wl.EventSource = null,
    message: []const u8 = "",
    state: u32 = 0,
    connectivity: u32 = 0,
    ethernet: [16]Ethernet = @splat(.{}),
    ethernet_count: usize = 0,
    wired_pending: ?Path = null,
    wired_want_connected: bool = false,
    wired_accepted: bool = false,
    wired_timer: ?*@import("wayland").server.wl.EventSource = null,
    wired_message: []const u8 = "",
    wired_generation: u64 = 0,
    /// What the taskbars were last told by `publishOffline`.
    offline_published: bool = false,
    /// Likewise for `publishPresence`.
    presence_published: Presence = .{},

    pub fn create(server: *Server) !*Manager {
        const self = try gpa.create(Manager);
        self.* = .{ .server = server };
        self.connect();
        return self;
    }
    pub fn destroy(self: *Manager) void {
        self.closing = true;
        if (self.join_timer) |timer| timer.remove();
        self.join_timer = null;
        if (self.scan_timer) |timer| timer.remove();
        self.scan_timer = null;
        if (self.wired_timer) |timer| timer.remove();
        self.wired_timer = null;
        if (self.conn) |conn| conn.destroy();
        gpa.destroy(self);
    }
    pub fn opened(self: *Manager) void {
        self.scan_pending = true;
        if (self.conn == null or self.conn.?.closed) self.connect() else self.fetch();
    }
    /// NetworkManager reports no connection at all (state ASLEEP or DISCONNECTED;
    /// connecting, unknown and an absent service are not alarming), by wifi or
    /// wire. The taskbar tints its network icon with it.
    pub fn offline(self: *const Manager) bool {
        return self.available and (self.state == 10 or self.state == 20);
    }
    /// A wireless adapter exists (even switched off), and a cable is connected:
    /// what decides the automatic Wi-Fi and Ethernet taskbar items.
    pub fn presence(self: *const Manager) Presence {
        if (!self.available) return .{};
        var cabled = false;
        for (self.ethernet[0..self.ethernet_count]) |eth| cabled = cabled or eth.connected();
        return .{ .wifi = self.device.len != 0, .wired = cabled };
    }
    /// Only a change reaches the taskbars, which then lay out again.
    fn publishPresence(self: *Manager) void {
        const now = self.presence();
        if (std.meta.eql(now, self.presence_published)) return;
        self.presence_published = now;
        var it = self.server.outputs.iterator(.forward);
        while (it.next()) |output| if (output.taskbar) |bar| bar.applyNetworkPresence(now);
        // Settings lists the items as shown.
        if (self.server.input.open_control_center) |cc| cc.refresh();
    }
    /// Only a flip reaches the taskbars, so an idle session stays idle.
    pub fn publishOffline(self: *Manager) void {
        const now = self.offline();
        if (now == self.offline_published) return;
        self.offline_published = now;
        var it = self.server.outputs.iterator(.forward);
        while (it.next()) |output| if (output.taskbar) |bar| bar.applyNetwork(now);
    }
    pub fn refresh(self: *Manager) void {
        if (self.closing) return;
        self.publishOffline();
        self.publishPresence();
        if (self.server.input.open_wifi) |popup| popup.changed();
        if (self.server.input.open_control_center) |cc| if (cc.showingPage(.network)) cc.refresh();
    }
    pub fn reset(self: *Manager) void {
        self.epoch +%= 1;
        self.owner = .{};
        if (self.join_timer) |timer| timer.timerUpdate(0) catch {};
        self.stopScan();
        self.last_scan = -1;
        self.available = false;
        self.enabled = false;
        self.hardware = true;
        self.count = 0;
        self.saved_count = 0;
        self.device = .{};
        self.state = 0;
        self.connectivity = 0;
        self.ethernet_count = 0;
        self.wired_pending = null;
        self.wired_message = "";
        if (self.wired_timer) |timer| timer.timerUpdate(0) catch {};
        self.busy = false;
        self.joining = null;
        self.message = i18n.tr("NetworkManager is unavailable");
        self.refresh();
    }

    const connect = manager_bus.connect;
    pub const hello = manager_bus.hello;
    pub const fromOwner = manager_bus.fromOwner;
    const changed = manager_bus.changed;

    pub const fetch = manager_objects.fetch;
    pub const parseObjects = manager_objects.parseObjects;
    pub const applySaved = manager_objects.applySaved;
    pub const fetchSaved = manager_objects.fetchSaved;

    pub const searching = manager_actions.searching;
    pub const stopScan = manager_actions.stopScan;
    pub const scan = manager_actions.scan;
    pub const toggle = manager_actions.toggle;
    pub const setEthernet = manager_actions.setEthernet;
    pub const checkWired = manager_actions.checkWired;
    pub const finishWired = manager_actions.finishWired;
    pub const join = manager_actions.join;
    pub const action = manager_actions.action;
    pub const failed = manager_actions.failed;
};
pub fn sameNetwork(a: Network, b: Network) bool {
    return a.security == b.security and eq(u8, a.ssid.slice(), b.ssid.slice());
}
pub fn networkName(net: *const Network) []const u8 {
    return if (std.unicode.utf8ValidateSlice(net.ssid.slice())) net.ssid.slice() else i18n.tr("Wi-Fi network");
}
pub fn networkSubtitle(net: Network) []const u8 {
    return if (net.connected) (if (net.saved.len != 0) i18n.tr("Connected · Saved") else i18n.tr("Connected")) else if (net.saved.len != 0) i18n.tr("Saved") else if (net.security == .open) i18n.tr("Open") else if (net.security == .unsupported) i18n.tr("Additional setup required") else i18n.tr("Secured");
}
pub fn joinError(net: Network, password: []const u8) ?[]const u8 {
    if (net.ssid.len == 0) return i18n.tr("Enter a network name.");
    if (net.security == .unsupported and net.saved.len == 0) return i18n.tr("This security type needs a network configuration tool.");
    if (net.connected or net.security == .open or (net.saved.len != 0 and password.len == 0)) return null;
    const hex = password.len == 64 and for (password) |c| {
        if (!std.ascii.isHex(c)) break false;
    } else true;
    if (net.security == .personal and !hex and (password.len < 8 or password.len > 63)) return i18n.tr("Use 8–63 characters or a 64-digit hex key.");
    if (net.security == .sae and (password.len < 1 or password.len > 63)) return i18n.tr("Enter a password (1–63 bytes).");
    return null;
}

const manager_settings = @import("manager_settings.zig");
pub const addressList = manager_settings.addressList;
pub const writeWiredSettings = manager_settings.writeWiredSettings;
pub const parseSaved = manager_settings.parseSaved;
pub const writeSettings = manager_settings.writeSettings;
pub const replacePassword = manager_settings.replacePassword;
