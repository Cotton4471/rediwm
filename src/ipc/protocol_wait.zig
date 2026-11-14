//! IPC v1 wait conditions and widget state values.

const std = @import("std");
const WidgetStateValue = @import("protocol_results.zig").WidgetStateValue;
const freeWidgetStateValue = @import("protocol_results.zig").freeWidgetStateValue;
const WaitCondition = @import("protocol_results.zig").WaitCondition;
const ParseError = @import("protocol_parse.zig").ParseError;
const parseU64 = @import("protocol_parse.zig").parseU64;
const parseOptU64 = @import("protocol_parse.zig").parseOptU64;
const parseU32 = @import("protocol_parse.zig").parseU32;

pub const wait_aliases = .{
    .menu_opened = &[_][]const u8{"start_menu_opened"},
    .menu_closed = &[_][]const u8{"start_menu_closed"},
};

pub fn waitNames(comptime name: []const u8) []const []const u8 {
    return &[_][]const u8{name} ++ if (@hasField(@TypeOf(wait_aliases), name)) @field(wait_aliases, name) else &[_][]const u8{};
}

comptime {
    @setEvalBranchQuota(20_000);
    for (@typeInfo(@TypeOf(wait_aliases)).@"struct".field_names) |name| {
        if (!@hasField(WaitCondition, name)) @compileError("unknown wait alias target: " ++ name);
    }
    var names: []const []const u8 = &.{};
    for (@typeInfo(WaitCondition).@"union".field_names) |field_name| {
        for (waitNames(field_name)) |name| {
            for (names) |previous| {
                if (std.mem.eql(u8, previous, name)) @compileError("duplicate wait name: " ++ name);
            }
            names = names ++ .{name};
        }
    }
}

pub fn parseWidgetStateValue(allocator: std.mem.Allocator, val: std.json.Value) ParseError!WidgetStateValue {
    switch (val) {
        .bool => |b| return .{ .boolean = b },
        .integer => |i| return .{ .number = @floatFromInt(i) },
        .float => |f| return .{ .number = f },
        .string => |s| {
            if (s.len > 4096) return error.InvalidRequest;
            const str = allocator.dupe(u8, s) catch return error.OutOfMemory;
            return .{ .string = str };
        },
        .null => return .null_value,
        else => return error.InvalidRequest,
    }
}

