const std = @import("std");

test "all exported bindings match the installed headers" {
    @setEvalBranchQuota(100000);
    refAllDeclsRecursive(@import("wlr.zig"));
}

fn refAllDeclsRecursive(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl_name| {
        const value = @field(T, decl_name);
        if (@TypeOf(value) == type) {
            switch (@typeInfo(value)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(value),
                else => {},
            }
        }
        _ = &@field(T, decl_name);
    }
}

test "DRM format sets support empty storage and mutable removal" {
    const wlr = @import("wlr.zig");
    var formats: wlr.DrmFormatSet = std.mem.zeroes(wlr.DrmFormatSet);
    defer formats.finish();
    const argb8888: u32 = 0x34325241;
    const linear: u64 = 0;
    try std.testing.expect(formats.formats == null);
    try std.testing.expect(formats.get(argb8888) == null);
    try std.testing.expect(formats.add(argb8888, linear));
    try std.testing.expect(formats.has(argb8888, linear));
    const format = formats.get(argb8888).?;
    try std.testing.expectEqual(linear, format.modifiers.?[0]);
    try std.testing.expect(formats.remove(argb8888, linear));
    try std.testing.expect(!formats.has(argb8888, linear));
    formats.finish();
    try std.testing.expect(formats.formats == null);
    try std.testing.expectEqual(@as(usize, 0), formats.len);
}
