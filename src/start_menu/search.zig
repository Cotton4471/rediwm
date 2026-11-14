// Pure matching and deterministic ranking for the start menu.
//
// Matches search queries against application entries and built-in Settings,
// ranking exact matches, name prefixes, word prefixes, keywords, and descriptions.
const std = @import("std");
const i18n = @import("i18n");
const Allocator = std.mem.Allocator;
const fold = @import("ui").fold;

const applications = @import("applications.zig");
const AppEntry = applications.AppEntry;

pub const Category = enum {
    all,
    apps,
};

pub const SearchResult = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    icon: ?[]const u8 = null,
    is_settings: bool = false,
    is_loading: bool = false,
    app_entry: ?*const AppEntry = null,
    score: i32 = 0,
};

pub const settings_id = "rediwm.settings";
pub const settings_name = i18n.msg("Settings");
pub const settings_description = i18n.msg("System preferences, display, appearance and input");
pub const loading_id = "rediwm.loading";
pub const loading_name = i18n.msg("Loading applications…");
pub const loading_description = i18n.msg("Scanning installed apps");
const settings_keywords = i18n.msg("settings;control;panel;preferences;display;appearance;mouse;keyboard;printer;printers;printing");

pub fn search(
    allocator: Allocator,
    catalog: []const AppEntry,
    query: []const u8,
    category: Category,
    loading: bool,
) ![]SearchResult {
    return searchWithOptions(allocator, catalog, query, category, loading, .{ .turkish = @import("i18n").isTurkish() });
}

pub fn searchWithOptions(
    allocator: Allocator,
    catalog: []const AppEntry,
    query: []const u8,
    category: Category,
    loading: bool,
    options: fold.Options,
) ![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer results.deinit(allocator);

    const trimmed = std.mem.trim(u8, query, " \t\r\n");

    if (trimmed.len == 0) {
        // Empty query: alphabetical applications plus Settings if in .all
        for (catalog) |*app| {
            const desc = app.generic_name orelse app.comment orelse "";
            try results.append(allocator, .{
                .id = app.id,
                .name = app.name,
                .description = desc,
                .icon = app.icon,
                .is_settings = false,
                .app_entry = app,
                .score = 100,
            });
        }

        // Sort applications alphabetically
        std.mem.sort(SearchResult, results.items, options, sortAlphabetical);

        if (loading) {
            try results.append(allocator, .{
                .id = loading_id,
                .name = loading_name.get(),
                .description = loading_description.get(),
                .is_loading = true,
                .score = 0,
            });
        }

        if (category == .all) {
            try results.append(allocator, .{
                .id = settings_id,
                .name = settings_name.get(),
                .description = settings_description.get(),
                .icon = @import("ui").shell_icons.settings_icon_name,
                .is_settings = true,
                .app_entry = null,
                .score = 50,
            });
        }
        return results.toOwnedSlice(allocator);
    }

    // Score applications
    for (catalog) |*app| {
        const desc = app.generic_name orelse app.comment orelse "";
        if (scoreItem(app.name, app.generic_name, app.keywords, app.comment, trimmed, options)) |sc| {
            try results.append(allocator, .{
                .id = app.id,
                .name = app.name,
                .description = desc,
                .icon = app.icon,
                .is_settings = false,
                .app_entry = app,
                .score = sc,
            });
        }
    }

    // Score Settings if in .all
    if (category == .all) {
        const localized = scoreItem(settings_name.get(), null, settings_keywords.get(), settings_description.get(), trimmed, options);
        const english = scoreItem(settings_name.source, null, settings_keywords.source, settings_description.source, trimmed, options);
        if (localized orelse english) |sc| {
            try results.append(allocator, .{
                .id = settings_id,
                .name = settings_name.get(),
                .description = settings_description.get(),
                .icon = @import("ui").shell_icons.settings_icon_name,
                .is_settings = true,
                .app_entry = null,
                .score = sc,
            });
        }
    }

    // Sort by ranking criteria
    std.mem.sort(SearchResult, results.items, options, sortRanked);

    return results.toOwnedSlice(allocator);
}

fn scoreItem(
    name: []const u8,
    generic_name: ?[]const u8,
    keywords: []const u8,
    comment: ?[]const u8,
    query: []const u8,
    options: fold.Options,
) ?i32 {
    const name_len = name.len;

    const len_penalty: i32 = @intCast(@min(name_len, 50));

    // Tier 1: Exact match
    if (fold.eql(name, query, options)) {
        return 1000;
    }

    // Tier 2: Prefix match
    if (fold.startsWith(name, query, options)) {
        return 800 - len_penalty;
    }

    // Tier 3: Word prefix in name
    if (matchesWordPrefix(name, query, options)) {
        return 600 - len_penalty;
    }

    // Tier 4: Substring in name
    if (fold.contains(name, query, options)) {
        return 400 - len_penalty;
    }

    // Tier 5: Generic name / keywords match
    if (generic_name) |gn| {
        if (fold.startsWith(gn, query, options) or matchesWordPrefix(gn, query, options)) {
            return 300;
        }
    }

    if (keywords.len > 0) {
        var it = std.mem.splitScalar(u8, keywords, ';');
        while (it.next()) |kw| {
            const kw_trim = std.mem.trim(u8, kw, " \t");
            if (kw_trim.len == 0) continue;
            if (fold.startsWith(kw_trim, query, options)) {
                return 280;
            }
        }
    }

    // Tier 6: Description/comment match
    if (comment) |c| {
        if (fold.contains(c, query, options)) {
            return 200;
        }
    }

    return null;
}

