//! Evidence-based diagnostics, independent of transport and UI types.
//! A successful CUPS job is evidence of processing, never proof of a printed page.
const std = @import("std");
const usb_sysfs = @import("usb_sysfs.zig");

pub const Verdict = enum { pass, fail, unknown };
pub const Layer = enum { connection, device_node, cups, queue, backend, settings, last_job };
pub const Row = struct {
    layer: Layer,
    verdict: Verdict,
    message: []const u8,
    fix: []const u8 = "",
};
pub const Connection = enum { usb, network, other };
pub const UsbBackend = enum { unknown, libusb, device_node };
pub const QueueState = enum { unknown, idle, processing, stopped };
pub const JobState = enum { unknown, pending, held, processing, stopped, canceled, aborted, completed };
pub const Resolution = struct { x_dpi: u32, y_dpi: u32 };
pub const Queue = struct {
    state: QueueState = .unknown,
    accepting: ?bool = null,
    reasons: []const []const u8 = &.{},
    uri: []const u8 = "",
    default_media: []const u8 = "",
    resolution: ?Resolution = null,
};
pub const Job = struct {
    state: JobState = .unknown,
    sheets_completed: ?u32 = null,
    reasons: []const []const u8 = &.{},
    /// Used only to classify known failures; never copied into the report.
    message: []const u8 = "",
};
pub const Input = struct {
    connection: Connection = .other,
    cups_reachable: ?bool = null,
    queue: ?Queue = null,
    last_job: ?Job = null,
    /// The caller must establish this identity, e.g. using a USB serial.
    /// An arbitrary printer of the same model is not a match.
    usb: ?*const usb_sysfs.Device = null,
    usb_scan_complete: bool = false,
    usb_backend: UsbBackend = .unknown,
    /// Direct stat evidence for the exact path used by a node-based queue.
    /// This does not establish the identity or presence of a USB device.
    node_kind: ?usb_sysfs.NodeKind = null,
    settings_consistent: ?bool = null,
    network_reachable: ?bool = null,
    backend_match: ?bool = null,
    expected_media: ?[]const u8 = null,
    expected_resolution: ?Resolution = null,
    distribution: []const u8 = "",
    cups_version: []const u8 = "",
};

pub const Result = struct {
    rows: [7]Row,

    pub fn firstFailure(self: Result) ?usize {
        for (self.rows, 0..) |row, i| if (row.verdict == .fail) return i;
        return null;
    }
};

pub fn evaluate(input: Input) Result {
    return .{ .rows = .{
        connectionRow(input),
        nodeRow(input),
        cupsRow(input),
        queueRow(input),
        backendRow(input),
        settingsRow(input),
        jobRow(input.last_job),
    } };
}

fn connectionRow(input: Input) Row {
    switch (input.connection) {
        .usb => {
            if (input.usb) |device| return if (device.printer_class)
                .{ .layer = .connection, .verdict = .pass, .message = @import("i18n").tr("A matching USB printer interface is attached.") }
            else
                .{ .layer = .connection, .verdict = .fail, .message = @import("i18n").tr("The matching USB device has no printer-class interface."), .fix = @import("i18n").tr("Check the device's USB mode and its self-test instructions.") };
            return if (input.usb_scan_complete)
                .{ .layer = .connection, .verdict = .fail, .message = @import("i18n").tr("The matching USB printer was not found."), .fix = @import("i18n").tr("Check power, the USB cable, and which printer this queue uses.") }
            else
                .{ .layer = .connection, .verdict = .unknown, .message = @import("i18n").tr("USB presence or queue-to-device identity could not be established.") };
        },
        .network => return if (input.network_reachable) |reachable|
            if (reachable)
                .{ .layer = .connection, .verdict = .pass, .message = @import("i18n").tr("The printer answered an IPP request.") }
            else
                .{ .layer = .connection, .verdict = .fail, .message = @import("i18n").tr("The network printer did not answer."), .fix = @import("i18n").tr("Check printer power, the address, and access through the network or VPN.") }
        else
            .{ .layer = .connection, .verdict = .unknown, .message = @import("i18n").tr("Network reachability has not been checked.") },
        .other => return .{ .layer = .connection, .verdict = .unknown, .message = @import("i18n").tr("This connection has no direct presence check.") },
    }
}

