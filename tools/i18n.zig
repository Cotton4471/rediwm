//! Offline PO extraction, validation and compilation. English sources stay in Zig.
const std = @import("std");
const A = std.heap.page_allocator;
const Entry = struct {
    context: []const u8 = "",
    id: []const u8 = "",
    plural: []const u8 = "",
    forms: [3][]const u8 = .{ "", "", "" },
    count: usize = 0,
    seen_forms: u8 = 0,
    fuzzy: bool = false,
    note: []const u8 = "",
};
const List = std.ArrayList(Entry);
var io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    const args = init.minimal.args.vector;
    if (args.len < 2) return error.ExpectedCommand;
    const command = std.mem.span(args[1]);
    if (std.mem.eql(u8, command, "compile")) {
        if (args.len < 3) return error.ExpectedOutput;
        try compile(std.mem.span(args[2]));
        return;
    }
    if (std.mem.eql(u8, command, "data")) {
        if (args.len < 4) return error.ExpectedDataPaths;
        try generateData(try catalogs(), std.mem.span(args[2]), std.mem.span(args[3]));
        return;
    }
    var source: List = .empty;
    try scan("src", &source);
    try dataEntries(&source);
    std.mem.sort(Entry, source.items, {}, less);
    if (std.mem.eql(u8, command, "extract")) {
        try writePot(source.items);
    } else if (std.mem.eql(u8, command, "check")) {
        const pot = try readPo("po/rediwm.pot");
        if (!sameSources(source.items, pot.items)) return error.StaleTemplateRunI18nExtract;
        try checkCatalogs(source.items);
    } else if (std.mem.eql(u8, command, "lint")) {
        // Converted files opt in individually; protocol/id literals are deliberately excluded.
        const paths = read("po/lint-files") catch "";
        var lines = std.mem.tokenizeAny(u8, paths, "\n\r");
        while (lines.next()) |path| try lint(path);
    } else return error.UnknownCommand;
}

fn read(path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, A, .limited(16 * 1024 * 1024));
}
fn write(path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}
fn quoted(bytes: []const u8) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(A);
    try w.writer.writeByte('"');
    for (bytes) |ch| switch (ch) {
        '\\' => try w.writer.writeAll("\\\\"),
        '"' => try w.writer.writeAll("\\\""),
        '\n' => try w.writer.writeAll("\\n"),
        '\r' => try w.writer.writeAll("\\r"),
        '\t' => try w.writer.writeAll("\\t"),
        else => try w.writer.writeByte(ch),
    };
    try w.writer.writeByte('"');
    return w.toOwnedSlice();
}
fn unquote(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return error.InvalidPoString;
    // PO and Zig have the same escapes for the strings accepted here.
    return std.zig.string_literal.parseAlloc(A, trimmed);
}
fn same(a: Entry, b: Entry) bool {
    return std.mem.eql(u8, a.id, b.id) and std.mem.eql(u8, a.context, b.context);
}
fn less(_: void, a: Entry, b: Entry) bool {
    const order = std.mem.order(u8, a.context, b.context);
    return if (order == .eq) std.mem.lessThan(u8, a.id, b.id) else order == .lt;
}
fn add(list: *List, entry: Entry) !void {
    if (entry.id.len == 0) return;
    for (list.items) |*old| if (same(old.*, entry)) {
        if (!std.mem.eql(u8, old.plural, entry.plural)) return error.ConflictingPlural;
        return;
    };
    try list.append(A, entry);
}

fn scan(path: []const u8, list: *List) anyerror!void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList(struct { name: []const u8, directory: bool }) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory or (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig") and !std.mem.endsWith(u8, entry.name, "tests.zig"))) try names.append(A, .{ .name = try A.dupe(u8, entry.name), .directory = entry.kind == .directory });
    }
    std.mem.sort(@TypeOf(names.items[0]), names.items, {}, struct {
        fn lt(_: void, left: @TypeOf(names.items[0]), right: @TypeOf(names.items[0])) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lt);
    for (names.items) |entry| {
        const next = try std.fmt.allocPrint(A, "{s}/{s}", .{ path, entry.name });
        if (std.mem.eql(u8, next, "src/i18n")) continue;
        if (entry.directory) try scan(next, list) else try extract(next, list);
    }
}

