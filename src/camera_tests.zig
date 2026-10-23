const std = @import("std");
const camera_mod = @import("camera.zig");
const Offset = camera_mod.Offset;
const Vec = camera_mod.Vec;
const boostedScale = camera_mod.boostedScale;
const zoomPercentAtIndex = camera_mod.zoomPercentAtIndex;
const zoomAtIndex = camera_mod.zoomAtIndex;
const nearestIndex = camera_mod.nearestIndex;
const offsetLimits = camera_mod.offsetLimits;
const rubberBand = camera_mod.rubberBand;
const Camera = camera_mod.Camera;
const focusOffset = camera_mod.focusOffset;
const Bounds = camera_mod.Bounds;
const ZoomScroll = camera_mod.ZoomScroll;
const default_multiplier = camera_mod.default_multiplier;
const computeBounds = camera_mod.computeBounds;
const desktopOffset = camera_mod.desktopOffset;
const computeGridBounds = camera_mod.computeGridBounds;
const expandToFrame = camera_mod.expandToFrame;
const applyMotion = camera_mod.applyMotion;
const applyMotionRubber = camera_mod.applyMotionRubber;
const appliedOffset = camera_mod.appliedOffset;
const layoutToWorld = camera_mod.layoutToWorld;
const worldToLayout = camera_mod.worldToLayout;
const reveal = camera_mod.reveal;

test "desktopOffset steps between grid cells and stops at the edges" {
    // 3 columns of 1000: desktops at -1000, 0, 1000.
    try std.testing.expectEqual(@as(f64, 1000), desktopOffset(0, 1000, 3, 1, 1));
    try std.testing.expectEqual(@as(f64, 1000), desktopOffset(1000, 1000, 3, 1, 1));
    try std.testing.expectEqual(@as(f64, -1000), desktopOffset(-1000, 1000, 3, 1, -1));
    // A drag left the camera between desktops: snap, then step.
    try std.testing.expectEqual(@as(f64, 0), desktopOffset(-620, 1000, 3, 1, 1));
    try std.testing.expectEqual(@as(f64, 0), desktopOffset(310, 1000, 3, 1, 0));
    // Beyond the grid (bounds grown to reach a window) counts as the edge desktop.
    try std.testing.expectEqual(@as(f64, 0), desktopOffset(4000, 1000, 3, 1, -1));
    // Even counts sit on half cells.
    try std.testing.expectEqual(@as(f64, 500), desktopOffset(-500, 1000, 2, 1, 1));
    try std.testing.expectEqual(@as(f64, 0), desktopOffset(123, 1000, 1, 1, 1));
}

test "desktopOffset centres the desktop when zoomed out" {
    // At 0.5x the view is 2000 wide; centring the right desktop
    // (world 1000..2000) puts the view's left edge at 500.
    try std.testing.expectEqual(@as(f64, 500), desktopOffset(-500, 1000, 3, 0.5, 1));
}

test "rectangular canvas sizes include even counts and a single screen" {
    const b = computeGridBounds(-200, 100, 1000, 700, 10, 2);
    try std.testing.expectEqual(@as(f64, 4500), b.max_x);
    try std.testing.expectEqual(@as(f64, 350), b.max_y);
    const single = computeGridBounds(0, 0, 1000, 700, 1, 1);
    try std.testing.expectEqual(@as(f64, 0), single.max_x);
    try std.testing.expectEqual(@as(f64, 0), single.max_y);
}

test "computeBounds default multiplier" {
    const b = computeBounds(0, 0, 1920, 1080, default_multiplier);
    try std.testing.expectEqual(@as(f64, 1920), b.max_x);
    try std.testing.expectEqual(@as(f64, 1080), b.max_y);
}

test "computeBounds multiplier 5" {
    const b = computeBounds(0, 0, 1920, 1080, 5);
    try std.testing.expectEqual(@as(f64, 3840), b.max_x);
    try std.testing.expectEqual(@as(f64, 2160), b.max_y);
}

test "computeBounds non-zero layout origin" {
    const b = computeBounds(100, 200, 1920, 1080, default_multiplier);
    try std.testing.expectEqual(@as(f64, 1920), b.max_x);
    try std.testing.expectEqual(@as(f64, 1080), b.max_y);
}

test "computeBounds zero size" {
    const b = computeBounds(0, 0, 0, 0, default_multiplier);
    try std.testing.expectEqual(@as(f64, 0), b.max_x);
    try std.testing.expectEqual(@as(f64, 0), b.max_y);
}

