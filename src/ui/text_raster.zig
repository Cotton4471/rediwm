//! Glyph rasters (cached, italic and colour bitmaps) and blending them into premultiplied ARGB.

const gpa = @import("memory").gpa;
const text = @import("text.zig");
const c = text.c;
const Color = text.Color;
const Face = text.Face;
const load_flags = text.load_flags;
const color_load_flags = text.color_load_flags;
const GlyphKey = text.GlyphKey;
const CachedGlyph = text.CachedGlyph;

pub fn copyBitmapRows(bitmap: c.FT_Bitmap, cols: i32, rows: i32, bpp: i32) ?[]u8 {
    if (cols <= 0 or rows <= 0) return null;
    const count: usize = @intCast(cols * rows * bpp);
    const copy = gpa.alloc(u8, count) catch return null;
    const pitch: i32 = bitmap.pitch;
    var row: i32 = 0;
    while (row < rows) : (row += 1) {
        // A negative pitch means FreeType handed back a bottom-up bitmap;
        // either way row 0 of the copy is the top row.
        const source_offset = @as(isize, row) * @as(isize, pitch);
        const source: [*]const u8 = @ptrCast(bitmap.buffer + @as(usize, @intCast(if (pitch < 0) source_offset + @as(isize, rows - 1) * -@as(isize, pitch) else source_offset)));
        const dest_off: usize = @intCast(row * cols * bpp);
        @memcpy(copy[dest_off..][0..@intCast(cols * bpp)], source[0..@intCast(cols * bpp)]);
    }
    return copy;
}

pub fn scaleBgra(src: []const u8, src_w: i32, src_h: i32, dst_w: i32, dst_h: i32) ?[]u8 {
    const sw: usize = @intCast(src_w);
    const sh: usize = @intCast(src_h);
    const dw: usize = @intCast(dst_w);
    const dh: usize = @intCast(dst_h);
    const dst = gpa.alloc(u8, dw * dh * 4) catch return null;
    if (src_w == dst_w and src_h == dst_h) {
        @memcpy(dst, src[0 .. dw * dh * 4]);
        return dst;
    }
    var y: usize = 0;
    while (y < dh) : (y += 1) {
        const sy = @as(f32, @floatFromInt(y)) * @as(f32, @floatFromInt(src_h)) / @as(f32, @floatFromInt(dst_h));
        const y0: usize = @min(@as(usize, @intFromFloat(@floor(sy))), sh - 1);
        const y1: usize = @min(y0 + 1, sh - 1);
        const fy = sy - @as(f32, @floatFromInt(y0));
        var x: usize = 0;
        while (x < dw) : (x += 1) {
            const sx = @as(f32, @floatFromInt(x)) * @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(dst_w));
            const x0: usize = @min(@as(usize, @intFromFloat(@floor(sx))), sw - 1);
            const x1: usize = @min(x0 + 1, sw - 1);
            const fx = sx - @as(f32, @floatFromInt(x0));
            const dst_i = (y * dw + x) * 4;
            var ch: usize = 0;
            while (ch < 4) : (ch += 1) {
                const s00 = @as(f32, @floatFromInt(src[(y0 * sw + x0) * 4 + ch]));
                const s10 = @as(f32, @floatFromInt(src[(y0 * sw + x1) * 4 + ch]));
                const s01 = @as(f32, @floatFromInt(src[(y1 * sw + x0) * 4 + ch]));
                const s11 = @as(f32, @floatFromInt(src[(y1 * sw + x1) * 4 + ch]));
                const v = s00 * (1 - fx) * (1 - fy) + s10 * fx * (1 - fy) + s01 * (1 - fx) * fy + s11 * fx * fy;
                dst[dst_i + ch] = @intFromFloat(@max(0, @min(v + 0.5, 255)));
            }
        }
    }
    return dst;
}

