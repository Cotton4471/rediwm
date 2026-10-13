// Pointer-to-value mapping for a `.slider` widget. Geometry mirrors
// paint.zig's `paintSlider` — the whole widget rect is the track, so the
// value is a linear map of the pointer's x across `computed_x .. +width`.
const std = @import("std");
const anim = @import("../anim.zig");
const layout = @import("../layout.zig");
const scrollbar = @import("scrollbar.zig");
const Widget = layout.Widget;
const Renderer = @import("../paint.zig").Renderer;
const theme = @import("../theme.zig");
const sdf = @import("../sdf.zig");
const text = @import("../text.zig");

/// A recessed rail with a luminous fill and a reflective, round thumb.
/// All light stays inside the widget so partial repaints erase it completely.
pub fn paintShaded(widget: *const Widget, data: layout.SliderData, r: *Renderer) void {
    const t = r.palette orelse theme.global;
    const w = widget.computed_width;
    const h = widget.computed_height;
    if (w <= 2 or h <= 2) return;
    r.clean = false;
    const s = r.scale;
    var left = widget.computed_x * s;
    var top = widget.computed_y * s;
    var right = (widget.computed_x + w) * s;
    var bottom = (widget.computed_y + h) * s;
    if (r.effectiveClip()) |clip| {
        left = @max(left, clip.x * s);
        top = @max(top, clip.y * s);
        right = @min(right, (clip.x + clip.w) * s);
        bottom = @min(bottom, (clip.y + clip.h) * s);
    }
    const x0: i32 = @intFromFloat(@floor(@max(0, left)));
    const y0: i32 = @intFromFloat(@floor(@max(0, top)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), right)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), bottom)));
    const settings = data.style == .settings;
    const track_h = @min(h - 2, @max(0.5, (if (settings) t.slider_settings_track_height else t.slider_track_height) * (1 + t.slider_track_grow * data.feel.wide)));
    const diameter = @min(@min(w, h) - 2, @max(1, @min(t.slider_thumb_size, if (settings) t.slider_settings_thumb_height else t.slider_thumb_size)));
    const radius = diameter / 2;
    const fraction = if (data.max > data.min) std.math.clamp((data.value - data.min) / (data.max - data.min), 0, 1) else 0;
    const cx = std.math.clamp(fraction * w, radius + 1, w - radius - 1);
    const cy = h / 2;
    const highlight = t.slider_highlight orelse t.control_thumb;
    const intensity = std.math.clamp(data.feel.accent, 0, 1);
    var py = y0;
    while (py < y1) : (py += 1) {
        const y = (@as(f32, @floatFromInt(py)) + 0.5) / s - widget.computed_y;
        var px = x0;
        while (px < x1) : (px += 1) {
            const x = (@as(f32, @floatFromInt(px)) + 0.5) / s - widget.computed_x;
            const pixel = &r.pixels[@intCast(py * r.width + px)];
            const dx = x - cx;
            const dy = y - cy;
            const rail = sdf.sdRoundedBox(x, y, 0, cy - track_h / 2, w, track_h, track_h / 2);
            const fill = sdf.sdRoundedBox(x, y, 0, cy - track_h / 2, cx, track_h, track_h / 2);
            // A warm halo along the filled rail, brightest beside the knob.
            const tip = falloff(dx / (radius * 3));
            const edge_fade = std.math.clamp(@min(@min(x, w - x), @min(y, h - y)), 0, 1);
            const halo = std.math.clamp(1 - @max(0, fill) / 3, 0, 1);
            if (fraction > 0) blend(pixel, t.accent, halo * halo * (0.12 + 0.16 * tip + 0.10 * intensity) * edge_fade);
            const rail_y = std.math.clamp((dy + track_h / 2) / track_h, 0, 1);
            blend(pixel, shade(t.slider_track, -0.24 + 0.32 * rail_y), sdf.coverage(rail * s));
            if (fraction > 0) {
                const streak = falloff((dy + track_h * 0.16) / (track_h * 0.38));
                const gold = mix(t.accent, highlight, 0.18 + 0.50 * streak + 0.25 * tip);
                blend(pixel, gold, sdf.coverage(fill * s));
            }
            const shadow = @sqrt(dx * dx + (dy - 1) * (dy - 1)) - radius;
            blend(pixel, .{ 0, 0, 0, 0.28 }, std.math.clamp(1 - shadow / 1.5, 0, 1) * edge_fade);
            const distance = @sqrt(dx * dx + dy * dy) - radius;
            const coverage = sdf.coverage(distance * s);
            if (coverage <= 0) continue;
            const nx = dx / radius;
            const ny = dy / radius;
            const nz = @sqrt(@max(0, 1 - nx * nx - ny * ny));
            const light = std.math.clamp(-0.45 * nx - 0.55 * ny + 0.70 * nz, 0, 1);
            var knob = shade(t.accent, -0.48 + 0.68 * light);
            // Broad upper-left reflection and a smaller lower-right glint.
            const specular = falloff((nx + 0.32) / 0.48) * falloff((ny + 0.42) / 0.43);
            const glint = falloff((nx - 0.40) / 0.30) * falloff((ny - 0.57) / 0.25);
            knob = mix(knob, highlight, @min(1, 0.95 * specular + 0.70 * glint));
            const rim = 1 - std.math.clamp(-distance / 1.2, 0, 1);
            knob = mix(knob, highlight, rim * (0.50 + 0.35 * light));
            blend(pixel, knob, coverage);
        }
    }
}