test "expandToFrame grows bounds to reach a window" {
    var b = computeBounds(0, 0, 1920, 1080, default_multiplier);
    // Pan only far enough to bring the outside edge into the viewport.
    expandToFrame(&b, -2500, 0, 400, 300, 0, 0, 1920, 1080);
    try std.testing.expectEqual(@as(f64, 2500), b.max_x);
    try std.testing.expectEqual(@as(f64, 1080), b.max_y);

    b = computeBounds(0, 0, 1920, 1080, default_multiplier);
    expandToFrame(&b, 5000, 0, 400, 300, 0, 0, 1920, 1080);
    try std.testing.expectEqual(@as(f64, 3480), b.max_x);
}

test "visible windows do not expand a resized canvas" {
    for ([_]u32{ 1, 2, 3 }) |count| {
        var b = computeGridBounds(-1920, -200, 1920, 1080, count, count);
        const before = b;
        expandToFrame(&b, -1820, -100, 400, 300, -1920, -200, 1920, 1080);
        try std.testing.expectEqual(before, b);
    }
}

test "single-screen canvas keeps the top-left frame edges reachable" {
    var b = computeGridBounds(-1920, -200, 1920, 1080, 1, 1);
    expandToFrame(&b, -2020, -250, 2220, 1200, -1920, -200, 1920, 1080);
    try std.testing.expectEqual(@as(f64, 100), b.max_x);
    try std.testing.expectEqual(@as(f64, 50), b.max_y);
}

test "a frame nudged past the bottom or right does not add a row or column" {
    // One row of three: a window hanging 300 below the screen keeps max_y at 0.
    var b = computeGridBounds(0, 0, 1920, 1080, 3, 1);
    const before = b;
    expandToFrame(&b, 200, 600, 800, 780, 0, 0, 1920, 1080);
    expandToFrame(&b, 3500, 100, 800, 600, 0, 0, 1920, 1080);
    try std.testing.expectEqual(before, b);
    // A frame whose grab strip left the grid is still reachable in full.
    expandToFrame(&b, 200, 1050, 800, 600, 0, 0, 1920, 1080);
    try std.testing.expectEqual(@as(f64, 570), b.max_y);
}

test "focusOffset is null when the clamped camera cannot reveal more" {
    const b = computeGridBounds(0, 0, 1920, 1080, 1, 1);
    const cam: Camera = .{};
    try std.testing.expect(focusOffset(cam, b, .{ .x = 200, .y = 900 }, .{ .x = 800, .y = 600 }, .{ .x = 0, .y = 0 }, .{ .x = 1920, .y = 1080 }, true) == null);
}

test "expandToFrame no-op when window already reachable" {
    var b = computeBounds(0, 0, 1920, 1080, default_multiplier);
    expandToFrame(&b, 100, 100, 400, 300, 0, 0, 1920, 1080);
    try std.testing.expectEqual(@as(f64, 1920), b.max_x);
    try std.testing.expectEqual(@as(f64, 1080), b.max_y);
}

test "expandToFrame skips empty usable area" {
    var b = computeBounds(0, 0, 0, 0, default_multiplier);
    expandToFrame(&b, 100, 100, 400, 300, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(f64, 0), b.max_x);
    try std.testing.expectEqual(@as(f64, 0), b.max_y);
}

test "applyMotion basic pan" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    var cam: Camera = .{};

    const r = applyMotion(&cam, 100, 50, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 100), r.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), r.applied_dy, 1e-9);
    try std.testing.expectEqual(@as(i32, 100), r.offset_x);
    try std.testing.expectEqual(@as(i32, 50), r.offset_y);
    try std.testing.expectApproxEqAbs(@as(f64, 100), cam.offset_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), cam.offset_y, 1e-9);
}

test "applyMotion negative direction" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    var cam: Camera = .{};

    const r = applyMotion(&cam, -300, -200, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, -300), r.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -200), r.applied_dy, 1e-9);
    try std.testing.expectEqual(@as(i32, -300), r.offset_x);
    try std.testing.expectEqual(@as(i32, -200), r.offset_y);
}

test "applyMotion clamps at positive boundary" {
    const bounds: Bounds = .{ .max_x = 500, .max_y = 500 };
    var cam: Camera = .{};

    const r = applyMotion(&cam, 600, 600, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 500), r.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 500), r.applied_dy, 1e-9);
    try std.testing.expectEqual(@as(i32, 500), r.offset_x);
    try std.testing.expectEqual(@as(i32, 500), r.offset_y);
    try std.testing.expectApproxEqAbs(@as(f64, 500), cam.offset_x, 1e-9);
}

