//! A flattened theme and bounded, decoded wallpaper shared with the greeter.
//! No pack discovery, home access, image decoder or executable configuration.
const std = @import("std");
const theme = @import("ui").theme;
const png = @import("../png.zig");
const wallpapers = @import("../wallpapers.zig");
const c = @import("c");
pub const root = @import("../dm/appearance.zig").root;
const max_theme_bytes = 64 * 1024;
const max_edge = 1920;
const max_wallpaper_bytes = 12 + max_edge * max_edge * 4;
var serial: std.atomic.Value(u64) = .init(0);

pub fn directory(a: std.mem.Allocator, base: []const u8, uid: u32) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{d}", .{ base, uid });
}

/// Only a real desktop session publishes, and only into a directory already
/// provisioned for it by rediwm-dm. Nested/headless compositors never call this.
pub fn writableDirectory(a: std.mem.Allocator) ?[]u8 {
    const path = directory(a, root, c.getuid()) catch return null;
    const fd = openDirectory(path, c.getuid()) catch {
        a.free(path);
        return null;
    };
    _ = c.close(fd);
    return path;
}

fn openDirectory(path: []const u8, uid: u32) !c_int {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0);
    const fd = c.open(z, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.OpenDirectoryFailed;
    errdefer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_uid != uid or stat.st_mode & 0o022 != 0) return error.UnsafeDirectory;
    return fd;
}

pub fn saveTheme(a: std.mem.Allocator, path: []const u8, chosen: theme.Theme) !void {
    var tokens = chosen;
    tokens.start_button_icon = ""; // No paths to private pack assets.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try theme.writeInto(a, &bytes, tokens);
    if (bytes.items.len > max_theme_bytes) return error.ThemeTooLarge;
    try writeAtomic(path, "theme.toml", &.{bytes.items});
}

/// Called on the existing wallpaper decode worker, never on the UI thread.
/// Store little-endian premultiplied ARGB pixels; decoding at login needs only
/// fixed bounds checks. Keep aspect ratio and cap both dimensions at 1920.
pub fn saveWallpaper(a: std.mem.Allocator, path: []const u8, image: png.Image) !void {
    const scale = @min(1.0, @as(f64, max_edge) / @as(f64, @floatFromInt(@max(image.width, image.height))));
    const w: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(image.width)) * scale))));
    const h: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(image.height)) * scale))));
    const pixels = try wallpapers.thumbnail(a, image.pixels, image.width, image.height, w, h);
    defer a.free(pixels);
    for (pixels) |*pixel| pixel.* = std.mem.nativeToLittle(u32, pixel.*);
    var header: [12]u8 = undefined;
    @memcpy(header[0..4], "RWA1");
    std.mem.writeInt(u32, header[4..8], @intCast(w), .little);
    std.mem.writeInt(u32, header[8..12], @intCast(h), .little);
    try writeAtomic(path, "wallpaper.argb", &.{ &header, std.mem.sliceAsBytes(pixels) });
}

fn writeAtomic(path: []const u8, name: [:0]const u8, parts: []const []const u8) !void {
    const dir = try openDirectory(path, c.getuid());
    defer _ = c.close(dir);
    var buf: [100]u8 = undefined;
    const temp = try std.fmt.bufPrintSentinel(&buf, ".{s}.{d}.{d}", .{ name, c.getpid(), serial.fetchAdd(1, .monotonic) }, 0);
    const fd = c.openat(dir, temp, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.CreateFileFailed;
    defer _ = c.close(fd);
    defer _ = c.unlinkat(dir, temp, 0);
    for (parts) |bytes| {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n <= 0) return error.WriteFailed;
            offset += @intCast(n);
        }
    }
    // The snapshot is deliberately readable by the greeter regardless of umask.
    if (c.fchmod(fd, 0o644) != 0 or c.fsync(fd) != 0) return error.WriteFailed;
    if (c.renameat(dir, temp, dir, name) != 0) return error.RenameFailed;
}

fn readFile(a: std.mem.Allocator, dir: c_int, uid: u32, name: [:0]const u8, limit: usize) ![]u8 {
    // NONBLOCK prevents a substituted FIFO from hanging the login screen.
    const fd = c.openat(dir, name, c.O_RDONLY | c.O_NOFOLLOW | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) return error.OpenFileFailed;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_uid != uid or stat.st_mode & 0o022 != 0) return error.UnsafeFile;
    if (stat.st_size < 0 or stat.st_size > limit) return error.FileTooLarge;
    const bytes = try a.alloc(u8, @intCast(stat.st_size));
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.ReadFailed;
        offset += @intCast(n);
    }
    return bytes;
}

pub const Saved = struct {
    arena: std.heap.ArenaAllocator,
    tokens: theme.Theme,
    wallpaper: ?png.Image,

    pub fn deinit(self: *Saved, a: std.mem.Allocator) void {
        if (self.wallpaper) |image| image.deinit(a);
        self.arena.deinit();
    }
};

