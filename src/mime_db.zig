//! Filename MIME classification from the shared-mime-info database, without
//! GIO: `globs2`, `aliases`, `subclasses`, `icons`, `generic-icons` and the
//! per-type XML comments under `$XDG_DATA_HOME` and `$XDG_DATA_DIRS`.
//! Names only; file contents are never read. The database loads on first use,
//! is immutable afterwards, and is rechecked at most every few seconds when
//! asked (a changed `globs2` swaps in a fresh copy). Every returned slice
//! lives for the rest of the process: replaced copies are retired, not freed,
//! because other threads may still hold their strings.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const unknown = "application/octet-stream";
pub const directory = "inode/directory";

const recheck_seconds = 5;
const max_matches = 32;
const name_max = 255;

const Glob = struct {
    mime: []const u8,
    weight: u8,
    len: u16,
    /// Index of the data directory the entry came from (0 = most specific).
    dir: u8,
};

const Pattern = struct {
    glob: Glob,
    pattern: [:0]const u8,
    case_sensitive: bool,
};

const Parents = std.ArrayList([]const u8);

extern fn fnmatch(pattern: [*:0]const u8, name: [*:0]const u8, flags: c_int) c_int;

pub const Db = struct {
    arena: std.heap.ArenaAllocator,
    /// `<data dir>/mime`, most specific first.
    dirs: std.ArrayList([:0]const u8) = .empty,
    /// Modification time of each directory's `globs2`, for staleness checks.
    stamp: std.ArrayList(i128) = .empty,
    literals: std.StringHashMapUnmanaged(Glob) = .empty,
    literals_ci: std.StringHashMapUnmanaged(Glob) = .empty,
    /// `*.ext` patterns keyed by everything after the `*`.
    suffixes: std.StringHashMapUnmanaged(Glob) = .empty,
    suffixes_ci: std.StringHashMapUnmanaged(Glob) = .empty,
    patterns: std.ArrayList(Pattern) = .empty,
    /// `__NOGLOBS__`: lower-priority directories lose this type's globs.
    no_globs: std.StringHashMapUnmanaged(u8) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    parents: std.StringHashMapUnmanaged(Parents) = .empty,
    icons: std.StringHashMapUnmanaged([]const u8) = .empty,
    generic_icons: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(backing: Allocator) Db {
        return .{ .arena = .init(backing) };
    }

    pub fn deinit(self: *Db) void {
        self.arena.deinit();
    }

    // ---- loading -------------------------------------------------------

    pub fn addGlobs(self: *Db, text: []const u8, dir: u8) Allocator.Error!void {
        const a = self.arena.allocator();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const first = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const rest = line[first + 1 ..];
            const second = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const weight = std.fmt.parseInt(u8, line[0..first], 10) catch continue;
            const mime = rest[0..second];
            var pattern = rest[second + 1 ..];
            var case_sensitive = false;
            if (std.mem.indexOfScalar(u8, pattern, ':')) |colon| {
                var flags = std.mem.splitScalar(u8, pattern[colon + 1 ..], ',');
                while (flags.next()) |flag| {
                    if (std.mem.eql(u8, flag, "cs")) case_sensitive = true;
                }
                pattern = pattern[0..colon];
            }
            if (mime.len == 0 or pattern.len == 0) continue;
            const owned_mime = try self.intern(mime);
            if (std.mem.eql(u8, pattern, "__NOGLOBS__")) {
                const entry = try self.no_globs.getOrPut(a, owned_mime);
                if (!entry.found_existing or entry.value_ptr.* > dir) entry.value_ptr.* = dir;
                continue;
            }
            const glob: Glob = .{
                .mime = owned_mime,
                .weight = weight,
                .len = @intCast(@min(pattern.len, std.math.maxInt(u16))),
                .dir = dir,
            };
            const key = if (case_sensitive) try a.dupe(u8, pattern) else try std.ascii.allocLowerString(a, pattern);
            // The database writes a case-sensitive glob and then the same
            // glob again without the flag: the flag sticks.
            if (std.mem.indexOfAny(u8, key, "*?[\\") == null) {
                try self.putGlob(&self.literals, &self.literals_ci, key, pattern, glob, case_sensitive);
            } else if (key[0] == '*' and std.mem.indexOfAny(u8, key[1..], "*?[\\") == null) {
                try self.putGlob(&self.suffixes, &self.suffixes_ci, key[1..], pattern[1..], glob, case_sensitive);
            } else {
                try self.patterns.append(a, .{ .glob = glob, .pattern = try a.dupeSentinel(u8, key, 0), .case_sensitive = case_sensitive });
            }
        }
    }

    pub fn addAliases(self: *Db, text: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var fields = std.mem.tokenizeAny(u8, raw, " \t\r");
            const alias = fields.next() orelse continue;
            if (alias[0] == '#') continue;
            const canonical = fields.next() orelse continue;
            const entry = try self.aliases.getOrPut(a, try self.intern(alias));
            if (!entry.found_existing) entry.value_ptr.* = try self.intern(canonical);
        }
    }

    pub fn addSubclasses(self: *Db, text: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var fields = std.mem.tokenizeAny(u8, raw, " \t\r");
            const child = fields.next() orelse continue;
            if (child[0] == '#') continue;
            const parent = fields.next() orelse continue;
            const entry = try self.parents.getOrPut(a, try self.intern(child));
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(a, try self.intern(parent));
        }
    }

    /// `mime:icon-name` lines, shared by `icons` and `generic-icons`.
    pub fn addIcons(self: *Db, text: []const u8, generic: bool) Allocator.Error!void {
        const a = self.arena.allocator();
        const map = if (generic) &self.generic_icons else &self.icons;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (colon == 0 or colon + 1 == line.len) continue;
            const entry = try map.getOrPut(a, try self.intern(line[0..colon]));
            if (!entry.found_existing) entry.value_ptr.* = try a.dupe(u8, line[colon + 1 ..]);
        }
    }

    fn intern(self: *Db, s: []const u8) Allocator.Error![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    fn putGlob(
        self: *Db,
        exact: *std.StringHashMapUnmanaged(Glob),
        folded: *std.StringHashMapUnmanaged(Glob),
        key: []const u8,
        original: []const u8,
        glob: Glob,
        case_sensitive: bool,
    ) Allocator.Error!void {
        const a = self.arena.allocator();
        if (case_sensitive) {
            if (folded.get(key)) |old| if (std.mem.eql(u8, old.mime, glob.mime) and old.dir == glob.dir) {
                _ = folded.remove(key);
            };
        } else if (exact.get(original)) |old| {
            if (std.mem.eql(u8, old.mime, glob.mime) and old.dir == glob.dir) return;
        }
        const map = if (case_sensitive) exact else folded;
        const entry = try map.getOrPut(a, key);
        if (!entry.found_existing or better(glob, entry.value_ptr.*)) entry.value_ptr.* = glob;
    }

    // ---- queries -------------------------------------------------------

    /// Best name match, or null when no glob applies.
    pub fn guess(self: *const Db, base: []const u8) ?[]const u8 {
        if (base.len == 0 or base.len > name_max) return null;
        var lower_buf: [name_max + 1]u8 = undefined;
        const lower = std.ascii.lowerString(&lower_buf, base);
        lower_buf[base.len] = 0;
        const lower_z: [*:0]const u8 = @ptrCast(&lower_buf);
        var base_buf: [name_max + 1]u8 = undefined;
        @memcpy(base_buf[0..base.len], base);
        base_buf[base.len] = 0;
        const base_z: [*:0]const u8 = @ptrCast(&base_buf);

        // Literal names beat suffix globs, which beat general patterns: a
        // lower-weight literal still wins over a heavier wildcard, as in GIO.
        var best: ?Glob = null;
        if (self.literals.get(base)) |g| self.consider(&best, g);
        if (self.literals_ci.get(lower)) |g| self.consider(&best, g);
        if (best == null) {
            var i: usize = 0;
            while (i < base.len) : (i += 1) {
                if (self.suffixes.get(base[i..])) |g| self.consider(&best, g);
                if (self.suffixes_ci.get(lower[i..])) |g| self.consider(&best, g);
            }
        }
        if (best == null) {
            for (self.patterns.items) |p| {
                const name = if (p.case_sensitive) base_z else lower_z;
                if (fnmatch(p.pattern, name, 0) == 0) self.consider(&best, p.glob);
            }
        }
        return if (best) |g| g.mime else null;
    }

    fn consider(self: *const Db, best: *?Glob, g: Glob) void {
        if (self.no_globs.get(g.mime)) |dir| if (g.dir > dir) return;
        if (best.* == null or better(g, best.*.?)) best.* = g;
    }

    pub fn unalias(self: *const Db, mime: []const u8) []const u8 {
        return self.aliases.get(mime) orelse mime;
    }

    pub fn equals(self: *const Db, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, self.unalias(a), self.unalias(b));
    }

    pub fn isA(self: *const Db, mime: []const u8, parent: []const u8) bool {
        return self.isAUnaliased(self.unalias(mime), self.unalias(parent), 0);
    }

    fn isAUnaliased(self: *const Db, mime: []const u8, parent: []const u8, depth: u8) bool {
        if (std.mem.eql(u8, mime, parent)) return true;
        // Implicit rules of the specification.
        if (std.mem.eql(u8, parent, unknown) and !std.mem.startsWith(u8, mime, "inode/")) return true;
        if (std.mem.eql(u8, parent, "text/plain") and std.mem.startsWith(u8, mime, "text/")) return true;
        if (depth >= 16) return false;
        const list = self.parents.get(mime) orelse return false;
        for (list.items) |next| {
            if (self.isAUnaliased(self.unalias(next), parent, depth + 1)) return true;
        }
        return false;
    }

    /// Themed icon names in preference order: the type's own icon, the dashed
    /// type name, then its generic icon, without repeats. Slices point into
    /// `self` or `buf`.
    pub fn iconNames(self: *const Db, mime: []const u8, buf: *IconBuffer) []const []const u8 {
        const canonical = self.unalias(mime);
        var count: usize = 0;
        if (self.icons.get(canonical)) |name| count = appendUnique(buf, count, name);
        if (mime.len <= buf.dashed.len) {
            @memcpy(buf.dashed[0..mime.len], mime);
            for (buf.dashed[0..mime.len]) |*ch| {
                if (ch.* == '/') ch.* = '-';
            }
            count = appendUnique(buf, count, buf.dashed[0..mime.len]);
        }
        if (self.generic_icons.get(canonical)) |name| {
            count = appendUnique(buf, count, name);
        } else {
            const suffix = "-x-generic";
            const media_len = std.mem.indexOfScalar(u8, canonical, '/') orelse canonical.len;
            if (media_len + suffix.len <= buf.generic.len) {
                @memcpy(buf.generic[0..media_len], canonical[0..media_len]);
                @memcpy(buf.generic[media_len..][0..suffix.len], suffix);
                count = appendUnique(buf, count, buf.generic[0 .. media_len + suffix.len]);
            }
        }
        return buf.names[0..count];
    }
};

