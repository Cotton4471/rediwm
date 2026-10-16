//! Server wake handlers: audio, battery and the GPU timer.

const std = @import("std");
const Server = @import("../Server.zig");
const wl = @import("wayland").server.wl;
const battery_mod = @import("../taskbar/battery.zig");
const Taskbar = @import("../Taskbar.zig");
const gpu_timer_idle_ns = Server.gpu_timer_idle_ns;

/// Best-effort: `null` on any failure just means the taskbar/control-center
/// UI catches up to an external volume change (another app, `pactl`) on its
/// next incidental repaint instead of immediately — never fatal.
pub fn createAudioWakeFd() ?std.posix.fd_t {
    const rc = std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// Runs on the compositor thread, woken by `audio.AudioManager`'s PA-thread
/// callback incrementing `fd` (see audio/pipewire.zig's module doc
/// comment) — never touches `AudioManager` state directly, since the actual
/// re-read happens in Taskbar.tick and the open control center's next frame.
pub fn handleAudioWake(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = mask;
    var buf: [8]u8 = undefined;
    _ = std.posix.system.read(fd, &buf, buf.len);
    @import("../osd.zig").refreshAudio(server);
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.taskbar) |bar| bar.markDirty(Taskbar.paint_audio);
    }
    // Only General and Audio show audio state; elsewhere a rebuild is wasted.
    if (server.input.open_control_center) |cc| if (cc.page == .general or cc.page == .audio) cc.refresh();
    if (server.locker) |lock| lock.controlsChanged();
    server.scheduleFrames();
    return 0;
}

/// Drains everything queued, so events that arrive together (a plug-in sends
/// several) cost one sysfs read, shared by every output's taskbar.
pub fn handleBatteryUevent(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = mask;
    if (!battery_mod.drainUevents(fd)) return 0;
    const state = battery_mod.read(server.io, @import("../main.zig").gpa);
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.taskbar) |bar| bar.applyBattery(state);
    }
    return 0;
}

pub fn ensureGpuTimer(server: *Server) void {
    server.gpu_timer_used_ns = @import("../ipc/stats.zig").nowNs();
    if (server.gpu_timer_tried) return;
    server.gpu_timer_tried = true;
    server.gpu_timer = @import("../gpu_timing.zig").Timer.create(server.renderer);
}

/// Whether a stats request came in recently enough that per-stage frame timing
/// is worth its clock reads (the same window the GPU timer uses).
pub fn observingStats(server: *const Server, now_ns: u64) bool {
    return server.gpu_timer_tried and now_ns -% server.gpu_timer_used_ns < gpu_timer_idle_ns;
}

/// One `perf` query must not leave the timer's per-frame cost (measured
/// ~0.17 ms at 60 Hz on Iris Xe) running for the rest of the session. After
/// five minutes without a stats request it stops; the next request restarts it.
pub fn expireGpuTimer(server: *Server) void {
    const timer = server.gpu_timer orelse return;
    if (@import("../ipc/stats.zig").nowNs() -% server.gpu_timer_used_ns < gpu_timer_idle_ns) return;
    timer.destroy();
    server.gpu_timer = null;
    server.gpu_timer_tried = false;
}