pub fn glyphBitmap(face: *Face, face_id: u32, index: u32, italic: bool) ?CachedGlyph {
    const slant = italic and !face.color;
    const key = GlyphKey{ .face = face_id, .size = face.set_size, .index = index, .italic = slant };
    if (text.glyph_cache.get(key)) |cached| return cached;

    // Manrope has no italic face. Slant the outline after hinting, keeping
    // advances and baselines intact, and restore the shared face immediately.
    var matrix: c.FT_Matrix = .{ .xx = 65536, .xy = 13930, .yx = 0, .yy = 65536 };
    if (slant) c.FT_Set_Transform(face.ft_face, &matrix, null);
    defer if (slant) c.FT_Set_Transform(face.ft_face, null, null);
    const flags: c_int = if (face.color) color_load_flags else load_flags;
    if (c.FT_Load_Glyph(face.ft_face, index, flags) != 0) return null;
    if (c.FT_Render_Glyph(face.ft_face.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0) return null;

    const glyph_slot = face.ft_face.*.glyph;
    const bitmap = glyph_slot.*.bitmap;
    const cols: i32 = @intCast(bitmap.width);
    const rows: i32 = @intCast(bitmap.rows);

    var pixels: []u8 = &.{};
    var out_cols = cols;
    var out_rows = rows;
    var out_left = glyph_slot.*.bitmap_left;
    var out_top = glyph_slot.*.bitmap_top;
    var is_color = false;

    if (bitmap.pixel_mode == c.FT_PIXEL_MODE_BGRA and cols > 0 and rows > 0) {
        const src = copyBitmapRows(bitmap, cols, rows, 4) orelse return null;
        is_color = true;
        const want_px: i32 = @max(1, @as(i32, @intCast(@divTrunc(face.set_size + 32, 64))));
        if (rows != want_px) {
            const dst_h = want_px;
            const dst_w: i32 = @max(1, @divTrunc(cols * want_px, rows));
            if (scaleBgra(src, cols, rows, dst_w, dst_h)) |scaled| {
                gpa.free(src);
                pixels = scaled;
                out_cols = dst_w;
                out_rows = dst_h;
                out_left = @divTrunc(glyph_slot.*.bitmap_left * dst_w, cols);
                out_top = @divTrunc(glyph_slot.*.bitmap_top * dst_h, rows);
            } else {
                pixels = src;
            }
        } else {
            pixels = src;
        }
    } else if (bitmap.pixel_mode == c.FT_PIXEL_MODE_GRAY and cols > 0 and rows > 0) {
        pixels = copyBitmapRows(bitmap, cols, rows, 1) orelse &.{};
    }

    const cached = CachedGlyph{
        .pixels = pixels,
        .cols = if (pixels.len == 0) 0 else out_cols,
        .rows = if (pixels.len == 0) 0 else out_rows,
        .left = out_left,
        .top = out_top,
        .color = is_color,
    };
    text.glyph_cache.put(gpa, key, cached) catch {
        if (pixels.len > 0) gpa.free(pixels);
        return .{ .pixels = &.{}, .cols = 0, .rows = 0, .left = cached.left, .top = cached.top };
    };
    return cached;
}

pub fn snap26_6(value: c.FT_Pos) i32 {
    return @intCast(@divFloor(value + 32, 64));
}

pub fn blendBitmap(
    pixels: []u32,
    width: i32,
    height: i32,
    clip_x0: i32,
    clip_y0: i32,
    clip_x1: i32,
    clip_y1: i32,
    origin_x: i32,
    origin_y: i32,
    glyph: CachedGlyph,
    color: Color,
) void {
    const x_start = @max(clip_x0, @max(0, origin_x));
    const y_start = @max(clip_y0, @max(0, origin_y));
    const x_end = @min(@min(clip_x1, width), origin_x + glyph.cols);
    const y_end = @min(@min(clip_y1, height), origin_y + glyph.rows);

    var py = y_start;
    while (py < y_end) : (py += 1) {
        const source_row: usize = @intCast((py - origin_y) * glyph.cols);
        var px = x_start;
        while (px < x_end) : (px += 1) {
            const value = glyph.pixels[source_row + @as(usize, @intCast(px - origin_x))];
            if (value == 0) continue;
            blendPixel(&pixels[@intCast(py * width + px)], color, @as(f32, @floatFromInt(value)) / 255.0);
        }
    }
}

pub fn blendColorBitmap(
    pixels: []u32,
    width: i32,
    height: i32,
    clip_x0: i32,
    clip_y0: i32,
    clip_x1: i32,
    clip_y1: i32,
    origin_x: i32,
    origin_y: i32,
    glyph: CachedGlyph,
    color_a: f32,
) void {
    if (color_a <= 0) return;
    const x_start = @max(clip_x0, @max(0, origin_x));
    const y_start = @max(clip_y0, @max(0, origin_y));
    const x_end = @min(@min(clip_x1, width), origin_x + glyph.cols);
    const y_end = @min(@min(clip_y1, height), origin_y + glyph.rows);

    var py = y_start;
    while (py < y_end) : (py += 1) {
        const source_row: usize = @intCast((py - origin_y) * glyph.cols * 4);
        var px = x_start;
        while (px < x_end) : (px += 1) {
            const off = source_row + @as(usize, @intCast(px - origin_x)) * 4;
            const src_b = glyph.pixels[off];
            const src_g = glyph.pixels[off + 1];
            const src_r = glyph.pixels[off + 2];
            const src_a = glyph.pixels[off + 3];
            if (src_a == 0) continue;
            blendColorPixel(&pixels[@intCast(py * width + px)], src_r, src_g, src_b, src_a, color_a);
        }
    }
}

pub fn blendColorPixel(destination: *u32, src_r: u8, src_g: u8, src_b: u8, src_a: u8, color_a: f32) void {
    const sa = @as(f32, @floatFromInt(src_a)) / 255.0 * color_a;
    const sr = @as(f32, @floatFromInt(src_r)) / 255.0 * color_a;
    const sg = @as(f32, @floatFromInt(src_g)) / 255.0 * color_a;
    const sb = @as(f32, @floatFromInt(src_b)) / 255.0 * color_a;
    const inverse = 1.0 - sa;
    const value = destination.*;
    const da = @as(f32, @floatFromInt((value >> 24) & 0xff)) / 255.0;
    const dr = @as(f32, @floatFromInt((value >> 16) & 0xff)) / 255.0;
    const dg = @as(f32, @floatFromInt((value >> 8) & 0xff)) / 255.0;
    const db = @as(f32, @floatFromInt(value & 0xff)) / 255.0;
    const a = sa + da * inverse;
    const r = sr + dr * inverse;
    const g = sg + dg * inverse;
    const b = sb + db * inverse;
    destination.* = (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b);
}

pub inline fn blendPixel(destination: *u32, color: Color, coverage_a: f32) void {
    const value = destination.*;
    const sa = color.a * coverage_a;
    const inverse = 1.0 - sa;
    const da = @as(f32, @floatFromInt((value >> 24) & 0xff)) / 255.0;
    const dr = @as(f32, @floatFromInt((value >> 16) & 0xff)) / 255.0;
    const dg = @as(f32, @floatFromInt((value >> 8) & 0xff)) / 255.0;
    const db = @as(f32, @floatFromInt(value & 0xff)) / 255.0;
    const a = sa + da * inverse;
    const r = color.r * sa + dr * inverse;
    const g = color.g * sa + dg * inverse;
    const b = color.b * sa + db * inverse;
    destination.* = (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b);
}

// Rounds like @round for the [0,1] inputs this takes, without the call into
// compiler_rt's roundf that @round compiles to on a baseline x86_64 target
// (no SSE4.1 roundss). It runs four times per blended pixel, so that call
// showed up as ~15% of a start menu frame.
pub inline fn byte(value: f32) u32 {
    return @intFromFloat(@max(0, @min(value, 1)) * 255 + 0.5);
}

pub fn devicePixels(logical: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(logical)) * scale));
}