fn matchesWordPrefix(text: []const u8, prefix: []const u8, options: fold.Options) bool {
    var it = std.mem.splitAny(u8, text, " \t-_/");
    while (it.next()) |word| {
        if (word.len == 0) continue;
        if (fold.startsWith(word, prefix, options)) return true;
    }
    return false;
}

fn sortAlphabetical(options: fold.Options, a: SearchResult, b: SearchResult) bool {
    const ord = fold.order(a.name, b.name, options);
    if (ord != .eq) return ord == .lt;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn sortRanked(options: fold.Options, a: SearchResult, b: SearchResult) bool {
    // Higher score first
    if (a.score != b.score) return a.score > b.score;
    // Shorter name preferred
    if (a.name.len != b.name.len) return a.name.len < b.name.len;
    // Alphabetical tie-breaking
    const ord = fold.order(a.name, b.name, options);
    if (ord != .eq) return ord == .lt;
    // Stable ID tie-breaking
    return std.mem.order(u8, a.id, b.id) == .lt;
}

test "search exact match vs prefix rank" {
    const apps = [_]AppEntry{
        .{
            .id = "term.desktop",
            .desktop_file_path = "",
            .name = "Terminal",
            .exec = "term",
        },
        .{
            .id = "term-emu.desktop",
            .desktop_file_path = "",
            .name = "Terminal Emulator",
            .exec = "term",
        },
    };
    const res = try search(std.testing.allocator, &apps, "Terminal", .all, false);
    defer std.testing.allocator.free(res);

    try std.testing.expect(res.len >= 2);
    try std.testing.expectEqualStrings("Terminal", res[0].name);
    try std.testing.expectEqualStrings("Terminal Emulator", res[1].name);
}

test "search word prefix in name" {
    const apps = [_]AppEntry{
        .{
            .id = "foot-server.desktop",
            .desktop_file_path = "",
            .name = "Foot Server",
            .exec = "foot --server",
        },
    };
    const res = try search(std.testing.allocator, &apps, "serv", .all, false);
    defer std.testing.allocator.free(res);

    try std.testing.expectEqual(@as(usize, 1), res.len);
    try std.testing.expectEqualStrings("Foot Server", res[0].name);
}

test "search folds translated names aliases and arbitrarily long fields" {
    const long_prefix = comptime blk: {
        var repeated: []const u8 = "";
        for (0..80) |_| repeated = repeated ++ "Long ";
        break :blk repeated;
    };
    const apps = [_]AppEntry{
        .{ .id = "camera", .desktop_file_path = "", .name = "Cámara", .exec = "camera" },
        .{ .id = "terminal", .desktop_file_path = "", .name = "Терминал", .exec = "terminal" },
        .{ .id = "photo", .desktop_file_path = "", .name = "Photos", .generic_name = "Álbum", .exec = "photo" },
        .{ .id = "street", .desktop_file_path = "", .name = "Maps", .keywords = "Straße;Œuvre", .exec = "maps" },
        .{ .id = "long", .desktop_file_path = "", .name = long_prefix ++ "Éditeur", .comment = long_prefix ++ "Удобный", .exec = "editor" },
    };
    const cases = .{
        .{ "camara", "camera" },
        .{ "терм", "terminal" },
        .{ "album", "photo" },
        .{ "STRASSE", "street" },
        .{ "oeuv", "street" },
        .{ "editeur", "long" },
        .{ "удоб", "long" },
    };
    inline for (cases) |case| {
        const results = try searchWithOptions(std.testing.allocator, &apps, case[0], .apps, false, .{});
        defer std.testing.allocator.free(results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqualStrings(case[1], results[0].id);
    }
    try std.testing.expectEqual(@as(?i32, 1000), scoreItem("IŞIK", null, "", null, "ışık", .{ .turkish = true }));
    try std.testing.expectEqual(@as(?i32, null), scoreItem("IŞIK", null, "", null, "ışık", .{}));
}

test "search empty query and category filtering" {
    const apps = [_]AppEntry{
        .{
            .id = "z.desktop",
            .desktop_file_path = "",
            .name = "Zebra",
            .exec = "zebra",
        },
        .{
            .id = "a.desktop",
            .desktop_file_path = "",
            .name = "Ant",
            .exec = "ant",
        },
    };

    // Category .all contains alphabetical apps + Settings action
    const all_res = try search(std.testing.allocator, &apps, "", .all, false);
    defer std.testing.allocator.free(all_res);
    try std.testing.expectEqual(@as(usize, 3), all_res.len);
    try std.testing.expectEqualStrings("Ant", all_res[0].name);
    try std.testing.expectEqualStrings("Zebra", all_res[1].name);
    try std.testing.expect(all_res[2].is_settings);

    const loading_res = try search(std.testing.allocator, &.{}, "", .all, true);
    defer std.testing.allocator.free(loading_res);
    try std.testing.expectEqual(@as(usize, 2), loading_res.len);
    try std.testing.expect(loading_res[0].is_loading);
    try std.testing.expect(loading_res[1].is_settings);

    // Category .apps filters out Settings action
    const apps_res = try search(std.testing.allocator, &apps, "", .apps, false);
    defer std.testing.allocator.free(apps_res);
    try std.testing.expectEqual(@as(usize, 2), apps_res.len);
    try std.testing.expectEqualStrings("Ant", apps_res[0].name);
    try std.testing.expectEqualStrings("Zebra", apps_res[1].name);
}
