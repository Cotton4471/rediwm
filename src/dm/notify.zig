//! Only the main DM sends readiness; the unprivileged greeter uses its
//! inherited private IPC connection and never receives the notify socket.
const std = @import("std");
const linux = std.os.linux;
const c = @import("c");

pub fn greeterReady() !void {
    const raw = c.getenv("NOTIFY_SOCKET") orelse return;
    const path = std.mem.span(raw);
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len < 2 or path.len >= address.path.len or
        (path[0] != '/' and path[0] != '@')) return error.InvalidNotifySocket;
    @memcpy(address.path[0..path.len], path);
    if (path[0] == '@') address.path[0] = 0;
    const fd_result = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(fd_result) != .SUCCESS) return error.NotifySocketFailed;
    const fd: i32 = @intCast(fd_result);
    defer _ = linux.close(fd);
    const message = "READY=1\nSTATUS=Greeter presented; seat input and login interface operational";
    const len: u32 = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + @intFromBool(path[0] != '@'));
    const result = linux.sendto(fd, message.ptr, message.len, linux.MSG.NOSIGNAL, @ptrCast(&address), len);
    if (linux.errno(result) != .SUCCESS or result != message.len) return error.NotifySendFailed;
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.BOOTTIME, &ts)) == .SUCCESS)
        std.log.info("greeter-operational boottime={d}.{d:0>9}", .{ ts.sec, ts.nsec });
}
