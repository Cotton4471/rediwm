//! UI paint tests.

const std = @import("std");
const layout = @import("layout.zig");
const Widget = layout.Widget;
const RectStyle = layout.RectStyle;
const TextStyle = layout.TextStyle;
const overPremultiplied = @import("paint_image.zig").overPremultiplied;
const boxSample = @import("paint_image.zig").boxSample;
const blendPremultipliedPixel = @import("paint_image.zig").blendPremultipliedPixel;
const paintButton = @import("paint_widgets.zig").paintButton;
const paintTextInput = @import("paint_widgets.zig").paintTextInput;
const intersectClip = @import("paint_widgets.zig").intersectClip;
const anim = @import("paint.zig").anim;
const text_mod = @import("paint.zig").text_mod;
const theme = @import("paint.zig").theme;
const ui_input = @import("paint.zig").ui_input;
const field_widget = @import("paint.zig").field_widget;
const ClipRect = @import("paint.zig").ClipRect;
const Image = @import("paint.zig").Image;
const RoundedFill = @import("paint.zig").RoundedFill;
const blendConstOver = @import("paint.zig").blendConstOver;
const Renderer = @import("paint.zig").Renderer;
const toColor = @import("paint.zig").toColor;
const blendPixel = @import("paint.zig").blendPixel;
const paint = @import("paint.zig").paint;
const paintTree = @import("paint.zig").paintTree;
const byte = @import("paint.zig").byte;

test "scroll underlay paints beneath rows, which skip their own fill when told to" {
    const Hook = struct {
        fn paint(_: ?*anyopaque, scroll: *const Widget, r: *Renderer) void {
            r.fillRect(scroll.computed_x, scroll.computed_y, scroll.computed_width, 10, .{ .color = .{ 1, 0, 0, 1 } });
        }
    };
    var pixels = [_]u32{0} ** (20 * 20);
    var r = Renderer.init(&pixels, 20, 20, 1);
    var row = Widget{
        .kind = .{ .row = .{ .selected = true, .underlay = true } },
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 20,
        .computed_height = 20,
    };
    var kids = [_]Widget{row};
    var scroll = Widget{
        .kind = .{ .scroll_container = .{ .underlay = .{ .owner = null, .paint = Hook.paint } } },
        .children = &kids,
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 20,
        .computed_height = 20,
    };
    paintTree(&scroll, &r);
    // The underlay's red band survives; the underlay row drew nothing over it.
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[5 * 20 + 5]);
    // Below the band nothing was drawn: an ordinary selected row would have.
    try std.testing.expectEqual(@as(u32, 0), pixels[15 * 20 + 10]);
    // A sidebar rect uses the same hook without becoming a scroll viewport.
    scroll.kind = .{ .rect = .{ .color = .{ 0, 0, 1, 1 } } };
    scroll.underlay = .{ .owner = null, .paint = Hook.paint };
    @memset(&pixels, 0);
    paintTree(&scroll, &r);
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[5 * 20 + 5]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[15 * 20 + 10]);
    scroll.kind = .{ .scroll_container = .{ .underlay = scroll.underlay } };
    scroll.underlay = null;
    row.kind.row.underlay = false;
    kids[0] = row;
    @memset(&pixels, 0);
    paintTree(&scroll, &r);
    try std.testing.expect(pixels[15 * 20 + 10] != 0);
}

test "fillRect paints solid color inside a device-pixel buffer" {
    var pixels = [_]u32{0} ** (10 * 10);
    var r = Renderer.init(&pixels, 10, 10, 1);
    r.fillRect(1, 1, 4, 4, .{ .color = .{ 1, 0, 0, 1 } });
    // Center of the fill should be fully opaque red; a corner outside it stays clear.
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[3 * 10 + 3]);
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
}

test "fillRect respects the active clip rect" {
    var pixels = [_]u32{0} ** (10 * 10);
    var r = Renderer.init(&pixels, 10, 10, 1);
    r.clip = .{ .x = 0, .y = 0, .w = 5, .h = 10 };
    r.fillRect(0, 0, 10, 10, .{ .color = .{ 1, 1, 1, 1 } });
    try std.testing.expect(pixels[5 * 10 + 2] != 0); // column 2: inside the 5px-wide clip
    try std.testing.expectEqual(@as(u32, 0), pixels[5 * 10 + 7]); // column 7: outside it
}