fn appendUnique(buf: *IconBuffer, count: usize, name: []const u8) usize {
    for (buf.names[0..count]) |existing| if (std.mem.eql(u8, existing, name)) return count;
    buf.names[count] = name;
    return count + 1;
}

fn better(a: Glob, b: Glob) bool {
    return a.weight > b.weight or (a.weight == b.weight and a.len > b.len);
}

pub const IconBuffer = struct {
    names: [3][]const u8 = undefined,
    dashed: [160]u8 = undefined,
    generic: [64]u8 = undefined,
};

// ---- process-wide database ------------------------------------------------

var mutex: std.Io.Mutex = .init;
var state: std.atomic.Value(?*Db) = .init(null);
var last_check: std.atomic.Value(i64) = .init(0);

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn now() i64 {
    var ts: std.posix.timespec = undefined;
    return switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => ts.sec,
        else => 0,
    };
}

fn current() ?*Db {
    const db = state.load(.acquire) orelse return load();
    const t = now();
    if (t - last_check.load(.monotonic) < recheck_seconds) return db;
    if (!mutex.tryLock()) return db;
    defer mutex.unlock(io());
    last_check.store(t, .monotonic);
    if (!stale(db)) return db;
    return reload();
}

fn load() ?*Db {
    mutex.lockUncancelable(io());
    defer mutex.unlock(io());
    if (state.load(.acquire)) |db| return db;
    last_check.store(now(), .monotonic);
    return reload();
}

