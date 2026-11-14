const std = @import("std");
const wlr = @import("wlroots");
const shape = @import("shape.zig");
const place = shape.place;
const flush = shape.flush;
const min_width = shape.min_width;
const cornerInset = shape.cornerInset;
const effectiveRadius = shape.effectiveRadius;
const Look = shape.Look;
const background = shape.background;
const window_shape = @import("ui").window_shape;

const TestColor = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,

    pub fn over(source: TestColor, destination: TestColor) TestColor {
        const alpha = source.a + destination.a * (1 - source.a);
        if (alpha == 0) return .{};
        return .{
            .r = (source.r * source.a + destination.r * destination.a * (1 - source.a)) / alpha,
            .g = (source.g * source.a + destination.g * destination.a * (1 - source.a)) / alpha,
            .b = (source.b * source.a + destination.b * destination.a * (1 - source.a)) / alpha,
            .a = alpha,
        };
    }
    pub fn argb(color: TestColor) u32 {
        const q = struct {
            fn channel(v: f32) u32 {
                return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
            }
        };
        return q.channel(color.a) << 24 | q.channel(color.r) << 16 | q.channel(color.g) << 8 | q.channel(color.b);
    }
    pub fn scaled(color: TestColor, alpha: f32) TestColor {
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

    inline for (.{ .left, .center, .right }, .{ 100, 484, 868 }) |alignment, x| {
        for ([_]bool{ false, true }) |at_top| {
            const aligned = place(output, .{ .height = 44, .edge_gap = 12, .length = 60, .alignment = alignment, .top = at_top });
            try std.testing.expectEqual(@as(i32, x), aligned.box.x);
            try std.testing.expectEqual(floating.box.width, aligned.box.width);
            try std.testing.expectEqual(if (at_top) top.box.y else floating.box.y, aligned.box.y);
            try std.testing.expectEqual(floating.reserved, aligned.reserved);
            try std.testing.expectEqual(flat.box, place(output, .{ .height = 44, .alignment = alignment }).box);
        }
    }

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
    try std.testing.expect(flush(output, bottom, 0, false));
    try std.testing.expect(flush(output, place(output, .{ .height = 44, .top = true }).box, 0, false));
    try std.testing.expect(!flush(output, bottom, 8, false));
    try std.testing.expect(!flush(output, place(output, .{ .height = 44, .edge_gap = 6 }).box, 0, false));
    try std.testing.expect(!flush(output, place(output, .{ .height = 44, .length = 80 }).box, 0, false));
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

// A raised left section, a step down and a slanted right end, as a 44 px bar.
const stepped = "0 -0, 14 0, 300 0, 312 6, -14 6, -0 -0";

test "a polygon outline resolves against the bar and is refused when it does not fit" {
    const poly = shape.polygon(stepped, 1000, 44).?;
    try std.testing.expectEqual(@as(usize, 6), poly.count);
    try std.testing.expectEqual([2]f64{ 986, 6 }, poly.points[4]);
    try std.testing.expectEqual([2]f64{ 1000, 44 }, poly.points[5]);
    try std.testing.expectEqual(@as(?window_shape.Resolved, null), shape.polygon("", 1000, 44));
    try std.testing.expectEqual(@as(?window_shape.Resolved, null), shape.polygon("0 0, 5 5", 1000, 44));
    // Edges that cross fold the outline over itself.
    try std.testing.expectEqual(@as(?window_shape.Resolved, null), shape.polygon("0 0, 30 30, 30 0, 0 30", 1000, 44));
    // A polygon bar is never the flush one, whatever its radius.
    const output: wlr.Box = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    try std.testing.expect(!flush(output, place(output, .{ .height = 44 }).box, 0, true));
}

test "items clear the slanted ends of a polygon bar" {
    // Band 4 to 40 of 44: the left slant (0,44)-(14,0) is 12.7 px in at row 4. The
    // right one, (w-14,6)-(w,44), is 14 px in at row 6; rows above the step belong
    // to the notch and are not the ends' business.
    const insets = shape.polygonInsets(stepped, 44, 4, 40);
    try std.testing.expect(insets.left >= 12 and insets.left <= 14);
    try std.testing.expect(insets.right >= 12 and insets.right <= 15);
    // A rectangle needs none; text that is no outline needs none.
    try std.testing.expectEqual(shape.Insets{}, shape.polygonInsets("0 0, -0 0, -0 -0, 0 -0", 44, 4, 40));
    try std.testing.expectEqual(shape.Insets{}, shape.polygonInsets("", 44, 4, 40));
}

fn expectRasterMatchesReference(text: []const u8, width: usize, height_px: f64, scale: f32, outline_width: f32) !void {
    const fill: TestColor = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 0.9 };
    const line: TestColor = .{ .r = 1, .g = 0, .b = 0, .a = 0.5 };
    const device_height: usize = @intFromFloat(@round(height_px * scale));
    const poly = shape.polygon(text, @as(f64, @floatFromInt(width)) / scale, height_px).?;
    const pixels = try std.testing.allocator.alloc(u32, width * device_height);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0xdeadbeef);
    shape.paintPolygon(TestColor, .{ .pixels = pixels, .stride = width, .width = width, .height = device_height, .scale = scale }, poly, outline_width, fill, line);
    var wrong: usize = 0;
    for (0..device_height) |y| for (0..width) |x| {
        const px = (@as(f64, @floatFromInt(x)) + 0.5) / scale;
        const py = (@as(f64, @floatFromInt(y)) + 0.5) / scale;
        const want = shape.edgePixel(TestColor, window_shape.sdPolygon(poly, px, py), scale, outline_width, fill, line);
        if (pixels[y * width + x] != want) wrong += 1;
    };
    // Only a pixel centre on an edge itself may land on either side of it.
    try std.testing.expect(wrong * 2000 < width * device_height);
}

