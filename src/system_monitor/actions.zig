//! Action authority is checked again at execution, never trusted from a row.
const std = @import("std");
const proc = @import("proc.zig");
const c = proc.c;
pub const Kind = enum { end, force };

pub fn execute(identity: proc.Identity, kind: Kind) !void {
    const rc = std.os.linux.pidfd_open(identity.pid, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return signalError(std.os.linux.errno(rc));
    const pidfd: i32 = @intCast(rc);
    defer _ = c.close(pidfd);
    // Open the proc directory AFTER the pidfd. If PID reuse occurs between
    // them, the old pidfd becomes readable and the final liveness gate fails.
    const dir = try proc.openProcess(identity.pid);
    defer _ = c.close(dir);
    var stat_buf: [4096]u8 = undefined;
    const stat = proc.parseStat(try proc.readAt(dir, "stat", &stat_buf)) orelse return error.IdentityUnavailable;
    if (stat.start != identity.start) return error.ProcessExited;
    var status_buf: [16384]u8 = undefined;
    const uids = proc.parseUids(try proc.readAt(dir, "status", &status_buf)) orelse return error.IdentityUnavailable;
    if (!proc.owned(uids, c.getuid())) return error.PermissionDenied;
    if (try proc.protectedAt(dir, identity.pid)) return error.ProtectedProcess;
    // fdinfo identifies the task referred to by THIS pidfd, not whichever task
    // currently occupies /proc/PID. An exited pidfd reports Pid: -1.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/proc/self/fdinfo/{d}", .{pidfd});
    var info_buf: [4096]u8 = undefined;
    const info = try proc.readAt(c.AT_FDCWD, path, &info_buf);
    var lines = std.mem.splitScalar(u8, info, '\n');
    var pid_matches = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Pid:")) {
            const pid = std.fmt.parseInt(i32, std.mem.trim(u8, line[4..], " \t"), 10) catch return error.IdentityUnavailable;
            pid_matches = pid == identity.pid;
        }
    }
    if (!pid_matches) return error.ProcessExited;
    var fd = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
    if (c.poll(&fd, 1, 0) != 0) return error.ProcessExited;
    const result = std.os.linux.pidfd_send_signal(pidfd, if (kind == .end) std.posix.SIG.TERM else std.posix.SIG.KILL, null, 0);
    if (std.os.linux.errno(result) != .SUCCESS) return signalError(std.os.linux.errno(result));
}

fn signalError(err: std.os.linux.E) error{ ProcessExited, PermissionDenied, PidfdUnavailable, SignalFailed } {
    return switch (err) {
        .SRCH, .NOENT => error.ProcessExited,
        .PERM, .ACCES => error.PermissionDenied,
        .NOSYS, .INVAL => error.PidfdUnavailable,
        else => error.SignalFailed,
    };
}

pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.ProcessExited => "Process already exited",
        error.PermissionDenied => "Permission denied: only your own processes can be managed",
        error.ProtectedProcess => "This essential RediWM session process is protected",
        error.PidfdUnavailable => "Safe process actions require Linux pidfd support",
        error.IdentityUnavailable => "Could not verify the process identity",
        else => "Could not send the signal",
    };
}
