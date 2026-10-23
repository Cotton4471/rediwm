//! Adding a printer (discovery, address, probe, driver, create) and renaming a queue.

const i18n = @import("i18n");
const std = @import("std");
const ui = @import("ui");
const panel = @import("../panel.zig");
const printing = @import("../../printing/client.zig");
const cups = @import("../../printing/cups.zig");
const admin = @import("../../printing/admin.zig");
const setup = @import("../../printing/setup.zig");
const gpa = @import("../../main.zig").gpa;
const W = ui.layout.Widget;
const A = std.mem.Allocator;
const printers = @import("printers.zig");
const PendingAdd = printers.PendingAdd;
const PendingRename = printers.PendingRename;
const Section = printers.Section;
const text = printers.text;
const card = printers.card;
const button = printers.button;
const owner = printers.owner;
const busy = printers.busy;
const canAdmin = printers.canAdmin;
const chosen = printers.chosen;
const fieldValue = printers.fieldValue;
const setField = printers.setField;
const entry = printers.entry;
const queueNames = printers.queueNames;
const runAdmin = printers.runAdmin;
const runClient = printers.runClient;
const dismiss = printers.dismiss;

pub fn addClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const state = cc.printers.client.?.current orelse return;
    const data = state.cups orelse return;
    cc.printers.form = .add;
    cc.printers.driver_index = 0;
    cc.printers.driver_name_len = 0;
    cc.printers.add_discovered = false;
    cc.printers.add_device_len = 0;
    cc.printers.probe_address_len = 0;
    cc.printers.message = "";
    const a = cc.printers.arena.allocator();
    const name = setup.uniqueName(a, "Printer", queueNames(a, data) catch return) catch return;
    setField(&cc.printers, .name, name) catch return;
    runClient(cc, .catalog);
}