test "the row-span raster paints exactly what a distance per pixel would" {
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        try expectRasterMatchesReference(stepped, @intFromFloat(@round(1000 * scale)), 44, scale, 1);
        try expectRasterMatchesReference(stepped, @intFromFloat(@round(700 * scale)), 44, scale, 2.5);
        try expectRasterMatchesReference(stepped, @intFromFloat(@round(700 * scale)), 44, scale, 0);
        // Diagonals through the middle and a vertical edge.
        try expectRasterMatchesReference("0 -0, 30 0, 60% 22, -30 0, -0 -0, 50% -0, 20 -8", @intFromFloat(@round(500 * scale)), 44, scale, 1);
    }
}

test "a polygon raster is filled in runs: nothing near an edge but the edges" {
    const fill: TestColor = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 0.9 };
    const line: TestColor = .{ .r = 1, .g = 0, .b = 0, .a = 0.5 };
    const width = 1000;
    const pixels = try std.testing.allocator.alloc(u32, width * 44);
    defer std.testing.allocator.free(pixels);
    shape.paintPolygon(TestColor, .{ .pixels = pixels, .stride = width, .width = width, .height = 44, .scale = 1 }, shape.polygon(stepped, 1000, 44).?, 1, fill, line);
    // The middle of the raised section is fill, the cut-away top right is clear.
    try std.testing.expectEqual(fill.argb(), pixels[22 * width + 100]);
    try std.testing.expectEqual(@as(u32, 0), pixels[2 * width + 600]);
    try std.testing.expectEqual(fill.argb(), pixels[20 * width + 600]);
    try std.testing.expectEqual(line.over(fill).argb(), pixels[43 * width + 500]);
}

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn lap(mark: *u64) u64 {
    const now = nowNs();
    defer mark.* = now;
    return now - mark.*;
}

test "bench: polygon raster against a distance per pixel (printed, never asserted)" {
    const fill: TestColor = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 0.9 };
    const line: TestColor = .{ .r = 1, .g = 0, .b = 0, .a = 0.5 };
    const scale: f32 = 2;
    const width = 3840;
    const height = 88;
    const pixels = try std.testing.allocator.alloc(u32, width * height);
    defer std.testing.allocator.free(pixels);
    const poly = shape.polygon(stepped, 1920, 44).?;
    var mark = nowNs();
    for (0..20) |_| shape.paintPolygon(TestColor, .{ .pixels = pixels, .stride = width, .width = width, .height = height, .scale = scale }, poly, 1, fill, line);
    const spans = lap(&mark) / 20;
    const look: Look = .{ .width = 1920, .height = 44, .radius = 12, .outline = 1, .flush = false, .top = false };
    for (0..20) |_| for (0..height) |y| for (0..width) |x| {
        pixels[y * width + x] = background(TestColor, look, (@as(f32, @floatFromInt(x)) + 0.5) / scale, (@as(f32, @floatFromInt(y)) + 0.5) / scale, scale, fill, line).argb();
    };
    const rounded = lap(&mark) / 20;
    var every: u64 = 0;
    for (0..20) |_| for (0..height) |y| for (0..width) |x| {
        const d = window_shape.sdPolygon(poly, (@as(f64, @floatFromInt(x)) + 0.5) / scale, (@as(f64, @floatFromInt(y)) + 0.5) / scale);
        pixels[y * width + x] = shape.edgePixel(TestColor, d, scale, 1, fill, line);
        every += pixels[y * width + x] & 1;
    };
    const naive = lap(&mark) / 20;
    std.debug.print("\nbench 1920x44 @2x: polygon spans {d} us, rounded bar {d} us, polygon per pixel {d} us ({d})\n", .{ spans / 1000, rounded / 1000, naive / 1000, every });
}
