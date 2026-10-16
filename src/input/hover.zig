//! Input hover state: border glow, taskbar and toast hover.

const std = @import("std");
const Input = @import("../Input.zig");
const Taskbar = @import("../Taskbar.zig");
const Toplevel = @import("../Toplevel.zig");
const chrome = @import("../chrome.zig");
const resize = @import("../resize.zig");
const scene_data = @import("../scene_data.zig");

/// The focused window's edge lights up where the pointer nears it, unless
/// something else (another window, shell UI) is under the pointer.
pub fn updateBorderGlow(input: *Input, hit: scene_data.Hit) void {
    var target: ?*Toplevel = null;
    if (@import("../config_runtime/actions.zig").focusedToplevel(input.server)) |top| {
        const clear = switch (hit) {
            .none, .layer, .desktop => true,
            .chrome => |h| h.toplevel == top,
            .surface => |h| h.toplevel == top,
            else => false,
        };
        if (clear) target = top;
    }
    input.setBorderGlowTarget(target);
}

/// A compositor grab owns the pointer even outside the window's current box.
/// Refresh again when chrome applies a size: client replies can follow motion.
pub fn updateGrabBorderGlow(input: *Input) void {
    if (input.cursor_mode != .move and input.cursor_mode != .resize) return;
    input.setBorderGlowTarget(input.grabbed_toplevel);
}

pub fn setBorderGlowTarget(input: *Input, target: ?*Toplevel) void {
    if (input.glow_toplevel) |previous| {
        if (previous != target) previous.setGlow(null);
    }
    input.glow_toplevel = target;
    if (target) |top| top.setGlow(top.glowProbe(input.cursor.x, input.cursor.y));
}

pub fn setHover(input: *Input, toplevel: ?*Toplevel, control: ?chrome.ControlKind) void {
    if (input.hovered_toplevel) |previous| {
        if (previous != toplevel) previous.applyHover(false, null);
    }
    input.hovered_toplevel = toplevel;
    if (toplevel) |hovered| hovered.applyHover(true, control);
}

pub fn clearTaskbarHover(input: *Input) void {
    if (input.hovered_taskbar) |previous| {
        previous.pointerLeave();
        input.hovered_taskbar = null;
    }
}

pub fn clearToastHover(input: *Input) void {
    if (input.hovered_toast) |previous| {
        previous.setHovered(false, @import("../Taskbar.zig").nowMs());
        input.hovered_toast = null;
    }
}

pub fn setToastHover(input: *Input, toast: *@import("../notifications/toast.zig").Toast) void {
    if (input.hovered_toast == toast) return;
    input.clearToastHover();
    input.hovered_toast = toast;
    toast.setHovered(true, @import("../Taskbar.zig").nowMs());
}