pub fn addForm(self: *Section, cc: *panel.ControlCenter, a: A, state: *const printing.State) !W {
    var items: std.ArrayList(W) = .empty;
    try items.append(a, panel.sectionTitle(if (self.form == .connection) i18n.tr("Change printer connection") else i18n.tr("Add a printer")));
    try items.append(a, button(cc, "printers_discover", i18n.tr("Find available printers"), 0, !canAdmin(self) or busy(self), discoverClicked));
    if (self.administration) |manager| {
        const devices = try a.alloc(admin.Device, manager.devices.len);
        for (manager.devices, 0..) |device, i| devices[i] = .{ .uri = try a.dupe(u8, device.uri), .make_model = try a.dupe(u8, device.make_model), .info = try a.dupe(u8, device.info), .device_id = try a.dupe(u8, device.device_id) };
        self.device_refs = devices;
    }
    for (self.device_refs, 0..) |device, i| {
        var used = false;
        if (state.cups) |data| for (data.printers) |printer| if (std.mem.eql(u8, printer.device_uri, device.uri)) {
            used = true;
        };
        if (used and self.form == .add) continue;
        try items.append(a, button(cc, try std.fmt.allocPrint(a, "printers_device_{d}", .{i}), try cups.clean(a, if (device.info.len > 0) device.info else device.make_model), i, busy(self), deviceClicked));
    }
    try items.append(a, try entry(self, cc, a, .address, i18n.tr("Printer address (ipp, ipps, socket or lpd)"), ""));
    try items.append(a, button(cc, "printers_probe", i18n.tr("Check IPP address"), 0, busy(self), probeClicked));
    if (self.form == .connection) {
        try items.append(a, text(i18n.tr("Select an installed USB backend from discovery, or enter a network address. This changes the connection for the selected queue."), true));
        try items.append(a, button(cc, "printers_connection_apply", i18n.tr("Apply connection"), 0, busy(self) or !canAdmin(self), applyConnectionClicked));
        try items.append(a, button(cc, "printers_add_cancel", i18n.tr("Keep connection"), 0, busy(self), dismiss));
        return card(a, items.items);
    }
    try items.append(a, try entry(self, cc, a, .name, i18n.tr("Queue name"), i18n.tr("Printer")));
    const data = state.cups orelse return card(a, items.items);
    if (data.drivers_error) |err| try items.append(a, text(cups.failure(err), true));
    const labels = try a.alloc([]const u8, data.drivers.len + 3);
    labels[0] = i18n.tr("Choose a driver…");
    labels[1] = i18n.tr("IPP Everywhere / AirPrint");
    labels[2] = i18n.tr("Raw queue (printer commands only)");
    const driver_refs = try a.alloc([]const u8, data.drivers.len);
    for (data.drivers, 0..) |driver, i| labels[i + 3] = try cups.clean(a, try std.fmt.allocPrint(a, "{s} ({s})", .{ if (driver.model.len > 0) driver.model else i18n.tr("Driver"), driver.name }));
    for (data.drivers, 0..) |driver, i| driver_refs[i] = try a.dupe(u8, driver.name);
    self.driver_refs = driver_refs;
    if (self.driver_name_len > 0) {
        self.driver_index = 0;
        for (data.drivers, 0..) |driver, i| if (std.mem.eql(u8, driver.name, self.driver_name[0..self.driver_name_len])) {
            self.driver_index = i + 3;
            break;
        };
    }
    if (self.driver_index == 0 and self.add_device_len > 0) {
        const ppds = try a.alloc(setup.Ppd, data.drivers.len);
        for (data.drivers, 0..) |driver, i| ppds[i] = .{ .name = driver.name, .make_model = driver.model, .device_id = driver.device_id };
        if (setup.driverMatch(self.add_device_id[0..self.add_device_len], ppds)) |match| {
            self.driver_index = match + 3;
            self.driver_name_len = @min(data.drivers[match].name.len, self.driver_name.len);
            @memcpy(self.driver_name[0..self.driver_name_len], data.drivers[match].name[0..self.driver_name_len]);
        }
    }
    if (state.action_error == null and state.probe == true and std.mem.eql(u8, fieldValue(self, .address), self.probe_address[0..self.probe_address_len]) and self.driver_index == 0) self.driver_index = 1;
    if (self.driver_index >= labels.len) self.driver_index = 0;
    try items.append(a, .{ .name = "printers_driver", .kind = .{ .select = .{ .labels = labels, .selected = self.driver_index, .disabled = busy(self), .owner = cc, .on_change = driverChanged } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } });
    try items.append(a, text(i18n.tr("A raw queue passes commands unchanged; ordinary PDF printing needs a compatible driver."), true));
    if (self.driver_index == 0) try items.append(a, text(i18n.tr("No unambiguous automatic driver match. Choose a listed driver, check an IPP address, or explicitly choose a raw queue."), true));
    try items.append(a, button(cc, "printers_create", i18n.tr("Create printer"), 0, busy(self) or !canAdmin(self) or self.driver_index == 0, createClicked));
    try items.append(a, button(cc, "printers_add_cancel", i18n.tr("Cancel setup"), 0, busy(self), dismiss));
    return card(a, items.items);
}

pub fn discoverClicked(raw: ?*anyopaque, _: usize) void {
    runAdmin(owner(raw), .discover);
}

pub fn deviceClicked(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    if (id >= cc.printers.device_refs.len) return;
    const device = cc.printers.device_refs[id];
    setField(&cc.printers, .address, device.uri) catch return;
    cc.printers.add_discovered = true;
    cc.printers.add_device_len = @min(device.device_id.len, cc.printers.add_device_id.len);
    @memcpy(cc.printers.add_device_id[0..cc.printers.add_device_len], device.device_id[0..cc.printers.add_device_len]);
    cc.printers.driver_index = 0;
    cc.printers.driver_name_len = 0;
    const data = cc.printers.client.?.current.?.cups orelse return;
    const a = cc.printers.arena.allocator();
    setField(&cc.printers, .name, setup.uniqueName(a, device.make_model, queueNames(a, data) catch return) catch return) catch return;
    cc.refresh();
}

pub fn normalizedAddress(a: A, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "://") != null) return a.dupe(u8, trimmed);
    return std.fmt.allocPrint(a, "ipp://{s}/ipp/print", .{trimmed});
}

