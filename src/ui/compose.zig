//! Dead keys and Compose sequences for text fields that read raw xkb keys.
//!
//! `xkb_state_key_get_utf8` returns nothing for a dead key, so a field that
//! only asks it for text drops the accent: ´ then a never becomes á. Every
//! compositor-drawn field and every app client feeds its key presses here
//! first. A press that starts or continues a sequence is `consumed` (typed
//! text arrives when the sequence completes); anything else is `null` and
//! takes the ordinary path.
//!
//! The table comes from the user's language, not from `C`: ´ then c is ç in
//! `pt_BR` and ć elsewhere. It is built lazily, so a session that never
//! presses a dead key never loads one, and one table is shared by every
//! `Compose` in the process.
const std = @import("std");
const c = @import("c_gfx");

/// Longest normalized locale name kept (`ll_CC.UTF-8` plus slack).
const max_locale = 48;
/// Used for an unset or unusable locale; its table has the ordinary dead-key
/// sequences.
const fallback_locale = "C.UTF-8";

/// XKB_KEY_dead_grave through XKB_KEY_dead_longsolidusoverlay, and Multi_key.
const dead_first: u32 = 0xfe50;
const dead_last: u32 = 0xfe93;
const multi_key: u32 = 0xff20;

/// Whether `sym` can begin a sequence, so a press of it must not be typed.
pub fn startsSequence(sym: u32) bool {
    return (sym >= dead_first and sym <= dead_last) or sym == multi_key;
}

/// `ll_CC.utf8@modifier` as `ll_CC.UTF-8`. xkbcommon finds a Compose file by
/// locale name: a name without an encoding (`pt_BR`) maps to the ISO 8859-1
/// file, which does not parse as UTF-8, and a modifier is not part of the
/// name. The text we produce is always UTF-8.
pub fn normalizeLocale(out: *[max_locale]u8, raw: []const u8) []const u8 {
    const suffix = ".UTF-8";
    var name = raw;
    if (std.mem.indexOfScalar(u8, name, '@')) |at| name = name[0..at];
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| name = name[0..dot];
    if (name.len == 0 or std.mem.eql(u8, name, "C") or std.mem.eql(u8, name, "POSIX") or name.len + suffix.len > out.len) return fallback_locale;
    @memcpy(out[0..name.len], name);
    @memcpy(out[name.len..][0..suffix.len], suffix);
    return out[0 .. name.len + suffix.len];
}