fn extract(path: []const u8, list: *List) !void {
    const source = try A.dupeSentinel(u8, try read(path), 0);
    var tree = try std.zig.Ast.parse(A, source, .{});
    defer tree.deinit(A);
    const tags = tree.tokens.items(.tag);
    var i: u32 = 0;
    var test_depth: usize = 0;
    var pending_test = false;
    while (i + 3 < tags.len) : (i += 1) {
        if (tags[i] == .keyword_test) pending_test = true;
        if (tags[i] == .l_brace) {
            if (pending_test or test_depth != 0) test_depth += 1;
            pending_test = false;
        }
        if (tags[i] == .r_brace and test_depth != 0) {
            test_depth -= 1;
            continue;
        }
        if (test_depth != 0 or tags[i] != .identifier or tags[i + 1] != .l_paren or (i > 0 and tags[i - 1] == .keyword_fn)) continue;
        const name = tree.tokenSlice(i);
        const context = std.mem.eql(u8, name, "trc") or std.mem.eql(u8, name, "trnc");
        const plural = std.mem.eql(u8, name, "trn") or std.mem.eql(u8, name, "trnc");
        if (!context and !plural and !std.mem.eql(u8, name, "tr") and !std.mem.eql(u8, name, "trZ") and !std.mem.eql(u8, name, "msg")) continue;
        if (tags[i + 2] != .string_literal) {
            std.debug.print("{s}: {s} requires an extractable string literal\n", .{ path, name });
            return error.ExpectedLiteral;
        }
        var e: Entry = .{ .note = path };
        var token = i + 2;
        if (context) {
            e.context = try unquote(tree.tokenSlice(token));
            token += 2;
            if (token >= tags.len or tags[token] != .string_literal) return error.ExpectedLiteral;
        }
        e.id = try unquote(tree.tokenSlice(token));
        if (plural) {
            token += 2;
            if (token >= tags.len or tags[token] != .string_literal) return error.ExpectedLiteral;
            e.plural = try unquote(tree.tokenSlice(token));
        }
        // Nearby translator comments travel with the template.
        const start = tree.tokens.items(.start)[i];
        const before = source[start -| 350..start];
        if (std.mem.lastIndexOf(u8, before, "// i18n:")) |note| {
            const text = before[note + 8 ..];
            e.note = try std.fmt.allocPrint(A, "{s}\n#. {s}", .{ path, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len] });
        }
        try add(list, e);
    }
}

fn dataEntries(list: *List) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, "data", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".desktop")) continue;
        const path = try std.fmt.allocPrint(A, "data/{s}", .{file.name});
        var lines = std.mem.splitScalar(u8, try read(path), '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            for ([_][]const u8{ "Name", "GenericName", "Comment", "Keywords" }) |field| if (std.mem.eql(u8, key, field)) {
                try add(list, .{ .context = try std.fmt.allocPrint(A, "desktop:{s}", .{key}), .id = line[eq + 1 ..], .note = path });
            };
        }
    }
    const policy = try read("data/org.rediwm.accounts.policy");
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, policy, pos, "<message>")) |start| {
        const end = std.mem.indexOfPos(u8, policy, start, "</message>") orelse return error.InvalidPolicy;
        try add(list, .{ .context = "polkit", .id = policy[start + 9 .. end], .note = "data/org.rediwm.accounts.policy" });
        pos = end + 10;
    }
}

