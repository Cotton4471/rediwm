//! Taskbar geometry from the theme: bar, chip, tile, tray and start button sizes.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const wlr = @import("wlroots");
const shape = @import("../taskbar/shape.zig");
const ui_theme = @import("ui").theme;
const chrome = @import("../chrome.zig");
const max_edge_gap = Taskbar.max_edge_gap;
const edge_pad = Taskbar.edge_pad;
const base_chip_size = Taskbar.base_chip_size;
const base_tile_size = Taskbar.base_tile_size;
const default_chip_vertical_margin = Taskbar.default_chip_vertical_margin;
const max_chip_vertical_margin = Taskbar.max_chip_vertical_margin;
const min_chip_size = Taskbar.min_chip_size;
const min_tile_size = Taskbar.min_tile_size;
const base_tray_hit = Taskbar.base_tray_hit;
const min_tray_hit = Taskbar.min_tray_hit;

pub fn barHeight() i32 {
    return @intFromFloat(@round(ui_theme.global.taskbar_size));
}

pub fn edgeGap() i32 {
    return @intFromFloat(@round(std.math.clamp(ui_theme.global.taskbar_edge_gap, 0, max_edge_gap)));
}

/// What the bar claims from its output edge: its height and its gap.
pub fn reservedHeight() i32 {
    return barHeight() + edgeGap();
}

/// What the theme's `taskbar_shape` means for items and pixels, worked out once
/// per change of the text, bar height or item margin: whether the bar is a
/// polygon and how far in its ends push the items. Reading it costs a hash of the
/// text, so it can sit in hit testing.
const PolygonInfo = struct { key: u64 = 0, active: bool = false, insets: shape.Insets = .{} };
var polygon_info: PolygonInfo = .{};

fn polygonInfo() PolygonInfo {
    const text = ui_theme.global.taskbar_shape;
    if (text.len == 0 or !chrome.shapes) return .{};
    const margin = chipVerticalMargin();
    const height = barHeight();
    const key = std.hash.Wyhash.hash(@as(u64, @bitCast(@as(i64, height))) ^ (@as(u64, @as(u32, @bitCast(margin))) << 32), text) | 1;
    if (polygon_info.key == key) return polygon_info;
    const h: f64 = @floatFromInt(height);
    const active = shape.polygon(text, 1600, h) != null and chrome.polygonsReady();
    polygon_info = .{
        .key = key,
        .active = active,
        .insets = if (active) shape.polygonInsets(text, h, margin, h - margin) else .{},
    };
    return polygon_info;
}

/// Whether the bar is drawn as the theme's polygon outline.
pub fn hasPolygon() bool {
    return polygonInfo().active;
}

pub fn barRadius() f32 {
    if (hasPolygon()) return 0;
    return shape.effectiveRadius(ui_theme.global.taskbar_radius, barHeight());
}

pub fn chipGap() i32 {
    return @intFromFloat(@round(ui_theme.global.chip_gap));
}

pub fn chipVerticalMargin() f32 {
    const margin_per_gap_px = default_chip_vertical_margin / 8.0; // original 8px gap anchor
    return @min(ui_theme.global.chip_gap * margin_per_gap_px, max_chip_vertical_margin);
}

pub fn chipSize() i32 {
    const raw = @as(f32, @floatFromInt(barHeight())) - 2 * chipVerticalMargin();
    return @max(min_chip_size, @as(i32, @intFromFloat(@round(raw))));
}

pub fn tileSize() i32 {
    const ratio = base_tile_size / @as(f32, @floatFromInt(base_chip_size));
    return @max(min_tile_size, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(chipSize())) * ratio))));
}

pub fn chipPad() i32 {
    return @divTrunc(chipSize() - tileSize(), 2);
}

pub fn trayHit() i32 {
    const ratio = @as(f32, @floatFromInt(base_tray_hit)) / @as(f32, @floatFromInt(base_chip_size));
    return @max(min_tray_hit, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(chipSize())) * ratio))));
}

// Same height as the chip row so the whole strip lines up.
pub fn buttonSize() i32 {
    return chipSize();
}

pub fn startButtonGap() i32 {
    return @intFromFloat(@round(ui_theme.global.start_button_gap));
}

pub fn startButtonLeft() i32 {
    return startButtonGap() + endInset(.left);
}

// Items keep clear of the curve at either end of a rounded bar, or of the slant
// of a polygon one.
pub fn endInset(end: enum { left, right }) i32 {
    const info = polygonInfo();
    if (info.active) return if (end == .left) info.insets.left else info.insets.right;
    return shape.cornerInset(barRadius(), chipVerticalMargin());
}

pub fn rightPad() i32 {
    return @max(edge_pad, endInset(.right) + startButtonGap());
}

pub fn startButtonBox(bar: *Taskbar) wlr.Box {
    const size = buttonSize();
    return .{
        .x = bar.box.x + bar.startX(),
        .y = bar.box.y + @divTrunc(bar.box.height - size, 2),
        .width = size,
        .height = size,
    };
}

/// Logical size the start button logo is drawn at.
pub fn startIconSize() i32 {
    const configured: i32 = @intFromFloat(@round(ui_theme.global.start_button_icon_size));
    return @max(8, @min(configured, buttonSize()));
}

pub fn firstChipX() i32 {
    return startButtonLeft() + buttonSize() + startButtonGap();
}
