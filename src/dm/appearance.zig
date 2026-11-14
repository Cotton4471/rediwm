//! Login appearance lives outside private/encrypted homes. Root creates only
//! directories; it never opens or parses the account's appearance files.
const std = @import("std");
const c = @import("c");

pub const root = "/var/lib/rediwm-appearance";

pub fn provision(uid: u32, gid: u32) !void {
    if (c.mkdir(root, 0o755) != 0 and std.posix.errno(-1) != .EXIST) return error.CreateDirectoryFailed;
    const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.OpenDirectoryFailed;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_uid != 0 or stat.st_mode & 0o022 != 0) return error.UnsafeDirectory;
    // mkdir is subject to the service's umask; the greeter must traverse it.
    if (c.fchmod(fd, 0o755) != 0) return error.DirectoryPermissionsFailed;
    try provisionAt(fd, uid, gid);
}

fn provisionAt(parent: c_int, uid: u32, gid: u32) !void {
    var buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&buf, "{d}", .{uid}, 0);
    const created = c.mkdirat(parent, name, 0o755) == 0;
    if (!created and std.posix.errno(-1) != .EXIST) return error.CreateDirectoryFailed;
    const fd = c.openat(parent, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.OpenDirectoryFailed;
    defer _ = c.close(fd);
    if (created) {
        // Set mode before handing ownership to the account. Never chmod or
        // chown an existing user-controlled entry (including a symlink).
        if (c.fchmod(fd, 0o755) != 0 or c.fchown(fd, uid, gid) != 0) return error.DirectoryPermissionsFailed;
    }
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_uid != uid) return error.UnsafeDirectory;
}

test "login appearance provisioning is per uid and refuses symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const uid = c.getuid();
    try provisionAt(tmp.dir.handle, uid, c.getgid());
    try provisionAt(tmp.dir.handle, uid, c.getgid());
    var name_buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buf, "{d}", .{uid}, 0);
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(tmp.dir.handle, name, &stat, c.AT_SYMLINK_NOFOLLOW));
    try std.testing.expectEqual(uid, stat.st_uid);
    try std.testing.expectEqual(@as(c_uint, 0o755), stat.st_mode & 0o777);
    try tmp.dir.deleteDir(std.testing.io, name);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat(".", tmp.dir.handle, name));
    try std.testing.expectError(error.OpenDirectoryFailed, provisionAt(tmp.dir.handle, uid, c.getgid()));
}
