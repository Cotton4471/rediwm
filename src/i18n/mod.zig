//! Compiled, allocation-free UI catalogs. No process locale changes or file IO.
const std = @import("std");
const data = @import("catalogs");
pub const languages = data.languages;

var active = std.atomic.Value(usize).init(0);
var turkish = std.atomic.Value(bool).init(false);

pub fn resolve(configured: []const u8, environ: std.process.Environ) []const u8 {
    if (configured.len != 0) return configured;
    for ([_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |key| {
        if (environ.getPosix(key)) |value| if (value.len != 0) return value;
    }
    return "C";
}

pub fn init(environ: std.process.Environ) void {
    _ = setLanguage(resolve("", environ));
}

/// Strip encoding/modifier and normalize language/country without allocating.
pub fn normalize(buf: []u8, raw: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, raw, ".@") orelse raw.len;
    if (end > buf.len) return "en";
    var country = false;
    for (raw[0..end], 0..) |ch, i| {
        if (ch == '_' or ch == '-') {
            buf[i] = '_';
            country = true;
        } else buf[i] = if (country) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
    }
    const tag = buf[0..end];
    if (std.mem.eql(u8, tag, "c") or std.mem.eql(u8, tag, "posix") or tag.len == 0) return "en";
    return tag;
}

pub fn setLanguage(raw: []const u8) bool {
    var buf: [128]u8 = undefined;
    const tag = normalize(&buf, raw);
    const base = tag[0 .. std.mem.indexOfScalar(u8, tag, '_') orelse tag.len];
    const turkish_changed = turkish.swap(std.mem.eql(u8, base, "tr"), .acq_rel) != std.mem.eql(u8, base, "tr");
    var selected: usize = 0;
    for (data.catalogs, 0..) |catalog, i| {
        if (std.mem.eql(u8, catalog.tag, tag)) {
            selected = i + 1;
            break;
        }
    }
    if (selected == 0) for (data.catalogs, 0..) |catalog, i| {
        if (std.mem.eql(u8, catalog.tag, base) or (std.mem.eql(u8, base, "pt") and std.mem.eql(u8, catalog.tag, "pt_BR"))) {
            selected = i + 1;
            break;
        }
    };
    const changed = active.swap(selected, .acq_rel) != selected;
    return changed or turkish_changed;
}

pub fn language() []const u8 {
    const index = active.load(.acquire);
    return if (index == 0) "en" else data.catalogs[index - 1].tag;
}

pub fn isTurkish() bool {
    return turkish.load(.acquire);
}

pub fn hash(context: []const u8, msgid: []const u8) u64 {
    @setEvalBranchQuota(1000000);
    var value: u64 = 14695981039346656037;
    for (context) |ch| value = (value ^ ch) *% 1099511628211;
    value = (value ^ 4) *% 1099511628211;
    for (msgid) |ch| value = (value ^ ch) *% 1099511628211;
    return value;
}

pub fn tr(comptime msgid: []const u8) []const u8 {
    return trc("", msgid);
}

pub fn trZ(comptime msgid: []const u8) [:0]const u8 {
    const value = lookup("", msgid, comptime hash("", msgid), null) orelse return msgid ++ "";
    return value;
}

/// Store a prehashed message in a static UI descriptor, resolve when building UI.
pub const Message = struct {
    source: []const u8,
    key: u64,
    pub fn get(self: Message) []const u8 {
        return lookup("", self.source, self.key, null) orelse self.source;
    }
};
pub fn msg(comptime msgid: []const u8) Message {
    return .{ .source = msgid, .key = comptime hash("", msgid) };
}

pub fn trc(comptime context: []const u8, comptime msgid: []const u8) []const u8 {
    return lookup(context, msgid, comptime hash(context, msgid), null) orelse msgid;
}

pub fn trn(comptime singular: []const u8, comptime plural: []const u8, n: u64) []const u8 {
    return trnc("", singular, plural, n);
}

pub fn trnc(comptime context: []const u8, comptime singular: []const u8, comptime plural: []const u8, n: u64) []const u8 {
    return lookup(context, singular, comptime hash(context, singular), n) orelse if (n == 1) singular else plural;
}

fn lookup(context: []const u8, msgid: []const u8, key: u64, count: ?u64) ?[:0]const u8 {
    const index = active.load(.acquire);
    if (index == 0) return null;
    // Keep catalog probing out of each literal's specialized wrapper. English
    // is one atomic load/branch, and optimized builds share the larger lookup.
    return @call(.never_inline, lookupCatalog, .{ index, context, msgid, key, count });
}

fn lookupCatalog(index: usize, context: []const u8, msgid: []const u8, key: u64, count: ?u64) ?[:0]const u8 {
    const catalog = data.catalogs[index - 1];
    if (lookupTable(catalog.slots, context, msgid, key, if (count) |n| pluralIndex(catalog.tag, n) else 0)) |value| return value;
    // Regional catalogs are sparse overlays. Missing entries inherit the base
    // language before falling back to the English source string.
    const base = catalog.tag[0 .. std.mem.indexOfScalar(u8, catalog.tag, '_') orelse catalog.tag.len];
    for (data.catalogs) |fallback| {
        if (std.mem.eql(u8, fallback.tag, catalog.tag)) continue;
        if (std.mem.eql(u8, fallback.tag, base) or (std.mem.eql(u8, base, "pt") and std.mem.eql(u8, fallback.tag, "pt_BR"))) {
            if (lookupTable(fallback.slots, context, msgid, key, if (count) |n| pluralIndex(fallback.tag, n) else 0)) |value| return value;
        }
    }
    return null;
}

fn lookupTable(table: []const ?data.Entry, context: []const u8, msgid: []const u8, key: u64, form: usize) ?[:0]const u8 {
    if (table.len == 0) return null;
    var slot: usize = @intCast(key % table.len);
    for (0..table.len) |_| {
        const entry = table[slot] orelse return null;
        if (entry.hash == key and std.mem.eql(u8, entry.context, context) and std.mem.eql(u8, entry.msgid, msgid)) {
            if (entry.forms.len == 0) return null;
            const value = entry.forms[@min(form, entry.forms.len - 1)];
            return if (value.len == 0) null else value;
        }
        slot = (slot + 1) % table.len;
    }
    return null;
}

pub fn pluralCount(tag: []const u8) usize {
    return if (std.mem.eql(u8, tag, "ru") or std.mem.eql(u8, tag, "uk") or std.mem.eql(u8, tag, "pl") or std.mem.eql(u8, tag, "cs")) 3 else 2;
}

pub fn pluralIndex(tag: []const u8, n: u64) usize {
    if (std.mem.eql(u8, tag, "fr") or std.mem.eql(u8, tag, "pt_BR")) return if (n <= 1) 0 else 1;
    if (std.mem.eql(u8, tag, "ru") or std.mem.eql(u8, tag, "uk")) {
        if (n % 10 == 1 and n % 100 != 11) return 0;
        return if (n % 10 >= 2 and n % 10 <= 4 and (n % 100 < 12 or n % 100 > 14)) 1 else 2;
    }
    if (std.mem.eql(u8, tag, "pl")) {
        if (n == 1) return 0;
        return if (n % 10 >= 2 and n % 10 <= 4 and (n % 100 < 12 or n % 100 > 14)) 1 else 2;
    }
    if (std.mem.eql(u8, tag, "cs")) return if (n == 1) 0 else if (n >= 2 and n <= 4) 1 else 2;
    return if (n == 1) 0 else 1;
}

pub const FormatError = error{ NoSpaceLeft, InvalidFormat, MissingArgument };

/// Named fields may be reordered/repeated by translators; braces escape as {{/}}.
pub fn fmt(buf: []u8, pattern: []const u8, args: anytype) FormatError![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try format(&writer, pattern, args);
    return buf[0..writer.end];
}

pub fn allocPrint(allocator: std.mem.Allocator, pattern: []const u8, args: anytype) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try format(&writer.writer, pattern, args);
    return writer.toOwnedSlice();
}