fn writePot(entries: []const Entry) !void {
    var w = std.Io.Writer.Allocating.init(A);
    try w.writer.writeAll("# RediWM UI messages. Generated by zig build i18n-extract.\nmsgid \"\"\nmsgstr \"\"\n\"Content-Type: text/plain; charset=UTF-8\\n\"\n\n");
    for (entries) |e| {
        try w.writer.print("#: {s}\n", .{e.note});
        if (e.context.len != 0) try w.writer.print("msgctxt {s}\n", .{try quoted(e.context)});
        try w.writer.print("msgid {s}\n", .{try quoted(e.id)});
        if (e.plural.len != 0) try w.writer.print("msgid_plural {s}\nmsgstr[0] \"\"\nmsgstr[1] \"\"\n\n", .{try quoted(e.plural)}) else try w.writer.writeAll("msgstr \"\"\n\n");
    }
    try write("po/rediwm.pot", w.written());
}

fn readPo(path: []const u8) !List {
    return parsePo(try read(path));
}
fn parsePo(bytes: []const u8) !List {
    var entries: List = .empty;
    var e: Entry = .{};
    var field: ?*[]const u8 = null;
    var started = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            if (started) try entries.append(A, e);
            e = .{};
            field = null;
            started = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "#~")) return error.ObsoletePoEntry;
        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, "#,") and std.mem.indexOf(u8, line, "fuzzy") != null) e.fuzzy = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "msgctxt ")) {
            field = &e.context;
            field.?.* = try unquote(line[8..]);
            started = true;
        } else if (std.mem.startsWith(u8, line, "msgid_plural ")) {
            field = &e.plural;
            field.?.* = try unquote(line[13..]);
        } else if (std.mem.startsWith(u8, line, "msgid ")) {
            field = &e.id;
            field.?.* = try unquote(line[6..]);
            started = true;
        } else if (std.mem.startsWith(u8, line, "msgstr[")) {
            if (line.len < 11 or line[8] != ']') return error.InvalidPoPlural;
            const index = std.fmt.parseInt(usize, line[7..8], 10) catch return error.InvalidPoPlural;
            if (index >= e.forms.len) return error.InvalidPoPlural;
            if (e.seen_forms & (@as(u8, 1) << @intCast(index)) != 0) return error.DuplicatePoForm;
            e.seen_forms |= @as(u8, 1) << @intCast(index);
            e.count = @max(e.count, index + 1);
            field = &e.forms[index];
            field.?.* = try unquote(line[10..]);
        } else if (std.mem.startsWith(u8, line, "msgstr ")) {
            if (e.seen_forms != 0) return error.DuplicatePoForm;
            e.seen_forms = 1;
            e.count = 1;
            field = &e.forms[0];
            field.?.* = try unquote(line[7..]);
        } else if (line[0] == '"') {
            const target = field orelse return error.InvalidPoContinuation;
            target.* = try std.mem.concat(A, u8, &.{ target.*, try unquote(line) });
        } else return error.InvalidPoLine;
    }
    if (started) try entries.append(A, e);
    for (entries.items, 0..) |item, i| for (entries.items[0..i]) |other| if (same(item, other)) return error.DuplicatePoEntry;
    return entries;
}
fn sameSources(source: []const Entry, pot: []const Entry) bool {
    var count: usize = 0;
    for (pot) |entry| {
        if (entry.id.len == 0) continue;
        count += 1;
        var found = false;
        for (source) |candidate| if (same(entry, candidate) and std.mem.eql(u8, entry.plural, candidate.plural)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return count == source.len;
}
fn countPlural(tag: []const u8) usize {
    return if (std.mem.eql(u8, tag, "ru")) 3 else 2;
}
fn placeholders(text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '{' or text[i] == '}') {
            if (i + 1 < text.len and text[i + 1] == text[i]) {
                i += 1;
                continue;
            }
            if (text[i] == '}') return error.InvalidPlaceholder;
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '}') orelse return error.InvalidPlaceholder;
            const name = text[i + 1 .. end];
            if (name.len == 0) return error.InvalidPlaceholder;
            for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidPlaceholder;
            var found = false;
            for (out.items) |old| if (std.mem.eql(u8, old, name)) {
                found = true;
                break;
            };
            if (!found) try out.append(A, name);
            i = end;
        }
    }
    return out.toOwnedSlice(A);
}
fn samePlaceholders(a: []const u8, b: []const u8) !bool {
    const left = try placeholders(a);
    const right = try placeholders(b);
    if (left.len != right.len) return false;
    for (left) |name| {
        var found = false;
        for (right) |other| if (std.mem.eql(u8, name, other)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}
fn dateFields(text: []const u8) [128]u16 {
    var counts: [128]u16 = @splat(0);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '%') continue;
        i += 1;
        while (i < text.len and !std.ascii.isAlphabetic(text[i]) and text[i] != '%') : (i += 1) {}
        if (i < text.len and text[i] < 128) counts[text[i]] +|= 1;
    }
    return counts;
}
fn sameDateFields(original: []const u8, translated_text: []const u8) bool {
    return std.meta.eql(dateFields(original), dateFields(translated_text));
}

