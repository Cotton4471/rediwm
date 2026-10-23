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
pub const name = "org.freedesktop.systemd1";
pub const path = "/org/freedesktop/systemd1";
pub const manager = name ++ ".Manager";
pub const properties = "org.freedesktop.DBus.Properties";
const edit = @import("systemd_edit.zig");
const client_live = @import("systemd/live.zig");
const client_actions = @import("systemd/actions.zig");
const client_requests = @import("systemd/requests.zig");
const client_bus = @import("systemd/bus.zig");
pub const polkit_name = "org.freedesktop.PolicyKit1";
pub const polkit_path = "/org/freedesktop/PolicyKit1/Authority";
pub const polkit_authority = polkit_name ++ ".Authority";
pub const unlock_action = "org.freedesktop.systemd1.manage-unit-files";
pub const unlock_cancellation = "rediwm-settings-services-unlock";
pub const manager_match = "type='signal',sender='" ++ name ++ "',interface='" ++ manager ++ "'";
pub const properties_match = "type='signal',sender='" ++ name ++ "',interface='" ++ properties ++ "',path_namespace='" ++ path ++ "/unit'";
/// How long an IPC query keeps the list live after its last call.
pub const lease_ms: i32 = 15000;
/// How long changes the signals could not describe are allowed to pile up before
/// the list is read again: at most one reload per this long.
pub const settle_ms: i32 = 400;
pub const max_in_flight = 8;
/// Text copied into a snapshot's arena (replaced text stays there) beyond which
/// the list is rebuilt rather than grown.
pub const copied_limit: usize = 1 << 21;

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

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    units: std.ArrayList(Unit) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Bytes copied into the arena so far, replaced text included.
    copied: usize = 0,

    pub fn deinit(s: *Snapshot) void {
        s.arena.deinit();
        s.* = .{};
    }
    pub fn copy(s: *Snapshot, value: []const u8) ![]const u8 {
        if (intern(value)) |word| return word;
        s.copied += value.len;
        return s.arena.allocator().dupe(u8, value);
    }
    pub fn get(s: *Snapshot, unit_name: []const u8) !*Unit {
        if (s.index.get(unit_name)) |i| return &s.units.items[i];
        const owned = try s.copy(unit_name);
        try s.units.append(s.arena.allocator(), .{ .name = owned });
        try s.index.put(s.arena.allocator(), owned, s.units.items.len - 1);
        return &s.units.items[s.units.items.len - 1];
    }
    /// The loaded unit at an object path, if it is one of the rows.
    pub fn at(s: *Snapshot, object: []const u8) ?*Unit {
        for (s.units.items) |*unit| if (unit.path.len > 0 and std.mem.eql(u8, unit.path, object)) return unit;
        return null;
    }
    /// Drops rows that are neither loaded nor backed by a unit file. Rows move,
    /// so never while a request holds a row's index (loading or analyzing).
    pub fn prune(s: *Snapshot) void {
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
pub fn markUnloaded(unit: *Unit) void {
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
pub const Prop = enum {
    description,
    active,
    sub,
    load,
    transient,
    trigger,
    service_type,

    pub fn interface(p: Prop) []const u8 {
        return if (p == .service_type) name ++ ".Service" else name ++ ".Unit";
    }
    pub fn key(p: Prop) []const u8 {
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
    pub fn of(on: []const u8, member: []const u8) ?Prop {
        for (std.enums.values(Prop)) |p| {
            if (std.mem.eql(u8, p.interface(), on) and std.mem.eql(u8, p.key(), member)) return p;
        }
        return null;
    }
};
/// What the table shows that ListUnits does not say.
pub const detail_props = [_]Prop{ .transient, .trigger, .service_type };

/// Sets `prop` from the value `r` is positioned at (signature `sig`), reporting
/// whether the row changed.
pub fn apply(s: *Snapshot, unit: *Unit, prop: Prop, sig: []const u8, r: *wire.Reader) !bool {
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
pub const Kind = enum { subscribe, units, files, detail, timing, boot, action, reload, unlock };
pub const Request = struct {
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
    pub fn inform(self: *Client, value: []const u8) void {
        self.message_len = @min(value.len, self.message.len);
        @memcpy(self.message[0..self.message_len], value[0..self.message_len]);
        self.changed();
    }
    pub fn changed(self: *Client) void {
        if (!self.closing) if (self.server.input.open_control_center) |cc| {
            if (cc.showingPage(.services)) cc.refresh();
        };
    }

    pub const show = client_live.show;
    pub const hide = client_live.hide;
    pub const lease = client_live.lease;
    pub const sync = client_live.sync;
    pub const startWatching = client_live.startWatching;
    pub const stopWatching = client_live.stopWatching;
    pub const subscribe = client_live.subscribe;
    pub const refresh = client_live.refresh;
    pub const reload = client_live.reload;
    pub const analyze = client_live.analyze;
    pub const detachSettings = client_live.detachSettings;

    pub const lock = client_actions.lock;
    pub const unlock = client_actions.unlock;
    pub const checkAuthorization = client_actions.checkAuthorization;
    pub const cancelUnlock = client_actions.cancelUnlock;
    pub const act = client_actions.act;
    pub const setMode = client_actions.setMode;
    pub const sendAction = client_actions.sendAction;
    pub const setType = client_actions.setType;
    pub const edited = client_actions.edited;

    pub const call = client_requests.call;
    pub const send = client_requests.send;
    pub const getAll = client_requests.getAll;
    pub const getDetail = client_requests.getDetail;
    pub const pump = client_requests.pump;
    pub const pumpTiming = client_requests.pumpTiming;
    pub const reply = client_requests.reply;
    pub const failed = client_requests.failed;
    pub const accept = client_requests.accept;
    pub const fromOwner = client_requests.fromOwner;

    pub const resetState = client_bus.resetState;
    pub const setOwner = client_bus.setOwner;
    const disconnected = client_bus.disconnected;
    const hello = client_bus.hello;
    pub const setup = client_bus.setup;
    pub const fresh = client_bus.fresh;
    pub const markDirty = client_bus.markDirty;
    pub const unitRemoved = client_bus.unitRemoved;
    pub const propertiesChanged = client_bus.propertiesChanged;
};

/// Applies ListUnitFiles to `snap`: every service file gets its startup state.
pub fn mergeFiles(snap: *Snapshot, body: *wire.Reader) !void {
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
