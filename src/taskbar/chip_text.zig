//! Taskbar chip titles and part text.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const sn = @import("../node.zig");
const battery = @import("../taskbar/battery.zig");
const battery_badge = @import("ui").widgets.battery;
const start_button = @import("../taskbar/start_button.zig");
const text = @import("ui").text;
const ui_theme = @import("ui").theme;
const stats = @import("../ipc/stats.zig");
const icon_scale = Taskbar.icon_scale;
const icon_text_gap = Taskbar.icon_text_gap;
const title_pad_right = Taskbar.title_pad_right;
const paint_chips = Taskbar.paint_chips;
const capture_label = Taskbar.capture_label;
const ChipState = Taskbar.ChipState;
const ChipMemo = Taskbar.ChipMemo;
const ChipRasterKey = Taskbar.ChipRasterKey;
const clock_time_size = Taskbar.clock_time_size;
const clock_date_size = Taskbar.clock_date_size;
const Color = Taskbar.Color;
const BarBuffer = Taskbar.BarBuffer;
const Part = Taskbar.Part;
const ChipPaint = Taskbar.ChipPaint;
const chipSize = Taskbar.chipSize;
const tileSize = Taskbar.tileSize;
const chipPad = Taskbar.chipPad;
const trayHit = Taskbar.trayHit;
const buttonSize = Taskbar.buttonSize;
const clockFont = Taskbar.clockFont;
const chipTitle = Taskbar.chipTitle;
const monogramOf = Taskbar.monogramOf;
const textColor = Taskbar.textColor;
const chipPixelArgb = Taskbar.chipPixelArgb;

/// Chip pixels for device columns `x0..x1` of a raster whose logical origin
/// is (`origin_x`, `origin_y`). Full and title-only chip repaints share it,
/// so both evaluate exactly the same expressions.
pub fn fillChipColumns(paint: *const ChipPaint, pixels: []u32, width: i32, height: i32, origin_x: i32, origin_y: i32, x0: usize, x1: usize, scale: f32) void {
    const stride: usize = @intCast(width);
    for (0..@intCast(height)) |dy| {
        const py = @as(f32, @floatFromInt(origin_y)) + (@as(f32, @floatFromInt(dy)) + 0.5) / scale;
        for (x0..x1) |dx| {
            const px = @as(f32, @floatFromInt(origin_x)) + (@as(f32, @floatFromInt(dx)) + 0.5) / scale;
            pixels[dy * stride + dx] = chipPixelArgb(paint, px, py, scale);
        }
    }
}

/// The chip title's box in raster-local logical pixels, or null when the chip
/// is too narrow to show one. `cx` is the chip's rounded left edge.
pub fn chipTitleRect(cx: i32, bar_h: i32, chip_width: f32, origin_x: i32, origin_y: i32) ?text.Rect {
    const tw: i32 = @as(i32, @intFromFloat(@round(chip_width))) - chipPad() - tileSize() - icon_text_gap - title_pad_right;
    if (tw < 16) return null;
    const cy = @divTrunc(bar_h - chipSize(), 2);
    return .{ .x = cx + chipPad() + tileSize() + icon_text_gap - origin_x, .y = cy - origin_y, .w = tw, .h = chipSize() };
}

pub fn chipTitleColor(bar: *Taskbar, chip: *const ChipState) text.Color {
    return if (chip.toplevel == bar.server.world.toplevels.first()) Color.clock_time() else Color.chip_title_idle();
}

pub fn drawChipTitle(pixels: []u32, width: i32, height: i32, rect: text.Rect, title: []const u8, color: text.Color, scale: f32) void {
    if (title.len == 0) return;
    // Keep a font-metric baseline: animated title glyphs change their ink
    // bounds, which must not shift the rest of the title up and down.
    text.draw(pixels, width, height, rect, title, color, scale, .manrope, ui_theme.global.taskbar_title_size) catch {};
}