test "replacement fills preserve alpha, rounded corners and damage clips" {
    for ([_]f32{ 1, 1.5 }) |scale| {
        var pixels = [_]u32{0xffeeeeee} ** (30 * 30);
        var r = Renderer.init(&pixels, 30, 30, scale);
        const style: RectStyle = .{ .color = .{ 0.4, 0.2, 0.1, 0.5 }, .radius = 4, .replace = true };
        r.fillRect(2, 2, 16, 16, style);
        const centre: usize = @intFromFloat(10 * scale);
        try std.testing.expectEqual(@as(u32, 128), pixels[centre * 30 + centre] >> 24);
        try std.testing.expectEqual(@as(u32, 0xffeeeeee), pixels[0]);
        const corner: usize = @intFromFloat(2 * scale);
        try std.testing.expectEqual(@as(u32, 0xffeeeeee), pixels[corner * 30 + corner]);
        const expected = pixels;
        r.damage_clip = .{ .x = 8, .y = 8, .w = 4, .h = 4 };
        r.fillRect(2, 2, 16, 16, style);
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    }
}

test "rounded fill spans match per-pixel shading at fractional scales" {
    const cases = [_]struct { w: f32, h: f32, radius: f32, border: f32 }{
        .{ .w = 44, .h = 24, .radius = 8, .border = 1 },
        .{ .w = 24, .h = 44, .radius = 8, .border = 1 },
        .{ .w = 44, .h = 24, .radius = 0, .border = 0 },
        .{ .w = 44, .h = 24, .radius = 8, .border = 0.5 },
        .{ .w = 44, .h = 24, .radius = 2, .border = 4 },
        .{ .w = 44, .h = 24, .radius = 80, .border = 1 },
        .{ .w = 3, .h = 4, .radius = 1.5, .border = 1 },
        .{ .w = 3, .h = 4, .radius = 2, .border = 3 },
    };
    var actual: [96 * 96]u32 = undefined;
    var expected: [96 * 96]u32 = undefined;
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        for ([_]f32{ 2, 2.3 }) |origin| {
            for (cases) |case| {
                for ([_]u32{ 0, 0xff182430, 0x80402010 }) |background| {
                    for ([_]f32{ 0.09, 0.78, 1 }) |alpha| {
                        @memset(&actual, background);
                        @memset(&expected, background);
                        var renderer = Renderer.init(&actual, 96, 96, scale);
                        renderer.clean = background == 0;
                        // Exercise both uncut corners and a clip through them.
                        if (origin != 2) renderer.clip = .{ .x = 5.2, .y = 3.7, .w = 33.1, .h = 35.4 };
                        const style: RectStyle = .{
                            .color = .{ 0.2, 0.6, 0.9, alpha },
                            .radius = case.radius,
                            .border_width = case.border,
                            .border_color = .{ 0.8, 0.1, 0.3, 0.35 },
                        };
                        renderer.fillRect(origin, origin, case.w, case.h, style);
                        const shape: RoundedFill = .{
                            .box_x = origin * scale,
                            .box_y = origin * scale,
                            .box_w = case.w * scale,
                            .box_h = case.h * scale,
                            .radius = case.radius * scale,
                            .border = case.border * scale,
                            .fg = toColor(style.color),
                            .border_color = toColor(style.border_color),
                        };
                        var clip = ClipRect{ .x = origin, .y = origin, .w = case.w, .h = case.h };
                        clip = intersectClip(renderer.clip, clip);
                        const x0: usize = @intFromFloat(@floor(clip.x * scale));
                        const y0: usize = @intFromFloat(@floor(clip.y * scale));
                        const x1: usize = @intFromFloat(@ceil((clip.x + clip.w) * scale));
                        const y1: usize = @intFromFloat(@ceil((clip.y + clip.h) * scale));
                        // Empty logical clips can have a nonempty rounded pixel
                        // extent; match fillRect's device clipping convention.
                        for (y0..y1) |y| {
                            for (x0..x1) |x| {
                                shape.shade(&expected, y * 96 + x, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
                            }
                        }
                        for (actual, expected) |got, want| {
                            // Integer source-over and the float reference can
                            // differ by one quantization level, as above.
                            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                                const a: i32 = @intCast((got >> shift) & 255);
                                const b: i32 = @intCast((want >> shift) & 255);
                                try std.testing.expect(@abs(a - b) <= 1);
                            }
                            try std.testing.expect((got & 255) <= (got >> 24));
                            try std.testing.expect(((got >> 8) & 255) <= (got >> 24));
                            try std.testing.expect(((got >> 16) & 255) <= (got >> 24));
                        }
                    }
                }
            }
        }
    }
}

