//! The bar as a shape: where it sits on its output, how far its items keep
//! from rounded ends, and the pixels of its background. Pure arithmetic, so
//! every floating variant is checked without a compositor.
const std = @import("std");
const wlr = @import("wlroots");
const sdf = @import("ui").sdf;
const window_shape = @import("ui").window_shape;

/// The narrowest a bar is drawn however short it is asked to be: the start
/// button, a few icons and the clock still have to fit.
pub const min_width: i32 = 420;

pub const Spec = struct {
    height: i32,
    /// Logical px between the bar and the output edge it sits on.
    edge_gap: i32 = 0,
    /// Percent of the output's width.
    length: f32 = 100,
    alignment: @import("config").types.TaskbarAlignment = .center,
    radius: f32 = 0,
    top: bool = false,
};

pub const Placement = struct {
    box: wlr.Box,
    /// What the bar claims from the output edge: its height and its gap.
    reserved: i32,
};

pub fn place(output: wlr.Box, spec: Spec) Placement {
    const percent = std.math.clamp(spec.length, 20, 100);
    const wanted: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(output.width)) * percent / 100));
    const width = std.math.clamp(wanted, @min(output.width, min_width), output.width);
    const gap = std.math.clamp(spec.edge_gap, 0, @max(0, output.height - spec.height));
    return .{
        .box = .{
            .x = output.x + switch (spec.alignment) {
                .left => @as(i32, 0),
                .center => @divTrunc(output.width - width, 2),
                .right => output.width - width,
            },
            .y = if (spec.top) output.y + gap else output.y + output.height - spec.height - gap,
            .width = width,
            .height = spec.height,
        },
        .reserved = spec.height + gap,
    };
}

/// Flush means the original bar: edge to edge, on the output's edge, square.
/// It keeps its single hairline on the side facing the windows.
pub fn flush(output: wlr.Box, placed: wlr.Box, radius: f32, outlined: bool) bool {
    return !outlined and radius <= 0 and placed.width >= output.width and placed.x == output.x and
        (placed.y == output.y or placed.y + placed.height == output.y + output.height);
}

/// A corner can't be rounder than a pill.
pub fn effectiveRadius(radius: f32, height: i32) f32 {
    return @max(0, @min(radius, @as(f32, @floatFromInt(height)) / 2));
}

/// How far from an end of the bar an item has to start to stay inside the
/// curve, when its near edge is `margin` from the bar's top or bottom.
pub fn cornerInset(radius: f32, margin: f32) i32 {
    const rise = radius - margin;
    if (radius <= 0 or rise <= 0) return 0;
    return @intFromFloat(@ceil(radius - @sqrt(radius * radius - rise * rise)));
}

pub const Look = struct {
    /// Logical size of the raster the pixel is sampled in.
    width: f32,
    height: f32,
    radius: f32,
    outline: f32,
    flush: bool,
    top: bool,
};

/// One pixel of the bar's background at logical `px`, `py` of its raster.
/// `C` is a straight-alpha colour with `over` and `scaled`. The outline is
/// composited over the fill, never replacing it: both are translucent.
pub fn background(comptime C: type, look: Look, px: f32, py: f32, scale: f32, fill: C, outline: C) C {
    if (look.flush) {
        const edge = if (look.top) py >= look.height - look.outline else py < look.outline;
        return if (edge) outline.over(fill) else fill;
    }
    const covered = coverage(sdf.sdRoundedBox(px, py, 0, 0, look.width, look.height, look.radius), scale);
    if (covered <= 0) return fill.scaled(0);
    const o = look.outline;
    const inside = if (o <= 0) 1 else coverage(sdf.sdRoundedBox(px, py, o, o, look.width - 2 * o, look.height - 2 * o, @max(0, look.radius - o)), scale);
    return outline.scaled(1 - inside).over(fill).scaled(covered);
}

fn coverage(distance: f32, scale: f32) f32 {
    return std.math.clamp(0.5 - distance * scale, 0, 1);
}

test {
    _ = @import("shape_tests.zig");
}

