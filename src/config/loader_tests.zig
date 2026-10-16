//! Config loader tests.

const std = @import("std");
const theme_mod = @import("ui").theme;
const Theme = theme_mod.Theme;
const keybinds = @import("keybinds.zig");
const Action = keybinds.Action;
const default_file = @import("default.zig");
const types = @import("types.zig");
const window_rules = @import("window_rules.zig");
const sandbox_allow = @import("sandbox_allow.zig");
const anim = @import("ui").anim;
const output_transform = @import("output_transform.zig");
const schedule_mod = @import("schedule.zig");
const ScheduleMode = schedule_mod.ScheduleMode;
const NightLightConfig = schedule_mod.NightLightConfig;
const AccelProfile = types.AccelProfile;
const PanModifier = types.PanModifier;
const spliceSection = @import("loader_edit.zig").spliceSection;
const output_rules = @import("loader_fields.zig").output_rules;
const fieldHint = @import("loader_fields.zig").fieldHint;
const applyInputKey = @import("loader_fields.zig").applyInputKey;
const applyCompositorKey = @import("loader_fields.zig").applyCompositorKey;
const applyIdleKey = @import("loader_fields.zig").applyIdleKey;
const inputEql = @import("loader_compare.zig").inputEql;
const themeEql = @import("loader_compare.zig").themeEql;
const default_zoom_percents = @import("loader.zig").default_zoom_percents;
const InputConfig = @import("loader.zig").InputConfig;
const CompositorConfig = @import("loader.zig").CompositorConfig;
const OutputConfig = @import("loader.zig").OutputConfig;
const IdleConfig = @import("loader.zig").IdleConfig;
const desktopEnabled = @import("loader.zig").desktopEnabled;
const isDesktopClient = @import("loader.zig").isDesktopClient;
const default = @import("loader.zig").default;
const loadFromBytes = @import("loader.zig").loadFromBytes;
const parse = @import("loader.zig").parse;

test "[taskbar_theme] holds only taskbar tokens and is rewritten without touching its neighbours" {
    const a = std.testing.allocator;
    var cfg = try parse(a, "[theme]\nwindow_fg = \"#102030\"\n[taskbar_theme]\ntaskbar_bg = \"#112233\"\nwindow_fg = \"#445566\"\naccent = \"#ff0000\"\nchip_gap = 30\n[input]\ntap_drag = false\n", "mem");
    defer cfg.deinit();
    const chosen = cfg.taskbar_theme.?;
    try std.testing.expectEqual(theme_mod.parseColor("#112233") catch unreachable, chosen.taskbar_bg);
    try std.testing.expectEqual(theme_mod.parseColor("#445566") catch unreachable, theme_mod.taskbarTokens(chosen).window_fg);
    // Neither the main theme nor the taskbar's other tokens move.
    try std.testing.expectEqual(theme_mod.parseColor("#102030") catch unreachable, cfg.theme.window_fg);
    try std.testing.expectEqual(@as(Theme, .{}).accent, chosen.accent);
    try std.testing.expectEqual(@as(Theme, .{}).chip_gap, chosen.chip_gap);
    // The header alone chooses a taskbar theme; no header means the main one.
    var bare = try parse(a, "[taskbar_theme]\n", "mem");
    defer bare.deinit();
    try std.testing.expect(bare.taskbar_theme != null);
    var none = try parse(a, "[theme]\n", "mem");
    defer none.deinit();
    try std.testing.expect(none.taskbar_theme == null);

    // What the writer saves reads back equal, and `[theme]` is not mistaken for it.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try theme_mod.writeTaskbarInto(a, &body, chosen);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try spliceSection(a, &out, "[theme]\nfont = \"X\"\n\n[input]\ntap_drag = false\n", "[taskbar_theme]", body.items);
    try std.testing.expectEqualStrings("[theme]\nfont = \"X\"\n\n[input]\ntap_drag = false\n[taskbar_theme]\ntaskbar_bg = \"rgba(17,34,51,1.000)\"\nwindow_fg = \"rgba(68,85,102,1.000)\"\n", out.items);
    var reread = try parse(a, out.items, "mem");
    defer reread.deinit();
    try std.testing.expect(theme_mod.taskbarOverrideEql(chosen, reread.taskbar_theme));
    try std.testing.expectEqualStrings("X", reread.theme.font);

    // Replacing it again keeps one copy and no extra blank lines; null removes it.
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(a);
    try spliceSection(a, &again, out.items, "[taskbar_theme]", "[taskbar_theme]\n");
    try std.testing.expectEqualStrings("[theme]\nfont = \"X\"\n\n[input]\ntap_drag = false\n[taskbar_theme]\n", again.items);
    var removed: std.ArrayList(u8) = .empty;
    defer removed.deinit(a);
    try spliceSection(a, &removed, out.items, "[taskbar_theme]", null);
    try std.testing.expectEqualStrings("[theme]\nfont = \"X\"\n\n[input]\ntap_drag = false\n", removed.items);
}

test "empty config keeps built-in zoom steps and default keybinds" {
    var cfg = try parse(std.testing.allocator, "", "mem");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 4), cfg.compositor.zoom_step_count);
    try std.testing.expectEqual(@as(u8, 100), cfg.compositor.zoom_percents[0]);
    try std.testing.expect(cfg.autostart.len == 0);
    try std.testing.expect(cfg.keybinds.len > 0);
    const spec = try keybinds.parseKeybind("super+t");
    const action = cfg.lookupKeybind(spec.modifiers, spec.sym) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("default-terminal", action.spawn);
}

test "the desktop follows its section, then a legacy rediwm-desktop autostart" {
    var empty = try parse(std.testing.allocator, "", "empty");
    defer empty.deinit();
    try std.testing.expect(!desktopEnabled(&empty));
    var legacy = try parse(std.testing.allocator, "[[autostart]]\ncmd = \"/usr/local/bin/rediwm-desktop --verbose\"\n", "legacy");
    defer legacy.deinit();
    try std.testing.expect(desktopEnabled(&legacy));
    var off = try parse(std.testing.allocator, "[[autostart]]\ncmd = \"rediwm-desktop\"\n[desktop]\nenabled = false\n", "off");
    defer off.deinit();
    try std.testing.expect(!desktopEnabled(&off));
    try std.testing.expect(!isDesktopClient("rediwm-desktop-helper"));
}

