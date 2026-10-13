// State transitions for a `.toggle` widget — identical shape to
// checkbox.zig's `toggle`, kept separate since the two carry unrelated
// visuals (a pill thumb vs. a checked square; see layout.zig's ToggleData).
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;

const Renderer = @import("../paint.zig").Renderer;
const theme = @import("../theme.zig");
const Rect = @import("field.zig").Rect;
const sdf = @import("../sdf.zig");
const text = @import("../text.zig");

/// Natural switch size, shared by widget trees (measure.zig) and hand-laid panels.
pub const width: f32 = 36;
pub const height: f32 = 20;

pub const Options = struct {
    on: bool,
    style: @FieldType(layout.ToggleData, "style") = .standard,
    focused: bool = false,
    disabled: bool = false,
};

/// Shared switch painter for widget trees and hand-laid panels.
pub fn paint(r: *Renderer, box: Rect, opts: Options) void {
    const t = r.palette orelse theme.global;
    if (t.toggle_shaded) return paintShaded(r, box, opts, t);
    const radius: f32 = if (opts.style == .settings) t.toggle_radius else box.h / 2;
    var track: [4]f32 = if (opts.on) t.toggle_on orelse t.accent else t.toggle_track;
    var thumb = t.toggle_thumb orelse t.control_thumb;
    if (opts.disabled) {
        track[3] *= 0.5;
        thumb[3] *= 0.5;
    }
    r.fillRect(box.x, box.y, box.w, box.h, .{
        .color = track,
        .radius = radius,
        .border_width = if (opts.focused and !opts.disabled) 2 else 0,
        .border_color = t.controlFocusColor(),
    });
    const inset: f32 = 2;
    const side = @max(0, box.h - inset * 2);
    const x = if (opts.on) box.x + box.w - inset - side else box.x + inset;
    r.fillRect(x, box.y + inset, side, side, .{ .color = thumb, .radius = if (opts.style == .settings) t.toggle_thumb_radius else side / 2 });
}

/// Recessed track and raised knob, contained in the control's damage bounds.
fn paintShaded(r: *Renderer, box: Rect, opts: Options, t: theme.Theme) void {
    if (box.w <= 0 or box.h <= 0) return;
    r.clean = false;
    const scale = r.scale;
    var left = box.x * scale;
    var top = box.y * scale;
    var right = (box.x + box.w) * scale;
    var bottom = (box.y + box.h) * scale;
    if (r.effectiveClip()) |clip| {
        left = @max(left, clip.x * scale);
        top = @max(top, clip.y * scale);
        right = @min(right, (clip.x + clip.w) * scale);
        bottom = @min(bottom, (clip.y + clip.h) * scale);
    }
    const x0: i32 = @intFromFloat(@floor(@max(0, left)));
    const y0: i32 = @intFromFloat(@floor(@max(0, top)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), right)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), bottom)));
    const radius = if (opts.style == .settings) t.toggle_radius else box.h / 2;
    const inset = box.h * 0.14;
    const side = box.h - 2 * inset;
    const thumb_x = if (opts.on) box.w - inset - side else inset;
    const thumb_radius = if (opts.style == .settings) t.toggle_thumb_radius else side / 2;
    const track = if (opts.on) t.toggle_on orelse t.accent else t.toggle_track;
    const thumb = t.toggle_thumb orelse t.control_thumb;
    const opacity: f32 = if (opts.disabled) 0.5 else 1;
    var py = y0;
    while (py < y1) : (py += 1) {
        const y = (@as(f32, @floatFromInt(py)) + 0.5) / scale - box.y;
        const vertical = std.math.clamp(y / box.h, 0, 1);
        var px = x0;
        while (px < x1) : (px += 1) {
            const x = (@as(f32, @floatFromInt(px)) + 0.5) / scale - box.x;
            const distance = sdf.sdRoundedBox(x, y, 0, 0, box.w, box.h, radius);
            const coverage = sdf.coverage(distance * scale);
            if (coverage <= 0) continue;
            // Dark upper lip fades into the track; the lower lip catches light.
            const rim = 1 - std.math.clamp(-distance / 1.4, 0, 1);
            var color = shade(track, -0.07 + 0.10 * vertical + rim * (-0.22 + 0.32 * vertical));
            // The knob casts a short, soft shadow down into the recess.
            const shadow_distance = sdf.sdRoundedBox(x, y, thumb_x, inset + 0.8, side, side, thumb_radius);
            const shadow = std.math.clamp(1 - shadow_distance / 1.6, 0, 1);
            color = shade(color, -0.24 * shadow * shadow);
            if (opts.focused and !opts.disabled) {
                const focus = sdf.coverage((distance + 2) * scale);
                color = mix(color, t.controlFocusColor(), 1 - focus);
            }
            const knob_distance = sdf.sdRoundedBox(x, y, thumb_x, inset, side, side, thumb_radius);
            const knob_coverage = sdf.coverage(knob_distance * scale);
            const knob_y = std.math.clamp((y - inset) / side, 0, 1);
            const knob_rim = 1 - std.math.clamp(-knob_distance / 0.7, 0, 1);
            const knob = shade(thumb, 0.10 * (1 - knob_y) - 0.04 * knob_y - 0.09 * knob_rim * knob_y);
            // Mix premultiplied layers before applying disabled opacity once.
            const alpha = knob[3] * knob_coverage;
            const out_alpha = alpha + color[3] * (1 - alpha);
            if (out_alpha <= 0) continue;
            text.blendPixel(&r.pixels[@intCast(py * r.width + px)], .{
                .r = (knob[0] * alpha + color[0] * color[3] * (1 - alpha)) / out_alpha,
                .g = (knob[1] * alpha + color[1] * color[3] * (1 - alpha)) / out_alpha,
                .b = (knob[2] * alpha + color[2] * color[3] * (1 - alpha)) / out_alpha,
                .a = out_alpha * opacity,
            }, coverage);
        }
    }
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

pub fn toggle(widget: *Widget) void {
    switch (widget.kind) {
        .toggle => |*data| {
            if (data.disabled) return;
            data.on = !data.on;
            widget.markDirty();
            data.on_change(data.owner, data.id, data.on);
        },
        else => {},
    }
}

test "toggle routes changes to its own context and ID" {
    const Recorder = struct {
        last: bool = false,
        calls: u32 = 0,
        id: usize = 0,
        fn call(owner: ?*anyopaque, id: usize, value: bool) void {
            const self: *@This() = @ptrCast(@alignCast(owner.?));
            self.last = value;
            self.calls += 1;
            self.id = id;
        }
    };
    var first = Recorder{};
    var second = Recorder{};
    var one = Widget{ .kind = .{ .toggle = .{ .on = false, .owner = &first, .id = 12, .on_change = Recorder.call } } };
    var two = Widget{ .kind = .{ .toggle = .{ .on = false, .owner = &second, .id = 34, .on_change = Recorder.call } } };
    one.needs_layout = false;
    toggle(&one);
    toggle(&two);
    toggle(&one);
    try std.testing.expect(!one.kind.toggle.on);
    try std.testing.expect(one.needs_layout);
    try std.testing.expectEqual(@as(u32, 2), first.calls);
    try std.testing.expectEqual(@as(usize, 12), first.id);
    try std.testing.expect(!first.last);
    try std.testing.expectEqual(@as(u32, 1), second.calls);
    try std.testing.expectEqual(@as(usize, 34), second.id);
    try std.testing.expect(second.last);
    two.kind.toggle.disabled = true;
    toggle(&two);
    try std.testing.expect(two.kind.toggle.on);
    try std.testing.expectEqual(@as(u32, 1), second.calls);
}