fn reload() ?*Db {
    const db = build(std.heap.page_allocator) catch return state.load(.acquire);
    state.store(db, .release);
    return db;
}

fn dataDirs(db: *Db) Allocator.Error!void {
    const a = db.arena.allocator();
    const home = std.c.getenv("XDG_DATA_HOME");
    if (home != null and home.?[0] == '/') {
        try db.dirs.append(a, try std.fmt.allocPrintSentinel(a, "{s}/mime", .{std.mem.span(home.?)}, 0));
    } else if (std.c.getenv("HOME")) |h| {
        try db.dirs.append(a, try std.fmt.allocPrintSentinel(a, "{s}/.local/share/mime", .{std.mem.span(h)}, 0));
    }
    const list = if (std.c.getenv("XDG_DATA_DIRS")) |v| std.mem.span(v) else "";
    var it = std.mem.tokenizeScalar(u8, if (list.len > 0) list else "/usr/local/share:/usr/share", ':');
    while (it.next()) |dir| {
        if (dir[0] != '/') continue;
        try db.dirs.append(a, try std.fmt.allocPrintSentinel(a, "{s}/mime", .{std.mem.trimEnd(u8, dir, "/")}, 0));
    }
}

fn mtime(path: []const u8) i128 {
    const stat = std.Io.Dir.cwd().statFile(io(), path, .{}) catch return 0;
    return stat.mtime.nanoseconds;
}