pub fn fmtZ(buf: []u8, pattern: []const u8, args: anytype) FormatError![:0]const u8 {
    if (buf.len == 0) return error.NoSpaceLeft;
    const value = try fmt(buf[0 .. buf.len - 1], pattern, args);
    buf[value.len] = 0;
    return buf[0..value.len :0];
}

fn format(writer: *std.Io.Writer, pattern: []const u8, args: anytype) FormatError!void {
    var i: usize = 0;
    while (i < pattern.len) {
        const ch = pattern[i];
        if (ch == '{' or ch == '}') {
            if (i + 1 < pattern.len and pattern[i + 1] == ch) {
                writer.writeByte(ch) catch return error.NoSpaceLeft;
                i += 2;
                continue;
            }
            if (ch == '}') return error.InvalidFormat;
            const end = std.mem.indexOfScalarPos(u8, pattern, i + 1, '}') orelse return error.InvalidFormat;
            const name = pattern[i + 1 .. end];
            var found = false;
            inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field_name| {
                if (std.mem.eql(u8, name, field_name)) {
                    const value = @field(args, field_name);
                    switch (@typeInfo(@FieldType(@TypeOf(args), field_name))) {
                        .int, .comptime_int, .float, .comptime_float => writer.print("{d}", .{value}) catch return error.NoSpaceLeft,
                        .pointer, .array => writer.print("{s}", .{value}) catch return error.NoSpaceLeft,
                        else => @compileError("i18n argument " ++ field_name ++ " must be string or integer, got " ++ @typeName(@FieldType(@TypeOf(args), field_name))),
                    }
                    found = true;
                }
            }
            if (!found) return error.MissingArgument;
            i = end + 1;
        } else {
            writer.writeByte(ch) catch return error.NoSpaceLeft;
            i += 1;
        }
    }
}

