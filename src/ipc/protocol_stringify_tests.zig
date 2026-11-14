//! Serializer tests: responses and events, screenshots and PNG encoding, audio, performance, panel and animation stats, widget events and id envelopes.

const std = @import("std");
const protocol = @import("protocol.zig");

test "stringify response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const resp = protocol.Response{ .ok = .{ .version = "0.1.0" } };
    try protocol.stringifyResponse(resp, bw);
    try std.testing.expectEqualSlices(u8, "{\"Ok\":{\"Version\":\"0.1.0\"}}\n", list.items);
}

test "stringify event" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const ev = protocol.Event{ .window_closed = .{ .seq = 3, .id = 42 } };
    try protocol.stringifyEvent(ev, bw);
    try std.testing.expectEqualSlices(u8, "{\"WindowClosed\":{\"seq\":3,\"id\":42}}\n", list.items);
}

test "stringify screenshot response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const sr = protocol.ScreenshotResult{
        .width = 1920,
        .height = 1080,
        .format = "png",
        .data = "SGVsbG8=",
        .path = null,
        .output_name = "WL-1",
        .capture_mode = "output",
        .frame_seq = 42,
    };
    const resp = protocol.Response{ .ok = .{ .screenshot = sr } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"Screenshot\":{\"width\":1920,\"height\":1080,\"format\":\"png\",\"data\":\"SGVsbG8=\",\"path\":null,\"output_name\":\"WL-1\",\"capture_mode\":\"output\",\"frame_seq\":42}}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}

test "encode png and base64" {
    const allocator = std.testing.allocator;
    const encode = @import("../screenshot/encode.zig");

    var pixels: [16]u32 = undefined;
    for (&pixels) |*p| p.* = 0xFF00FF00; // Opaque green premultiplied ARGB8888

    const png_bytes = try encode.encodePng(allocator, 4, 4, &pixels, 4);
    defer allocator.free(png_bytes);

    // Verify PNG header signature
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    try std.testing.expect(png_bytes.len > sig.len);
    try std.testing.expectEqualSlices(u8, &sig, png_bytes[0..sig.len]);

    const b64 = try encode.encodeBase64(allocator, png_bytes);
    defer allocator.free(b64);
    try std.testing.expect(b64.len > 0);
}

test "stringify camera response and event" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };

    const resp = protocol.Response{ .ok = .{ .camera = .{ .x = 100, .y = -50, .max_x = 1920, .max_y = 1080 } } };
    try protocol.stringifyResponse(resp, bw);
    try std.testing.expectEqualSlices(u8, "{\"Ok\":{\"Camera\":{\"x\":100,\"y\":-50,\"max_x\":1920,\"max_y\":1080,\"zoom_percent\":100}}}\n", list.items);

    list.clearRetainingCapacity();
    const ev = protocol.Event{ .camera_changed = .{ .seq = 7, .x = 200, .y = 100, .max_x = 1920, .max_y = 1080 } };
    try protocol.stringifyEvent(ev, bw);
    try std.testing.expectEqualSlices(u8, "{\"CameraChanged\":{\"seq\":7,\"x\":200,\"y\":100,\"max_x\":1920,\"max_y\":1080,\"zoom_percent\":100}}\n", list.items);
}