fn backendKind(input: Input) UsbBackend {
    if (input.usb_backend != .unknown) return input.usb_backend;
    if (input.queue) |queue| if (std.mem.startsWith(u8, queue.uri, "usb://")) return .libusb;
    return .unknown;
}
fn nodeRow(input: Input) Row {
    const layer = Layer.device_node;
    if (input.connection != .usb) return .{ .layer = layer, .verdict = .unknown, .message = @import("i18n").tr("A USB character device is not applicable to this connection.") };
    if (backendKind(input) == .libusb) return .{ .layer = layer, .verdict = .unknown, .message = @import("i18n").tr("The CUPS USB backend uses libusb; a usblp node is not required.") };
    if (backendKind(input) == .device_node) if (input.node_kind) |kind| return switch (kind) {
        .regular, .other => .{ .layer = layer, .verdict = .fail, .message = @import("i18n").tr("The queue's device-node path is a regular file or another wrong file type."), .fix = @import("i18n").tr("Have an administrator inspect the node; never write print data to a regular file.") },
        .missing => .{ .layer = layer, .verdict = .fail, .message = @import("i18n").tr("The character-device path used by this queue is missing."), .fix = @import("i18n").tr("Check the usblp driver and the queue's device path; node names can change after reconnection.") },
        .character => .{ .layer = layer, .verdict = .pass, .message = @import("i18n").tr("The queue's character device exists; backend access has not been tested.") },
        .unavailable => .{ .layer = layer, .verdict = .unknown, .message = @import("i18n").tr("The file type of the queue's device-node path could not be read.") },
    };
    const device = input.usb orelse return .{ .layer = layer, .verdict = .unknown, .message = @import("i18n").tr("No matching USB device is available to identify its node.") };
    var character = false;
    var regular = false;
    var inaccessible = false;
    for (device.nodes) |node| switch (node.kind) {
        .character => character = true,
        .regular, .other => regular = true,
        .unavailable => inaccessible = true,
        .missing => {},
    };
    if (backendKind(input) == .unknown) return .{ .layer = layer, .verdict = .unknown, .message = if (regular)
        "A matched node path is not a character device; this backend's need for it is unknown."
    else
        "This backend's need for a usblp node has not been established." };
    if (regular) return .{ .layer = layer, .verdict = .fail, .message = @import("i18n").tr("A matched device-node path is a regular file or another wrong file type."), .fix = @import("i18n").tr("Have an administrator inspect the node; never write print data to a regular file.") };
    if (character) return .{ .layer = layer, .verdict = .pass, .message = @import("i18n").tr("A matching character device exists; backend access has not been tested.") };
    if (inaccessible) return .{ .layer = layer, .verdict = .unknown, .message = @import("i18n").tr("The matching device-node file type could not be read.") };
    return .{ .layer = layer, .verdict = .fail, .message = @import("i18n").tr("This backend needs a character device, but no matching node was found."), .fix = @import("i18n").tr("Check the usblp driver and the queue's device path; node names can change after reconnection.") };
}
fn cupsRow(input: Input) Row {
    if (input.cups_reachable) |reachable| return if (reachable)
        .{ .layer = .cups, .verdict = .pass, .message = @import("i18n").tr("CUPS answered an IPP request.") }
    else
        .{ .layer = .cups, .verdict = .fail, .message = @import("i18n").tr("CUPS did not answer an IPP request."), .fix = @import("i18n").tr("Check the configured CUPS server and whether the print service is installed and available.") };
    return .{ .layer = .cups, .verdict = .unknown, .message = @import("i18n").tr("CUPS availability has not been checked.") };
}
fn queueRow(input: Input) Row {
    const queue = input.queue orelse return if (input.cups_reachable == true)
        .{ .layer = .queue, .verdict = .fail, .message = @import("i18n").tr("The selected queue was not found."), .fix = @import("i18n").tr("Select an existing queue or add the printer again.") }
    else
        .{ .layer = .queue, .verdict = .unknown, .message = @import("i18n").tr("The queue could not be checked without a CUPS response.") };
    if (queue.state == .stopped) return .{ .layer = .queue, .verdict = .fail, .message = @import("i18n").tr("The printer queue is stopped."), .fix = @import("i18n").tr("Resolve the reported printer problem before resuming the queue.") };
    if (queue.accepting == false) return .{ .layer = .queue, .verdict = .fail, .message = @import("i18n").tr("The printer queue is not accepting new jobs."), .fix = @import("i18n").tr("Enable acceptance of jobs when the printer is ready.") };
    if (queue.accepting == null or queue.state == .unknown) return .{ .layer = .queue, .verdict = .unknown, .message = @import("i18n").tr("The queue exists, but its state or acceptance of jobs is unknown.") };
    return .{ .layer = .queue, .verdict = .pass, .message = @import("i18n").tr("The queue exists, is enabled, and accepts jobs.") };
}
fn backendRow(input: Input) Row {
    if (input.backend_match == false) return .{ .layer = .backend, .verdict = .fail, .message = @import("i18n").tr("The queue's device address does not match the selected printer."), .fix = @import("i18n").tr("Check the queue address and USB serial; reconnecting can change a device-node path.") };
    if (input.last_job) |job| {
        if (hasReason(job.reasons, "printer-unreachable") or ((job.state == .aborted or job.state == .stopped) and hasReason(job.reasons, "connecting-to-device")) or containsAsciiIgnoreCase(job.message, "USB transaction timeout")) return .{
            .layer = .backend,
            .verdict = .fail,
            .message = @import("i18n").tr("The last job reports a backend connection problem."),
            .fix = @import("i18n").tr("Check the connection and backend address. A timeout alone does not prove that a USB quirk is needed."),
        };
    }
    return .{ .layer = .backend, .verdict = .unknown, .message = if (input.backend_match == true)
        @import("i18n").tr("The device address matches; successful communication has not been confirmed.")
    else
        @import("i18n").tr("Backend communication and device identity have not been confirmed.") };
}
fn settingsRow(input: Input) Row {
    const queue = input.queue orelse return .{ .layer = .settings, .verdict = .unknown, .message = @import("i18n").tr("Queue media and resolution could not be read.") };
    if (input.settings_consistent == false) return .{ .layer = .settings, .verdict = .fail, .message = @import("i18n").tr("CUPS reports conflicting queue and driver defaults."), .fix = @import("i18n").tr("Reapply the intended paper, resolution or driver option, then refresh to verify the result.") };
    if (input.expected_media) |expected| {
        if (queue.default_media.len > 0 and !std.mem.eql(u8, expected, queue.default_media)) return .{ .layer = .settings, .verdict = .fail, .message = @import("i18n").tr("The queue's default media differs from the expected media."), .fix = @import("i18n").tr("Choose the paper or label size actually loaded in the printer.") };
    }
    if (input.expected_resolution) |expected| {
        if (queue.resolution) |actual| if (expected.x_dpi != actual.x_dpi or expected.y_dpi != actual.y_dpi) return .{ .layer = .settings, .verdict = .fail, .message = @import("i18n").tr("The queue resolution differs from the expected resolution."), .fix = @import("i18n").tr("Confirm resolution using the printer's self-test or a measured ruler test.") };
    }
    if ((input.expected_media != null and queue.default_media.len == 0) or (input.expected_resolution != null and queue.resolution == null) or (input.expected_media == null and input.expected_resolution == null)) return .{ .layer = .settings, .verdict = .unknown, .message = @import("i18n").tr("Media and resolution need confirmation against what is loaded in the printer.") };
    return .{ .layer = .settings, .verdict = .pass, .message = @import("i18n").tr("The available queue settings match the supplied media or resolution expectations.") };
}
fn jobRow(job_value: ?Job) Row {
    const job = job_value orelse return .{ .layer = .last_job, .verdict = .unknown, .message = @import("i18n").tr("No recent job information is available.") };
    if (containsAsciiIgnoreCase(job.message, "No pages were found") or hasReason(job.reasons, "document-format-error") or hasReason(job.reasons, "document-unprintable-error") or hasReason(job.reasons, "cups-filter-error")) return .{ .layer = .last_job, .verdict = .fail, .message = @import("i18n").tr("The last job reports a document or filter failure."), .fix = @import("i18n").tr("Check the document, driver, media size, and resolution. Compare with a test that skips the filters.") };
    if (job.state == .completed and job.sheets_completed == 0) return .{ .layer = .last_job, .verdict = .unknown, .message = @import("i18n").tr("CUPS completed the job with zero sheets reported; physical output is not confirmed."), .fix = @import("i18n").tr("Check the physical output and any document or filter failure; sheet counters can be incomplete.") };
    if (job.state == .aborted or job.state == .stopped) return .{ .layer = .last_job, .verdict = .fail, .message = @import("i18n").tr("The last job was aborted or stopped."), .fix = @import("i18n").tr("Check the job's reported reason before retrying.") };
    if (job.state == .completed) return .{ .layer = .last_job, .verdict = .unknown, .message = @import("i18n").tr("CUPS reports the job completed; physical printed output is not confirmed.") };
    if (job.state == .canceled) return .{ .layer = .last_job, .verdict = .unknown, .message = @import("i18n").tr("The last job was canceled.") };
    return .{ .layer = .last_job, .verdict = .unknown, .message = @import("i18n").tr("The last job has not completed.") };
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const bounded = haystack[0..@min(haystack.len, 4096)];
    if (needle.len > bounded.len) return false;
    for (0..bounded.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(bounded[i .. i + needle.len], needle)) return true;
    return false;
}
fn hasReason(reasons: []const []const u8, expected: []const u8) bool {
    for (reasons[0..@min(reasons.len, 64)]) |reason| if (std.mem.eql(u8, reason, expected)) return true;
    return false;
}

