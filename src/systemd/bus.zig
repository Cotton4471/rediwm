//! Bus ownership and signals: discovering systemd's owner, Hello, signal dispatch, settling dirty state, unit removal and PropertiesChanged.

const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const gpa = @import("../main.zig").gpa;
const edit = @import("../systemd_edit.zig");
const systemd_mod = @import("../systemd.zig");
const Client = systemd_mod.Client;
const name = systemd_mod.name;
const path = systemd_mod.path;
const manager = systemd_mod.manager;
const properties = systemd_mod.properties;
const settle_ms = systemd_mod.settle_ms;
const copied_limit = systemd_mod.copied_limit;
const Snapshot = systemd_mod.Snapshot;
const markUnloaded = systemd_mod.markUnloaded;
const Prop = systemd_mod.Prop;
const apply = systemd_mod.apply;

/// Forgets everything read from systemd and everything still on its way.
pub fn resetState(self: *Client) void {
    self.dirty = false;
    if (self.settle_timer) |timer| timer.timerUpdate(0) catch {};
    edit.cancel(self);
    self.edited_type = null;
    if (self.edited_unit) |unit| gpa.free(unit);
    self.edited_unit = null;
    self.generation += 1;
    if (self.action_job) |job| gpa.free(job);
    self.action_job = null;
    self.snapshot.deinit();
    self.staging.deinit();
    self.loading = false;
    self.staging_listed = false;
    self.analyzing = false;
    self.analyzed = false;
    self.boot_pending = false;
    self.action_pending = false;
    self.subscribed = false;
    self.again = false;
    self.again_force = false;
    self.next_detail = 0;
    self.next_step = 0;
    self.pending_details = 0;
    self.boot_us = null;
    self.message_len = 0;
}

pub fn setOwner(self: *Client, unique: []const u8) void {
    self.cancelUnlock();
    self.resetState();
    if (self.owner) |old| gpa.free(old);
    self.owner = if (unique.len > 0) gpa.dupe(u8, unique) catch null else null;
    // A new daemon has no subscribers: ask again if anything still wants it.
    if (self.available() and self.watching) {
        self.subscribe() catch {};
    } else self.sync();
    if (!self.closing) if (self.server.input.open_control_center) |cc| {
        cc.refresh();
    };
}

pub fn disconnected(ctx: ?*anyopaque) void {
    const self: *Client = @ptrCast(@alignCast(ctx orelse return));
    if (!self.closing) self.setOwner("");
}

pub fn hello(ctx: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Client = @ptrCast(@alignCast(ctx orelse return));
    if (self.closing) return;
    const msg = result catch return;
    if (msg.kind != .method_return) return;
    self.setup(conn) catch self.inform(@import("i18n").tr("Could not connect to systemd."));
}

pub fn setup(self: *Client, conn: *dbus.Connection) !void {
    try conn.registerSignal(.{ .owner = self, .callback = signal });
    // Only the owner of the name is tracked until the page asks for more.
    _ = try conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ name ++ "'", null, null);
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    try body.string(name);
    _ = try conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &body, self, discovered, 5000);
}

pub fn discovered(ctx: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Client = @ptrCast(@alignCast(ctx orelse return));
    if (self.closing or self.generation != 0) return;
    var msg = result catch return;
    if (msg.kind != .method_return) return;
    self.setOwner(msg.body.string() catch return);
}