test "prototype button states retain neutral premultiplied fills" {
    const saved = theme.global;
    defer theme.global = saved;
    theme.global = .{};
    var pixels = [_]u32{0} ** (30 * 30);
    var renderer = Renderer.init(&pixels, 30, 30, 1);
    const Callback = struct {
        fn call(_: ?*anyopaque, _: usize) void {}
    };
    const widget = Widget{ .kind = .container, .computed_width = 30, .computed_height = 30 };
    paintButton(&widget, .{ .label = "", .on_click = Callback.call }, &renderer);
    try std.testing.expectEqual(@as(u32, 0x0d0d0d0d), pixels[15 * 30 + 15]);
    @memset(&pixels, 0);
    paintButton(&widget, .{ .label = "", .on_click = Callback.call, .state = .hover }, &renderer);
    try std.testing.expectEqual(@as(u32, 0x14141414), pixels[15 * 30 + 15]);
    @memset(&pixels, 0);
    paintButton(&widget, .{ .variant = .ghost, .label = "", .on_click = Callback.call }, &renderer);
    try std.testing.expectEqual(@as(u32, 0), pixels[15 * 30 + 15]);
    @memset(&pixels, 0);
    paintButton(&widget, .{ .variant = .ghost, .label = "", .on_click = Callback.call, .state = .hover }, &renderer);
    try std.testing.expectEqual(@as(u32, 0x14141414), pixels[15 * 30 + 15]);
}

test "translucent interior blend matches the float path within a unit" {
    // The interior fast path and the edge/corner path meet along every fill's
    // border, so their results have to agree to the eye: check the integer
    // blend never drifts more than one 8-bit step from blendPixel's float.
    const alphas = [_]f32{ 0.06, 0.3, 0.5, 0.78, 0.95 };
    for (alphas) |a| {
        const color: text_mod.Color = .{ .r = 0.2, .g = 0.6, .b = 0.9, .a = a };
        const alpha8 = byte(color.a);
        const inv = 255 - alpha8;
        const premul = (alpha8 << 24) | (byte(color.r * color.a) << 16) |
            (byte(color.g * color.a) << 8) | byte(color.b * color.a);
        for ([_]u32{ 0x00000000, 0xff000000, 0xffffffff, 0x80402010, 0x7f7f7f7f }) |dst| {
            var reference = dst;
            blendPixel(&reference, color, 1);
            const fast = blendConstOver(dst, premul, inv);
            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                const want: i32 = @intCast((reference >> shift) & 0xff);
                const got: i32 = @intCast((fast >> shift) & 0xff);
                try std.testing.expect(@abs(want - got) <= 1);
            }
        }
    }
}

test "premultiplied blit matches the float path within a unit" {
    for ([_]u32{ 0x00000000, 0x40201008, 0x80402010, 0xff3366aa, 0xffffffff }) |sample| {
        for ([_]u32{ 0x00000000, 0xff000000, 0xffffffff, 0x9a123456 }) |dst| {
            var reference = dst;
            blendPremultipliedPixel(&reference, sample, 1);
            const fast = overPremultiplied(dst, sample);
            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                const want: i32 = @intCast((reference >> shift) & 0xff);
                const got: i32 = @intCast((fast >> shift) & 0xff);
                try std.testing.expect(@abs(want - got) <= 1);
            }
        }
    }
}