/// Human-readable status for recognized IPP printer-state-reasons.
/// Unknown strings are deliberately not echoed into reports or UI labels.
pub fn reasonText(reason: []const u8) ?[]const u8 {
    var base = reason;
    for ([_][]const u8{ "-error", "-warning", "-report" }) |suffix| if (std.mem.endsWith(u8, base, suffix)) {
        base = base[0 .. base.len - suffix.len];
        break;
    };
    const known = .{
        .{ "none", "No reported problem" },
        .{ "media-empty", "Out of paper" },
        .{ "media-needed", "Paper is needed" },
        .{ "media-jam", "Paper jam" },
        .{ "media-low", "Paper is low" },
        .{ "toner-empty", "Toner is empty" },
        .{ "toner-low", "Toner is low" },
        .{ "marker-supply-empty", "Ink or toner is empty" },
        .{ "marker-supply-low", "Ink or toner is low" },
        .{ "cover-open", "Cover open" },
        .{ "door-open", "Door open" },
        .{ "paused", "Queue paused" },
        .{ "connecting-to-device", "Connecting to the printer" },
        .{ "printer-unreachable", "Printer unreachable" },
        .{ "offline", "Printer offline" },
        .{ "cups-missing-filter", "A required print filter is missing" },
        .{ "cups-insecure-filter", "A print filter has unsafe permissions" },
        .{ "cups-filter-error", "Print filter failed" },
        .{ "document-format-error", "Document format error" },
        .{ "document-unprintable-error", "Document could not be printed" },
        .{ "job-completed-successfully", "Job completed in CUPS" },
        .{ "job-canceled-by-user", "Job canceled" },
        .{ "job-canceled-at-device", "Job canceled at the printer" },
        .{ "job-hold-until-specified", "Job held" },
    };
    inline for (known) |entry| if (std.mem.eql(u8, reason, entry[0]) or std.mem.eql(u8, base, entry[0])) return entry[1];
    return null;
}

