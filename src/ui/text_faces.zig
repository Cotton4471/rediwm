//! Font faces: the FreeType library, the face table, fallback chains and coverage, weights and sizes.

const std = @import("std");
const gpa = @import("memory").gpa;
const font_fallback = @import("font_fallback.zig");
const log = std.log.scoped(.text);
const text = @import("text.zig");
const c = text.c;
const Font = text.Font;
const Face = text.Face;
const size_slots = text.size_slots;
const load_flags = text.load_flags;
const color_load_flags = text.color_load_flags;
const font_count = text.font_count;
const no_face = text.no_face;
const preferredSans = text.preferredSans;
const preferredMono = text.preferredMono;
const bundledWeight = text.bundledWeight;
const genericFamilyZ = text.genericFamilyZ;
const size26 = text.size26;
const coverageKey = text.coverageKey;

pub fn ensureLibrary() !void {
    if (text.ft_library == null and c.FT_Init_FreeType(&text.ft_library) != 0) return error.FreeTypeInitFailed;
}

pub fn ensureFaceTable() void {
    if (text.faces.items.len >= font_count) return;
    const fonts = [_]Font{ .manrope, .manrope_bold, .mono, .mono_bold, .manrope_heavy };
    for (fonts) |font| {
        text.faces.append(gpa, .{
            .source = .{ .bundled = font },
            .weight = bundledWeight(font),
        }) catch return;
    }
}

pub fn chainAppend(font: Font, id: u32) void {
    const ch = &text.chains[@intFromEnum(font)];
    for (ch.items) |existing| if (existing == id) return;
    ch.append(gpa, id) catch {};
}

pub fn ensureChain(font: Font) void {
    ensureFaceTable();
    const idx = @intFromEnum(font);
    if (text.chains[idx].items.len != 0) return;

    const preferred = switch (font) {
        .manrope, .manrope_bold, .manrope_heavy => preferredSans(),
        .mono, .mono_bold => preferredMono(),
    };
    const weight = bundledWeight(font);
    if (preferred.len > 0 and !font_fallback.isBundledFamily(preferred)) {
        if (font_fallback.matchFamily(gpa, preferred, weight)) |cand| {
            chainAppend(font, internFileFace(cand, weight));
        }
    }
    chainAppend(font, idx);
}

pub fn primaryId(font: Font) u32 {
    ensureChain(font);
    const items = text.chains[@intFromEnum(font)].items;
    return if (items.len == 0) @intFromEnum(font) else items[0];
}

pub fn internFileFace(cand: font_fallback.Candidate, weight: u32) u32 {
    for (text.faces.items, 0..) |f, i| {
        switch (f.source) {
            .file => |file| {
                if (file.index == cand.index and f.weight == weight and std.mem.eql(u8, file.path, cand.path)) {
                    cand.deinit(gpa);
                    return @intCast(i);
                }
            },
            .bundled => {},
        }
    }
    const path = cand.path;
    const index = cand.index;
    const color = cand.color;
    cand.discardCharset();
    text.faces.append(gpa, .{
        .source = .{ .file = .{ .path = path, .index = index } },
        .color = color,
        .weight = weight,
    }) catch {
        gpa.free(path);
        return 0;
    };
    log.debug("fallback face {s}#{d}", .{ path, index });
    return @intCast(text.faces.items.len - 1);
}

