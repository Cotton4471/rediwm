//! The request pipeline: queued calls, pumping, replies, failures and folding results into the snapshot.

const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const gpa = @import("../main.zig").gpa;
const systemd_mod = @import("../systemd.zig");
const Client = systemd_mod.Client;
const name = systemd_mod.name;
const path = systemd_mod.path;
const manager = systemd_mod.manager;
const properties = systemd_mod.properties;
const max_in_flight = systemd_mod.max_in_flight;
const service_types = systemd_mod.service_types;
const Prop = systemd_mod.Prop;
const detail_props = systemd_mod.detail_props;
const apply = systemd_mod.apply;
const Kind = systemd_mod.Kind;
const Request = systemd_mod.Request;
const mergeFiles = systemd_mod.mergeFiles;

pub fn call(self: *Client, kind: Kind, index: usize, object: []const u8, interface: []const u8, method: []const u8, signature: []const u8, body: *const wire.Writer, auth: bool) !void {
    return self.send(.{ .client = self, .generation = self.generation, .kind = kind, .index = index }, object, interface, method, signature, body, auth);
}

pub fn send(self: *Client, template: Request, object: []const u8, interface: []const u8, method: []const u8, signature: []const u8, body: *const wire.Writer, auth: bool) !void {
    const destination = self.owner orelse return error.Disconnected;
    const req = try gpa.create(Request);
    errdefer gpa.destroy(req);
    req.* = template;
    _ = try self.conn.?.callWithFlags(destination, object, interface, method, signature, body, req, reply, if (auth) 120000 else 10000, if (auth) wire.flag_allow_interactive_authorization else 0);
}

pub fn getAll(self: *Client, kind: Kind, index: usize, object: []const u8, interface: []const u8) !void {
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    try body.string(interface);
    try self.call(kind, index, object, properties, "GetAll", "s", &body, false);
}

/// One property of the loaded unit at `index` of `staging`.
pub fn getDetail(self: *Client, index: usize, object: []const u8, prop: Prop) !void {
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    try body.string(prop.interface());
    try body.string(prop.key());
    try self.send(.{ .client = self, .generation = self.generation, .kind = .detail, .index = index, .prop = prop }, object, properties, "Get", "ss", &body, false);
}

/// Reads the details of the next loaded units still lacking them, a few at a
/// time, and swaps the finished list in. Unloaded units are skipped: nothing
/// is asked of a unit systemd has not loaded.
pub fn pump(self: *Client) void {
    const units = self.staging.units.items;
    while (self.pending_details < max_in_flight and self.next_detail < units.len) {
        const i = self.next_detail;
        const unit = &units[i];
        if (self.next_step == 0 and (unit.path.len == 0 or unit.has_details)) {
            self.next_detail += 1;
            continue;
        }
        const prop = detail_props[self.next_step];
        self.next_step += 1;
        if (self.next_step == detail_props.len) {
            self.next_step = 0;
            self.next_detail += 1;
        }
        unit.has_details = true;
        self.getDetail(i, unit.path, prop) catch continue;
        self.pending_details += 1;
    }
    if (self.pending_details != 0) return;
    for (self.staging.units.items) |*unit| {
        if (self.snapshot.index.get(unit.name)) |i| unit.time_us = self.snapshot.units.items[i].time_us;
    }
    self.snapshot.deinit();
    self.snapshot = self.staging;
    self.staging = .{};
    self.staging_listed = false;
    self.loading = false;
    // Units that unloaded during the load and have no file are done with.
    self.snapshot.prune();
    if (self.edited_type) |expected| {
        self.edited_type = null;
        const i = self.snapshot.index.get(self.edited_unit.?);
        if (i == null or !std.mem.eql(u8, self.snapshot.units.items[i.?].service_type, service_types[expected]))
            self.inform(@import("i18n").tr("Notify override saved, but the selected type is not active in systemd. Check other service overrides."));
    }
    self.changed();
    if (self.again) self.reload(self.again_force);
}