/// Privacy by construction: names, document titles, arbitrary status messages,
/// URI userinfo/hosts/paths/queries, and USB serial strings are never included.
/// Known failure classifications preserve useful evidence without copying logs.
pub fn report(a: std.mem.Allocator, input: Input) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.writer.writeAll("RediWM printer diagnostics\n");
    try out.writer.print("Connection: {s}\n", .{@tagName(input.connection)});
    const distro = distributionName(input.distribution);
    try out.writer.print("Distribution: {s}\nCUPS version: {s}\n", .{ distro, safeVersion(input.cups_version) });
    if (input.usb) |device| {
        try out.writer.print("USB: {x:0>4}:{x:0>4}; printer class: {s}\n", .{ device.vid, device.pid, if (device.printer_class) "07" else "no" });
        try out.writer.print("Matched device nodes: {d}\n", .{device.nodes.len});
        for (device.nodes[0..@min(device.nodes.len, 32)]) |node| try out.writer.print("  Node type: {s}\n", .{@tagName(node.kind)});
    }
    if (input.node_kind) |kind| try out.writer.print("Queue device-node type: {s}\n", .{@tagName(kind)});
    if (input.queue) |queue| {
        try out.writer.print("Queue state: {s}; accepting: {s}\n", .{ @tagName(queue.state), if (queue.accepting) |value| if (value) "yes" else "no" else "unknown" });
        try out.writer.print("Device URI: {s}\nDefault media: {s}\n", .{ redactedUri(queue.uri), safeMedia(queue.default_media) });
        if (queue.resolution) |resolution| try out.writer.print("Resolution: {d} x {d} dpi\n", .{ resolution.x_dpi, resolution.y_dpi });
        try reportReasons(&out.writer, "Printer reason", queue.reasons);
    }
    if (input.last_job) |job| {
        try out.writer.print("Last job state: {s}\n", .{@tagName(job.state)});
        if (job.sheets_completed) |sheets| try out.writer.print("Completed sheets reported by CUPS: {d}\n", .{sheets});
        try reportReasons(&out.writer, "Job reason", job.reasons);
        if (job.message.len > 0) try out.writer.writeAll("Job message: omitted for privacy; recognized failures appear below\n");
    }
    for (evaluate(input).rows) |row| try out.writer.print("{s}: {s} - {s}\n", .{ @tagName(row.layer), @tagName(row.verdict), row.message });
    try out.writer.writeAll("CUPS completion does not confirm physical output. No test prints were started by this report.\n");
    return out.toOwnedSlice();
}