pub fn signal(ctx: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
    const self: *Client = @ptrCast(@alignCast(ctx orelse return));
    if (self.closing) return;
    const member = msg.headers.member orelse return;
    const interface = msg.headers.interface orelse return;
    var body = msg.body;
    if (std.mem.eql(u8, interface, "org.freedesktop.DBus") and std.mem.eql(u8, member, "NameOwnerChanged") and std.mem.eql(u8, msg.headers.sender orelse "", "org.freedesktop.DBus")) {
        if (!std.mem.eql(u8, try body.string(), name)) return;
        _ = try body.string();
        self.setOwner(try body.string());
    } else if (self.fromOwner(msg) and self.watching) {
        if (std.mem.eql(u8, interface, manager)) {
            // Type is a constant property until daemon reload; systemd
            // does not have to emit Service.PropertiesChanged for it.
            if (std.mem.eql(u8, member, "Reloading")) {
                if (!try body.boolean()) self.reload(true);
            } else if (std.mem.eql(u8, member, "JobRemoved")) {
                _ = try body.uint32();
                const job = try body.string();
                _ = try body.string();
                const outcome = try body.string();
                if (self.action_job) |requested| {
                    if (std.mem.eql(u8, requested, job)) {
                        if (!std.mem.eql(u8, outcome, "done")) self.inform(outcome);
                        gpa.free(requested);
                        self.action_job = null;
                    }
                }
            } else if (std.mem.eql(u8, member, "UnitNew")) {
                // Mounts, targets and the rest are not rows; only a service is news.
                if (std.mem.endsWith(u8, try body.string(), ".service")) self.markDirty();
            } else if (std.mem.eql(u8, member, "UnitRemoved")) {
                self.unitRemoved(try body.string());
            } else if (std.mem.eql(u8, member, "UnitFilesChanged")) {
                self.markDirty();
            }
        } else if (std.mem.eql(u8, interface, properties) and std.mem.eql(u8, member, "PropertiesChanged")) {
            try self.propertiesChanged(msg.headers.path orelse return, &body);
        }
    }
}

// Live updates go to the freshest data there is: the half-built list once
// ListUnits is in it, else the current one. They never restart a load, and
// none of them makes a call: see `markDirty`.
pub fn fresh(self: *Client) *Snapshot {
    return if (self.loading and self.staging_listed) &self.staging else &self.snapshot;
}

/// Something changed that a signal cannot describe. Read the list again after
/// a settling time, once however many signals ask.
pub fn markDirty(self: *Client) void {
    if (self.dirty) return;
    if (self.settle_timer == null) {
        self.settle_timer = self.server.wl_server.getEventLoop().addTimer(*Client, settled, self) catch return;
    }
    self.settle_timer.?.timerUpdate(settle_ms) catch return;
    self.dirty = true;
}

pub fn settled(self: *Client) c_int {
    self.dirty = false;
    self.reload(false);
    return 0;
}

pub fn unitRemoved(self: *Client, id: []const u8) void {
    if (!std.mem.endsWith(u8, id, ".service")) return;
    const snap = self.fresh();
    const i = snap.index.get(id) orelse return;
    markUnloaded(&snap.units.items[i]);
    // Rows move when pruned: not in a half-built list, not while timing.
    if (snap == &self.snapshot and !self.analyzing) snap.prune();
    self.changed();
}

pub fn propertiesChanged(self: *Client, object: []const u8, body: *wire.Reader) !void {
    if (!std.mem.startsWith(u8, object, path ++ "/unit/")) return;
    const on = try body.string();
    // Only an interface the table reads is worth a look.
    if (!std.mem.eql(u8, on, name ++ ".Unit") and !std.mem.eql(u8, on, name ++ ".Service")) return;
    const snap = self.fresh();
    const unit = snap.at(object) orelse return;
    var touched = false;
    var delivered: std.EnumSet(Prop) = .empty;
    var values = try body.array(8);
    while (values.offset < values.bytes.len) {
        try values.alignTo(8);
        const member = try values.string();
        const sig = try values.variant();
        if (Prop.of(on, member)) |prop| {
            delivered.insert(prop);
            if (try apply(snap, unit, prop, sig, &values)) touched = true;
        } else try values.skip(sig);
    }
    // systemd lists properties like Description as invalidated on ordinary
    // changes. Only a name the table shows live that did not arrive with its
    // value needs another look.
    var stale = try body.array(4);
    while (stale.offset < stale.bytes.len) {
        const prop = Prop.of(on, try stale.string()) orelse continue;
        if (delivered.contains(prop) or !(prop == .active or prop == .sub or prop == .service_type)) continue;
        // A new Type is part of the details, which are only read once.
        if (prop == .service_type) unit.has_details = false;
        self.markDirty();
    }
    if (touched) self.changed();
    if (self.snapshot.copied > copied_limit) self.reload(false);
}
