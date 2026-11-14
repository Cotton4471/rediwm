//! Desktop integration for type-2 AppImages. Read metadata with unsquashfs;
//! never execute the image or its AppRun while adding it to the applications.
const std = @import("std");
const tr = @import("i18n").tr;
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;

extern fn g_key_file_new() *anyopaque;
extern fn g_key_file_unref(key_file: *anyopaque) void;
extern fn g_key_file_load_from_data(key_file: *anyopaque, data: [*]const u8, length: usize, flags: c_int, err: ?*?*anyopaque) c_int;
extern fn g_key_file_get_keys(key_file: *anyopaque, group: [*:0]const u8, length: ?*usize, err: ?*?*anyopaque) ?[*:null]?[*:0]u8;
extern fn g_key_file_get_string(key_file: *anyopaque, group: [*:0]const u8, key: [*:0]const u8, err: ?*?*anyopaque) ?[*:0]u8;
extern fn g_key_file_set_string(key_file: *anyopaque, group: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) void;
extern fn g_key_file_to_data(key_file: *anyopaque, length: ?*usize, err: ?*?*anyopaque) ?[*:0]u8;
extern fn g_strfreev(strings: ?[*:null]?[*:0]u8) void;
extern fn g_free(memory: ?*anyopaque) void;
extern fn g_object_unref(object: *anyopaque) void;
extern fn g_desktop_app_info_new_from_filename(filename: [*:0]const u8) ?*anyopaque;
extern fn g_desktop_app_info_new_from_keyfile(key_file: *anyopaque) ?*anyopaque;
extern fn g_app_info_get_default_for_type(content_type: [*:0]const u8, must_support_uris: c_int) ?*anyopaque;
extern fn g_app_info_add_supports_type(app: *anyopaque, content_type: [*:0]const u8, err: ?*?*anyopaque) c_int;
extern fn g_app_info_set_as_default_for_type(app: *anyopaque, content_type: [*:0]const u8, err: ?*?*anyopaque) c_int;

pub const Notice = struct { message: []const u8, failed: bool = false };

pub fn candidate(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".AppImage");
}

pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => tr("Install squashfs-tools to add AppImages to applications"),
        error.UnsupportedAppImage => tr("Only type-2 AppImages are supported"),
        error.InvalidDesktopEntry, error.MissingDesktopEntry => tr("The AppImage has no usable application launcher"),
        error.AmbiguousDesktopEntry => tr("The AppImage contains more than one application launcher"),
        error.InvalidAppImage, error.ReadFailed, error.MetadataFailed => tr("Could not read the AppImage's application details"),
        error.AssociationFailed => tr("Application added, but some file or link associations could not be registered"),
        else => tr("Could not add the AppImage to applications"),
    };
}

fn readAt(fd: c_int, bytes: []u8, offset: u64) !void {
    var n: usize = 0;
    while (n < bytes.len) {
        const got = c.pread(fd, bytes[n..].ptr, bytes.len - n, @intCast(offset + n));
        if (got < 0 and std.posix.errno(got) == .INTR) continue;
        if (got <= 0) return error.ReadFailed;
        n += @intCast(got);
    }
}

