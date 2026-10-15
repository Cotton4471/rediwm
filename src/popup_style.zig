//! Shared taskbar popup surfaces; controls still use the shared widgets.
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("node.zig");
const ui = @import("ui");
const glass = @import("glass.zig");
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;

pub fn configureGlass(effect: *?*glass.Effect, engine: ?*glass.Engine, node: *sn.Buffer, factor: f32) void {
    const t = ui.theme.global;
    if (!t.popup_blur) {
        glass.Effect.detach(effect.*);
        effect.* = null;
        return;
    }
    if (effect.* == null) effect.* = glass.Engine.attach(engine, node, &node.node, .panel);
    glass.Effect.configure(effect.*, t.popup_radius * factor, node.opacity);
}

pub fn background(r: *ui.paint.Renderer, buf: *PanelBuffer, width: f32, height: f32, tail: f32, tip: f32, top: bool) void {
    const t = r.palette.?;
    var bg = t.popup_bg orelse t.window_bg;
    if (t.popup_bg == null) bg[3] = 1;
    const border = t.popup_border orelse t.border_hover;
    // A glass panel uses one rounded footprint, matching the backdrop clip.
    r.fillRect(0, 0, width, height - (if (t.popup_blur) @as(f32, 0) else tail), .{ .color = bg, .radius = t.popup_radius, .border_width = 1, .border_color = border });
    if (t.popup_blur) {
        // Soft light along the inside edge gives the glass a little depth.
        r.fillRect(1, 1, width - 2, height - 2, .{ .color = .{ 0, 0, 0, 0 }, .radius = @max(0, t.popup_radius - 1), .border_width = 1, .border_color = .{ border[0], border[1], border[2], border[3] * 0.18 } });
        return;
    }
    for (0..@intCast(buf.height)) |iy| {
        const y = (@as(f32, @floatFromInt(iy)) + 0.5) / r.scale;
        if (y < height - tail - 1) continue;
        for (0..@intCast(buf.width)) |ix| {
            const x = (@as(f32, @floatFromInt(ix)) + 0.5) / r.scale;
            const d = (@abs(x - tip) + y - height) / @sqrt(@as(f32, 2));
            const coverage = std.math.clamp(0.5 - d * r.scale, 0, 1);
            if (coverage == 0) continue;
            const mix = (1 - std.math.clamp((-d - 1) * r.scale + 0.5, 0, 1)) * border[3];
            buf.pixels[iy * @as(usize, @intCast(buf.width)) + ix] = (@import("color.zig").Straight{
                .r = bg[0] * (1 - mix) + border[0] * mix,
                .g = bg[1] * (1 - mix) + border[1] * mix,
                .b = bg[2] * (1 - mix) + border[2] * mix,
                .a = coverage * bg[3],
            }).argb();
        }
    }
    if (top) buf.flipVertical();
}

pub fn cardPalette(t: ui.theme.Theme) ui.theme.Theme {
    var result = t;
    result.window_fg = t.popup_card_fg orelse t.window_fg;
    result.fg = t.popup_card_fg orelse t.fg;
    result.window_dim = t.popup_card_dim orelse t.window_dim;
    result.dim = t.popup_card_dim orelse t.dim;
    result.faint = t.popup_card_dim orelse t.faint;
    if (t.popup_card_bg != null) {
        result.surface_hover = t.accent;
        result.surface_hover[3] = 0.18;
        result.border_soft = t.popup_card_border orelse t.border_soft;
    }
    return result;
}

pub fn card(r: *ui.paint.Renderer, x: f32, y: f32, w: f32, h: f32) void {
    const t = r.palette.?;
    r.fillRect(x, y, w, h, .{
        .color = t.popup_card_bg orelse t.surface_hover,
        .radius = t.popup_card_radius,
        .border_width = if (t.popup_card_border != null) 1 else 0,
        .border_color = t.popup_card_border orelse t.border_soft,
    });
}
