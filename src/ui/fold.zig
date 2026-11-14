//! Allocation-free Unicode matching for user-visible names. The table folds
//! Latin, Greek and Cyrillic case and accents; other scripts pass through.
//! Invalid UTF-8 bytes remain distinct, so arbitrary filenames can be searched.
const std = @import("std");
const data = @import("fold_data.zig");

pub const Options = struct { turkish: bool = false };
pub const Match = struct { start: usize, end: usize };
pub const unicode_version = data.unicode_version;

const Unit = struct { value: u21, start: usize, end: usize };
const invalid_base = 0x110000;

const Iterator = struct {
    text: []const u8,
    options: Options,
    offset: usize = 0,
    pending: ?Unit = null,
    strip_marks: bool = false,

    fn next(self: *Iterator) ?Unit {
        if (self.pending) |unit| {
            self.pending = null;
            return unit;
        }
        while (self.offset < self.text.len) {
            const start = self.offset;
            const cp = decode(self.text, &self.offset);
            if (isCombining(cp)) {
                if (self.strip_marks) continue;
                return .{ .value = cp, .start = start, .end = self.offset };
            }
            self.strip_marks = isFoldedScript(cp);
            // Include stripped marks in the span used for search highlighting.
            var end = self.offset;
            var dotted = false;
            if (self.strip_marks) {
                while (end < self.text.len) {
                    var next_end = end;
                    const mark = decode(self.text, &next_end);
                    if (!isCombining(mark)) break;
                    dotted = dotted or mark == 0x307;
                    end = next_end;
                }
                self.offset = end;
            }
            if (self.options.turkish) {
                if (cp == 'I') return .{ .value = if (dotted) 'i' else 0x131, .start = start, .end = end };
                if (cp == 0x130) return .{ .value = 'i', .start = start, .end = end };
            }
            if (cp >= 'A' and cp <= 'Z') return .{ .value = cp + ('a' - 'A'), .start = start, .end = end };
            if (mapping(cp)) |m| {
                if (m.second != 0) self.pending = .{ .value = m.second, .start = start, .end = end };
                return .{ .value = m.first, .start = start, .end = end };
            }
            return .{ .value = cp, .start = start, .end = end };
        }
        return null;
    }
};

fn decode(text: []const u8, offset: *usize) u21 {
    const start = offset.*;
    const byte = text[start];
    const len = std.unicode.utf8ByteSequenceLength(byte) catch {
        offset.* += 1;
        return invalid_base + @as(u21, byte);
    };
    if (start + len <= text.len) {
        if (std.unicode.utf8Decode(text[start..][0..len])) |cp| {
            offset.* += len;
            return cp;
        } else |_| {}
    }
    offset.* += 1;
    return invalid_base + @as(u21, byte);
}

fn mapping(cp: u21) ?data.Mapping {
    if (cp < 0xc0) return null;
    var lo: usize = 0;
    var hi: usize = data.mappings.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = data.mappings[mid];
        if (entry.from < cp) lo = mid + 1 else if (entry.from > cp) hi = mid else return entry;
    }
    return null;
}

fn isCombining(cp: u21) bool {
    if (cp < 0x300) return false;
    var lo: usize = 0;
    var hi: usize = data.combining.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = data.combining[mid];
        if (range[1] < cp) lo = mid + 1 else if (range[0] > cp) hi = mid else return true;
    }
    return false;
}

fn isFoldedScript(cp: u21) bool {
    return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or
        (cp >= 0xc0 and cp <= 0x24f) or (cp >= 0x370 and cp <= 0x52f) or
        (cp >= 0x1d00 and cp <= 0x1fff) or (cp >= 0x2c60 and cp <= 0x2c7f) or
        (cp >= 0xa640 and cp <= 0xa69f) or (cp >= 0xa720 and cp <= 0xa7ff) or
        (cp >= 0xab30 and cp <= 0xab6f);
}

/// Byte offsets refer to the original haystack, including attached accents.
/// Expansions such as ß→ss map both folded letters to the original character.
pub fn indexOf(haystack: []const u8, needle: []const u8, options: Options) ?Match {
    var query = Iterator{ .text = needle, .options = options };
    const first = query.next() orelse return .{ .start = 0, .end = 0 };
    var candidates = Iterator{ .text = haystack, .options = options };
    while (candidates.next()) |candidate| {
        if (candidate.value != first.value) continue;
        var rest = candidates;
        var remaining = query;
        var end = candidate.end;
        while (remaining.next()) |expected| {
            const actual = rest.next() orelse break;
            if (actual.value != expected.value) break;
            end = actual.end;
        } else return .{ .start = candidate.start, .end = end };
    }
    return null;
}

