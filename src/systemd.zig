//! Settings' systemd client. Queries and runtime actions use D-Bus; editing
//! Type uses an authorized systemctl drop-in edit, completed through eventfd.
//! All requests target the discovered unique owner; generations discard replies
//! from a previous daemon. The Settings window owns this connection.
//!
//! The client is live only while something shows its data: the Services page
//! (`show`/`hide`) or a recent IPC query (`lease`). Going live adds the signal
//! matches, calls Manager.Subscribe and loads the list; going dark removes the
//! matches, calls Unsubscribe and drops the data. A closed Settings window or a
//! page nobody looks at costs systemd and polkit nothing.
//!
//! Loading is two list calls (ListUnits, whose state fields are the rows'
//! state, and ListUnitFiles for the startup setting) plus three single-property
//! reads for each *loaded* unit, once. Unloaded units are never asked about:
//! they show the unit-file state and "Not loaded", and are never loaded on the
//! user's behalf (that needs RefUnit, which systemd checks with polkit on every
//! call; refreshing hundreds of unloaded units that way pinned PID 1 and polkitd).
//! After the load, signals update rows in place: PropertiesChanged carries the
//! new state, UnitRemoved unloads its row. Whatever a signal cannot say by itself
//! (a unit that appeared, a name that was only invalidated, new unit files, a
//! finished daemon reload) marks the list dirty, and one reload runs after a short
//! settling time, however many signals arrive. systemd broadcasts thousands of
//! UnitNew/UnitRemoved a second while anything loads units in bulk, so no signal
//! may cost a call of its own. Nothing polls.
//!
//! Changes are locked until the user unlocks them: that asks polkit once for
//! manage-unit-files, whose `imply` annotation also covers manage-units and
//! reload-daemon, so later enable/disable/start/stop/restart calls reuse the
//! retained authorization instead of prompting again. The lock is a session
//! gate in the UI and in `act`/`setType`; polkit still decides every request.
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const wl = @import("wayland").server.wl;
const gpa = @import("main.zig").gpa;
const panel = @import("control_center/panel.zig");
const name = "org.freedesktop.systemd1";
const path = "/org/freedesktop/systemd1";
const manager = name ++ ".Manager";
const properties = "org.freedesktop.DBus.Properties";
const edit = @import("systemd_edit.zig");
const polkit_name = "org.freedesktop.PolicyKit1";
const polkit_path = "/org/freedesktop/PolicyKit1/Authority";
const polkit_authority = polkit_name ++ ".Authority";
const unlock_action = "org.freedesktop.systemd1.manage-unit-files";
const unlock_cancellation = "rediwm-settings-services-unlock";
const manager_match = "type='signal',sender='" ++ name ++ "',interface='" ++ manager ++ "'";
const properties_match = "type='signal',sender='" ++ name ++ "',interface='" ++ properties ++ "',path_namespace='" ++ path ++ "/unit'";
/// How long an IPC query keeps the list live after its last call.
const lease_ms: i32 = 15000;
/// How long changes the signals could not describe are allowed to pile up before
/// the list is read again: at most one reload per this long.
const settle_ms: i32 = 400;
const max_in_flight = 8;
/// Text copied into a snapshot's arena (replaced text stays there) beyond which
/// the list is rebuilt rather than grown.
const copied_limit: usize = 1 << 21;

pub const service_types: []const []const u8 = &.{ "exec", "dbus", "simple", "forking", "notify", "oneshot", "idle", "notify-reload" };

pub fn typeIndex(value: []const u8) ?usize {
    for (service_types, 0..) |candidate, i| if (std.mem.eql(u8, value, candidate)) return i;
    return null;
}