fn validate(tag: []const u8, entries: []const Entry, source: []const Entry) !void {
    for (entries) |e| {
        if (e.id.len == 0) continue;
        var found = false;
        for (source) |s| if (same(e, s) and std.mem.eql(u8, e.plural, s.plural)) {
            found = true;
            break;
        };
        if (!found) {
            std.debug.print("{s}: stale message: {s}\n", .{ tag, e.id });
            return error.StaleTranslation;
        }
        if (e.seen_forms != 0 and e.seen_forms != (@as(u8, 1) << @intCast(e.count)) - 1) return error.WrongPluralCount;
        if (e.plural.len != 0 and e.count != countPlural(tag)) return error.WrongPluralCount;
        if (e.plural.len == 0 and e.count != 1) return error.WrongPluralCount;
        for (e.forms[0..e.count]) |form| {
            if (form.len == 0) continue;
            if (!std.unicode.utf8ValidateSlice(form)) return error.InvalidUtf8;
            if (std.mem.indexOfScalar(u8, form, 0) != null) return error.InvalidNull;
            if (std.mem.eql(u8, e.context, "date") and !sameDateFields(e.id, form)) return error.DateFieldMismatch;
            if (!try samePlaceholders(e.id, form)) {
                std.debug.print("{s}: placeholders: {s}\n", .{ tag, e.id });
                return error.PlaceholderMismatch;
            }
            if (std.mem.eql(u8, tag, "fr") and std.mem.indexOf(u8, form, "\xe2\x80\xaf") != null) return error.UseNoBreakSpaceU00A0;
        }
    }
}
fn catalogs() ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, "po", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |file| if (file.kind == .file and std.mem.endsWith(u8, file.name, ".po")) try out.append(A, try A.dupe(u8, file.name[0 .. file.name.len - 3]));
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(A);
}
fn checkCatalogs(source: []const Entry) !void {
    for (try catalogs()) |tag| {
        const po = try readPo(try std.fmt.allocPrint(A, "po/{s}.po", .{tag}));
        try validate(tag, po.items, source);
        var translated_count: usize = 0;
        var fuzzy: usize = 0;
        for (po.items) |e| if (e.id.len != 0) {
            if (e.fuzzy) fuzzy += 1 else if (e.forms[0].len != 0) {
                translated_count += 1;
            }
        };
        std.debug.print("{s}: {d}/{d} translated, {d} fuzzy (excluded at runtime)\n", .{ tag, translated_count, source.len, fuzzy });
    }
}
fn hash(context: []const u8, id: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (context) |ch| h = (h ^ ch) *% 1099511628211;
    h = (h ^ 4) *% 1099511628211;
    for (id) |ch| h = (h ^ ch) *% 1099511628211;
    return h;
}
fn pseudo(text: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(A);
    try out.writer.writeAll("[ ");
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, text, i, '}') orelse return error.InvalidPlaceholder;
            try out.writer.writeAll(text[i .. end + 1]);
            i = end + 1;
            continue;
        }
        if (text[i] == '%' and i + 1 < text.len) {
            var end = i + 1;
            while (end < text.len and !std.ascii.isAlphabetic(text[end]) and text[end] != '%') : (end += 1) {}
            end = @min(end + 1, text.len);
            try out.writer.writeAll(text[i..end]);
            i = end;
            continue;
        }
        switch (text[i]) {
            'a' => try out.writer.writeAll("à"),
            'e' => try out.writer.writeAll("é"),
            'i' => try out.writer.writeAll("ï"),
            'o' => try out.writer.writeAll("ô"),
            'u' => try out.writer.writeAll("ü"),
            else => try out.writer.writeByte(text[i]),
        }
        i += 1;
    }
    for (0..text.len * 2 / 5) |_| try out.writer.writeByte('!');
    try out.writer.writeAll(" ]");
    return out.toOwnedSlice();
}

