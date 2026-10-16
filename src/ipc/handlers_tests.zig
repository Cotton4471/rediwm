//! Tests for the IPC widget tree and payload helpers.

const std = @import("std");
const protocol = @import("protocol.zig");
const ui = @import("ui");
const walkWidgetTree = @import("handlers_widgets.zig").walkWidgetTree;
const computeTargetPoint = @import("handlers_widgets.zig").computeTargetPoint;
const findWidgetInNodes = @import("handlers_widgets.zig").findWidgetInNodes;

test "walkWidgetTree builds hierarchical paths from named ancestors and preserves parent_index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var slider = ui.layout.Widget{
        .name = "output_volume",
        .kind = .{ .slider = .{ .value = 0.5, .min = 0, .max = 1, .step = 0.05, .on_change = struct {
            fn noop(_: ?*anyopaque, _: usize, _: f32) void {}
        }.noop } },
    };
    var intermediate_container = ui.layout.Widget{
        .kind = .container,
        .children = @as([*]ui.layout.Widget, @ptrCast(&slider))[0..1],
    };
    const sound_section = ui.layout.Widget{
        .name = "sound",
        .kind = .container,
        .children = @as([*]ui.layout.Widget, @ptrCast(&intermediate_container))[0..1],
    };
    const button = ui.layout.Widget{
        .name = "close",
        .kind = .{ .button = .{ .label = "Close settings" } },
    };
    var root_children = [_]ui.layout.Widget{ sound_section, button };
    var root = ui.layout.Widget{
        .kind = .container,
        .children = &root_children,
    };

    var list = std.ArrayList(protocol.WidgetNodeData).empty;
    try walkWidgetTree(&root, &list, a, "control_center", null, 100, 200, null);

    // root: index 0, parent_index null, path null (unnamed)
    try std.testing.expectEqual(@as(usize, 5), list.items.len);
    try std.testing.expect(list.items[0].parent_index == null);
    try std.testing.expect(list.items[0].path == null);

    // sound_section: index 1, parent_index 0, path control_center/sound
    try std.testing.expectEqual(@as(?usize, 0), list.items[1].parent_index);
    try std.testing.expectEqualStrings("control_center/sound", list.items[1].path.?);
    try std.testing.expectEqualStrings("sound", list.items[1].name.?);

    // intermediate_container: index 2, parent_index 1, path null (unnamed)
    try std.testing.expectEqual(@as(?usize, 1), list.items[2].parent_index);
    try std.testing.expect(list.items[2].path == null);

    // slider: index 3, parent_index 2, path control_center/sound/output_volume
    try std.testing.expectEqual(@as(?usize, 2), list.items[3].parent_index);
    try std.testing.expectEqualStrings("control_center/sound/output_volume", list.items[3].path.?);
    try std.testing.expectEqualStrings("output_volume", list.items[3].name.?);
    try std.testing.expectEqual(@as(?f64, 0.5), list.items[3].value);
    try std.testing.expectEqual(@as(?f64, 0), list.items[3].min);
    try std.testing.expectEqual(@as(?f64, 1), list.items[3].max);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), list.items[3].step.?, 0.0001);
    try std.testing.expectEqual(list.items[3].box.x + 100, list.items[3].global_box.?.x);
    try std.testing.expectEqual(list.items[3].box.y + 200, list.items[3].global_box.?.y);

    // button: index 4, parent_index 0, path control_center/close
    try std.testing.expectEqual(@as(?usize, 0), list.items[4].parent_index);
    try std.testing.expectEqualStrings("control_center/close", list.items[4].path.?);
    try std.testing.expectEqualStrings("close", list.items[4].name.?);
    try std.testing.expectEqualStrings("btn_Close settings", list.items[4].semantic_id.?);
}

