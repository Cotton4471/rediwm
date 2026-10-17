//! Bounded os-release parsing and package guidance. No package manager, shell,
//! service mutation or scheduler connection is involved in platform discovery.
const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Distro = enum { arch, artix, cachyos, debian, ubuntu, fedora, opensuse, generic };
pub const Info = struct {
    distro: Distro = .generic,
    id: []const u8 = "",
    id_like: []const u8 = "",
    cups_package: []const u8 = "cups",
    helper_package: []const u8 = "cups-pk-helper",
    // A regular executable at a conventional path is evidence of installation,
    // never evidence that the daemon is running/enabled. null means inaccessible.
    daemon_installed: ?bool = null,
    missing_cups: []const u8 = "Printing needs CUPS. Ask your distribution's package manager for its CUPS print-server package, then start the print service.",
    missing_helper: []const u8 = "Printer administration uses CUPS authentication when the optional cups-pk-helper package is unavailable.",

    pub fn deinit(self: *Info, a: A) void {
        a.free(self.id);
        a.free(self.id_like);
        self.* = undefined;
    }
};

fn value(raw: []const u8) ![]const u8 {
    const text = std.mem.trim(u8, raw, " \t\r");
    if (text.len > 255) return error.InvalidOsRelease;
    if (text.len == 0) return text;
    if (text[0] == '\'' or text[0] == '"') {
        if (text.len < 2 or text[text.len - 1] != text[0]) return error.InvalidOsRelease;
        return text[1 .. text.len - 1];
    }
    if (std.mem.indexOfAny(u8, text, "\"'") != null) return error.InvalidOsRelease;
    return text;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 127) return false;
    for (id) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '.' and ch != '_' and ch != '-') return false;
    return true;
}

fn exact(id: []const u8) ?Distro {
    const entries = .{ .{ "arch", Distro.arch }, .{ "artix", Distro.artix }, .{ "cachyos", Distro.cachyos }, .{ "debian", Distro.debian }, .{ "ubuntu", Distro.ubuntu }, .{ "fedora", Distro.fedora }, .{ "opensuse", Distro.opensuse }, .{ "opensuse-tumbleweed", Distro.opensuse }, .{ "opensuse-leap", Distro.opensuse }, .{ "suse", Distro.opensuse }, .{ "sles", Distro.opensuse } };
    inline for (entries) |entry| if (std.mem.eql(u8, id, entry[0])) return entry[1];
    return null;
}

/// ID takes precedence over ID_LIKE; derivatives with no ID_LIKE (Artix) are
/// recognized explicitly. ID_LIKE is an ordered list, never a substring match.
pub fn parse(a: A, bytes: []const u8) !Info {
    if (bytes.len > 65536 or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidOsRelease;
    var id: []const u8 = "";
    var like: []const u8 = "";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..separator];
        if (std.mem.eql(u8, key, "ID")) {
            id = try value(line[separator + 1 ..]);
            if (!validId(id)) return error.InvalidOsRelease;
        } else if (std.mem.eql(u8, key, "ID_LIKE")) {
            like = try value(line[separator + 1 ..]);
            var tokens = std.mem.tokenizeAny(u8, like, " \t");
            while (tokens.next()) |token| if (!validId(token)) return error.InvalidOsRelease;
        }
    }
    var distro = exact(id) orelse Distro.generic;
    if (distro == .generic) {
        var tokens = std.mem.tokenizeAny(u8, like, " \t");
        while (tokens.next()) |token| if (exact(token)) |known| {
            distro = known;
            break;
        };
    }
    var info: Info = .{ .distro = distro };
    info.id = try a.dupe(u8, id);
    errdefer a.free(info.id);
    info.id_like = try a.dupe(u8, like);
    info.missing_cups = switch (distro) {
        .arch, .cachyos => "Install the cups package with your distribution's package manager, then start the CUPS print service. RediWM does not install it automatically.",
        .artix => "Install the cups package and your init system's CUPS service package, then start that service. Artix does not use systemd.",
        .debian, .ubuntu => "Install the cups package with your distribution's package manager, then start the CUPS print service.",
        .fedora => "Install the cups package with your distribution's package manager, then start the CUPS print service.",
        .opensuse => "Install the cups package using your distribution's package manager, then start the CUPS print service. openSUSE release qualification is still pending.",
        .generic => info.missing_cups,
    };
    info.missing_helper = switch (distro) {
        .arch, .cachyos, .artix => "The optional cups-pk-helper package provides polkit authorization. Without it, printer setup uses CUPS administrator credentials.",
        .debian, .ubuntu => "The optional cups-pk-helper package provides polkit authorization. Without it, printer setup uses CUPS administrator credentials.",
        .fedora => "The optional cups-pk-helper package provides polkit authorization. Without it, printer setup uses CUPS administrator credentials.",
        .opensuse => "Look for the optional cups-pk-helper package in your openSUSE repositories. Availability and authorization depend on the release and local policy.",
        .generic => info.missing_helper,
    };
    return info;
}