fn reportReasons(writer: *std.Io.Writer, label: []const u8, reasons: []const []const u8) !void {
    var unknown: usize = 0;
    for (reasons[0..@min(reasons.len, 64)]) |reason| {
        if (reasonText(reason)) |text| try writer.print("{s}: {s}\n", .{ label, text }) else unknown += 1;
    }
    if (unknown > 0) try writer.print("{s}: {d} unrecognized values omitted\n", .{ label, unknown });
}
fn distributionName(raw: []const u8) []const u8 {
    for ([_][]const u8{ "arch", "artix", "cachyos", "debian", "ubuntu", "fedora", "opensuse", "opensuse-leap", "opensuse-tumbleweed" }) |known| if (std.mem.eql(u8, raw, known)) return known;
    return "unknown";
}
fn safeVersion(raw: []const u8) []const u8 {
    if (raw.len == 0 or raw.len > 32) return "unknown";
    for (raw) |byte| if (!std.ascii.isDigit(byte) and byte != '.' and byte != '-') return "unknown";
    return raw;
}
fn safeMedia(raw: []const u8) []const u8 {
    // Exact known keywords only: a standard-looking prefix is insufficient,
    // since an untrusted server could put a document name or hostname after it.
    const known_media = [_][]const u8{
        "A3",                       "A4",                       "A5",
        "A6",                       "Letter",                   "Legal",
        "Executive",                "4x6",                      "4x6.Borderless",
        "iso_a3_297x420mm",         "iso_a4_210x297mm",         "iso_a5_148x210mm",
        "iso_a6_105x148mm",         "iso_b5_176x250mm",         "iso_c5_162x229mm",
        "iso_dl_110x220mm",         "jis_b5_182x257mm",         "na_letter_8.5x11in",
        "na_legal_8.5x14in",        "na_executive_7.25x10.5in", "na_ledger_11x17in",
        "na_index-4x6_4x6in",       "na_number-10_4.125x9.5in", "oe_photo-l_3.5x5in",
        "oe_photo-2l_5x7in",        "om_small-photo_100x150mm", "om_medium-photo_130x180mm",
        "om_large-photo_200x300mm",
    };
    for (known_media) |known| if (std.mem.eql(u8, raw, known)) return known;
    if (raw.len == 0) return "unknown";
    return "[unrecognized value omitted]";
}
fn redactedUri(uri: []const u8) []const u8 {
    for ([_][]const u8{ "usb", "ipp", "ipps", "http", "https", "socket", "lpd", "dnssd", "file", "parallel", "serial" }) |scheme| {
        if (uri.len > scheme.len and uri[scheme.len] == ':' and std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) {
            if (std.mem.eql(u8, scheme, "usb")) return "usb:[device identity omitted]";
            if (std.mem.eql(u8, scheme, "file")) return "file:[path omitted]";
            return "[known URI scheme; credentials, host and path omitted]";
        }
    }
    return "[URI omitted]";
}