fn stale(db: *const Db) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (db.dirs.items, db.stamp.items) |dir, stamp| {
        const path = std.fmt.bufPrint(&buf, "{s}/globs2", .{dir}) catch continue;
        if (mtime(path) != stamp) return true;
    }
    return false;
}

fn readFile(a: Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(io(), path, a, .limited(16 * 1024 * 1024)) catch null;
}

fn build(backing: Allocator) !*Db {
    const db = try backing.create(Db);
    errdefer backing.destroy(db);
    db.* = Db.init(backing);
    errdefer db.deinit();
    try dataDirs(db);
    const scratch_backing = std.heap.page_allocator;
    for (db.dirs.items, 0..) |dir, i| {
        const index: u8 = @intCast(@min(i, std.math.maxInt(u8)));
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const globs_path = std.fmt.bufPrint(&buf, "{s}/globs2", .{dir}) catch "";
        try db.stamp.append(db.arena.allocator(), mtime(globs_path));
        inline for (.{ "globs2", "aliases", "subclasses", "icons", "generic-icons" }, 0..) |name, kind| {
            if (readFile(scratch_backing, dir, name)) |text| {
                defer scratch_backing.free(text);
                switch (kind) {
                    0 => try db.addGlobs(text, index),
                    1 => try db.addAliases(text),
                    2 => try db.addSubclasses(text),
                    3 => try db.addIcons(text, false),
                    else => try db.addIcons(text, true),
                }
            }
        }
    }
    return db;
}

// ---- public API -------------------------------------------------------------

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// MIME type for a file name or path, `application/octet-stream` when no glob
/// matches. A trailing slash means a directory.
pub fn guess(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, "/")) return directory;
    const db = current() orelse return unknown;
    return db.guess(baseName(path)) orelse unknown;
}

pub fn isA(mime: []const u8, parent: []const u8) bool {
    const db = current() orelse return std.mem.eql(u8, mime, parent);
    return db.isA(mime, parent);
}

/// Same type after resolving aliases (`video/x-matroska` = `video/matroska`).
pub fn equals(a: []const u8, b: []const u8) bool {
    const db = current() orelse return std.mem.eql(u8, a, b);
    return db.equals(a, b);
}

