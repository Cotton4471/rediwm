//! Going live and dark: show, hide and the IPC lease, signal matches and Subscribe, refresh, reload, boot analysis and detaching from Settings.

const dbus = @import("dbus");
const wire = dbus.wire;
const gpa = @import("../main.zig").gpa;
const edit = @import("../systemd_edit.zig");
const systemd_mod = @import("../systemd.zig");
const Client = systemd_mod.Client;
const path = systemd_mod.path;
const manager = systemd_mod.manager;
const manager_match = systemd_mod.manager_match;
const properties_match = systemd_mod.properties_match;
const lease_ms = systemd_mod.lease_ms;

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

pub fn leaseExpired(self: *Client) c_int {
    self.leased = false;
    self.sync();
    return 0;
}

/// Live exactly while a page or a lease wants the data. Going live waits for
/// systemd to be found; `setOwner` calls this again then.
pub fn sync(self: *Client) void {
    const wanted = (self.visible or self.leased) and !self.closing;
    if (wanted == self.watching) return;
    if (wanted) {
        if (self.available()) self.startWatching();
    } else self.stopWatching();
}

pub fn startWatching(self: *Client) void {
    const conn = self.conn orelse return;
    self.watching = true;
    _ = conn.addMatch(manager_match, null, null) catch {
        self.inform(@import("i18n").tr("Could not subscribe to service updates."));
        return;
    };
    _ = conn.addMatch(properties_match, null, null) catch {
        self.inform(@import("i18n").tr("Could not subscribe to service updates."));
        return;
    };
    self.subscribe() catch self.inform(@import("i18n").tr("Could not subscribe to service updates."));
}

pub fn stopWatching(self: *Client) void {
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

pub fn subscribe(self: *Client) !void {
    const body: wire.Writer = .{ .allocator = gpa };
    try self.call(.subscribe, 0, path, manager, "Subscribe", "", &body, false);
}

/// Re-reads everything, details included: the user asked, or systemd reloaded.
pub fn refresh(self: *Client) void {
    self.reload(true);
}

/// Lists units and unit files again; details are only read for loaded units
/// that have none yet, unless `force`.
pub fn reload(self: *Client, force: bool) void {
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
        self.inform(@import("i18n").tr("Could not load services. Try Refresh."));
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
        self.inform(@import("i18n").tr("Boot summary is unavailable."));
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