pub fn selectedAddress(self: *Section) ![]const u8 {
    const value = fieldValue(self, .address);
    return if (self.add_discovered) self.arena.allocator().dupe(u8, value) else normalizedAddress(self.arena.allocator(), value);
}

pub fn connectionClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const printer = chosen(cc) orelse return;
    cc.printers.form = .connection;
    cc.printers.add_discovered = false;
    cc.printers.add_device_len = 0;
    cc.printers.probe_address_len = 0;
    // Existing non-network backends must be selected again from discovery;
    // historical queue URIs are not proof that the backend is installed now.
    const address = if (setup.validateUri(printer.device_uri, false)) printer.device_uri else |_| "";
    setField(&cc.printers, .address, address) catch return;
    cc.refresh();
}

pub fn applyConnectionClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.form != .connection) return;
    const printer = chosen(cc) orelse return;
    const uri = selectedAddress(&cc.printers) catch return;
    runAdmin(cc, .{ .device = .{ .name = printer.name, .uri = uri, .discovered = cc.printers.add_discovered } });
}

pub fn probeClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const uri = selectedAddress(&cc.printers) catch return;
    setup.validateUri(uri, cc.printers.add_discovered) catch {
        cc.printers.message = i18n.tr("Enter a supported printer address without credentials.");
        cc.refresh();
        return;
    };
    if (!std.mem.startsWith(u8, uri, "ipp://") and !std.mem.startsWith(u8, uri, "ipps://")) {
        cc.printers.message = i18n.tr("Address checks support IPP printers. Other connections can be tested with an explicit print after setup.");
        cc.refresh();
        return;
    }
    setField(&cc.printers, .address, uri) catch return;
    cc.printers.probe_address_len = @min(uri.len, cc.printers.probe_address.len);
    @memcpy(cc.printers.probe_address[0..cc.printers.probe_address_len], uri[0..cc.printers.probe_address_len]);
    runClient(cc, .{ .probe = uri });
}

pub fn driverChanged(raw: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(raw);
    cc.printers.driver_index = index;
    cc.printers.driver_name_len = 0;
    if (index >= 3) {
        if (index - 3 >= cc.printers.driver_refs.len) return;
        const name = cc.printers.driver_refs[index - 3];
        cc.printers.driver_name_len = @min(name.len, cc.printers.driver_name.len);
        @memcpy(cc.printers.driver_name[0..cc.printers.driver_name_len], name[0..cc.printers.driver_name_len]);
    }
    cc.refresh();
}

pub fn createClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.form != .add or busy(&cc.printers) or !canAdmin(&cc.printers) or cc.printers.pending_add != null) return;
    const state = cc.printers.client.?.current orelse return;
    const data = state.cups orelse return;
    const index = cc.printers.driver_index;
    if (index == 0 or index >= data.drivers.len + 3) return;
    const uri = selectedAddress(&cc.printers) catch return;
    const ppd = if (index == 1) "everywhere" else if (index == 2) "raw" else cc.printers.driver_name[0..cc.printers.driver_name_len];
    const pending = gpa.create(PendingAdd) catch return;
    pending.* = .{ .arena = .init(gpa), .arguments = undefined };
    const mem = pending.arena.allocator();
    pending.arguments = .{ .name = mem.dupe(u8, fieldValue(&cc.printers, .name)) catch {
        pending.destroy();
        return;
    }, .uri = mem.dupe(u8, uri) catch {
        pending.destroy();
        return;
    }, .ppd = mem.dupe(u8, ppd) catch {
        pending.destroy();
        return;
    }, .discovered = cc.printers.add_discovered };
    pending.arguments.info = pending.arguments.name;
    cc.printers.pending_add = pending;
    runClient(cc, .refresh);
}

pub fn finishCreate(cc: *panel.ControlCenter) void {
    const pending = cc.printers.pending_add orelse return;
    cc.printers.pending_add = null;
    defer pending.destroy();
    const state = cc.printers.client.?.current orelse return;
    if (state.failure != null or cc.printers.client.?.failure != null or state.generation != cc.printers.client.?.generation) {
        cc.printers.message = i18n.tr("Could not verify existing printers. Refresh before creating a queue.");
        return;
    }
    const data = state.cups orelse return;
    var arguments = pending.arguments;
    arguments.existing_names = queueNames(pending.arena.allocator(), data) catch return;
    runAdmin(cc, .{ .add = arguments });
}