test "applyMotion clamps at negative boundary" {
    const bounds: Bounds = .{ .max_x = 500, .max_y = 500 };
    var cam: Camera = .{};

    const r = applyMotion(&cam, -700, -700, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, -500), r.applied_dx, 1e-9);
    try std.testing.expectEqual(@as(i32, -500), r.offset_x);
}

test "applyMotion boundary reversal moves immediately" {
    const bounds: Bounds = .{ .max_x = 500, .max_y = 500 };
    var cam: Camera = .{};

    // Drive to positive boundary
    _ = applyMotion(&cam, 1000, 0, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 500), cam.offset_x, 1e-9);

    // More in same direction → no movement
    const r1 = applyMotion(&cam, 50, 0, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 0), r1.applied_dx, 1e-9);

    // Reverse → should start moving immediately
    const r2 = applyMotion(&cam, -10, 0, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, -10), r2.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 490), cam.offset_x, 1e-9);
}

test "applyMotion fractional accumulation" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    var cam: Camera = .{};

    _ = applyMotion(&cam, 0.3, 0, bounds);
    _ = applyMotion(&cam, 0.3, 0, bounds);
    _ = applyMotion(&cam, 0.3, 0, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), cam.offset_x, 1e-9);
    const off = appliedOffset(cam);
    try std.testing.expectEqual(@as(i32, 1), off.x);
}

test "appliedOffset rounding" {
    const cam: Camera = .{ .offset_x = 2.5, .offset_y = -3.6 };
    const off = appliedOffset(cam);
    try std.testing.expectEqual(@as(i32, 3), off.x);
    try std.testing.expectEqual(@as(i32, -4), off.y);
}

test "layoutToWorld and worldToLayout round-trip" {
    const offset: Offset = .{ .x = 100, .y = -50 };
    const world = layoutToWorld(200, 300, offset);
    try std.testing.expectEqual(@as(i32, 300), world.x);
    try std.testing.expectEqual(@as(i32, 250), world.y);

    const back = worldToLayout(world.x, world.y, offset);
    try std.testing.expectEqual(@as(i32, 200), back.x);
    try std.testing.expectEqual(@as(i32, 300), back.y);
}

test "reveal window already visible" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    const d = reveal(100, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, 0), d.dx);
    try std.testing.expectEqual(@as(i32, 0), d.dy);
}

test "reveal window off-screen to the right" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    // Window at world x=1800, width=400. In layout space: 1800..2200. Screen: 0..1920.
    // Shift layout by -280 to bring right edge to 1920.
    // target_ox = 0 - (-280) = +280.
    const d = reveal(1800, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, 280), d.dx);
    try std.testing.expectEqual(@as(i32, 0), d.dy);
}

test "reveal window off-screen to the left" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    // Window at world x=-200. Layout x=-200. Shift layout by +200 so left edge is at 0.
    // target_ox = 0 - 200 = -200.
    const d = reveal(-200, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, -200), d.dx);
    try std.testing.expectEqual(@as(i32, 0), d.dy);
}

test "reveal window off-screen to the top" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    const d = reveal(100, -300, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, 0), d.dx);
    try std.testing.expectEqual(@as(i32, -300), d.dy);
}

test "reveal clamped to bounds" {
    const bounds: Bounds = .{ .max_x = 100, .max_y = 100 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    // Window at x=-500, needs ox=-500, but clamped to -100
    const d = reveal(-500, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, -100), d.dx);
}

test "reveal with non-zero camera offset" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 200, .y = 0 };
    // Window at world x=300, layout x = 300 - 200 = 100 (visible)
    const d = reveal(300, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, 0), d.dx);
    try std.testing.expectEqual(@as(i32, 0), d.dy);
}

test "reveal maximized window" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    // Maximized window placed at world (400, 200)
    const d = reveal(400, 200, 1920, 1040, 0, 0, 1920, 1040, offset, bounds, true);
    try std.testing.expectEqual(@as(i32, 400), d.dx);
    try std.testing.expectEqual(@as(i32, 200), d.dy);
}

test "zoom anchor and world geometry round trip on negative layout" {
    const bounds = computeBounds(-1920, -200, 3200, 1080, 3);
    var camera: Camera = .{ .offset_x = -100, .offset_y = -100 };
    const anchor: Vec = .{ .x = -500, .y = 300 };
    const point = camera.toWorld(bounds, anchor.x, anchor.y);
    for ([_]usize{ 1, 2, 3, 2, 1, 0 }) |index| {
        camera.setZoom(bounds, index, anchor);
        const projected = camera.toLayout(bounds, point.x, point.y);
        try std.testing.expectApproxEqAbs(anchor.x, projected.x, 0.000001);
        try std.testing.expectApproxEqAbs(anchor.y, projected.y, 0.000001);
        const inverse = camera.toWorld(bounds, projected.x, projected.y);
        try std.testing.expectApproxEqAbs(point.x, inverse.x, 0.000001);
        try std.testing.expectApproxEqAbs(point.y, inverse.y, 0.000001);
    }
    try std.testing.expectApproxEqAbs(@as(f64, -100), camera.offset_x, 0.000001);
}