pub const Unit = struct {
    name: []const u8,
    description: []const u8 = "Not loaded",
    path: []const u8 = "",
    active: []const u8 = "inactive",
    sub: []const u8 = "dead",
    load: []const u8 = "unloaded",
    startup: []const u8 = "unknown",
    service_type: []const u8 = "",
    transient: bool = false,
    trigger: []const u8 = "",
    time_us: ?u64 = null,
    /// Type, Transient and TriggeredBy were requested for this loaded unit.
    has_details: bool = false,

    pub fn enabled(u: Unit) bool {
        return std.mem.eql(u8, u.startup, "enabled") or std.mem.eql(u8, u.startup, "enabled-runtime");
    }
    pub fn editable(u: Unit) bool {
        return u.enabled() or std.mem.eql(u8, u.startup, "disabled");
    }
    pub fn typeEditable(u: Unit) bool {
        return u.service_type.len > 0 and std.mem.eql(u8, u.load, "loaded") and
            !std.mem.startsWith(u8, u.startup, "masked") and
            !u.transient and !std.mem.eql(u8, u.startup, "transient");
    }
};

/// What systemd reports for state, load and startup, as static text. Rows hold
/// these instead of copies, so a service that flips between states all day adds
/// nothing to the arena.
const words = [_][]const u8{
    "active",       "inactive",     "failed",       "activating",   "deactivating",  "reloading",       "maintenance",
    "refreshing",   "loaded",       "not-found",    "bad-setting",  "error",         "masked",          "merged",
    "stub",         "unloaded",     "running",      "exited",       "dead",          "start",           "stop",
    "start-pre",    "start-post",   "stop-sigterm", "stop-sigkill", "stop-post",     "final-sigterm",   "final-sigkill",
    "auto-restart", "condition",    "reload",       "cleaning",     "enabled",       "disabled",        "static",
    "indirect",     "generated",    "transient",    "alias",        "linked",        "enabled-runtime", "masked-runtime",
    "linked-runtime", "bad",        "unknown",
};
fn intern(value: []const u8) ?[]const u8 {
    for (words) |word| if (std.mem.eql(u8, word, value)) return word;
    return null;
}

const Snapshot = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    units: std.ArrayList(Unit) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Bytes copied into the arena so far, replaced text included.
    copied: usize = 0,

    fn deinit(s: *Snapshot) void {
        s.arena.deinit();
        s.* = .{};
    }
    fn copy(s: *Snapshot, value: []const u8) ![]const u8 {
        if (intern(value)) |word| return word;
        s.copied += value.len;
        return s.arena.allocator().dupe(u8, value);
    }
    fn get(s: *Snapshot, unit_name: []const u8) !*Unit {
        if (s.index.get(unit_name)) |i| return &s.units.items[i];
        const owned = try s.copy(unit_name);
        try s.units.append(s.arena.allocator(), .{ .name = owned });
        try s.index.put(s.arena.allocator(), owned, s.units.items.len - 1);
        return &s.units.items[s.units.items.len - 1];
    }
    /// The loaded unit at an object path, if it is one of the rows.
    fn at(s: *Snapshot, object: []const u8) ?*Unit {
        for (s.units.items) |*unit| if (unit.path.len > 0 and std.mem.eql(u8, unit.path, object)) return unit;
        return null;
    }
    /// Drops rows that are neither loaded nor backed by a unit file. Rows move,
    /// so never while a request holds a row's index (loading or analyzing).
    fn prune(s: *Snapshot) void {
        var kept: usize = 0;
        for (s.units.items) |unit| {
            if (unit.path.len == 0 and std.mem.eql(u8, unit.startup, "unknown")) continue;
            s.units.items[kept] = unit;
            kept += 1;
        }
        if (kept == s.units.items.len) return;
        s.units.items.len = kept;
        s.index.clearRetainingCapacity();
        for (s.units.items, 0..) |unit, i| s.index.putAssumeCapacity(unit.name, i);
    }
};

/// A unit that is not loaded: what ListUnitFiles alone says about it.
fn markUnloaded(unit: *Unit) void {
    unit.path = "";
    unit.description = "Not loaded";
    unit.load = "unloaded";
    unit.active = "inactive";
    unit.sub = "dead";
    unit.service_type = "";
    unit.trigger = "";
    unit.transient = false;
    unit.has_details = false;
}

