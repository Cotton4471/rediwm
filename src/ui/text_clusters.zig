//! Grapheme clusters: codepoints, emoji sequences, marks and whether a cluster wants colour.

const std = @import("std");
const text = @import("text.zig");
const c = text.c;

pub fn nextCodepoint(bytes: []const u8, i: *usize) ?u21 {
    if (i.* >= bytes.len) return null;
    const n = std.unicode.utf8ByteSequenceLength(bytes[i.*]) catch {
        i.* += 1;
        return null;
    };
    if (i.* + n > bytes.len) {
        i.* = bytes.len;
        return null;
    }
    const cp = std.unicode.utf8Decode(bytes[i.*..][0..n]) catch {
        i.* += 1;
        return null;
    };
    i.* += n;
    return cp;
}

pub fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

pub fn isSkinTone(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

pub fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}

pub fn isMark(cp: u21) bool {
    const cat = c.hb_unicode_general_category(c.hb_unicode_funcs_get_default(), cp);
    return cat == c.HB_UNICODE_GENERAL_CATEGORY_NON_SPACING_MARK or
        cat == c.HB_UNICODE_GENERAL_CATEGORY_SPACING_MARK or
        cat == c.HB_UNICODE_GENERAL_CATEGORY_ENCLOSING_MARK;
}

pub fn consumeExtenders(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i < bytes.len) {
        var j = i;
        const cp = nextCodepoint(bytes, &j) orelse break;
        if (isMark(cp) or isVariationSelector(cp) or isSkinTone(cp) or cp == 0x20E3) {
            i = j;
            continue;
        }
        break;
    }
    return i;
}

/// End of the grapheme cluster starting at `start`. ZWJ emoji sequences and
/// flag pairs stay together so HarfBuzz can ligate them on one face.
pub fn nextClusterEnd(bytes: []const u8, start: usize) usize {
    if (start >= bytes.len) return bytes.len;
    var i = start;
    const first = nextCodepoint(bytes, &i) orelse return @min(start + 1, bytes.len);

    if (isRegionalIndicator(first)) {
        const saved = i;
        if (nextCodepoint(bytes, &i)) |second| {
            if (!isRegionalIndicator(second)) i = saved;
        } else i = saved;
        return consumeExtenders(bytes, i);
    }

    i = consumeExtenders(bytes, i);
    while (i < bytes.len) {
        var j = i;
        const cp = nextCodepoint(bytes, &j) orelse break;
        if (cp != 0x200D) break;
        i = j;
        if (i >= bytes.len) break;
        _ = nextCodepoint(bytes, &i);
        i = consumeExtenders(bytes, i);
    }
    return i;
}

pub fn clusterBase(bytes: []const u8) ?u32 {
    var i: usize = 0;
    while (i < bytes.len) {
        const cp = nextCodepoint(bytes, &i) orelse break;
        if (cp == 0x200D or isMark(cp) or isVariationSelector(cp) or isSkinTone(cp)) continue;
        return cp;
    }
    return null;
}

pub fn clusterWantsColor(bytes: []const u8) bool {
    var i: usize = 0;
    var vs16 = false;
    var pictographic = false;
    while (i < bytes.len) {
        const cp = nextCodepoint(bytes, &i) orelse break;
        if (cp == 0xFE0F) vs16 = true;
        if (cp >= 0x1F000 and cp <= 0x1FFFF) pictographic = true;
    }
    return pictographic or vs16;
}

pub fn previousUtf8Boundary(bytes: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var start = end - 1;
    while (start > 0 and (bytes[start] & 0xc0) == 0x80) : (start -= 1) {}
    return start;
}
