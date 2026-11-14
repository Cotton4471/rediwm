const std = @import("std");
const loader = @import("loader.zig");
const device = @import("input_device.zig");
const save = @import("input_device_save.zig");

test "saving a pointer field preserves other records global settings and comments" {
    const a = std.testing.allocator;
    const original = "# preferences\n[input]\nnatural_scroll = false\npointer_speed = 0.1\n" ++
        "[[input_device]] # mouse\n  \"natural_scroll\" = false  # wheel direction\nid = \"mouse\"\npointer_speed = 0.7\n" ++
        "[[input_device]]\nid = \"pad\"\nnatural_scroll = true\n# keep this\n" ++
        "[theme]\nfont = \"Example\"\n[[outputs]]\nname = \"DP-1\"\nscale = 1.5\n";
    const updated = try save.patch(a, original, "mouse", "natural_scroll", true);
    defer a.free(updated);
    const expected = try std.mem.replaceOwned(u8, a, original, "\"natural_scroll\" = false  # wheel", "\"natural_scroll\" = true  # wheel");
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, updated);
    const crlf = try std.mem.replaceOwned(u8, a, original, "\n", "\r\n");
    defer a.free(crlf);
    const crlf_updated = try save.patch(a, crlf, "mouse", "natural_scroll", true);
    defer a.free(crlf_updated);
    const crlf_expected = try std.mem.replaceOwned(u8, a, expected, "\n", "\r\n");
    defer a.free(crlf_expected);
    try std.testing.expectEqualStrings(crlf_expected, crlf_updated);
    var cfg = try loader.parse(a, updated, "saved");
    defer cfg.deinit();
    try std.testing.expect(!cfg.input.natural_scroll);
    try std.testing.expectEqual(@as(?bool, true), cfg.input_devices[0].natural_scroll);
    try std.testing.expectEqual(@as(?f32, 0.7), cfg.input_devices[0].pointer_speed);
    try std.testing.expectEqual(@as(?bool, true), cfg.input_devices[1].natural_scroll);
    try std.testing.expectEqualStrings("Example", cfg.theme.font);
    try std.testing.expectEqual(@as(?f32, 1.5), cfg.outputs[0].scale);
}

test "pointer persistence adds missing records and fields without replacing records" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "", "[input]\nnatural_scroll = false", "[[input_device]]\nid = \"mouse\"", "[[input_device]]\nid = \"other\"\nnatural_scroll = false\n" }) |original| {
        const speed = try save.patch(a, original, "mouse", "pointer_speed", 0.4);
        defer a.free(speed);
        const natural = try save.patch(a, speed, "mouse", "natural_scroll", true);
        defer a.free(natural);
        const repeated = try save.patch(a, natural, "mouse", "pointer_speed", -0.6);
        defer a.free(repeated);
        var cfg = try loader.parse(a, repeated, "saved");
        defer cfg.deinit();
        const record = device.find(cfg.input_devices, "mouse").?;
        try std.testing.expectEqual(@as(?f32, -0.6), record.pointer_speed);
        try std.testing.expectEqual(@as(?bool, true), record.natural_scroll);
        try std.testing.expectEqual(@as(?bool, null), record.tap_to_click);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, repeated, "id = \"mouse\""));
    }
}

test "invalid pointer save leaves config file untouched and restart restores accepted values" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "# preserve\n[input]\nnatural_scroll = false\n[[input_device]]\nid = \"pad\"\nnatural_scroll = true\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = original });
    const path = try tmp.dir.realPathFileAlloc(io, "config.toml", a);
    defer a.free(path);
    try std.testing.expectError(error.InvalidValue, save.save(a, io, path, "mouse", "pointer_speed", 2));
    try std.testing.expectError(error.InvalidValue, save.save(a, io, path, "bad\"identity", "natural_scroll", true));
    const unchanged = try tmp.dir.readFileAlloc(io, "config.toml", a, .limited(4096));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);
    try save.save(a, io, path, "mouse", "natural_scroll", false);
    try save.save(a, io, path, "mouse", "pointer_speed", 0.7);
    const saved = try tmp.dir.readFileAlloc(io, "config.toml", a, .limited(4096));
    defer a.free(saved);
    // A fresh loader owns no memory or state from either save operation.
    var restarted = try loader.parse(a, saved, path);
    defer restarted.deinit();
    const mouse = device.resolve(restarted.input, restarted.input_devices, "mouse", false);
    const pad = device.resolve(restarted.input, restarted.input_devices, "pad", true);
    try std.testing.expect(!mouse.natural_scroll);
    try std.testing.expect(pad.natural_scroll);
    try std.testing.expectEqual(@as(f32, 0.7), mouse.pointer_speed);
    try std.testing.expect(std.mem.startsWith(u8, saved, original));
    const malformed = "[[input_device]]\nid = \"mouse\"\nid = \"other\"\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = malformed });
    try std.testing.expectError(error.InvalidConfig, save.save(a, io, path, "mouse", "natural_scroll", true));
    const invalid_unchanged = try tmp.dir.readFileAlloc(io, "config.toml", a, .limited(4096));
    defer a.free(invalid_unchanged);
    try std.testing.expectEqualStrings(malformed, invalid_unchanged);
}

