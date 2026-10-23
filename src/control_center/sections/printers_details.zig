//! The selected printer's page: status and diagnosis, management, printing options and the job list.

const i18n = @import("i18n");
const std = @import("std");
const ui = @import("ui");
const panel = @import("../panel.zig");
const printing = @import("../../printing/client.zig");
const cups = @import("../../printing/cups.zig");
const ladder = @import("../../printing/ladder.zig");
const usb = @import("../../printing/usb_sysfs.zig");
const tools = @import("../../printing/tools.zig");
const preferences = @import("../../printing/preferences.zig");
const driver_options = @import("../../printing/options.zig");
const W = ui.layout.Widget;
const A = std.mem.Allocator;
const printers = @import("printers.zig");
const Section = printers.Section;
const text = printers.text;
const named = printers.named;
const group = printers.group;
const card = printers.card;
const button = printers.button;
const isOpen = printers.isOpen;
const disclosure = printers.disclosure;
const actionRow = printers.actionRow;
const owner = printers.owner;
const cancel = printers.cancel;
const copy = printers.copy;
const busy = printers.busy;
const canAdmin = printers.canAdmin;
const fieldValue = printers.fieldValue;
const setField = printers.setField;
const entry = printers.entry;
const dismiss = printers.dismiss;
const resumeClicked = printers.resumeClicked;
const disableClicked = printers.disableClicked;
const acceptingClicked = printers.acceptingClicked;
const defaultClicked = printers.defaultClicked;
const systemDefaultClicked = printers.systemDefaultClicked;
const renameClicked = printers.renameClicked;
const removeClicked = printers.removeClicked;
const removeConfirm = printers.removeConfirm;
const optionChanged = printers.optionChanged;
const rangeChanged = printers.rangeChanged;
const rangeApply = printers.rangeApply;
const connectionClicked = printers.connectionClicked;
const queueRenameClicked = printers.queueRenameClicked;
const queueRenameConfirm = printers.queueRenameConfirm;
const mediaFor = printers.mediaFor;
const toolsForm = printers.toolsForm;
const testClicked = printers.testClicked;

pub fn splitReasons(a: A, values: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitSequence(u8, values, ", ");
    while (parts.next()) |part| if (part.len > 0) {
        try out.append(a, part);
    };
    return out.toOwnedSlice(a);
}

pub fn showReasons(a: A, content: *std.ArrayList(W), values: []const u8) !void {
    for (try splitReasons(a, values)) |reason| {
        const label = ladder.reasonText(reason) orelse reason;
        if (!std.mem.eql(u8, reason, "none")) try content.append(a, text(try a.dupe(u8, label), true));
    }
}

pub fn resolution(value: ?cups.ipp.Resolution) ?ladder.Resolution {
    const r = value orelse return null;
    if (r.x <= 0 or r.y <= 0) return null;
    const x = if (r.units == .dpi) r.x else @divTrunc(@as(i64, r.x) * 254 + 50, 100);
    const y = if (r.units == .dpi) r.y else @divTrunc(@as(i64, r.y) * 254 + 50, 100);
    if (x > std.math.maxInt(u32) or y > std.math.maxInt(u32)) return null;
    return .{ .x_dpi = @intCast(x), .y_dpi = @intCast(y) };
}

