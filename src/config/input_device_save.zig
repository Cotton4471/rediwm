//! Patch one property in one [[input_device]] record, preserving the rest of
//! the file byte-for-byte. Both versions must validate before atomic publish.
const std = @import("std");
const Io = std.Io;
const loader = @import("loader.zig");
const device = @import("input_device.zig");
const theme = @import("ui").theme;
const setting_save = @import("setting_save.zig");

pub fn save(allocator: std.mem.Allocator, io: Io, path: []const u8, id: []const u8, comptime key: []const u8, value: device.Value(key)) !void {
    if (path.len == 0) return error.NoConfigPath;
    const original = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(original);
    const result = try patch(allocator, original, id, key, value);
    defer allocator.free(result);
    try setting_save.writeValidated(allocator, io, path, result);
}

pub fn reset(allocator: std.mem.Allocator, io: Io, path: []const u8, id: []const u8) !void {
    if (path.len == 0) return error.NoConfigPath;
    const original = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(original);
    const result = try resetPatch(allocator, original, id);
    defer allocator.free(result);
    if (std.mem.eql(u8, original, result)) return;
    try setting_save.writeValidated(allocator, io, path, result);
}

pub fn patch(a: std.mem.Allocator, original: []const u8, id: []const u8, comptime key: []const u8, value: device.Value(key)) ![]u8 {
    if (!device.validId(id)) return error.InvalidValue;
    try device.validateValue(key, value);
    var old = try loader.parse(a, original, "input-device-save");
    defer old.deinit();
    const serialized = if (@TypeOf(value) == bool)
        try std.fmt.allocPrint(a, "{}", .{value})
    else
        try std.fmt.allocPrint(a, "{d}", .{value});
    defer a.free(serialized);
    return rewrite(a, original, id, .{ .setting = .{ .key = key, .value = serialized } });
}

pub fn resetPatch(a: std.mem.Allocator, original: []const u8, id: []const u8) ![]u8 {
    if (!device.validId(id)) return error.InvalidValue;
    var old = try loader.parse(a, original, "input-device-reset");
    defer old.deinit();
    return rewrite(a, original, id, .reset);
}

const Change = union(enum) {
    setting: struct { key: []const u8, value: []const u8 },
    reset,
};

fn rewrite(a: std.mem.Allocator, original: []const u8, id: []const u8, change: Change) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var start: usize = 0;
    var offset: usize = 0;
    var device_block = false;
    var matched = false;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |raw| {
        const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (std.mem.startsWith(u8, line, "[")) {
            matched = try appendBlock(a, &result, original[start..offset], device_block, id, change) or matched;
            start = offset;
            device_block = std.mem.eql(u8, line, "[[input_device]]");
        }
        offset = @min(original.len, offset + raw.len + 1);
    }
    matched = try appendBlock(a, &result, original[start..], device_block, id, change) or matched;
    if (!matched and change == .setting) {
        const block = try std.fmt.allocPrint(a, "\n[[input_device]]\nid = \"{s}\"\n{s} = {s}\n", .{ id, change.setting.key, change.setting.value });
        defer a.free(block);
        try result.appendSlice(a, block);
    }
    return result.toOwnedSlice(a);
}

fn appendBlock(a: std.mem.Allocator, out: *std.ArrayList(u8), block: []const u8, is_device: bool, id: []const u8, change: Change) !bool {
    var target = false;
    var lines = std.mem.splitScalar(u8, block, '\n');
    if (is_device) while (lines.next()) |raw| {
        const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const field = loader.unquoteKey(std.mem.trim(u8, line[0..eq], " \t"));
        if (!std.mem.eql(u8, field, "id")) continue;
        const identity = try theme.unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        target = std.mem.eql(u8, identity, id);
    };
    if (!target) {
        try out.appendSlice(a, block);
        return false;
    }
    lines = std.mem.splitScalar(u8, block, '\n');
    var offset: usize = 0;
    var replaced = false;
    while (lines.next()) |raw| {
        const end = @min(block.len, offset + raw.len + 1);
        const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
        const eq = std.mem.indexOfScalar(u8, line, '=');
        const field = if (eq) |i| loader.unquoteKey(std.mem.trim(u8, line[0..i], " \t")) else "";
        if (change == .reset and std.meta.stringToEnum(std.meta.FieldEnum(device.Effective), field) != null) {
            // Strip the assignment, retaining any inline comment and its line
            // ending. Standalone comments and the identity stay byte-for-byte.
            if (std.mem.indexOfScalar(u8, raw, '#')) |comment| {
                const indent = raw.len - std.mem.trimStart(u8, raw, " \t").len;
                try out.appendSlice(a, raw[0..indent]);
                try out.appendSlice(a, block[offset + comment .. end]);
            }
        } else if (change == .setting and std.mem.eql(u8, field, change.setting.key)) {
            const raw_eq = std.mem.indexOfScalar(u8, raw, '=').?;
            const comment = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
            const old_value = std.mem.trim(u8, raw[raw_eq + 1 .. comment], " \t\r");
            const value_start = @intFromPtr(old_value.ptr) - @intFromPtr(raw.ptr);
            try out.appendSlice(a, raw[0..value_start]);
            try out.appendSlice(a, change.setting.value);
            try out.appendSlice(a, block[offset + value_start + old_value.len .. end]);
            replaced = true;
        } else try out.appendSlice(a, block[offset..end]);
        offset = end;
    }
    if (!replaced and change == .setting) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        try out.appendSlice(a, change.setting.key);
        try out.appendSlice(a, " = ");
        try out.appendSlice(a, change.setting.value);
        try out.append(a, '\n');
    }
    return true;
}

test {
    _ = @import("input_device_save_tests.zig");
}
