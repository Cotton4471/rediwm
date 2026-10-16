//! Printer setup, queue settings and explicit diagnostic print workflows.
const std = @import("std");
const ui = @import("ui");
const panel = @import("../panel.zig");
const printing = @import("../../printing/client.zig");
const cups = @import("../../printing/cups.zig");
const ladder = @import("../../printing/ladder.zig");
const usb = @import("../../printing/usb_sysfs.zig");
const admin = @import("../../printing/admin.zig");
const setup = @import("../../printing/setup.zig");
const tools = @import("../../printing/tools.zig");
const preferences = @import("../../printing/preferences.zig");
const known = @import("../../printing/known_devices.zig");
const notifier = @import("../../printing/notifier.zig");
const driver_options = @import("../../printing/options.zig");
const gpa = @import("../../main.zig").gpa;
const W = ui.layout.Widget;
const A = std.mem.Allocator;
const Form = enum { none, add, connection, remove, test_confirm, test_result, queue_rename };
const Field = enum { address, name, rename, loaded_width, loaded_height, measured_width, measured_height, raw_dpi, queue_name };
const field_names = [_][]const u8{ "printers_address", "printers_name", "printers_rename", "printers_loaded_width", "printers_loaded_height", "printers_measured_width", "printers_measured_height", "printers_raw_dpi", "printers_queue_name" };
const Input = struct { widget: ?*W = null, data: ?ui.layout.TextInputData = null };
const RangeDraft = struct { name: [128]u8 = undefined, len: usize = 0, range: cups.ipp.Range = .{ .lower = 0, .upper = 0 }, value: f32 = 0 };
const PendingAdd = struct {
    arena: std.heap.ArenaAllocator,
    arguments: admin.Add,
    fn destroy(self: *PendingAdd) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};
const PendingRename = struct { old: [128]u8 = undefined, old_len: usize = 0, new: [128]u8 = undefined, new_len: usize = 0, after_admin: bool = false };
const PendingOption = struct { queue: [128]u8 = undefined, queue_len: usize = 0, key: [128]u8 = undefined, key_len: usize = 0, value: [1024]u8 = undefined, value_len: usize = 0, ppd: bool = false, after_admin: bool = false };

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    client: ?*printing.Client = null,
    administration: ?*admin.Manager = null,
    listener: ?*notifier.Listener = null,
    listener_attempted: bool = false,
    admin_generation: u64 = 0,
    form: Form = .none,
    fields: [field_names.len]Input = @splat(.{}),
    focused_field: ?Field = null,
    message: []const u8 = "",
    driver_index: usize = 0,
    driver_name: [1024]u8 = undefined,
    driver_name_len: usize = 0,
    pending_add: ?*PendingAdd = null,
    pending_rename: ?PendingRename = null,
    pending_option: ?PendingOption = null,
    migration_pending: bool = false,
    queue_refs: []const []const u8 = &.{},
    driver_refs: []const []const u8 = &.{},
    device_refs: []const admin.Device = &.{},
    ranges: [16]RangeDraft = @splat(.{}),
    range_count: usize = 0,
    add_discovered: bool = false,
    add_device_id: [8192]u8 = undefined,
    add_device_len: usize = 0,
    language: ?tools.Language = null,
    test_kind: printing.TestKind = .driver,
    inches: bool = false,
    suggested: ?cups.ipp.Resolution = null,
    show_diagnostics: bool = false,
    fields_for: [512]u8 = undefined,
    fields_for_len: usize = 0,
    probe_address: [8192]u8 = undefined,
    probe_address_len: usize = 0,
    option_refs: []const @import("../../printing/options.zig").Option = &.{},
    selected: [512]u8 = undefined,
    selected_len: usize = 0,
    copied: bool = false,
    pub fn capture(self: *Section) void {
        self.focused_field = null;
        if (ui.input.current.focused) |focused| {
            for (self.fields, 0..) |field, i| if (field.widget == focused) {
                self.focused_field = @enumFromInt(i);
            };
        }
    }
    fn saveFields(self: *Section) void {
        for (&self.fields) |*field| {
            if (field.widget) |widget| field.data = widget.kind.text_input;
            field.widget = null;
        }
    }
    pub fn restoreFocus(self: *Section, cc: *panel.ControlCenter) void {
        if (self.focused_field) |id| if (self.fields[@intFromEnum(id)].widget) |widget| ui.input.current.focus(&cc.root, widget);
    }
    pub fn hide(self: *Section) void {
        self.saveFields();
        if (self.pending_add) |pending| pending.destroy();
        self.pending_add = null;
        self.pending_rename = null;
        self.pending_option = null;
        self.migration_pending = false;
        if (self.administration) |manager| manager.destroy();
        self.administration = null;
        if (self.client) |client| client.destroy();
        self.client = null;
        if (self.listener) |listener| listener.destroy();
        self.listener = null;
        self.listener_attempted = false;
        self.form = .none;
        self.focused_field = null;
        self.copied = false;
    }
    pub fn deinit(self: *Section) void {
        self.hide();
        for (self.fields) |field| if (field.data) |data| gpa.free(data.value);
        self.arena.deinit();
    }
};