test "documented default parses all sections" {
    var cfg = try parse(std.testing.allocator, default_file.source, "default");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 5), cfg.compositor.zoom_step_count);
    try std.testing.expectEqual(@as(u8, 40), cfg.compositor.zoom_percents[4]);
    try std.testing.expectEqual(@as(usize, 0), cfg.autostart.len);
    try std.testing.expect(desktopEnabled(&cfg));
    try std.testing.expect(cfg.input.natural_scroll);
    try std.testing.expectEqual(@as(u32, 400), cfg.input.key_repeat_delay);
    try std.testing.expectEqual(AccelProfile.bezier, cfg.input.accel_profile);
    try std.testing.expectEqual([2]f32{ 0.0, 0.0 }, cfg.input.accel_p1);
    try std.testing.expectEqual([2]f32{ 0.15, 1.0 }, cfg.input.accel_p2);
    try std.testing.expectEqual(@as(f32, 10.0), cfg.input.accel_max_speed);
    try std.testing.expectEqual(@as(u32, 10), cfg.compositor.border_radius);
    try std.testing.expect(cfg.compositor.xwayland);
    try std.testing.expectEqualStrings("Manrope", cfg.theme.font);

    const q = try keybinds.parseKeybind("super+q");
    try std.testing.expectEqual(Action.close_window, cfg.lookupKeybind(q.modifiers, q.sym).?);

    const depth = try keybinds.parseKeybind("super+3");
    try std.testing.expectEqual(@as(u8, 2), cfg.lookupKeybind(depth.modifiers, depth.sym).?.set_depth);
}

test "syntax error returns InvalidConfig" {
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[input]
        \\pointer_speed = 4.0
    , "bad"));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[keybinds]
        \\"super+t" = "nope"
    , "bad"));
}

test "xwayland config defaults on and can be disabled" {
    var on = try parse(std.testing.allocator, "", "mem");
    defer on.deinit();
    try std.testing.expect(on.compositor.xwayland);

    var off = try parse(std.testing.allocator,
        \\[compositor]
        \\xwayland = false
    , "off");
    defer off.deinit();
    try std.testing.expect(!off.compositor.xwayland);
}

test "inline comments do not break values" {
    var cfg = try parse(std.testing.allocator,
        \\[input]
        \\pointer_speed = 0.5  # comment
        \\natural_scroll = false
    , "comments");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), cfg.input.pointer_speed);
    try std.testing.expect(!cfg.input.natural_scroll);
}

test "accel config parses bezier and flat sections" {
    var bezier_cfg = try parse(std.testing.allocator,
        \\[input]
        \\accel_profile = "bezier"
        \\accel_p1 = [0.1, 0.2]
        \\accel_p2 = [0.3, 0.9]
        \\accel_max_speed = 15.0
    , "bezier");
    defer bezier_cfg.deinit();
    try std.testing.expectEqual(AccelProfile.bezier, bezier_cfg.input.accel_profile);
    try std.testing.expectEqual([2]f32{ 0.1, 0.2 }, bezier_cfg.input.accel_p1);
    try std.testing.expectEqual([2]f32{ 0.3, 0.9 }, bezier_cfg.input.accel_p2);
    try std.testing.expectEqual(@as(f32, 15.0), bezier_cfg.input.accel_max_speed);

    var flat_cfg = try parse(std.testing.allocator,
        \\[input]
        \\accel_profile = "flat"
    , "flat");
    defer flat_cfg.deinit();
    try std.testing.expectEqual(AccelProfile.flat, flat_cfg.input.accel_profile);
}

test "idle config parsing and validation" {
    var def = try parse(std.testing.allocator, "", "mem");
    defer def.deinit();
    try std.testing.expectEqual(@as(?bool, null), def.idle.enabled);
    try std.testing.expectEqual(@as(u32, 600), def.idle.blank_after_seconds);
    try std.testing.expectEqual(@as(u32, 0), def.idle.suspend_after_seconds);

    var custom = try parse(std.testing.allocator,
        \\[idle]
        \\enabled = true
        \\blank_after_seconds = 300
        \\suspend_after_seconds = 600
    , "custom");
    defer custom.deinit();
    try std.testing.expectEqual(@as(?bool, true), custom.idle.enabled);
    try std.testing.expectEqual(@as(u32, 300), custom.idle.blank_after_seconds);
    try std.testing.expectEqual(@as(u32, 600), custom.idle.suspend_after_seconds);

    // Validation: suspend must be strictly greater than blank when both are non-zero
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = 600
        \\suspend_after_seconds = 600
    , "equal"));

    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = 600
        \\suspend_after_seconds = 300
    , "less"));

    // Negative values fail parsing
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = -1
    , "negative"));
}

test "input and theme reload detect every field and compare strings by content" {
    const original_theme = Theme{};
    inline for (std.meta.fields(Theme)) |field| {
        var changed = original_theme;
        @field(changed, field.name) = switch (field.type) {
            bool => !@field(original_theme, field.name),
            f32 => @field(original_theme, field.name) + 1,
            []const u8 => "another theme",
            [4]f32 => .{ 0.1, 0.2, 0.3, 0.4 },
            ?[4]f32 => .{ 0.1, 0.2, 0.3, 0.4 },
            else => @compileError("add a theme change fixture for " ++ field.name),
        };
        try std.testing.expect(!themeEql(original_theme, changed));
        try std.testing.expect(!themeEql(changed, original_theme));
    }
    var theme_copy = original_theme;
    theme_copy.font = try std.testing.allocator.dupe(u8, original_theme.font);
    defer std.testing.allocator.free(theme_copy.font);
    try std.testing.expect(themeEql(original_theme, theme_copy));
    const original = InputConfig{};
    inline for (std.meta.fields(InputConfig)) |field| {
        var changed = original;
        @field(changed, field.name) = switch (field.type) {
            bool => !@field(original, field.name),
            f32, u32 => @field(original, field.name) + 1,
            []const u8 => "another theme",
            []const []const u8 => if (@field(original, field.name).len == 0) &.{"another"} else &.{},
            AccelProfile => switch (@field(original, field.name)) {
                .bezier => .flat,
                .flat => .bezier,
            },
            PanModifier => switch (@field(original, field.name)) {
                .super => .super_alt,
                .super_alt => .super,
            },
            [2]f32 => .{ @field(original, field.name)[0] + 0.1, @field(original, field.name)[1] + 0.1 },
            else => @compileError("add an input change fixture for " ++ field.name),
        };
        try std.testing.expect(!inputEql(original, changed));
        try std.testing.expect(!inputEql(changed, original));
    }
    var copy = original;
    copy.cursor_theme = try std.testing.allocator.dupe(u8, original.cursor_theme);
    defer std.testing.allocator.free(copy.cursor_theme);
    try std.testing.expect(inputEql(original, copy));
}