/// The bar's polygon outline in a bar of `width` x `height` logical px, from the
/// theme's `taskbar_shape` text, or null for the rounded rectangle (no text, a
/// text that does not parse, or an outline the size folds over itself).
pub fn polygon(text: []const u8, width: f64, height: f64) ?window_shape.Resolved {
    const outline = (window_shape.parse(text) catch return null) orelse return null;
    const resolved = window_shape.resolve(outline, width, height, 1);
    return if (window_shape.usable(resolved)) resolved else null;
}

pub const Insets = struct { left: i32 = 0, right: i32 = 0 };

/// How far from either end of a bar with this outline the items have to start
/// to stay inside it, over the band `top` to `bottom` (logical px from the bar's
/// top): the first column from that end where every row of the band is inside.
/// A row with no inside near the end (a notch the band reaches into) is left to
/// the clip rather than pushing the items off the bar. The outline is resolved at
/// a width past any slanted end, so the answer does not depend on the bar's
/// length for the usual px-anchored ends.
pub fn polygonInsets(text: []const u8, height: f64, top: f64, bottom: f64) Insets {
    const reference: f64 = 1600;
    const reach: i32 = 160;
    const poly = polygon(text, reference, height) orelse return .{};
    var out: Insets = .{};
    const rows = 8;
    for (0..rows + 1) |i| {
        const y = top + (bottom - top) * @as(f64, @floatFromInt(i)) / rows;
        var x: i32 = 0;
        while (x < reach and window_shape.sdPolygon(poly, @floatFromInt(x), y) > 0) x += 1;
        if (x < reach) out.left = @max(out.left, x);
        x = 0;
        while (x < reach and window_shape.sdPolygon(poly, reference - @as(f64, @floatFromInt(x)), y) > 0) x += 1;
        if (x < reach) out.right = @max(out.right, x);
    }
    return out;
}

/// A raster of device pixels the bar paints itself into.
pub const Raster = struct {
    pixels: []u32,
    stride: usize,
    width: usize,
    height: usize,
    scale: f32,
};

const max_edges = window_shape.max_points;