/// Icon names to try for a type, best first. Valid until `buf` is reused.
pub fn iconNames(mime: []const u8, buf: *IconBuffer) []const []const u8 {
    const db = current() orelse {
        buf.names[0] = "application-x-generic";
        return buf.names[0..1];
    };
    return db.iconNames(mime, buf);
}

// ---- descriptions -----------------------------------------------------------

/// Locale names to prefer, most specific first, ending with "C": the same
/// order as `g_get_language_names`.
fn languages(a: Allocator, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    const locale = firstSet(&.{ "LC_ALL", "LC_MESSAGES", "LANG" });
    if (std.c.getenv("LANGUAGE")) |list| {
        if (locale != null and !std.mem.eql(u8, locale.?, "C") and !std.mem.eql(u8, locale.?, "POSIX")) {
            var it = std.mem.tokenizeScalar(u8, std.mem.span(list), ':');
            while (it.next()) |name| try variants(a, out, name);
        }
    }
    if (locale) |name| try variants(a, out, name);
    try out.append(a, "C");
}

fn firstSet(names: []const [:0]const u8) ?[]const u8 {
    for (names) |name| {
        if (std.c.getenv(name)) |v| if (v[0] != 0) return std.mem.span(v);
    }
    return null;
}

/// `ll_CC.enc@mod` expands to every combination that keeps `ll`.
fn variants(a: Allocator, out: *std.ArrayList([]const u8), locale: []const u8) Allocator.Error!void {
    var rest = locale;
    var modifier: []const u8 = "";
    var codeset: []const u8 = "";
    var territory: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '@')) |i| {
        modifier = rest[i..];
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, '.')) |i| {
        codeset = rest[i..];
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, '_')) |i| {
        territory = rest[i..];
        rest = rest[0..i];
    }
    if (rest.len == 0) return;
    var mask: u3 = 7;
    while (true) : (mask -= 1) {
        const name = try std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{
            rest,
            if (mask & 4 != 0) territory else "",
            if (mask & 2 != 0) codeset else "",
            if (mask & 1 != 0) modifier else "",
        });
        var dup = false;
        for (out.items) |existing| dup = dup or std.mem.eql(u8, existing, name);
        if (!dup) try out.append(a, name);
        if (mask == 0) break;
    }
}

/// Localized description of a type ("PNG image"), taken from the per-type XML
/// next to the database; `"<type> type"` when no description exists.
pub fn description(a: Allocator, mime: []const u8) Allocator.Error![]u8 {
    const db = current();
    const type_name = if (db) |d| d.unalias(mime) else mime;
    if (std.mem.indexOfAny(u8, type_name, "\\\x00") != null or std.mem.indexOf(u8, type_name, "..") != null) {
        return std.fmt.allocPrint(a, "{s} type", .{type_name});
    }
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var langs: std.ArrayList([]const u8) = .empty;
    try languages(arena.allocator(), &langs);
    if (db) |d| {
        var name_buf: [256]u8 = undefined;
        const file = std.fmt.bufPrint(&name_buf, "{s}.xml", .{type_name}) catch return std.fmt.allocPrint(a, "{s} type", .{type_name});
        for (d.dirs.items) |dir| {
            const xml = readFile(arena.allocator(), dir, file) orelse continue;
            if (pickComment(arena.allocator(), xml, langs.items)) |text| return a.dupe(u8, text);
            break;
        }
    }
    return std.fmt.allocPrint(a, "{s} type", .{type_name});
}