test "secret input widget never retains hidden or echo-on responses in run cache" {
    var bytes: [510]u8 = @splat(0);
    var field = @import("widgets/secret_input.zig").Input{ .storage = &bytes };
    defer field.clear();
    try std.testing.expect(field.insert("fixture-sensitive-response"));
    var pixels: [400 * 50]u32 = @splat(0);
    var renderer = Renderer.init(&pixels, 400, 50, 1);
    const before = text_mod.testingRunCacheCount();
    _ = field.paint(&renderer, 0, 0, 80, 42, 18, .{ .hidden = true, .caret = true, .placeholder = "" });
    _ = field.paint(&renderer, 0, 0, 80, 42, 18, .{ .hidden = false, .caret = true, .placeholder = "" });
    // And through the shared field, frame and all.
    _ = field_widget.paintSecret(&renderer, .{ .x = 0, .y = 0, .w = 400, .h = 50 }, .{ .size = .lg, .trailing = .reveal }, .{ .focused = true }, &field, "");
    _ = field_widget.paintSecret(&renderer, .{ .x = 0, .y = 0, .w = 400, .h = 50 }, .{ .size = .lg, .trailing = .reveal }, .{ .focused = true, .revealed = true }, &field, "");
    // Dotted masking: the caret keeps the field font's height, hidden or not.
    const box: field_widget.Rect = .{ .x = 0, .y = 0, .w = 400, .h = 50 };
    const dotted: field_widget.Options = .{ .size = .lg, .secret_dots = .{ .diameter = 0.46, .pitch = 1.05 } };
    const hidden = field_widget.paintSecret(&renderer, box, dotted, .{ .focused = true }, &field, "").caret.?;
    const clear = field_widget.paintSecret(&renderer, box, dotted, .{ .focused = true, .revealed = true }, &field, "").caret.?;
    try std.testing.expectEqual(clear.h, hidden.h);
    try std.testing.expectEqual(clear.y, hidden.y);
    try std.testing.expectEqual(before, text_mod.testingRunCacheCount());
}

// A partially scrolled row must retain the same glyph positions as the full row.
test "text clipping preserves layout at scroll edges" {
    for ([_]f32{ 1, 1.5 }) |scale| {
        var full: [240 * 90]u32 = @splat(0);
        var clipped: [240 * 90]u32 = @splat(0);
        var r = Renderer.init(&full, 240, 90, scale);
        const style: TextStyle = .{ .content = "Transmission label", .font_size = 16, .color = .{ 1, 1, 1, 1 } };
        r.drawText(4, 4, 140, 34, style);
        r.pixels = &clipped;
        r.clip = .{ .x = 18, .y = 20, .w = 90, .h = 12 };
        r.drawText(4, 4, 140, 34, style);
        const clip = r.textClip(r.clip).?;
        var ink: usize = 0;
        for (clipped, 0..) |pixel, i| {
            const x: i32 = @intCast(i % 240);
            const y: i32 = @intCast(i / 240);
            const inside = x >= clip.x and x < clip.x + clip.w and y >= clip.y and y < clip.y + clip.h;
            try std.testing.expectEqual(if (inside) full[i] else 0, pixel);
            if (pixel != 0) ink += 1;
        }
        try std.testing.expect(ink > 0);
    }
}