/// Text is clipped to `rect`, so repainting that rect's device columns first
/// removes every pixel an earlier title touched.
pub fn paintChipTitleColumns(paint: *const ChipPaint, pixels: []u32, width: i32, height: i32, origin_x: i32, rect: text.Rect, title: []const u8, color: text.Color, scale: f32) void {
    // The same rounding text.drawOpts applies to its clip.
    const x0: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(rect.x)) * scale));
    const x1: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(rect.x + rect.w)) * scale));
    fillChipColumns(paint, pixels, width, height, origin_x, 0, @intCast(std.math.clamp(x0, 0, width)), @intCast(std.math.clamp(x1, 0, width)), scale);
    drawChipTitle(pixels, width, height, rect, title, color, scale);
}

/// Terminals animate their titles several times a second. When nothing but
/// the title changed, copy the previous raster and repaint only the title
/// box instead of the pill's edge and icon SDFs. False means a full raster
/// is needed.
pub fn repaintChipTitle(bar: *Taskbar, now_ms: i64, chip: *ChipState, memo: ChipMemo, key: ChipRasterKey, bar_h: i32, node: *sn.Buffer) bool {
    const previous = chip.raster orelse return false;
    const previous_key = chip.raster_key orelse return false;
    var painted = chip.painted orelse return false;
    if (!std.meta.eql(previous_key, key)) return false;
    painted.title_hash = memo.title_hash;
    if (!std.meta.eql(painted, memo)) return false;

    const started = stats.nowNs();
    const scale = bar.wlr_output.scale;
    const buf = BarBuffer.create(key.width, bar_h, scale) catch return false;
    if (buf.pixels.len != previous.pixels.len) {
        buf.base.drop();
        return false;
    }
    @memcpy(buf.pixels, previous.pixels);
    const cx: i32 = @intFromFloat(@round(chip.renderX(now_ms)));
    if (chipTitleRect(cx, bar.box.height, chip.width, key.left, 0)) |rect| {
        const paint = ChipPaint.init(bar, now_ms, chip);
        paintChipTitleColumns(&paint, buf.pixels, buf.width, buf.height, key.left, rect, chipTitle(chip.toplevel), chipTitleColor(bar, chip), scale);
    }
    node.node.setPosition(key.left, 0);
    node.setBuffer(&buf.base);
    node.setDestSize(key.width, bar_h);
    previous.base.drop();
    chip.raster = buf;
    stats.recordTaskbarPaint(stats.nowNs() -% started, @as(u64, @intCast(buf.width)) * @as(u64, @intCast(buf.height)), paint_chips);
    return true;
}

// Standalone status labels align their visible ink with adjacent icons.
pub fn drawCenteredText(pixels: []u32, width: i32, height: i32, rect: text.Rect, label: []const u8, color: text.Color, scale: f32, font: text.Font, size: f32) !void {
    try text.drawOpts(pixels, width, height, label, color, scale, font, size, .{ .rect = rect, .center_ink = true });
}