test "config field parsing preserves ranges and derived zoom state" {
    var input = InputConfig{};
    const a = std.testing.allocator;
    inline for (.{
        .{ "key_repeat_delay", "1", "5000", "0", "5001" },
        .{ "key_repeat_rate", "1", "200", "0", "201" },
        .{ "cursor_size", "1", "256", "0", "257" },
    }) |fixture| {
        try applyInputKey(&input, a, fixture[0], fixture[1]);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, fixture[1], 10), @field(input, fixture[0]));
        try applyInputKey(&input, a, fixture[0], fixture[2]);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, fixture[2], 10), @field(input, fixture[0]));
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, fixture[0], fixture[3]));
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, fixture[0], fixture[4]));
    }
    try applyInputKey(&input, a, "pointer_speed", "-1");
    try std.testing.expectEqual(@as(f32, -1), input.pointer_speed);
    try applyInputKey(&input, a, "pointer_speed", "1");
    try std.testing.expectEqual(@as(f32, 1), input.pointer_speed);
    try applyInputKey(&input, a, "pointer_speed_touchpad", "-1");
    try std.testing.expectEqual(@as(f32, -1), input.pointer_speed_touchpad);
    try applyInputKey(&input, a, "pointer_speed_touchpad", "1");
    try std.testing.expectEqual(@as(f32, 1), input.pointer_speed_touchpad);
    try applyInputKey(&input, a, "disable_while_typing_touchpad", "true");
    try std.testing.expect(input.disable_while_typing_touchpad);
    try applyInputKey(&input, a, "disable_while_typing_touchpad", "false");
    try std.testing.expect(!input.disable_while_typing_touchpad);
    inline for (.{ "-1.01", "1.01", "nan", "inf" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "pointer_speed", v));
    }
    inline for (.{ "-1.01", "1.01", "nan", "inf" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "pointer_speed_touchpad", v));
    }
    inline for (.{ "natural_scroll", "invert_scroll", "tap_to_click", "tap_drag", "disable_while_typing" }) |key| {
        try applyInputKey(&input, a, key, "false");
        try std.testing.expect(!@field(input, key));
        try applyInputKey(&input, a, key, "true");
        try std.testing.expect(@field(input, key));
    }
    try applyInputKey(&input, a, "cursor_theme", "\"custom\"");
    defer a.free(input.cursor_theme);
    try std.testing.expectEqualStrings("custom", input.cursor_theme);

    try applyInputKey(&input, a, "accel_profile", "\"flat\"");
    try std.testing.expectEqual(AccelProfile.flat, input.accel_profile);
    try applyInputKey(&input, a, "accel_profile", "bezier");
    try std.testing.expectEqual(AccelProfile.bezier, input.accel_profile);
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_profile", "\"nope\""));

    try applyInputKey(&input, a, "accel_p1", "[0.0, 0.0]");
    try std.testing.expectEqual([2]f32{ 0.0, 0.0 }, input.accel_p1);
    try applyInputKey(&input, a, "accel_p2", "[ 0.15 , 1.0 ]");
    try std.testing.expectEqual([2]f32{ 0.15, 1.0 }, input.accel_p2);
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[-0.1, 0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[1.1, 0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[0.0, 0.0, 0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "bad"));

    try applyInputKey(&input, a, "accel_max_speed", "10.0");
    try std.testing.expectEqual(@as(f32, 10.0), input.accel_max_speed);
    try applyInputKey(&input, a, "accel_max_speed", "25.5");
    try std.testing.expectEqual(@as(f32, 25.5), input.accel_max_speed);
    inline for (.{ "0", "-1", "nan", "inf" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_max_speed", v));
    }

    var c = CompositorConfig{};
    try std.testing.expectEqual(types.DockPosition.bottom, c.dock_position);
    inline for (.{ "top", "bottom", "left", "right" }) |value| {
        try applyCompositorKey(&c, a, "dock_position", value);
        try std.testing.expectEqual(std.meta.stringToEnum(types.DockPosition, value).?, c.dock_position);
    }
    try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "dock_position", "center"));
    try std.testing.expectEqual(@as(u32, 0), c.windowGap());
    c.desktop_mode = .workspaces;
    try std.testing.expectEqual(@as(u32, 8), c.windowGap());
    try applyCompositorKey(&c, a, "window_gap", "0");
    try std.testing.expectEqual(@as(u32, 0), c.windowGap());
    c.desktop_mode = .canvas;
    inline for (.{
        .{ "canvas_width", "1", "100000", "0", "100001" },
        .{ "canvas_height", "1", "100000", "0", "100001" },
        .{ "window_gap", "0", "512", "513", "514" },
        .{ "border_radius", "0", "128", "129", "130" },
        .{ "dock_height", "48", "96", "47", "97" },
    }) |fixture| {
        try applyCompositorKey(&c, a, fixture[0], fixture[1]);
        try std.testing.expectEqual(@as(@TypeOf(@field(c, fixture[0])), try std.fmt.parseInt(u32, fixture[1], 10)), @field(c, fixture[0]));
        try applyCompositorKey(&c, a, fixture[0], fixture[2]);
        try std.testing.expectEqual(@as(@TypeOf(@field(c, fixture[0])), try std.fmt.parseInt(u32, fixture[2], 10)), @field(c, fixture[0]));
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, fixture[0], fixture[3]));
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, fixture[0], fixture[4]));
    }
    inline for (.{ "1", "1.05", "1.5" }) |value| {
        try applyCompositorKey(&c, a, "dock_hover_zoom", value);
        try std.testing.expectEqual(try std.fmt.parseFloat(f32, value), c.dock_hover_zoom);
    }
    inline for (.{ "nan", "inf", "0.99", "1.51" }) |value| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "dock_hover_zoom", value));
    }
    inline for (.{ "camera_zoom_min", "camera_zoom_max", "inactive_opacity" }) |key| {
        try applyCompositorKey(&c, a, key, "0.5");
        try std.testing.expectEqual(@as(f32, 0.5), @field(c, key));
        inline for (.{ "nan", "inf", "-0.1", "8.1" }) |v| {
            try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, key, v));
        }
    }
    inline for (.{ "camera_zoom_min", "camera_zoom_max" }) |key| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, key, "0"));
        try applyCompositorKey(&c, a, key, "8");
        try std.testing.expectEqual(@as(f32, 8), @field(c, key));
    }
    try applyCompositorKey(&c, a, "inactive_opacity", "0");
    try std.testing.expectEqual(@as(f32, 0), c.inactive_opacity);
    try applyCompositorKey(&c, a, "inactive_opacity", "1");
    try std.testing.expectEqual(@as(f32, 1), c.inactive_opacity);
    try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "inactive_opacity", "1.01"));
    try std.testing.expectEqual(@as(?f32, null), c.terminal_opacity);
    try applyCompositorKey(&c, a, "terminal_opacity", "0.85");
    try std.testing.expectEqual(@as(?f32, 0.85), c.terminal_opacity);
    inline for (.{ "nan", "-0.1", "1.01" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "terminal_opacity", v));
    }
    try std.testing.expectEqual(@as(?f32, null), c.dock_opacity);
    try std.testing.expect(!c.dock_active_highlight);
    try applyCompositorKey(&c, a, "dock_opacity", "0.6");
    try std.testing.expectEqual(@as(?f32, 0.6), c.dock_opacity);
    inline for (.{ "nan", "-0.1", "1.01" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "dock_opacity", v));
    }
    try applyCompositorKey(&c, a, "dock_active_highlight", "true");
    try std.testing.expect(c.dock_active_highlight);
    try std.testing.expect(c.inactive_dim);
    try std.testing.expectEqual(@as(f32, 0.08), c.inactive_dim_amount);
    try applyCompositorKey(&c, a, "inactive_dim", "false");
    try std.testing.expect(!c.inactive_dim);
    try applyCompositorKey(&c, a, "inactive_dim_amount", "0.5");
    try std.testing.expectEqual(@as(f32, 0.5), c.inactive_dim_amount);
    inline for (.{ "nan", "inf", "-0.1", "0.51" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "inactive_dim_amount", v));
    }
    try applyCompositorKey(&c, a, "focus_follows_mouse", "true");
    try std.testing.expect(c.focus_follows_mouse);
    try applyCompositorKey(&c, a, "xwayland", "false");
    try std.testing.expect(!c.xwayland);
    try applyCompositorKey(&c, a, "zoom_steps", "[1, 0.75]");
    try std.testing.expectEqual(@as(u8, 2), c.zoom_step_count);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0.75 }, c.zoom_steps[0..2]);
    try applyCompositorKey(&c, a, "zoom_step_count", "7");
    try applyCompositorKey(&c, a, "zoom_percents", "[20]");
    try std.testing.expectEqual(@as(u8, 2), c.zoom_step_count);
    try std.testing.expectEqualSlices(u8, &default_zoom_percents, c.zoom_percents);
    try applyInputKey(&input, a, "unknown", "ignored");
    try applyCompositorKey(&c, a, "unknown", "ignored");
}