/// One readable property of a loaded unit, with where it lives on the bus.
const Prop = enum {
    description,
    active,
    sub,
    load,
    transient,
    trigger,
    service_type,

    fn interface(p: Prop) []const u8 {
        return if (p == .service_type) name ++ ".Service" else name ++ ".Unit";
    }
    fn key(p: Prop) []const u8 {
        return switch (p) {
            .description => "Description",
            .active => "ActiveState",
            .sub => "SubState",
            .load => "LoadState",
            .transient => "Transient",
            .trigger => "TriggeredBy",
            .service_type => "Type",
        };
    }
    fn signature(p: Prop) []const u8 {
        return switch (p) {
            .transient => "b",
            .trigger => "as",
            else => "s",
        };
    }
    fn of(on: []const u8, member: []const u8) ?Prop {
        for (std.enums.values(Prop)) |p| {
            if (std.mem.eql(u8, p.interface(), on) and std.mem.eql(u8, p.key(), member)) return p;
        }
        return null;
    }
};
/// What the table shows that ListUnits does not say.
const detail_props = [_]Prop{ .transient, .trigger, .service_type };

/// Sets `prop` from the value `r` is positioned at (signature `sig`), reporting
/// whether the row changed.
fn apply(s: *Snapshot, unit: *Unit, prop: Prop, sig: []const u8, r: *wire.Reader) !bool {
    if (!std.mem.eql(u8, sig, prop.signature())) {
        try r.skip(sig);
        return false;
    }
    switch (prop) {
        .transient => {
            const value = try r.boolean();
            const differs = unit.transient != value;
            unit.transient = value;
            return differs;
        },
        .trigger => {
            var items = try r.array(4);
            var joined: std.ArrayList(u8) = .empty;
            const a = s.arena.allocator();
            while (items.offset < items.bytes.len) {
                const trigger = try items.string();
                if (joined.items.len > 0) try joined.appendSlice(a, ", ");
                try joined.appendSlice(a, trigger);
            }
            if (std.mem.eql(u8, unit.trigger, joined.items)) return false;
            s.copied += joined.items.len;
            unit.trigger = joined.items;
            return true;
        },
        else => {
            const value = try r.string();
            const field: *[]const u8 = switch (prop) {
                .description => &unit.description,
                .active => &unit.active,
                .sub => &unit.sub,
                .load => &unit.load,
                else => &unit.service_type,
            };
            if (std.mem.eql(u8, field.*, value)) return false;
            field.* = try s.copy(value);
            return true;
        },
    }
}

pub const Action = enum { enable, disable, start, stop, restart };
const Kind = enum { subscribe, units, files, detail, timing, boot, action, reload, unlock };
const Request = struct {
    client: *Client,
    generation: u64,
    kind: Kind,
    index: usize = 0,
    prop: Prop = .transient,
};