fn pickComment(a: Allocator, xml: []const u8, langs: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_rank: usize = std.math.maxInt(usize);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, xml, at, "<comment")) |open| {
        const tag_end = std.mem.indexOfScalarPos(u8, xml, open, '>') orelse break;
        const tag = xml[open + "<comment".len .. tag_end];
        at = tag_end + 1;
        if (tag.len > 0 and tag[tag.len - 1] == '/') continue;
        if (tag.len > 0 and tag[0] != ' ' and tag[0] != '\t' and tag[0] != '\n') continue;
        const close = std.mem.indexOfPos(u8, xml, at, "</comment>") orelse break;
        const body = xml[at..close];
        at = close;
        const lang = attribute(tag, "xml:lang") orelse "C";
        var rank: usize = 0;
        while (rank < langs.len) : (rank += 1) {
            if (std.mem.eql(u8, langs[rank], lang)) break;
        }
        if (rank >= best_rank or rank == langs.len) continue;
        best_rank = rank;
        best = unescape(a, body) catch null;
        if (rank == 0) break;
    }
    return best;
}

fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, tag, at, name)) |i| {
        at = i + name.len;
        var j = at;
        while (j < tag.len and tag[j] == ' ') j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and tag[j] == ' ') j += 1;
        if (j >= tag.len or (tag[j] != '"' and tag[j] != '\'')) continue;
        const quote = tag[j];
        const end = std.mem.indexOfScalarPos(u8, tag, j + 1, quote) orelse return null;
        return tag[j + 1 .. end];
    }
    return null;
}

fn unescape(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            const entities = [_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' }, .{ "&apos;", '\'' } };
            var matched = false;
            for (entities) |e| {
                if (std.mem.startsWith(u8, text[i..], e[0])) {
                    try out.append(a, e[1]);
                    i += e[0].len;
                    matched = true;
                    break;
                }
            }
            if (matched) continue;
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return out.items;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn fixture() !Db {
    var db: Db = .init(testing.allocator);
    errdefer db.deinit();
    try db.addGlobs(
        \\# comment
        \\50:text/plain:*.txt
        \\50:application/gzip:*.gz
        \\50:application/x-compressed-tar:*.tar.gz
        \\50:text/x-makefile:Makefile
        \\50:image/png:*.png
        \\50:image/x-xcf:*.xcf
        \\80:text/html:*.html
        \\50:application/x-pdf-fake:*.PDF:cs
        \\50:application/pdf:*.pdf
        \\50:text/x-manual:*.[1-9]
        \\60:application/x-weird:*.x*y
        \\0:model/skipped:__NOGLOBS__
        \\50:model/skipped:*.skip
    , 0);
    try db.addGlobs("50:model/skipped:*.skip2\n", 1);
    try db.addAliases("video/x-matroska video/matroska\n");
    try db.addSubclasses(
        \\text/x-makefile text/plain
        \\application/x-compressed-tar application/gzip
        \\image/svg+xml application/xml
        \\application/xml text/plain
    );
    try db.addIcons("application/pdf:x-pdf\n", false);
    try db.addIcons("text/x-makefile:text-x-script\n", true);
    return db;
}

test "globs pick literals, longest suffix and highest weight" {
    var db = try fixture();
    defer db.deinit();
    try testing.expectEqualStrings("text/plain", db.guess("notes.txt").?);
    try testing.expectEqualStrings("text/x-makefile", db.guess("Makefile").?);
    try testing.expectEqualStrings("application/x-compressed-tar", db.guess("a.tar.gz").?);
    try testing.expectEqualStrings("application/gzip", db.guess("a.gz").?);
    try testing.expectEqualStrings("text/html", db.guess("index.html").?);
    try testing.expectEqualStrings("text/x-manual", db.guess("ls.1").?);
    try testing.expectEqualStrings("application/x-weird", db.guess("a.xzzy").?);
    try testing.expect(db.guess("noextension") == null);
    try testing.expect(db.guess("") == null);
}

test "matching ignores case unless a glob is case sensitive" {
    var db = try fixture();
    defer db.deinit();
    try testing.expectEqualStrings("image/png", db.guess("PHOTO.PNG").?);
    try testing.expectEqualStrings("application/x-pdf-fake", db.guess("A.PDF").?);
    try testing.expectEqualStrings("application/pdf", db.guess("a.Pdf").?);
}