fn text(value: []const u8, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = t.app_text_size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } }, .width = .{ .percent = 1 } };
}
fn named(value: W, name: []const u8) W {
    var result = value;
    result.name = name;
    return result;
}
fn group(a: A, items: []const W) !W {
    return .{ .kind = .container, .direction = .column, .gap = 10, .width = .{ .percent = 1 }, .children = try a.dupe(W, items) };
}
fn card(a: A, items: []const W) !W {
    var result = try group(a, items);
    const t = panel.palette();
    result.kind = .{ .rect = .{ .color = t.app_item, .radius = t.settings_card_radius, .border_width = 1, .border_color = t.app_item_border } };
    result.padding = ui.layout.Edges.all(14);
    return result;
}
fn button(cc: *panel.ControlCenter, name: []const u8, label: []const u8, id: usize, disabled: bool, callback: *const fn (?*anyopaque, usize) void) W {
    return .{ .name = name, .kind = .{ .button = .{ .label = label, .owner = cc, .id = id, .on_click = callback, .state = if (disabled) .disabled else .idle } }, .height = .{ .fixed = 34 } };
}
fn changed(raw: *anyopaque) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(raw));
    cc.printers.copied = false;
    if (cc.printers.pending_add != null and !cc.printers.client.?.busy) finishCreate(cc);
    if (cc.printers.pending_rename) |pending| if (!cc.printers.client.?.busy) {
        if (pending.after_admin) finishRename(cc) else submitRename(cc);
    };
    if (cc.printers.migration_pending and !cc.printers.client.?.busy) {
        cc.printers.fields_for_len = 0;
        cc.printers.migration_pending = false;
    }
    if (cc.printers.pending_option) |pending| if (pending.after_admin and !cc.printers.client.?.busy) verifyOption(cc);
    cc.refresh();
}
fn adminChanged(raw: *anyopaque) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(raw));
    if (cc.printers.administration) |manager| if (manager.generation != cc.printers.admin_generation) {
        cc.printers.admin_generation = manager.generation;
        cc.printers.form = .none;
        if (cc.printers.pending_rename) |*pending| pending.after_admin = true;
        if (cc.printers.pending_option) |*pending| pending.after_admin = true;
        if (cc.printers.client) |client| client.act(.refresh) catch client.invalidate();
    };
    cc.refresh();
}
fn cupsChanged(raw: *anyopaque) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(raw));
    if (cc.printers.client) |client| client.invalidate();
}
pub fn build(self: *Section, cc: *panel.ControlCenter) void {
    self.saveFields();
    self.option_refs = &.{};
    self.queue_refs = &.{};
    self.driver_refs = &.{};
    self.device_refs = &.{};
    _ = self.arena.reset(.retain_capacity);
    self.root = tree(self, cc, self.arena.allocator()) catch panel.outOfMemory();
    const width: f32 = @floatFromInt(cc.panel_box.width - @as(i32, if (cc.panel_box.width < 660) 140 else 308));
    wrapLabels(self.arena.allocator(), &self.root, @max(width, 80)) catch {};
}
/// Widget text is single-line. Explanatory paragraphs become ordinary shared
/// text widgets so long diagnostic reasons remain readable at narrow widths.
fn wrapLabels(a: A, widget: *W, available: f32) !void {
    const width = switch (widget.width) {
        .fixed => |v| v,
        .percent => |v| available * v,
        else => available,
    };
    const inner = @max(40, width - widget.padding.left - widget.padding.right);
    if (widget.kind == .text and widget.name == null) {
        const style = widget.kind.text;
        const font: ui.text.Font = if (style.family == .mono) .mono else if (style.weight >= 700) .manrope_heavy else if (style.weight >= 600) .manrope_bold else .manrope;
        if ((ui.text.measureWidthF(style.content, font, style.font_size, 1) catch 0) <= inner) return;
        var lines: std.ArrayList(W) = .empty;
        var start: usize = 0;
        var last_space: ?usize = null;
        for (style.content, 0..) |ch, i| {
            if (ch != ' ') continue;
            if ((ui.text.measureWidthF(style.content[start..i], font, style.font_size, 1) catch 0) > inner) {
                const end = last_space orelse i;
                var line = style;
                line.content = style.content[start..end];
                try lines.append(a, .{ .kind = .{ .text = line }, .width = .{ .percent = 1 } });
                start = end + 1;
                last_space = null;
            }
            last_space = i;
        }
        if (start < style.content.len) {
            if ((ui.text.measureWidthF(style.content[start..], font, style.font_size, 1) catch 0) > inner) if (last_space) |end| {
                if (end > start) {
                    var line = style;
                    line.content = style.content[start..end];
                    try lines.append(a, .{ .kind = .{ .text = line }, .width = .{ .percent = 1 } });
                    start = end + 1;
                }
            };
            var line = style;
            line.content = style.content[start..];
            try lines.append(a, .{ .kind = .{ .text = line }, .width = .{ .percent = 1 } });
        }
        widget.kind = .container;
        widget.direction = .column;
        widget.gap = 2;
        widget.children = try lines.toOwnedSlice(a);
        return;
    }
    var fixed: f32 = 0;
    var flex: usize = 0;
    if (widget.direction == .row) for (widget.children) |child| {
        switch (child.width) {
            .fixed => |v| fixed += v,
            else => flex += 1,
        }
    };
    const share = if (flex > 0) @max(40, (inner - fixed - widget.gap * @as(f32, @floatFromInt(widget.children.len -| 1))) / @as(f32, @floatFromInt(flex))) else inner;
    for (widget.children) |*child| try wrapLabels(a, child, if (widget.direction == .row and child.width != .fixed) share else inner);
}
fn tree(self: *Section, cc: *panel.ControlCenter, a: A) !W {
    if (cc.server.greeter_mode) return text("Printers are unavailable in the greeter.", true);
    if (self.client == null) self.client = printing.Client.create(cc.server.io, cc.server.environ, cc.server.wl_server.getEventLoop(), cc, changed) catch return text("Could not start printer diagnostics.", true);
    const client = self.client.?;
    var content: std.ArrayList(W) = .empty;
    const state = client.current;
    if (state) |snapshot| if (snapshot.admin_local) {
        if (self.administration == null) self.administration = admin.Manager.create(cc.server.wl_server.getEventLoop(), cc.server.environ, cc, adminChanged) catch null;
        if (!self.listener_attempted) {
            self.listener_attempted = true;
            self.listener = notifier.Listener.create(gpa, cc.server.io, cc.server.environ, cc.server.wl_server.getEventLoop(), cc, cupsChanged) catch null;
        }
        if (self.listener) |listener| if (listener.ready) client.enableSubscriptions();
    };
    if (state) |snapshot| if (!snapshot.admin_local) {
        if (self.administration) |manager| manager.destroy();
        self.administration = null;
        if (self.listener) |listener| listener.destroy();
        self.listener = null;
        self.listener_attempted = false;
    };
    const failure: ?anyerror = if (client.failure) |err| err else if (state) |snapshot| if (snapshot.failure) |err| err else snapshot.action_error else null;
    const status = if (client.busy) "Loading printers…" else if (failure) |err| cups.failure(err) else "Connected to CUPS.";
    try content.append(a, named(text(status, true), "printers_status"));
    try content.append(a, button(cc, "printers_refresh", "Refresh", 0, client.busy, refresh));
    try content.append(a, button(cc, "printers_add", "Add a printer", 0, !canAdmin(self) or busy(self), addClicked));
    if (self.message.len > 0) try content.append(a, text(self.message, false));
    if (self.administration) |manager| try content.append(a, text(manager.status, true)) else try content.append(a, text("Printer setup requires the local default CUPS server and cups-pk-helper.", true));
    if (state) |snapshot| {
        if (snapshot.action_error) |err| try content.append(a, text(cups.failure(err), false));
        if (snapshot.failure != null) {
            try content.append(a, text(snapshot.platform.missing_cups, true));
            try content.append(a, button(cc, "printers_start", "Start CUPS", 0, !snapshot.admin_local or busy(self) or self.administration == null, startClicked));
        }
        if (self.administration) |manager| if (manager.availability == .missing) try content.append(a, text(snapshot.platform.missing_helper, true));
        if (self.form == .add or self.form == .connection) try content.append(a, try addForm(self, cc, a, snapshot));
        if (snapshot.cups) |data| {
            if (data.printers.len == 0) {
                try content.append(a, text("No printers configured.", false));
            } else {
                const selected = selectIndex(self, data.printers);
                var choices: std.ArrayList(W) = .empty;
                const queue_refs = try a.alloc([]const u8, data.printers.len);
                for (data.printers, 0..) |printer, i| {
                    queue_refs[i] = try a.dupe(u8, printer.name);
                    var row = button(cc, try std.fmt.allocPrint(a, "printers_queue_{d}", .{i}), try std.fmt.allocPrint(a, "{s} · {s}{s}", .{ printer.name, cups.printerState(printer.state), if (std.mem.eql(u8, printer.name, data.user_default)) " · Default" else if (printer.is_default) " · System default" else "" }), i, busy(self), select);
                    row.kind.button.leading_icon = .print;
                    if (i == selected) row.kind.button.variant = .primary;
                    try choices.append(a, row);
                }
                self.queue_refs = queue_refs;
                var detail_items: std.ArrayList(W) = .empty;
                try details(self, cc, a, &detail_items, snapshot, data, data.printers[selected]);
                var queue_list = try group(a, choices.items);
                var detail_list = try group(a, detail_items.items);
                var columns = try group(a, &.{});
                if (cc.panel_box.width >= 1050) {
                    queue_list.width = .{ .fixed = 210 };
                    detail_list.width = .{ .flex = 1 };
                    columns.direction = .row;
                    columns.@"align" = .start;
                }
                columns.children = try a.dupe(W, &.{ queue_list, detail_list });
                try content.append(a, columns);
            }
        }
        // Attached printers can still be inspected if CUPS is missing or empty.
        if (snapshot.usb) |inventory| if (inventory.devices.len > 0) {
            var devices: std.ArrayList(W) = .empty;
            try devices.append(a, panel.sectionTitle("Attached USB printers"));
            for (inventory.devices) |device| {
                try devices.append(a, text(try std.fmt.allocPrint(a, "{s} {s} ({x:0>4}:{x:0>4})", .{ device.manufacturer, device.product, device.vid, device.pid }), true));
                if (known.lookup(device.vid, device.pid)) |hint| {
                    try devices.append(a, text(hint.note, true));
                    try devices.append(a, text(hint.driver_project, true));
                }
                if (device.nodes.len == 0) try devices.append(a, text("No usblp node was found; CUPS may still use libusb or ipp-usb.", true));
            }
            try content.append(a, try card(a, devices.items));
        };
    }
    return group(a, content.items);
}
fn selectIndex(self: *Section, printers: []const cups.Printer) usize {
    for (printers, 0..) |printer, i| if (std.mem.eql(u8, printer.name, self.selected[0..self.selected_len])) return i;
    self.form = .none;
    self.selected_len = @min(printers[0].name.len, self.selected.len);
    @memcpy(self.selected[0..self.selected_len], printers[0].name[0..self.selected_len]);
    return 0;
}
fn splitReasons(a: A, values: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitSequence(u8, values, ", ");
    while (parts.next()) |part| if (part.len > 0) {
        try out.append(a, part);
    };
    return out.toOwnedSlice(a);
}
fn showReasons(a: A, content: *std.ArrayList(W), values: []const u8) !void {
    for (try splitReasons(a, values)) |reason| {
        const label = ladder.reasonText(reason) orelse reason;
        if (!std.mem.eql(u8, reason, "none")) try content.append(a, text(try a.dupe(u8, label), true));
    }
}
fn resolution(value: ?cups.ipp.Resolution) ?ladder.Resolution {
    const r = value orelse return null;
    if (r.x <= 0 or r.y <= 0) return null;
    const x = if (r.units == .dpi) r.x else @divTrunc(@as(i64, r.x) * 254 + 50, 100);
    const y = if (r.units == .dpi) r.y else @divTrunc(@as(i64, r.y) * 254 + 50, 100);
    if (x > std.math.maxInt(u32) or y > std.math.maxInt(u32)) return null;
    return .{ .x_dpi = @intCast(x), .y_dpi = @intCast(y) };
}
fn diagnostic(a: A, state: *const printing.State, data: cups.Snapshot, printer: cups.Printer) !ladder.Input {
    const uri = printer.device_uri;
    const connection: ladder.Connection = if (std.mem.startsWith(u8, uri, "usb://") or printer.node_kind != null) .usb else if (std.mem.startsWith(u8, uri, "ipp://") or std.mem.startsWith(u8, uri, "ipps://") or std.mem.startsWith(u8, uri, "socket://") or std.mem.startsWith(u8, uri, "lpd://") or std.mem.startsWith(u8, uri, "dnssd://")) .network else .other;
    var input: ladder.Input = .{
        .connection = connection,
        .cups_reachable = true,
        .network_reachable = printer.network_reachable,
        .distribution = @tagName(state.platform.distro),
        .cups_version = data.cups_version,
        .node_kind = printer.node_kind,
        .usb_backend = if (printer.node_kind != null) .device_node else .unknown,
        .settings_consistent = !printer.inconsistent_defaults,
        .queue = .{ .state = switch (printer.state orelse 0) {
            3 => .idle,
            4 => .processing,
            5 => .stopped,
            else => .unknown,
        }, .accepting = printer.accepting, .reasons = try splitReasons(a, printer.reasons), .uri = uri, .default_media = printer.media, .resolution = resolution(printer.resolution) },
    };
    if (printer.user.expected_media) |expected| if (mediaFor(printer, state)) |actual| {
        input.expected_media = if (@abs(expected.width_mm - actual.width_mm) <= 1 and @abs(expected.height_mm - actual.height_mm) <= 1) printer.media else "different-loaded-size";
    };
    if (state.usb) |*inventory| {
        const match = usb.matchQueue(inventory, uri);
        input.usb = match.device;
        input.usb_scan_complete = match.conclusive;
    }
    for (data.jobs) |job| if (job.own and std.mem.eql(u8, job.printer, printer.name)) {
        input.last_job = .{
            .state = switch (job.state orelse 0) {
                3 => .pending,
                4 => .held,
                5 => .processing,
                6 => .stopped,
                7 => .canceled,
                8 => .aborted,
                9 => .completed,
                else => .unknown,
            },
            .sheets_completed = if (job.sheets) |n| if (n >= 0) @intCast(n) else null else null,
            .reasons = try splitReasons(a, job.reasons),
            .message = job.message,
        };
        break;
    };
    return input;
}
fn details(self: *Section, cc: *panel.ControlCenter, a: A, content: *std.ArrayList(W), state: *const printing.State, data: cups.Snapshot, printer: cups.Printer) !void {
    if (std.mem.eql(u8, state.selected, printer.name) and !std.mem.eql(u8, self.fields_for[0..self.fields_for_len], printer.name)) {
        self.fields_for_len = @min(printer.name.len, self.fields_for.len);
        @memcpy(self.fields_for[0..self.fields_for_len], printer.name[0..self.fields_for_len]);
        try setField(self, .rename, if (printer.info.len != 0) printer.info else printer.name);
        try setField(self, .queue_name, printer.name);
        const media = printer.user.expected_media orelse mediaFor(printer, state) orelse tools.Media{ .width_mm = 0, .height_mm = 0 };
        try setField(self, .loaded_width, if (media.width_mm > 0) try std.fmt.allocPrint(a, "{d:.2}", .{media.width_mm}) else "");
        try setField(self, .loaded_height, if (media.height_mm > 0) try std.fmt.allocPrint(a, "{d:.2}", .{media.height_mm}) else "");
        try setField(self, .measured_width, "");
        try setField(self, .measured_height, "");
        try setField(self, .raw_dpi, if (resolution(printer.resolution)) |r| try std.fmt.allocPrint(a, "{d}", .{r.x_dpi}) else "");
        self.inches = false;
        self.language = printer.user.language;
        if (self.language == null) {
            const detected = tools.detectLanguages(a, printer.device_id) catch &.{};
            if (detected.len == 1) self.language = detected[0];
        }
        self.suggested = null;
        self.range_count = 0;
    }
    if (!std.mem.eql(u8, state.selected, printer.name) and !self.client.?.busy) self.client.?.act(.{ .select = printer.name }) catch {};
    if (!self.client.?.busy and self.form != .test_confirm and self.form != .test_result) {
        self.language = printer.user.language;
        if (self.language == null) {
            const detected = tools.detectLanguages(a, printer.device_id) catch &.{};
            if (detected.len == 1) self.language = detected[0];
        }
    }
    var header: std.ArrayList(W) = .empty;
    try header.append(a, panel.sectionTitle(try a.dupe(u8, if (printer.info.len > 0) printer.info else printer.name)));
    try header.append(a, text(try std.fmt.allocPrint(a, "Queue: {s}", .{printer.name}), true));
    try header.append(a, text(try a.dupe(u8, printer.model), true));
    try header.append(a, named(text(cups.printerState(printer.state), false), "printers_state"));
    try showReasons(a, &header, printer.reasons);
    if (printer.message.len > 0) try header.append(a, text(try a.dupe(u8, printer.message), true));
    for (printer.markers) |marker| {
        try header.append(a, text(if (marker.level) |level| try std.fmt.allocPrint(a, "{s}: {d}%", .{ marker.name, level }) else try std.fmt.allocPrint(a, "{s}: level unavailable", .{marker.name}), true));
        if (marker.level) |level| {
            const fill = try a.create(W);
            fill.* = .{ .kind = .{ .rect = .{ .color = panel.palette().accent, .radius = 3 } }, .width = .{ .percent = @as(f32, @floatFromInt(level)) / 100 }, .height = .{ .fixed = 6 } };
            try header.append(a, .{ .kind = .{ .rect = .{ .color = panel.palette().border_soft, .radius = 3 } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 6 }, .children = fill[0..1] });
        }
    }
    try header.append(a, button(cc, "printers_resume", "Resume printer", 0, !canAdmin(self) or busy(self) or printer.state != 5, resumeClicked));
    try header.append(a, button(cc, "printers_disable", "Disable printer", 0, !canAdmin(self) or busy(self) or printer.state == 5, disableClicked));
    try header.append(a, button(cc, "printers_accepting", if (printer.accepting == false) "Accept jobs" else "Stop accepting jobs", 0, !canAdmin(self) or busy(self), acceptingClicked));
    try header.append(a, button(cc, "printers_connection", "Change connection…", 0, !canAdmin(self) or busy(self), connectionClicked));
    try content.append(a, try card(a, header.items));

    var rows: std.ArrayList(W) = .empty;
    try rows.append(a, panel.sectionTitle("Connection and print diagnostics"));
    const input = try diagnostic(a, state, data, printer);
    const result = ladder.evaluate(input);
    const layer_names = [_][]const u8{ "Connection", "Device node", "CUPS", "Queue", "Backend", "Media and resolution", "Last job" };
    try rows.append(a, button(cc, "printers_diagnostics", if (self.show_diagnostics) "Collapse diagnostic ladder" else "Show diagnostic ladder", 0, false, diagnosticsClicked));
    for (result.rows, layer_names, 0..) |row, name, index| {
        if (!self.show_diagnostics and result.firstFailure() != index) continue;
        try rows.append(a, text(try std.fmt.allocPrint(a, "{s} · {s}: {s}", .{ switch (row.verdict) {
            .pass => "Pass",
            .fail => "Problem",
            .unknown => "Unknown",
        }, name, row.message }), row.verdict != .fail));
        if (result.firstFailure()) |first| if (result.rows[first].layer == row.layer and row.fix.len > 0) try rows.append(a, text(row.fix, true));
    }
    try content.append(a, try card(a, rows.items));
    var options: std.ArrayList(W) = .empty;
    try options.append(a, panel.sectionTitle("Queue settings"));
    try options.append(a, text(try std.fmt.allocPrint(a, "Paper: {s}", .{if (printer.media.len > 0) printer.media else "Unavailable"}), true));
    if (resolution(printer.resolution)) |r| {
        try options.append(a, text(try std.fmt.allocPrint(a, "Resolution: {d} × {d} dpi", .{ r.x_dpi, r.y_dpi }), true));
    } else try options.append(a, text("Resolution: Unavailable", true));
    if (printer.color.len > 0) try options.append(a, text(try std.fmt.allocPrint(a, "Colour: {s}", .{printer.color}), true));
    if (printer.sides.len > 0) try options.append(a, text(try std.fmt.allocPrint(a, "Sides: {s}", .{printer.sides}), true));
    if (std.mem.eql(u8, state.selected, printer.name)) for (state.groups) |option_group| for (option_group.options) |option| {
        if (!std.mem.eql(u8, option.name, "PageSize")) continue;
        if (@import("../../printing/options.zig").ppdMargins(state.ppd, option.default orelse continue)) |margins| {
            try options.append(a, text(try std.fmt.allocPrint(a, "Margins (mm): left {d:.1}, right {d:.1}, top {d:.1}, bottom {d:.1}", .{ margins.left_mm, margins.right_mm, margins.top_mm, margins.bottom_mm }), true));
        }
    };
    var refs: std.ArrayList(@import("../../printing/options.zig").Option) = .empty;
    if (std.mem.eql(u8, state.selected, printer.name)) for (state.groups) |option_group| {
        try options.append(a, panel.sectionTitle(try a.dupe(u8, option_group.label)));
        for (option_group.options) |option| {
            if (option.source == .ipp and (std.mem.eql(u8, option.name, "print-color-mode") or std.mem.eql(u8, option.name, "print-quality"))) continue;
            const editable = state.ppd.len > 0 and driver_options.queueEditable(option, state.groups) and (option.range == null or option.source == .ppd);
            if (option.choices.len == 0) {
                if (option.range) |range| {
                    if (option.name.len > 128 or range.upper > 16_777_216) continue;
                    var index: ?usize = null;
                    for (self.ranges[0..self.range_count], 0..) |draft, i| if (std.mem.eql(u8, draft.name[0..draft.len], option.name)) {
                        index = i;
                        break;
                    };
                    if (index == null and self.range_count < self.ranges.len) {
                        index = self.range_count;
                        self.range_count += 1;
                        const draft = &self.ranges[index.?];
                        draft.len = option.name.len;
                        @memcpy(draft.name[0..draft.len], option.name);
                        draft.value = @floatFromInt(std.fmt.parseInt(i32, option.default orelse "", 10) catch range.lower);
                    }
                    const draft = &self.ranges[index orelse continue];
                    draft.range = range;
                    draft.value = std.math.clamp(draft.value, @as(f32, @floatFromInt(range.lower)), @as(f32, @floatFromInt(range.upper)));
                    try options.append(a, text(try a.dupe(u8, option.label), false));
                    if (canAdmin(self) and !busy(self) and editable) {
                        try options.append(a, .{ .name = try std.fmt.allocPrint(a, "printers_range_{s}", .{option.name}), .kind = .{ .stepper = .{ .value = draft.value, .min = @floatFromInt(range.lower), .max = @floatFromInt(range.upper), .step = 1, .owner = cc, .id = index.?, .on_change = rangeChanged } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 34 } });
                        try options.append(a, button(cc, try std.fmt.allocPrint(a, "printers_option_{s}_apply", .{option.name}), "Apply value", index.?, false, rangeApply));
                    } else {
                        try options.append(a, text(try std.fmt.allocPrint(a, "{d:.0} (supported {d}–{d})", .{ draft.value, range.lower, range.upper }), true));
                        if (!editable) try options.append(a, text("This range has no selectable queue setting in the current driver.", true));
                    }
                }
                continue;
            }
            const labels = try a.alloc([]const u8, option.choices.len);
            var selected: usize = 0;
            for (option.choices, 0..) |choice, index| {
                labels[index] = try a.dupe(u8, choice.label);
                if (option.default) |value| if (std.mem.eql(u8, value, choice.value)) {
                    selected = index;
                };
            }
            const id = refs.items.len;
            const choices = try a.alloc(@import("../../printing/options.zig").Choice, option.choices.len);
            for (option.choices, 0..) |choice, i| choices[i] = .{ .value = try a.dupe(u8, choice.value), .label = labels[i] };
            try refs.append(a, .{ .name = try a.dupe(u8, option.name), .label = try a.dupe(u8, option.label), .choices = choices, .source = option.source });
            try options.append(a, text(try a.dupe(u8, option.label), false));
            try options.append(a, .{ .name = try std.fmt.allocPrint(a, "printers_option_{s}", .{option.name}), .kind = .{ .select = .{ .labels = labels, .selected = selected, .disabled = !canAdmin(self) or busy(self) or !editable, .owner = cc, .id = id, .on_change = optionChanged } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } });
            if (!editable) try options.append(a, text("This capability has no selectable queue default in the current driver.", true));
        }
    };
    self.option_refs = refs.items;
    try options.append(a, button(cc, "printers_default", if (std.mem.eql(u8, data.user_default, printer.name)) "Your default printer" else "Set as my default", 0, busy(self), defaultClicked));
    if (preferences.overrideMessage(cc.server.environ)) |message| try options.append(a, text(message, true));
    try options.append(a, button(cc, "printers_system_default", "Set as system default", 0, !canAdmin(self) or busy(self) or printer.is_default, systemDefaultClicked));
    try options.append(a, try entry(self, cc, a, .rename, "Display name", ""));
    try options.append(a, button(cc, "printers_rename_save", "Save display name", 0, !canAdmin(self) or busy(self), renameClicked));
    try options.append(a, try entry(self, cc, a, .queue_name, "Queue identifier", ""));
    try options.append(a, button(cc, "printers_queue_rename", "Change queue identifier…", 0, !canAdmin(self) or busy(self) or std.ascii.eqlIgnoreCase(fieldValue(self, .queue_name), printer.name), queueRenameClicked));
    if (self.form == .queue_rename) {
        try options.append(a, text(try std.fmt.allocPrint(a, "Change {s} to {s}?", .{ printer.name, fieldValue(self, .queue_name) }), false));
        try options.append(a, text("CUPS copies the queue and removes its old identifier. Finish all jobs first. Check the resulting driver options afterwards.", true));
        try options.append(a, button(cc, "printers_queue_rename_confirm", "Change this queue identifier", 0, !canAdmin(self) or busy(self), queueRenameConfirm));
        try options.append(a, button(cc, "printers_queue_rename_cancel", "Keep identifier", 0, busy(self), dismiss));
    }
    try content.append(a, try card(a, options.items));

    var jobs: std.ArrayList(W) = .empty;
    try jobs.append(a, panel.sectionTitle("Your recent jobs"));
    var count: usize = 0;
    for (data.jobs) |job| {
        if (!job.own or !std.mem.eql(u8, job.printer, printer.name)) continue;
        count += 1;
        try jobs.append(a, text(try std.fmt.allocPrint(a, "Job {d} · {s}", .{ job.id, cups.jobState(job.state) }), false));
        if (job.sheets) |sheets| if (sheets >= 0) try jobs.append(a, text(try std.fmt.allocPrint(a, "{d} completed sheets reported by CUPS", .{sheets}), true));
        try showReasons(a, &jobs, job.reasons);
        if (job.message.len > 0) try jobs.append(a, text(try a.dupe(u8, job.message), true));
        if (job.cancellable()) try jobs.append(a, button(cc, try std.fmt.allocPrint(a, "printers_cancel_{d}", .{job.id}), "Cancel job", @intCast(job.id), self.client.?.busy, cancel));
    }
    if (data.jobs_error) |err| try jobs.append(a, text(cups.failure(err), true)) else if (count == 0) try jobs.append(a, text("No recent jobs available for your account.", true));
    try content.append(a, try card(a, jobs.items));
    try content.append(a, try toolsForm(self, cc, a, state, printer));
    if (self.form == .remove) {
        try content.append(a, text(try std.fmt.allocPrint(a, "Remove printer {s} ({s})? This deletes its queue and settings.", .{ if (printer.info.len > 0) printer.info else printer.name, printer.name }), false));
        try content.append(a, button(cc, "printers_remove_confirm", "Remove this printer", 0, !canAdmin(self) or busy(self), removeConfirm));
        try content.append(a, button(cc, "printers_remove_cancel", "Keep printer", 0, busy(self), dismiss));
    } else try content.append(a, button(cc, "printers_remove", "Remove printer…", 0, !canAdmin(self) or busy(self), removeClicked));
    try content.append(a, button(cc, "printers_copy_report", if (self.copied) "Report copied" else "Copy diagnostic report", 0, false, copy));
    try content.append(a, text("Reports omit document names, user names, USB serials and private printer addresses.", true));
}
fn owner(raw: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(raw.?));
}
fn refresh(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.administration) |manager| if (manager.availability == .missing and !manager.busy) {
        manager.destroy();
        cc.printers.administration = null;
    };
    if (cc.printers.listener) |listener| if (listener.conn.closed) {
        listener.destroy();
        cc.printers.listener = null;
    };
    if (cc.printers.listener == null) cc.printers.listener_attempted = false;
    if (cc.printers.client) |client| client.refresh();
    cc.printers.copied = false;
    cc.refresh();
}
fn select(raw: ?*anyopaque, index: usize) void {
    const cc = owner(raw);
    if (busy(&cc.printers)) return;
    const client = cc.printers.client orelse return;
    const state = client.current orelse return;
    const data = state.cups orelse return;
    if (index >= cc.printers.queue_refs.len) return;
    const name = cc.printers.queue_refs[index];
    var found = false;
    for (data.printers) |printer| if (std.mem.eql(u8, printer.name, name)) {
        found = true;
        break;
    };
    if (!found) return;
    cc.printers.selected_len = @min(name.len, cc.printers.selected.len);
    @memcpy(cc.printers.selected[0..cc.printers.selected_len], name[0..cc.printers.selected_len]);
    cc.printers.copied = false;
    cc.printers.form = .none;
    cc.printers.message = "";
    client.act(.{ .select = name }) catch {};
    cc.refresh();
}
fn cancel(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    if (id > std.math.maxInt(i32)) return;
    if (cc.printers.client) |client| client.cancelJob(@intCast(id));
    cc.refresh();
}
fn copy(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const client = cc.printers.client orelse return;
    const state = client.current orelse return;
    const data = state.cups orelse return;
    if (data.printers.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const printer = chosen(cc) orelse return;
    const input = diagnostic(a, state, data, printer) catch return;
    const report = ladder.report(a, input) catch return;
    var output: std.Io.Writer.Allocating = .init(a);
    output.writer.writeAll(report) catch return;
    output.writer.print("User observations: driver={s}, raw={s}, ruler={s}\n", .{ @tagName(printer.user.driver), @tagName(printer.user.raw), @tagName(printer.user.ruler) }) catch return;
    if (printer.user.language) |language| output.writer.print("User-confirmed command language: {s}\n", .{language.label()}) catch return;
    if (printer.user.expected_media) |media| output.writer.print("Loaded media: {d:.2} x {d:.2} mm\n", .{ media.width_mm, media.height_mm }) catch return;
    var count: usize = 0;
    for (data.jobs) |job| if (job.own and std.mem.eql(u8, job.printer, printer.name) and count < 10) {
        output.writer.print("Recent job: state={s}; sheets={d}\n", .{ cups.jobState(job.state), job.sheets orelse -1 }) catch return;
        count += 1;
    };
    @import("../../clipboard.zig").copyText(cc.server, output.written());
    cc.printers.copied = true;
    cc.refresh();
}

fn busy(self: *Section) bool {
    return (if (self.client) |client| client.busy else true) or (if (self.administration) |manager| manager.busy else false);
}
fn canAdmin(self: *Section) bool {
    const client = self.client orelse return false;
    const state = client.current orelse return false;
    const manager = self.administration orelse return false;
    return state.admin_local and client.failure == null and state.failure == null and state.cups != null and manager.availability == .available;
}
fn chosen(cc: *panel.ControlCenter) ?cups.Printer {
    if (!std.mem.eql(u8, cc.printers.selected[0..cc.printers.selected_len], cc.printers.fields_for[0..cc.printers.fields_for_len])) return null;
    const client = cc.printers.client orelse return null;
    const state = client.current orelse return null;
    const data = state.cups orelse return null;
    for (data.printers) |printer| if (std.mem.eql(u8, printer.name, cc.printers.selected[0..cc.printers.selected_len])) return printer;
    return null;
}
fn fieldValue(self: *Section, id: Field) []const u8 {
    const input = self.fields[@intFromEnum(id)];
    return if (input.widget) |widget| widget.kind.text_input.value else if (input.data) |data| data.value else "";
}
fn setField(self: *Section, id: Field, text_value: []const u8) !void {
    const input = &self.fields[@intFromEnum(id)];
    const copy_value = try gpa.dupe(u8, text_value);
    if (input.widget) |widget| input.data = widget.kind.text_input;
    if (input.data) |*data| {
        gpa.free(data.value);
        data.value = copy_value;
        data.cursor_pos = copy_value.len;
        data.selection_anchor = null;
        if (input.widget) |widget| widget.kind.text_input = data.*;
    } else input.data = .{ .owner = null, .id = @intFromEnum(id), .placeholder = "", .value = copy_value, .cursor_pos = copy_value.len, .on_change = fieldChanged };
}
fn entry(self: *Section, cc: *panel.ControlCenter, a: A, id: Field, label: []const u8, initial: []const u8) !W {
    const input = &self.fields[@intFromEnum(id)];
    if (input.data == null) try setField(self, id, initial);
    var data = input.data.?;
    data.owner = cc;
    data.id = @intFromEnum(id);
    data.placeholder = label;
    data.on_change = fieldChanged;
    const widget: W = .{ .name = field_names[@intFromEnum(id)], .kind = .{ .text_input = data }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } };
    const container = try group(a, &.{ text(label, true), widget });
    input.widget = &container.children[1];
    return container;
}
fn fieldChanged(raw: ?*anyopaque, id: usize, _: []const u8) void {
    const cc = owner(raw);
    if (id == @intFromEnum(Field.address)) {
        cc.printers.add_discovered = false;
        cc.printers.probe_address_len = 0;
        cc.printers.add_device_len = 0;
        cc.printers.driver_name_len = 0;
        cc.printers.driver_index = 0;
    }
    cc.printers.suggested = null;
    cc.refresh();
}
fn queueNames(a: A, data: cups.Snapshot) ![]const []const u8 {
    const names = try a.alloc([]const u8, data.printers.len);
    for (data.printers, 0..) |printer, i| names[i] = printer.name;
    return names;
}
fn runAdmin(cc: *panel.ControlCenter, action: admin.Action) void {
    if (busy(&cc.printers) or (action != .start_service and !canAdmin(&cc.printers))) return;
    if (action == .start_service) {
        const client = cc.printers.client orelse return;
        const state = client.current orelse return;
        if (!state.admin_local) return;
    }
    const manager = cc.printers.administration orelse return;
    manager.request(action) catch |err| {
        cc.printers.message = switch (err) {
            error.QueueExists => "A printer with this queue name already exists. Choose another name.",
            error.InvalidName => "Use letters, numbers, dots, hyphens or underscores for the queue name.",
            error.InvalidUri, error.UnsupportedScheme => "Enter a supported printer address without credentials.",
            error.UntrustedDevice => "Find available printers again and choose the current discovered device.",
            else => "The printer change could not be requested.",
        };
    };
    cc.refresh();
}
fn runClient(cc: *panel.ControlCenter, action: printing.Action) void {
    const client = cc.printers.client orelse return;
    client.act(action) catch {
        cc.printers.message = "Wait for the current printer operation to finish.";
    };
    cc.refresh();
}
fn dismiss(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    cc.printers.form = .none;
    cc.refresh();
}
fn startClicked(raw: ?*anyopaque, _: usize) void {
    runAdmin(owner(raw), .start_service);
}
fn resumeClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runAdmin(cc, .{ .enabled = .{ .name = (chosen(cc) orelse return).name, .value = true } });
}
fn disableClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runAdmin(cc, .{ .enabled = .{ .name = (chosen(cc) orelse return).name, .value = false } });
}
fn acceptingClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const p = chosen(cc) orelse return;
    runAdmin(cc, .{ .accepting = .{ .name = p.name, .value = p.accepting == false } });
}
fn defaultClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runClient(cc, .{ .personal_default = (chosen(cc) orelse return).name });
}
fn systemDefaultClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runAdmin(cc, .{ .system_default = (chosen(cc) orelse return).name });
}
fn renameClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runAdmin(cc, .{ .info = .{ .name = (chosen(cc) orelse return).name, .value = fieldValue(&cc.printers, .rename) } });
}
fn removeClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (chosen(cc) == null) return;
    cc.printers.form = .remove;
    cc.refresh();
}
fn removeConfirm(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.form != .remove) return;
    runAdmin(cc, .{ .remove = (chosen(cc) orelse return).name });
}
fn diagnosticsClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    cc.printers.show_diagnostics = !cc.printers.show_diagnostics;
    cc.refresh();
}
fn optionChanged(raw: ?*anyopaque, id: usize, index: usize) void {
    const cc = owner(raw);
    if (id >= cc.printers.option_refs.len) return;
    const option = cc.printers.option_refs[id];
    if (index >= option.choices.len) return;
    const state = cc.printers.client.?.current orelse return;
    if (state.ppd.len == 0 or !driver_options.queueEditable(option, state.groups)) return;
    changeOption(cc, option, option.choices[index].value);
}
fn changeOption(cc: *panel.ControlCenter, option: driver_options.Option, value: []const u8) void {
    const printer = chosen(cc) orelse return;
    if (busy(&cc.printers) or printer.name.len > 127 or option.name.len > 127 or value.len > 1024) return;
    var pending: PendingOption = .{ .queue_len = printer.name.len, .key_len = option.name.len, .value_len = value.len, .ppd = option.source == .ppd };
    @memcpy(pending.queue[0..pending.queue_len], printer.name);
    @memcpy(pending.key[0..pending.key_len], option.name);
    @memcpy(pending.value[0..pending.value_len], value);
    cc.printers.pending_option = pending;
    runAdmin(cc, .{ .ppd_option = .{ .name = printer.name, .key = option.name, .values = &.{value} } });
    if (cc.printers.administration) |manager| if (!manager.busy) {
        cc.printers.pending_option = null;
    };
}
fn verifyOption(cc: *panel.ControlCenter) void {
    const pending = cc.printers.pending_option orelse return;
    cc.printers.pending_option = null;
    const client = cc.printers.client orelse return;
    const state = client.current orelse return;
    if (state.failure != null or client.failure != null or state.generation != client.generation) return;
    const data = state.cups orelse return;
    for (data.printers) |printer| if (std.mem.eql(u8, printer.name, pending.queue[0..pending.queue_len])) {
        const option: driver_options.Option = .{ .name = pending.key[0..pending.key_len], .source = if (pending.ppd) .ppd else .ipp };
        const matches = driver_options.settingMatches(state.groups, printer.attributes, option, pending.value[0..pending.value_len]);
        cc.printers.message = if (matches) |saved| if (saved) "Printer setting verified." else "The driver did not report the requested value. Review its settings before printing." else "CUPS accepted the change; the resulting driver value could not be verified.";
        return;
    };
}
fn rangeChanged(raw: ?*anyopaque, id: usize, new_value: f32) void {
    const cc = owner(raw);
    if (id >= cc.printers.range_count or busy(&cc.printers)) return;
    cc.printers.ranges[id].value = new_value;
}
fn rangeApply(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    if (id >= cc.printers.range_count) return;
    const draft = cc.printers.ranges[id];
    if (!std.math.isFinite(draft.value) or draft.value < @as(f32, @floatFromInt(draft.range.lower)) or draft.value > @as(f32, @floatFromInt(draft.range.upper))) return;
    var buffer: [32]u8 = undefined;
    const setting = std.fmt.bufPrint(&buffer, "{d}", .{@as(i32, @intFromFloat(@round(draft.value)))}) catch return;
    runAdmin(cc, .{ .ppd_option = .{ .name = (chosen(cc) orelse return).name, .key = draft.name[0..draft.len], .values = &.{setting} } });
}
fn addClicked(raw: ?*anyopaque, _: usize) void {
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
fn addForm(self: *Section, cc: *panel.ControlCenter, a: A, state: *const printing.State) !W {
    var items: std.ArrayList(W) = .empty;
    try items.append(a, panel.sectionTitle(if (self.form == .connection) "Change printer connection" else "Add a printer"));
    try items.append(a, button(cc, "printers_discover", "Find available printers", 0, !canAdmin(self) or busy(self), discoverClicked));
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
    try items.append(a, try entry(self, cc, a, .address, "Printer address (ipp, ipps, socket or lpd)", ""));
    try items.append(a, button(cc, "printers_probe", "Check IPP address", 0, busy(self), probeClicked));
    if (self.form == .connection) {
        try items.append(a, text("Select an installed USB backend from discovery, or enter a network address. This changes the connection for the selected queue.", true));
        try items.append(a, button(cc, "printers_connection_apply", "Apply connection", 0, busy(self) or !canAdmin(self), applyConnectionClicked));
        try items.append(a, button(cc, "printers_add_cancel", "Keep connection", 0, busy(self), dismiss));
        return card(a, items.items);
    }
    try items.append(a, try entry(self, cc, a, .name, "Queue name", "Printer"));
    const data = state.cups orelse return card(a, items.items);
    if (data.drivers_error) |err| try items.append(a, text(cups.failure(err), true));
    const labels = try a.alloc([]const u8, data.drivers.len + 3);
    labels[0] = "Choose a driver…";
    labels[1] = "IPP Everywhere / AirPrint";
    labels[2] = "Raw queue (printer commands only)";
    const driver_refs = try a.alloc([]const u8, data.drivers.len);
    for (data.drivers, 0..) |driver, i| labels[i + 3] = try cups.clean(a, try std.fmt.allocPrint(a, "{s} ({s})", .{ if (driver.model.len > 0) driver.model else "Driver", driver.name }));
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
    try items.append(a, text("A raw queue passes commands unchanged; ordinary PDF printing needs a compatible driver.", true));
    if (self.driver_index == 0) try items.append(a, text("No unambiguous automatic driver match. Choose a listed driver, check an IPP address, or explicitly choose a raw queue.", true));
    try items.append(a, button(cc, "printers_create", "Create printer", 0, busy(self) or !canAdmin(self) or self.driver_index == 0, createClicked));
    try items.append(a, button(cc, "printers_add_cancel", "Cancel setup", 0, busy(self), dismiss));
    return card(a, items.items);
}
fn discoverClicked(raw: ?*anyopaque, _: usize) void {
    runAdmin(owner(raw), .discover);
}
fn deviceClicked(raw: ?*anyopaque, id: usize) void {
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
fn normalizedAddress(a: A, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "://") != null) return a.dupe(u8, trimmed);
    return std.fmt.allocPrint(a, "ipp://{s}/ipp/print", .{trimmed});
}
fn selectedAddress(self: *Section) ![]const u8 {
    const value = fieldValue(self, .address);
    return if (self.add_discovered) self.arena.allocator().dupe(u8, value) else normalizedAddress(self.arena.allocator(), value);
}
fn connectionClicked(raw: ?*anyopaque, _: usize) void {
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
fn applyConnectionClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.form != .connection) return;
    const printer = chosen(cc) orelse return;
    const uri = selectedAddress(&cc.printers) catch return;
    runAdmin(cc, .{ .device = .{ .name = printer.name, .uri = uri, .discovered = cc.printers.add_discovered } });
}
fn probeClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const uri = selectedAddress(&cc.printers) catch return;
    setup.validateUri(uri, cc.printers.add_discovered) catch {
        cc.printers.message = "Enter a supported printer address without credentials.";
        cc.refresh();
        return;
    };
    if (!std.mem.startsWith(u8, uri, "ipp://") and !std.mem.startsWith(u8, uri, "ipps://")) {
        cc.printers.message = "Address checks support IPP printers. Other connections can be tested with an explicit print after setup.";
        cc.refresh();
        return;
    }
    setField(&cc.printers, .address, uri) catch return;
    cc.printers.probe_address_len = @min(uri.len, cc.printers.probe_address.len);
    @memcpy(cc.printers.probe_address[0..cc.printers.probe_address_len], uri[0..cc.printers.probe_address_len]);
    runClient(cc, .{ .probe = uri });
}
fn driverChanged(raw: ?*anyopaque, _: usize, index: usize) void {
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
fn createClicked(raw: ?*anyopaque, _: usize) void {
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
fn finishCreate(cc: *panel.ControlCenter) void {
    const pending = cc.printers.pending_add orelse return;
    cc.printers.pending_add = null;
    defer pending.destroy();
    const state = cc.printers.client.?.current orelse return;
    if (state.failure != null or cc.printers.client.?.failure != null or state.generation != cc.printers.client.?.generation) {
        cc.printers.message = "Could not verify existing printers. Refresh before creating a queue.";
        return;
    }
    const data = state.cups orelse return;
    var arguments = pending.arguments;
    arguments.existing_names = queueNames(pending.arena.allocator(), data) catch return;
    runAdmin(cc, .{ .add = arguments });
}
fn queueRenameClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const name = fieldValue(&cc.printers, .queue_name);
    if (!setup.validName(name)) {
        cc.printers.message = "Use letters, numbers, dots, hyphens or underscores for the queue identifier.";
        cc.refresh();
        return;
    }
    cc.printers.form = .queue_rename;
    cc.refresh();
}
fn queueRenameConfirm(raw: ?*anyopaque, _: usize) void {
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
fn submitRename(cc: *panel.ControlCenter) void {
    const pending = cc.printers.pending_rename orelse return;
    const state = cc.printers.client.?.current orelse return;
    if (state.failure != null or cc.printers.client.?.failure != null or state.generation != cc.printers.client.?.generation) {
        cc.printers.pending_rename = null;
        cc.printers.message = "Could not verify existing printers before changing the identifier.";
        return;
    }
    const data = state.cups orelse return;
    const old = pending.old[0..pending.old_len];
    if (data.jobs_error != null) {
        cc.printers.pending_rename = null;
        cc.printers.message = "Could not verify the printer's jobs. Refresh before changing its identifier.";
        return;
    }
    for (data.jobs) |job| if (job.cancellable() and std.mem.eql(u8, job.printer, old)) {
        cc.printers.pending_rename = null;
        cc.printers.message = "Finish or cancel the printer's jobs before changing its identifier.";
        return;
    };
    var source_exists = false;
    for (data.printers) |printer| if (std.mem.eql(u8, printer.name, old)) {
        source_exists = true;
        break;
    };
    if (!source_exists) {
        cc.printers.pending_rename = null;
        cc.printers.message = "The printer no longer exists. Refresh before retrying.";
        return;
    }
    runAdmin(cc, .{ .rename = .{ .name = old, .new_name = pending.new[0..pending.new_len], .existing_names = queueNames(cc.printers.arena.allocator(), data) catch return } });
    if (cc.printers.administration) |manager| if (!manager.busy) {
        cc.printers.pending_rename = null;
    };
}
fn finishRename(cc: *panel.ControlCenter) void {
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
    } else cc.printers.message = "The queue identifier change could not be verified. Review the printer list before retrying.";
}
fn mediaFor(printer: cups.Printer, state: *const printing.State) ?tools.Media {
    if (tools.mediaFromKeyword(printer.media)) |media| return media;
    if (std.mem.eql(u8, state.selected, printer.name)) {
        for (state.groups) |option_group| for (option_group.options) |option| {
            if (!std.mem.eql(u8, option.name, "PageSize")) continue;
            return @import("../../printing/options.zig").ppdMediaDimensions(state.ppd, option.default orelse return null);
        };
    }
    return null;
}
fn measurement(self: *Section, id: Field) ?f64 {
    const result = std.fmt.parseFloat(f64, fieldValue(self, id)) catch return null;
    if (!std.math.isFinite(result) or result <= 0) return null;
    return result * @as(f64, if (self.inches) 25.4 else 1);
}
fn loadedMedia(self: *Section) ?tools.Media {
    const media: tools.Media = .{ .width_mm = measurement(self, .loaded_width) orelse return null, .height_mm = measurement(self, .loaded_height) orelse return null };
    return if (media.valid()) media else null;
}
fn toolsForm(self: *Section, cc: *panel.ControlCenter, a: A, state: *const printing.State, printer: cups.Printer) !W {
    var items: std.ArrayList(W) = .empty;
    try items.append(a, panel.sectionTitle("Print tests and scale"));
    try items.append(a, .{ .name = "printers_label", .kind = .{ .checkbox = .{ .label = "This is a label printer", .checked = printer.user.label, .disabled = busy(self), .owner = cc, .on_change = labelChanged } }, .width = .{ .percent = 1 } });
    try items.append(a, .{ .name = "printers_units", .kind = .{ .select = .{ .labels = &.{ "Millimetres", "Inches" }, .selected = @intFromBool(self.inches), .owner = cc, .on_change = unitsChanged } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } });
    try items.append(a, try entry(self, cc, a, .loaded_width, "Loaded paper width", ""));
    try items.append(a, try entry(self, cc, a, .loaded_height, "Loaded paper height", ""));
    try items.append(a, button(cc, "printers_save_media", "Remember loaded paper size", 0, busy(self) or loadedMedia(self) == null, saveMedia));
    const language_labels = try a.alloc([]const u8, tools.probe_languages.len + 1);
    language_labels[0] = "Unknown language — check the self-test sheet";
    var lang_index: usize = 0;
    for (tools.probe_languages, 0..) |language, index| {
        language_labels[index + 1] = language.label();
        if (self.language == language) lang_index = index + 1;
    }
    try items.append(a, .{ .name = "printers_language", .kind = .{ .select = .{ .labels = language_labels, .selected = lang_index, .disabled = busy(self), .owner = cc, .on_change = languageChanged } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } });
    try items.append(a, text("Check the printer's self-test sheet for its language and real resolution.", true));
    try items.append(a, try entry(self, cc, a, .raw_dpi, "Raw sample resolution (dpi)", ""));
    const awaiting_result = self.form == .test_result;
    try items.append(a, button(cc, "printers_test_page", "Test page through the driver…", @intFromEnum(printing.TestKind.driver), busy(self) or awaiting_result, testClicked));
    try items.append(a, button(cc, "printers_test_raw", "Test without the driver…", @intFromEnum(printing.TestKind.raw), busy(self) or awaiting_result or self.language == null, testClicked));
    try items.append(a, button(cc, "printers_probe_language", "Try one language sample…", @intFromEnum(printing.TestKind.raw), busy(self) or awaiting_result, probeLanguage));
    if (printer.label_media) try items.append(a, text("The driver reports label media.", true));
    if (printer.user.label or printer.label_media) {
        try items.append(a, button(cc, "printers_check_scale", "Print a 2 × 3 inch ruler…", @intFromEnum(printing.TestKind.ruler), busy(self) or awaiting_result, testClicked));
        try items.append(a, text("Measure the rectangle edge to edge in the selected unit. Print scaling is disabled for this test.", true));
        try items.append(a, try entry(self, cc, a, .measured_width, "Measured rectangle width", ""));
        try items.append(a, try entry(self, cc, a, .measured_height, "Measured rectangle height", ""));
        try items.append(a, button(cc, "printers_calibrate", "Check measured scale", 0, busy(self), calibrate));
        if (self.suggested) |suggestion| {
            const r = resolution(suggestion).?;
            try items.append(a, text(try std.fmt.allocPrint(a, "Suggested supported resolution: {d} × {d} dpi", .{ r.x_dpi, r.y_dpi }), false));
            const selectable = resolutionChoice(state, suggestion) != null;
            try items.append(a, button(cc, "printers_apply_resolution", "Use suggested resolution", 0, busy(self) or !canAdmin(self) or !selectable, applyResolution));
            if (!selectable) try items.append(a, text("This driver does not expose the suggested resolution as a queue setting. Review its quality or driver choices.", true));
        }
    }
    if (self.form == .test_confirm) {
        const media = loadedMedia(self);
        try items.append(a, text(try std.fmt.allocPrint(a, "Print one {s} test on {s}?", .{ @tagName(self.test_kind), if (printer.info.len != 0) printer.info else printer.name }), false));
        if (media) |size| try items.append(a, text(try std.fmt.allocPrint(a, "Paper: {d:.2} × {d:.2} mm", .{ size.width_mm, size.height_mm }), true));
        try items.append(a, text(try std.fmt.allocPrint(a, "Queue paper setting: {s}. Check that this matches the loaded paper.", .{if (printer.media.len > 0) printer.media else "Unavailable"}), true));
        if (self.test_kind == .raw) try items.append(a, text(try std.fmt.allocPrint(a, "Language: {s}. This sample bypasses the filters and uses the queue's backend.", .{if (self.language) |language| language.label() else "Unknown"}), true));
        if (self.test_kind == .raw) try items.append(a, text(tools.self_test_help, true));
        try items.append(a, button(cc, "printers_test_confirm", "Print one test", 0, busy(self) or media == null or (self.test_kind == .raw and (self.language == null or rawDpi(self) == null)), confirmTest));
        try items.append(a, button(cc, "printers_test_cancel", "Cancel test", 0, busy(self), dismiss));
    }
    if (self.form == .test_result) {
        const valid = state.receipt != null and state.receipt.?.matchesQueue(printer.name) and state.receipt.?.kind == self.test_kind and state.action_error == null;
        try items.append(a, text("Did the test produce printed output? CUPS completion alone cannot tell.", false));
        try items.append(a, button(cc, "printers_test_printed", "It printed", 0, busy(self) or !valid, testOutcome));
        try items.append(a, button(cc, "printers_test_blank", "Blank or no output", 1, busy(self) or !valid, testOutcome));
        try items.append(a, button(cc, "printers_test_close", "Close test result", 0, busy(self), dismiss));
    }
    if (printer.user.raw == .printed and printer.user.driver == .no_output) try items.append(a, text("The raw sample printed but the driver test did not: investigate the driver, filters, paper size and resolution.", false));
    if (printer.user.raw == .no_output and printer.user.driver == .no_output) try items.append(a, text("Neither test produced output: check the backend, connection, printer and loaded paper.", false));
    return card(a, items.items);
}
fn labelChanged(raw: ?*anyopaque, _: usize, checked: bool) void {
    const cc = owner(raw);
    const printer = chosen(cc) orelse return;
    var prefs = printer.user;
    prefs.label = checked;
    runClient(cc, .{ .save = .{ .queue = printer.name, .state = prefs } });
}
fn saveMedia(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const printer = chosen(cc) orelse return;
    var prefs = printer.user;
    prefs.expected_media = loadedMedia(&cc.printers) orelse return;
    runClient(cc, .{ .save = .{ .queue = printer.name, .state = prefs } });
}
fn languageChanged(raw: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(raw);
    if (index > tools.probe_languages.len) return;
    cc.printers.language = if (index == 0) null else tools.probe_languages[index - 1];
    const printer = chosen(cc) orelse return;
    var prefs = printer.user;
    prefs.language = cc.printers.language;
    runClient(cc, .{ .save = .{ .queue = printer.name, .state = prefs } });
}
fn unitsChanged(raw: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(raw);
    if (index > 1 or cc.printers.inches == (index == 1)) return;
    for ([_]Field{ .loaded_width, .loaded_height, .measured_width, .measured_height }) |id| {
        const mm = measurement(&cc.printers, id) orelse continue;
        var buffer: [64]u8 = undefined;
        const converted = std.fmt.bufPrint(&buffer, "{d:.3}", .{mm / @as(f64, if (index == 1) 25.4 else 1)}) catch continue;
        setField(&cc.printers, id, converted) catch {};
    }
    cc.printers.inches = index == 1;
    cc.printers.suggested = null;
    cc.refresh();
}
fn testClicked(raw: ?*anyopaque, kind: usize) void {
    const cc = owner(raw);
    if (kind > @intFromEnum(printing.TestKind.ruler) or chosen(cc) == null) return;
    cc.printers.test_kind = @enumFromInt(kind);
    cc.printers.form = .test_confirm;
    cc.refresh();
}
fn probeLanguage(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.language == null) cc.printers.language = .tspl;
    cc.printers.message = "Choose a language from the self-test sheet or try one sample. Record the outcome before choosing another language.";
    testClicked(raw, @intFromEnum(printing.TestKind.raw));
}
fn confirmTest(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.form != .test_confirm or busy(&cc.printers)) return;
    if (cc.printers.test_kind == .raw and (cc.printers.language == null or rawDpi(&cc.printers) == null)) return;
    const printer = chosen(cc) orelse return;
    const state = cc.printers.client.?.current orelse return;
    const media = loadedMedia(&cc.printers) orelse return;
    cc.printers.form = .test_result;
    runClient(cc, .{ .test_print = .{ .queue = printer.name, .kind = cc.printers.test_kind, .media = media, .media_keyword = printer.media, .language = cc.printers.language, .dpi = rawDpi(&cc.printers) orelse 203, .queue_resolution = queueResolution(printer, state) } });
}
fn rawDpi(self: *Section) ?u32 {
    const dpi = std.fmt.parseInt(u32, fieldValue(self, .raw_dpi), 10) catch return null;
    return if (dpi >= 72 and dpi <= 1200) dpi else null;
}
fn testOutcome(raw: ?*anyopaque, result: usize) void {
    const cc = owner(raw);
    if (cc.printers.form != .test_result or busy(&cc.printers)) return;
    const state = cc.printers.client.?.current orelse return;
    const receipt = state.receipt orelse return;
    if (receipt.kind != cc.printers.test_kind or state.action_error != null) return;
    const printer = chosen(cc) orelse return;
    if (!receipt.matchesQueue(printer.name)) return;
    var prefs = printer.user;
    const outcome: preferences.Outcome = if (result == 0) .printed else .no_output;
    switch (cc.printers.test_kind) {
        .driver => prefs.driver = outcome,
        .raw => prefs.raw = outcome,
        .ruler => {
            prefs.ruler = outcome;
            prefs.ruler_resolution = receipt.queue_resolution;
        },
    }
    prefs.language = receipt.language;
    prefs.expected_media = receipt.media;
    cc.printers.form = .none;
    runClient(cc, .{ .save = .{ .queue = printer.name, .state = prefs } });
}
fn calibrate(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (busy(&cc.printers)) return;
    const printer = chosen(cc) orelse return;
    const state = cc.printers.client.?.current orelse return;
    const options_module = @import("../../printing/options.zig");
    const receipt_resolution = if (state.receipt) |receipt| if (receipt.kind == .ruler and receipt.matchesQueue(printer.name)) receipt.queue_resolution else null else null;
    const current_value = receipt_resolution orelse printer.user.ruler_resolution orelse queueResolution(printer, state);
    const current = current_value orelse {
        cc.printers.message = "The current printer resolution is unavailable.";
        cc.refresh();
        return;
    };
    var supported: std.ArrayList(cups.ipp.Resolution) = .empty;
    const a = cc.printers.arena.allocator();
    for (printer.attributes) |attr| if (std.mem.eql(u8, attr.name, "printer-resolution-supported")) {
        if (attr.resolution()) |r| supported.append(a, r) catch return;
    };
    if (supported.items.len == 0) supported.appendSlice(a, options_module.resolutionChoices(a, state.groups) catch &.{}) catch return;
    cc.printers.suggested = tools.suggestResolution(current, supported.items, measurement(&cc.printers, .measured_width) orelse 0, measurement(&cc.printers, .measured_height) orelse 0);
    cc.printers.message = if (cc.printers.suggested != null) "Review the suggested resolution, then apply it explicitly." else "No supported resolution consistently matches both measurements. Check the ruler and print scaling.";
    cc.refresh();
}
fn queueResolution(printer: cups.Printer, state: *const printing.State) ?cups.ipp.Resolution {
    for (state.groups) |option_group| for (option_group.options) |option| {
        if (driver_options.resolutionOption(option) and option.source == .ppd) if (option.default) |setting| return driver_options.parseResolution(setting);
    };
    return printer.resolution;
}
fn applyResolution(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const r = cc.printers.suggested orelse return;
    const state = cc.printers.client.?.current orelse return;
    const match = resolutionChoice(state, r) orelse return;
    changeOption(cc, match.option, match.value);
}
const ResolutionChoice = struct { option: driver_options.Option, value: []const u8 };
fn resolutionChoice(state: *const printing.State, r: cups.ipp.Resolution) ?ResolutionChoice {
    for (state.groups) |option_group| for (option_group.options) |option| {
        if (option.source != .ppd or !driver_options.resolutionOption(option)) continue;
        for (option.choices) |choice| {
            const parsed = driver_options.parseResolution(choice.value) orelse continue;
            if (parsed.x == r.x and parsed.y == r.y and parsed.units == r.units) {
                return .{ .option = option, .value = choice.value };
            }
        }
    };
    return null;
}