fn falloff(value: f32) f32 {
    const v = @max(0, 1 - value * value);
    return v * v;
}

fn mix(a: [4]f32, b: [4]f32, amount: f32) [4]f32 {
    var result: [4]f32 = undefined;
    for (&result, a, b) |*out, start, end| out.* = start + (end - start) * amount;
    return result;
}

fn shade(color: [4]f32, amount: f32) [4]f32 {
    const light: f32 = if (amount > 0) 1 else 0;
    return mix(color, .{ light, light, light, color[3] }, @abs(amount));
}

fn blend(pixel: *u32, color: [4]f32, coverage: f32) void {
    text.blendPixel(pixel, .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] }, coverage);
}

fn snap(value: f32, min: f32, max: f32, step: f32) f32 {
    const clamped = std.math.clamp(value, min, max);
    if (step <= 0) return clamped;
    const steps = @round((clamped - min) / step);
    return std.math.clamp(min + steps * step, min, max);
}

pub fn beginDrag(widget: *Widget, pointer_x: f32) void {
    switch (widget.kind) {
        .slider => |*data| {
            data.dragging = true;
            setFromPointer(widget, pointer_x);
        },
        else => {},
    }
}

pub fn dragTo(widget: *Widget, pointer_x: f32) void {
    switch (widget.kind) {
        .slider => |data| if (data.dragging) setFromPointer(widget, pointer_x),
        else => {},
    }
}

pub fn endDrag(widget: *Widget) void {
    switch (widget.kind) {
        .slider => |*data| data.dragging = false,
        else => {},
    }
}

/// A slider's value readout: its text in a rounded label that lights up while
/// the slider is dragged (`stepFeedback` finds it with `findPill`). Callers pick
/// the font and resting colour and give it a width that fits the longest value,
/// or the label grows and shrinks as the digits change.
pub fn valuePill(content: []const u8, font_size: f32, color: [4]f32) Widget {
    return .{
        .kind = .{ .text = .{ .content = content, .font_size = font_size, .color = color, .pill = true } },
        .min_width = 48,
    };
}

/// What a rebuilt tree needs to keep each named slider looking as it did: a
/// drag's save rebuilds the page the moment the button is released, and without
/// this the track would snap to rest under a pointer that never left it.
pub const Saved = struct {
    pub const capacity = 24;
    count: usize = 0,
    names: [capacity][]const u8 = undefined,
    feel: [capacity]scrollbar.Appearance = undefined,
    glow: [capacity]anim.Anim = undefined,
    observed: [capacity]f32 = undefined,
    hovered: [capacity]bool = undefined,
};

