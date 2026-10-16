//! Taskbar app tray.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const wlr = @import("wlroots");
const icon_service = @import("../icon_service.zig");
const battery = @import("../taskbar/battery.zig");
const taskbar_items = @import("config").taskbar_items;
const text = @import("ui").text;
const tray_gap = Taskbar.tray_gap;
const clock_gap = Taskbar.clock_gap;
const battery_width = Taskbar.battery_width;
const Color = Taskbar.Color;
const BarBuffer = Taskbar.BarBuffer;
const trayHit = Taskbar.trayHit;
const buttonSize = Taskbar.buttonSize;
const startButtonLeft = Taskbar.startButtonLeft;
const rightPad = Taskbar.rightPad;

pub fn appTrayCount(bar: *Taskbar) usize {
    if (!bar.itemShown(.tray)) return 0;
    const mgr = bar.server.tray orelse return 0;
    var fixed: f32 = @floatFromInt(rightPad() + startButtonLeft() + 80 + 5 * clock_gap);
    if (bar.itemShown(.start)) fixed += @floatFromInt(buttonSize());
    if (bar.itemShown(.battery)) fixed += battery_width;
    if (bar.itemShown(.wifi)) fixed += @floatFromInt(trayHit());
    if (bar.itemShown(.wired)) fixed += @floatFromInt(trayHit());
    if (bar.itemShown(.volume)) fixed += @floatFromInt(trayHit());
    if (bar.itemShown(.clock)) fixed += bar.clockColumnWidth();
    if (bar.itemShown(.power)) fixed += @floatFromInt(trayHit() + tray_gap);
    if (bar.capturing()) fixed += @floatFromInt(bar.captureWidth());
    const room = @max(0, @as(f32, @floatFromInt(bar.box.width)) - fixed);
    return @min(mgr.visibleCount(), @as(usize, @intFromFloat(room / @as(f32, @floatFromInt(trayHit() + tray_gap)))));
}

pub fn appTrayLeft(bar: *Taskbar) f32 {
    return bar.item_layout.x[@intFromEnum(taskbar_items.Item.tray)] orelse 0;
}

pub fn appTrayBox(bar: *Taskbar, index: usize) wlr.Box {
    return .{ .x = bar.box.x + @as(i32, @intFromFloat(bar.appTrayLeft())) + @as(i32, @intCast(index)) * (trayHit() + tray_gap), .y = bar.box.y + @divTrunc(bar.box.height - trayHit(), 2), .width = trayHit(), .height = trayHit() };
}

pub fn appTrayAt(bar: *Taskbar, sx: f64, sy: f64) ?usize {
    for (0..bar.appTrayCount()) |i| {
        const b = bar.appTrayBox(i);
        const x: f64 = @floatFromInt(b.x - bar.box.x);
        const y: f64 = @floatFromInt(b.y - bar.box.y);
        if (sx >= x and sx < x + @as(f64, @floatFromInt(b.width)) and sy >= y and sy < y + @as(f64, @floatFromInt(b.height))) return i;
    }
    return null;
}

pub fn renderAppTray(bar: *Taskbar) void {
    const mgr = bar.server.tray orelse {
        bar.app_tray_node.node.setEnabled(false);
        return;
    };
    const count = bar.appTrayCount();
    bar.app_tray_node.node.setEnabled(count > 0);
    const left: i32 = @intFromFloat(bar.appTrayLeft());
    bar.app_tray_node.node.setPosition(left, 0);
    if (count == 0 or (bar.app_tray_generation == mgr.generation and !bar.background_dirty)) return;
    const width: i32 = @as(i32, @intCast(count)) * (trayHit() + tray_gap);
    const scale = bar.wlr_output.scale;
    const buf = BarBuffer.create(width, bar.box.height, scale) catch return;
    defer buf.base.drop();
    @memset(buf.pixels, 0);
    const size: i32 = @min(22, trayHit() - 4);
    for (0..count) |i| {
        const item = mgr.visibleItem(i) orelse continue;
        var pixels: []const u32 = item.pixels;
        var sw = item.width;
        var sh = item.height;
        if (item.attention and item.attention_pixels.len > 0) {
            pixels = item.attention_pixels;
            sw = item.attention_width;
            sh = item.attention_height;
        }
        const icon_name = if (item.attention and item.attention_icon.len > 0) item.attention_icon else if (item.attention and item.attention_pixels.len > 0) "" else item.icon;
        const icon_size: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(size)) * scale));
        var lookup: icon_service.Lookup = if (icon_name.len > 0) bar.server.iconLookup(icon_name, icon_size) else .missing;
        if (icon_name.len > 0 and icon_name[0] != '/' and item.icon_theme_path.len > 0) {
            // Resolve application-private indicator directories on the existing
            // icon worker, never synchronously decode from the rendering loop.
            var path_buf: [4096]u8 = undefined;
            for ([_][]const u8{ "", ".png", ".svg" }) |extension| {
                const full = std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ item.icon_theme_path, icon_name, extension }) catch continue;
                const candidate = bar.server.iconLookup(full, icon_size);
                if (candidate == .ready) {
                    lookup = candidate;
                    break;
                }
            }
        }
        if (icon_name.len > 0) switch (lookup) {
            .ready => |entry| {
                pixels = entry.pixels;
                sw = entry.size;
                sh = entry.size;
            },
            else => {},
        };
        const x = @as(i32, @intCast(i)) * (trayHit() + tray_gap) + @divTrunc(trayHit() - size, 2);
        const y = @divTrunc(bar.box.height - size, 2);
        if (pixels.len == 0 or sw <= 0 or sh <= 0) {
            text.draw(buf.pixels, buf.width, buf.height, .{ .x = x, .y = y, .w = size, .h = size }, "●", Color.clock_time(), scale, .manrope, 16) catch {};
            continue;
        }
        const dw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(size)) * scale));
        const dx: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x)) * scale));
        const dy: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y)) * scale));
        var py: i32 = 0;
        while (py < dw) : (py += 1) {
            var px: i32 = 0;
            while (px < dw) : (px += 1) {
                const src: usize = @intCast(@divTrunc(py * sh, dw) * sw + @divTrunc(px * sw, dw));
                const dest: usize = @intCast((dy + py) * buf.width + dx + px);
                buf.pixels[dest] = pixels[src];
            }
        }
    }
    bar.app_tray_node.setBuffer(&buf.base);
    bar.app_tray_node.setDestSize(width, bar.box.height);
    bar.app_tray_generation = mgr.generation;
}