pub fn load(a: std.mem.Allocator, base: []const u8, uid: u32) !Saved {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const path = try directory(aa, base, uid);
    const dir = try openDirectory(path, uid);
    defer _ = c.close(dir);
    const bytes = try readFile(aa, dir, uid, "theme.toml", max_theme_bytes);
    if (!std.mem.startsWith(u8, bytes, "[theme]\n")) return error.InvalidTheme;
    var tokens = try theme.parse(aa, bytes);
    tokens.start_button_icon = "";
    // A bad image cannot prevent the colours or the login screen from loading.
    const image = blk: {
        const raster = readFile(a, dir, uid, "wallpaper.argb", max_wallpaper_bytes) catch break :blk null;
        defer a.free(raster);
        break :blk decodeWallpaper(a, raster) catch null;
    };
    return .{ .arena = arena, .tokens = tokens, .wallpaper = image };
}

fn decodeWallpaper(a: std.mem.Allocator, bytes: []const u8) !png.Image {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RWA1")) return error.InvalidWallpaper;
    const w = std.mem.readInt(u32, bytes[4..8], .little);
    const h = std.mem.readInt(u32, bytes[8..12], .little);
    if (w == 0 or h == 0 or w > max_edge or h > max_edge) return error.InvalidWallpaper;
    if (bytes.len != 12 + @as(usize, w) * h * 4) return error.InvalidWallpaper;
    const pixels = try a.alloc(u32, @as(usize, w) * h);
    for (pixels, 0..) |*pixel, i| {
        const p = std.mem.readInt(u32, bytes[12 + i * 4 ..][0..4], .little);
        const alpha = p >> 24;
        // Keep untrusted rasters premultiplied, even if hand-written.
        pixel.* = (alpha << 24) | (@min(alpha, (p >> 16) & 255) << 16) | (@min(alpha, (p >> 8) & 255) << 8) | @min(alpha, p & 255);
    }
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = pixels, .has_alpha = true };
}

test "greeter appearance round trip, replacement and hostile files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const uid = c.getuid();
    const path = try directory(a, base, uid);
    defer a.free(path);
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    const dir = try openDirectory(path, uid);
    defer _ = c.close(dir);
    var tokens: theme.Theme = .{};
    tokens.lock_bg = try theme.parseColor("#123456");
    tokens.font = "Test Font";
    tokens.start_button_icon = "/private/home/logo.svg";
    try saveTheme(a, path, tokens);
    var pixels = [_]u32{ 0xff123456, 0x80403020 };
    try saveWallpaper(a, path, .{ .width = 2, .height = 1, .pixels = &pixels, .has_alpha = true });
    var saved = try load(a, base, uid);
    defer saved.deinit(a);
    try std.testing.expectEqual(tokens.lock_bg, saved.tokens.lock_bg);
    try std.testing.expectEqualStrings("Test Font", saved.tokens.font);
    try std.testing.expectEqualStrings("", saved.tokens.start_button_icon);
    try std.testing.expectEqualSlices(u32, &pixels, saved.wallpaper.?.pixels);
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(dir, "theme.toml", &stat, c.AT_SYMLINK_NOFOLLOW));
    try std.testing.expectEqual(@as(c_uint, 0o644), stat.st_mode & 0o777);

    // Replacement is complete and clears old overrides, including fonts.
    try saveTheme(a, path, .{});
    var defaults = try load(a, base, uid);
    defer defaults.deinit(a);
    try std.testing.expectEqual((theme.Theme{}).lock_bg, defaults.tokens.lock_bg);
    try std.testing.expectEqualStrings((theme.Theme{}).font, defaults.tokens.font);
    try std.testing.expectError(error.OpenDirectoryFailed, load(a, base, uid + 1));

    // No following symlinks, blocking on FIFOs, or trusting raster dimensions.
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir, "wallpaper.argb", 0));
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("theme.toml", dir, "wallpaper.argb"));
    var no_image = try load(a, base, uid);
    defer no_image.deinit(a);
    try std.testing.expect(no_image.wallpaper == null);
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir, "theme.toml", 0));
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifoat(dir, "theme.toml", 0o644));
    try std.testing.expectError(error.UnsafeFile, load(a, base, uid));
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir, "theme.toml", 0));
    try writeAtomic(path, "theme.toml", &.{"[theme]\nlock_bg = \"broken\"\n"});
    if (load(a, base, uid)) |unexpected| {
        var value = unexpected;
        value.deinit(a);
        return error.AcceptedInvalidTheme;
    } else |_| {}
    try std.testing.expectError(error.InvalidWallpaper, decodeWallpaper(a, "RWA1\xff\xff\xff\xff\x01\x00\x00\x00"));
    try std.testing.expectError(error.InvalidWallpaper, decodeWallpaper(a, "RWA1\x01\x00\x00\x00\x01\x00\x00\x00"));
}