test "integer CLDR families" {
    const t = std.testing;
    for ([_]u64{ 1, 21 }) |n| try t.expectEqual(@as(usize, 0), pluralIndex("ru", n));
    for ([_]u64{ 2, 22 }) |n| try t.expectEqual(@as(usize, 1), pluralIndex("ru", n));
    for ([_]u64{ 5, 11, 12, 25, 111 }) |n| try t.expectEqual(@as(usize, 2), pluralIndex("ru", n));
    for ([_][]const u8{ "fr", "pt_BR" }) |tag| {
        try t.expectEqual(@as(usize, 0), pluralIndex(tag, 0));
        try t.expectEqual(@as(usize, 0), pluralIndex(tag, 1));
        try t.expectEqual(@as(usize, 1), pluralIndex(tag, 2));
    }
    try t.expectEqual(@as(usize, 2), pluralIndex("pl", 21));
}

test "named formatting, braces, bounds and malformed fields" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Delete 3: abc? {ok}", try fmt(&buf, "Delete {n}: {name}? {{ok}}", .{ .name = "abc", .n = 3 }));
    try std.testing.expectError(error.MissingArgument, fmt(&buf, "{missing}", .{}));
    try std.testing.expectError(error.InvalidFormat, fmt(&buf, "{name", .{ .name = "abc" }));
    try std.testing.expectError(error.NoSpaceLeft, fmt(buf[0..2], "{name}", .{ .name = "abc" }));
}

test "locale normalization, fallback and fuzzy identity" {
    defer _ = setLanguage("en");
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("pt_BR", normalize(&buf, "pt-br.UTF-8@x"));
    _ = setLanguage("zz_ZZ.UTF-8");
    try std.testing.expectEqualStrings("en", language());
    try std.testing.expectEqualStrings("Cancel", tr("Cancel"));
    _ = setLanguage("tr_TR");
    try std.testing.expect(isTurkish());
}

test "compiled pseudo locale, context, sentinel and English missing fallback" {
    defer _ = setLanguage("en");
    _ = setLanguage("qps");
    try std.testing.expect(!std.mem.eql(u8, "Cancel", tr("Cancel")));
    try std.testing.expectEqual(@as(u8, 0), trZ("Cancel").ptr[trZ("Cancel").len]);
    try std.testing.expectEqualStrings("no such source message", tr("no such source message"));
    _ = setLanguage("en_US.UTF-8");
    try std.testing.expectEqualStrings("Cancel", tr("Cancel"));
    try std.testing.expectEqualStrings("many", trn("one", "many", 0));
}

test "open addressing resolves collisions and confirms context" {
    var slots: [4]?data.Entry = @splat(null);
    const first = hash("", "a");
    const second = hash("", "e");
    try std.testing.expectEqual(first % 4, second % 4);
    slots[first % 4] = .{ .hash = first, .context = "", .msgid = "a", .forms = &.{"A"} };
    slots[(first % 4 + 1) % 4] = .{ .hash = second, .context = "", .msgid = "e", .forms = &.{ "E", "Es" } };
    try std.testing.expectEqualStrings("A", lookupTable(&slots, "", "a", first, 0).?);
    try std.testing.expectEqualStrings("Es", lookupTable(&slots, "", "e", second, 1).?);
    try std.testing.expectEqual(@as(?[:0]const u8, null), lookupTable(&slots, "different context", "e", second, 0));
}
