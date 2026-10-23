//! Unlocking through polkit and acting on units: start/stop/enable, service modes and the Type drop-in edit.

const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const gpa = @import("../main.zig").gpa;
const edit = @import("../systemd_edit.zig");
const systemd_mod = @import("../systemd.zig");
const Client = systemd_mod.Client;
const path = systemd_mod.path;
const manager = systemd_mod.manager;
const polkit_name = systemd_mod.polkit_name;
const polkit_path = systemd_mod.polkit_path;
const polkit_authority = systemd_mod.polkit_authority;
const unlock_action = systemd_mod.unlock_action;
const unlock_cancellation = systemd_mod.unlock_cancellation;
const service_types = systemd_mod.service_types;
const Unit = systemd_mod.Unit;
const Action = systemd_mod.Action;
const Request = systemd_mod.Request;
const reply = Client.reply;

pub fn lock(self: *Client) void {
    if (!self.unlocked) return;
    self.unlocked = false;
    self.changed();
}

pub fn unlock(self: *Client) void {
    if (self.unlocked or self.unlocking or !self.available()) return;
    self.unlock_generation +%= 1;
    self.unlocking = true;
    self.message_len = 0;
    self.checkAuthorization() catch {
        self.unlocking = false;
        self.inform(@import("i18n").tr("Could not start the authentication request."));
    };
    self.changed();
}

pub fn checkAuthorization(self: *Client) !void {
    const conn = self.conn orelse return error.Disconnected;
    // The subject is this connection; polkit resolves it to our process,
    // which is also what systemd reports for later calls on it.
    const unique = conn.unique_name orelse return error.Disconnected;
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    try body.alignTo(8);
    try body.string("system-bus-name");
    const subject = try body.beginArray(8);
    try body.string("name");
    try body.variant("s");
    try body.string(unique);
    try body.endArray(subject);
    try body.string(unlock_action);
    const details = try body.beginArray(8);
    try body.endArray(details);
    try body.uint32(1); // AllowUserInteraction
    try body.string(unlock_cancellation);
    const req = try gpa.create(Request);
    errdefer gpa.destroy(req);
    req.* = .{ .client = self, .generation = self.generation, .kind = .unlock, .index = self.unlock_generation };
    _ = try conn.callWithFlags(polkit_name, polkit_path, polkit_authority, "CheckAuthorization", "(sa{sv})sa{ss}us", &body, req, reply, 120000, 0);
}

/// Withdraw a pending prompt so no dialog outlives its Settings window.
/// Best effort: polkit also ignores unknown ids.
pub fn cancelUnlock(self: *Client) void {
    if (!self.unlocking) return;
    self.unlocking = false;
    const conn = self.conn orelse return;
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    body.string(unlock_cancellation) catch return;
    _ = conn.call(polkit_name, polkit_path, polkit_authority, "CancelCheckAuthorization", "s", &body, null, null, 1000) catch return;
    conn.flush() catch {};
}

pub fn act(self: *Client, unit_name: []const u8, action: Action) void {
    if (!self.unlocked or self.busy() or !self.available()) return;
    const i = self.snapshot.index.get(unit_name) orelse return;
    const unit = self.snapshot.units.items[i];
    if ((action == .enable or action == .disable) and !unit.editable()) return;
    self.action_pending = true;
    self.message_len = 0;
    self.sendAction(unit, action) catch {
        self.action_pending = false;
        self.inform(@import("i18n").tr("Could not send the service action."));
    };
    self.changed();
}

/// IPC goes through systemd's own interactive authorization on this bus.
/// Startup edits never implicitly start or stop a running service.
pub fn setMode(self: *Client, unit_name: []const u8, mode: @import("../ipc/protocol.zig").ServiceMode) !void {
    if (mode == .deferred) return error.UnsupportedServiceMode;
    if (!self.available()) return error.ServicesUnavailable;
    self.lease();
    if (self.busy() or self.awaitingList()) return error.ServicesBusy;
    const i = self.snapshot.index.get(unit_name) orelse return error.UnknownService;
    const unit = self.snapshot.units.items[i];
    if (!unit.editable()) return error.ServiceModeReadOnly;
    if (mode == .@"on-demand" and unit.trigger.len == 0) return error.ServiceHasNoTrigger;
    self.action_pending = true;
    errdefer self.action_pending = false;
    self.message_len = 0;
    try self.sendAction(unit, if (mode == .on) .enable else .disable);
    self.changed();
}

pub fn sendAction(self: *Client, unit: Unit, action: Action) !void {
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    const install = action == .enable or action == .disable;
    if (install) {
        const array = try body.beginArray(4);
        try body.string(unit.name);
        try body.endArray(array);
        try body.boolean(false);
        if (action == .enable) try body.boolean(false);
    } else {
        try body.string(unit.name);
        try body.string("replace");
    }
    const method: []const u8 = switch (action) {
        .enable => "EnableUnitFiles",
        .disable => "DisableUnitFiles",
        .start => "StartUnit",
        .stop => "StopUnit",
        .restart => "RestartUnit",
    };
    const signature: []const u8 = if (action == .enable) "asbb" else if (action == .disable) "asb" else "ss";
    try self.call(.action, @intFromBool(install), path, manager, method, signature, &body, true);
}

pub fn setType(self: *Client, unit_name: []const u8, index: usize) void {
    if (!self.unlocked or self.busy() or !self.available() or index >= service_types.len) return;
    const unit = self.snapshot.units.items[self.snapshot.index.get(unit_name) orelse return];
    if (!unit.typeEditable() or std.mem.eql(u8, unit.service_type, service_types[index])) return;
    const owned_name = gpa.dupe(u8, unit_name) catch return;
    if (self.edited_unit) |old| gpa.free(old);
    self.edited_unit = owned_name;
    self.edited_type = index;
    self.action_pending = true;
    self.message_len = 0;
    edit.start(self, unit_name, service_types[index]) catch {
        self.edited_type = null;
        self.action_pending = false;
        self.inform(@import("i18n").tr("Could not open the service edit for authorization."));
    };
    self.changed();
}

pub fn edited(self: *Client, status_code: i32) void {
    if (status_code != 0) {
        self.edited_type = null;
        self.action_pending = false;
        self.inform(if (status_code == 126 or status_code == 127)
            @import("i18n").tr("Authentication was cancelled or denied. Notify setting is unchanged.")
        else
            @import("i18n").tr("Could not save Notify. Service editing requires systemd 256 or newer."));
        self.reload(false);
        return;
    }
    const empty: wire.Writer = .{ .allocator = gpa };
    self.call(.reload, 1, path, manager, "Reload", "", &empty, true) catch {
        self.edited_type = null;
        self.action_pending = false;
        self.inform(@import("i18n").tr("Notify override saved, but systemd could not reload it. Try Refresh after a daemon reload."));
    };
    self.changed();
}
