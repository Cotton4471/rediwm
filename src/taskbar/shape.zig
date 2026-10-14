//! The bar as a shape: where it sits on its output, how far its items keep
//! from rounded ends, and the pixels of its background. Pure arithmetic, so
//! every floating variant is checked without a compositor.
const std = @import("std");
const wlr = @import("wlroots");
const sdf = @import("ui").sdf;

/// The narrowest a bar is drawn however short it is asked to be: the start
/// button, a few icons and the clock still have to fit.
pub const min_width: i32 = 420;

pub const Spec = struct {
    height: i32,
    /// Logical px between the bar and the output edge it sits on.
    edge_gap: i32 = 0,
    /// Percent of the output's width; the bar is centred.
    length: f32 = 100,
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
            .x = output.x + @divTrunc(output.width - width, 2),
            .y = if (spec.top) output.y + gap else output.y + output.height - spec.height - gap,
            .width = width,
            .height = spec.height,
        },
        .reserved = spec.height + gap,
    };
}

/// Flush means the original bar: edge to edge, on the output's edge, square.
/// It keeps its single hairline on the side facing the windows.
pub fn flush(output: wlr.Box, placed: wlr.Box, radius: f32) bool {
    return radius <= 0 and placed.width >= output.width and placed.x == output.x and
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

const TestColor = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,

    fn over(source: TestColor, destination: TestColor) TestColor {
        const alpha = source.a + destination.a * (1 - source.a);
        if (alpha == 0) return .{};
        return .{
            .r = (source.r * source.a + destination.r * destination.a * (1 - source.a)) / alpha,
            .g = (source.g * source.a + destination.g * destination.a * (1 - source.a)) / alpha,
            .b = (source.b * source.a + destination.b * destination.a * (1 - source.a)) / alpha,
            .a = alpha,
        };
    }
    fn scaled(color: TestColor, alpha: f32) TestColor {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = std.math.clamp(color.a * alpha, 0, 1) };
    }
};

test "the bar is centred, keeps its gap on the edge it sits on and never gets too short" {
    const output: wlr.Box = .{ .x = 100, .y = 50, .width = 1920, .height = 1080 };
    const flat = place(output, .{ .height = 44 });
    try std.testing.expectEqual(wlr.Box{ .x = 100, .y = 50 + 1080 - 44, .width = 1920, .height = 44 }, flat.box);
    try std.testing.expectEqual(@as(i32, 44), flat.reserved);

    const floating = place(output, .{ .height = 44, .edge_gap = 12, .length = 60 });
    try std.testing.expectEqual(wlr.Box{ .x = 100 + 384, .y = 50 + 1080 - 44 - 12, .width = 1152, .height = 44 }, floating.box);
    try std.testing.expectEqual(@as(i32, 56), floating.reserved);

    const top = place(output, .{ .height = 44, .edge_gap = 12, .length = 60, .top = true });
    try std.testing.expectEqual(@as(i32, 50 + 12), top.box.y);
    try std.testing.expectEqual(@as(i32, 56), top.reserved);

    // Shorter than the items need, or than the output is wide.
    try std.testing.expectEqual(min_width, place(output, .{ .height = 44, .length = 20 }).box.width);
    const narrow: wlr.Box = .{ .x = 0, .y = 0, .width = 300, .height = 600 };
    try std.testing.expectEqual(@as(i32, 300), place(narrow, .{ .height = 44, .length = 50 }).box.width);
    // Out-of-range asks fall back into range instead of leaving the output.
    try std.testing.expectEqual(@as(i32, 1920), place(output, .{ .height = 44, .length = 400 }).box.width);
    try std.testing.expectEqual(@as(i32, 1080), place(output, .{ .height = 44, .edge_gap = 5000 }).reserved);
}