pub fn ensureLoaded(id: u32) !*Face {
    ensureFaceTable();
    if (id >= text.faces.items.len) return error.FontLoadFailed;
    const face = &text.faces.items[id];
    if (face.dead) return error.FontLoadFailed;
    if (face.hb_font != null) return face;
    try ensureLibrary();

    switch (face.source) {
        .bundled => |font| {
            const font_bytes = font.bytes();
            if (c.FT_New_Memory_Face(text.ft_library, @ptrCast(font_bytes.ptr), @intCast(font_bytes.len), 0, &face.ft_face) != 0) {
                face.dead = true;
                return error.FontLoadFailed;
            }
        },
        .file => |file| {
            if (c.FT_New_Face(text.ft_library, file.path.ptr, file.index, &face.ft_face) != 0) {
                face.dead = true;
                return error.FontLoadFailed;
            }
        },
    }
    errdefer {
        _ = c.FT_Done_Face(face.ft_face);
        face.ft_face = null;
        face.set_size = 0;
    }
    selectWeight(face.ft_face, face.weight);
    // hb-ft requires an initialized face size at construction.
    if (c.FT_Set_Char_Size(face.ft_face, 0, 64, 72, 72) != 0) {
        if (face.ft_face.*.num_fixed_sizes > 0) {
            _ = c.FT_Select_Size(face.ft_face, 0);
        } else return error.FontSizeFailed;
    }
    face.set_size = 64;
    const flags: c_int = if (face.color) color_load_flags else load_flags;
    // Initialize the variable font's lazy metrics before hb-ft caches its
    // first advance. Otherwise Manrope's first shaped glyph can get a
    // rounded fallback advance while later calls get fractional metrics.
    _ = c.FT_Load_Glyph(face.ft_face, 0, flags);
    const hb_font = c.hb_ft_font_create_referenced(face.ft_face) orelse return error.HarfBuzzFontFailed;
    c.hb_ft_font_set_load_flags(hb_font, flags);
    face.sizes[0] = .{ .size = 64, .ft_size = face.ft_face.*.size, .hb_font = hb_font, .used = 0 };
    face.size_count = 1;
    face.hb_font = hb_font;
    return face;
}

pub fn ensureFace(font: Font) !*Face {
    ensureFaceTable();
    return ensureLoaded(@intFromEnum(font));
}

pub fn faceHasChar(id: u32, cp: u32) bool {
    ensureFaceTable();
    if (id >= text.faces.items.len) return false;
    const face = &text.faces.items[id];
    if (face.dead) return false;
    const loaded = ensureLoaded(id) catch return false;
    return c.FT_Get_Char_Index(loaded.ft_face, cp) != 0;
}

pub fn findAndIntern(font: Font, cp: u32, color: bool) ?u32 {
    const cand = font_fallback.findCovering(gpa, genericFamilyZ(font), bundledWeight(font), cp, color) orelse return null;
    return internFileFace(cand, bundledWeight(font));
}

pub fn resolveChar(font: Font, cp: u32, want_color: bool) u32 {
    const primary = primaryId(font);
    if (want_color) {
        if (text.coverage.get(coverageKey(cp, true))) |id| {
            if (id != no_face) return id;
        } else if (findAndIntern(font, cp, true)) |id| {
            text.coverage.put(gpa, coverageKey(cp, true), id) catch {};
            return id;
        } else {
            text.coverage.put(gpa, coverageKey(cp, true), no_face) catch {};
        }
    }
    if (faceHasChar(primary, cp)) return primary;
    if (text.coverage.get(coverageKey(cp, false))) |id| {
        return if (id == no_face) primary else id;
    }
    if (findAndIntern(font, cp, false)) |id| {
        text.coverage.put(gpa, coverageKey(cp, false), id) catch {};
        return id;
    }
    text.coverage.put(gpa, coverageKey(cp, false), no_face) catch {};
    return primary;
}

pub const wght_tag: c.FT_ULong = (@as(c.FT_ULong, 'w') << 24) | (@as(c.FT_ULong, 'g') << 16) | (@as(c.FT_ULong, 'h') << 8) | @as(c.FT_ULong, 't');

// Manrope ships as a variable font whose fvar default (and OS/2 usWeightClass)
// is 200 (ExtraLight), not 400 (Regular). Left alone, FreeType instantiates
// that hairline-thin default, which is what made the compositor-drawn chrome
// (titlebars, control center, taskbar chip titles) look faint and blurry
// next to the statically-hinted JetBrains Mono clock. Pin variable axes to
// the requested design weight (400 for regular, 600 for bold/semibold);
// harmless no-op for the static mono faces.
pub fn selectWeight(face: c.FT_Face, target_weight: u32) void {
    var mm_var: [*c]c.FT_MM_Var = null;
    if (c.FT_Get_MM_Var(face, &mm_var) != 0) return;
    defer _ = c.FT_Done_MM_Var(text.ft_library, mm_var);

    var coords: [16]c.FT_Fixed = undefined;
    const num_axis = @min(@as(usize, mm_var.*.num_axis), coords.len);
    for (0..num_axis) |i| {
        const axis = mm_var.*.axis[i];
        coords[i] = if (axis.tag == wght_tag) @as(c.FT_Fixed, @as(i32, @intCast(target_weight)) << 16) else axis.def;
    }
    _ = c.FT_Set_Var_Design_Coordinates(face, @intCast(num_axis), &coords);
}

