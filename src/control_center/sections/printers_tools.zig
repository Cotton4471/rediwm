//! Label tools: loaded media, measurements, test prints, calibration and resolution.

const i18n = @import("i18n");
const std = @import("std");
const ui = @import("ui");
const panel = @import("../panel.zig");
const printing = @import("../../printing/client.zig");
const cups = @import("../../printing/cups.zig");
const tools = @import("../../printing/tools.zig");
const preferences = @import("../../printing/preferences.zig");
const driver_options = @import("../../printing/options.zig");
const W = ui.layout.Widget;
const A = std.mem.Allocator;
const printers = @import("printers.zig");
const Field = printers.Field;
const Section = printers.Section;
const text = printers.text;
const card = printers.card;
const button = printers.button;
const resolution = printers.resolution;
const owner = printers.owner;
const busy = printers.busy;
const canAdmin = printers.canAdmin;
const chosen = printers.chosen;
const fieldValue = printers.fieldValue;
const setField = printers.setField;
const entry = printers.entry;
const runClient = printers.runClient;
const dismiss = printers.dismiss;
const changeOption = printers.changeOption;

pub fn mediaFor(printer: cups.Printer, state: *const printing.State) ?tools.Media {
    if (tools.mediaFromKeyword(printer.media)) |media| return media;
    if (std.mem.eql(u8, state.selected, printer.name)) {
        for (state.groups) |option_group| for (option_group.options) |option| {
            if (!std.mem.eql(u8, option.name, "PageSize")) continue;
            return @import("../../printing/options.zig").ppdMediaDimensions(state.ppd, option.default orelse return null);
        };
    }
    return null;
}

pub fn measurement(self: *Section, id: Field) ?f64 {
    const result = std.fmt.parseFloat(f64, fieldValue(self, id)) catch return null;
    if (!std.math.isFinite(result) or result <= 0) return null;
    return result * @as(f64, if (self.inches) 25.4 else 1);
}

pub fn loadedMedia(self: *Section) ?tools.Media {
    const media: tools.Media = .{ .width_mm = measurement(self, .loaded_width) orelse return null, .height_mm = measurement(self, .loaded_height) orelse return null };
    return if (media.valid()) media else null;
}

