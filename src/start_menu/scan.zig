//! Scanning application directories into entries, and copying and filtering them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const catalog_cache = @import("catalog_cache.zig");
const i18n = @import("i18n");
const applications = @import("applications.zig");
const AppEntry = applications.AppEntry;
const Locale = applications.Locale;
const parseDesktopFile = applications.parseDesktopFile;
const checkTryExec = applications.checkTryExec;
const checkDesktopVisibility = applications.checkDesktopVisibility;

pub fn copyFiltered(arena: Allocator, entries: []const AppEntry, environ: std.process.Environ) ![]AppEntry {
    var out: std.ArrayList(AppEntry) = .empty;
    errdefer out.deinit(arena);
    for (entries) |e| {
        if (e.try_exec) |try_exec| {
            if (!checkTryExec(try_exec, environ)) continue;
        }
        try out.append(arena, try dupeEntry(arena, e));
    }
    return out.toOwnedSlice(arena);
}

pub fn dupeEntry(arena: Allocator, e: AppEntry) !AppEntry {
    return .{
        .id = try arena.dupe(u8, e.id),
        .desktop_file_path = try arena.dupe(u8, e.desktop_file_path),
        .name = try arena.dupe(u8, e.name),
        .generic_name = if (e.generic_name) |s| try arena.dupe(u8, s) else null,
        .comment = if (e.comment) |s| try arena.dupe(u8, s) else null,
        .icon = if (e.icon) |s| try arena.dupe(u8, s) else null,
        .startup_wm_class = if (e.startup_wm_class) |s| try arena.dupe(u8, s) else null,
        .exec = try arena.dupe(u8, e.exec),
        .path = if (e.path) |s| try arena.dupe(u8, s) else null,
        .try_exec = if (e.try_exec) |s| try arena.dupe(u8, s) else null,
        .terminal = e.terminal,
        .keywords = try arena.dupe(u8, e.keywords),
        .categories = try arena.dupe(u8, e.categories),
        .dbus_activatable = e.dbus_activatable,
    };
}

pub fn resolveApplicationDirs(arena: Allocator, environ: std.process.Environ) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;

    if (environ.getPosix("XDG_DATA_HOME")) |dh| {
        try dirs.append(arena, try std.fmt.allocPrint(arena, "{s}/applications", .{dh}));
    } else if (environ.getPosix("HOME")) |home| {
        try dirs.append(arena, try std.fmt.allocPrint(arena, "{s}/.local/share/applications", .{home}));
    }

    const data_dirs = environ.getPosix("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, data_dirs, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        try dirs.append(arena, try std.fmt.allocPrint(arena, "{s}/applications", .{dir}));
    }
    return dirs.toOwnedSlice(arena);
}

pub const ScanOutcome = struct {
    entries: []AppEntry,
    sources: []catalog_cache.SourceIdent,
};

pub fn scanAll(arena: Allocator, io: Io, environ: std.process.Environ) !ScanOutcome {
    return scanAllWithLocale(arena, io, environ, i18n.resolve("", environ));
}

pub fn scanAllWithLocale(arena: Allocator, io: Io, environ: std.process.Environ, locale_tag: []const u8) !ScanOutcome {
    const locale = Locale.forLanguage(locale_tag);
    const current_desktop = environ.getPosix("XDG_CURRENT_DESKTOP");
    const app_dirs = try resolveApplicationDirs(arena, environ);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    var results: std.ArrayList(AppEntry) = .empty;
    var sources: std.ArrayList(catalog_cache.SourceIdent) = .empty;

    for (app_dirs) |dir| {
        scanDirectory(arena, io, environ, dir, "", locale, current_desktop, &seen, &results, &sources) catch continue;
    }
    catalog_cache.sortSources(sources.items);

    return .{
        .entries = try results.toOwnedSlice(arena),
        .sources = try sources.toOwnedSlice(arena),
    };
}