/// AppImage's filesystem starts after the ELF's last on-disk section/table.
/// Computing this avoids mistaking the runtime's embedded "hsqs" for a superblock.
fn filesystemOffset(fd: c_int, size: u64) !u64 {
    var header: [64]u8 = undefined;
    try readAt(fd, &header, 0);
    if (!std.mem.eql(u8, header[0..4], "\x7fELF") or !std.mem.eql(u8, header[8..11], "AI\x02")) return error.UnsupportedAppImage;
    if (header[5] != 1 or (header[4] != 1 and header[4] != 2)) return error.UnsupportedAppImage;
    const wide = header[4] == 2;
    const table = if (wide) std.mem.readInt(u64, header[40..48], .little) else std.mem.readInt(u32, header[32..36], .little);
    const stride = std.mem.readInt(u16, if (wide) header[58..60] else header[46..48], .little);
    const count = std.mem.readInt(u16, if (wide) header[60..62] else header[48..50], .little);
    if (count == 0 or count > 4096 or stride != @as(u16, if (wide) 64 else 40) or table > size or @as(u64, stride) * count > size - table) return error.InvalidAppImage;
    var offset = table + @as(u64, stride) * count;
    for (0..count) |i| {
        var section: [64]u8 = undefined;
        try readAt(fd, section[0..stride], table + i * stride);
        const kind = std.mem.readInt(u32, section[4..8], .little);
        if (kind == 8) continue; // SHT_NOBITS has no bytes on disk.
        const start = if (wide) std.mem.readInt(u64, section[24..32], .little) else std.mem.readInt(u32, section[16..20], .little);
        const length = if (wide) std.mem.readInt(u64, section[32..40], .little) else std.mem.readInt(u32, section[20..24], .little);
        if (start > size or length > size - start) return error.InvalidAppImage;
        offset = @max(offset, start + length);
    }
    var super: [96]u8 = undefined;
    if (offset > size or size - offset < super.len) return error.InvalidAppImage;
    try readAt(fd, &super, offset);
    const used = std.mem.readInt(u64, super[40..48], .little);
    if (!std.mem.eql(u8, super[0..4], "hsqs") or std.mem.readInt(u16, super[28..30], .little) != 4 or used < super.len or used > size - offset) return error.InvalidAppImage;
    return offset;
}

fn command(a: Allocator, io: std.Io, args: []const []const u8, limit: usize) ![]const u8 {
    const result = try std.process.run(a, io, .{
        .argv = args,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(16384),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        a.free(result.stdout);
        return error.MetadataFailed;
    }
    return result.stdout;
}

const Image = struct {
    path: []const u8,
    offset: []const u8,

    fn cat(self: Image, a: Allocator, io: std.Io, member: []const u8, limit: usize) ![]const u8 {
        return command(a, io, &.{ "unsquashfs", "-cat", "-no-wildcards", "-processors", "1", "-mem", "16M", "-offset", self.offset, self.path, member }, limit);
    }
};

fn get(file: *anyopaque, key: [*:0]const u8) ?[*:0]u8 {
    return g_key_file_get_string(file, "Desktop Entry", key, null);
}

fn set(a: Allocator, file: *anyopaque, key: [*:0]const u8, value: []const u8) !void {
    const z = try a.dupeSentinel(u8, value, 0);
    defer a.free(z);
    g_key_file_set_string(file, "Desktop Entry", key, z);
}

/// Quote for Desktop Entry Exec, before the key-file layer escapes backslashes.
fn quotedExecutable(a: Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, '"');
    for (path) |ch| {
        if (ch < 32 or ch == 127) return error.InvalidDesktopEntry;
        if (std.mem.indexOfScalar(u8, "\\\"`$", ch) != null) try out.append(a, '\\');
        try out.append(a, ch);
        if (ch == '%') try out.append(a, '%');
    }
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

/// Keep the bundled argument template, replacing only its executable. Desktop
/// actions, TryExec, Path and D-Bus activation must not refer into the image.
fn launcher(a: Allocator, source: *anyopaque, path: []const u8, icon: []const u8) ![]const u8 {
    const kind = get(source, "Type") orelse return error.InvalidDesktopEntry;
    defer g_free(kind);
    if (!std.mem.eql(u8, std.mem.span(kind), "Application")) return error.InvalidDesktopEntry;
    const name = get(source, "Name") orelse return error.InvalidDesktopEntry;
    defer g_free(name);
    if (std.mem.span(name).len == 0) return error.InvalidDesktopEntry;
    const exec_z = get(source, "Exec") orelse return error.InvalidDesktopEntry;
    defer g_free(exec_z);
    const exec = std.mem.trim(u8, std.mem.span(exec_z), " \t");
    var end: usize = 0;
    var quote = false;
    while (end < exec.len) : (end += 1) {
        const ch = exec[end];
        if (ch == '\\') {
            end += 1;
            if (end == exec.len) return error.InvalidDesktopEntry;
        } else if (ch == '"') {
            quote = !quote;
        } else if (!quote and (ch == ' ' or ch == '\t')) break;
    }
    if (quote or end == 0) return error.InvalidDesktopEntry;
    const quoted = try quotedExecutable(a, path);
    defer a.free(quoted);
    // GIO checks argv[0] before expanding %% field escapes. Putting the path
    // in env's argv lets filenames containing '%' pass both loading and launch.
    const new_exec = try std.fmt.allocPrint(a, "/usr/bin/env -- {s}{s}", .{ quoted, exec[end..] });
    defer a.free(new_exec);
    const target = g_key_file_new();
    defer g_key_file_unref(target);
    const keys = g_key_file_get_keys(source, "Desktop Entry", null, null) orelse return error.InvalidDesktopEntry;
    defer g_strfreev(keys);
    var i: usize = 0;
    while (keys[i]) |key| : (i += 1) {
        const k = std.mem.span(key);
        const keep = for ([_][]const u8{ "Name", "GenericName", "Comment", "Keywords", "Categories", "StartupWMClass", "Terminal", "MimeType", "PrefersNonDefaultGPU" }) |allowed| {
            if (std.mem.eql(u8, k, allowed) or
                (std.mem.startsWith(u8, k, allowed) and k.len > allowed.len and k[allowed.len] == '[')) break true;
        } else false;
        if (!keep) continue;
        const value = get(source, key) orelse continue;
        defer g_free(value);
        try set(a, target, key, std.mem.span(value));
    }
    try set(a, target, "Type", "Application");
    try set(a, target, "Exec", new_exec);
    try set(a, target, "Icon", icon);
    try set(a, target, "X-RediWM-AppImage", path);
    const checked = g_desktop_app_info_new_from_keyfile(target) orelse return error.InvalidDesktopEntry;
    g_object_unref(checked);
    var length: usize = 0;
    const data = g_key_file_to_data(target, &length, null) orelse return error.InvalidDesktopEntry;
    defer g_free(data);
    return a.dupe(u8, data[0..length]);
}

fn atomicWrite(a: Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrintSentinel(a, "{s}.XXXXXX", .{path}, 0);
    defer a.free(tmp);
    const fd = c.mkstemp(tmp);
    if (fd < 0) return error.WriteFailed;
    defer _ = c.close(fd);
    defer _ = c.unlink(tmp);
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = c.write(fd, bytes[sent..].ptr, bytes.len - sent);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
    try std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io);
}