test "typing reveals text behind the gliding caret and preserves the suffix" {
    const saved_dispatcher = ui_input.active_dispatcher;
    defer ui_input.active_dispatcher = saved_dispatcher;
    const saved_config = ui_input.caret_config;
    defer ui_input.caret_config = saved_config;
    defer anim.setNowMs(null);
    ui_input.caret_config = .{ .motion_ms = 80 };

    for ([_]f32{ 1, 1.5 }) |scale| {
        for ([_][]const u8{ "ab", "abcd" }) |value| {
            var widget = Widget{ .kind = .{ .text_input = .{
                .value = try std.testing.allocator.dupe(u8, if (value.len == 2) "a" else "acd"),
                .placeholder = "",
                .cursor_pos = 1,
                .on_change = struct {
                    fn changed(_: ?*anyopaque, _: usize, _: []const u8) void {}
                }.changed,
            } }, .computed_width = 150, .computed_height = 40 };
            defer std.testing.allocator.free(widget.kind.text_input.value);
            var dispatcher = ui_input.Dispatcher{ .focused = &widget };
            ui_input.active_dispatcher = &dispatcher;
            var background: [240 * 90]u32 = @splat(0);
            var first = background;
            var middle = background;
            var complete = background;
            var r = Renderer.init(&background, 240, 90, scale);
            // Hide only the caret's ink so the comparison isolates the text.
            r.palette = theme.Theme{ .caret = .{ 0, 0, 0, 0 } };
            const frame = field_widget.paintFrame(&r, .{ .x = 0, .y = 0, .w = 150, .h = 40 }, .{}, .{ .focused = true });
            const start = try text_mod.measureWidthF("a", .manrope, frame.font_size, scale);
            const target = try text_mod.measureWidthF("ab", .manrope, frame.font_size, scale);
            dispatcher.caret.track(0, start);

            anim.setNowMs(1000);
            _ = try dispatcher.keyEvent(std.testing.allocator, .{ .char = "b" }, .{});
            r.pixels = &first;
            paintTextInput(&widget, widget.kind.text_input, &r);
            try std.testing.expect(dispatcher.caret.moving(1000));
            anim.setNowMs(1020);
            r.pixels = &middle;
            paintTextInput(&widget, widget.kind.text_input, &r);
            const mid = dispatcher.caret.offset(1020);
            try std.testing.expect(mid > start and mid < target);
            anim.setNowMs(1080);
            r.pixels = &complete;
            paintTextInput(&widget, widget.kind.text_input, &r);

            var hidden_ink: usize = 0;
            var suffix_ink: usize = 0;
            const suffix_x = @ceil(frame.text.x + target) * scale;
            for (complete, 0..) |pixel, i| {
                const x: f32 = @floatFromInt(i % 240);
                const start_x = @ceil(@floor(frame.text.x + start) * scale);
                const mid_x = @ceil(@floor(frame.text.x + mid) * scale);
                if (x >= start_x and x < suffix_x) {
                    try std.testing.expectEqual(background[i], first[i]);
                    if (pixel != background[i]) hidden_ink += 1;
                }
                if (x >= mid_x and x < suffix_x)
                    try std.testing.expectEqual(background[i], middle[i]);
                if (x >= suffix_x) {
                    try std.testing.expectEqual(pixel, first[i]);
                    try std.testing.expectEqual(pixel, middle[i]);
                    if (pixel != background[i]) suffix_ink += 1;
                }
            }
            try std.testing.expect(hidden_ink > 0);
            if (value.len > 2) try std.testing.expect(suffix_ink > 0);

            // Navigation cancels the reveal: existing text stays visible.
            dispatcher.caret.noteEdit(1100);
            try std.testing.expect(!dispatcher.caret.revealing);
        }
    }
}

test "smooth image sampling is exact at one to one, blends between pixels and shrinks flat colour unchanged" {
    const black: u32 = 0xff000000;
    const white: u32 = 0xffffffff;
    const checker = [_]u32{ black, white, white, black };
    const image: Image = .{ .pixels = &checker, .width = 2, .height = 2 };
    // Centred on a source pixel, one pixel wide: that pixel, untouched.
    try std.testing.expectEqual(black, boxSample(image, 0.5, 0.5, 1));
    try std.testing.expectEqual(white, boxSample(image, 1.5, 0.5, 1));
    // Halfway between two columns: an even mix (bilinear).
    try std.testing.expectEqual(@as(u32, 0xff808080), boxSample(image, 1.0, 0.5, 1));
    // The whole image averages to mid grey whatever the footprint around its centre.
    try std.testing.expectEqual(@as(u32, 0xff808080), boxSample(image, 1.0, 1.0, 2));

    // Shrinking a flat translucent image by 1.3 keeps its premultiplied colour,
    // also at the edge, where the footprint leaves the image.
    const flat = [_]u32{0x80402010} ** 16;
    const small: Image = .{ .pixels = &flat, .width = 4, .height = 4 };
    for ([_]f32{ 0.1, 0.5, 2, 3.9 }) |at| try std.testing.expectEqual(@as(u32, 0x80402010), boxSample(small, at, at, 1.3));

    // Placed 1:1 on a pixel boundary it reproduces the image.
    var pixels = [_]u32{0} ** 16;
    var r = Renderer.init(&pixels, 4, 4, 1);
    r.drawImageSmooth(1, 1, 2, 2, 0, image);
    try std.testing.expectEqual(black, pixels[1 * 4 + 1]);
    try std.testing.expectEqual(white, pixels[1 * 4 + 2]);
    try std.testing.expectEqual(white, pixels[2 * 4 + 1]);
    try std.testing.expectEqual(black, pixels[2 * 4 + 2]);
}