pub fn parseWaitCondition(allocator: std.mem.Allocator, val: std.json.Value) ParseError!WaitCondition {
    const Tag = std.meta.Tag(WaitCondition);
    var selected: ?Tag = null;
    var value: std.json.Value = .null;
    switch (val) {
        .string => |s| {
            inline for (@typeInfo(WaitCondition).@"union".field_names) |field_name| {
                if (@FieldType(WaitCondition, field_name) == void) {
                    inline for (comptime waitNames(field_name)) |name| {
                        if (std.mem.eql(u8, s, name)) return @unionInit(WaitCondition, field_name, {});
                    }
                }
            }
            return error.InvalidRequest;
        },
        .object => |obj| {
            // Historically all no-payload conditions take precedence over
            // payload conditions, independently of object insertion order.
            inline for (.{ true, false }) |no_payload| {
                inline for (@typeInfo(WaitCondition).@"union".field_names) |field_name| {
                    if ((@FieldType(WaitCondition, field_name) == void) == no_payload) {
                        inline for (comptime waitNames(field_name)) |name| {
                            if (selected == null) {
                                if (obj.get(name)) |v| {
                                    selected = @field(Tag, field_name);
                                    value = v;
                                }
                            }
                        }
                    }
                }
            }
        },
        else => return error.InvalidRequest,
    }
    switch (selected orelse return error.InvalidRequest) {
        .window_mapped => {
            const wm = value;
            var id: ?u64 = null;
            var app_id: ?[]const u8 = null;
            var title: ?[]const u8 = null;
            if (wm == .object) {
                if (wm.object.get("id")) |id_v| id = try parseOptU64(id_v);
                if (wm.object.get("app_id")) |app_v| {
                    if (app_v == .string) {
                        if (app_v.string.len > 256) return error.InvalidRequest;
                        app_id = allocator.dupe(u8, app_v.string) catch return error.OutOfMemory;
                    } else if (app_v != .null) return error.InvalidRequest;
                }
                if (wm.object.get("title")) |t_v| {
                    if (t_v == .string) {
                        if (t_v.string.len > 512) return error.InvalidRequest;
                        title = allocator.dupe(u8, t_v.string) catch return error.OutOfMemory;
                    } else if (t_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .window_mapped = .{ .id = id, .app_id = app_id, .title = title } };
        },
        .window_closed => {
            const wc = value;
            if (wc != .object) return error.InvalidRequest;
            const id_v = wc.object.get("id") orelse return error.InvalidRequest;
            return .{ .window_closed = .{ .id = try parseU64(id_v) } };
        },
        .window_focused => {
            const wf = value;
            var id: ?u64 = null;
            if (wf == .object) {
                if (wf.object.get("id")) |id_v| id = try parseOptU64(id_v);
            }
            return .{ .window_focused = .{ .id = id } };
        },
        .window_geometry_settled => {
            const wg = value;
            if (wg != .object) return error.InvalidRequest;
            const id_v = wg.object.get("id") orelse return error.InvalidRequest;
            return .{ .window_geometry_settled = .{ .id = try parseU64(id_v) } };
        },
        .output_frame => {
            const of = value;
            var out_name: ?[]const u8 = null;
            if (of == .object) {
                if (of.object.get("output")) |out_v| {
                    if (out_v == .string) {
                        if (out_v.string.len > 256) return error.InvalidRequest;
                        out_name = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                    } else if (out_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .output_frame = .{ .output = out_name } };
        },
        .notification_count => {
            const nc = value;
            var count: ?usize = null;
            var app_name: ?[]const u8 = null;
            var summary: ?[]const u8 = null;
            if (nc == .object) {
                if (nc.object.get("count")) |cnt_v| {
                    if (cnt_v == .integer and cnt_v.integer >= 0) {
                        count = @intCast(cnt_v.integer);
                    } else return error.InvalidRequest;
                }
                if (nc.object.get("app_name")) |app_v| {
                    if (app_v == .string) {
                        if (app_v.string.len > 256) return error.InvalidRequest;
                        app_name = allocator.dupe(u8, app_v.string) catch return error.OutOfMemory;
                    } else if (app_v != .null) return error.InvalidRequest;
                }
                if (nc.object.get("summary")) |sum_v| {
                    if (sum_v == .string) {
                        if (sum_v.string.len > 512) return error.InvalidRequest;
                        summary = allocator.dupe(u8, sum_v.string) catch return error.OutOfMemory;
                    } else if (sum_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .notification_count = .{ .count = count, .app_name = app_name, .summary = summary } };
        },
        .notification_closed => {
            const nc = value;
            if (nc != .object) return error.InvalidRequest;
            const id_v = nc.object.get("id") orelse return error.InvalidRequest;
            return .{ .notification_closed = .{ .id = try parseU32(id_v) } };
        },
        .notification_action => {
            const na = value;
            if (na != .object) return error.InvalidRequest;
            const id_v = na.object.get("id") orelse return error.InvalidRequest;
            var action_key: ?[]const u8 = null;
            if (na.object.get("action_key")) |ak_v| {
                if (ak_v == .string) {
                    if (ak_v.string.len > 256) return error.InvalidRequest;
                    action_key = allocator.dupe(u8, ak_v.string) catch return error.OutOfMemory;
                } else if (ak_v != .null) return error.InvalidRequest;
            }
            return .{ .notification_action = .{ .id = try parseU32(id_v), .action_key = action_key } };
        },
        .launch_started => {
            const ls = value;
            var desktop_id: ?[]const u8 = null;
            if (ls == .object) {
                if (ls.object.get("desktop_id")) |d_v| {
                    if (d_v == .string) {
                        if (d_v.string.len > 256) return error.InvalidRequest;
                        desktop_id = allocator.dupe(u8, d_v.string) catch return error.OutOfMemory;
                    } else if (d_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .launch_started = .{ .desktop_id = desktop_id } };
        },
        .launch_matched => {
            const lm = value;
            var desktop_id: ?[]const u8 = null;
            var window_id: ?u64 = null;
            if (lm == .object) {
                if (lm.object.get("desktop_id")) |d_v| {
                    if (d_v == .string) {
                        if (d_v.string.len > 256) return error.InvalidRequest;
                        desktop_id = allocator.dupe(u8, d_v.string) catch return error.OutOfMemory;
                    } else if (d_v != .null) return error.InvalidRequest;
                }
                if (lm.object.get("window_id")) |w_v| window_id = try parseOptU64(w_v);
            }
            return .{ .launch_matched = .{ .desktop_id = desktop_id, .window_id = window_id } };
        },
        .launch_timeout => {
            const lt = value;
            var desktop_id: ?[]const u8 = null;
            if (lt == .object) {
                if (lt.object.get("desktop_id")) |d_v| {
                    if (d_v == .string) {
                        if (d_v.string.len > 256) return error.InvalidRequest;
                        desktop_id = allocator.dupe(u8, d_v.string) catch return error.OutOfMemory;
                    } else if (d_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .launch_timeout = .{ .desktop_id = desktop_id } };
        },
        .widget_present => {
            var path: ?[]const u8 = null;
            if (value == .string) {
                if (value.string.len == 0 or value.string.len > 4096) return error.InvalidRequest;
                path = try allocator.dupe(u8, value.string);
            } else if (value == .object) {
                if (value.object.get("path")) |pv| {
                    if (pv == .string and pv.string.len > 0 and pv.string.len <= 4096) {
                        path = try allocator.dupe(u8, pv.string);
                    } else if (pv != .null) return error.InvalidRequest;
                }
            }
            return .{ .widget_present = .{ .path = path orelse return error.InvalidRequest } };
        },
        .widget_absent => {
            var path: ?[]const u8 = null;
            if (value == .string) {
                if (value.string.len == 0 or value.string.len > 4096) return error.InvalidRequest;
                path = try allocator.dupe(u8, value.string);
            } else if (value == .object) {
                if (value.object.get("path")) |pv| {
                    if (pv == .string and pv.string.len > 0 and pv.string.len <= 4096) {
                        path = try allocator.dupe(u8, pv.string);
                    } else if (pv != .null) return error.InvalidRequest;
                }
            }
            return .{ .widget_absent = .{ .path = path orelse return error.InvalidRequest } };
        },
        .widget_state => {
            if (value != .object) return error.InvalidRequest;
            const path_v = value.object.get("path") orelse return error.InvalidRequest;
            if (path_v != .string or path_v.string.len == 0 or path_v.string.len > 4096) return error.InvalidRequest;
            const field_v = value.object.get("field") orelse return error.InvalidRequest;
            if (field_v != .string or field_v.string.len == 0 or field_v.string.len > 256) return error.InvalidRequest;
            const eq_v = value.object.get("equals") orelse return error.InvalidRequest;
            const equals = try parseWidgetStateValue(allocator, eq_v);
            errdefer freeWidgetStateValue(allocator, equals);
            const path = allocator.dupe(u8, path_v.string) catch return error.OutOfMemory;
            errdefer allocator.free(path);
            const field = allocator.dupe(u8, field_v.string) catch return error.OutOfMemory;
            return .{ .widget_state = .{
                .path = path,
                .field = field,
                .equals = equals,
            } };
        },
        .panel_settled => {
            var panel: ?[]const u8 = null;
            if (value == .string) {
                if (value.string.len == 0 or value.string.len > 64) return error.InvalidRequest;
                panel = try allocator.dupe(u8, value.string);
            } else if (value == .object) {
                if (value.object.get("panel")) |pv| {
                    if (pv == .string and pv.string.len > 0 and pv.string.len <= 64) {
                        panel = try allocator.dupe(u8, pv.string);
                    } else if (pv != .null) return error.InvalidRequest;
                }
            }
            return .{ .panel_settled = .{ .panel = panel orelse return error.InvalidRequest } };
        },
        inline else => |tag| {
            if (@FieldType(WaitCondition, @tagName(tag)) != void)
                @compileError("missing wait parameter parser: " ++ @tagName(tag));
            return @unionInit(WaitCondition, @tagName(tag), {});
        },
    }
}