test "walkWidgetTree captures per-kind state and scroll container clipping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const toggle = ui.layout.Widget{
        .name = "dark_mode",
        .kind = .{ .toggle = .{ .on = true, .on_change = struct {
            fn noop(_: ?*anyopaque, _: usize, _: bool) void {}
        }.noop } },
    };
    const text_in = ui.layout.Widget{
        .name = "search_box",
        .kind = .{ .text_input = .{
            .placeholder = "Search...",
            .value = try a.dupe(u8, "super secret input query"),
            .on_change = struct {
                fn noop(_: ?*anyopaque, _: usize, _: []const u8) void {}
            }.noop,
        } },
    };
    // Child 1 inside scroll container: partially visible
    const item1 = ui.layout.Widget{
        .computed_x = 10,
        .computed_y = 50,
        .computed_width = 80,
        .computed_height = 80,
        .kind = .container,
    };
    // Child 2 inside scroll container: completely scrolled out of view (y > 100)
    const item2 = ui.layout.Widget{
        .computed_x = 10,
        .computed_y = 150,
        .computed_width = 80,
        .computed_height = 80,
        .kind = .container,
    };
    var scroll_kids = [_]ui.layout.Widget{ item1, item2 };
    const scroll = ui.layout.Widget{
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 100,
        .computed_height = 100,
        .kind = .{ .scroll_container = .{ .scroll_offset = 20, .content_size = 300 } },
        .children = &scroll_kids,
    };
    var root_kids = [_]ui.layout.Widget{ toggle, text_in, scroll };
    var root = ui.layout.Widget{
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 200,
        .computed_height = 400,
        .kind = .container,
        .children = &root_kids,
    };

    var list = std.ArrayList(protocol.WidgetNodeData).empty;
    try walkWidgetTree(&root, &list, a, "panel", null, 50, 60, null);

    // Toggle widget checks
    const tg_node = list.items[1];
    try std.testing.expectEqualStrings("toggle", tg_node.role);
    try std.testing.expectEqual(@as(?bool, true), tg_node.on);
    try std.testing.expectEqual(@as(?bool, true), tg_node.checked);

    // TextInput widget checks: returns text_length and placeholder label, NEVER contents
    const ti_node = list.items[2];
    try std.testing.expectEqualStrings("text_input", ti_node.role);
    try std.testing.expectEqualStrings("Search...", ti_node.label.?);
    try std.testing.expectEqual(@as(?usize, 24), ti_node.text_length);

    // ScrollContainer checks
    const sc_node = list.items[3];
    try std.testing.expectEqualStrings("scroll_container", sc_node.role);
    try std.testing.expectEqual(@as(?f64, 20), sc_node.scroll_offset);
    try std.testing.expectEqual(@as(?f64, 300), sc_node.content_size);

    // item1: [50, 130] in y, scroll container viewport is [0, 100]. Overlaps -> visible = true, clipped = true
    const item1_node = list.items[4];
    try std.testing.expectEqual(true, item1_node.visible);
    try std.testing.expectEqual(true, item1_node.clipped);

    // item2: [150, 230] in y, outside [0, 100] -> visible = false, clipped = true
    const item2_node = list.items[5];
    try std.testing.expectEqual(false, item2_node.visible);
    try std.testing.expectEqual(true, item2_node.clipped);
}

test "computeTargetPoint calculates coordinates with fractional offsets and clamping" {
    const box = protocol.RectData{
        .x = 100,
        .y = 200,
        .width = 50,
        .height = 40,
    };

    // Default center (0.5, 0.5)
    const center = computeTargetPoint(box, .{ .x = 0.5, .y = 0.5 });
    try std.testing.expectEqual(@as(i32, 125), center.x);
    try std.testing.expectEqual(@as(i32, 220), center.y);

    // Top-left (0.0, 0.0)
    const top_left = computeTargetPoint(box, .{ .x = 0.0, .y = 0.0 });
    try std.testing.expectEqual(@as(i32, 100), top_left.x);
    try std.testing.expectEqual(@as(i32, 200), top_left.y);

    // Bottom-right (1.0, 1.0)
    const bottom_right = computeTargetPoint(box, .{ .x = 1.0, .y = 1.0 });
    try std.testing.expectEqual(@as(i32, 150), bottom_right.x);
    try std.testing.expectEqual(@as(i32, 240), bottom_right.y);

    // Slider fraction (0.2, 0.5)
    const slider_pt = computeTargetPoint(box, .{ .x = 0.2, .y = 0.5 });
    try std.testing.expectEqual(@as(i32, 110), slider_pt.x);
    try std.testing.expectEqual(@as(i32, 220), slider_pt.y);

    // Out-of-bounds clamped to [0, 1]
    const clamped_pt = computeTargetPoint(box, .{ .x = -0.5, .y = 1.5 });
    try std.testing.expectEqual(@as(i32, 100), clamped_pt.x);
    try std.testing.expectEqual(@as(i32, 240), clamped_pt.y);
}

