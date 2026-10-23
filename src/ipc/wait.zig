const std = @import("std");
const wl = @import("wayland").server.wl;

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const anim = @import("ui").anim;
const protocol = @import("protocol.zig");
const handlers = @import("handlers.zig");
const wait_replies = @import("wait_replies.zig");
const wait_conditions = @import("wait_conditions.zig");
const log = std.log.scoped(.ipc_wait);

pub const WaitKind = union(enum) {
    condition: protocol.WaitCondition,
    frame: ?[]const u8, // output name or null
};

pub const WaitEntry = struct {
    wait_id: u64,
    client_id: u64,
    request_id: ?protocol.RequestId,
    kind: WaitKind,
    start_time_ms: i64,
    timeout_ms: u64,
    deadline_ms: i64,
    timer_source: ?*wl.EventSource = null,
    manager: *WaitManager,
};

pub const WaitManager = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*WaitEntry),
    next_wait_id: u64 = 1,

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*WaitManager {
        const mgr = try allocator.create(WaitManager);
        mgr.* = .{
            .server = server,
            .allocator = allocator,
            .entries = std.ArrayList(*WaitEntry).empty,
        };
        return mgr;
    }

    pub fn deinit(mgr: *WaitManager) void {
        for (mgr.entries.items) |entry| {
            if (entry.timer_source) |ts| ts.remove();
            mgr.freeEntry(entry);
        }
        mgr.entries.deinit(mgr.allocator);
        mgr.allocator.destroy(mgr);
    }

    fn freeEntry(mgr: *WaitManager, entry: *WaitEntry) void {
        switch (entry.kind) {
            .condition => |cond| switch (cond) {
                .window_mapped => |p| {
                    if (p.app_id) |a| mgr.allocator.free(a);
                    if (p.title) |t| mgr.allocator.free(t);
                },
                .output_frame => |p| {
                    if (p.output) |o| mgr.allocator.free(o);
                },
                .notification_count => |p| {
                    if (p.app_name) |a| mgr.allocator.free(a);
                    if (p.summary) |s| mgr.allocator.free(s);
                },
                .notification_action => |p| {
                    if (p.action_key) |k| mgr.allocator.free(k);
                },
                .launch_started => |p| {
                    if (p.desktop_id) |d| mgr.allocator.free(d);
                },
                .launch_matched => |p| {
                    if (p.desktop_id) |d| mgr.allocator.free(d);
                },
                .launch_timeout => |p| {
                    if (p.desktop_id) |d| mgr.allocator.free(d);
                },
                .widget_present => |p| {
                    mgr.allocator.free(p.path);
                },
                .widget_absent => |p| {
                    mgr.allocator.free(p.path);
                },
                .widget_state => |p| {
                    mgr.allocator.free(p.path);
                    mgr.allocator.free(p.field);
                    protocol.freeWidgetStateValue(mgr.allocator, p.equals);
                },
                .panel_settled => |p| {
                    mgr.allocator.free(p.panel);
                },
                else => {},
            },
            .frame => |opt_out| {
                if (opt_out) |o| mgr.allocator.free(o);
            },
        }
        if (entry.request_id) |rid| {
            switch (rid) {
                .string => |s| mgr.allocator.free(s),
                .integer => {},
            }
        }
        mgr.allocator.destroy(entry);
    }

    pub fn clientCount(mgr: *WaitManager, client_id: u64) usize {
        var count: usize = 0;
        for (mgr.entries.items) |e| {
            if (e.client_id == client_id) count += 1;
        }
        return count;
    }

    pub fn cancelForClient(mgr: *WaitManager, client_id: u64) void {
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            if (entry.client_id == client_id) {
                if (entry.timer_source) |ts| ts.remove();
                _ = mgr.entries.orderedRemove(i);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    /// Ends every pending wait with `reason`. Locking uses this so a wait
    /// registered beforehand cannot report state changes behind the lock.
    pub fn failAll(mgr: *WaitManager, reason: []const u8) void {
        while (mgr.entries.pop()) |entry| {
            if (entry.timer_source) |ts| ts.remove();
            if (mgr.server.ipc) |ipc| if (ipc.findClientById(entry.client_id)) |client| {
                const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
                protocol.stringifyResponseWithId(entry.request_id, .{ .err = reason }, bw) catch {};
                client.updateFdInterest() catch {};
            };
            mgr.freeEntry(entry);
        }
    }

    pub fn registerCondition(
        mgr: *WaitManager,
        client_id: u64,
        request_id: ?protocol.RequestId,
        condition: protocol.WaitCondition,
        timeout_ms: u64,
    ) !protocol.Response {
        const now = anim.nowMs();

        // 1. Evaluate condition immediately
        if (mgr.isConditionMet(condition, now)) {
            const cond_str = conditionName(condition);
            return .{ .ok = .{ .wait_for = .{
                .condition = cond_str,
                .elapsed_ms = 0,
                .state = null,
            } } };
        }

        mgr.server.scheduleFrames();

        if (mgr.clientCount(client_id) >= 16) {
            return .{ .err = "Busy: wait limit per client reached" };
        }

        const entry = try mgr.allocator.create(WaitEntry);
        entry.* = .{
            .wait_id = mgr.next_wait_id,
            .client_id = client_id,
            .request_id = null,
            .kind = .{ .frame = null },
            .start_time_ms = now,
            .timeout_ms = timeout_ms,
            .deadline_ms = now + @as(i64, @intCast(timeout_ms)),
            .timer_source = null,
            .manager = mgr,
        };
        errdefer mgr.freeEntry(entry);
        const owned_condition = try mgr.cloneCondition(condition);
        entry.kind = .{ .condition = owned_condition };
        const owned_request_id = if (request_id) |rid| try mgr.cloneRequestId(rid) else null;
        entry.request_id = owned_request_id;
        mgr.next_wait_id += 1;

        const loop = mgr.server.wl_server.getEventLoop();
        const timer = loop.addTimer(*WaitEntry, handleWaitTimer, entry) catch return error.EventLoopFailed;
        // A later allocation failure must not leave a timer pointing at entry.
        errdefer timer.remove();
        entry.timer_source = timer;
        timer.timerUpdate(@intCast(timeout_ms)) catch return error.EventLoopFailed;

        try mgr.entries.append(mgr.allocator, entry);
        return .{ .ok = .async_pending };
    }

    pub fn registerFrame(
        mgr: *WaitManager,
        client_id: u64,
        request_id: ?protocol.RequestId,
        output_name: ?[]const u8,
        timeout_ms: u64,
    ) !protocol.Response {
        const now = anim.nowMs();

        // Ensure frame is scheduled
        if (output_name) |name| {
            if (mgr.server.findOutputByName(name)) |out| {
                out.wlr_output.scheduleFrame();
            } else {
                return .{ .err = "UnknownOutput" };
            }
        } else {
            mgr.server.scheduleFrames();
        }

        if (mgr.clientCount(client_id) >= 16) {
            return .{ .err = "Busy: wait limit per client reached" };
        }

        const entry = try mgr.allocator.create(WaitEntry);
        entry.* = .{
            .wait_id = mgr.next_wait_id,
            .client_id = client_id,
            .request_id = null,
            .kind = .{ .frame = null },
            .start_time_ms = now,
            .timeout_ms = timeout_ms,
            .deadline_ms = now + @as(i64, @intCast(timeout_ms)),
            .timer_source = null,
            .manager = mgr,
        };
        errdefer mgr.freeEntry(entry);
        const owned_output = if (output_name) |o| try mgr.allocator.dupe(u8, o) else null;
        entry.kind = .{ .frame = owned_output };
        const owned_request_id = if (request_id) |rid| try mgr.cloneRequestId(rid) else null;
        entry.request_id = owned_request_id;
        mgr.next_wait_id += 1;

        const loop = mgr.server.wl_server.getEventLoop();
        const timer = loop.addTimer(*WaitEntry, handleWaitTimer, entry) catch return error.EventLoopFailed;
        // A later allocation failure must not leave a timer pointing at entry.
        errdefer timer.remove();
        entry.timer_source = timer;
        timer.timerUpdate(@intCast(timeout_ms)) catch return error.EventLoopFailed;

        try mgr.entries.append(mgr.allocator, entry);
        return .{ .ok = .async_pending };
    }

    pub fn onOutputFrame(mgr: *WaitManager, output: *Output) void {
        const out_name = std.mem.span(output.wlr_output.name);
        const now = anim.nowMs();

        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;

            switch (entry.kind) {
                .frame => |opt_out| {
                    if (opt_out) |req_name| {
                        if (std.mem.eql(u8, req_name, out_name)) satisfied = true;
                    } else {
                        satisfied = true;
                    }
                },
                .condition => |cond| {
                    if (cond == .output_frame) {
                        if (cond.output_frame.output) |req_name| {
                            if (std.mem.eql(u8, req_name, out_name)) satisfied = true;
                        } else {
                            satisfied = true;
                        }
                    }
                },
            }

            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();

                mgr.notifySuccess(entry, now, out_name);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    pub fn onLaunchStarted(mgr: *WaitManager, desktop_id: []const u8) void {
        const now = anim.nowMs();
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;
            if (entry.kind == .condition and entry.kind.condition == .launch_started) {
                if (entry.kind.condition.launch_started.desktop_id) |target| {
                    if (std.mem.eql(u8, target, desktop_id)) satisfied = true;
                } else {
                    satisfied = true;
                }
            }
            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();
                mgr.notifySuccess(entry, now, desktop_id);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    pub fn onLaunchMatched(mgr: *WaitManager, desktop_id: []const u8, window_id: u64) void {
        const now = anim.nowMs();
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;
            if (entry.kind == .condition and entry.kind.condition == .launch_matched) {
                const p = entry.kind.condition.launch_matched;
                var match = true;
                if (p.desktop_id) |target| {
                    if (!std.mem.eql(u8, target, desktop_id)) match = false;
                }
                if (p.window_id) |wid| {
                    if (wid != window_id) match = false;
                }
                if (match) satisfied = true;
            }
            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();
                mgr.notifySuccess(entry, now, desktop_id);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    pub fn onLaunchTimeout(mgr: *WaitManager, desktop_id: []const u8) void {
        const now = anim.nowMs();
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;
            if (entry.kind == .condition and entry.kind.condition == .launch_timeout) {
                if (entry.kind.condition.launch_timeout.desktop_id) |target| {
                    if (std.mem.eql(u8, target, desktop_id)) satisfied = true;
                } else {
                    satisfied = true;
                }
            }
            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();
                mgr.notifySuccess(entry, now, desktop_id);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    pub fn waitsForFrame(mgr: *const WaitManager) bool {
        for (mgr.entries.items) |entry| if (entry.kind == .frame) return true;
        return false;
    }

    pub fn checkAll(mgr: *WaitManager) void {
        const now = anim.nowMs();
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;
            switch (entry.kind) {
                .condition => |cond| {
                    if (cond != .output_frame and mgr.isConditionMet(cond, now)) {
                        satisfied = true;
                    }
                },
                .frame => {},
            }

            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();

                mgr.notifySuccess(entry, now, "");
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    const notifySuccess = wait_replies.notifySuccess;
    const notifyTimeout = wait_replies.notifyTimeout;
    pub const buildTimeoutDiagnostic = wait_replies.buildTimeoutDiagnostic;

    const isConditionMet = wait_conditions.isConditionMet;
    const cloneCondition = wait_conditions.cloneCondition;
    const cloneRequestId = wait_conditions.cloneRequestId;
};

fn handleWaitTimer(entry: *WaitEntry) c_int {
    const mgr = entry.manager;
    var found_idx: ?usize = null;
    for (mgr.entries.items, 0..) |item, idx| {
        if (item == entry) {
            found_idx = idx;
            break;
        }
    }

    if (found_idx) |idx| {
        _ = mgr.entries.orderedRemove(idx);
        if (entry.timer_source) |ts| ts.remove();
        entry.timer_source = null;

        const now = anim.nowMs();
        var satisfied = false;
        switch (entry.kind) {
            .condition => |cond| {
                if (cond != .output_frame and mgr.isConditionMet(cond, now)) {
                    satisfied = true;
                }
            },
            .frame => {},
        }

        if (satisfied) {
            mgr.notifySuccess(entry, now, "");
        } else {
            mgr.notifyTimeout(entry);
        }
        mgr.freeEntry(entry);
    }
    return 0;
}

pub fn conditionName(cond: protocol.WaitCondition) []const u8 {
    return switch (cond) {
        .menu_opened => "menu_opened",
        .menu_closed => "menu_closed",
        .control_center_opened => "control_center_opened",
        .control_center_closed => "control_center_closed",
        .power_menu_opened => "power_menu_opened",
        .power_menu_closed => "power_menu_closed",
        .window_mapped => "window_mapped",
        .window_closed => "window_closed",
        .window_focused => "window_focused",
        .window_geometry_settled => "window_geometry_settled",
        .output_frame => "output_frame",
        .catalog_published => "catalog_published",
        .wallpaper_presented => "wallpaper_presented",
        .notification_count => "notification_count",
        .notification_closed => "notification_closed",
        .notification_action => "notification_action",
        .launch_started => "launch_started",
        .launch_matched => "launch_matched",
        .launch_timeout => "launch_timeout",
        .widget_present => "widget_present",
        .widget_absent => "widget_absent",
        .widget_state => "widget_state",
        .panel_settled => "panel_settled",
    };
}