test "idle field rules preserve optional enabled and strict unknown keys" {
    const a = std.testing.allocator;
    var idle = IdleConfig{};
    try std.testing.expectEqual(@as(?bool, null), idle.enabled);
    try applyIdleKey(&idle, a, "enabled", "false");
    try std.testing.expectEqual(@as(?bool, false), idle.enabled);
    try applyIdleKey(&idle, a, "enabled", "true");
    try std.testing.expectEqual(@as(?bool, true), idle.enabled);
    try std.testing.expectError(error.InvalidValue, applyIdleKey(&idle, a, "enabled", "null"));
    inline for (.{ "blank_after_seconds", "suspend_after_seconds" }) |key| {
        try applyIdleKey(&idle, a, key, "0");
        try std.testing.expectEqual(@as(u32, 0), @field(idle, key));
        try applyIdleKey(&idle, a, key, "4294967295");
        try std.testing.expectEqual(std.math.maxInt(u32), @field(idle, key));
        try std.testing.expectError(error.Overflow, applyIdleKey(&idle, a, key, "4294967296"));
    }
    try std.testing.expectError(error.InvalidField, applyIdleKey(&idle, a, "unknown", "ignored"));
}

test "window_rules TOML parsing and validation" {
    const toml =
        \\[[window_rules]]
        \\app_id = "org.telegram.desktop"
        \\exclude_title = "Media viewer"
        \\output = "DP-2"
        \\center = true
        \\width = 900
        \\height = 700
        \\
        \\[[window_rules]]
        \\app_id = ["firefox", "chromium"]
        \\title = "Picture-in-Picture"
        \\opacity = 0.9
        \\skip_taskbar = true
        \\focus = false
        \\
        \\[[window_rules]]
        \\x11_class = "Steam"
        \\dialog = false
        \\maximized = true
        \\
        \\[[window_rules]]
        \\app_id = "foot"
        \\decorations = "client"
    ;

    var cfg = try parse(std.testing.allocator, toml, "rules_test");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 4), cfg.window_rules.len);

    const r0 = cfg.window_rules[0];
    try std.testing.expectEqualStrings("org.telegram.desktop", r0.app_id.?[0]);
    try std.testing.expectEqualStrings("Media viewer", r0.exclude_title.?[0]);
    try std.testing.expectEqualStrings("DP-2", r0.output.?);
    try std.testing.expectEqual(@as(?bool, true), r0.center);
    try std.testing.expectEqual(@as(?u32, 900), r0.width);
    try std.testing.expectEqual(@as(?u32, 700), r0.height);

    const r1 = cfg.window_rules[1];
    try std.testing.expectEqual(@as(usize, 2), r1.app_id.?.len);
    try std.testing.expectEqualStrings("firefox", r1.app_id.?[0]);
    try std.testing.expectEqualStrings("chromium", r1.app_id.?[1]);
    try std.testing.expectEqualStrings("Picture-in-Picture", r1.title.?[0]);
    try std.testing.expectEqual(@as(?f32, 0.9), r1.opacity);
    try std.testing.expectEqual(@as(?bool, true), r1.skip_taskbar);
    try std.testing.expectEqual(@as(?bool, false), r1.focus);

    const r2 = cfg.window_rules[2];
    try std.testing.expectEqualStrings("Steam", r2.x11_class.?[0]);
    try std.testing.expectEqual(@as(?bool, false), r2.dialog);
    try std.testing.expectEqual(@as(?bool, true), r2.maximized);

    const r3 = cfg.window_rules[3];
    try std.testing.expectEqualStrings("foot", r3.app_id.?[0]);
    try std.testing.expectEqual(window_rules.DecorationMode.client, r3.decorations.?);

    // Conflict error in TOML
    const bad_toml =
        \\[[window_rules]]
        \\center = true
        \\x = 100
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, bad_toml, "bad_rule"));

    // Unknown field error
    const bad_key =
        \\[[window_rules]]
        \\unknown_field = "value"
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, bad_key, "bad_key"));
}