test "only the original bar is flush" {
    const output: wlr.Box = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const bottom = place(output, .{ .height = 44 }).box;
    try std.testing.expect(flush(output, bottom, 0));
    try std.testing.expect(flush(output, place(output, .{ .height = 44, .top = true }).box, 0));
    try std.testing.expect(!flush(output, bottom, 8));
    try std.testing.expect(!flush(output, place(output, .{ .height = 44, .edge_gap = 6 }).box, 0));
    try std.testing.expect(!flush(output, place(output, .{ .height = 44, .length = 80 }).box, 0));
}

test "items clear a rounded end by exactly what the curve takes" {
    try std.testing.expectEqual(@as(i32, 0), cornerInset(0, 4));
    // Margin as tall as the radius: the item's corner is past the curve.
    try std.testing.expectEqual(@as(i32, 0), cornerInset(6, 6));
    // A pill 44 high: an item 4 from the top starts about 9.4 px in.
    try std.testing.expectEqual(@as(i32, 10), cornerInset(22, 4));
    try std.testing.expectEqual(@as(f32, 22), effectiveRadius(80, 44));
    try std.testing.expectEqual(@as(f32, 0), effectiveRadius(-3, 44));
    // The reported inset really does put the item corner inside the arc.
    const r: f32 = 22;
    const inset: f32 = @floatFromInt(cornerInset(r, 4));
    try std.testing.expect((r - inset) * (r - inset) + (r - 4) * (r - 4) <= r * r);
}

test "the flush background is the original fill and hairline, on the side facing the windows" {
    const fill: TestColor = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 0.96 };
    const line: TestColor = .{ .r = 1, .g = 1, .b = 1, .a = 0.06 };
    const bottom: Look = .{ .width = 400, .height = 44, .radius = 0, .outline = 1, .flush = true, .top = false };
    try std.testing.expectEqualDeep(line.over(fill), background(TestColor, bottom, 100, 0.5, 1, fill, line));
    try std.testing.expectEqualDeep(fill, background(TestColor, bottom, 100, 1.5, 1, fill, line));
    var top = bottom;
    top.top = true;
    try std.testing.expectEqualDeep(fill, background(TestColor, top, 100, 0.5, 1, fill, line));
    try std.testing.expectEqualDeep(line.over(fill), background(TestColor, top, 100, 43.5, 1, fill, line));
    var bare = bottom;
    bare.outline = 0;
    try std.testing.expectEqualDeep(fill, background(TestColor, bare, 100, 0.5, 1, fill, line));
}

fn expectColor(expected: TestColor, actual: TestColor) !void {
    inline for (.{ "r", "g", "b", "a" }) |channel| try std.testing.expectApproxEqAbs(@field(expected, channel), @field(actual, channel), 1e-5);
}

test "a floating background rounds its corners and wears its outline all round" {
    const fill: TestColor = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 0.9 };
    const line: TestColor = .{ .r = 1, .g = 0, .b = 0, .a = 0.5 };
    const look: Look = .{ .width = 400, .height = 44, .radius = 22, .outline = 2, .flush = false, .top = false };
    // The corner is cut away, the middle is plain fill, the rim carries the outline.
    try std.testing.expectEqual(@as(f32, 0), background(TestColor, look, 0.5, 0.5, 1, fill, line).a);
    try expectColor(fill, background(TestColor, look, 200, 22, 1, fill, line));
    try expectColor(line.over(fill), background(TestColor, look, 200, 0.5, 1, fill, line));
    try expectColor(line.over(fill), background(TestColor, look, 200, 43.5, 1, fill, line));
    try expectColor(line.over(fill), background(TestColor, look, 0.5, 22, 1, fill, line));
    // Square but floating (only a gap or a length): the corners stay filled.
    var square = look;
    square.radius = 0;
    try std.testing.expect(background(TestColor, square, 1, 1, 1, fill, line).a > 0.9);
    // The ramp is antialiased across the curve.
    const edge = background(TestColor, look, 6.4, 6.4, 1, fill, line).a;
    try std.testing.expect(edge > 0 and edge < 1);
}