test "reset removes only selected device overrides while preserving every comment" {
    const a = std.testing.allocator;
    const prefix = "# preferences\n[input]\nnatural_scroll = false\npointer_speed = 0.1\n";
    const suffix = "[[input_device]]\nid = \"pad\"\nnatural_scroll = true\n# keep pad\n[theme]\nfont = \"Example\"\n";
    const original = prefix ++ "[[input_device]] # mouse\n  \"natural_scroll\" = false  # wheel\nid = \"mouse\" # identity\n" ++
        "pointer_speed = 0.7\nleft_handed = true # buttons\ntap_to_click = true\ntap_drag = true\ndisable_while_typing = false\n# keep mouse\n" ++ suffix;
    const expected = prefix ++ "[[input_device]] # mouse\n  # wheel\nid = \"mouse\" # identity\n# buttons\n# keep mouse\n" ++ suffix;
    const reset = try save.resetPatch(a, original, "mouse");
    defer a.free(reset);
    try std.testing.expectEqualStrings(expected, reset);
    const crlf = try std.mem.replaceOwned(u8, a, original, "\n", "\r\n");
    defer a.free(crlf);
    const reset_crlf = try save.resetPatch(a, crlf, "mouse");
    defer a.free(reset_crlf);
    const expected_crlf = try std.mem.replaceOwned(u8, a, expected, "\n", "\r\n");
    defer a.free(expected_crlf);
    try std.testing.expectEqualStrings(expected_crlf, reset_crlf);
    const changed_defaults = try std.mem.replaceOwned(u8, a, reset, "pointer_speed = 0.1", "pointer_speed = -0.6");
    defer a.free(changed_defaults);
    var restarted = try loader.parse(a, changed_defaults, "reset-reload");
    defer restarted.deinit();
    try std.testing.expect(!device.hasOverrides(restarted.input_devices, "mouse"));
    try std.testing.expect(device.hasOverrides(restarted.input_devices, "pad"));
    const inherited = device.resolve(restarted.input, restarted.input_devices, "mouse", false);
    try std.testing.expectEqual(@as(f32, -0.6), inherited.pointer_speed);
    try std.testing.expect(!inherited.natural_scroll);
}

test "reset persists inheritance leaves absent devices alone and refuses invalid files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "[input]\nnatural_scroll = false\n[[input_device]]\nid = \"mouse\"\nnatural_scroll = true # direction";
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = original });
    const path = try tmp.dir.realPathFileAlloc(io, "config.toml", a);
    defer a.free(path);
    // An absent device must not even attempt an atomic rewrite.
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml.setting-save.tmp", .data = "reserved" });
    try save.reset(a, io, path, "absent");
    try tmp.dir.deleteFile(io, "config.toml.setting-save.tmp");
    const unchanged = try tmp.dir.readFileAlloc(io, "config.toml", a, .limited(4096));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);
    try save.reset(a, io, path, "mouse");
    const reset = try tmp.dir.readFileAlloc(io, "config.toml", a, .limited(4096));
    defer a.free(reset);
    try std.testing.expectEqualStrings("[input]\nnatural_scroll = false\n[[input_device]]\nid = \"mouse\"\n# direction", reset);
    var restarted = try loader.parse(a, reset, path);
    defer restarted.deinit();
    try std.testing.expect(!device.hasOverrides(restarted.input_devices, "mouse"));
    try std.testing.expectError(error.InvalidValue, save.reset(a, io, path, "bad\"id"));
    const malformed = "[[input_device]]\nid = \"mouse\"\nid = \"other\"\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = malformed });
    try std.testing.expectError(error.InvalidConfig, save.reset(a, io, path, "mouse"));
    const invalid_unchanged = try tmp.dir.readFileAlloc(io, "config.toml", a, .limited(4096));
    defer a.free(invalid_unchanged);
    try std.testing.expectEqualStrings(malformed, invalid_unchanged);
}