/// Startup times for the loaded units, on request.
pub fn pumpTiming(self: *Client) void {
    const units = self.snapshot.units.items;
    while (self.pending_details < 4 and self.next_detail < units.len) {
        const i = self.next_detail;
        self.next_detail += 1;
        if (units[i].path.len == 0) continue;
        self.getAll(.timing, i, units[i].path, name ++ ".Unit") catch continue;
        self.pending_details += 1;
    }
    if (self.pending_details != 0 or self.boot_pending) return;
    self.analyzing = false;
    self.analyzed = true;
    self.snapshot.prune();
    self.changed();
    if (self.again) self.reload(self.again_force);
}

pub fn reply(ctx: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req: *Request = @ptrCast(@alignCast(ctx orelse return));
    defer gpa.destroy(req);
    const self = req.client;
    if (self.closing or req.generation != self.generation) return;
    const msg = result catch {
        self.failed(req, "Service request timed out or the connection was lost.");
        return;
    };
    if (msg.kind == .error_reply) {
        const error_name = msg.headers.error_name orelse "Service request failed.";
        // Left over from an earlier visit that never unsubscribed: still subscribed.
        if (req.kind == .subscribe and std.mem.eql(u8, error_name, name ++ ".AlreadySubscribed")) {
            self.accept(req, msg) catch {};
            return;
        }
        self.failed(req, error_name);
        return;
    }
    // polkit answers the unlock check; everything else must be systemd.
    if (req.kind != .unlock and !self.fromOwner(msg)) return;
    self.accept(req, msg) catch self.failed(req, "Could not read the systemd response.");
}

pub fn failed(self: *Client, req: *const Request, reason: []const u8) void {
    switch (req.kind) {
        .unlock => {
            self.unlocking = false;
            self.inform(@import("i18n").tr("Could not request authentication. Check that polkit is running."));
        },
        .detail => {
            // Not every loaded unit has every property (a masked service has no Type).
            self.pending_details -= 1;
            self.pump();
        },
        .timing => {
            self.pending_details -= 1;
            self.inform(@import("i18n").tr("Some startup times are unavailable."));
            self.pumpTiming();
        },
        .boot => {
            self.boot_pending = false;
            self.inform(@import("i18n").tr("Boot summary is unavailable."));
            self.pumpTiming();
        },
        .action, .reload => {
            self.action_pending = false;
            if (req.kind == .reload and req.index == 1) {
                self.edited_type = null;
                self.inform(@import("i18n").tr("Notify override saved, but systemd could not reload it. Try Refresh after a daemon reload."));
            } else self.inform(reason);
            self.reload(false);
        },
        else => {
            self.loading = false;
            self.inform(reason);
        },
    }
}

