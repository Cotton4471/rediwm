//! Bounded Linux proc readers. No compositor, Wayland or UI dependencies.
const std = @import("std");
pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("pwd.h");
    @cInclude("poll.h");
    @cInclude("sys/eventfd.h");
    @cInclude("time.h");
});

pub const Identity = struct {
    pid: i32,
    start: u64,
    pub fn eql(a: Identity, b: Identity) bool {
        return a.pid == b.pid and a.start == b.start;
    }
};
pub const Stat = struct { name: []const u8, state: u8, cpu: u64, start: u64, rss: u64 };

/// comm may contain spaces, newlines and closing parentheses. Field 3 starts
/// after the LAST closing parenthesis; fields 14/15/22/24 are CPU/start/RSS.
pub fn parseStat(bytes: []const u8) ?Stat {
    const begin = std.mem.indexOfScalar(u8, bytes, '(') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return null;
    if (end <= begin) return null;
    var fields = std.mem.tokenizeAny(u8, bytes[end + 1 ..], " \n");
    var out: Stat = .{ .name = bytes[begin + 1 .. end], .state = '?', .cpu = 0, .start = 0, .rss = 0 };
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) switch (index) {
        0 => {
            if (field.len != 1) return null;
            out.state = field[0];
        },
        11, 12 => out.cpu +|= std.fmt.parseInt(u64, field, 10) catch return null,
        19 => out.start = std.fmt.parseInt(u64, field, 10) catch return null,
        21 => {
            const rss = std.fmt.parseInt(i64, field, 10) catch return null;
            out.rss = @intCast(@max(0, rss));
            return out;
        },
        else => {},
    };
    return null;
}

pub fn readAt(dir: c_int, path: [*:0]const u8, buf: []u8) ![]const u8 {
    const fd = c.openat(dir, path, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return switch (std.posix.errno(fd)) {
        .ACCES, .PERM => error.PermissionDenied,
        .NOENT, .SRCH => error.ProcessExited,
        else => error.ReadFailed,
    };
    defer _ = c.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = c.read(fd, buf.ptr + len, buf.len - len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0) return error.ReadFailed;
        if (n == 0) return buf[0..len];
        len += @intCast(n);
    }
    return error.DataTooLarge;
}

pub fn openProcess(pid: i32) !c_int {
    if (pid <= 0) return error.ProcessExited;
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/proc/{d}", .{pid});
    const fd = c.open(path, c.O_DIRECTORY | c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return switch (std.posix.errno(fd)) {
        .ACCES, .PERM => error.PermissionDenied,
        .NOENT, .SRCH => error.ProcessExited,
        else => error.ReadFailed,
    };
    return fd;
}

pub fn readStat(pid: i32, buf: []u8) ?Stat {
    const dir = openProcess(pid) catch return null;
    defer _ = c.close(dir);
    return parseStat(readAt(dir, "stat", buf) catch return null);
}

pub const Uids = [4]u32;
pub fn parseUids(bytes: []const u8) ?Uids {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Uid:")) continue;
        var values = std.mem.tokenizeAny(u8, line[4..], " \t");
        var out: Uids = undefined;
        for (&out) |*uid| uid.* = std.fmt.parseInt(u32, values.next() orelse return null, 10) catch return null;
        return out;
    }
    return null;
}

pub fn owned(uids: Uids, uid: u32) bool {
    for (uids) |value| if (value != uid) return false;
    return true;
}

pub fn protectedName(name: []const u8) bool {
    const clean = if (std.mem.endsWith(u8, name, " (deleted)")) name[0 .. name.len - " (deleted)".len] else name;
    const base = std.fs.path.basename(clean);
    inline for (.{ "rediwm", "rediwm-session", "rediwm-dm", "rediwm-accounts-helper", "rediwm-polkit-agent" }) |protected| {
        if (std.mem.eql(u8, base, protected)) return true;
    }
    return false;
}

pub fn protectedAt(dir: c_int, pid: i32) !bool {
    if (pid <= 1 or pid == c.getpid()) return true;
    var buf: [4096]u8 = undefined;
    const n = c.readlinkat(dir, "exe", &buf, buf.len);
    if (n < 0 or n == buf.len) return error.IdentityUnavailable;
    return protectedName(buf[0..@intCast(n)]);
}

pub const Cpu = struct { total: u64, idle: u64 };
pub fn parseCpu(bytes: []const u8) ?Cpu {
    var fields = std.mem.tokenizeAny(u8, bytes[0 .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len], " \t");
    if (!std.mem.eql(u8, fields.next() orelse return null, "cpu")) return null;
    var out: Cpu = .{ .total = 0, .idle = 0 };
    var count: usize = 0;
    // guest and guest_nice are already included in user/nice.
    while (fields.next()) |field| : (count += 1) {
        if (count == 8) break;
        const ticks = std.fmt.parseInt(u64, field, 10) catch return null;
        out.total +|= ticks;
        if (count == 3 or count == 4) out.idle +|= ticks;
    }
    return if (count >= 4) out else null;
}
pub fn cpuPercent(before: Cpu, after: Cpu) ?f64 {
    if (after.total <= before.total or after.idle < before.idle) return null;
    const total = after.total - before.total;
    return @as(f64, @floatFromInt(total -| (after.idle - before.idle))) * 100 / @as(f64, @floatFromInt(total));
}
/// Process CPU uses one core = 100%, and may exceed 100% for threaded apps.
pub fn processPercent(before: Stat, after: Stat, hz: u64, elapsed_ns: u64) ?f64 {
    if (before.start != after.start or after.cpu < before.cpu or hz == 0 or elapsed_ns == 0) return null;
    return @as(f64, @floatFromInt(after.cpu - before.cpu)) * 100 * 1_000_000_000 /
        (@as(f64, @floatFromInt(hz)) * @as(f64, @floatFromInt(elapsed_ns)));
}

pub const Memory = struct {
    total: u64,
    available: u64,
    swap_total: ?u64,
    swap_free: ?u64,
    pub fn used(self: Memory) u64 {
        return self.total -| self.available;
    }
};
pub fn parseMemory(bytes: []const u8) ?Memory {
    var total: ?u64 = null;
    var available: ?u64 = null;
    var swap_total: ?u64 = null;
    var swap_free: ?u64 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const key = fields.next() orelse continue;
        const relevant = std.mem.eql(u8, key, "MemTotal:") or std.mem.eql(u8, key, "MemAvailable:") or std.mem.eql(u8, key, "SwapTotal:") or std.mem.eql(u8, key, "SwapFree:");
        if (!relevant) continue;
        const kb = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        if (!std.mem.eql(u8, fields.next() orelse return null, "kB")) return null;
        const value = std.math.mul(u64, kb, 1024) catch return null;
        if (std.mem.eql(u8, key, "MemTotal:")) total = value;
        if (std.mem.eql(u8, key, "MemAvailable:")) available = value;
        if (std.mem.eql(u8, key, "SwapTotal:")) swap_total = value;
        if (std.mem.eql(u8, key, "SwapFree:")) swap_free = value;
    }
    return .{ .total = total orelse return null, .available = available orelse return null, .swap_total = swap_total, .swap_free = swap_free };
}

pub fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