/// The caller owns an arena. No files are extracted from the image to disk;
/// only bounded launcher/icon bytes are published to the user's XDG data dir.
pub fn install(a: Allocator, io: std.Io, environ: std.process.Environ, path: []const u8) !void {
    const zpath = try a.dupeSentinel(u8, path, 0);
    const canonical = c.realpath(zpath, null) orelse return error.ReadFailed;
    defer c.free(canonical);
    const image_path = std.mem.span(canonical);
    const fd = c.open(canonical, c.O_RDONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) return error.ReadFailed;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size < 64) return error.InvalidAppImage;
    const offset = try filesystemOffset(fd, @intCast(stat.st_size));
    const image: Image = .{ .path = image_path, .offset = try std.fmt.allocPrint(a, "{d}", .{offset}) };
    const listing = try command(a, io, &.{ "unsquashfs", "-ls", "-offset", image.offset, image.path, "*.desktop" }, 256 * 1024);
    var desktop: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        const prefix = "squashfs-root/";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const member = line[prefix.len..];
        if (std.mem.indexOfAny(u8, member, "/\\\r\x00") != null or !std.mem.endsWith(u8, member, ".desktop")) continue;
        if (desktop != null) return error.AmbiguousDesktopEntry;
        desktop = member;
    }
    const data = try image.cat(a, io, desktop orelse return error.MissingDesktopEntry, 64 * 1024);
    const source = g_key_file_new();
    defer g_key_file_unref(source);
    if (g_key_file_load_from_data(source, data.ptr, data.len, 2, null) == 0) return error.InvalidDesktopEntry;

    const home = environ.getPosix("HOME") orelse return error.NoHome;
    const data_home = if (environ.getPosix("XDG_DATA_HOME")) |dir| (if (std.fs.path.isAbsolute(dir)) dir else null) else null;
    const base = data_home orelse try std.fs.path.join(a, &.{ home, ".local/share" });
    // Path-derived IDs make repeated adds idempotent and avoid overwriting a
    // packaged launcher or another AppImage with the same embedded filename.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image_path, &digest, .{});
    const id = try std.fmt.allocPrint(a, "rediwm-appimage-{s}", .{std.fmt.bytesToHex(digest[0..16], .lower)});
    const applications = try std.fs.path.join(a, &.{ base, "applications" });
    const icon_dir = try std.fs.path.join(a, &.{ base, "icons/hicolor/256x256/apps" });
    const desktop_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}.desktop", .{ applications, id }, 0);

    var icon_bytes: ?[]const u8 = image.cat(a, io, ".DirIcon", 4 * 1024 * 1024) catch null;
    if (icon_bytes == null) {
        if (get(source, "Icon")) |icon| {
            defer g_free(icon);
            const name = std.mem.span(icon);
            if (name.len > 0 and std.mem.indexOfAny(u8, name, "/\\\n\r") == null) {
                for ([_][]const u8{ "", ".png", ".svg", ".xpm" }) |extension| {
                    icon_bytes = image.cat(a, io, try std.fmt.allocPrint(a, "{s}{s}", .{ name, extension }), 4 * 1024 * 1024) catch continue;
                    break;
                }
            }
        }
    }
    var icon_path: []const u8 = "application-x-executable";
    if (icon_bytes) |bytes| {
        const extension: ?[]const u8 = if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) "png" else if (std.mem.indexOf(u8, bytes[0..@min(bytes.len, 4096)], "<svg") != null) "svg" else if (std.mem.startsWith(u8, bytes, "/* XPM */")) "xpm" else null;
        if (extension) |ext| {
            try std.Io.Dir.cwd().createDirPath(io, icon_dir);
            icon_path = try std.fmt.allocPrint(a, "{s}/{s}.{s}", .{ icon_dir, id, ext });
            try atomicWrite(a, io, icon_path, bytes);
        }
    }
    const output = try launcher(a, source, image_path, icon_path);
    try std.Io.Dir.cwd().createDirPath(io, applications);
    // An already executable image can live in a read-only/shared location.
    // Otherwise grant owner execute, preserving ordinary access bits only.
    if (c.access(canonical, c.X_OK) != 0 and c.fchmod(fd, (stat.st_mode & 0o777) | 0o100) != 0) return error.WriteFailed;
    try atomicWrite(a, io, desktop_path, output);
    const app = g_desktop_app_info_new_from_filename(desktop_path) orelse return error.InvalidDesktopEntry;
    defer g_object_unref(app);
    if (get(source, "MimeType")) |types| {
        defer g_free(types);
        var entries = std.mem.splitScalar(u8, std.mem.span(types), ';');
        var failed = false;
        while (entries.next()) |entry| {
            if (entry.len == 0) continue;
            if (entry.len > 255 or std.mem.indexOfScalar(u8, entry, '/') == null or std.mem.indexOfAny(u8, entry, " \t\r\n\\") != null) continue;
            const mime = try a.dupeSentinel(u8, entry, 0);
            if (g_app_info_add_supports_type(app, mime, null) == 0) failed = true;
            // Claim unhandled URL schemes (including Unity's sign-in callback),
            // preserving an existing user choice and all file-type defaults.
            if (std.mem.startsWith(u8, entry, "x-scheme-handler/")) {
                if (g_app_info_get_default_for_type(mime, 0)) |existing| {
                    g_object_unref(existing);
                } else if (g_app_info_set_as_default_for_type(app, mime, null) == 0) failed = true;
            }
        }
        if (failed) return error.AssociationFailed;
    }
}