/// Records the feedback of every named slider under `root`. Unnamed sliders
/// have nothing to be matched by and start fresh.
pub fn capture(root: *const Widget, saved: *Saved) void {
    switch (root.kind) {
        .slider => |data| if (root.name) |name| {
            if (saved.count < Saved.capacity) {
                const i = saved.count;
                saved.count += 1;
                saved.names[i] = name;
                saved.feel[i] = data.feel;
                saved.glow[i] = data.glow;
                saved.observed[i] = data.observed;
                saved.hovered[i] = data.hovered;
            }
        },
        else => {},
    }
    for (root.children) |*child| capture(child, saved);
}

/// Hands the recorded feedback to the sliders of a freshly built `root` that
/// have the same name. Returns the slider the pointer was over, so the input
/// dispatcher can be told it still is.
pub fn restore(root: *Widget, saved: *const Saved) ?*Widget {
    var hovered: ?*Widget = null;
    switch (root.kind) {
        .slider => |*data| if (root.name) |name| {
            for (saved.names[0..saved.count], 0..) |old, i| {
                if (!std.mem.eql(u8, old, name)) continue;
                data.feel = saved.feel[i];
                data.glow = saved.glow[i];
                data.observed = saved.observed[i];
                data.hovered = saved.hovered[i];
                // The new readout starts unlit whatever the old one showed.
                data.glow_shown = std.math.nan(f32);
                if (data.hovered) hovered = root;
                break;
            }
        },
        else => {},
    }
    for (root.children) |*child| {
        if (restore(child, saved)) |found| hovered = found;
    }
    return hovered;
}

/// The pointer entered or left the slider. The look follows from `step`.
pub fn setHovered(widget: *Widget, hover: bool) void {
    switch (widget.kind) {
        .slider => |*data| {
            if (data.hovered == hover) return;
            data.hovered = hover;
            widget.markPaintDirty();
        },
        else => {},
    }
}

/// The readout that belongs to `slider`: the first value pill under its
/// parent. Every slider is built with its readout in the same row or column
/// group, at most a header row down.
pub fn findPill(slider: *Widget) ?*Widget {
    return pillIn(slider.parent orelse return null, 3);
}

fn pillIn(widget: *Widget, depth: u8) ?*Widget {
    switch (widget.kind) {
        .text => |style| if (style.pill) return widget,
        else => {},
    }
    if (depth == 0) return null;
    for (widget.children) |*child| {
        if (pillIn(child, depth - 1)) |found| return found;
    }
    return null;
}

pub const Step = struct {
    /// An ease is in flight: frames are needed until it settles.
    active: bool = false,
    /// The hold after a change ends then.
    deadline: ?i64 = null,
};

/// Advances one slider's feedback with the scrollbar's own rules, so the two
/// match: hover and drag tint toward the accent and thicken the track, and a
/// change leaves a faint tint for a moment. The readout pill follows the drag
/// alone. Repaints whatever drawn state changed, so an idle slider costs nothing.
pub fn stepFeedback(widget: *Widget, now_ms: i64) Step {
    const data = switch (widget.kind) {
        .slider => |*data| data,
        else => return .{},
    };
    const moved = !std.math.isNan(data.observed) and data.value != data.observed;
    data.observed = data.value;
    if (data.feel.step(now_ms, moved, data.hovered, data.dragging, true)) {
        widget.markPaintDirty();
        anim.observeNoteChanged();
    }

    const target: f32 = if (data.dragging) 1 else 0;
    if (anim.reducedMotion() or !anim.enabled()) {
        data.glow.cancel(target);
    } else if (data.glow.to != target) {
        data.glow.retarget(now_ms, target, 180, .out_cubic);
    }
    const glow = data.glow.value(now_ms);
    const glow_settled = data.glow.settled(now_ms);
    if (glow != data.glow_shown) {
        data.glow_shown = glow;
        if (findPill(widget)) |pill| {
            pill.kind.text.glow = glow;
            pill.markPaintDirty();
            anim.observeNoteChanged();
        }
    }

    const active = data.feel.active or !glow_settled;
    if (active) anim.observeNoteActive(now_ms, now_ms);
    return .{ .active = active, .deadline = data.feel.deadline };
}