/// The bar's background for a polygon outline: `fill` inside it, with `outline`
/// (`outline_width` logical px, composited over the fill) along its edge, and
/// transparent outside, the way `background` paints the rounded bar, except that
/// the outer edge is not anti-aliased: the tree's clip (`Taskbar.applyClip`)
/// shapes and smooths it on the GPU, and a second ramp would thin it.
///
/// Only the pixels within reach of an edge cost a distance. For each row the
/// stretches that are near an edge (its extent in the row, widened by the
/// outline and a pixel) are worked out exactly; the rest of the row is flat,
/// filled in runs by the even-odd crossings of the row. A long flat top or
/// bottom edge is the whole of its rows, but the rows in between hold a few
/// short stretches, so a bar costs a fraction of one distance per pixel.
pub fn paintPolygon(comptime C: type, raster: Raster, poly: window_shape.Resolved, outline_width: f32, fill: C, outline: C) void {
    const scale: f64 = raster.scale;
    const reach: f64 = @max(outline_width, 0) + 1.0 / scale;
    const fill_px: u32 = fill.argb();
    const width: i32 = @intCast(raster.width);
    for (0..raster.height) |row_index| {
        const py = (@as(f64, @floatFromInt(row_index)) + 0.5) / scale;
        const row = raster.pixels[row_index * raster.stride ..][0..raster.width];
        var active: [max_edges]u8 = undefined;
        var active_count: usize = 0;
        var near: [max_edges][2]i32 = undefined;
        var crossings: [max_edges]f64 = undefined;
        var crossing_count: usize = 0;
        for (0..poly.count) |i| {
            const a = poly.points[i];
            const b = poly.points[(i + 1) % poly.count];
            if ((a[1] <= py) != (b[1] <= py)) {
                crossings[crossing_count] = a[0] + (py - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
                crossing_count += 1;
            }
            if (@max(a[1], b[1]) < py - reach or @min(a[1], b[1]) > py + reach) continue;
            // The part of the edge within reach of this row, and the columns it spans.
            var t0: f64 = 0;
            var t1: f64 = 1;
            const dy = b[1] - a[1];
            if (dy != 0) {
                const u = (py - reach - a[1]) / dy;
                const v = (py + reach - a[1]) / dy;
                t0 = std.math.clamp(@min(u, v), 0, 1);
                t1 = std.math.clamp(@max(u, v), 0, 1);
            }
            const x0 = a[0] + t0 * (b[0] - a[0]);
            const x1 = a[0] + t1 * (b[0] - a[0]);
            active[active_count] = @intCast(i);
            near[active_count] = .{
                std.math.clamp(@as(i32, @intFromFloat(@floor((@min(x0, x1) - reach) * scale))), 0, width),
                std.math.clamp(@as(i32, @intFromFloat(@ceil((@max(x0, x1) + reach) * scale))) + 1, 0, width),
            };
            active_count += 1;
        }
        std.mem.sort(f64, crossings[0..crossing_count], {}, std.sort.asc(f64));
        // Where each crossing falls among the pixel centres: the first column right of it.
        var bounds: [max_edges]i32 = undefined;
        for (crossings[0..crossing_count], 0..) |x, i| {
            bounds[i] = std.math.clamp(@as(i32, @intFromFloat(@floor(x * scale - 0.5))) + 1, 0, width);
        }
        // The near stretches, merged left to right.
        std.mem.sort([2]i32, near[0..active_count], {}, struct {
            fn less(_: void, a: [2]i32, b: [2]i32) bool {
                return a[0] < b[0];
            }
        }.less);
        var cursor: i32 = 0;
        var i: usize = 0;
        while (i < active_count) {
            var start = near[i][0];
            var end = near[i][1];
            i += 1;
            while (i < active_count and near[i][0] <= end) : (i += 1) end = @max(end, near[i][1]);
            start = @max(start, cursor);
            if (end <= start) continue;
            flatRun(row, cursor, start, bounds[0..crossing_count], fill_px);
            for (@as(usize, @intCast(start))..@as(usize, @intCast(end))) |x| {
                const px = (@as(f64, @floatFromInt(x)) + 0.5) / scale;
                var d2: f64 = std.math.inf(f64);
                for (active[0..active_count]) |edge| d2 = @min(d2, segmentDistanceSquared(poly.points[edge], poly.points[(edge + 1) % poly.count], px, py));
                const distance: f64 = if (insideAt(bounds[0..crossing_count], @intCast(x))) -@sqrt(d2) else @sqrt(d2);
                row[x] = edgePixel(C, distance, scale, outline_width, fill, outline);
            }
            cursor = end;
        }
        flatRun(row, cursor, width, bounds[0..crossing_count], fill_px);
    }
}

/// Whether column `x` is inside: an odd number of the row's crossings lie left of it.
fn insideAt(bounds: []const i32, x: i32) bool {
    var count: usize = 0;
    for (bounds) |b| count += @intFromBool(b <= x);
    return count % 2 == 1;
}

/// Columns `from` to `to` of a row away from every edge: the fill inside, nothing outside.
fn flatRun(row: []u32, from: i32, to: i32, bounds: []const i32, fill_px: u32) void {
    if (to <= from) return;
    var k: usize = 0;
    while (k < bounds.len and bounds[k] <= from) k += 1;
    var x = from;
    while (x < to) {
        const next = if (k < bounds.len) @min(to, bounds[k]) else to;
        @memset(row[@intCast(x)..@intCast(next)], if (k % 2 == 1) fill_px else 0);
        x = next;
        k += 1;
    }
}

fn segmentDistanceSquared(a: [2]f64, b: [2]f64, px: f64, py: f64) f64 {
    const ex = b[0] - a[0];
    const ey = b[1] - a[1];
    const wx = px - a[0];
    const wy = py - a[1];
    const h = std.math.clamp((wx * ex + wy * ey) / @max(ex * ex + ey * ey, 1e-4), 0, 1);
    const bx = wx - ex * h;
    const by = wy - ey * h;
    return bx * bx + by * by;
}

/// One pixel at signed distance `distance` (logical px, negative inside).
pub fn edgePixel(comptime C: type, distance: f64, scale: f64, outline_width: f32, fill: C, outline: C) u32 {
    if (distance * scale >= 0.5) return 0;
    if (outline_width <= 0) return fill.argb();
    const inside = coverage(@floatCast(distance + outline_width), @floatCast(scale));
    return outline.scaled(1 - inside).over(fill).argb();
}
