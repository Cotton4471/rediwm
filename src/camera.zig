// Pure world/layout camera geometry. Layout = O + zoom * (world - O - C).
// Source geometry remains integral; the presentation adapter rounds projected
// endpoints once, retaining fractional camera motion between input events.
const std = @import("std");
const anim = @import("ui").anim;

pub const Offset = struct {
    x: i32,
    y: i32,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const RevealDelta = struct {
    dx: i32,
    dy: i32,
};

/// Accumulated fractional camera offset (not yet rounded to the scene tree).
pub const default_zoom_levels = [_]u8{ 100, 85, 70, 55 };
/// Live zoom table. Defaults to `default_zoom_levels`; config hot-reload may
/// point this at a longer or shorter slice owned by the current Config arena.
pub var zoom_levels: []const u8 = &default_zoom_levels;
pub const Vec = struct { x: f64, y: f64 };

pub const FocusZoom = @import("config").types.FocusZoom;

/// A temporary presentation scale; the window's saved zoom stays unchanged.
pub fn boostedScale(window: f64, desktop: f64, mix: f64) f64 {
    const amount = std.math.clamp(mix, 0, 1);
    return window * (1 - amount) + amount / desktop;
}

/// Camera zoom never magnifies beyond 100%, even with custom window steps.
pub fn zoomPercentAtIndex(index: usize) u8 {
    if (zoom_levels.len == 0) return 100;
    return @min(100, zoom_levels[@min(index, zoom_levels.len - 1)]);
}

/// Discrete camera zoom as a scale factor. Empty tables are treated as 1×.
pub fn zoomAtIndex(index: usize) f64 {
    return @as(f64, @floatFromInt(zoomPercentAtIndex(index))) / 100;
}

/// Closest discrete zoom table entry to a continuous scale. Ties keep the
/// earlier (typically larger) step so a pinch that lands halfway snaps out.
pub fn nearestIndex(z: f64) usize {
    if (zoom_levels.len == 0) return 0;
    var best: usize = 0;
    var best_d: f64 = std.math.inf(f64);
    for (zoom_levels, 0..) |pct, i| {
        const step = @as(f64, @floatFromInt(@min(pct, 100))) / 100;
        const d = @abs(z - step);
        if (d < best_d) {
            best = i;
            best_d = d;
        }
    }
    return best;
}

pub const Limits = struct {
    lo_x: f64,
    hi_x: f64,
    lo_y: f64,
    hi_y: f64,
};

/// Offset range that keeps the expanded world reachable at `zoom`.
pub fn offsetLimits(bounds: Bounds, zoom: f64) Limits {
    const z = if (zoom > 1e-6) zoom else 1;
    return .{
        .lo_x = -bounds.max_x,
        .hi_x = bounds.max_x - bounds.width * (1 / z - 1),
        .lo_y = -bounds.max_y,
        .hi_y = bounds.max_y - bounds.height * (1 / z - 1),
    };
}

/// Apple-style rubber band in camera-offset space. `dimension` is the
/// viewport size along that axis (`bounds.width` / `bounds.height`).
pub fn rubberBand(value: f64, lo: f64, hi: f64, dimension: f64) f64 {
    const c: f64 = anim.rubber_c;
    const d = if (dimension > 0) dimension else 1;
    if (value < lo) {
        const x = lo - value;
        return lo - (1.0 - 1.0 / (x * c / d + 1.0)) * d;
    }
    if (value > hi) {
        const x = value - hi;
        return hi + (1.0 - 1.0 / (x * c / d + 1.0)) * d;
    }
    return value;
}

pub const Camera = struct {
    offset_x: f64 = 0,
    offset_y: f64 = 0,
    zoom_index: usize = 0,
    /// Continuous visual zoom. Defaults to 1× so `Camera{}` matches index 0.
    zoom_value: f64 = 1,
    /// Only explicit camera focus permits magnification. Keep the old limit
    /// during the transition back to ordinary desktop zoom.
    zoom_limit: f64 = 1,
    focus_zoom: ?f64 = null,

    pub fn targetZoom(self: Camera) f64 {
        return self.focus_zoom orelse zoomAtIndex(self.zoom_index);
    }

    pub fn targetPercent(self: Camera) u16 {
        return @intFromFloat(@round(self.targetZoom() * 100));
    }

    pub fn zoom(self: Camera) f64 {
        return if (self.zoom_value > 0) @min(self.zoom_value, self.zoom_limit) else self.targetZoom();
    }
    pub fn toLayout(self: Camera, bounds: Bounds, x: f64, y: f64) Vec {
        return .{ .x = bounds.origin_x + self.zoom() * (x - bounds.origin_x - self.offset_x), .y = bounds.origin_y + self.zoom() * (y - bounds.origin_y - self.offset_y) };
    }
    pub fn toWorld(self: Camera, bounds: Bounds, x: f64, y: f64) Vec {
        return .{ .x = bounds.origin_x + self.offset_x + (x - bounds.origin_x) / self.zoom(), .y = bounds.origin_y + self.offset_y + (y - bounds.origin_y) / self.zoom() };
    }
    pub fn setZoom(self: *Camera, bounds: Bounds, index: usize, anchor: Vec) void {
        const point = self.toWorld(bounds, anchor.x, anchor.y);
        self.focus_zoom = null;
        self.zoom_limit = 1;
        self.zoom_index = @min(index, zoom_levels.len -| 1);
        self.placeZoom(bounds, zoomAtIndex(self.zoom_index), point, anchor);
    }
    /// Keep `world_point` under `anchor` at `zoom`, then clamp.
    pub fn placeZoom(self: *Camera, bounds: Bounds, zoom_scale: f64, world_point: Vec, anchor: Vec) void {
        const z = if (zoom_scale > 1e-6) @min(zoom_scale, self.zoom_limit) else 1;
        self.zoom_value = z;
        self.offset_x = world_point.x - bounds.origin_x - (anchor.x - bounds.origin_x) / z;
        self.offset_y = world_point.y - bounds.origin_y - (anchor.y - bounds.origin_y) / z;
        self.clamp(bounds);
    }
    pub fn clamp(self: *Camera, bounds: Bounds) void {
        const limits = offsetLimits(bounds, self.zoom());
        self.offset_x = clampAxis(self.offset_x, limits.lo_x, limits.hi_x);
        self.offset_y = clampAxis(self.offset_y, limits.lo_y, limits.hi_y);
    }
};

/// Reveal a mostly hidden window in the work area. Large frames keep their
/// title and left edge reachable; ordinary frames are centered, like the
/// prototype. A small visible sliver is not enough to skip navigation.
pub fn focusOffset(cam: Camera, bounds: Bounds, origin: Vec, size: Vec, usable: Vec, area: Vec, force: bool) ?Vec {
    if (size.x <= 0 or size.y <= 0 or area.x <= 0 or area.y <= 0) return null;
    const a = cam.toLayout(bounds, origin.x, origin.y);
    const w = size.x * cam.zoom();
    const h = size.y * cam.zoom();
    const overlap_x = @max(0, @min(a.x + w, usable.x + area.x) - @max(a.x, usable.x));
    const overlap_y = @max(0, @min(a.y + h, usable.y + area.y) - @max(a.y, usable.y));
    if (!force and overlap_x * overlap_y >= 0.35 * @min(w * h, area.x * area.y)) return null;
    const x = usable.x + @max(0, (area.x - w) / 2);
    const y = usable.y + @max(0, (area.y - h) / 2);
    var result = cam;
    result.offset_x += (a.x - x) / cam.zoom();
    result.offset_y += (a.y - y) / cam.zoom();
    result.clamp(bounds);
    // A frame hanging off the canvas edge may be as revealed as it gets.
    if (result.offset_x == cam.offset_x and result.offset_y == cam.offset_y) return null;
    return .{ .x = result.offset_x, .y = result.offset_y };
}
fn clampAxis(value: f64, lo: f64, hi: f64) f64 {
    return if (hi < lo) (lo + hi) / 2 else std.math.clamp(value, lo, hi);
}
/// Minimum world extents are origin-max through origin+layout_size+max.
pub const Bounds = struct {
    max_x: f64 = 0,
    max_y: f64 = 0,
    origin_x: f64 = 0,
    origin_y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
};

/// Scroll normalization shared by physical and synthetic input. Discrete values
/// are Wayland v120 units; continuous finger motion uses 40 logical units.
pub const ZoomScroll = struct {
    remainder: f64 = 0,
    source: ?u32 = null,
    pub fn reset(self: *ZoomScroll) void {
        self.* = .{};
    }
    pub fn feed(self: *ZoomScroll, discrete: i32, delta: f64, source: u32) i32 {
        if (delta == 0 and discrete == 0) {
            self.reset();
            return 0;
        }
        const amount = if (discrete != 0) @as(f64, @floatFromInt(discrete)) / 120 else delta / 40;
        if (!std.math.isFinite(amount)) return 0;
        if (self.source != source or self.remainder * amount < 0) self.remainder = 0;
        self.source = source;
        self.remainder += amount;
        const steps: i32 = @intFromFloat(std.math.clamp(@trunc(self.remainder), -3, 3));
        self.remainder -= @as(f64, @floatFromInt(steps));
        return steps;
    }
};

/// World-space bounds multiplier. 3 → one extra screen-width in each
/// direction, so the camera range is ±W on x and ±H on y.
pub const default_multiplier: f64 = 3;

/// Compute camera bounds for the given output layout rectangle.
///
/// World bounds: (lx - W*(m-1)/2, ly - H*(m-1)/2, W*m, H*m)
/// Camera offset ranges: x ∈ [-W*(m-1)/2, W*(m-1)/2], y ∈ [-H*(m-1)/2, H*(m-1)/2]
///
/// For the default multiplier of 3 this gives one full extra screen in each
/// cardinal direction (range [-W, W], [-H, H]).
pub fn computeBounds(
    layout_x: i32,
    layout_y: i32,
    layout_w: i32,
    layout_h: i32,
    multiplier: f64,
) Bounds {
    const w: f64 = @floatFromInt(@max(0, layout_w));
    const h: f64 = @floatFromInt(@max(0, layout_h));
    const extra = @max(0.0, (multiplier - 1.0) / 2.0);
    return .{
        .origin_x = @floatFromInt(layout_x),
        .origin_y = @floatFromInt(layout_y),
        .width = w,
        .height = h,
        .max_x = w * extra,
        .max_y = h * extra,
    };
}

/// Camera offset along one axis for keyboard desktop switching. The grid holds
/// `count` desktops of `size` (the layout extent) centred on the original
/// layout. Starts from the desktop nearest the viewport centre at `offset`, so a
/// drag-panned camera snaps back onto the grid, then moves `step` desktops and
/// stops at the edge. At `zoom` < 1 the chosen desktop is centred.
pub fn desktopOffset(offset: f64, size: f64, count: u32, zoom: f64, step: i32) f64 {
    if (size <= 0) return offset;
    const z = if (zoom > 1e-6) zoom else 1;
    const last: f64 = @floatFromInt(@max(count, 1) - 1);
    const first = -size * last / 2 - size * (1 / z - 1) / 2;
    const current = std.math.clamp(@round((offset - first) / size), 0, last);
    const next = std.math.clamp(current + @as(f64, @floatFromInt(step)), 0, last);
    return first + next * size;
}

test {
    _ = @import("camera_tests.zig");
}

/// Independent screen counts, centred on the original output layout.
pub fn computeGridBounds(x: i32, y: i32, width: i32, height: i32, columns: u32, rows: u32) Bounds {
    var bounds = computeBounds(x, y, width, height, @floatFromInt(columns));
    bounds.max_y = bounds.height * @as(f64, @floatFromInt(rows -| 1)) / 2;
    return bounds;
}

/// A frame whose top-left strip this deep is within reach may hang past the
/// right or bottom of the grid: its title bar and a grab area stay reachable.
pub const reachable_strip: i32 = 96;

/// Grow `bounds.max_*` so a frame at (wx, wy, w, h) stays reachable by panning
/// the camera across `usable`. Its top and left edges (title and left border)
/// must be reachable. Past the right or bottom, a frame only grows the bounds
/// once its `reachable_strip` has left them, so nudging a window off a one-row
/// canvas does not add a second row. No-op when the usable viewport is empty.
pub fn expandToFrame(
    bounds: *Bounds,
    wx: i32,
    wy: i32,
    w: i32,
    h: i32,
    usable_x: i32,
    usable_y: i32,
    usable_w: i32,
    usable_h: i32,
) void {
    if (usable_w <= 0 or usable_h <= 0) return;

    const ox1 = wx - usable_x;
    const ox2 = if (@as(f64, @floatFromInt(wx + @min(w, reachable_strip) - (usable_x + usable_w))) <= bounds.max_x) 0 else wx + w - (usable_x + usable_w);
    const oy1 = wy - usable_y;
    const oy2 = if (@as(f64, @floatFromInt(wy + @min(h, reachable_strip) - (usable_y + usable_h))) <= bounds.max_y) 0 else wy + h - (usable_y + usable_h);

    // Only edges outside the viewport need more pan range. Taking absolute
    // distances also counts the empty space beside an already visible window,
    // expanding even a single-screen canvas when its settings are reapplied.
    const needed_max_x: f64 = @floatFromInt(@max(0, -ox1, ox2));
    const needed_max_y: f64 = @floatFromInt(@max(0, -oy1, oy2));

    if (needed_max_x > bounds.max_x) bounds.max_x = needed_max_x;
    if (needed_max_y > bounds.max_y) bounds.max_y = needed_max_y;
}

/// Returned by applyMotion — carries both the f64 delta that was actually
/// consumed and the new integer-rounded camera offset.
pub const MotionResult = struct {
    applied_dx: f64,
    applied_dy: f64,
    offset_x: i32,
    offset_y: i32,
};

/// Clamp each axis independently. When the camera is at a boundary and the
/// caller requests more motion in the same direction it is silently dropped.
/// When the caller reverses direction the overshoot is not deducted — motion
/// starts immediately from the boundary.
///
/// `dx` and `dy` are the delta to add to `camera.offset_x` and `camera.offset_y`.
/// Note: to follow the hand when dragging by pointer delta (pdx, pdy),
/// the camera offset delta is (-pdx, -pdy).
///
/// Updates `camera` in-place and returns what was actually applied plus the
/// new rounded offset.
pub fn applyMotion(
    camera: *Camera,
    dx: f64,
    dy: f64,
    bounds: Bounds,
) MotionResult {
    const limits = offsetLimits(bounds, camera.zoom());
    const new_x = clampAxis(camera.offset_x + dx, limits.lo_x, limits.hi_x);
    const new_y = clampAxis(camera.offset_y + dy, limits.lo_y, limits.hi_y);

    const applied_dx = new_x - camera.offset_x;
    const applied_dy = new_y - camera.offset_y;

    camera.offset_x = new_x;
    camera.offset_y = new_y;

    return .{
        .applied_dx = applied_dx,
        .applied_dy = applied_dy,
        .offset_x = @intFromFloat(@round(camera.offset_x)),
        .offset_y = @intFromFloat(@round(camera.offset_y)),
    };
}

/// Like `applyMotion`, but past `Limits` the surface follows with falling
/// gain instead of stopping. `raw_x`/`raw_y` accumulate the unconstrained
/// gesture offset; the camera stores the rubber-banded visual.
pub fn applyMotionRubber(
    camera: *Camera,
    dx: f64,
    dy: f64,
    bounds: Bounds,
    raw_x: *f64,
    raw_y: *f64,
) MotionResult {
    raw_x.* += dx;
    raw_y.* += dy;
    const limits = offsetLimits(bounds, camera.zoom());
    const dim_x = if (bounds.width > 0) bounds.width else 1;
    const dim_y = if (bounds.height > 0) bounds.height else 1;
    const new_x = rubberBand(raw_x.*, limits.lo_x, limits.hi_x, dim_x);
    const new_y = rubberBand(raw_y.*, limits.lo_y, limits.hi_y, dim_y);

    const applied_dx = new_x - camera.offset_x;
    const applied_dy = new_y - camera.offset_y;

    camera.offset_x = new_x;
    camera.offset_y = new_y;

    return .{
        .applied_dx = applied_dx,
        .applied_dy = applied_dy,
        .offset_x = @intFromFloat(@round(camera.offset_x)),
        .offset_y = @intFromFloat(@round(camera.offset_y)),
    };
}

/// Rounded offset for the existing integer IPC representation. Rendering uses f64.
pub fn appliedOffset(camera: Camera) Offset {
    return .{
        .x = @intFromFloat(@round(camera.offset_x)),
        .y = @intFromFloat(@round(camera.offset_y)),
    };
}

/// Convert a layout (screen) position to world coordinates.
pub fn layoutToWorld(
    lx: i32,
    ly: i32,
    offset: Offset,
) Point {
    return .{
        .x = lx + offset.x,
        .y = ly + offset.y,
    };
}

/// Convert a world position to layout (screen) coordinates.
pub fn worldToLayout(
    wx: i32,
    wy: i32,
    offset: Offset,
) Point {
    return .{
        .x = wx - offset.x,
        .y = wy - offset.y,
    };
}

/// Compute the camera offset delta needed to bring the frame (wx,wy,w,h) into
/// the usable output area (usable_x,usable_y,usable_w,usable_h).
///
/// Prioritises making the top-left corner of the frame visible (titlebar and
/// controls). Maximized windows are aligned directly to the usable origin.
/// The returned delta is clamped so the resulting offset stays within `bounds`.
///
/// Returns a `RevealDelta` { dx, dy } to add to the camera offset.
pub fn reveal(
    wx: i32,
    wy: i32,
    w: i32,
    h: i32,
    usable_x: i32,
    usable_y: i32,
    usable_w: i32,
    usable_h: i32,
    current_offset: Offset,
    bounds: Bounds,
    is_maximized: bool,
) RevealDelta {
    // Current frame position in layout space
    const lx = wx - current_offset.x;
    const ly = wy - current_offset.y;
    const lx2 = lx + w;
    const ly2 = ly + h;

    const ux2 = usable_x + usable_w;
    const uy2 = usable_y + usable_h;

    var target_ox = current_offset.x;
    var target_oy = current_offset.y;

    if (is_maximized) {
        // Maximized windows align directly to usable origin
        target_ox = wx - usable_x;
        target_oy = wy - usable_y;
    } else {
        var shift_lx: i32 = 0;
        var shift_ly: i32 = 0;

        // X axis: prioritize top-left
        if (lx < usable_x) {
            shift_lx = usable_x - lx;
        } else if (lx2 > ux2) {
            shift_lx = ux2 - lx2;
            if (lx + shift_lx < usable_x) {
                shift_lx = usable_x - lx;
            }
        }

        // Y axis: prioritize top-left
        if (ly < usable_y) {
            shift_ly = usable_y - ly;
        } else if (ly2 > uy2) {
            shift_ly = uy2 - ly2;
            if (ly + shift_ly < usable_y) {
                shift_ly = usable_y - ly;
            }
        }

        // lx_new = lx + shift_lx => target_ox = current_ox - shift_lx
        target_ox = current_offset.x - shift_lx;
        target_oy = current_offset.y - shift_ly;
    }

    // Clamp target offset to bounds
    const max_x: i32 = @intFromFloat(bounds.max_x);
    const max_y: i32 = @intFromFloat(bounds.max_y);
    const new_ox = std.math.clamp(target_ox, -max_x, max_x);
    const new_oy = std.math.clamp(target_oy, -max_y, max_y);

    return .{
        .dx = new_ox - current_offset.x,
        .dy = new_oy - current_offset.y,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