pub fn toolsForm(self: *Section, cc: *panel.ControlCenter, a: A, state: *const printing.State, printer: cups.Printer) !W {
    var items: std.ArrayList(W) = .empty;
    const testing = self.form == .test_confirm or self.form == .test_result;
    try items.append(a, panel.sectionTitle(if (testing) i18n.tr("Print test") else i18n.tr("Label printer and advanced test tools")));
    if (self.form != .test_result) {
        if (!testing) try items.append(a, .{ .name = "printers_label", .kind = .{ .checkbox = .{ .label = i18n.tr("This is a label printer"), .checked = printer.user.label, .disabled = busy(self), .owner = cc, .on_change = labelChanged } }, .width = .{ .percent = 1 } });
        try items.append(a, .{ .name = "printers_units", .kind = .{ .select = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Millimetres"), i18n.msg("Inches") }), .selected = @intFromBool(self.inches), .owner = cc, .on_change = unitsChanged } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } });
        try items.append(a, try entry(self, cc, a, .loaded_width, i18n.tr("Loaded paper width"), ""));
        try items.append(a, try entry(self, cc, a, .loaded_height, i18n.tr("Loaded paper height"), ""));
        try items.append(a, button(cc, "printers_save_media", i18n.tr("Remember loaded paper size"), 0, busy(self) or loadedMedia(self) == null, saveMedia));
        if (!testing or self.test_kind == .raw) {
            const language_labels = try a.alloc([]const u8, tools.probe_languages.len + 1);
            language_labels[0] = "Unknown language — check the self-test sheet";
            var lang_index: usize = 0;
            for (tools.probe_languages, 0..) |language, index| {
                language_labels[index + 1] = language.label();
                if (self.language == language) lang_index = index + 1;
            }
            try items.append(a, .{ .name = "printers_language", .kind = .{ .select = .{ .labels = language_labels, .selected = lang_index, .disabled = busy(self), .owner = cc, .on_change = languageChanged } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } });
            try items.append(a, text(i18n.tr("Check the printer's self-test sheet for its language and real resolution."), true));
            try items.append(a, try entry(self, cc, a, .raw_dpi, i18n.tr("Raw sample resolution (dpi)"), ""));
        }
    }
    if (!testing) {
        const awaiting_result = self.form == .test_result;
        try items.append(a, button(cc, "printers_test_raw", i18n.tr("Test without the driver…"), @intFromEnum(printing.TestKind.raw), busy(self) or awaiting_result or self.language == null, testClicked));
        try items.append(a, button(cc, "printers_probe_language", i18n.tr("Try one language sample…"), @intFromEnum(printing.TestKind.raw), busy(self) or awaiting_result, probeLanguage));
        if (printer.label_media) try items.append(a, text(i18n.tr("The driver reports label media."), true));
        if (printer.user.label or printer.label_media) {
            try items.append(a, button(cc, "printers_check_scale", i18n.tr("Print a 2 × 3 inch ruler…"), @intFromEnum(printing.TestKind.ruler), busy(self) or awaiting_result, testClicked));
            try items.append(a, text(i18n.tr("Measure the rectangle edge to edge in the selected unit. Print scaling is disabled for this test."), true));
            try items.append(a, try entry(self, cc, a, .measured_width, i18n.tr("Measured rectangle width"), ""));
            try items.append(a, try entry(self, cc, a, .measured_height, i18n.tr("Measured rectangle height"), ""));
            try items.append(a, button(cc, "printers_calibrate", i18n.tr("Check measured scale"), 0, busy(self), calibrate));
            if (self.suggested) |suggestion| {
                const r = resolution(suggestion).?;
                try items.append(a, text(try i18n.allocPrint(a, i18n.tr("Suggested supported resolution: {x} × {y} dpi"), .{ .x = r.x_dpi, .y = r.y_dpi }), false));
                const selectable = resolutionChoice(state, suggestion) != null;
                try items.append(a, button(cc, "printers_apply_resolution", i18n.tr("Use suggested resolution"), 0, busy(self) or !canAdmin(self) or !selectable, applyResolution));
                if (!selectable) try items.append(a, text(i18n.tr("This driver does not expose the suggested resolution as a queue setting. Review its quality or driver choices."), true));
            }
        }
    }
    if (self.form == .test_confirm) {
        const media = loadedMedia(self);
        try items.append(a, text(try i18n.allocPrint(a, i18n.tr("Print one {kind} test on {name}?"), .{ .kind = @tagName(self.test_kind), .name = if (printer.info.len != 0) printer.info else printer.name }), false));
        if (media) |size| try items.append(a, text(try i18n.allocPrint(a, i18n.tr("Paper: {width} × {height} mm"), .{ .width = try std.fmt.allocPrint(a, "{d:.2}", .{size.width_mm}), .height = try std.fmt.allocPrint(a, "{d:.2}", .{size.height_mm}) }), true));
        try items.append(a, text(try i18n.allocPrint(a, i18n.tr("Queue paper setting: {paper}. Check that this matches the loaded paper."), .{ .paper = if (printer.media.len > 0) printer.media else i18n.tr("Unavailable") }), true));
        if (self.test_kind == .raw) try items.append(a, text(try i18n.allocPrint(a, i18n.tr("Language: {language}. This sample bypasses the filters and uses the queue's backend."), .{ .language = if (self.language) |language| language.label() else i18n.tr("Unknown") }), true));
        if (self.test_kind == .raw) try items.append(a, text(tools.self_test_help, true));
        try items.append(a, button(cc, "printers_test_confirm", i18n.tr("Print one test"), 0, busy(self) or media == null or (self.test_kind == .raw and (self.language == null or rawDpi(self) == null)), confirmTest));
        try items.append(a, button(cc, "printers_test_cancel", i18n.tr("Cancel test"), 0, busy(self), dismiss));
    }
    if (self.form == .test_result) {
        const valid = state.receipt != null and state.receipt.?.matchesQueue(printer.name) and state.receipt.?.kind == self.test_kind and state.action_error == null;
        try items.append(a, text(i18n.tr("Did the test produce printed output? CUPS completion alone cannot tell."), false));
        try items.append(a, button(cc, "printers_test_printed", i18n.tr("It printed"), 0, busy(self) or !valid, testOutcome));
        try items.append(a, button(cc, "printers_test_blank", i18n.tr("Blank or no output"), 1, busy(self) or !valid, testOutcome));
        try items.append(a, button(cc, "printers_test_close", i18n.tr("Close test result"), 0, busy(self), dismiss));
    }
    if (printer.user.raw == .printed and printer.user.driver == .no_output) try items.append(a, text(i18n.tr("The raw sample printed but the driver test did not: investigate the driver, filters, paper size and resolution."), false));
    if (printer.user.raw == .no_output and printer.user.driver == .no_output) try items.append(a, text(i18n.tr("Neither test produced output: check the backend, connection, printer and loaded paper."), false));
    return card(a, items.items);
}

pub fn labelChanged(raw: ?*anyopaque, _: usize, checked: bool) void {
    const cc = owner(raw);
    const printer = chosen(cc) orelse return;
    var prefs = printer.user;
    prefs.label = checked;
    runClient(cc, .{ .save = .{ .queue = printer.name, .state = prefs } });
}

pub fn saveMedia(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const printer = chosen(cc) orelse return;
    var prefs = printer.user;
    prefs.expected_media = loadedMedia(&cc.printers) orelse return;
    runClient(cc, .{ .save = .{ .queue = printer.name, .state = prefs } });
}

pub fn languageChanged(raw: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(raw);
    if (index > tools.probe_languages.len) return;
    cc.printers.language = if (index == 0) null else tools.probe_languages[index - 1];
    const printer = chosen(cc) orelse return;
    var prefs = printer.user;
    prefs.language = cc.printers.language;
    runClient(cc, .{ .save = .{ .queue = printer.name, .state = prefs } });
}

pub fn unitsChanged(raw: ?*anyopaque, _: usize, index: usize) void {
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

pub fn testClicked(raw: ?*anyopaque, kind: usize) void {
    const cc = owner(raw);
    if (kind > @intFromEnum(printing.TestKind.ruler) or chosen(cc) == null) return;
    cc.printers.test_kind = @enumFromInt(kind);
    cc.printers.form = .test_confirm;
    cc.printers.reveal_target = "printers_test_form";
    cc.refresh();
}

pub fn probeLanguage(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.language == null) cc.printers.language = .tspl;
    cc.printers.message = i18n.tr("Choose a language from the self-test sheet or try one sample. Record the outcome before choosing another language.");
    testClicked(raw, @intFromEnum(printing.TestKind.raw));
}

pub fn confirmTest(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.form != .test_confirm or busy(&cc.printers)) return;
    if (cc.printers.test_kind == .raw and (cc.printers.language == null or rawDpi(&cc.printers) == null)) return;
    const printer = chosen(cc) orelse return;
    const state = cc.printers.client.?.current orelse return;
    const media = loadedMedia(&cc.printers) orelse return;
    cc.printers.form = .test_result;
    runClient(cc, .{ .test_print = .{ .queue = printer.name, .kind = cc.printers.test_kind, .media = media, .media_keyword = printer.media, .language = cc.printers.language, .dpi = rawDpi(&cc.printers) orelse 203, .queue_resolution = queueResolution(printer, state) } });
}

pub fn rawDpi(self: *Section) ?u32 {
    const dpi = std.fmt.parseInt(u32, fieldValue(self, .raw_dpi), 10) catch return null;
    return if (dpi >= 72 and dpi <= 1200) dpi else null;
}

pub fn testOutcome(raw: ?*anyopaque, result: usize) void {
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

pub fn calibrate(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (busy(&cc.printers)) return;
    const printer = chosen(cc) orelse return;
    const state = cc.printers.client.?.current orelse return;
    const options_module = @import("../../printing/options.zig");
    const receipt_resolution = if (state.receipt) |receipt| if (receipt.kind == .ruler and receipt.matchesQueue(printer.name)) receipt.queue_resolution else null else null;
    const current_value = receipt_resolution orelse printer.user.ruler_resolution orelse queueResolution(printer, state);
    const current = current_value orelse {
        cc.printers.message = i18n.tr("The current printer resolution is unavailable.");
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
    cc.printers.message = if (cc.printers.suggested != null) i18n.tr("Review the suggested resolution, then apply it explicitly.") else i18n.tr("No supported resolution consistently matches both measurements. Check the ruler and print scaling.");
    cc.refresh();
}

pub fn queueResolution(printer: cups.Printer, state: *const printing.State) ?cups.ipp.Resolution {
    for (state.groups) |option_group| for (option_group.options) |option| {
        if (driver_options.resolutionOption(option) and option.source == .ppd) if (option.default) |setting| return driver_options.parseResolution(setting);
    };
    return printer.resolution;
}

pub fn applyResolution(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const r = cc.printers.suggested orelse return;
    const state = cc.printers.client.?.current orelse return;
    const match = resolutionChoice(state, r) orelse return;
    changeOption(cc, match.option, match.value);
}

pub const ResolutionChoice = struct { option: driver_options.Option, value: []const u8 };

pub fn resolutionChoice(state: *const printing.State, r: cups.ipp.Resolution) ?ResolutionChoice {
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