pub fn accept(self: *Client, req: *const Request, msg: wire.Message) !void {
    var body = msg.body;
    switch (req.kind) {
        .subscribe => {
            self.subscribed = true;
            self.reload(true);
        },
        .units => {
            if (!std.mem.eql(u8, msg.headers.signature, "a(ssssssouso)")) return error.InvalidMessage;
            var array = try body.array(8);
            while (array.offset < array.bytes.len) {
                try array.alignTo(8);
                const id = try array.string();
                const description = try array.string();
                const load_state = try array.string();
                const active = try array.string();
                const sub = try array.string();
                _ = try array.string();
                const object = try array.string();
                _ = try array.uint32();
                _ = try array.string();
                _ = try array.string();
                if (!std.mem.endsWith(u8, id, ".service")) continue;
                const unit = try self.staging.get(id);
                unit.description = try self.staging.copy(description);
                unit.load = try self.staging.copy(load_state);
                unit.active = try self.staging.copy(active);
                unit.sub = try self.staging.copy(sub);
                unit.path = try self.staging.copy(object);
            }
            self.staging_listed = true;
            const empty: wire.Writer = .{ .allocator = gpa };
            try self.call(.files, 0, path, manager, "ListUnitFiles", "", &empty, false);
        },
        .files => {
            if (!std.mem.eql(u8, msg.headers.signature, "a(ss)")) return error.InvalidMessage;
            try mergeFiles(&self.staging, &body);
            // What the last list learned about a still-loaded unit stands
            // until systemd reloads or the user refreshes.
            if (!self.force_details) for (self.staging.units.items) |*unit| {
                const i = self.snapshot.index.get(unit.name) orelse continue;
                const old = self.snapshot.units.items[i];
                if (!old.has_details or unit.path.len == 0 or !std.mem.eql(u8, old.path, unit.path)) continue;
                unit.service_type = try self.staging.copy(old.service_type);
                unit.trigger = try self.staging.copy(old.trigger);
                unit.transient = old.transient;
                unit.has_details = true;
            };
            self.next_detail = 0;
            self.next_step = 0;
            self.pending_details = 0;
            self.pump();
        },
        .detail => {
            if (!std.mem.eql(u8, msg.headers.signature, "v")) return error.InvalidMessage;
            const sig = try body.variant();
            if (req.index < self.staging.units.items.len)
                _ = try apply(&self.staging, &self.staging.units.items[req.index], req.prop, sig, &body);
            self.pending_details -= 1;
            self.pump();
        },
        .timing, .boot => {
            if (!std.mem.eql(u8, msg.headers.signature, "a{sv}")) return error.InvalidMessage;
            var entries = try body.array(8);
            var start: u64 = 0;
            var end: u64 = 0;
            while (entries.offset < entries.bytes.len) {
                try entries.alignTo(8);
                const key = try entries.string();
                const sig = try entries.variant();
                if (std.mem.eql(u8, sig, "t")) {
                    const value = try entries.uint64();
                    if (std.mem.eql(u8, key, "InactiveExitTimestampMonotonic")) start = value;
                    if (std.mem.eql(u8, key, "ActiveEnterTimestampMonotonic")) end = value;
                    if (req.kind == .boot and std.mem.eql(u8, key, "FinishTimestampMonotonic")) self.boot_us = if (value > 0) value else null;
                } else try entries.skip(sig);
            }
            if (req.kind == .boot) {
                self.boot_pending = false;
            } else {
                if (req.index < self.snapshot.units.items.len)
                    self.snapshot.units.items[req.index].time_us = if (start > 0 and end > start) end - start else null;
                self.pending_details -= 1;
            }
            self.pumpTiming();
        },
        .action => {
            if (req.index == 1) {
                const empty: wire.Writer = .{ .allocator = gpa };
                try self.call(.reload, 0, path, manager, "Reload", "", &empty, true);
            } else {
                if (self.action_job) |job| gpa.free(job);
                self.action_job = null;
                self.action_job = try gpa.dupe(u8, try body.string());
                self.action_pending = false;
                // The unit's new state arrives as a signal.
                self.inform(@import("i18n").tr("Request accepted. Status updates when the job completes."));
            }
        },
        .unlock => {
            if (!self.unlocking or req.index != self.unlock_generation) return;
            if (!std.mem.eql(u8, msg.headers.signature, "(bba{ss})")) return error.InvalidMessage;
            try body.alignTo(8);
            const authorized = try body.boolean();
            self.unlocking = false;
            self.unlocked = authorized;
            if (authorized) self.changed() else self.inform(@import("i18n").tr("Authentication was cancelled or denied."));
        },
        .reload => {
            self.action_pending = false;
            self.inform(if (req.index == 1) @import("i18n").tr("Notify setting saved. Applies on the next service start.") else @import("i18n").tr("Startup setting saved. Running status is unchanged."));
            self.reload(true);
        },
    }
}

pub fn fromOwner(self: *Client, msg: wire.Message) bool {
    return std.mem.eql(u8, self.owner orelse return false, msg.headers.sender orelse return false);
}