/// The locale for LC_CTYPE, in POSIX precedence; empty when none is set.
pub fn localeFromEnviron(environ: std.process.Environ) []const u8 {
    inline for (.{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        if (environ.getPosix(name)) |value| if (value.len != 0) return value;
    }
    return "";
}

// Main thread only. States hold their own reference to the table they were
// made from, so replacing the cached table never invalidates a pending one.
var cache: struct {
    key: [max_locale]u8 = undefined,
    key_len: usize = 0,
    table: ?*c.xkb_compose_table = null,
    loaded: bool = false,
} = .{};

fn load(locale: []const u8) ?*c.xkb_compose_table {
    const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return null;
    defer c.xkb_context_unref(context);
    var name: [max_locale + 1]u8 = undefined;
    @memcpy(name[0..locale.len], locale);
    name[locale.len] = 0;
    return c.xkb_compose_table_new_from_locale(context, @ptrCast(&name), c.XKB_COMPOSE_COMPILE_NO_FLAGS);
}

/// The table for a normalized `locale`, loaded on first use. A locale with no
/// Compose file falls back to `C.UTF-8`; the answer is cached either way so a
/// bad name is not retried (and logged by xkbcommon) on every press.
fn table(locale: []const u8) ?*c.xkb_compose_table {
    if (cache.loaded and std.mem.eql(u8, cache.key[0..cache.key_len], locale)) return cache.table;
    if (cache.table) |old| c.xkb_compose_table_unref(old);
    cache.table = load(locale) orelse if (std.mem.eql(u8, locale, fallback_locale)) null else load(fallback_locale);
    @memcpy(cache.key[0..locale.len], locale);
    cache.key_len = locale.len;
    cache.loaded = true;
    return cache.table;
}

/// Loads the table for `locale` now. For a process that is about to lose its
/// filesystem (the PDF viewer's sandbox): the first dead key would otherwise
/// find nothing to read.
pub fn preload(locale: []const u8) void {
    var buf: [max_locale]u8 = undefined;
    _ = table(normalizeLocale(&buf, locale));
}

/// Drops the shared table; for shutdown and tests.
pub fn flushTable() void {
    if (cache.table) |old| c.xkb_compose_table_unref(old);
    cache = .{};
}

pub const Compose = struct {
    state: ?*c.xkb_compose_state = null,
    locale: [max_locale]u8 = undefined,
    locale_len: usize = 0,
    /// The last `feed` returned text or swallowed the key. Callers that ask
    /// whether a press may repeat after delivering it read this.
    consumed: bool = false,

    pub fn deinit(self: *Compose) void {
        if (self.state) |state| c.xkb_compose_state_unref(state);
        self.state = null;
        self.consumed = false;
    }

    /// Forgets a half-typed sequence (focus moved, a shortcut modifier went
    /// down, the field closed).
    pub fn reset(self: *Compose) void {
        if (self.state) |state| c.xkb_compose_state_reset(state);
        self.consumed = false;
    }

    /// A dead key or Compose key is down and the next key completes it.
    pub fn pending(self: *const Compose) bool {
        const state = self.state orelse return false;
        return c.xkb_compose_state_get_status(state) == c.XKB_COMPOSE_COMPOSING;
    }

    /// Whether the next press of `sym` will be taken by a sequence. Callers
    /// that decide on key repeat before delivering the press ask this.
    pub fn willConsume(self: *const Compose, sym: u32) bool {
        return startsSequence(sym) or self.pending();
    }

    /// One key press. Null: not part of a sequence, type it as usual. Empty:
    /// a sequence is pending (or was cancelled by this key); type nothing.
    /// Otherwise the composed text, in `buf` (at least 8 bytes). Call it only
    /// for presses without Ctrl, Alt or Super, and `reset` when those go down.
    /// `locale` is the user's language (`LANG`-style); an unusable one falls
    /// back to `C.UTF-8`.
    pub fn feed(self: *Compose, locale: []const u8, sym: u32, buf: []u8) ?[]const u8 {
        if (!self.willConsume(sym)) {
            self.consumed = false;
            return null;
        }
        const result = self.advance(locale, sym, buf);
        self.consumed = result != null;
        return result;
    }

    fn advance(self: *Compose, locale: []const u8, sym: u32, buf: []u8) ?[]const u8 {
        var name_buf: [max_locale]u8 = undefined;
        const name = normalizeLocale(&name_buf, locale);
        if (self.state != null and !std.mem.eql(u8, self.locale[0..self.locale_len], name)) self.deinit();
        const state = self.state orelse blk: {
            const fresh = c.xkb_compose_state_new(table(name) orelse return null, c.XKB_COMPOSE_STATE_NO_FLAGS) orelse return null;
            @memcpy(self.locale[0..name.len], name);
            self.locale_len = name.len;
            self.state = fresh;
            break :blk fresh;
        };
        _ = c.xkb_compose_state_feed(state, sym);
        switch (c.xkb_compose_state_get_status(state)) {
            c.XKB_COMPOSE_COMPOSING => return "",
            c.XKB_COMPOSE_COMPOSED => {
                const n = c.xkb_compose_state_get_utf8(state, buf.ptr, buf.len);
                c.xkb_compose_state_reset(state);
                return buf[0..@min(@as(usize, @intCast(@max(n, 0))), buf.len -| 1)];
            },
            c.XKB_COMPOSE_CANCELLED => {
                c.xkb_compose_state_reset(state);
                return "";
            },
            else => return null,
        }
    }
};

const dead_acute: u32 = 0xfe51;
const dead_tilde: u32 = 0xfe53;

fn needTable(compose: *Compose, locale: []const u8) !void {
    var scratch: [16]u8 = undefined;
    // A machine without X11 locale data has no table; nothing to test then.
    if (compose.feed(locale, dead_acute, &scratch) == null) return error.SkipZigTest;
    compose.reset();
}

test "dead keys and the Compose key start sequences, ordinary keys do not" {
    try std.testing.expect(startsSequence(dead_acute));
    try std.testing.expect(startsSequence(dead_first));
    try std.testing.expect(startsSequence(dead_last));
    try std.testing.expect(startsSequence(multi_key));
    try std.testing.expect(!startsSequence('a'));
    try std.testing.expect(!startsSequence(dead_first - 1));
    try std.testing.expect(!startsSequence(dead_last + 1));
}

test "locale names get a UTF-8 encoding and lose their modifier" {
    var buf: [max_locale]u8 = undefined;
    try std.testing.expectEqualStrings("pt_BR.UTF-8", normalizeLocale(&buf, "pt_BR.utf8"));
    try std.testing.expectEqualStrings("pt_BR.UTF-8", normalizeLocale(&buf, "pt_BR"));
    try std.testing.expectEqualStrings("es_MX.UTF-8", normalizeLocale(&buf, "es_MX.ISO-8859-1@euro"));
    try std.testing.expectEqualStrings("de.UTF-8", normalizeLocale(&buf, "de@x"));
    try std.testing.expectEqualStrings(fallback_locale, normalizeLocale(&buf, ""));
    try std.testing.expectEqualStrings(fallback_locale, normalizeLocale(&buf, "C"));
    try std.testing.expectEqualStrings(fallback_locale, normalizeLocale(&buf, "POSIX"));
    try std.testing.expectEqualStrings(fallback_locale, normalizeLocale(&buf, "C.UTF-8"));
    try std.testing.expectEqualStrings(fallback_locale, normalizeLocale(&buf, &@as([60]u8, @splat('x'))));
}

test "ordinary keys pass through without loading a table" {
    flushTable();
    var compose: Compose = .{};
    defer compose.deinit();
    var buf: [16]u8 = undefined;
    try std.testing.expect(compose.feed("pt_BR.utf8", 'a', &buf) == null);
    try std.testing.expect(!compose.consumed);
    try std.testing.expect(compose.state == null);
    try std.testing.expect(!cache.loaded);
}

test "a dead key then a letter composes the accented letter" {
    var compose: Compose = .{};
    defer compose.deinit();
    try needTable(&compose, "C.UTF-8");
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", compose.feed("C.UTF-8", dead_acute, &buf).?);
    try std.testing.expect(compose.pending());
    try std.testing.expect(compose.consumed);
    try std.testing.expect(compose.willConsume('a'));
    try std.testing.expectEqualStrings("á", compose.feed("C.UTF-8", 'a', &buf).?);
    try std.testing.expect(!compose.pending());
    try std.testing.expect(compose.consumed);
    try std.testing.expect(compose.feed("C.UTF-8", 'a', &buf) == null);
    try std.testing.expect(!compose.consumed);
    try std.testing.expectEqualStrings("", compose.feed("C.UTF-8", dead_tilde, &buf).?);
    try std.testing.expectEqualStrings("ã", compose.feed("C.UTF-8", 'a', &buf).?);
}

test "a key that does not fit the sequence cancels it" {
    var compose: Compose = .{};
    defer compose.deinit();
    try needTable(&compose, "C.UTF-8");
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", compose.feed("C.UTF-8", dead_acute, &buf).?);
    try std.testing.expectEqualStrings("", compose.feed("C.UTF-8", 'x', &buf).?);
    try std.testing.expect(!compose.pending());
    try std.testing.expect(compose.feed("C.UTF-8", 'x', &buf) == null);
}

test "reset forgets a pending dead key" {
    var compose: Compose = .{};
    defer compose.deinit();
    try needTable(&compose, "C.UTF-8");
    var buf: [16]u8 = undefined;
    _ = compose.feed("C.UTF-8", dead_acute, &buf);
    try std.testing.expect(compose.pending());
    compose.reset();
    try std.testing.expect(!compose.pending());
    try std.testing.expect(compose.feed("C.UTF-8", 'a', &buf) == null);
}

test "acute then c follows the language: ç in Portuguese, ć otherwise" {
    var compose: Compose = .{};
    defer compose.deinit();
    try needTable(&compose, "pt_BR.utf8");
    var buf: [16]u8 = undefined;
    _ = compose.feed("pt_BR.utf8", dead_acute, &buf);
    const portuguese = compose.feed("pt_BR.utf8", 'c', &buf).?;
    // Without the pt_BR Compose file the fallback table answers; only the
    // real one can be checked.
    if (std.mem.eql(u8, portuguese, "ć")) return error.SkipZigTest;
    try std.testing.expectEqualStrings("ç", portuguese);
    // The same state, told another language, switches table.
    _ = compose.feed("es_MX.utf8", dead_acute, &buf);
    try std.testing.expectEqualStrings("ć", compose.feed("es_MX.utf8", 'c', &buf).?);
}

test "an unknown locale falls back instead of failing" {
    flushTable();
    var compose: Compose = .{};
    defer compose.deinit();
    var buf: [16]u8 = undefined;
    const first = compose.feed("xx_XX.utf8", dead_acute, &buf) orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("", first);
    try std.testing.expectEqualStrings("á", compose.feed("xx_XX.utf8", 'a', &buf).?);
}
