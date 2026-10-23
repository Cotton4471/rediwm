//! Replying to waiters: success, timeouts and the timeout diagnostic.

const std = @import("std");
const anim = @import("ui").anim;
const protocol = @import("protocol.zig");
const wait_mod = @import("wait.zig");
const WaitManager = wait_mod.WaitManager;
const WaitEntry = wait_mod.WaitEntry;
const conditionName = wait_mod.conditionName;

pub fn notifySuccess(mgr: *WaitManager, entry: *WaitEntry, now: i64, extra_name: []const u8) void {
    const ipc = mgr.server.ipc orelse return;
    const client = ipc.findClientById(entry.client_id) orelse return;

    const elapsed: u64 = if (now >= entry.start_time_ms)
        @intCast(now - entry.start_time_ms)
    else
        0;

    const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };

    switch (entry.kind) {
        .condition => |cond| {
            const res = protocol.WaitForResult{
                .condition = conditionName(cond),
                .elapsed_ms = elapsed,
                .state = null,
            };
            protocol.stringifyResponseWithId(entry.request_id, .{ .ok = .{ .wait_for = res } }, bw) catch {};
        },
        .frame => {
            const out_res = protocol.WaitForFrameResult{
                .output = extra_name,
                .frame_seq = ipc.seq,
                .elapsed_ms = elapsed,
            };
            protocol.stringifyResponseWithId(entry.request_id, .{ .ok = .{ .wait_for_frame = out_res } }, bw) catch {};
        },
    }
    client.updateFdInterest() catch {};
}

pub fn notifyTimeout(mgr: *WaitManager, entry: *WaitEntry) void {
    const ipc = mgr.server.ipc orelse return;
    const client = ipc.findClientById(entry.client_id) orelse return;

    var buf: [256]u8 = undefined;
    const diag = mgr.buildTimeoutDiagnostic(entry, &buf);

    const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
    protocol.stringifyResponseWithId(entry.request_id, .{ .err = diag }, bw) catch {};
    client.updateFdInterest() catch {};
}

pub fn buildTimeoutDiagnostic(mgr: *WaitManager, entry: *WaitEntry, buf: []u8) []const u8 {
    const now = anim.nowMs();
    switch (entry.kind) {
        .condition => |cond| switch (cond) {
            .menu_opened => {
                const out = mgr.server.getDefaultOutput();
                if (out != null and out.?.start_menu != null) {
                    const sm = out.?.start_menu.?;
                    return std.fmt.bufPrint(buf, "Timeout: start menu in state '{s}' (settled={}) after {d}ms", .{
                        @tagName(sm.state), sm.slide.settled(now), entry.timeout_ms,
                    }) catch "Timeout: menu_opened";
                }
                return std.fmt.bufPrint(buf, "Timeout: start menu is not open after {d}ms", .{entry.timeout_ms}) catch "Timeout";
            },
            .menu_closed => {
                const out = mgr.server.getDefaultOutput();
                if (out != null and out.?.start_menu != null) {
                    const sm = out.?.start_menu.?;
                    return std.fmt.bufPrint(buf, "Timeout: start menu still open with state '{s}' after {d}ms", .{
                        @tagName(sm.state), entry.timeout_ms,
                    }) catch "Timeout: menu_closed";
                }
                return std.fmt.bufPrint(buf, "Timeout: start menu not closed after {d}ms", .{entry.timeout_ms}) catch "Timeout";
            },
            .control_center_opened => return "Timeout: control center not open",
            .control_center_closed => return "Timeout: control center not closed",
            .power_menu_opened => return "Timeout: power menu not open",
            .power_menu_closed => return "Timeout: power menu not closed",
            .window_mapped => |p| {
                if (p.id) |id| {
                    return std.fmt.bufPrint(buf, "Timeout: window {d} not mapped after {d}ms", .{ id, entry.timeout_ms }) catch "Timeout";
                }
                return "Timeout: window not mapped";
            },
            .window_closed => |p| {
                return std.fmt.bufPrint(buf, "Timeout: window {d} still open after {d}ms", .{ p.id, entry.timeout_ms }) catch "Timeout";
            },
            .window_focused => |p| {
                if (p.id) |id| {
                    return std.fmt.bufPrint(buf, "Timeout: window {d} not focused after {d}ms", .{ id, entry.timeout_ms }) catch "Timeout";
                }
                return "Timeout: focus not cleared";
            },
            .window_geometry_settled => |p| {
                return std.fmt.bufPrint(buf, "Timeout: window {d} geometry not settled after {d}ms", .{ p.id, entry.timeout_ms }) catch "Timeout";
            },
            .output_frame => return "Timeout: output frame not received",
            .catalog_published => return "Timeout: catalogue not published",
            .wallpaper_presented => return "Timeout: wallpaper not presented",
            .notification_count => return "Timeout: notification count condition not met",
            .notification_closed => return "Timeout: notification not closed",
            .notification_action => return "Timeout: notification action not received",
            .launch_started => return "Timeout: launch not started",
            .launch_matched => return "Timeout: launch not matched",
            .launch_timeout => return "Timeout: launch did not timeout",
            .widget_present => |p| {
                return std.fmt.bufPrint(buf, "Timeout: widget '{s}' not present after {d}ms", .{ p.path, entry.timeout_ms }) catch "Timeout: widget not present";
            },
            .widget_absent => |p| {
                return std.fmt.bufPrint(buf, "Timeout: widget '{s}' still present after {d}ms", .{ p.path, entry.timeout_ms }) catch "Timeout: widget not absent";
            },
            .widget_state => |p| {
                return std.fmt.bufPrint(buf, "Timeout: widget '{s}' field '{s}' condition not met after {d}ms", .{ p.path, p.field, entry.timeout_ms }) catch "Timeout: widget state";
            },
            .panel_settled => |p| {
                return std.fmt.bufPrint(buf, "Timeout: panel '{s}' not settled after {d}ms", .{ p.panel, entry.timeout_ms }) catch "Timeout: panel not settled";
            },
        },
        .frame => return "Timeout: frame presentation not received",
    }
}