test "libusb does not require usblp; missing evidence does not become a failure" {
    const result = evaluate(.{ .connection = .usb, .cups_reachable = true, .queue = .{ .state = .idle, .accepting = true, .uri = "usb://Printer/Model" } });
    try std.testing.expectEqual(Verdict.unknown, result.rows[0].verdict);
    try std.testing.expectEqual(Verdict.unknown, result.rows[1].verdict);
    try std.testing.expectEqual(Verdict.pass, result.rows[3].verdict);
    try std.testing.expectEqual(@as(?usize, null), result.firstFailure());
}

test "completed empty job points to filter evidence; completed sheets are not proof of output" {
    var input: Input = .{ .last_job = .{ .state = .completed, .sheets_completed = 0, .message = "No pages were found." } };
    try std.testing.expectEqual(Verdict.fail, evaluate(input).rows[6].verdict);
    try std.testing.expect(std.mem.indexOf(u8, evaluate(input).rows[6].message, "filter") != null);
    input.last_job = .{ .state = .completed, .sheets_completed = 1 };
    try std.testing.expectEqual(Verdict.unknown, evaluate(input).rows[6].verdict);
    input.last_job = .{ .state = .completed };
    try std.testing.expectEqual(Verdict.unknown, evaluate(input).rows[6].verdict);
    input.last_job = .{ .state = .completed, .sheets_completed = 0 };
    try std.testing.expectEqual(Verdict.unknown, evaluate(input).rows[6].verdict);
}