test "findWidgetInNodes resolves by path, name, or semantic_id" {
    const nodes = [_]protocol.WidgetNodeData{
        .{
            .id = 1,
            .role = "button",
            .name = "tab_sound",
            .path = "control_center/tab_sound",
            .semantic_id = "btn_Sound",
            .label = "Sound",
            .box = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
            .global_box = .{ .x = 10, .y = 20, .width = 100, .height = 40 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 2,
            .role = "button",
            .name = "disabled_btn",
            .path = "control_center/disabled_btn",
            .semantic_id = "btn_Disabled",
            .box = .{ .x = 0, .y = 40, .width = 100, .height = 40 },
            .global_box = .{ .x = 10, .y = 60, .width = 100, .height = 40 },
            .visible = true,
            .is_disabled = true,
        },
        .{
            .id = 3,
            .role = "row",
            .name = "hidden_row",
            .path = "control_center/hidden_row",
            .semantic_id = "row_3",
            .box = .{ .x = 0, .y = 80, .width = 100, .height = 40 },
            .global_box = .{ .x = 10, .y = 100, .width = 100, .height = 40 },
            .visible = false,
            .is_disabled = false,
        },
    };

    // Match by full path
    const m1 = findWidgetInNodes(&nodes, "control_center/tab_sound", "tab_sound");
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(@as(u64, 1), m1.?.id);

    // Match by subpath / name
    const m2 = findWidgetInNodes(&nodes, "tab_sound", "tab_sound");
    try std.testing.expect(m2 != null);
    try std.testing.expectEqual(@as(u64, 1), m2.?.id);

    // Match by semantic_id
    const m3 = findWidgetInNodes(&nodes, "btn_Sound", "btn_Sound");
    try std.testing.expect(m3 != null);
    try std.testing.expectEqual(@as(u64, 1), m3.?.id);

    // Match disabled widget
    const m4 = findWidgetInNodes(&nodes, "control_center/disabled_btn", "disabled_btn");
    try std.testing.expect(m4 != null);
    try std.testing.expect(m4.?.is_disabled);

    // Match invisible widget
    const m5 = findWidgetInNodes(&nodes, "control_center/hidden_row", "hidden_row");
    try std.testing.expect(m5 != null);
    try std.testing.expect(!m5.?.visible);

    // Not found
    const m6 = findWidgetInNodes(&nodes, "control_center/nonexistent", "nonexistent");
    try std.testing.expect(m6 == null);
}

test "findWidgetInNodes resolves Phase 5 taskbar and window hotspot nodes" {
    const taskbar_nodes = [_]protocol.WidgetNodeData{
        .{
            .id = 1,
            .role = "panel",
            .name = "taskbar",
            .path = "taskbar",
            .box = .{ .x = 0, .y = 0, .width = 1920, .height = 64 },
            .global_box = .{ .x = 0, .y = 1016, .width = 1920, .height = 64 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 2,
            .role = "button",
            .name = "start",
            .path = "taskbar/start",
            .semantic_id = "btn_Start",
            .label = "Start",
            .box = .{ .x = 16, .y = 11, .width = 42, .height = 42 },
            .global_box = .{ .x = 16, .y = 1027, .width = 42, .height = 42 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 3,
            .role = "label",
            .name = "clock",
            .path = "taskbar/clock",
            .semantic_id = "taskbar_clock",
            .label = "Clock",
            .box = .{ .x = 1800, .y = 11, .width = 100, .height = 42 },
            .global_box = .{ .x = 1800, .y = 1027, .width = 100, .height = 42 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 4,
            .role = "button",
            .name = "chip_42",
            .path = "taskbar/window/42",
            .semantic_id = "chip_42",
            .label = "Terminal",
            .box = .{ .x = 74, .y = 11, .width = 120, .height = 42 },
            .global_box = .{ .x = 74, .y = 1027, .width = 120, .height = 42 },
            .visible = true,
            .is_disabled = false,
            .is_focused = true,
        },
        .{
            .id = 5,
            .role = "button",
            .name = "tray/0",
            .path = "taskbar/tray/0",
            .semantic_id = "tray_volume",
            .label = "Volume",
            .box = .{ .x = 1720, .y = 11, .width = 32, .height = 32 },
            .global_box = .{ .x = 1720, .y = 1027, .width = 32, .height = 32 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 6,
            .role = "button",
            .name = "tray/1",
            .path = "taskbar/tray/1",
            .semantic_id = "tray_network",
            .label = "Network",
            .box = .{ .x = 1760, .y = 11, .width = 32, .height = 32 },
            .global_box = .{ .x = 1760, .y = 1027, .width = 32, .height = 32 },
            .visible = true,
            .is_disabled = false,
        },
    };

    // Taskbar hotspot queries
    const start_node = findWidgetInNodes(&taskbar_nodes, "taskbar/start", "start");
    try std.testing.expect(start_node != null);
    try std.testing.expectEqualStrings("btn_Start", start_node.?.semantic_id.?);

    const clock_node = findWidgetInNodes(&taskbar_nodes, "taskbar/clock", "clock");
    try std.testing.expect(clock_node != null);
    try std.testing.expectEqualStrings("taskbar_clock", clock_node.?.semantic_id.?);

    const chip_node = findWidgetInNodes(&taskbar_nodes, "taskbar/window/42", "window/42");
    try std.testing.expect(chip_node != null);
    try std.testing.expectEqualStrings("chip_42", chip_node.?.semantic_id.?);
    try std.testing.expect(chip_node.?.is_focused);

    const tray_vol = findWidgetInNodes(&taskbar_nodes, "taskbar/tray/0", "tray/0");
    try std.testing.expect(tray_vol != null);
    try std.testing.expectEqualStrings("tray_volume", tray_vol.?.semantic_id.?);

    // Window controls
    const window_nodes = [_]protocol.WidgetNodeData{
        .{
            .id = 1,
            .role = "window",
            .name = "window",
            .path = "window/42",
            .label = "Terminal",
            .box = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
            .global_box = .{ .x = 100, .y = 100, .width = 800, .height = 600 },
            .visible = true,
            .is_focused = true,
        },
        .{
            .id = 2,
            .role = "titlebar",
            .name = "titlebar",
            .path = "window/42/titlebar",
            .label = "Terminal",
            .box = .{ .x = 0, .y = 0, .width = 800, .height = 38 },
            .global_box = .{ .x = 100, .y = 100, .width = 800, .height = 38 },
            .visible = true,
            .is_focused = true,
        },
        .{
            .id = 3,
            .role = "button",
            .name = "close",
            .path = "window/42/close",
            .semantic_id = "btn_close",
            .label = "close",
            .box = .{ .x = 760, .y = 4, .width = 32, .height = 30 },
            .global_box = .{ .x = 860, .y = 104, .width = 32, .height = 30 },
            .visible = true,
            .is_focused = true,
        },
        .{
            .id = 4,
            .role = "button",
            .name = "maximize",
            .path = "window/42/maximize",
            .semantic_id = "btn_maximize",
            .label = "maximize",
            .box = .{ .x = 724, .y = 4, .width = 32, .height = 30 },
            .global_box = .{ .x = 824, .y = 104, .width = 32, .height = 30 },
            .visible = true,
            .is_focused = true,
        },
        .{
            .id = 5,
            .role = "button",
            .name = "minimize",
            .path = "window/42/minimize",
            .semantic_id = "btn_minimize",
            .label = "minimize",
            .box = .{ .x = 688, .y = 4, .width = 32, .height = 30 },
            .global_box = .{ .x = 788, .y = 104, .width = 32, .height = 30 },
            .visible = true,
            .is_focused = true,
        },
    };

    const win_root = findWidgetInNodes(&window_nodes, "window/42", "window/42");
    try std.testing.expect(win_root != null);
    try std.testing.expectEqualStrings("window", win_root.?.role);

    const win_close = findWidgetInNodes(&window_nodes, "window/42/close", "close");
    try std.testing.expect(win_close != null);
    try std.testing.expectEqualStrings("btn_close", win_close.?.semantic_id.?);

    const win_max = findWidgetInNodes(&window_nodes, "window/42/maximize", "maximize");
    try std.testing.expect(win_max != null);
    try std.testing.expectEqualStrings("btn_maximize", win_max.?.semantic_id.?);

    const win_min = findWidgetInNodes(&window_nodes, "window/42/minimize", "minimize");
    try std.testing.expect(win_min != null);
    try std.testing.expectEqualStrings("btn_minimize", win_min.?.semantic_id.?);
}