pub fn diagnostic(a: A, state: *const printing.State, data: cups.Snapshot, printer: cups.Printer) !ladder.Input {
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

pub fn details(self: *Section, cc: *panel.ControlCenter, a: A, content: *std.ArrayList(W), state: *const printing.State, data: cups.Snapshot, printer: cups.Printer) !void {
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
    if (printer.model.len > 0) try header.append(a, text(try a.dupe(u8, printer.model), true));
    try header.append(a, named(text(cups.printerState(printer.state), false), "printers_state"));
    try showReasons(a, &header, printer.reasons);
    var repeated_message = std.ascii.eqlIgnoreCase(printer.message, cups.printerState(printer.state));
    for (try splitReasons(a, printer.reasons)) |reason| {
        if (std.ascii.eqlIgnoreCase(printer.message, ladder.reasonText(reason) orelse reason)) repeated_message = true;
    }
    if (printer.message.len > 0 and !repeated_message) try header.append(a, text(try a.dupe(u8, printer.message), true));
    for (printer.markers) |marker| {
        if (marker.level == null) continue;
        try header.append(a, text(if (marker.level) |level| try std.fmt.allocPrint(a, "{s}: {d}%", .{ marker.name, level }) else try i18n.allocPrint(a, i18n.tr("{name}: level unavailable"), .{ .name = marker.name }), true));
        if (marker.level) |level| {
            const fill = try a.create(W);
            fill.* = .{ .kind = .{ .rect = .{ .color = panel.palette().accent, .radius = 3 } }, .width = .{ .percent = @as(f32, @floatFromInt(level)) / 100 }, .height = .{ .fixed = 6 } };
            try header.append(a, .{ .kind = .{ .rect = .{ .color = panel.palette().border_soft, .radius = 3 } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 6 }, .children = fill[0..1] });
        }
    }
    if (printer.accepting == false) try header.append(a, text(i18n.tr("Not accepting new jobs"), false));
    const result = ladder.evaluate(try diagnostic(a, state, data, printer));
    if (result.firstFailure()) |first| {
        const row = result.rows[first];
        // Historical job failures belong in history and troubleshooting.
        if (row.layer != .last_job and row.layer != .queue) try header.append(a, text(try a.dupe(u8, row.message), false));
    }
    if (printer.state == 5) try header.append(a, button(cc, "printers_resume", i18n.tr("Resume printer"), 0, !canAdmin(self) or busy(self), resumeClicked));
    try header.append(a, try actionRow(a, cc, &.{
        button(cc, "printers_test_page", i18n.tr("Print test page…"), @intFromEnum(printing.TestKind.driver), busy(self) or self.form == .test_result, testClicked),
        button(cc, "printers_default", if (std.mem.eql(u8, data.user_default, printer.name)) i18n.tr("Your default printer") else i18n.tr("Set as my default"), 0, busy(self) or std.mem.eql(u8, data.user_default, printer.name), defaultClicked),
        disclosure(self, cc, "printers_manage", i18n.tr("Manage…"), .manage),
    }));
    if (preferences.overrideMessage(cc.server.environ)) |message| try header.append(a, text(message, true));
    if (isOpen(self, .manage)) try header.append(a, try management(self, cc, a, printer));
    try content.append(a, try card(a, header.items));
    const testing = self.form == .test_confirm or self.form == .test_result;
    if (testing) try content.append(a, named(try toolsForm(self, cc, a, state, printer), "printers_test_form"));
    try content.append(a, try jobList(self, cc, a, data, printer));
    try content.append(a, try printingOptions(self, cc, a, state, printer));

    var troubleshooting: std.ArrayList(W) = .empty;
    try troubleshooting.append(a, disclosure(self, cc, "printers_diagnostics", i18n.tr("Troubleshooting"), .troubleshooting));
    if (isOpen(self, .troubleshooting)) {
        const layer_names = [_]i18n.Message{ i18n.msg("Connection"), i18n.msg("Device node"), i18n.msg("CUPS"), i18n.msg("Queue"), i18n.msg("Backend"), i18n.msg("Media and resolution"), i18n.msg("Last job") };
        for (result.rows, layer_names) |row, name| {
            try troubleshooting.append(a, text(try std.fmt.allocPrint(a, "{s} · {s}: {s}", .{ switch (row.verdict) {
                .pass => i18n.tr("Pass"),
                .fail => i18n.tr("Problem"),
                .unknown => i18n.tr("Unknown"),
            }, name.get(), row.message }), row.verdict != .fail));
            if (row.verdict == .fail and row.fix.len > 0) try troubleshooting.append(a, text(row.fix, true));
        }
        try troubleshooting.append(a, button(cc, "printers_copy_report", if (self.copied) i18n.tr("Report copied") else i18n.tr("Copy diagnostic report"), 0, false, copy));
        try troubleshooting.append(a, text(i18n.tr("Reports omit document names, user names, USB serials and private printer addresses."), true));
    }
    try content.append(a, try card(a, troubleshooting.items));
    // A test owns the media fields until its confirmation/result is dismissed.
    if (!testing) {
        try content.append(a, disclosure(self, cc, "printers_label_tools", i18n.tr("Label printer and advanced test tools"), .label_tools));
        if (isOpen(self, .label_tools)) try content.append(a, try toolsForm(self, cc, a, state, printer));
    }
}

pub fn management(self: *Section, cc: *panel.ControlCenter, a: A, printer: cups.Printer) !W {
    var items: std.ArrayList(W) = .empty;
    try items.append(a, text(try i18n.allocPrint(a, i18n.tr("Queue: {name}"), .{ .name = printer.name }), true));
    try items.append(a, button(cc, "printers_disable", i18n.tr("Disable printer"), 0, !canAdmin(self) or busy(self) or printer.state == 5, disableClicked));
    try items.append(a, button(cc, "printers_accepting", if (printer.accepting == false) i18n.tr("Accept jobs") else i18n.tr("Stop accepting jobs"), 0, !canAdmin(self) or busy(self), acceptingClicked));
    try items.append(a, button(cc, "printers_connection", i18n.tr("Change connection…"), 0, !canAdmin(self) or busy(self), connectionClicked));
    try items.append(a, button(cc, "printers_system_default", i18n.tr("Set as system default"), 0, !canAdmin(self) or busy(self) or printer.is_default, systemDefaultClicked));
    try items.append(a, try entry(self, cc, a, .rename, i18n.tr("Display name"), ""));
    try items.append(a, button(cc, "printers_rename_save", i18n.tr("Save display name"), 0, !canAdmin(self) or busy(self), renameClicked));
    try items.append(a, try entry(self, cc, a, .queue_name, i18n.tr("Queue identifier"), ""));
    try items.append(a, button(cc, "printers_queue_rename", i18n.tr("Change queue identifier…"), 0, !canAdmin(self) or busy(self) or std.ascii.eqlIgnoreCase(fieldValue(self, .queue_name), printer.name), queueRenameClicked));
    if (self.form == .queue_rename) {
        try items.append(a, text(try i18n.allocPrint(a, i18n.tr("Change {old} to {name}?"), .{ .old = printer.name, .name = fieldValue(self, .queue_name) }), false));
        try items.append(a, text(i18n.tr("CUPS copies the queue and removes its old identifier. Finish all jobs first. Check the resulting driver options afterwards."), true));
        try items.append(a, button(cc, "printers_queue_rename_confirm", i18n.tr("Change this queue identifier"), 0, !canAdmin(self) or busy(self), queueRenameConfirm));
        try items.append(a, button(cc, "printers_queue_rename_cancel", i18n.tr("Keep identifier"), 0, busy(self), dismiss));
    }
    if (self.form == .remove) {
        try items.append(a, text(try i18n.allocPrint(a, i18n.tr("Remove printer {name} ({queue})? This deletes its queue and settings."), .{ .name = if (printer.info.len > 0) printer.info else printer.name, .queue = printer.name }), false));
        try items.append(a, button(cc, "printers_remove_confirm", i18n.tr("Remove this printer"), 0, !canAdmin(self) or busy(self), removeConfirm));
        try items.append(a, button(cc, "printers_remove_cancel", i18n.tr("Keep printer"), 0, busy(self), dismiss));
    } else try items.append(a, button(cc, "printers_remove", i18n.tr("Remove printer…"), 0, !canAdmin(self) or busy(self), removeClicked));
    return group(a, items.items);
}

pub const Preference = enum { paper, resolution, colour, sides, quality };

pub fn preference(option: driver_options.Option) ?Preference {
    const name = option.name;
    if (driver_options.resolutionOption(option)) return .resolution;
    if (std.mem.eql(u8, name, "media") or std.mem.eql(u8, name, "PageSize") or std.mem.eql(u8, name, "PageRegion")) return .paper;
    inline for (.{ "sides", "Duplex", "JCLDuplex", "EFDuplex", "KD03Duplex" }) |key| if (std.mem.eql(u8, name, key)) return .sides;
    inline for (.{ "print-color-mode", "ColorModel", "ColorMode", "OutputMode" }) |key| if (std.mem.eql(u8, name, key)) return .colour;
    inline for (.{ "print-quality", "cupsPrintQuality", "PrintQuality", "Quality" }) |key| if (std.mem.eql(u8, name, key)) return .quality;
    return null;
}

pub fn printingOptions(self: *Section, cc: *panel.ControlCenter, a: A, state: *const printing.State, printer: cups.Printer) !W {
    var options: std.ArrayList(W) = .empty;
    try options.append(a, panel.sectionTitle(i18n.tr("Printing preferences")));
    const groups: []const driver_options.Group = if (std.mem.eql(u8, state.selected, printer.name)) state.groups else &.{};
    // Prefer the driver's selectable default over an alias of the same setting.
    var common: [@typeInfo(Preference).@"enum".fields.len]?*const driver_options.Option = @splat(null);
    for (groups) |option_group| for (option_group.options) |*option| {
        const kind = preference(option.*) orelse continue;
        if (option.choices.len == 0) continue;
        const slot = &common[@intFromEnum(kind)];
        if (slot.* == null or (slot.*.?.source == .ipp and option.source == .ppd)) slot.* = option;
    };
    if (common[@intFromEnum(Preference.paper)] == null) try options.append(a, text(try i18n.allocPrint(a, i18n.tr("Paper: {paper}"), .{ .paper = if (printer.media.len > 0) printer.media else i18n.tr("Unavailable") }), true));
    if (common[@intFromEnum(Preference.resolution)] == null) {
        if (resolution(printer.resolution)) |r| {
            try options.append(a, text(try i18n.allocPrint(a, i18n.tr("Resolution: {x} × {y} dpi"), .{ .x = r.x_dpi, .y = r.y_dpi }), true));
        } else try options.append(a, text(i18n.tr("Resolution: Unavailable"), true));
    }
    if (common[@intFromEnum(Preference.colour)] == null and printer.color.len > 0) try options.append(a, text(try i18n.allocPrint(a, i18n.tr("Colour: {colour}"), .{ .colour = printer.color }), true));
    if (common[@intFromEnum(Preference.sides)] == null and printer.sides.len > 0) try options.append(a, text(try i18n.allocPrint(a, i18n.tr("Sides: {sides}"), .{ .sides = printer.sides }), true));
    var refs: std.ArrayList(driver_options.Option) = .empty;
    for (common) |option| if (option) |value| try optionWidget(self, cc, a, &options, &refs, state, value.*);
    var has_more = false;
    for (groups) |option_group| for (option_group.options) |option| {
        if (preference(option) == null and (option.choices.len > 0 or option.range != null)) has_more = true;
        if (std.mem.eql(u8, option.name, "PageSize")) if (option.default) |value| {
            if (driver_options.ppdMargins(state.ppd, value) != null) has_more = true;
        };
    };
    if (has_more) try options.append(a, disclosure(self, cc, "printers_more_options", i18n.tr("More printing options"), .more_options));
    if (isOpen(self, .more_options)) for (groups) |option_group| {
        var heading = false;
        for (option_group.options) |option| {
            if (std.mem.eql(u8, option.name, "PageSize")) {
                if (driver_options.ppdMargins(state.ppd, option.default orelse continue)) |margins| try options.append(a, text(try i18n.allocPrint(a, i18n.tr("Margins (mm): left {left}, right {right}, top {top}, bottom {bottom}"), .{ .left = try std.fmt.allocPrint(a, "{d:.1}", .{margins.left_mm}), .right = try std.fmt.allocPrint(a, "{d:.1}", .{margins.right_mm}), .top = try std.fmt.allocPrint(a, "{d:.1}", .{margins.top_mm}), .bottom = try std.fmt.allocPrint(a, "{d:.1}", .{margins.bottom_mm}) }), true));
            }
            if (preference(option) != null or (option.choices.len == 0 and option.range == null)) continue;
            if (!heading) {
                try options.append(a, panel.sectionTitle(try a.dupe(u8, option_group.label)));
                heading = true;
            }
            try optionWidget(self, cc, a, &options, &refs, state, option);
        }
    };
    self.option_refs = refs.items;
    return card(a, options.items);
}

pub fn optionWidget(self: *Section, cc: *panel.ControlCenter, a: A, options: *std.ArrayList(W), refs: *std.ArrayList(driver_options.Option), state: *const printing.State, option: driver_options.Option) !void {
    const editable = state.ppd.len > 0 and driver_options.queueEditable(option, state.groups) and (option.range == null or option.source == .ppd);
    if (option.choices.len == 0) {
        if (option.range) |range| {
            if (option.name.len > 128 or range.upper > 16_777_216) return;
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
            const draft = &self.ranges[index orelse return];
            draft.range = range;
            draft.value = std.math.clamp(draft.value, @as(f32, @floatFromInt(range.lower)), @as(f32, @floatFromInt(range.upper)));
            try options.append(a, text(try a.dupe(u8, option.label), false));
            if (canAdmin(self) and !busy(self) and editable) {
                try options.append(a, .{ .name = try std.fmt.allocPrint(a, "printers_range_{s}", .{option.name}), .kind = .{ .stepper = .{ .value = draft.value, .min = @floatFromInt(range.lower), .max = @floatFromInt(range.upper), .step = 1, .owner = cc, .id = index.?, .on_change = rangeChanged } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 34 } });
                try options.append(a, button(cc, try std.fmt.allocPrint(a, "printers_option_{s}_apply", .{option.name}), i18n.tr("Apply value"), index.?, false, rangeApply));
            } else {
                try options.append(a, text(try i18n.allocPrint(a, i18n.tr("{value} (supported {min}–{max})"), .{ .value = try std.fmt.allocPrint(a, "{d:.0}", .{draft.value}), .min = range.lower, .max = range.upper }), true));
                if (!editable) try options.append(a, text(i18n.tr("This range has no selectable queue setting in the current driver."), true));
            }
        }
        return;
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
    try options.append(a, try actionRow(a, cc, &.{
        text(try a.dupe(u8, option.label), false),
        .{ .name = try std.fmt.allocPrint(a, "printers_option_{s}", .{option.name}), .kind = .{ .select = .{ .labels = labels, .selected = selected, .disabled = !canAdmin(self) or busy(self) or !editable, .owner = cc, .id = id, .on_change = optionChanged } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } },
    }));
    if (!editable) try options.append(a, text(i18n.tr("This capability has no selectable queue default in the current driver."), true));
}

pub fn historical(job: cups.Job) bool {
    return if (job.state) |value| value >= 7 and value <= 9 else false;
}

pub fn jobList(self: *Section, cc: *panel.ControlCenter, a: A, data: cups.Snapshot, printer: cups.Printer) !W {
    var items: std.ArrayList(W) = .empty;
    var active: usize = 0;
    var history: usize = 0;
    for (data.jobs) |job| {
        if (!job.own or !std.mem.eql(u8, job.printer, printer.name)) continue;
        if (historical(job)) history += 1 else active += 1;
    }
    try items.append(a, panel.sectionTitle(if (active == 0) i18n.tr("Print queue") else try i18n.allocPrint(a, i18n.tr("Print queue · {n}"), .{ .n = active })));
    for (data.jobs) |job| {
        if (!job.own or !std.mem.eql(u8, job.printer, printer.name) or historical(job)) continue;
        try jobRow(self, cc, a, &items, job);
        // Held/stopped jobs remain actionable even with their detail row closed.
        if (job.state == 4 or job.state == 6) {
            try showReasons(a, &items, job.reasons);
            if (job.message.len > 0) try items.append(a, text(try a.dupe(u8, job.message), true));
        }
    }
    if (data.jobs_error) |err| try items.append(a, text(cups.failure(err), true)) else if (active == 0) try items.append(a, text(i18n.tr("No active jobs"), true));
    if (history > 0) {
        try items.append(a, disclosure(self, cc, "printers_history", try i18n.allocPrint(a, i18n.tr("Job history · {n}"), .{ .n = history }), .history));
        if (isOpen(self, .history)) {
            var shown: usize = 0;
            for (data.jobs) |job| {
                if (!job.own or !std.mem.eql(u8, job.printer, printer.name) or !historical(job)) continue;
                if (shown >= self.history_limit) break;
                try jobRow(self, cc, a, &items, job);
                shown += 1;
            }
            if (shown < history) try items.append(a, button(cc, "printers_history_more", i18n.tr("Show more"), 0, false, moreHistory));
        }
    }
    return card(a, items.items);
}

pub fn jobRow(self: *Section, cc: *panel.ControlCenter, a: A, items: *std.ArrayList(W), job: cups.Job) !void {
    var row = button(cc, try std.fmt.allocPrint(a, "printers_job_{d}", .{job.id}), try i18n.allocPrint(a, i18n.tr("Job {id} · {state}"), .{ .id = job.id, .state = cups.jobState(job.state) }), @intCast(@max(0, job.id)), job.id <= 0, jobClicked);
    row.kind.button.variant = .ghost;
    row.kind.button.trailing_icon = if (self.expanded_job == job.id) .chevron_down else .chevron_right;
    if (job.cancellable()) {
        try items.append(a, try actionRow(a, cc, &.{ row, button(cc, try std.fmt.allocPrint(a, "printers_cancel_{d}", .{job.id}), i18n.tr("Cancel job"), @intCast(job.id), self.client.?.busy, cancel) }));
    } else try items.append(a, row);
    if (self.expanded_job == job.id) {
        if (job.sheets) |sheets| if (sheets >= 0) try items.append(a, text(try i18n.allocPrint(a, i18n.trn("{n} completed sheet reported by CUPS", "{n} completed sheets reported by CUPS", @intCast(sheets)), .{ .n = sheets }), true));
        if (job.state != 4 and job.state != 6) {
            try showReasons(a, items, job.reasons);
            if (job.message.len > 0) try items.append(a, text(try a.dupe(u8, job.message), true));
        }
    }
}

pub fn jobClicked(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    const job: i32 = @intCast(id);
    cc.printers.expanded_job = if (cc.printers.expanded_job == job) null else job;
    cc.refresh();
}

pub fn moreHistory(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    cc.printers.history_limit = @min(cups.max_jobs, cc.printers.history_limit + 5);
    cc.refresh();
}