/// Testable filesystem probe. Only stat conventional cupsd paths under root.
pub fn daemonInstalled(a: A, io: Io, root: []const u8) !?bool {
    var inaccessible = false;
    for ([_][]const u8{ "usr/sbin/cupsd", "usr/bin/cupsd", "sbin/cupsd" }) |relative| {
        const candidate = try std.fs.path.join(a, &.{ root, relative });
        defer a.free(candidate);
        const stat = Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => {
                inaccessible = true;
                continue;
            },
        };
        if (stat.kind == .file and stat.permissions.toMode() & 0o111 != 0) return true;
    }
    return if (inaccessible) null else false;
}

pub fn load(a: A, io: Io) !Info {
    const bytes = Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", a, .limited(65536)) catch |err| switch (err) {
        error.FileNotFound => Io.Dir.cwd().readFileAlloc(io, "/usr/lib/os-release", a, .limited(65536)) catch |fallback_err| switch (fallback_err) {
            error.FileNotFound => try a.dupe(u8, ""),
            else => return fallback_err,
        },
        else => return err,
    };
    defer a.free(bytes);
    var info = try parse(a, bytes);
    errdefer info.deinit(a);
    info.daemon_installed = try daemonInstalled(a, io, "/");
    return info;
}

test "distro detection uses exact ID then ordered ID_LIKE and handles Artix without systemd" {
    const a = std.testing.allocator;
    const cases = .{ .{ "ID=artix\n", Distro.artix }, .{ "ID=cachyos\nID_LIKE=arch\n", Distro.cachyos }, .{ "ID=ubuntu\nID_LIKE=debian\n", Distro.ubuntu }, .{ "ID=linuxmint\nID_LIKE=\"ubuntu debian\"\n", Distro.ubuntu }, .{ "ID=custom\nID_LIKE='notarch fedora'\n", Distro.fedora }, .{ "ID=opensuse-tumbleweed\n", Distro.opensuse }, .{ "ID=custom\nID_LIKE=notarch\n", Distro.generic } };
    inline for (cases) |case| {
        var info = try parse(a, case[0]);
        defer info.deinit(a);
        try std.testing.expectEqual(case[1], info.distro);
    }
    var artix = try parse(a, "ID=artix\n");
    defer artix.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, artix.missing_cups, "init system") != null);
}

test "os-release never executes or accepts interpolation and rejects malformed identifiers" {
    for ([_][]const u8{ "ID=\"$(touch /tmp/never)\"\n", "ID=\"arch\n", "ID=arch\x00\n", "ID_LIKE=\"arch;evil\"\n", "ID=Arch\n" }) |bytes| try std.testing.expectError(error.InvalidOsRelease, parse(std.testing.allocator, bytes));
}

test "daemon probe distinguishes a regular executable from a directory or plain file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try std.testing.expectEqual(@as(?bool, false), try daemonInstalled(a, io, root));
    try tmp.dir.createDirPath(io, "usr/sbin");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/sbin/cupsd", .data = "fixture" });
    try std.testing.expectEqual(@as(?bool, false), try daemonInstalled(a, io, root));
    try tmp.dir.setFilePermissions(io, "usr/sbin/cupsd", .fromMode(0o700), .{});
    try std.testing.expectEqual(@as(?bool, true), try daemonInstalled(a, io, root));
}