test "existing configs inherit laptop controls and can override or disable them" {
    var cfg = try parse(std.testing.allocator,
        \\[keybinds]
        \\"super+t" = "spawn foot"
        \\"XF86AudioMute" = "noop"
    , "hardware");
    defer cfg.deinit();
    const up = try keybinds.parseKeybind("XF86AudioRaiseVolume");
    try std.testing.expectEqual(Action.volume_up, cfg.lookupKeybind(up.modifiers, up.sym).?);
    const mute = try keybinds.parseKeybind("XF86AudioMute");
    try std.testing.expectEqual(Action.noop, cfg.lookupKeybind(mute.modifiers, mute.sym).?);
}

test "night_light config parsing and defaults" {
    var def = try default(std.testing.allocator);
    defer def.deinit();

    try std.testing.expectEqual(true, def.night_light.enabled);
    try std.testing.expectEqual(ScheduleMode.always, def.night_light.schedule);
    try std.testing.expectEqual(@as(u32, 5000), def.night_light.temperature);
    try std.testing.expectEqual(@as(u32, 6500), def.night_light.day_temperature);
    try std.testing.expectEqual(@as(u16, 21 * 60), def.night_light.start);
    try std.testing.expectEqual(@as(u16, 7 * 60), def.night_light.end);
    try std.testing.expectEqual(@as(u16, 30), def.night_light.transition_minutes);
    try std.testing.expectEqual(@as(?f64, null), def.night_light.latitude);
    try std.testing.expectEqual(@as(?f64, null), def.night_light.longitude);

    // Snapshot survives deinit (holds only scalars)
    var snapshot: NightLightConfig = undefined;
    {
        var custom = try parse(std.testing.allocator,
            \\[night_light]
            \\enabled = true
            \\schedule = "fixed"
            \\temperature = 3400
            \\day_temperature = 6000
            \\start = "22:00"
            \\end = "06:30"
            \\transition_minutes = 45
            \\
            \\[[outputs]]
            \\name = "DP-2"
            \\night_light = false
            \\gamma = 1.2
        , "custom");
        snapshot = custom.night_light;
        try std.testing.expectEqual(true, custom.outputs[0].night_light == false);
        try std.testing.expectApproxEqAbs(@as(f32, 1.2), custom.outputs[0].gamma, 0.001);
        custom.deinit();
    }
    try std.testing.expectEqual(true, snapshot.enabled);
    try std.testing.expectEqual(ScheduleMode.fixed, snapshot.schedule);
    try std.testing.expectEqual(@as(u32, 3400), snapshot.temperature);
    try std.testing.expectEqual(@as(u32, 6000), snapshot.day_temperature);
    try std.testing.expectEqual(@as(u16, 22 * 60), snapshot.start);
    try std.testing.expectEqual(@as(u16, 6 * 60 + 30), snapshot.end);
    try std.testing.expectEqual(@as(u16, 45), snapshot.transition_minutes);
}

test "output policy parses enabled and unique primary" {
    var cfg = try parse(std.testing.allocator,
        \\[[outputs]]
        \\name = "DP-1"
        \\primary = true
        \\enabled = false
        \\
        \\[[outputs]]
        \\name = "DP-2"
    , "output_policy");
    defer cfg.deinit();
    try std.testing.expectEqual(false, cfg.outputs[0].enabled);
    try std.testing.expectEqual(true, cfg.outputs[0].primary);
    try std.testing.expectEqual(true, cfg.outputs[1].enabled);
    try std.testing.expectEqual(false, cfg.outputs[1].primary);

    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[[outputs]]
        \\name = "DP-1"
        \\primary = true
        \\
        \\[[outputs]]
        \\name = "DP-2"
        \\primary = true
    , "ambiguous_primary"));
}

