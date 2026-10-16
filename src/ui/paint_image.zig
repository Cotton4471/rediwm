//! UI image painting: box-filtered sampling and premultiplied blending.

const std = @import("std");
const layout = @import("layout.zig");
const Widget = layout.Widget;
const ImageData = layout.ImageData;
const sdf = @import("paint.zig").sdf;
const theme = @import("paint.zig").theme;
const Image = @import("paint.zig").Image;
const Renderer = @import("paint.zig").Renderer;
const byte = @import("paint.zig").byte;

pub fn paintImage(widget: *const Widget, data: ImageData, renderer: *Renderer) void {
    renderer.clean = false;
    const s = renderer.scale;
    const x = widget.computed_x;
    const y = widget.computed_y;
    const w = widget.computed_width;
    const h = widget.computed_height;
    if (w <= 0 or h <= 0) return;

    var dx0 = x * s;
    var dy0 = y * s;
    var dx1 = (x + w) * s;
    var dy1 = (y + h) * s;
    if (renderer.effectiveClip()) |c| {
        dx0 = @max(dx0, c.x * s);
        dy0 = @max(dy0, c.y * s);
        dx1 = @min(dx1, (c.x + c.w) * s);
        dy1 = @min(dy1, (c.y + c.h) * s);
    }
    const x0: i32 = @intFromFloat(@floor(@max(0, dx0)));
    const y0: i32 = @intFromFloat(@floor(@max(0, dy0)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(renderer.width)), dx1)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(renderer.height)), dy1)));
    if (x0 >= x1 or y0 >= y1) return;

    const box_x = x * s;
    const box_y = y * s;
    const box_w = w * s;
    const box_h = h * s;
    const radius = data.radius * s;

    if (data.pixels) |pixels| {
        if (data.width <= 0 or data.height <= 0) return;

        // Icons are cached at the exact device size the row asks for, so the
        // usual case is a 1:1 blit: no sampling arithmetic, and the blend is
        // a plain premultiplied source-over in integer lanes. The general
        // path below stays for scaled or rounded draws.
        if (radius <= 0 and box_x == @floor(box_x) and box_y == @floor(box_y) and
            box_w == @as(f32, @floatFromInt(data.width)) and box_h == @as(f32, @floatFromInt(data.height)))
        {
            const src_stride: usize = @intCast(data.width);
            const off_x = x0 - @as(i32, @intFromFloat(box_x));
            const off_y = y0 - @as(i32, @intFromFloat(box_y));
            var row = y0;
            while (row < y1) : (row += 1) {
                const src_row: usize = @intCast(off_y + (row - y0));
                const src = pixels[src_row * src_stride ..][@intCast(off_x)..][0..@intCast(x1 - x0)];
                const dst = renderer.pixels[@intCast(row * renderer.width + x0)..][0..@intCast(x1 - x0)];
                for (dst, src) |*pixel, sample| pixel.* = overPremultiplied(pixel.*, sample);
            }
            return;
        }

        const src_w_f: f32 = @floatFromInt(data.width);
        const src_h_f: f32 = @floatFromInt(data.height);
        var py = y0;
        while (py < y1) : (py += 1) {
            var px = x0;
            while (px < x1) : (px += 1) {
                const sx = @as(f32, @floatFromInt(px)) + 0.5;
                const sy = @as(f32, @floatFromInt(py)) + 0.5;
                var cov: f32 = 1;
                if (radius > 0) {
                    cov = sdf.coverage(sdf.sdRoundedBox(sx, sy, box_x, box_y, box_w, box_h, radius));
                    if (cov <= 0) continue;
                }
                const norm_u = std.math.clamp((sx - box_x) / box_w, 0, 1);
                const norm_v = std.math.clamp((sy - box_y) / box_h, 0, 1);
                const ix: usize = @min(@as(usize, @intCast(@as(i32, @intFromFloat(@floor(norm_u * src_w_f))))), @as(usize, @intCast(data.width - 1)));
                const iy: usize = @min(@as(usize, @intCast(@as(i32, @intFromFloat(@floor(norm_v * src_h_f))))), @as(usize, @intCast(data.height - 1)));
                const sample = pixels[iy * @as(usize, @intCast(data.width)) + ix];
                blendPremultipliedPixel(&renderer.pixels[@intCast(py * renderer.width + px)], sample, cov);
            }
        }
    } else {
        const t = renderer.palette orelse theme.global;
        const bg_col = data.fallback_color orelse t.surface_hover;
        renderer.fillRect(x, y, w, h, .{ .color = bg_col, .radius = data.radius });
        if (data.fallback_icon) |icon_id| {
            const icon_pad = @min(w, h) * 0.25;
            renderer.drawIcon(x + icon_pad, y + icon_pad, w - 2 * icon_pad, h - 2 * icon_pad, .{ .id = icon_id, .color = t.dim });
        }
    }
}

