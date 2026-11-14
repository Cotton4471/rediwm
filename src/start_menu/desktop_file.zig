//! Parsing .desktop files: the locale and localized keys, escapes, TryExec and desktop visibility.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = std.posix.system;
const i18n = @import("i18n");

pub const Locale = struct {
    lang: []const u8 = "",
    country: []const u8 = "",
    modifier: []const u8 = "",

    pub fn fromEnv(environ: std.process.Environ) Locale {
        const raw = i18n.resolve("", environ);
        return forLanguage(raw);
    }

    /// The catalog's bare Portuguese choice follows Brazilian Portuguese.
    /// Keep parsing desktop-entry keys pure so Name[pt_BR] outranks Name[pt].
    pub fn forLanguage(raw: []const u8) Locale {
        var locale = parseLocale(raw);
        if (locale.country.len == 0 and std.ascii.eqlIgnoreCase(locale.lang, "pt")) locale.country = "BR";
        return locale;
    }

    pub fn parseLocale(raw: []const u8) Locale {
        var loc = Locale{};
        var rest = raw;
        // Strip encoding (.UTF-8)
        if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
            const before_dot = rest[0..dot];
            const after_dot = rest[dot + 1 ..];
            if (std.mem.indexOfScalar(u8, after_dot, '@')) |at| {
                loc.modifier = after_dot[at + 1 ..];
            }
            rest = before_dot;
        } else if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
            loc.modifier = rest[at + 1 ..];
            rest = rest[0..at];
        }

        if (std.mem.indexOfAny(u8, rest, "_-")) |us| {
            loc.lang = rest[0..us];
            loc.country = rest[us + 1 ..];
        } else {
            loc.lang = rest;
        }
        return loc;
    }
};

pub const ParsedEntry = struct {
    is_application: bool = false,
    no_display: bool = false,
    hidden: bool = false,
    try_exec: ?[]const u8 = null,
    only_show_in: ?[]const u8 = null,
    not_show_in: ?[]const u8 = null,
    name: ?[]const u8 = null,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    startup_wm_class: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    path: ?[]const u8 = null,
    terminal: bool = false,
    keywords: ?[]const u8 = null,
    categories: ?[]const u8 = null,
    dbus_activatable: bool = false,
};

/// Parses a desktop entry file content.
pub fn parseDesktopFile(arena: Allocator, content: []const u8, locale: Locale) ?ParsedEntry {
    var entry = ParsedEntry{};
    var in_desktop_entry = false;

    // Match priority for localized keys: 0 = unlocalized, 1 = lang, 2 = lang_country, 3 = lang_country@mod
    var name_prio: u8 = 0;
    var generic_prio: u8 = 0;
    var comment_prio: u8 = 0;
    var keywords_prio: u8 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const section = line[1..close];
            in_desktop_entry = std.mem.eql(u8, section, "Desktop Entry");
            continue;
        }
        if (!in_desktop_entry) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const raw_key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        // Split key and locale tag e.g. "Name[de_DE]"
        var key_name = raw_key;
        var key_locale: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, raw_key, '[')) |bracket| {
            if (std.mem.endsWith(u8, raw_key, "]")) {
                key_name = raw_key[0..bracket];
                key_locale = raw_key[bracket + 1 .. raw_key.len - 1];
            }
        }

        if (std.mem.eql(u8, key_name, "Type")) {
            entry.is_application = std.mem.eql(u8, raw_val, "Application");
        } else if (std.mem.eql(u8, key_name, "NoDisplay")) {
            entry.no_display = std.mem.eql(u8, raw_val, "true");
        } else if (std.mem.eql(u8, key_name, "Hidden")) {
            entry.hidden = std.mem.eql(u8, raw_val, "true");
        } else if (std.mem.eql(u8, key_name, "Terminal")) {
            entry.terminal = std.mem.eql(u8, raw_val, "true");
        } else if (std.mem.eql(u8, key_name, "DBusActivatable")) {
            entry.dbus_activatable = std.mem.eql(u8, raw_val, "true");
        } else if (std.mem.eql(u8, key_name, "TryExec")) {
            entry.try_exec = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Exec")) {
            entry.exec = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Path")) {
            entry.path = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Icon")) {
            entry.icon = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "StartupWMClass")) {
            entry.startup_wm_class = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Categories")) {
            entry.categories = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "OnlyShowIn")) {
            entry.only_show_in = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "NotShowIn")) {
            entry.not_show_in = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Name")) {
            const prio = localePriority(key_locale, locale);
            if (prio > name_prio or entry.name == null) {
                entry.name = unescape(arena, raw_val) catch raw_val;
                name_prio = prio;
            }
        } else if (std.mem.eql(u8, key_name, "GenericName")) {
            const prio = localePriority(key_locale, locale);
            if (prio > generic_prio or entry.generic_name == null) {
                entry.generic_name = unescape(arena, raw_val) catch raw_val;
                generic_prio = prio;
            }
        } else if (std.mem.eql(u8, key_name, "Comment")) {
            const prio = localePriority(key_locale, locale);
            if (prio > comment_prio or entry.comment == null) {
                entry.comment = unescape(arena, raw_val) catch raw_val;
                comment_prio = prio;
            }
        } else if (std.mem.eql(u8, key_name, "Keywords")) {
            const prio = localePriority(key_locale, locale);
            if (prio > keywords_prio or entry.keywords == null) {
                entry.keywords = unescape(arena, raw_val) catch raw_val;
                keywords_prio = prio;
            }
        }
    }

    if (!entry.is_application or entry.name == null or entry.name.?.len == 0) return null;
    return entry;
}