test "outputs fields parse through the rule table" {
    const a = std.testing.allocator;
    var cfg = try parse(a,
        \\[[outputs]]
        \\name = "DP-1"
        \\width = 2560
        \\height = 1440
        \\refresh_mhz = 144000
        \\x = -2560
        \\y = 0
        \\scale = 1.33
        \\transform = "flipped_90"
        \\night_light = false
        \\gamma = 1.2
        \\
        \\[[outputs]]
        \\name = "DP-2"
        \\scale = "auto"
    , "outputs_fields");
    defer cfg.deinit();
    const o = cfg.outputs[0];
    try std.testing.expectEqualStrings("DP-1", o.name);
    try std.testing.expectEqual(@as(?i32, 2560), o.width);
    try std.testing.expectEqual(@as(?i32, 1440), o.height);
    try std.testing.expectEqual(@as(?i32, 144000), o.refresh_mhz);
    try std.testing.expectEqual(@as(?i32, -2560), o.x);
    try std.testing.expectEqual(@as(?i32, 0), o.y);
    try std.testing.expectEqual(@as(?f32, 160.0 / 120.0), o.scale);
    try std.testing.expectEqual(output_transform.Transform.flipped_90, o.transform);
    try std.testing.expectEqual(false, o.night_light);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), o.gamma, 0.001);
    try std.testing.expectEqual(@as(?f32, null), cfg.outputs[1].scale);

    inline for (.{
        "width = 0",       "height = -1",        "refresh_mhz = 1.5", "x = 1.5",
        "scale = 0.9",     "scale = 3.1",        "scale = \"nan\"",   "scale = auto",
        "transform = 45",  "transform = \"45\"", "enabled = 1",       "name = DP-1",
        "unknown_key = 1",
    }) |line| {
        try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\n" ++ line ++ "\n", "err"));
    }
    try std.testing.expectEqualStrings("a positive integer", fieldHint(OutputConfig, output_rules, "width"));
    try std.testing.expectEqualStrings("an integer", fieldHint(OutputConfig, output_rules, "x"));
    try std.testing.expectEqualStrings("a number between 0.5 and 2", fieldHint(OutputConfig, output_rules, "gamma"));
}

test "night_light sun and always schedules" {
    var sun_cfg = try parse(std.testing.allocator,
        \\[night_light]
        \\enabled = true
        \\schedule = "sun"
        \\latitude = 51.51
        \\longitude = -0.13
    , "sun");
    defer sun_cfg.deinit();
    try std.testing.expectEqual(ScheduleMode.sun, sun_cfg.night_light.schedule);
    try std.testing.expectApproxEqAbs(@as(f64, 51.51), sun_cfg.night_light.latitude.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -0.13), sun_cfg.night_light.longitude.?, 0.001);

    var always_cfg = try parse(std.testing.allocator,
        \\[night_light]
        \\enabled = true
        \\schedule = "always"
        \\temperature = 2700
    , "always");
    defer always_cfg.deinit();
    try std.testing.expectEqual(ScheduleMode.always, always_cfg.night_light.schedule);
    try std.testing.expectEqual(@as(u32, 2700), always_cfg.night_light.temperature);
}

test "night_light validation errors" {
    const a = std.testing.allocator;

    // Unknown field
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nunknown = 1\n", "err"));

    // Temperature outside 1700-10000
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\ntemperature = 1600\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\ntemperature = 10500\n", "err"));

    // Day temperature outside 1700-10000
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nday_temperature = 1500\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nday_temperature = 11000\n", "err"));

    // Start equals end
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nstart = \"08:00\"\nend = \"08:00\"\n", "err"));

    // Transition minutes > 180
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\ntransition_minutes = 200\n", "err"));

    // Transition minutes not shorter than night or day span (e.g. night span 30m, transition 30m)
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nstart = \"23:00\"\nend = \"23:30\"\ntransition_minutes = 30\n", "err"));

    // Sun schedule missing coordinates
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\nlatitude = 50.0\n", "err"));

    // Sun schedule coordinates out of range
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\nlatitude = 95.0\nlongitude = 0.0\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\nlatitude = 0.0\nlongitude = -190.0\n", "err"));

    // Output gamma outside 0.5-2.0 or not finite
    try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\nname = \"DP-1\"\ngamma = 0.4\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\nname = \"DP-1\"\ngamma = 2.5\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\nname = \"DP-1\"\ngamma = \"nan\"\n", "err"));
}

test "animations config defaults and overlay" {
    var empty = try parse(std.testing.allocator, "", "mem");
    defer empty.deinit();
    try std.testing.expect(empty.animations.enabled);
    try std.testing.expectEqual(@as(f32, 1.0), empty.animations.speed);
    try std.testing.expectEqual(anim.ReducedMotion.auto, empty.animations.reduced_motion);
    const panel = empty.animations.targets[@intFromEnum(anim.Target.panel_slide)];
    try std.testing.expectEqual(anim.springs.panel_slide.stiffness, panel.curve.spring.stiffness);

    var cfg = try parse(std.testing.allocator,
        \\[animations]
        \\enabled = true
        \\speed = 0.5
        \\reduced_motion = "on"
        \\
        \\[animations.panel_slide]
        \\spring = { damping_ratio = 0.9, stiffness = 400, epsilon = 0.001 }
        \\
        \\[animations.taskbar_press]
        \\duration_ms = 120
        \\ease = "flip_bezier"
        \\
        \\[animations.camera_pan]
        \\spring = { damping_ratio = 1.0, stiffness = 300 }
        \\decay_rate = 0.99
        \\
        \\[animations.window_open]
        \\off = true
    , "anim");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), cfg.animations.speed);
    try std.testing.expectEqual(anim.ReducedMotion.on, cfg.animations.reduced_motion);
    const slide = cfg.animations.targets[@intFromEnum(anim.Target.panel_slide)].curve.spring;
    try std.testing.expectEqual(@as(f32, 0.9), slide.damping_ratio);
    try std.testing.expectEqual(@as(f32, 400), slide.stiffness);
    try std.testing.expectEqual(@as(f32, 0.001), slide.epsilon);
    const press = cfg.animations.targets[@intFromEnum(anim.Target.taskbar_press)].curve.duration;
    try std.testing.expectEqual(@as(i64, 120), press.ms);
    try std.testing.expectEqual(anim.Ease.flip_bezier, press.ease);
    const pan = cfg.animations.targets[@intFromEnum(anim.Target.camera_pan)];
    try std.testing.expectEqual(@as(f32, 300), pan.curve.spring.stiffness);
    try std.testing.expectEqual(@as(f32, 0.5), pan.curve.spring.epsilon);
    try std.testing.expectEqual(@as(f32, 0.99), pan.decay.rate);
    try std.testing.expect(cfg.animations.targets[@intFromEnum(anim.Target.window_open)].curve == .off);
}

test "animations config rejects unknown targets and illegal combinations" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.window_opne]\nspring = { stiffness = 800 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations]\nspeed = -1\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations]\nreduced_motion = \"maybe\"\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.panel_slide]\nspring = { damping_ratio = 1.0, stiffness = 900 }\nduration_ms = 90\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.panel_slide]\noff = true\nspring = { stiffness = 800 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.panel_slide]\nspring = { wobble = 1 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.camera_pan]\nspring = { damping_ratio = 1.0, stiffness = 500, epsilon = 0.0001 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations]\nunknown = true\n", "err"));
}