/// Source-over of an already-premultiplied sample at full coverage, in
/// integer lanes — the same rounding trick as `blendConstOver`, and safe from
/// lane overflow for the same reason (a premultiplied sample has
/// `channel <= alpha`, so `src_c + dst_c*inv/255 <= 255`).
pub inline fn overPremultiplied(dst: u32, src: u32) u32 {
    const src_alpha = src >> 24;
    if (src_alpha == 0) return dst;
    if (src_alpha == 255) return src;
    const inv = 255 - src_alpha;
    const rb = (dst & 0x00FF00FF) * inv + 0x00800080;
    const ag = ((dst >> 8) & 0x00FF00FF) * inv + 0x00800080;
    const rb_done = ((rb + ((rb >> 8) & 0x00FF00FF)) >> 8) & 0x00FF00FF;
    const ag_done = (ag + ((ag >> 8) & 0x00FF00FF)) & 0xFF00FF00;
    return src +% (rb_done | ag_done);
}

/// Wider footprints sample more than a few taps a pixel; the dock only ever
/// shrinks by its hover zoom (at most 1.5).
pub const max_footprint: f32 = 8;
pub const max_taps = 10;

/// The source pixels one axis of a footprint covers and how much of each: the
/// overlap of [centre - half, centre + half], cut to [0, limit], with pixel i
/// spanning [i, i + 1).
pub const Taps = struct {
    first: usize = 0,
    count: usize = 0,
    weight: [max_taps]f32 = undefined,
    sum: f32 = 0,

    pub fn init(centre: f32, half: f32, limit: i32) Taps {
        var taps: Taps = .{};
        const lo = @max(centre - half, 0);
        const hi = @min(centre + half, @as(f32, @floatFromInt(limit)));
        if (lo >= hi) return taps;
        taps.first = @intFromFloat(@floor(lo));
        const last = @min(@as(usize, @intFromFloat(@ceil(hi))), @as(usize, @intCast(limit)));
        taps.count = @min(last -| taps.first, max_taps);
        for (0..taps.count) |i| {
            const at: f32 = @floatFromInt(taps.first + i);
            const weight = @min(at + 1, hi) - @max(at, lo);
            taps.weight[i] = weight;
            taps.sum += weight;
        }
        return taps;
    }
};

/// Area average of the footprint whose axes are `across` and `down`: each source
/// pixel weighs by how much of the footprint it covers. At a width of one this is
/// bilinear interpolation. Premultiplied channels average correctly; the part of
/// the footprint outside the image is left out.
pub fn boxAverage(image: Image, across: Taps, down: Taps) u32 {
    const total = across.sum * down.sum;
    if (total <= 0) return 0;
    const stride: usize = @intCast(image.width);
    var a: f32 = 0;
    var red: f32 = 0;
    var green: f32 = 0;
    var blue: f32 = 0;
    for (0..down.count) |j| {
        const row = image.pixels[(down.first + j) * stride + across.first ..][0..across.count];
        var ra: f32 = 0;
        var rr: f32 = 0;
        var rg: f32 = 0;
        var rb: f32 = 0;
        for (row, across.weight[0..across.count]) |pixel, weight| {
            ra += weight * @as(f32, @floatFromInt(pixel >> 24));
            rr += weight * @as(f32, @floatFromInt((pixel >> 16) & 0xff));
            rg += weight * @as(f32, @floatFromInt((pixel >> 8) & 0xff));
            rb += weight * @as(f32, @floatFromInt(pixel & 0xff));
        }
        const weight = down.weight[j];
        a += weight * ra;
        red += weight * rr;
        green += weight * rg;
        blue += weight * rb;
    }
    const scale = 1 / total;
    // Averages of premultiplied channels stay premultiplied: no channel exceeds alpha.
    const out_a: u32 = @intFromFloat(@round(a * scale));
    const out_r: u32 = @min(@as(u32, @intFromFloat(@round(red * scale))), out_a);
    const out_g: u32 = @min(@as(u32, @intFromFloat(@round(green * scale))), out_a);
    const out_b: u32 = @min(@as(u32, @intFromFloat(@round(blue * scale))), out_a);
    return out_a << 24 | out_r << 16 | out_g << 8 | out_b;
}

/// `boxAverage` of the `width`-wide square centred on (u, v), in source pixels.
pub fn boxSample(image: Image, u: f32, v: f32, width: f32) u32 {
    const half = width / 2;
    return boxAverage(image, Taps.init(u, half, image.width), Taps.init(v, half, image.height));
}

pub fn blendPremultipliedPixel(dst: *u32, sample: u32, coverage: f32) void {
    if (coverage <= 0) return;
    const sa_raw = @as(f32, @floatFromInt((sample >> 24) & 0xff)) / 255.0;
    if (sa_raw <= 0) return;
    const sa = sa_raw * coverage;
    const inv = 1.0 - sa;
    const sr = @as(f32, @floatFromInt((sample >> 16) & 0xff)) / 255.0 * coverage;
    const sg = @as(f32, @floatFromInt((sample >> 8) & 0xff)) / 255.0 * coverage;
    const sb = @as(f32, @floatFromInt(sample & 0xff)) / 255.0 * coverage;

    const val = dst.*;
    const da = @as(f32, @floatFromInt((val >> 24) & 0xff)) / 255.0;
    const dr = @as(f32, @floatFromInt((val >> 16) & 0xff)) / 255.0;
    const dg = @as(f32, @floatFromInt((val >> 8) & 0xff)) / 255.0;
    const db = @as(f32, @floatFromInt(val & 0xff)) / 255.0;

    const a = sa + da * inv;
    const r = sr + dr * inv;
    const g = sg + dg * inv;
    const b = sb + db * inv;

    dst.* = (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b);
}
