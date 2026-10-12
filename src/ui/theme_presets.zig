//! Embedded fallback packs. Filesystem discovery and metadata parsing live
//! in config/theme_pack.zig, keeping shared UI independent of configuration.

pub const Preset = struct {
    id: []const u8 = "",
    name: []const u8,
    bytes: []const u8,
};

pub const bundled = [_]Preset{
    .{ .id = "rediwm-dark", .name = "RediWM Dark", .bytes = @embedFile("theme-rediwm-dark") },
    .{ .id = "rediwm-light", .name = "RediWM Light", .bytes = @embedFile("theme-rediwm-light") },
    .{ .id = "redi-blue", .name = "Redi Blue", .bytes = @embedFile("theme-redi-blue") },
};
