const std = @import("std");
const loader = @import("loader.zig");
const device = @import("input_device.zig");

test "pointer overrides keep devices independent and inherit kind defaults" {
    var cfg = try loader.parse(std.testing.allocator,
        \\[input]
        \\pointer_speed = 0.2
        \\pointer_speed_touchpad = -0.4
        \\disable_while_typing = false
        \\disable_while_typing_touchpad = true
        \\natural_scroll = false
        \\tap_drag = false
        \\[[input_device]]
        \\id = "mouse-a"
        \\pointer_speed = 0.8
        \\[[input_device]]
        \\id = "touchpad-a"
        \\natural_scroll = true
    , "test");
    defer cfg.deinit();
    const mouse = device.resolve(cfg.input, cfg.input_devices, "mouse-a", false);
    const touchpad = device.resolve(cfg.input, cfg.input_devices, "touchpad-a", true);
    const other = device.resolve(cfg.input, cfg.input_devices, "mouse-b", false);
    try std.testing.expect(!mouse.natural_scroll);
    try std.testing.expect(touchpad.natural_scroll);
    try std.testing.expectEqual(@as(f32, 0.8), mouse.pointer_speed);
    try std.testing.expectEqual(@as(f32, -0.4), touchpad.pointer_speed);
    try std.testing.expectEqual(@as(f32, 0.2), other.pointer_speed);
    try std.testing.expect(!mouse.disable_while_typing);
    try std.testing.expect(touchpad.disable_while_typing);
    try std.testing.expect(!touchpad.tap_drag);
    try std.testing.expectEqual(@as(?f32, null), cfg.input_devices[1].pointer_speed);
}

test "global-only input files remain backwards compatible" {
    var cfg = try loader.parse(std.testing.allocator, "[input]\nnatural_scroll = false\npointer_speed = 0.6\npointer_speed_touchpad = -0.7\n", "legacy");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.input_devices.len);
    const mouse = device.resolve(cfg.input, cfg.input_devices, "mouse", false);
    const pad = device.resolve(cfg.input, cfg.input_devices, null, true);
    try std.testing.expect(!mouse.natural_scroll and !pad.natural_scroll);
    try std.testing.expectEqual(@as(f32, 0.6), mouse.pointer_speed);
    try std.testing.expectEqual(@as(f32, -0.7), pad.pointer_speed);
}

test "input device records reject incomplete duplicate and invalid matchers or values" {
    inline for (.{
        "[[input_device]]",
        "[[input_device]]\nnatural_scroll = true\n",
        "[[input_device]]\nid = \"\"\n",
        "[[input_device]]\nid = \"mouse\"\nid = \"other\"\n",
        "[[input_device]]\nid = \"mouse\"\n[[input_device]]\nid = \"mouse\"\n",
        "[[input_device]]\nid = \"mouse\"\npointer_speed = 1.1\n",
        "[[input_device]]\nid = \"mouse\"\npointer_speed = nan\n",
        "[[input_device]]\nid = \"mouse\"\npointer_speed = inf\n",
        "[[input_device]]\nid = \"mouse\"\nnatural_scroll = 1\n",
        "[[input_device]]\nid = \"mouse\"\nnatural_scroll = true\nnatural_scroll = false\n",
        "[[input_device]]\nid = \"mouse\"\nunknown = true\n",
        "[[input_device]]\nid = \"mouse\"\ninvert_scroll = true\n",
        "[input_device]\nid = \"mouse\"\n",
        "[[input_device]]\nid = 'mouse'\n",
        "[[input_device]]\n'id' = \"mouse\"\n",
    }) |bytes| try std.testing.expectError(error.InvalidConfig, loader.parse(std.testing.allocator, bytes, "invalid-device"));
}

test "unidentified or duplicate devices cannot obtain an arbitrary matching override" {
    const records: []const device.Record = &.{
        .{ .id = "collision", .natural_scroll = false, .pointer_speed = 0.9 },
        .{ .id = "collision", .natural_scroll = true, .pointer_speed = -0.9 },
    };
    const defaults: loader.InputConfig = .{ .natural_scroll = false, .pointer_speed = 0.1 };
    for ([_]?[]const u8{ null, "", "collision", "different" }) |id| {
        const effective = device.resolve(defaults, records, id, false);
        try std.testing.expect(!effective.natural_scroll);
        try std.testing.expectEqual(@as(f32, 0.1), effective.pointer_speed);
    }
}

