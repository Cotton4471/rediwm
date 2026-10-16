//! IPC v1 request parsing: envelope, scalar helpers and empty requests.

const std = @import("std");
const commands = @import("commands.zig");
const RequestId = @import("protocol_data.zig").RequestId;
const ParsedEnvelope = @import("protocol_data.zig").ParsedEnvelope;
const RectData = @import("protocol_data.zig").RectData;
const FractionCoord = @import("protocol_data.zig").FractionCoord;
const GesturePhase = @import("protocol_results.zig").GesturePhase;
const parseQueryParams = @import("protocol_params.zig").parseQueryParams;
const parseActionParams = @import("protocol_params.zig").parseActionParams;
const Action = @import("protocol.zig").Action;
const Request = @import("protocol.zig").Request;

pub const ParseError = error{
    InvalidRequest,
    InvalidEnvelope,
    InvalidRequestId,
    OutOfMemory,
};

pub fn parseU64(val: std.json.Value) ParseError!u64 {
    return switch (val) {
        .integer => |i| if (i < 0) return error.InvalidRequest else @as(u64, @intCast(i)),
        else => error.InvalidRequest,
    };
}

pub fn parseOptU64(val: std.json.Value) ParseError!?u64 {
    return switch (val) {
        .null => null,
        .integer => |i| if (i < 0) return error.InvalidRequest else @as(u64, @intCast(i)),
        else => error.InvalidRequest,
    };
}

pub fn parseU32(val: std.json.Value) ParseError!u32 {
    return switch (val) {
        .integer => |i| if (i < 0 or i > std.math.maxInt(u32)) return error.InvalidRequest else @as(u32, @intCast(i)),
        else => error.InvalidRequest,
    };
}

pub fn parseOptU32(val: std.json.Value) ParseError!?u32 {
    return switch (val) {
        .null => null,
        .integer => |i| if (i < 0 or i > std.math.maxInt(u32)) return error.InvalidRequest else @as(u32, @intCast(i)),
        else => error.InvalidRequest,
    };
}

pub fn parseOptI64(val: std.json.Value) ParseError!?i64 {
    return switch (val) {
        .null => null,
        .integer => |i| i,
        else => error.InvalidRequest,
    };
}

pub fn parseI32(val: std.json.Value) ParseError!i32 {
    return switch (val) {
        .integer => |i| if (i < std.math.minInt(i32) or i > std.math.maxInt(i32)) return error.InvalidRequest else @as(i32, @intCast(i)),
        else => error.InvalidRequest,
    };
}

pub fn parseGesturePhase(val: std.json.Value) ParseError!GesturePhase {
    if (val != .string) return error.InvalidRequest;
    return std.meta.stringToEnum(GesturePhase, val.string) orelse error.InvalidRequest;
}

pub fn parseF64(val: std.json.Value) ParseError!f64 {
    const f: f64 = switch (val) {
        .float => |fl| fl,
        .integer => |i| @floatFromInt(i),
        else => return error.InvalidRequest,
    };
    if (!std.math.isFinite(f)) return error.InvalidRequest;
    return f;
}

pub fn parseFractionCoord(val: std.json.Value) ParseError!FractionCoord {
    switch (val) {
        .float, .integer => {
            const f = try parseF64(val);
            return .{ .x = f, .y = 0.5 };
        },
        .array => |arr| {
            if (arr.items.len != 2) return error.InvalidRequest;
            const x = try parseF64(arr.items[0]);
            const y = try parseF64(arr.items[1]);
            return .{ .x = x, .y = y };
        },
        .object => |obj| {
            const x_val = obj.get("x") orelse return error.InvalidRequest;
            const y_val = obj.get("y") orelse return error.InvalidRequest;
            const x = try parseF64(x_val);
            const y = try parseF64(y_val);
            return .{ .x = x, .y = y };
        },
        else => return error.InvalidRequest,
    }
}

pub fn parseVolume(val: std.json.Value) ParseError!f32 {
    const volume: f32 = switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => return error.InvalidRequest,
    };
    if (!std.math.isFinite(volume) or volume < 0 or volume > 1) return error.InvalidRequest;
    return volume;
}

pub fn parseRect(val: std.json.Value) ParseError!RectData {
    if (val != .object) return error.InvalidRequest;
    const x_val = val.object.get("x") orelse return error.InvalidRequest;
    const y_val = val.object.get("y") orelse return error.InvalidRequest;
    const w_val = val.object.get("width") orelse return error.InvalidRequest;
    const h_val = val.object.get("height") orelse return error.InvalidRequest;
    return .{
        .x = try parseI32(x_val),
        .y = try parseI32(y_val),
        .width = try parseI32(w_val),
        .height = try parseI32(h_val),
    };
}

pub fn parseRequest(allocator: std.mem.Allocator, json_text: []const u8) ParseError!Request {
    const env = try parseEnvelope(allocator, json_text);
    return env.request;
}

pub fn parseEnvelope(allocator: std.mem.Allocator, json_text: []const u8) ParseError!ParsedEnvelope {
    const trimmed = std.mem.trim(u8, json_text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidRequest;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();

    return parseEnvelopeValue(allocator, parsed.value);
}

// IPC v1 has exactly one request envelope and case-sensitive command names.
pub fn parseEnvelopeValue(allocator: std.mem.Allocator, val: std.json.Value) ParseError!ParsedEnvelope {
    if (val != .object) return error.InvalidEnvelope;
    const obj = val.object;
    for (obj.keys()) |key| {
        if (!std.mem.eql(u8, key, "version") and !std.mem.eql(u8, key, "command") and
            !std.mem.eql(u8, key, "params") and !std.mem.eql(u8, key, "id")) return error.InvalidEnvelope;
    }
    const version = obj.get("version") orelse return error.InvalidEnvelope;
    if (version != .integer or version.integer != 1) return error.InvalidEnvelope;
    const command = obj.get("command") orelse return error.InvalidEnvelope;
    if (command != .string) return error.InvalidEnvelope;
    var params: ?std.json.ObjectMap = null;
    if (obj.get("params")) |value| {
        if (value != .object) return error.InvalidRequest;
        params = value.object;
    }
    var id: ?RequestId = null;
    if (obj.get("id")) |value| {
        id = switch (value) {
            .integer => |n| if (n >= 0) .{ .integer = n } else return error.InvalidRequestId,
            .string => |str| if (str.len <= 256)
                .{ .string = allocator.dupe(u8, str) catch return error.OutOfMemory }
            else
                return error.InvalidRequestId,
            else => return error.InvalidRequestId,
        };
    }
    errdefer if (id) |request_id| switch (request_id) {
        .string => |str| allocator.free(str),
        .integer => {},
    };
    const request = if (commands.lookup(.query, command.string)) |tag|
        try parseQueryParams(allocator, tag, params)
    else if (commands.lookup(.action, command.string)) |tag|
        Request{ .action = try parseActionParams(allocator, tag, params) }
    else
        return error.InvalidRequest;
    return .{ .id = id, .request = request };
}

pub fn emptyAction(comptime name: []const u8) Action {
    if (@FieldType(Action, name) != void) @compileError("missing action parameter parser: " ++ name);
    return @unionInit(Action, name, {});
}

pub fn emptyRequest(comptime name: []const u8) Request {
    if (@hasField(Request, name)) {
        if (@FieldType(Request, name) != void) @compileError("missing query parameter parser: " ++ name);
        return @unionInit(Request, name, {});
    }
    return .{ .action = emptyAction(name) };
}
