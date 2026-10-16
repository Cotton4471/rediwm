//! Taskbar paint helpers: colours, fills and signed-distance shapes.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const chrome = @import("../chrome.zig");
const text = @import("ui").text;
const AppKind = Taskbar.AppKind;
const Color = Taskbar.Color;
const TileStyle = Taskbar.TileStyle;

pub fn hex(r: u8, g: u8, b: u8) Color {
    return .{ .r = @as(f32, @floatFromInt(r)) / 255.0, .g = @as(f32, @floatFromInt(g)) / 255.0, .b = @as(f32, @floatFromInt(b)) / 255.0, .a = 1 };
}

pub fn tileStyle(kind: AppKind) TileStyle {
    return switch (kind) {
        .file_explorer => .{ .fill = .{ .gradient = .{ .a = hex(0x22, 0xd3, 0xee), .b = hex(0x08, 0x91, 0xb2) } }, .hairline = false },
        .notes => .{ .fill = .{ .gradient = .{ .a = hex(0xfb, 0xbf, 0x24), .b = hex(0xd9, 0x76, 0x06) } }, .hairline = false },
        .terminal => .{ .fill = .{ .solid = hex(0x0d, 0x11, 0x17) }, .hairline = true },
        .settings, .other => .{ .fill = .{ .solid = Color{ .r = 1, .g = 1, .b = 1, .a = 0.08 } }, .hairline = true },
        .text_doc => .{ .fill = .{ .gradient = .{ .a = hex(0x60, 0xa5, 0xfa), .b = hex(0x25, 0x63, 0xeb) } }, .hairline = false },
        .browser => .{ .fill = .{ .gradient = .{ .a = hex(0x38, 0xbd, 0xf8), .b = hex(0x63, 0x66, 0xf1) } }, .hairline = false },
    };
}

pub fn textColor(color: Color) text.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

pub fn gradientColor(a: Color, b: Color, px: f32, py: f32, x: f32, y: f32, w: f32, h: f32) Color {
    // A 135deg (top-left to bottom-right) diagonal, which for a square tile
    // is just the averaged normalized projection onto both axes.
    const t = clamp01(((px - x) / w + (py - y) / h) / 2);
    return Color.lerp(a, b, t);
}

// ---- SDF primitives and per-app glyphs (26x26 tile, coords tile-centered) ----
pub fn sdCircle(px: f32, py: f32, cx: f32, cy: f32, r: f32) f32 {
    return @sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy)) - r;
}

// Terminal and the unrecognized-client fallback are stamped as text
// afterward (">_" and a monogram) instead of hand-drawn vectors.
pub fn glyphSd(kind: AppKind, gx: f32, gy: f32) ?f32 {
    return switch (kind) {
        .file_explorer => @min(
            chrome.sdRoundedBox(gx, gy, -8, -3, 16, 9, 2),
            chrome.sdRoundedBox(gx, gy, -8, -6, 7, 4, 1),
        ),
        .notes => @min(
            @min(
                chrome.sdRoundedBox(gx, gy, -7, -6, 14, 2, 1),
                chrome.sdRoundedBox(gx, gy, -7, -1, 14, 2, 1),
            ),
            chrome.sdRoundedBox(gx, gy, -7, 4, 10, 2, 1),
        ),
        .settings => @min(
            @abs(sdCircle(gx, gy, 0, 0, 7)) - 1.6,
            sdCircle(gx, gy, 0, 0, 2),
        ),
        .text_doc => @min(
            @min(
                @abs(chrome.sdRoundedBox(gx, gy, -7, -9, 14, 18, 2)) - 1.4,
                chrome.sdRoundedBox(gx, gy, -4, -3, 8, 1.6, 0.8),
            ),
            chrome.sdRoundedBox(gx, gy, -4, 1, 8, 1.6, 0.8),
        ),
        .browser => @min(
            @min(
                @abs(sdCircle(gx, gy, 0, 0, 9)) - 1.6,
                chrome.sdRoundedBox(gx, gy, -9, -0.8, 18, 1.6, 0.8),
            ),
            chrome.sdRoundedBox(gx, gy, -0.8, -9, 1.6, 18, 0.8),
        ),
        .terminal, .other => null,
    };
}

pub fn edgeCoverage(distance: f32, scale: f32) f32 {
    return clamp01(0.5 - distance * scale);
}

pub fn clamp01(value: f32) f32 {
    return @max(0, @min(1, value));
}