test "prepared pointer changes are unpublished and only modify one field of one record" {
    var cfg = try loader.parse(std.testing.allocator, "[[input_device]]\nid = \"mouse\"\nnatural_scroll = false\n[[input_device]]\nid = \"pad\"\nnatural_scroll = true\n", "test");
    defer cfg.deinit();
    const prepared = try device.prepareSet(&cfg, "mouse", "pointer_speed", 0.6);
    try std.testing.expect(device.eql(cfg.input_devices, cfg.input_devices));
    try std.testing.expectEqual(@as(?f32, null), cfg.input_devices[0].pointer_speed);
    prepared.commit(&cfg);
    try std.testing.expectEqual(@as(?f32, 0.6), cfg.input_devices[0].pointer_speed);
    try std.testing.expectEqual(@as(?bool, false), cfg.input_devices[0].natural_scroll);
    try std.testing.expectEqual(@as(?bool, true), cfg.input_devices[1].natural_scroll);
    const added = try device.prepareSet(&cfg, "second-mouse", "natural_scroll", true);
    try std.testing.expectEqual(@as(usize, 3), added.records.len);
    try std.testing.expectEqualStrings("second-mouse", added.record.id);
    try std.testing.expectEqual(@as(?f32, null), added.record.pointer_speed);
    try std.testing.expectEqual(@as(usize, 2), cfg.input_devices.len);
    added.commit(&cfg);
    try std.testing.expectEqual(@as(usize, 3), cfg.input_devices.len);
    try std.testing.expectError(error.InvalidValue, device.prepareSet(&cfg, "mouse", "pointer_speed", std.math.nan(f32)));
}

test "reloading new defaults retains per-device overrides" {
    const records: []const device.Record = &.{.{ .id = "mouse", .natural_scroll = false }};
    const before = device.resolve(.{ .natural_scroll = true, .pointer_speed = 0.1 }, records, "mouse", false);
    const after = device.resolve(.{ .natural_scroll = true, .pointer_speed = 0.7 }, records, "mouse", false);
    try std.testing.expect(!before.natural_scroll and !after.natural_scroll);
    try std.testing.expectEqual(@as(f32, 0.1), before.pointer_speed);
    try std.testing.expectEqual(@as(f32, 0.7), after.pointer_speed);
}

test "reset clears explicit overrides while inheritance indicators reflect presence not equality" {
    var cfg = try loader.parse(
        std.testing.allocator,
        "[input]\nnatural_scroll = false\npointer_speed = 0.2\n" ++
            "[[input_device]]\nid = \"mouse\"\nnatural_scroll = false\npointer_speed = 0.2\n" ++
            "[[input_device]]\nid = \"pad\"\ntap_to_click = false\n",
        "test",
    );
    defer cfg.deinit();
    try std.testing.expect(device.hasOverrides(cfg.input_devices, "mouse"));
    try std.testing.expect(device.isOverridden(cfg.input_devices, "mouse", "natural_scroll"));
    try std.testing.expect(device.isOverridden(cfg.input_devices, "mouse", "pointer_speed"));
    try std.testing.expect(!device.isOverridden(cfg.input_devices, "mouse", "tap_to_click"));
    try std.testing.expect(!device.hasOverrides(cfg.input_devices, null));
    try std.testing.expect(!device.isOverridden(cfg.input_devices, "absent", "natural_scroll"));
    const reset = try device.prepareReset(&cfg, "mouse");
    try std.testing.expect(device.hasOverrides(cfg.input_devices, "mouse"));
    reset.commit(&cfg);
    try std.testing.expect(!device.hasOverrides(cfg.input_devices, "mouse"));
    try std.testing.expect(!device.isOverridden(cfg.input_devices, "mouse", "natural_scroll"));
    try std.testing.expect(device.hasOverrides(cfg.input_devices, "pad"));
    cfg.input.natural_scroll = true;
    cfg.input.pointer_speed = 0.6;
    const inherited = device.resolve(cfg.input, cfg.input_devices, "mouse", false);
    try std.testing.expect(inherited.natural_scroll);
    try std.testing.expectEqual(@as(f32, 0.6), inherited.pointer_speed);
    const absent = try device.prepareReset(&cfg, "absent");
    try std.testing.expectEqual(@as(?usize, null), absent.index);
    absent.commit(&cfg);
    try std.testing.expectEqual(@as(usize, 2), cfg.input_devices.len);
    try std.testing.expectError(error.InvalidValue, device.prepareReset(&cfg, ""));
}
