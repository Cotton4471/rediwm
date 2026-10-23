//! Action parsing tests: virtual input, screenshots, the camera and audio.

const std = @import("std");
const protocol = @import("protocol.zig");

test "parse virtual input actions" {
    const allocator = std.testing.allocator;

    const r_mc = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"move_cursor\",\"params\":{\"x\":100,\"y\":200,\"output\":\"HDMI-A-1\"}}");
    switch (r_mc) {
        .action => |act| switch (act) {
            .move_cursor => |p| {
                try std.testing.expectEqual(@as(i32, 100), p.x);
                try std.testing.expectEqual(@as(i32, 200), p.y);
                try std.testing.expectEqualSlices(u8, "HDMI-A-1", p.output.?);
                allocator.free(p.output.?);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_mcr = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"move_cursor_relative\",\"params\":{\"dx\":15,\"dy\":-5}}");
    switch (r_mcr) {
        .action => |act| switch (act) {
            .move_cursor_relative => |p| {
                try std.testing.expectEqual(@as(i32, 15), p.dx);
                try std.testing.expectEqual(@as(i32, -5), p.dy);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_pb = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"pointer_button\",\"params\":{\"button\":272,\"pressed\":true}}");
    switch (r_pb) {
        .action => |act| switch (act) {
            .pointer_button => |p| {
                try std.testing.expectEqual(@as(u32, 272), p.button);
                try std.testing.expectEqual(true, p.pressed);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_clk1 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"click\",\"params\":{\"button\":273}}");
    switch (r_clk1) {
        .action => |act| switch (act) {
            .click => |p| try std.testing.expectEqual(@as(u32, 273), p.button),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_clk2 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"click\"}");
    switch (r_clk2) {
        .action => |act| switch (act) {
            .click => |p| try std.testing.expectEqual(@as(u32, 0x110), p.button),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_sc = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"scroll\",\"params\":{\"dx\":0.0,\"dy\":15.5}}");
    switch (r_sc) {
        .action => |act| switch (act) {
            .scroll => |p| {
                try std.testing.expectEqual(@as(f64, 0.0), p.dx);
                try std.testing.expectEqual(@as(f64, 15.5), p.dy);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_k = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"key\",\"params\":{\"keycode\":28,\"pressed\":false}}");
    switch (r_k) {
        .action => |act| switch (act) {
            .key => |p| {
                try std.testing.expectEqual(@as(u32, 28), p.keycode);
                try std.testing.expectEqual(false, p.pressed);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_kp = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"key_press\",\"params\":{\"key\":\"Return\"}}");
    switch (r_kp) {
        .action => |act| switch (act) {
            .key_press => |p| {
                try std.testing.expectEqualSlices(u8, "Return", p.key);
                allocator.free(p.key);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_tt = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"type_text\",\"params\":{\"text\":\"echo hello\"}}");
    switch (r_tt) {
        .action => |act| switch (act) {
            .type_text => |p| {
                try std.testing.expectEqualSlices(u8, "echo hello", p.text);
                allocator.free(p.text);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_dg = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"drag\",\"params\":{\"from_x\":10,\"from_y\":20,\"to_x\":100,\"to_y\":200,\"button\":272}}");
    switch (r_dg) {
        .action => |act| switch (act) {
            .drag => |p| {
                try std.testing.expectEqual(@as(i32, 10), p.from_x);
                try std.testing.expectEqual(@as(i32, 20), p.from_y);
                try std.testing.expectEqual(@as(i32, 100), p.to_x);
                try std.testing.expectEqual(@as(i32, 200), p.to_y);
                try std.testing.expectEqual(@as(u32, 272), p.button);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
}

test "parse screenshot action" {
    const allocator = std.testing.allocator;

    const r_sc1 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"screenshot\"}");
    switch (r_sc1) {
        .action => |act| switch (act) {
            .screenshot => |p| {
                try std.testing.expectEqual(@as(?[]const u8, null), p.output);
                try std.testing.expectEqual(@as(?u64, null), p.window_id);
                try std.testing.expectEqual(false, p.include_cursor);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_sc2 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"screenshot\",\"params\":{\"output\":\"WL-1\",\"window_id\":12,\"mode\":\"visible-region\",\"include_cursor\":true,\"path\":\"/tmp/shot.png\"}}");
    switch (r_sc2) {
        .action => |act| switch (act) {
            .screenshot => |p| {
                try std.testing.expectEqualSlices(u8, "WL-1", p.output.?);
                try std.testing.expectEqual(@as(?u64, 12), p.window_id);
                try std.testing.expectEqualSlices(u8, "visible-region", p.mode.?);
                try std.testing.expectEqual(true, p.include_cursor);
                try std.testing.expectEqualSlices(u8, "/tmp/shot.png", p.path.?);
                allocator.free(p.output.?);
                allocator.free(p.mode.?);
                allocator.free(p.path.?);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
}

test "parse camera actions" {
    const allocator = std.testing.allocator;

    const r_get = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_camera\"}");
    switch (r_get) {
        .action => |act| try std.testing.expectEqual(protocol.Action.get_camera, act),
        else => return error.TestFailed,
    }

    const r_reset = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"reset_camera\"}");
    switch (r_reset) {
        .action => |act| try std.testing.expectEqual(protocol.Action.reset_camera, act),
        else => return error.TestFailed,
    }

    const r_set = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_camera\",\"params\":{\"x\":250,\"y\":-150}}");
    switch (r_set) {
        .action => |act| switch (act) {
            .set_camera => |p| {
                try std.testing.expectEqual(@as(i32, 250), p.x);
                try std.testing.expectEqual(@as(i32, -150), p.y);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
}

test "parse audio actions" {
    const allocator = std.testing.allocator;

    const r_vol = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_master_volume\",\"params\":{\"volume\":0.5}}");
    switch (r_vol) {
        .action => |act| switch (act) {
            .set_master_volume => |p| try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.volume, 1e-6),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    // Integer JSON values must also be accepted for a float field.
    const r_vol_int = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_master_volume\",\"params\":{\"volume\":1}}");
    switch (r_vol_int) {
        .action => |act| switch (act) {
            .set_master_volume => |p| try std.testing.expectApproxEqAbs(@as(f32, 1.0), p.volume, 1e-6),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_master_volume\",\"params\":{\"volume\":1.5}}"));

    const r_mute = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"toggle_mute\"}");
    switch (r_mute) {
        .action => |act| try std.testing.expectEqual(protocol.Action.toggle_mute, act),
        else => return error.TestFailed,
    }

    const r_app = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_app_volume\",\"params\":{\"index\":7,\"volume\":0.8}}");
    switch (r_app) {
        .action => |act| switch (act) {
            .set_app_volume => |p| {
                try std.testing.expectEqual(@as(u32, 7), p.index);
                try std.testing.expectApproxEqAbs(@as(f32, 0.8), p.volume, 1e-6);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_app_mute = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_app_mute\",\"params\":{\"index\":7,\"muted\":true}}");
    switch (r_app_mute) {
        .action => |act| switch (act) {
            .set_app_mute => |p| {
                try std.testing.expectEqual(@as(u32, 7), p.index);
                try std.testing.expectEqual(true, p.muted);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_get = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_audio_state\"}");
    switch (r_get) {
        .action => |act| try std.testing.expectEqual(protocol.Action.get_audio_state, act),
        else => return error.TestFailed,
    }

    const r_stats = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_panel_stats\"}");
    switch (r_stats) {
        .action => |act| try std.testing.expectEqual(protocol.Action.get_panel_stats, act),
        else => return error.TestFailed,
    }

    const r_anims = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_animations\"}");
    switch (r_anims) {
        .action => |act| try std.testing.expectEqual(protocol.Action.get_animations, act),
        else => return error.TestFailed,
    }

    const r_reset = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"reset_panel_stats\"}");
    switch (r_reset) {
        .action => |act| try std.testing.expectEqual(protocol.Action.reset_panel_stats, act),
        else => return error.TestFailed,
    }

    const r_pinch = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"pinch\",\"params\":{\"phase\":\"begin\",\"scale\":1.2,\"fingers\":2}}");
    switch (r_pinch) {
        .action => |act| switch (act) {
            .pinch => |p| {
                try std.testing.expectEqual(protocol.GesturePhase.begin, p.phase);
                try std.testing.expectApproxEqAbs(@as(f64, 1.2), p.scale, 1e-9);
                try std.testing.expectEqual(@as(u32, 2), p.fingers);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_swipe = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"swipe\",\"params\":{\"phase\":\"update\",\"dx\":12,\"dy\":-4}}");
    switch (r_swipe) {
        .action => |act| switch (act) {
            .swipe => |p| {
                try std.testing.expectEqual(protocol.GesturePhase.update, p.phase);
                try std.testing.expectApproxEqAbs(@as(f64, 12), p.dx, 1e-9);
                try std.testing.expectApproxEqAbs(@as(f64, -4), p.dy, 1e-9);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_time = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_anim_time\",\"params\":{\"ms\":110}}");
    switch (r_time) {
        .action => |act| switch (act) {
            .set_anim_time => |p| try std.testing.expectEqual(@as(?i64, 110), p.ms),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_clear = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_anim_time\",\"params\":{\"ms\":null}}");
    switch (r_clear) {
        .action => |act| switch (act) {
            .set_anim_time => |p| try std.testing.expectEqual(@as(?i64, null), p.ms),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_open = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"open_start_menu\"}");
    switch (r_open) {
        .action => |act| try std.testing.expectEqual(protocol.Action.open_start_menu, act),
        else => return error.TestFailed,
    }
}