test "a case-sensitive glob repeated without the flag stays case sensitive" {
    var db: Db = .init(testing.allocator);
    defer db.deinit();
    try db.addGlobs("50:text/x-genie:*.gs:cs\n50:text/x-genie:*.gs\n50:application/x-core:core:cs\n50:application/x-core:core\n", 0);
    try testing.expectEqualStrings("text/x-genie", db.guess("a.gs").?);
    try testing.expect(db.guess("A.GS") == null);
    try testing.expect(db.guess("CORE") == null);
    try testing.expectEqualStrings("application/x-core", db.guess("core").?);
}

test "literals and suffixes outrank heavier wildcard patterns" {
    var db: Db = .init(testing.allocator);
    defer db.deinit();
    try db.addGlobs("60:application/x-sharedlib:*.so.[0-9]*\n50:application/x-trash:*.bak\n", 0);
    try testing.expectEqualStrings("application/x-trash", db.guess("libx.so.1.bak").?);
    try testing.expectEqualStrings("application/x-sharedlib", db.guess("libx.so.1").?);
}

test "NOGLOBS hides a type's globs from lower-priority directories only" {
    var db = try fixture();
    defer db.deinit();
    try testing.expectEqualStrings("model/skipped", db.guess("a.skip").?);
    try testing.expect(db.guess("a.skip2") == null);
}

test "aliases and inheritance" {
    var db = try fixture();
    defer db.deinit();
    try testing.expect(db.equals("video/x-matroska", "video/matroska"));
    try testing.expect(!db.equals("video/mp4", "video/matroska"));
    try testing.expect(db.isA("application/x-compressed-tar", "application/gzip"));
    try testing.expect(db.isA("image/svg+xml", "text/plain"));
    try testing.expect(db.isA("text/x-anything", "text/plain"));
    try testing.expect(db.isA("image/png", unknown));
    try testing.expect(!db.isA("inode/directory", unknown));
    try testing.expect(!db.isA("image/png", "text/plain"));
    try testing.expect(db.isA("video/x-matroska", "video/matroska"));
}

test "icon names follow the type, its dashed name and the generic icon" {
    var db = try fixture();
    defer db.deinit();
    var buf: IconBuffer = .{};
    const pdf = db.iconNames("application/pdf", &buf);
    try testing.expectEqual(@as(usize, 3), pdf.len);
    try testing.expectEqualStrings("x-pdf", pdf[0]);
    try testing.expectEqualStrings("application-pdf", pdf[1]);
    try testing.expectEqualStrings("application-x-generic", pdf[2]);
    var other: IconBuffer = .{};
    const make = db.iconNames("text/x-makefile", &other);
    try testing.expectEqualStrings("text-x-makefile", make[0]);
    try testing.expectEqualStrings("text-x-script", make[1]);
}

test "language variants run from specific to general" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try variants(arena.allocator(), &out, "pt_BR.UTF-8");
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqualStrings("pt_BR.UTF-8", out.items[0]);
    try testing.expectEqualStrings("pt_BR", out.items[1]);
    try testing.expectEqualStrings("pt.UTF-8", out.items[2]);
    try testing.expectEqualStrings("pt", out.items[3]);
}

test "comments choose the best language and decode entities" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const xml =
        \\<mime-type type="text/html">
        \\  <comment>HTML &amp; friends</comment>
        \\  <comment xml:lang="pt_BR">documento HTML</comment>
        \\  <comment xml:lang="de">HTML-Dokument</comment>
        \\</mime-type>
    ;
    try testing.expectEqualStrings("documento HTML", pickComment(arena.allocator(), xml, &.{ "pt_BR", "pt", "C" }).?);
    try testing.expectEqualStrings("HTML & friends", pickComment(arena.allocator(), xml, &.{ "fr", "C" }).?);
    try testing.expect(pickComment(arena.allocator(), xml, &.{"fr"}) == null);
}

test "public lookups work against the installed database" {
    // The installed database may be absent in a build sandbox; only check
    // that nothing crashes and unknown names stay unknown.
    try testing.expectEqualStrings(directory, guess("/tmp/"));
    _ = guess("/tmp/archive.tar.gz");
    try testing.expect(isA("text/x-anything", "text/plain"));
}