pub fn setFromPointer(widget: *Widget, pointer_x: f32) void {
    switch (widget.kind) {
        .slider => |*data| {
            const w = widget.computed_width;
            const t = if (w > 0) std.math.clamp((pointer_x - widget.computed_x) / w, 0, 1) else 0;
            const raw = data.min + t * (data.max - data.min);
            const value = snap(raw, data.min, data.max, data.step);
            if (value == data.value) return;
            data.value = value;
            widget.markDirty();
            data.on_change(data.owner, data.id, value);
        },
        else => {},
    }
}

test "setFromPointer maps position across the widget's own width" {
    const Recorder = struct {
        var last: f32 = 0;
        fn call(_: ?*anyopaque, _: usize, v: f32) void {
            last = v;
        }
    };
    var widget = Widget{ .kind = .{ .slider = .{ .value = 0, .min = -1, .max = 1, .step = 0.1, .on_change = &Recorder.call } } };
    widget.computed_x = 0;
    widget.computed_width = 100;

    setFromPointer(&widget, 75);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), widget.kind.slider.value, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), Recorder.last, 1e-3);
}

test "setFromPointer clamps outside the track and snaps to step" {
    var widget = Widget{ .kind = .{ .slider = .{ .value = 0, .min = 0, .max = 10, .step = 5, .on_change = &struct {
        fn call(_: ?*anyopaque, _: usize, _: f32) void {}
    }.call } } };
    widget.computed_x = 0;
    widget.computed_width = 100;

    setFromPointer(&widget, 999);
    try std.testing.expectEqual(@as(f32, 10), widget.kind.slider.value);

    setFromPointer(&widget, 42);
    try std.testing.expectEqual(@as(f32, 5), widget.kind.slider.value);
}

test "hover and drag light the slider, and only a drag lights its value pill" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });

    const noop = struct {
        fn call(_: ?*anyopaque, _: usize, _: f32) void {}
    }.call;
    var children = [_]Widget{
        .{ .kind = .{ .slider = .{ .value = 0.5, .min = 0, .max = 1, .on_change = &noop } } },
        valuePill("50%", 12, .{ 0.5, 0.5, 0.5, 1 }),
    };
    var row: Widget = .{ .kind = .container, .children = &children };
    row.linkParents();
    const slider = &children[0];
    const pill = &children[1];
    try std.testing.expect(findPill(slider) == pill);

    // A fresh slider is at rest and idle.
    try std.testing.expect(!stepFeedback(slider, 0).active);
    try std.testing.expectEqual(@as(f32, 0), slider.kind.slider.feel.accent);

    // Hovering tints and thickens the track, but leaves the pill alone.
    setHovered(slider, true);
    _ = stepFeedback(slider, 10);
    try std.testing.expect(stepFeedback(slider, 100).active);
    _ = stepFeedback(slider, 400);
    try std.testing.expectEqual(@as(f32, 1), slider.kind.slider.feel.accent);
    try std.testing.expectEqual(@as(f32, 1), slider.kind.slider.feel.wide);
    try std.testing.expectEqual(@as(f32, 0), pill.kind.text.glow);

    // Dragging lights the pill, and releasing lets it fade again.
    beginDrag(slider, 0.0);
    _ = stepFeedback(slider, 500);
    _ = stepFeedback(slider, 800);
    try std.testing.expectEqual(@as(f32, 1), pill.kind.text.glow);
    endDrag(slider);
    _ = stepFeedback(slider, 900);
    _ = stepFeedback(slider, 1200);
    try std.testing.expectEqual(@as(f32, 0), pill.kind.text.glow);

    // Leaving and then changing the value leaves only the faint hold.
    setHovered(slider, false);
    slider.kind.slider.value = 0.8;
    _ = stepFeedback(slider, 2000);
    _ = stepFeedback(slider, 2300);
    try std.testing.expectEqual(@as(f32, 0.35), slider.kind.slider.feel.accent);
    try std.testing.expect(stepFeedback(slider, 2300).deadline != null);
    _ = stepFeedback(slider, 2500);
    _ = stepFeedback(slider, 2800);
    try std.testing.expectEqual(@as(f32, 0), slider.kind.slider.feel.accent);
    try std.testing.expect(!stepFeedback(slider, 2800).active);
}