test "documented default still parses with commented animations block" {
    var cfg = try parse(std.testing.allocator, default_file.source, "default");
    defer cfg.deinit();
    try std.testing.expect(cfg.animations.enabled);
    try std.testing.expectEqual(anim.ReducedMotion.auto, cfg.animations.reduced_motion);
}

test "polkit defaults and strict configuration validation" {
    var defaults_cfg = try parse(std.testing.allocator, "", "polkit-defaults");
    defer defaults_cfg.deinit();
    try std.testing.expect(defaults_cfg.polkit.enable);
    try std.testing.expectEqualStrings("/run/polkit/agent-helper.socket", defaults_cfg.polkit.helper_socket);
    var custom = try parse(std.testing.allocator, "[polkit]\nenable = false\nhelper_socket = \"/tmp/test-helper\"\n", "polkit-custom");
    defer custom.deinit();
    try std.testing.expect(!custom.polkit.enable);
    try std.testing.expectEqualStrings("/tmp/test-helper", custom.polkit.helper_socket);
    for ([_][]const u8{ "enable = 1", "enabled = true", "helper_socket = \"\"", "helper_socket = \"relative/path\"", "unknown = false" }) |line| {
        const content = try std.fmt.allocPrint(std.testing.allocator, "[polkit]\n{s}\n", .{line});
        defer std.testing.allocator.free(content);
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, content, "polkit-invalid"));
    }
    const long_path = "[polkit]\nhelper_socket = \"/" ++ ("a" ** 107) ++ "\"\n";
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, long_path, "polkit-overlong"));
}

test "canvas screen counts default to three and reject values outside one to ten" {
    const a = std.testing.allocator;
    var defaults = try parse(a, "", "mem");
    defer defaults.deinit();
    try std.testing.expectEqual(@as(u32, 3), defaults.compositor.canvas_columns);
    try std.testing.expectEqual(@as(u32, 3), defaults.compositor.canvas_rows);
    var rectangular = try parse(a, "[compositor]\ncanvas_columns = 10\ncanvas_rows = 1\n", "mem");
    defer rectangular.deinit();
    try std.testing.expectEqual(@as(u32, 10), rectangular.compositor.canvas_columns);
    try std.testing.expectEqual(@as(u32, 1), rectangular.compositor.canvas_rows);
    inline for (.{ "canvas_columns", "canvas_rows" }) |key| {
        inline for (.{ "0", "11", "-1", "1.5" }) |value| {
            try std.testing.expectError(error.InvalidConfig, parse(a, "[compositor]\n" ++ key ++ " = " ++ value ++ "\n", "err"));
        }
    }
}

test "desktop switch duration sets the camera_desktop curve unless animations override it" {
    const a = std.testing.allocator;
    const idx = @intFromEnum(anim.Target.camera_desktop);
    var defaults = try parse(a, "", "mem");
    defer defaults.deinit();
    try std.testing.expectEqual(anim.desktopSwitchCurve(anim.default_desktop_switch_ms), defaults.animations.targets[idx].curve);
    var slow = try parse(a, "[compositor]\ndesktop_switch_ms = 1500\n", "mem");
    defer slow.deinit();
    try std.testing.expectEqual(anim.desktopSwitchCurve(1500), slow.animations.targets[idx].curve);
    var explicit = try parse(a, "[compositor]\ndesktop_switch_ms = 1500\n[animations.camera_desktop]\nduration_ms = 300\n", "mem");
    defer explicit.deinit();
    try std.testing.expectEqual(@as(i64, 300), explicit.animations.targets[idx].curve.duration.ms);
    inline for (.{ "99", "3001" }) |value| {
        try std.testing.expectError(error.InvalidConfig, parse(a, "[compositor]\ndesktop_switch_ms = " ++ value ++ "\n", "err"));
    }
}

test "input method environment validates supported names" {
    for ([_][]const u8{ "none", "fcitx", "ibus" }) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "[input_method]\nenv = \"{s}\"\n", .{name});
        defer std.testing.allocator.free(source);
        var cfg = try parse(std.testing.allocator, source, "ime-env");
        defer cfg.deinit();
        try std.testing.expectEqualStrings(name, @tagName(cfg.input_method.env));
    }
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[input_method]\nenv = \"unknown\"", "bad-ime-env"));
}

test "sandbox_allow TOML parsing and resolution" {
    const toml =
        \\[[sandbox_allow]]
        \\app_id = "com.obsproject.Studio"
        \\engine = "org.flatpak"
        \\allow = ["capture", "windows"]
        \\
        \\[[sandbox_allow]]
        \\app_id = "org.example.App"
        \\allow = ["clipboard", "unknown_group"]
    ;
    var cfg = try parse(std.testing.allocator, toml, "sandbox-test");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.sandbox_allow.len);

    const obs = cfg.sandboxAllowGroups("com.obsproject.Studio", "org.flatpak");
    try std.testing.expect(obs.contains(.capture));
    try std.testing.expect(obs.contains(.windows));
    try std.testing.expect(!obs.contains(.clipboard));

    const obs_wrong_engine = cfg.sandboxAllowGroups("com.obsproject.Studio", "other.engine");
    try std.testing.expect(obs_wrong_engine.count() == 0);

    const app = cfg.sandboxAllowGroups("org.example.App", "any.engine");
    try std.testing.expect(app.contains(.clipboard));
    try std.testing.expect(!app.contains(.capture));

    try std.testing.expect(cfg.sandboxAllowGroups(null, null).count() == 0);

    const bad_toml =
        \\[[sandbox_allow]]
        \\allow = ["clipboard"]
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, bad_toml, "bad-sandbox"));
}