pub fn localePriority(key_loc: ?[]const u8, target: Locale) u8 {
    const k = key_loc orelse return 1; // Unlocalized is lowest valid priority
    if (target.lang.len == 0) return 0;

    const parsed = Locale.parseLocale(k);
    if (!std.ascii.eqlIgnoreCase(parsed.lang, target.lang)) return 0;

    if (target.modifier.len > 0 and std.mem.eql(u8, parsed.modifier, target.modifier) and
        target.country.len > 0 and std.ascii.eqlIgnoreCase(parsed.country, target.country))
    {
        return 5;
    }
    if (target.country.len > 0 and std.ascii.eqlIgnoreCase(parsed.country, target.country)) {
        return 4;
    }
    if (target.modifier.len > 0 and std.mem.eql(u8, parsed.modifier, target.modifier)) {
        return 3;
    }
    if (parsed.country.len == 0 and parsed.modifier.len == 0) {
        return 2;
    }
    return 0;
}

pub fn unescape(allocator: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                's' => try out.append(allocator, ' '),
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                'r' => try out.append(allocator, '\r'),
                '\\' => try out.append(allocator, '\\'),
                else => try out.append(allocator, s[i]),
            }
        } else {
            try out.append(allocator, s[i]);
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn checkTryExec(try_exec: []const u8, environ: std.process.Environ) bool {
    if (try_exec.len == 0) return true;
    if (try_exec[0] == '/') {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        if (try_exec.len >= buf.len) return false;
        @memcpy(buf[0..try_exec.len], try_exec);
        buf[try_exec.len] = 0;
        const zpath: [*:0]const u8 = buf[0..try_exec.len :0];
        return c.access(zpath, c.X_OK) == 0;
    }

    const path_env = environ.getPosix("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const candidate = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, try_exec }, 0) catch continue;
        if (c.access(candidate.ptr, c.X_OK) == 0) return true;
    }
    return false;
}

pub fn checkDesktopVisibility(parsed: ParsedEntry, current_desktop: ?[]const u8) bool {
    if (parsed.hidden or parsed.no_display) return false;

    if (current_desktop) |desk| {
        if (parsed.not_show_in) |not_show| {
            var it = std.mem.splitScalar(u8, not_show, ';');
            while (it.next()) |d| {
                if (d.len > 0 and std.ascii.eqlIgnoreCase(d, desk)) return false;
            }
        }
        if (parsed.only_show_in) |only_show| {
            var found = false;
            var it = std.mem.splitScalar(u8, only_show, ';');
            while (it.next()) |d| {
                if (d.len > 0 and std.ascii.eqlIgnoreCase(d, desk)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }
    return true;
}
