//! Queue actions: refresh, selection, job cancel, copy, start/pause, defaults, removal and option changes.

const i18n = @import("i18n");
const std = @import("std");
const panel = @import("../panel.zig");
const cups = @import("../../printing/cups.zig");
const ladder = @import("../../printing/ladder.zig");
const driver_options = @import("../../printing/options.zig");
const gpa = @import("../../main.zig").gpa;
const printers = @import("printers.zig");
const Disclosure = printers.Disclosure;
const PendingOption = printers.PendingOption;
const diagnostic = printers.diagnostic;
const owner = printers.owner;
const busy = printers.busy;
const chosen = printers.chosen;
const fieldValue = printers.fieldValue;
const runAdmin = printers.runAdmin;
const runClient = printers.runClient;

pub fn refresh(raw: ?*anyopaque, _: usize) void {
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

pub fn select(raw: ?*anyopaque, _: usize, index: usize) void {
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
    cc.printers.expanded[@intFromEnum(Disclosure.history)] = false;
    cc.printers.history_limit = 5;
    cc.printers.expanded_job = null;
    cc.printers.reveal_target = "printers_printer";
    cc.printers.selected_len = @min(name.len, cc.printers.selected.len);
    @memcpy(cc.printers.selected[0..cc.printers.selected_len], name[0..cc.printers.selected_len]);
    cc.printers.copied = false;
    cc.printers.form = .none;
    cc.printers.message = "";
    client.act(.{ .select = name }) catch {};
    cc.refresh();
}

pub fn cancel(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    if (id > std.math.maxInt(i32)) return;
    if (cc.printers.client) |client| client.cancelJob(@intCast(id));
    cc.refresh();
}

pub fn copy(raw: ?*anyopaque, _: usize) void {
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

pub fn startClicked(raw: ?*anyopaque, _: usize) void {
    runAdmin(owner(raw), .start_service);
}

pub fn resumeClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runAdmin(cc, .{ .enabled = .{ .name = (chosen(cc) orelse return).name, .value = true } });
}

pub fn disableClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runAdmin(cc, .{ .enabled = .{ .name = (chosen(cc) orelse return).name, .value = false } });
}

pub fn acceptingClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const p = chosen(cc) orelse return;
    runAdmin(cc, .{ .accepting = .{ .name = p.name, .value = p.accepting == false } });
}

pub fn defaultClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runClient(cc, .{ .personal_default = (chosen(cc) orelse return).name });
}

pub fn systemDefaultClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runAdmin(cc, .{ .system_default = (chosen(cc) orelse return).name });
}

pub fn renameClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    runAdmin(cc, .{ .info = .{ .name = (chosen(cc) orelse return).name, .value = fieldValue(&cc.printers, .rename) } });
}

pub fn removeClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (chosen(cc) == null) return;
    cc.printers.form = .remove;
    cc.refresh();
}

pub fn removeConfirm(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.printers.form != .remove) return;
    runAdmin(cc, .{ .remove = (chosen(cc) orelse return).name });
}

pub fn optionChanged(raw: ?*anyopaque, id: usize, index: usize) void {
    const cc = owner(raw);
    if (id >= cc.printers.option_refs.len) return;
    const option = cc.printers.option_refs[id];
    if (index >= option.choices.len) return;
    const state = cc.printers.client.?.current orelse return;
    if (state.ppd.len == 0 or !driver_options.queueEditable(option, state.groups)) return;
    changeOption(cc, option, option.choices[index].value);
}

pub fn changeOption(cc: *panel.ControlCenter, option: driver_options.Option, value: []const u8) void {
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

pub fn verifyOption(cc: *panel.ControlCenter) void {
    const pending = cc.printers.pending_option orelse return;
    cc.printers.pending_option = null;
    const client = cc.printers.client orelse return;
    const state = client.current orelse return;
    if (state.failure != null or client.failure != null or state.generation != client.generation) return;
    const data = state.cups orelse return;
    for (data.printers) |printer| if (std.mem.eql(u8, printer.name, pending.queue[0..pending.queue_len])) {
        const option: driver_options.Option = .{ .name = pending.key[0..pending.key_len], .source = if (pending.ppd) .ppd else .ipp };
        const matches = driver_options.settingMatches(state.groups, printer.attributes, option, pending.value[0..pending.value_len]);
        cc.printers.message = if (matches) |saved| if (saved) i18n.tr("Printer setting verified.") else i18n.tr("The driver did not report the requested value. Review its settings before printing.") else i18n.tr("CUPS accepted the change; the resulting driver value could not be verified.");
        return;
    };
}

pub fn rangeChanged(raw: ?*anyopaque, id: usize, new_value: f32) void {
    const cc = owner(raw);
    if (id >= cc.printers.range_count or busy(&cc.printers)) return;
    cc.printers.ranges[id].value = new_value;
}

pub fn rangeApply(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    if (id >= cc.printers.range_count) return;
    const draft = cc.printers.ranges[id];
    if (!std.math.isFinite(draft.value) or draft.value < @as(f32, @floatFromInt(draft.range.lower)) or draft.value > @as(f32, @floatFromInt(draft.range.upper))) return;
    var buffer: [32]u8 = undefined;
    const setting = std.fmt.bufPrint(&buffer, "{d}", .{@as(i32, @intFromFloat(@round(draft.value)))}) catch return;
    runAdmin(cc, .{ .ppd_option = .{ .name = (chosen(cc) orelse return).name, .key = draft.name[0..draft.len], .values = &.{setting} } });
}