test "stopped queue and explicit media mismatch produce the correct first failing layer" {
    var input: Input = .{ .cups_reachable = true, .queue = .{ .state = .stopped, .accepting = true, .default_media = "A4" }, .expected_media = "4x6" };
    try std.testing.expectEqual(@as(?usize, 3), evaluate(input).firstFailure());
    input.queue.?.state = .idle;
    try std.testing.expectEqual(@as(?usize, 5), evaluate(input).firstFailure());
}

test "node-based backends reject impostors while ordinary connecting jobs remain inconclusive" {
    var nodes = [_]usb_sysfs.Node{.{ .path = "/dev/usb/lp9", .kind = .regular }};
    var device: usb_sysfs.Device = .{ .name = "1-2", .vid = 0x0416, .pid = 0x5011, .manufacturer = "", .product = "", .serial = "", .driver = "usblp", .nodes = &nodes };
    var input: Input = .{ .connection = .usb, .usb = &device, .usb_backend = .device_node, .last_job = .{ .state = .processing, .reasons = &.{"connecting-to-device"} } };
    try std.testing.expectEqual(Verdict.fail, evaluate(input).rows[1].verdict);
    try std.testing.expectEqual(Verdict.unknown, evaluate(input).rows[4].verdict);
    nodes[0].kind = .character;
    try std.testing.expectEqual(Verdict.pass, evaluate(input).rows[1].verdict);
    nodes[0].kind = .missing;
    try std.testing.expectEqual(Verdict.fail, evaluate(input).rows[1].verdict);
    input.usb_backend = .libusb;
    try std.testing.expectEqual(Verdict.unknown, evaluate(input).rows[1].verdict);
    input.last_job.?.state = .aborted;
    try std.testing.expectEqual(Verdict.fail, evaluate(input).rows[4].verdict);

    // An existing file: queue identifies its exact path even when sysfs cannot
    // establish a corresponding USB identity. Stat evidence is independent.
    input = .{ .connection = .usb, .usb_backend = .device_node, .queue = .{ .uri = "file:/dev/usb/lp0" }, .node_kind = .regular };
    try std.testing.expectEqual(Verdict.unknown, evaluate(input).rows[0].verdict);
    try std.testing.expectEqual(Verdict.fail, evaluate(input).rows[1].verdict);
    try std.testing.expectEqual(@as(?usize, 1), evaluate(input).firstFailure());
    input.node_kind = .other;
    try std.testing.expectEqual(Verdict.fail, evaluate(input).rows[1].verdict);
    input.node_kind = .missing;
    try std.testing.expectEqual(Verdict.fail, evaluate(input).rows[1].verdict);
    input.node_kind = .character;
    try std.testing.expectEqual(Verdict.pass, evaluate(input).rows[1].verdict);
    try std.testing.expectEqual(Verdict.unknown, evaluate(input).rows[0].verdict);
    input.node_kind = .unavailable;
    try std.testing.expectEqual(Verdict.unknown, evaluate(input).rows[1].verdict);
    input.usb_backend = .libusb;
    input.node_kind = .regular;
    try std.testing.expectEqual(Verdict.unknown, evaluate(input).rows[1].verdict);
}

test "diagnostic reports redact remote credentials identities messages and unknown reasons" {
    const a = std.testing.allocator;
    const text = try report(a, .{
        .connection = .network,
        .queue = .{ .uri = "ipp://secret-user:secret-password@private-host.example/printers/private-queue?token=secret-token", .default_media = "iso_private-user.private-host.example_1x2mm", .reasons = &.{ "media-empty-warning", "private-user\nprivate-document" } },
        .last_job = .{ .state = .aborted, .message = "private-user printed private-document at private-host.example" },
        .distribution = "arch\nprivate-host.example",
        .cups_version = "2.4.10\nsecret-token",
    });
    defer a.free(text);
    for ([_][]const u8{ "secret-user", "secret-password", "private-host", "private-user", "private-document", "secret-token", "private-queue" }) |secret| try std.testing.expect(std.mem.indexOf(u8, text, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Out of paper") != null);
}