pub fn collectSources(arena: Allocator, io: Io, environ: std.process.Environ) ![]catalog_cache.SourceIdent {
    const app_dirs = try resolveApplicationDirs(arena, environ);
    var sources: std.ArrayList(catalog_cache.SourceIdent) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    for (app_dirs) |dir| {
        walkSources(arena, io, dir, &sources, &seen) catch continue;
    }
    catalog_cache.sortSources(sources.items);
    return sources.toOwnedSlice(arena);
}

pub fn walkSources(
    arena: Allocator,
    io: Io,
    dir: []const u8,
    sources: *std.ArrayList(catalog_cache.SourceIdent),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    var iter = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer iter.close(io);
    var it = iter.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            const child = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, entry.name });
            walkSources(arena, io, child, sources, seen) catch continue;
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".desktop")) continue;
        const full_file_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, entry.name });
        if (seen.contains(full_file_path)) continue;
        try seen.put(arena, full_file_path, {});
        if (catalog_cache.statPath(io, full_file_path)) |ident| {
            try sources.append(arena, .{
                .path = full_file_path,
                .mtime_sec = ident.mtime_sec,
                .mtime_nsec = ident.mtime_nsec,
                .size = ident.size,
            });
        }
    }
}

pub fn scanDirectory(
    arena: Allocator,
    io: Io,
    environ: std.process.Environ,
    base_dir: []const u8,
    rel_sub: []const u8,
    locale: Locale,
    current_desktop: ?[]const u8,
    seen: *std.StringHashMapUnmanaged(void),
    results: *std.ArrayList(AppEntry),
    sources: *std.ArrayList(catalog_cache.SourceIdent),
) !void {
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    const full_dir = if (rel_sub.len == 0)
        base_dir
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, rel_sub }) catch return;

    var iter = Io.Dir.cwd().openDir(io, full_dir, .{ .iterate = true }) catch return;
    defer iter.close(io);

    var it = iter.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            var sub_buf: [256]u8 = undefined;
            const next_sub = if (rel_sub.len == 0)
                std.fmt.bufPrint(&sub_buf, "{s}", .{entry.name}) catch continue
            else
                std.fmt.bufPrint(&sub_buf, "{s}-{s}", .{ rel_sub, entry.name }) catch continue;
            scanDirectory(arena, io, environ, base_dir, next_sub, locale, current_desktop, seen, results, sources) catch continue;
            continue;
        }

        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".desktop")) continue;

        const full_file_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ full_dir, entry.name });
        if (catalog_cache.statPath(io, full_file_path)) |ident| {
            try sources.append(arena, .{
                .path = full_file_path,
                .mtime_sec = ident.mtime_sec,
                .mtime_nsec = ident.mtime_nsec,
                .size = ident.size,
            });
        }

        // Form desktop-file ID
        const desktop_id = if (rel_sub.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}-{s}", .{ rel_sub, entry.name });

        if (seen.contains(desktop_id)) continue;
        try seen.put(arena, desktop_id, {});

        const content = Io.Dir.cwd().readFileAlloc(io, full_file_path, arena, .limited(512 * 1024)) catch continue;

        const parsed = parseDesktopFile(arena, content, locale) orelse continue;

        // Visibility rules
        if (!checkDesktopVisibility(parsed, current_desktop)) continue;

        // TryExec check
        if (parsed.try_exec) |try_exec| {
            if (!checkTryExec(try_exec, environ)) continue;
        }

        const exec_cmd = parsed.exec orelse continue;

        try results.append(arena, .{
            .id = desktop_id,
            .desktop_file_path = full_file_path,
            .name = parsed.name.?,
            .generic_name = parsed.generic_name,
            .comment = parsed.comment,
            .icon = parsed.icon,
            .startup_wm_class = parsed.startup_wm_class,
            .exec = exec_cmd,
            .path = parsed.path,
            .try_exec = parsed.try_exec,
            .terminal = parsed.terminal,
            .keywords = parsed.keywords orelse "",
            .categories = parsed.categories orelse "",
            .dbus_activatable = parsed.dbus_activatable,
        });
    }
}