fn header(entries: []const Entry, key: []const u8) []const u8 {
    for (entries) |entry| if (entry.id.len == 0) {
        var lines = std.mem.splitScalar(u8, entry.forms[0], '\n');
        while (lines.next()) |line| if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ':') return std.mem.trim(u8, line[key.len + 1 ..], " \t");
    };
    return "";
}
fn metadataDefault(tag: []const u8, native: bool) []const u8 {
    const tags = [_][]const u8{ "es", "pt_BR", "de", "fr", "ru" };
    const names = [_][]const u8{ "Español", "Português (Brasil)", "Deutsch", "Français", "Русский" };
    const locales = [_][]const u8{ "es_ES.UTF-8", "pt_BR.UTF-8", "de_DE.UTF-8", "fr_FR.UTF-8", "ru_RU.UTF-8" };
    for (tags, 0..) |t, i| if (std.mem.eql(u8, tag, t)) return if (native) names[i] else locales[i];
    return tag;
}

fn compile(path: []const u8) !void {
    const pot = try readPo("po/rediwm.pot");
    var tags: std.ArrayList([]const u8) = .empty;
    try tags.appendSlice(A, try catalogs());
    try tags.append(A, "qps");
    var w = std.Io.Writer.Allocating.init(A);
    try w.writer.writeAll("// Generated by tools/i18n.zig; do not edit.\npub const Entry = struct { hash: u64, context: []const u8, msgid: []const u8, forms: []const [:0]const u8 };\npub const Catalog = struct { tag: []const u8, slots: []const ?Entry };\npub const catalogs = [_]Catalog{\n");
    for (tags.items) |tag| {
        const po = if (std.mem.eql(u8, tag, "qps")) pot else try readPo(try std.fmt.allocPrint(A, "po/{s}.po", .{tag}));
        const qps = std.mem.eql(u8, tag, "qps");
        if (!qps) try validate(tag, po.items, pot.items);
        var kept: List = .empty;
        for (po.items) |entry| {
            var e = entry;
            if (e.id.len == 0 or e.fuzzy or (!qps and e.forms[0].len == 0)) continue;
            if (qps) {
                e.count = if (e.plural.len == 0) 1 else 2;
                e.forms[0] = try pseudo(e.id);
                if (e.count == 2) e.forms[1] = try pseudo(e.plural);
            }
            var complete = true;
            for (e.forms[0..e.count]) |form| if (form.len == 0) {
                complete = false;
            };
            if (complete) try kept.append(A, e);
        }
        const n = kept.items.len * 2 + 1;
        const slots = try A.alloc(?Entry, n);
        @memset(slots, null);
        for (kept.items) |e| {
            var index: usize = @intCast(hash(e.context, e.id) % n);
            while (slots[index] != null) index = (index + 1) % n;
            slots[index] = e;
        }
        try w.writer.print(".{{ .tag = {s}, .slots = &.{{\n", .{try quoted(tag)});
        for (slots) |maybe| {
            if (maybe) |e| {
                try w.writer.print(".{{ .hash = {d}, .context = {s}, .msgid = {s}, .forms = &.{{", .{ hash(e.context, e.id), try quoted(e.context), try quoted(e.id) });
                for (e.forms[0..e.count]) |form| try w.writer.print("{s},", .{try quoted(form)});
                try w.writer.writeAll("} },\n");
            } else try w.writer.writeAll("null,\n");
        }
        try w.writer.writeAll("} },\n");
    }
    try w.writer.writeAll("};\npub const Language = struct { tag: []const u8, native_name: []const u8, locale: []const u8, translated: usize, total: usize, reviewed: bool };\npub const languages = [_]Language{\n");
    for (tags.items) |tag| {
        if (std.mem.eql(u8, tag, "qps")) continue;
        const po = try readPo(try std.fmt.allocPrint(A, "po/{s}.po", .{tag}));
        const native = header(po.items, "X-RediWM-Native-Name");
        const locale = header(po.items, "X-RediWM-Locale");
        var reviewed_count: usize = 0;
        for (po.items) |e| {
            if (e.id.len == 0 or e.fuzzy or e.forms[0].len == 0) continue;
            var complete = true;
            for (e.forms[0..e.count]) |form| if (form.len == 0) {
                complete = false;
            };
            if (complete) reviewed_count += 1;
        }
        try w.writer.print(".{{ .tag = {s}, .native_name = {s}, .locale = {s}, .translated = {d}, .total = {d}, .reviewed = {} }},\n", .{
            try quoted(tag),                                                         try quoted(if (native.len > 0) native else metadataDefault(tag, true)),
            try quoted(if (locale.len > 0) locale else metadataDefault(tag, false)), reviewed_count,
            pot.items.len - 1,                                                       std.mem.eql(u8, header(po.items, "X-RediWM-Reviewed"), "yes"),
        });
    }
    try w.writer.writeAll("};\n");
    try write(path, w.written());
}