test "mini map defaults and validated configuration" {
    const a = std.testing.allocator;
    var defaults = try parse(a, "", "mem");
    defer defaults.deinit();
    try std.testing.expect(defaults.compositor.mini_map_enabled);
    try std.testing.expectEqual(.bottom_right, defaults.compositor.mini_map_position);
    try std.testing.expectEqual(@as(u32, 1500), defaults.compositor.mini_map_hide_ms);
    var custom = try parse(a, "[compositor]\nmini_map_enabled = false\nmini_map_position = \"bottom_center\"\nmini_map_hide_ms = 2000\n", "mem");
    defer custom.deinit();
    try std.testing.expect(!custom.compositor.mini_map_enabled);
    try std.testing.expectEqual(.bottom_center, custom.compositor.mini_map_position);
    try std.testing.expectEqual(@as(u32, 2000), custom.compositor.mini_map_hide_ms);
    inline for (.{ "mini_map_position = \"top\"", "mini_map_hide_ms = 0", "mini_map_hide_ms = 10001", "mini_map_enabled = 1" }) |line| {
        try std.testing.expectError(error.InvalidConfig, parse(a, "[compositor]\n" ++ line ++ "\n", "invalid"));
    }
}

test "workspace preset is independent, overrides include noop, and mode preserves canvas bindings" {
    var cfg = try parse(std.testing.allocator, "[keybinds]\n\"Super+q\" = \"spawn custom-canvas\"\n" ++
        "[keybinds.workspace]\n\"Super+c\" = \"noop\"\n\"Super+F12\" = \"workspace 8\"\n", "test");
    defer cfg.deinit();
    const q = try keybinds.parseKeybind("Super+q");
    const c = try keybinds.parseKeybind("Super+c");
    const two = try keybinds.parseKeybind("Super+2");
    try std.testing.expectEqualStrings("custom-canvas", cfg.lookupKeybind(q.modifiers, q.sym).?.spawn);
    cfg.compositor.desktop_mode = .workspaces;
    try std.testing.expectEqualStrings("default-terminal", cfg.lookupKeybind(q.modifiers, q.sym).?.spawn);
    try std.testing.expectEqual(Action.noop, cfg.lookupKeybind(c.modifiers, c.sym).?);
    try std.testing.expectEqual(@as(u8, 2), cfg.lookupKeybind(two.modifiers, two.sym).?.workspace);
    const v = try keybinds.parseKeybind("Super+v");
    const rotate = try keybinds.parseKeybind("Super+j");
    const swap = try keybinds.parseKeybind("Super+Shift+Right");
    const split = try keybinds.parseKeybind("Super+Ctrl+Right");
    try std.testing.expectEqual(Action.toggle_floating, cfg.lookupKeybind(v.modifiers, v.sym).?);
    try std.testing.expectEqual(Action.toggle_split, cfg.lookupKeybind(rotate.modifiers, rotate.sym).?);
    try std.testing.expectEqual(Action.swap_right, cfg.lookupKeybind(swap.modifiers, swap.sym).?);
    try std.testing.expectEqual(Action.resize_split_right, cfg.lookupKeybind(split.modifiers, split.sym).?);
    cfg.compositor.desktop_mode = .canvas;
    try std.testing.expectEqual(@as(?Action, null), cfg.lookupKeybind(v.modifiers, v.sym));
    try std.testing.expectEqualStrings("custom-canvas", cfg.lookupKeybind(q.modifiers, q.sym).?.spawn);
    try std.testing.expectEqual(@as(?Action, null), cfg.lookupKeybind(two.modifiers, two.sym));
}

test "no base preserves legacy themes and embedded base layers config overrides" {
    const a = std.testing.allocator;
    const bytes = "[theme]\naccent = \"#123456\"\nfont_size = 14\n";
    var old = try parse(a, bytes, "legacy");
    defer old.deinit();
    var loaded = try loadFromBytes(a, bytes, "legacy", .empty, std.testing.io);
    defer loaded.deinit();
    try std.testing.expect(themeEql(old.theme, loaded.theme));
    var based = try loadFromBytes(a, "[theme]\nbase = \"rediwm-light\"\nfont_size = 14\n", "based", .empty, std.testing.io);
    defer based.deinit();
    try std.testing.expectEqualStrings("rediwm-light", based.theme_base);
    try std.testing.expectEqual(@as(f32, 14), based.theme.font_size);
    try std.testing.expect(themeEql(based.theme_defaults, based.theme_pack.?.tokens));
    try std.testing.expectEqual(based.theme_defaults.accent, based.theme.accent);

    var gold = try loadFromBytes(a, "[theme]\nbase = \"gold\"\n", "gold", .empty, std.testing.io);
    defer gold.deinit();
    try std.testing.expectEqual(.top, gold.compositor.taskbar_position);
    try std.testing.expect(gold.compositor.dock_enabled);
    try std.testing.expectEqual(@as(u32, 76), gold.compositor.dock_height);
    var customized = try loadFromBytes(a, "[theme]\nbase = \"gold\"\n[compositor]\ntaskbar_position = \"bottom\"\ndock_enabled = false\ndock_height = 52\n", "gold", .empty, std.testing.io);
    defer customized.deinit();
    try std.testing.expectEqual(.bottom, customized.compositor.taskbar_position);
    try std.testing.expect(!customized.compositor.dock_enabled);
    try std.testing.expectEqual(@as(u32, 52), customized.compositor.dock_height);
}

test "external overlay wins over a referenced pack without pinning inherited tokens" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", mem);
    const path = try std.fs.path.join(mem, &.{ root, "overlay.toml" });
    try tmp.dir.writeFile(io, .{ .sub_path = "overlay.toml", .data = "[theme]\nfont_size = 16\n" });
    const entry = try std.fmt.allocPrintSentinel(mem, "REDIWM_THEME={s}", .{path}, 0);
    const entries = [_:null]?[*:0]const u8{entry.ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = &entries } };
    var cfg = try loadFromBytes(a, "[theme]\nbase = \"rediwm-light\"\nfont_size = 14\n", "test", env, io);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 16), cfg.theme.font_size);
    try std.testing.expectEqual(@as(f32, 14), cfg.theme_config.font_size);
    var edited = cfg.theme;
    edited.font_size = 17;
    try theme_mod.saveOverlay(a, io, path, edited, cfg.theme_config);
    const saved = try tmp.dir.readFileAlloc(io, "overlay.toml", a, .limited(4096));
    defer a.free(saved);
    try std.testing.expectEqualStrings("[theme]\nfont_size = 17\n", saved);
}