pub fn contains(haystack: []const u8, needle: []const u8, options: Options) bool {
    return indexOf(haystack, needle, options) != null;
}

pub fn startsWith(haystack: []const u8, needle: []const u8, options: Options) bool {
    var text = Iterator{ .text = haystack, .options = options };
    var query = Iterator{ .text = needle, .options = options };
    while (query.next()) |expected| {
        const actual = text.next() orelse return false;
        if (actual.value != expected.value) return false;
    }
    return true;
}

pub fn eql(a: []const u8, b: []const u8, options: Options) bool {
    return order(a, b, options) == .eq;
}

/// Deterministic folded order; locale-sensitive file ordering uses LC_COLLATE.
pub fn order(a: []const u8, b: []const u8, options: Options) std.math.Order {
    var lhs = Iterator{ .text = a, .options = options };
    var rhs = Iterator{ .text = b, .options = options };
    while (lhs.next()) |left| {
        const right = rhs.next() orelse return .gt;
        const result = std.math.order(left.value, right.value);
        if (result != .eq) return result;
    }
    return if (rhs.next() == null) .eq else .lt;
}

pub fn write(buffer: []u8, input: []const u8, options: Options) error{NoSpaceLeft}![]const u8 {
    var iterator = Iterator{ .text = input, .options = options };
    var len: usize = 0;
    while (iterator.next()) |unit| {
        var bytes: [4]u8 = undefined;
        const count = if (unit.value >= invalid_base) blk: {
            bytes[0] = @intCast(unit.value - invalid_base);
            break :blk 1;
        } else std.unicode.utf8Encode(unit.value, &bytes) catch unreachable;
        if (count > buffer.len - len) return error.NoSpaceLeft;
        @memcpy(buffer[len..][0..count], bytes[0..count]);
        len += count;
    }
    return buffer[0..len];
}

test "fold Latin Greek Cyrillic and decomposition extras" {
    var buffer: [256]u8 = undefined;
    const cases = .{
        .{ "Cámara CÁMARA cafe\u{301}", "camara camara cafe" },
        .{ "Straße Æsir Œuvre ŁÓDŹ Øresund", "strasse aesir oeuvre lodz oresund" },
        .{ "ΑΘΉΝΑ Ἀθήνα τελικός", "αθηνα αθηνα τελικοσ" },
        .{ "Терминал ЁЖИК е\u{308}", "терминал ежик е" },
        .{ "Tiếng Việt", "tieng viet" },
        .{ "日本語 あ\u{3099} العربية", "日本語 あ\u{3099} العربية" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try write(&buffer, case[0], .{}));
    try std.testing.expectError(error.NoSpaceLeft, write(buffer[0..1], "Æ", .{}));
    try std.testing.expectEqualStrings("a\xffb", try write(&buffer, "A\xffB", .{}));
}

test "fold Turkish dotted and dotless i follow the chosen language" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("iiıi", try write(&buffer, "Iİıi", .{}));
    try std.testing.expectEqualStrings("ıiıi", try write(&buffer, "Iİıi", .{ .turkish = true }));
    try std.testing.expectEqualStrings("iı", try write(&buffer, "I\u{307}I", .{ .turkish = true }));
    try std.testing.expect(contains("IŞIK", "ışık", .{ .turkish = true }));
    try std.testing.expect(!contains("IŞIK", "ışık", .{}));
}

test "fold matching maps expansion and decomposed accent offsets" {
    try std.testing.expectEqual(Match{ .start = 1, .end = 8 }, indexOf("!Cámara?", "CAMARA", .{}).?);
    try std.testing.expectEqual(Match{ .start = 4, .end = 6 }, indexOf("Straße", "ss", .{}).?);
    try std.testing.expectEqual(Match{ .start = 0, .end = 3 }, indexOf("e\u{301}lan", "é", .{}).?);
    try std.testing.expect(contains("Терминал", "терм", .{}));
    try std.testing.expect(contains("œ", "OE", .{}));
    try std.testing.expect(!contains("é", "eagle", .{}));
    try std.testing.expect(startsWith("Æsir", "ae", .{}));
    try std.testing.expect(eql("ÉLAN", "e\u{301}lan", .{}));
    try std.testing.expectEqual(std.math.Order.lt, order("Äpfel", "Zebra", .{}));
    const long = comptime blk: {
        var repeated: []const u8 = "";
        for (0..100) |_| repeated = repeated ++ "Préfixe ";
        break :blk repeated;
    };
    try std.testing.expect(contains(long ++ "Терминал", "терм", .{}));
}