fn translated(tag: []const u8, context: []const u8, id: []const u8) !?[]const u8 {
    const po = try readPo(try std.fmt.allocPrint(A, "po/{s}.po", .{tag}));
    for (po.items) |e| if (!e.fuzzy and std.mem.eql(u8, e.context, context) and std.mem.eql(u8, e.id, id) and e.forms[0].len != 0) return e.forms[0];
    return null;
}
fn xmlEscaped(text: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(A);
    for (text) |ch| switch (ch) {
        '&' => try out.writer.writeAll("&amp;"),
        '<' => try out.writer.writeAll("&lt;"),
        '>' => try out.writer.writeAll("&gt;"),
        '"' => try out.writer.writeAll("&quot;"),
        else => try out.writer.writeByte(ch),
    };
    return out.toOwnedSlice();
}
fn generateData(tags: []const []const u8, source: []const u8, output: []const u8) !void {
    const bytes = try read(source);
    var out = std.Io.Writer.Allocating.init(A);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        try out.writer.writeAll(line);
        if (lines.index != null) try out.writer.writeByte('\n');
        if (std.mem.endsWith(u8, source, ".desktop")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            for ([_][]const u8{ "Name", "GenericName", "Comment", "Keywords" }) |field| if (std.mem.eql(u8, key, field)) {
                const context = try std.fmt.allocPrint(A, "desktop:{s}", .{key});
                for (tags) |tag| if (try translated(tag, context, line[eq + 1 ..])) |value| {
                    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidDesktopValue;
                    try out.writer.print("{s}[{s}]={s}\n", .{ key, tag, value });
                };
            };
        } else if (std.mem.indexOf(u8, line, "<message>")) |start| {
            const end = std.mem.indexOf(u8, line, "</message>") orelse return error.InvalidPolicy;
            for (tags) |tag| if (try translated(tag, "polkit", line[start + 9 .. end])) |value| {
                try out.writer.print("{s}<message xml:lang=\"{s}\">{s}</message>\n", .{ line[0..start], tag, try xmlEscaped(value) });
            };
        }
    }
    try write(output, out.written());
}
fn lint(path: []const u8) !void {
    const source = try A.dupeSentinel(u8, try read(path), 0);
    var tree = try std.zig.Ast.parse(A, source, .{});
    defer tree.deinit(A);
    const tags = tree.tokens.items(.tag);
    var test_depth: usize = 0;
    var pending_test = false;
    var i: u32 = 0;
    while (i + 3 < tags.len) : (i += 1) {
        if (tags[i] == .keyword_test) pending_test = true;
        if (tags[i] == .l_brace) {
            if (pending_test or test_depth != 0) test_depth += 1;
            pending_test = false;
        }
        if (tags[i] == .r_brace and test_depth != 0) {
            test_depth -= 1;
            continue;
        }
        if (test_depth != 0 or tags[i] != .period or tags[i + 1] != .identifier or tags[i + 2] != .equal or tags[i + 3] != .string_literal) continue;
        const field = tree.tokenSlice(i + 1);
        var sink = false;
        for ([_][]const u8{ "label", "placeholder", "title", "subtitle", "content" }) |known| if (std.mem.eql(u8, field, known)) {
            sink = true;
            break;
        };
        if (!sink) continue;
        const literal = tree.tokenSlice(i + 3);
        if (literal.len == 2) continue;
        const start = tree.tokens.items(.start)[i];
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |at| at + 1 else 0;
        const previous_start = if (line_start > 0) if (std.mem.lastIndexOfScalar(u8, source[0 .. line_start - 1], '\n')) |at| at + 1 else 0 else 0;
        const line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        if (std.mem.indexOf(u8, source[previous_start..line_end], "i18n: raw") != null) continue;
        std.debug.print("{s}: untranslated {s}: {s}\n", .{ path, field, literal });
        return error.UntranslatedLiteral;
    }
}