pub fn applySize(face: *Face, size: c.FT_F26Dot6) !void {
    if (face.set_size == size and face.hb_font != null) return;
    text.size_clock +%= 1;
    for (face.sizes[0..face.size_count]) |*slot| if (slot.size == size) {
        if (c.FT_Activate_Size(slot.ft_size) != 0) return error.FontSizeFailed;
        slot.used = text.size_clock;
        face.hb_font = slot.hb_font;
        face.set_size = size;
        return;
    };

    const previous = face.ft_face.*.size;
    var ft_size: c.FT_Size = null;
    if (c.FT_New_Size(face.ft_face, &ft_size) != 0) return error.FontSizeFailed;
    errdefer {
        _ = c.FT_Done_Size(ft_size);
        _ = c.FT_Activate_Size(previous);
    }
    if (c.FT_Activate_Size(ft_size) != 0) return error.FontSizeFailed;
    try setCharSize(face, size);
    const flags: c_int = if (face.color) color_load_flags else load_flags;
    // Same lazy-metrics warmup as ensureLoaded, at the size we will shape.
    _ = c.FT_Load_Glyph(face.ft_face, 0, flags);
    const hb_font = c.hb_ft_font_create_referenced(face.ft_face) orelse return error.HarfBuzzFontFailed;
    c.hb_ft_font_set_load_flags(hb_font, flags);

    const slot_index = if (face.size_count < size_slots) blk: {
        face.size_count += 1;
        break :blk face.size_count - 1;
    } else blk: {
        // The new size is active, so every stored one is safe to discard.
        var oldest: usize = 0;
        for (face.sizes[1..], 1..) |slot, i| {
            if (slot.used < face.sizes[oldest].used) oldest = i;
        }
        c.hb_font_destroy(face.sizes[oldest].hb_font);
        _ = c.FT_Done_Size(face.sizes[oldest].ft_size);
        break :blk oldest;
    };
    face.sizes[slot_index] = .{ .size = size, .ft_size = ft_size, .hb_font = hb_font, .used = text.size_clock };
    face.hb_font = hb_font;
    face.set_size = size;
}

pub fn setCharSize(face: *Face, size: c.FT_F26Dot6) !void {
    if (c.FT_Set_Char_Size(face.ft_face, 0, size, 72, 72) != 0) {
        if (face.ft_face.*.num_fixed_sizes > 0) {
            var best: i32 = 0;
            var best_diff: i32 = std.math.maxInt(i32);
            const want: i32 = @intCast(@divTrunc(size, 64));
            const n: usize = @intCast(face.ft_face.*.num_fixed_sizes);
            for (0..n) |i| {
                const h: i32 = face.ft_face.*.available_sizes[i].height;
                const diff: i32 = @intCast(@abs(h - want));
                if (diff < best_diff) {
                    best_diff = diff;
                    best = @intCast(i);
                }
            }
            if (c.FT_Select_Size(face.ft_face, best) != 0) return error.FontSizeFailed;
        } else return error.FontSizeFailed;
    }
}

pub fn setSize(font: Font, size_px: f32, scale: f32) !*Face {
    const face = try ensureLoaded(primaryId(font));
    try applySize(face, size26(size_px, scale));
    return face;
}

pub fn metricScale(face: *Face, requested: c.FT_F26Dot6) f32 {
    // Outline faces are sized in 26.6 already. Color bitmap strikes (Noto
    // Color Emoji is typically one 109px CBDT strike) report that strike's
    // ppem; scale advances down to the requested size so the emoji sits in
    // the title rather than overflowing it.
    if (!face.color) return 1;
    const ppem = face.ft_face.*.size.*.metrics.y_ppem;
    if (ppem == 0) return 1;
    const want = @as(f32, @floatFromInt(requested)) / 64.0;
    const have = @as(f32, @floatFromInt(ppem));
    if (@abs(want - have) < 0.5) return 1;
    return want / have;
}

pub fn scaledMetric(value: i32, scale: f32) i32 {
    if (scale == 1) return value;
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * scale));
}