pub fn queueRenameClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const name = fieldValue(&cc.printers, .queue_name);
    if (!setup.validName(name)) {
        cc.printers.message = i18n.tr("Use letters, numbers, dots, hyphens or underscores for the queue identifier.");
        cc.refresh();
        return;
    }
    cc.printers.form = .queue_rename;
    cc.refresh();
}

pub fn queueRenameConfirm(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.form != .queue_rename or busy(&cc.printers)) return;
    const printer = chosen(cc) orelse return;
    const name = fieldValue(&cc.printers, .queue_name);
    if (printer.name.len > 127 or !setup.validName(name)) return;
    var pending: PendingRename = .{ .old_len = printer.name.len, .new_len = name.len };
    @memcpy(pending.old[0..pending.old_len], printer.name);
    @memcpy(pending.new[0..pending.new_len], name);
    cc.printers.pending_rename = pending;
    runClient(cc, .refresh);
}

pub fn submitRename(cc: *panel.ControlCenter) void {
    const pending = cc.printers.pending_rename orelse return;
    const state = cc.printers.client.?.current orelse return;
    if (state.failure != null or cc.printers.client.?.failure != null or state.generation != cc.printers.client.?.generation) {
        cc.printers.pending_rename = null;
        cc.printers.message = i18n.tr("Could not verify existing printers before changing the identifier.");
        return;
    }
    const data = state.cups orelse return;
    const old = pending.old[0..pending.old_len];
    if (data.jobs_error != null) {
        cc.printers.pending_rename = null;
        cc.printers.message = i18n.tr("Could not verify the printer's jobs. Refresh before changing its identifier.");
        return;
    }
    for (data.jobs) |job| if (job.cancellable() and std.mem.eql(u8, job.printer, old)) {
        cc.printers.pending_rename = null;
        cc.printers.message = i18n.tr("Finish or cancel the printer's jobs before changing its identifier.");
        return;
    };
    var source_exists = false;
    for (data.printers) |printer| if (std.mem.eql(u8, printer.name, old)) {
        source_exists = true;
        break;
    };
    if (!source_exists) {
        cc.printers.pending_rename = null;
        cc.printers.message = i18n.tr("The printer no longer exists. Refresh before retrying.");
        return;
    }
    runAdmin(cc, .{ .rename = .{ .name = old, .new_name = pending.new[0..pending.new_len], .existing_names = queueNames(cc.printers.arena.allocator(), data) catch return } });
    if (cc.printers.administration) |manager| if (!manager.busy) {
        cc.printers.pending_rename = null;
    };
}

pub fn finishRename(cc: *panel.ControlCenter) void {
    const pending = cc.printers.pending_rename orelse return;
    cc.printers.pending_rename = null;
    const state = cc.printers.client.?.current orelse return;
    if (state.failure != null or cc.printers.client.?.failure != null or state.generation != cc.printers.client.?.generation) return;
    const data = state.cups orelse return;
    var old_exists = false;
    var new_exists = false;
    for (data.printers) |printer| {
        if (std.ascii.eqlIgnoreCase(printer.name, pending.old[0..pending.old_len])) old_exists = true;
        if (std.ascii.eqlIgnoreCase(printer.name, pending.new[0..pending.new_len])) new_exists = true;
    }
    if (!old_exists and new_exists) {
        cc.printers.selected_len = pending.new_len;
        @memcpy(cc.printers.selected[0..pending.new_len], pending.new[0..pending.new_len]);
        cc.printers.migration_pending = true;
        runClient(cc, .{ .rename_preferences = .{ .old = pending.old[0..pending.old_len], .new = pending.new[0..pending.new_len] } });
    } else cc.printers.message = i18n.tr("The queue identifier change could not be verified. Review the printer list before retrying.");
}