test "PO parser and formatter invariants" {
    try std.testing.expect(try samePlaceholders("{n} for {name}", "{name}: {n}"));
    try std.testing.expect(!try samePlaceholders("{name}", "{other}"));
    try std.testing.expectError(error.InvalidPlaceholder, placeholders("{bad"));
}

test "PO continuation, context, plurals, fuzzy and duplicate rejection" {
    const po = try parsePo("msgid \"\"\nmsgstr \"\"\n\"Language: ru\\n\"\n\n" ++
        "#, fuzzy\nmsgctxt \"files\"\nmsgid \"{n} file\"\nmsgid_plural \"{n} files\"\n" ++
        "msgstr[0] \"{n} файл\"\nmsgstr[1] \"{n} файла\"\nmsgstr[2] \"{n} файлов\"\n");
    try std.testing.expectEqual(@as(usize, 2), po.items.len);
    try std.testing.expectEqualStrings("ru", header(po.items, "Language"));
    try std.testing.expect(po.items[1].fuzzy);
    try std.testing.expectEqual(@as(usize, 3), po.items[1].count);
    try std.testing.expectEqualStrings("files", po.items[1].context);
    try std.testing.expectError(error.DuplicatePoEntry, parsePo("msgid \"A\"\nmsgstr \"B\"\n\nmsgid \"A\"\nmsgstr \"C\"\n"));
}

test "pseudo locale preserves named placeholders and strftime directives" {
    const value = try pseudo("{first_name}: %-d %B %Y");
    try std.testing.expect(try samePlaceholders("{first_name}: %-d %B %Y", value));
    try std.testing.expect(std.mem.indexOf(u8, value, "%-d %B %Y") != null);
}

test "validation rejects stale ids, placeholders, plural families and unsupported French spaces" {
    const source = [_]Entry{ .{ .id = "{n} file", .plural = "{n} files" }, .{ .id = "Open" } };
    const plural = [_]Entry{.{ .id = "{n} file", .plural = "{n} files", .count = 2, .forms = .{ "{n} файл", "{n} файлов", "" } }};
    try std.testing.expectError(error.WrongPluralCount, validate("ru", &plural, &source));
    const stale = [_]Entry{.{ .id = "Missing", .count = 1 }};
    try std.testing.expectError(error.StaleTranslation, validate("de", &stale, &source));
    const bad = [_]Entry{.{ .id = "Open", .count = 1, .forms = .{ "{name}", "", "" } }};
    try std.testing.expectError(error.PlaceholderMismatch, validate("de", &bad, &source));
    const space = [_]Entry{.{ .id = "Open", .count = 1, .forms = .{ "Ouvrir\xe2\x80\xaf!", "", "" } }};
    try std.testing.expectError(error.UseNoBreakSpaceU00A0, validate("fr", &space, &source));
}