test "pan preserves screen distance at all zoom levels and reverses at bounds" {
    const bounds = computeBounds(0, 0, 1000, 700, 3);
    for (0..camera_mod.zoom_levels.len) |index| {
        var camera: Camera = .{ .zoom_index = index, .zoom_value = zoomAtIndex(index) };
        const before = camera.toLayout(bounds, 200, 200);
        _ = applyMotion(&camera, -100 / camera.zoom(), -20 / camera.zoom(), bounds);
        const after = camera.toLayout(bounds, 200, 200);
        try std.testing.expectApproxEqAbs(@as(f64, 100), after.x - before.x, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 20), after.y - before.y, 0.000001);
        _ = applyMotion(&camera, -100000, 0, bounds);
        const reverse = applyMotion(&camera, 1, 0, bounds);
        try std.testing.expectEqual(@as(f64, 1), reverse.applied_dx);
    }
}

test "zoom bounds contain full expanded viewport and handle undersized worlds" {
    const bounds = computeBounds(-1000, 0, 1000, 700, 3);
    var camera: Camera = .{ .offset_x = 10000, .offset_y = 10000, .zoom_index = 3, .zoom_value = zoomAtIndex(3) };
    camera.clamp(bounds);
    const edge = camera.toWorld(bounds, 0, 700);
    try std.testing.expectApproxEqAbs(@as(f64, 1000), edge.x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1400), edge.y, 0.000001);
    const small = computeBounds(0, 0, 1000, 700, 1);
    camera.clamp(small);
    const center = camera.toWorld(small, 500, 350);
    try std.testing.expectApproxEqAbs(@as(f64, 500), center.x, 0.000001);
}

test "wheel v120 accumulation and continuous direction reversal" {
    var scroll: ZoomScroll = .{};
    try std.testing.expectEqual(@as(i32, 0), scroll.feed(60, 5, 0));
    try std.testing.expectEqual(@as(i32, 1), scroll.feed(60, 5, 0));
    try std.testing.expectEqual(@as(i32, 0), scroll.feed(0, 25, 1));
    try std.testing.expectEqual(@as(i32, -1), scroll.feed(0, -40, 1));
    _ = scroll.feed(0, 20, 1);
    _ = scroll.feed(0, 0, 1);
    try std.testing.expectEqual(@as(f64, 0), scroll.remainder);
}

test "rubber band resists past the limit and never reaches the viewport size" {
    const bounds = computeBounds(0, 0, 1000, 700, 3);
    var cam: Camera = .{};
    var raw_x: f64 = 0;
    var raw_y: f64 = 0;
    const limits = offsetLimits(bounds, cam.zoom());

    _ = applyMotionRubber(&cam, limits.hi_x + 400, 0, bounds, &raw_x, &raw_y);
    try std.testing.expect(cam.offset_x > limits.hi_x);
    try std.testing.expect(cam.offset_x < limits.hi_x + 400);
    try std.testing.expect(cam.offset_x < limits.hi_x + bounds.width);
    try std.testing.expectApproxEqAbs(rubberBand(raw_x, limits.lo_x, limits.hi_x, bounds.width), cam.offset_x, 1e-9);

    // Interior motion is still 1:1.
    cam = .{};
    raw_x = 0;
    raw_y = 0;
    const inner = applyMotionRubber(&cam, 80, -40, bounds, &raw_x, &raw_y);
    try std.testing.expectApproxEqAbs(@as(f64, 80), inner.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -40), inner.applied_dy, 1e-9);
}

test "placeZoom keeps the world point under the layout anchor" {
    const bounds = computeBounds(0, 0, 1920, 1080, 3);
    var cam: Camera = .{ .offset_x = 120, .offset_y = -40 };
    const anchor: Vec = .{ .x = 400, .y = 300 };
    const world = cam.toWorld(bounds, anchor.x, anchor.y);
    cam.placeZoom(bounds, 0.7, world, anchor);
    const projected = cam.toLayout(bounds, world.x, world.y);
    try std.testing.expectApproxEqAbs(anchor.x, projected.x, 1e-6);
    try std.testing.expectApproxEqAbs(anchor.y, projected.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), cam.zoom(), 1e-9);
}