test "stringify audio state response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const streams = [_]protocol.SinkInputData{
        .{ .index = 5, .name = "Firefox", .app_id = "org.mozilla.firefox", .pid = 1234, .volume = 0.8, .muted = false },
    };
    const resp = protocol.Response{ .ok = .{ .audio_state = .{
        .master_volume = 0.6,
        .master_muted = false,
        .default_sink = "Built-in Audio",
        .streams = &streams,
    } } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"AudioState\":{\"master_volume\":0.6,\"master_muted\":false,\"default_sink\":\"Built-in Audio\",\"streams\":[{\"index\":5,\"name\":\"Firefox\",\"app_id\":\"org.mozilla.firefox\",\"pid\":1234,\"volume\":0.8,\"muted\":false}]}}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}

test "stringify performance stats includes edge sample counters" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const resp = protocol.Response{ .ok = .{ .performance_stats = .{
        .output_commits = 3,
        .output_failed_commits = 1,
        .titlebar_paints = 4,
        .footer_paints = 2,
        .edge_samples_attempted = 5,
        .edge_samples_succeeded = 4,
        .edge_samples_skipped = 9,
        .edge_sample_ns = 1234,
        .panel_paints = 0,
        .panel_allocated_bytes = 0,
        .panel_reused_bytes = 0,
        .icon_cache_hits = 0,
        .icon_cache_misses = 0,
        .icon_decode_ns = 0,
        .icon_decode_count = 0,
        .icon_decoded_bytes = 0,
        .icon_queue_depth_max = 0,
        .taskbar_paints = 1,
        .taskbar_paint_ns = 500,
        .taskbar_raster_pixels = 640,
        .taskbar_clock_frame_requests = 2,
        .taskbar_clock_paints = 1,
        .taskbar_start_paints = 0,
        .taskbar_chip_paints = 1,
        .taskbar_tray_paints = 0,
        .taskbar_hover_paints = 0,
        .taskbar_press_paints = 0,
        .taskbar_audio_paints = 0,
        .recent_errors_count = 0,
    } } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"PerformanceStats\":{\"output_commits\":3,\"output_failed_commits\":1,\"fps\":0.0,\"frame_time_ms\":0.0,\"missed_frames\":0,\"refresh_hz\":0.0,\"titlebar_paints\":4,\"footer_paints\":2,\"edge_samples_attempted\":5,\"edge_samples_succeeded\":4,\"edge_samples_skipped\":9,\"edge_sample_ns\":1234,\"panel_paints\":0,\"panel_allocated_bytes\":0,\"panel_reused_bytes\":0,\"icon_cache_hits\":0,\"icon_cache_misses\":0,\"icon_decode_ns\":0,\"icon_decode_count\":0,\"icon_decoded_bytes\":0,\"icon_queue_depth_max\":0,\"taskbar_paints\":1,\"taskbar_paint_ns\":500,\"taskbar_raster_pixels\":640,\"taskbar_clock_frame_requests\":2,\"taskbar_clock_paints\":1,\"taskbar_start_paints\":0,\"taskbar_chip_paints\":1,\"taskbar_tray_paints\":0,\"taskbar_hover_paints\":0,\"taskbar_press_paints\":0,\"taskbar_audio_paints\":0,\"recent_errors_count\":0,\"anim_frames_scheduled\":0,\"anim_wasted_wakeups\":0,\"anim_longest_ms\":0,\"anim_speed\":1,\"anim_enabled\":true,\"anim_reduced_motion\":false}}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);

    // Live producers add work timings; preserve the legacy fixture above.
    var extended = resp;
    extended.ok.performance_stats.screenshot_selection = .{ .motion_events = 500, .updates = 2, .toolbar_paints = 1, .scene_nodes_created = 19 };
    extended.ok.performance_stats.frame_work = .{
        .cpu_frame = .{ .samples = 3, .total_samples = 3, .avg_ms = 3, .p50_ms = 3, .p95_ms = 5, .p99_ms = 5, .max_ms = 5 },
    };
    list.clearRetainingCapacity();
    try protocol.stringifyResponse(extended, bw);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, list.items, .{});
    defer parsed.deinit();
    const selection = parsed.value.object.get("Ok").?.object.get("PerformanceStats").?.object.get("screenshot_selection").?;
    try std.testing.expectEqual(@as(i64, 500), selection.object.get("motion_events").?.integer);
    try std.testing.expectEqual(@as(i64, 2), selection.object.get("updates").?.integer);
    const work = parsed.value.object.get("Ok").?.object.get("PerformanceStats").?.object.get("frame_work").?;
    try std.testing.expectEqual(@as(i64, 3), work.object.get("cpu_frame").?.object.get("samples").?.integer);
    try std.testing.expect(!work.object.get("gpu_timing_available").?.bool);
    try std.testing.expectEqual(@as(i64, 0), work.object.get("gpu_elapsed").?.object.get("samples").?.integer);
}

test "stringify panel stats response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const resp = protocol.Response{ .ok = .{ .panel_stats = .{
        .paints = 1,
        .allocated_bytes = 4096,
        .reused_bytes = 2048,
        .paint_ns = 12345,
    } } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"PanelStats\":{\"paints\":1,\"allocated_bytes\":4096,\"reused_bytes\":2048,\"paint_ns\":12345}}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}