pub fn drawPartText(bar: *Taskbar, now_ms: i64, part: Part, buf: *BarBuffer, ox: i32, oy: i32) void {
    const scale = bar.wlr_output.scale;
    const local = struct {
        fn box(x: i32, y: i32, w: i32, h: i32, origin_x: i32, origin_y: i32) text.Rect {
            return .{ .x = x - origin_x, .y = y - origin_y, .w = w, .h = h };
        }
    }.box;
    switch (part) {
        .start => if (bar.start_logo == null) {
            const btn_size = buttonSize();
            const w = text.measureWidth("R", .mono_bold, start_button.glyph_size_px, scale) catch 0;
            drawCenteredText(buf.pixels, buf.width, buf.height, local(bar.startX() + @divTrunc(btn_size - w, 2), @intFromFloat(@round(start_button.top(bar.box.height, btn_size))), btn_size, btn_size, ox, oy), "R", textColor(Color.fromRgba(ui_theme.taskbar(.start_button_logo_color) orelse .{ 1, 1, 1, 1 })), scale, .mono_bold, start_button.glyph_size_px) catch {};
        },
        .clock => {
            const time = std.mem.trimStart(u8, std.mem.sliceTo(&bar.clock_time, 0), " ");
            const date = std.mem.sliceTo(&bar.clock_date, 0);
            const dw = text.measureWidth(date, clockFont(), clock_date_size, scale) catch 0;
            const left: i32 = @intFromFloat(@round(bar.clockX()));
            const width: i32 = @intFromFloat(bar.clockColumnWidth());
            const clock_h: i32 = if (date.len == 0) 20 else 37;
            const time_y = @divTrunc(bar.box.height - clock_h, 2);
            const date_y = time_y + 21;
            if (bar.clockLine(time)) |line| {
                // Every piece shares the baseline the digits would centre on.
                const row = text.inkBaseline("0123456789", clockFont(), clock_time_size, scale, local(0, time_y, 1, 20, ox, oy)) catch null;
                const start = left + @divTrunc(width - line.width - 1, 2);
                for (line.pieces[0..line.count]) |piece| {
                    text.drawOpts(buf.pixels, buf.width, buf.height, piece.text, Color.clock_time(), scale, clockFont(), clock_time_size, .{
                        .rect = local(start + piece.x, time_y, piece.w + 1, 20, ox, oy),
                        .clip = local(left, time_y, width, 20, ox, oy),
                        .italic = ui_theme.taskbar(.clock_italic),
                        .center_ink = row == null,
                        .baseline = row,
                    }) catch {};
                }
            } else |_| {}
            if (date.len != 0) text.drawOpts(buf.pixels, buf.width, buf.height, date, Color.clock_date(), scale, clockFont(), clock_date_size, .{
                .rect = local(left + @divTrunc(width - dw - 1, 2), date_y, dw + 1, 16, ox, oy),
                .clip = local(left, date_y, width, 16, ox, oy),
                .italic = ui_theme.taskbar(.clock_italic),
                .center_ink = true,
            }) catch {};
        },
        .chip => |chip| {
            const cx: i32 = @intFromFloat(@round(chip.renderX(now_ms)));
            const cy = @divTrunc(bar.box.height - chipSize(), 2);
            if (chip.icon == null and (chip.kind == .terminal or chip.kind == .other)) {
                var storage: [4]u8 = undefined;
                const label: []const u8 = if (chip.kind == .terminal) ">_" else monogramOf(chip.toplevel, &storage);
                const w = text.measureWidth(label, .manrope, 14 * icon_scale, scale) catch 0;
                if (w > 0) drawCenteredText(buf.pixels, buf.width, buf.height, local(cx + chipPad() + @divTrunc(tileSize() - w, 2), cy + chipPad(), tileSize(), tileSize(), ox, oy), label, textColor(Color.glyph), scale, .manrope, 14 * icon_scale) catch {};
            }
            if (chipTitleRect(cx, bar.box.height, chip.width, ox, oy)) |rect| drawChipTitle(buf.pixels, buf.width, buf.height, rect, chipTitle(chip.toplevel), chipTitleColor(bar, chip), scale);
        },
        .tray => {},
        .capture => {
            const tx: i32 = @intFromFloat(@round(bar.captureX()));
            const tw = bar.captureWidth();
            const label_w = text.measureWidth(capture_label, .manrope, 12, scale) catch 0;
            drawCenteredText(
                buf.pixels,
                buf.width,
                buf.height,
                local(tx + @divTrunc(tw - label_w, 2), @divTrunc(bar.box.height - trayHit(), 2), tw, trayHit(), ox, oy),
                capture_label,
                .{ .r = 1, .g = 1, .b = 1, .a = 1 },
                scale,
                .manrope,
                12,
            ) catch {};
        },
        .battery => {
            var label_buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d}%", .{bar.battery_state.percent orelse 0}) catch unreachable;
            drawCenteredText(buf.pixels, buf.width, buf.height, .{ .x = @intFromFloat(battery_badge.label_x), .y = @divTrunc(bar.box.height - trayHit(), 2), .w = @intFromFloat(battery_badge.label_w), .h = trayHit() }, label, Color.clock_time(), scale, .manrope, battery_badge.label_size) catch {};
        },
        .background => {},
    }
}