test "nearestIndex picks the closest discrete zoom step" {
    try std.testing.expectEqual(@as(usize, 0), nearestIndex(1.0));
    try std.testing.expectEqual(@as(usize, 0), nearestIndex(0.96));
    try std.testing.expectEqual(@as(usize, 1), nearestIndex(0.90));
    try std.testing.expectEqual(@as(usize, 1), nearestIndex(0.85));
    try std.testing.expectEqual(@as(usize, 3), nearestIndex(0.40));
    try std.testing.expectEqual(@as(usize, 3), nearestIndex(0.0));
}

test "camera zoom caps custom steps and continuous magnification at 100 percent" {
    const previous = camera_mod.zoom_levels;
    defer camera_mod.zoom_levels = previous;
    camera_mod.zoom_levels = &.{ 150, 100, 70, 55 };
    const bounds = computeBounds(0, 0, 1280, 720, 3);
    var cam: Camera = .{};
    const anchor: Vec = .{ .x = 320, .y = 240 };
    cam.setZoom(bounds, 0, anchor);
    try std.testing.expectEqual(@as(f64, 1), cam.zoom());
    try std.testing.expectEqual(@as(u8, 100), zoomPercentAtIndex(0));
    cam.placeZoom(bounds, 2, anchor, anchor);
    try std.testing.expectEqual(@as(f64, 1), cam.zoom_value);
    try std.testing.expectEqual(anchor, cam.toWorld(bounds, anchor.x, anchor.y));
    cam.setZoom(bounds, 2, anchor);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), cam.zoom(), 1e-9);
    try std.testing.expectApproxEqAbs(anchor.x, cam.toWorld(bounds, anchor.x, anchor.y).x, 1e-9);
    try std.testing.expectApproxEqAbs(anchor.y, cam.toWorld(bounds, anchor.x, anchor.y).y, 1e-9);
}

test "temporary boost compensates desktop zoom without changing the saved window scale" {
    for ([_]f64{ 1, 0.85, 0.55, 0.25 }) |desktop| {
        for ([_]f64{ 1, 0.7, 0.4 }) |window| {
            try std.testing.expectApproxEqAbs(window, boostedScale(window, desktop, 0), 1e-9);
            try std.testing.expectApproxEqAbs(@as(f64, 1), boostedScale(window, desktop, 1) * desktop, 1e-9);
            const half = boostedScale(window, desktop, 0.5) * desktop;
            try std.testing.expect(half >= window * desktop and half <= 1);
        }
    }
}

test "focus reveal ignores a visible sliver and centers the destination" {
    const bounds = computeBounds(0, 0, 1280, 720, 3);
    const cam = Camera{};
    const area = Vec{ .x = 1280, .y = 660 };
    const size = Vec{ .x = 400, .y = 300 };
    try std.testing.expectEqual(@as(?Vec, null), focusOffset(cam, bounds, .{ .x = 100, .y = 100 }, size, .{ .x = 0, .y = 0 }, area, false));
    const offset = focusOffset(cam, bounds, .{ .x = 1279, .y = 100 }, size, .{ .x = 0, .y = 0 }, area, false).?;
    try std.testing.expectEqual(@as(f64, 839), offset.x);
    try std.testing.expectEqual(@as(f64, -80), offset.y);
    const oversized = focusOffset(cam, bounds, .{ .x = -200, .y = -100 }, .{ .x = 1800, .y = 1400 }, .{ .x = 0, .y = 0 }, area, true).?;
    try std.testing.expectEqual(@as(f64, -200), oversized.x);
    try std.testing.expectEqual(@as(f64, -100), oversized.y);
}

test "camera focus supports reciprocal depths and percentages above 255" {
    const bounds = computeBounds(-1280, 0, 2560, 720, 3);
    var cam = Camera{ .zoom_limit = 4, .focus_zoom = 4 };
    const anchor = Vec{ .x = -600, .y = 200 };
    const point = cam.toWorld(bounds, anchor.x, anchor.y);
    cam.placeZoom(bounds, 4, point, anchor);
    try std.testing.expectEqual(@as(u16, 400), cam.targetPercent());
    try std.testing.expectEqual(@as(f64, 4), cam.zoom());
    const screen = cam.toLayout(bounds, point.x, point.y);
    try std.testing.expectApproxEqAbs(anchor.x, screen.x, 1e-9);
    try std.testing.expectApproxEqAbs(anchor.y, screen.y, 1e-9);
    cam.setZoom(bounds, 0, anchor);
    try std.testing.expectEqual(@as(f64, 1), cam.zoom());
    try std.testing.expectEqual(@as(?f64, null), cam.focus_zoom);
}