test "stringify animations response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const items = [_]protocol.AnimationData{
        .{ .site = "start_menu.slide", .value = 0.5, .velocity = 1.25, .target = 1, .settled = false, .curve = "spring" },
    };
    const resp = protocol.Response{ .ok = .{ .animations = &items } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"Animations\":[{\"site\":\"start_menu.slide\",\"value\":0.5,\"velocity\":1.25,\"target\":1,\"settled\":false,\"curve\":\"spring\"}]}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}

test "stringify WidgetChanged event" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const ev = protocol.Event{
        .widget_changed = .{
            .seq = 10,
            .time_ms = 1000,
            .session_id = "test-session",
            .panel = "control_center",
            .path = "control_center/wifi",
            .name = "wifi",
            .widget = .{
                .id = 1,
                .role = "toggle",
                .name = "wifi",
                .path = "control_center/wifi",
                .box = .{ .x = 10, .y = 20, .width = 30, .height = 40 },
                .on = true,
            },
        },
    };
    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    try protocol.stringifyEvent(ev, bw);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"WidgetChanged\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"control_center/wifi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"on\":true") != null);
}

test "stringify response with id envelope" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const resp = protocol.Response{ .ok = .handled };

    try protocol.stringifyResponseWithId(.{ .integer = 42 }, resp, bw);
    try std.testing.expectEqualSlices(u8, "{\"id\":42,\"Ok\":\"Handled\"}\n", list.items);

    list.clearRetainingCapacity();
    try protocol.stringifyResponseWithId(.{ .string = "query-1" }, resp, bw);
    try std.testing.expectEqualSlices(u8, "{\"id\":\"query-1\",\"Ok\":\"Handled\"}\n", list.items);
}

pub fn expectJsonEqual(expected: std.json.Value, actual: std.json.Value) !void {
    if (expected == .integer and actual == .float) return std.testing.expectEqual(@as(f64, @floatFromInt(expected.integer)), actual.float);
    if (expected == .float and actual == .integer) return std.testing.expectEqual(expected.float, @as(f64, @floatFromInt(actual.integer)));
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .object => |obj| {
            try std.testing.expectEqual(obj.count(), actual.object.count());
            var it = obj.iterator();
            while (it.next()) |entry| try expectJsonEqual(entry.value_ptr.*, actual.object.get(entry.key_ptr.*) orelse return error.TestUnexpectedResult);
        },
        .array => |arr| {
            try std.testing.expectEqual(arr.items.len, actual.array.items.len);
            for (arr.items, actual.array.items) |a, b| try expectJsonEqual(a, b);
        },
        .string, .number_string => |s| try std.testing.expectEqualStrings(s, if (actual == .string) actual.string else actual.number_string),
        .integer => |i| try std.testing.expectEqual(i, actual.integer),
        .float => |f| try std.testing.expectEqual(f, actual.float),
        .bool => |b| try std.testing.expectEqual(b, actual.bool),
        .null => {},
    }
}

test "response serializers preserve baseline fields rounding and omissions" {
    @setEvalBranchQuota(200_000);
    const fixtures = @import("../ipc_serializer_fixtures.zig");
    var lines = std.mem.splitScalar(u8, @embedFile("../ipc_serializers.jsonl"), '\n');
    inline for (@typeInfo(protocol.ResponsePayload).@"union".field_names) |field_name| {
        inline for (.{ false, true }) |populated| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const payload = @unionInit(protocol.ResponsePayload, field_name, fixtures.sample(@FieldType(protocol.ResponsePayload, field_name), populated));
            var list: std.ArrayList(u8) = .empty;
            try protocol.stringifyResponse(.{ .ok = payload }, protocol.BufferWriter{ .list = &list, .allocator = a });
            const actual = try std.json.parseFromSlice(std.json.Value, a, list.items, .{});
            const expected = try std.json.parseFromSlice(std.json.Value, a, lines.next().?, .{});
            expectJsonEqual(expected.value, actual.value) catch |err| {
                std.debug.print("serializer {s}, populated={}\n", .{ field_name, populated });
                return err;
            };
        }
    }
}