pub const Client = struct {
    server: *@import("Server.zig"),
    conn: ?*dbus.Connection = null,
    owner: ?[]u8 = null,
    generation: u64 = 0,
    closing: bool = false,
    /// The Services page is on screen.
    visible: bool = false,
    /// An IPC query asked recently; `lease_timer` ends it.
    leased: bool = false,
    lease_timer: ?*wl.EventSource = null,
    /// Signals reported changes only a new list can describe; `settle_timer` runs it.
    dirty: bool = false,
    settle_timer: ?*wl.EventSource = null,
    /// Matches added and Subscribe sent: exactly while visible or leased.
    watching: bool = false,
    subscribed: bool = false,
    snapshot: Snapshot = .{},
    staging: Snapshot = .{},
    loading: bool = false,
    /// ListUnits has been merged into `staging`: it is the freshest data there is.
    staging_listed: bool = false,
    /// A full load re-reads every loaded unit's details, not only new ones.
    force_details: bool = false,
    analyzing: bool = false,
    analyzed: bool = false,
    boot_pending: bool = false,
    action_pending: bool = false,
    unlocked: bool = false,
    unlocking: bool = false,
    unlock_generation: usize = 0,
    edit_request: ?*edit.Request = null,
    edited_unit: ?[]u8 = null,
    edited_type: ?usize = null,
    action_job: ?[]u8 = null,
    /// Something changed while a load or analysis was running.
    again: bool = false,
    again_force: bool = false,
    next_detail: usize = 0,
    next_step: usize = 0,
    pending_details: usize = 0,
    boot_us: ?u64 = null,
    message: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn create(server: *@import("Server.zig")) !*Client {
        const self = try gpa.create(Client);
        self.* = .{ .server = server };
        errdefer gpa.destroy(self);
        const conn = try dbus.Connection.openSystem(gpa, server.wl_server.getEventLoop(), server.environ);
        self.conn = conn;
        errdefer conn.destroy();
        _ = try conn.hello(self, hello);
        conn.on_disconnect = .{ .owner = self, .callback = disconnected };
        return self;
    }
    pub fn destroy(self: *Client) void {
        self.closing = true;
        edit.cancel(self);
        self.cancelUnlock();
        if (self.lease_timer) |timer| timer.remove();
        if (self.settle_timer) |timer| timer.remove();
        if (self.edited_unit) |unit| gpa.free(unit);
        if (self.conn) |conn| conn.destroy();
        if (self.owner) |old| gpa.free(old);
        if (self.action_job) |job| gpa.free(job);
        self.snapshot.deinit();
        self.staging.deinit();
        gpa.destroy(self);
    }
    pub fn available(self: *const Client) bool {
        return self.owner != null;
    }
    pub fn busy(self: *const Client) bool {
        return self.loading or self.analyzing or self.action_pending;
    }
    pub fn status(self: *const Client) []const u8 {
        return self.message[0..self.message_len];
    }
    /// True until the first list arrives: nothing to show yet and no failure.
    pub fn awaitingList(self: *const Client) bool {
        if (self.snapshot.units.items.len > 0) return false;
        return self.loading or (!self.subscribed and self.message_len == 0);
    }
    fn inform(self: *Client, value: []const u8) void {
        self.message_len = @min(value.len, self.message.len);
        @memcpy(self.message[0..self.message_len], value[0..self.message_len]);
        self.changed();
    }
    fn changed(self: *Client) void {
        if (!self.closing) if (self.server.input.open_control_center) |cc| {
            if (cc.page == .services) cc.refresh();
        };
    }
    /// The Services page is on screen: go live. Idempotent; the page calls it
    /// on every build.
    pub fn show(self: *Client) void {
        self.visible = true;
        self.sync();
    }
    /// The page was left or Settings closed.
    pub fn hide(self: *Client) void {
        self.visible = false;
        self.sync();
    }
    /// An IPC reader is not a page: keep the list live for a while after each
    /// query, then let it go.
    pub fn lease(self: *Client) void {
        if (self.lease_timer == null) {
            self.lease_timer = self.server.wl_server.getEventLoop().addTimer(*Client, leaseExpired, self) catch return;
        }
        self.lease_timer.?.timerUpdate(lease_ms) catch return;
        self.leased = true;
        self.sync();
    }
    fn leaseExpired(self: *Client) c_int {
        self.leased = false;
        self.sync();
        return 0;
    }
    /// Live exactly while a page or a lease wants the data. Going live waits for
    /// systemd to be found; `setOwner` calls this again then.
    fn sync(self: *Client) void {
        const wanted = (self.visible or self.leased) and !self.closing;
        if (wanted == self.watching) return;
        if (wanted) {
            if (self.available()) self.startWatching();
        } else self.stopWatching();
    }
    fn startWatching(self: *Client) void {
        const conn = self.conn orelse return;
        self.watching = true;
        _ = conn.addMatch(manager_match, null, null) catch {
            self.inform("Could not subscribe to service updates.");
            return;
        };
        _ = conn.addMatch(properties_match, null, null) catch {
            self.inform("Could not subscribe to service updates.");
            return;
        };
        self.subscribe() catch self.inform("Could not subscribe to service updates.");
    }
    fn stopWatching(self: *Client) void {
        self.watching = false;
        if (self.conn) |conn| {
            _ = conn.removeMatch(manager_match, null, null) catch {};
            _ = conn.removeMatch(properties_match, null, null) catch {};
            // Whether or not the Subscribe reply landed: systemd keeps a subscriber
            // until it unsubscribes or disconnects, and a second Subscribe is an error.
            if (self.owner) |owner| {
                const body: wire.Writer = .{ .allocator = gpa };
                _ = conn.call(owner, path, manager, "Unsubscribe", "", &body, null, null, 5000) catch {};
            }
        }
        self.resetState();
    }
    fn subscribe(self: *Client) !void {
        const body: wire.Writer = .{ .allocator = gpa };
        try self.call(.subscribe, 0, path, manager, "Subscribe", "", &body, false);
    }
    /// Re-reads everything, details included: the user asked, or systemd reloaded.
    pub fn refresh(self: *Client) void {
        self.reload(true);
    }
    /// Lists units and unit files again; details are only read for loaded units
    /// that have none yet, unless `force`.
    fn reload(self: *Client, force: bool) void {
        if (!self.available() or !self.subscribed) return;
        if (self.busy()) {
            self.again = true;
            self.again_force = self.again_force or force;
            return;
        }
        self.again = false;
        self.again_force = false;
        self.loading = true;
        self.force_details = force;
        self.staging.deinit();
        self.staging_listed = false;
        self.next_detail = 0;
        self.next_step = 0;
        self.pending_details = 0;
        const body: wire.Writer = .{ .allocator = gpa };
        self.call(.units, 0, path, manager, "ListUnits", "", &body, false) catch {
            self.loading = false;
            self.inform("Could not load services. Try Refresh.");
        };
        self.changed();
    }
    pub fn analyze(self: *Client) void {
        if (self.busy() or !self.available()) return;
        self.analyzing = true;
        self.analyzed = false;
        self.boot_us = null;
        self.message_len = 0;
        self.next_detail = 0;
        self.pending_details = 0;
        for (self.snapshot.units.items) |*unit| unit.time_us = null;
        self.boot_pending = true;
        self.getAll(.boot, 0, path, manager) catch {
            self.boot_pending = false;
            self.inform("Boot summary is unavailable.");
        };
        self.pumpTiming();
        self.changed();
    }
    pub fn detachSettings(self: *Client) void {
        self.cancelUnlock();
        self.lock();
        const editing = self.edit_request != null;
        if (editing) {
            edit.cancel(self);
            self.action_pending = false;
            self.edited_type = null;
        }
        self.visible = false;
        self.sync();
        if (editing and self.watching) self.reload(false);
    }
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
            self.inform("Could not start the authentication request.");
        };
        self.changed();
    }
    fn checkAuthorization(self: *Client) !void {
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
    fn cancelUnlock(self: *Client) void {
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
            self.inform("Could not send the service action.");
        };
        self.changed();
    }
    /// IPC goes through systemd's own interactive authorization on this bus.
    /// Startup edits never implicitly start or stop a running service.
    pub fn setMode(self: *Client, unit_name: []const u8, mode: @import("ipc/protocol.zig").ServiceMode) !void {
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
    fn sendAction(self: *Client, unit: Unit, action: Action) !void {
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
            self.inform("Could not open the service edit for authorization.");
        };
        self.changed();
    }
    pub fn edited(self: *Client, status_code: i32) void {
        if (status_code != 0) {
            self.edited_type = null;
            self.action_pending = false;
            self.inform(if (status_code == 126 or status_code == 127)
                "Authentication was cancelled or denied. Notify setting is unchanged."
            else
                "Could not save Notify. Service editing requires systemd 256 or newer.");
            self.reload(false);
            return;
        }
        const empty: wire.Writer = .{ .allocator = gpa };
        self.call(.reload, 1, path, manager, "Reload", "", &empty, true) catch {
            self.edited_type = null;
            self.action_pending = false;
            self.inform("Notify override saved, but systemd could not reload it. Try Refresh after a daemon reload.");
        };
        self.changed();
    }
    fn call(self: *Client, kind: Kind, index: usize, object: []const u8, interface: []const u8, method: []const u8, signature: []const u8, body: *const wire.Writer, auth: bool) !void {
        return self.send(.{ .client = self, .generation = self.generation, .kind = kind, .index = index }, object, interface, method, signature, body, auth);
    }
    fn send(self: *Client, template: Request, object: []const u8, interface: []const u8, method: []const u8, signature: []const u8, body: *const wire.Writer, auth: bool) !void {
        const destination = self.owner orelse return error.Disconnected;
        const req = try gpa.create(Request);
        errdefer gpa.destroy(req);
        req.* = template;
        _ = try self.conn.?.callWithFlags(destination, object, interface, method, signature, body, req, reply, if (auth) 120000 else 10000, if (auth) wire.flag_allow_interactive_authorization else 0);
    }
    fn getAll(self: *Client, kind: Kind, index: usize, object: []const u8, interface: []const u8) !void {
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        try body.string(interface);
        try self.call(kind, index, object, properties, "GetAll", "s", &body, false);
    }
    /// One property of the loaded unit at `index` of `staging`.
    fn getDetail(self: *Client, index: usize, object: []const u8, prop: Prop) !void {
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        try body.string(prop.interface());
        try body.string(prop.key());
        try self.send(.{ .client = self, .generation = self.generation, .kind = .detail, .index = index, .prop = prop }, object, properties, "Get", "ss", &body, false);
    }
    /// Reads the details of the next loaded units still lacking them, a few at a
    /// time, and swaps the finished list in. Unloaded units are skipped: nothing
    /// is asked of a unit systemd has not loaded.
    fn pump(self: *Client) void {
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
                self.inform("Notify override saved, but the selected type is not active in systemd. Check other service overrides.");
        }
        self.changed();
        if (self.again) self.reload(self.again_force);
    }
    /// Startup times for the loaded units, on request.
    fn pumpTiming(self: *Client) void {
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
    fn reply(ctx: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
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
    fn failed(self: *Client, req: *const Request, reason: []const u8) void {
        switch (req.kind) {
            .unlock => {
                self.unlocking = false;
                self.inform("Could not request authentication. Check that polkit is running.");
            },
            .detail => {
                // Not every loaded unit has every property (a masked service has no Type).
                self.pending_details -= 1;
                self.pump();
            },
            .timing => {
                self.pending_details -= 1;
                self.inform("Some startup times are unavailable.");
                self.pumpTiming();
            },
            .boot => {
                self.boot_pending = false;
                self.inform("Boot summary is unavailable.");
                self.pumpTiming();
            },
            .action, .reload => {
                self.action_pending = false;
                if (req.kind == .reload and req.index == 1) {
                    self.edited_type = null;
                    self.inform("Notify override saved, but systemd could not reload it. Try Refresh after a daemon reload.");
                } else self.inform(reason);
                self.reload(false);
            },
            else => {
                self.loading = false;
                self.inform(reason);
            },
        }
    }
    fn accept(self: *Client, req: *const Request, msg: wire.Message) !void {
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
                    self.inform("Request accepted. Status updates when the job completes.");
                }
            },
            .unlock => {
                if (!self.unlocking or req.index != self.unlock_generation) return;
                if (!std.mem.eql(u8, msg.headers.signature, "(bba{ss})")) return error.InvalidMessage;
                try body.alignTo(8);
                const authorized = try body.boolean();
                self.unlocking = false;
                self.unlocked = authorized;
                if (authorized) self.changed() else self.inform("Authentication was cancelled or denied.");
            },
            .reload => {
                self.action_pending = false;
                self.inform(if (req.index == 1) "Notify setting saved. Applies on the next service start." else "Startup setting saved. Running status is unchanged.");
                self.reload(true);
            },
        }
    }
    fn fromOwner(self: *Client, msg: wire.Message) bool {
        return std.mem.eql(u8, self.owner orelse return false, msg.headers.sender orelse return false);
    }
    /// Forgets everything read from systemd and everything still on its way.
    fn resetState(self: *Client) void {
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
    fn setOwner(self: *Client, unique: []const u8) void {
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
    fn disconnected(ctx: ?*anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ctx orelse return));
        if (!self.closing) self.setOwner("");
    }
    fn hello(ctx: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Client = @ptrCast(@alignCast(ctx orelse return));
        if (self.closing) return;
        const msg = result catch return;
        if (msg.kind != .method_return) return;
        self.setup(conn) catch self.inform("Could not connect to systemd.");
    }
    fn setup(self: *Client, conn: *dbus.Connection) !void {
        try conn.registerSignal(.{ .owner = self, .callback = signal });
        // Only the owner of the name is tracked until the page asks for more.
        _ = try conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ name ++ "'", null, null);
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        try body.string(name);
        _ = try conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &body, self, discovered, 5000);
    }
    fn discovered(ctx: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Client = @ptrCast(@alignCast(ctx orelse return));
        if (self.closing or self.generation != 0) return;
        var msg = result catch return;
        if (msg.kind != .method_return) return;
        self.setOwner(msg.body.string() catch return);
    }
    fn signal(ctx: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
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
    fn fresh(self: *Client) *Snapshot {
        return if (self.loading and self.staging_listed) &self.staging else &self.snapshot;
    }
    /// Something changed that a signal cannot describe. Read the list again after
    /// a settling time, once however many signals ask.
    fn markDirty(self: *Client) void {
        if (self.dirty) return;
        if (self.settle_timer == null) {
            self.settle_timer = self.server.wl_server.getEventLoop().addTimer(*Client, settled, self) catch return;
        }
        self.settle_timer.?.timerUpdate(settle_ms) catch return;
        self.dirty = true;
    }
    fn settled(self: *Client) c_int {
        self.dirty = false;
        self.reload(false);
        return 0;
    }
    fn unitRemoved(self: *Client, id: []const u8) void {
        if (!std.mem.endsWith(u8, id, ".service")) return;
        const snap = self.fresh();
        const i = snap.index.get(id) orelse return;
        markUnloaded(&snap.units.items[i]);
        // Rows move when pruned: not in a half-built list, not while timing.
        if (snap == &self.snapshot and !self.analyzing) snap.prune();
        self.changed();
    }
    fn propertiesChanged(self: *Client, object: []const u8, body: *wire.Reader) !void {
        if (!std.mem.startsWith(u8, object, path ++ "/unit/")) return;
        const on = try body.string();
        // Only an interface the table reads is worth a look.
        if (!std.mem.eql(u8, on, name ++ ".Unit") and !std.mem.eql(u8, on, name ++ ".Service")) return;
        const snap = self.fresh();
        const unit = snap.at(object) orelse return;
        var touched = false;
        var delivered: std.EnumSet(Prop) = .initEmpty();
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
};

/// Applies ListUnitFiles to `snap`: every service file gets its startup state.
fn mergeFiles(snap: *Snapshot, body: *wire.Reader) !void {
    var array = try body.array(8);
    while (array.offset < array.bytes.len) {
        try array.alignTo(8);
        const id = std.fs.path.basename(try array.string());
        const state = try array.string();
        if (!std.mem.endsWith(u8, id, ".service")) continue;
        const unit = try snap.get(id);
        unit.startup = try snap.copy(state);
    }
}
