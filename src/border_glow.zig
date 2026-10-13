//! Where the pointer is relative to a window's edge, for the highlight the frame
//! shows near it (`Toplevel.setGlow`). Pure geometry, in frame units.
const std = @import("std");

pub const Probe = struct {
    /// 0 at `reach` from the edge or beyond, 1 on it, eased.
    near: f32,
    /// The point of the edge closest to the pointer.
    x: f32,
    y: f32,
};

/// The frame is `width` by `height` at the origin with corner `radius`. Null when
/// the pointer is `reach` or more from the edge, on either side of it.
pub fn probe(width: f32, height: f32, radius: f32, px: f32, py: f32, reach: f32) ?Probe {
    if (!(reach > 0) or !(width > 0) or !(height > 0)) return null;
    const r = @min(radius, 0.5 * @min(width, height));
    const qx = @abs(px - 0.5 * width) - (0.5 * width - r);
    const qy = @abs(py - 0.5 * height) - (0.5 * height - r);
    const outside = std.math.hypot(@max(qx, 0), @max(qy, 0));
    const distance = @abs(outside + @min(@max(qx, qy), 0) - r);
    if (!(distance < reach)) return null;

    var ex: f32 = undefined;
    var ey: f32 = undefined;
    if (px < 0 or px > width or py < 0 or py > height) {
        ex = std.math.clamp(px, 0, width);
        ey = std.math.clamp(py, 0, height);
    } else {
        // Inside: the nearest side.
        const to_left = px;
        const to_right = width - px;
        const to_top = py;
        const to_bottom = height - py;
        const nearest = @min(@min(to_left, to_right), @min(to_top, to_bottom));
        ex = px;
        ey = py;
        if (nearest == to_left) ex = 0 else if (nearest == to_right) ex = width else if (nearest == to_top) ey = 0 else ey = height;
    }
    const n = 1 - distance / reach;
    return .{ .near = n * n * (3 - 2 * n), .x = ex, .y = ey };
}
