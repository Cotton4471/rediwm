//! Output configuration lookups: transform, scale and display mode.

const std = @import("std");
const Output = @import("../Output.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const output_transform = @import("config").output_transform;

pub fn configured(server: *Server, out: *wlr.Output) ?@import("config").loader.OutputConfig {
    for (server.config.outputs) |config| {
        if (std.mem.eql(u8, config.name, std.mem.span(out.name))) return config;
    }
    return null;
}

pub fn configuredTransform(server: *Server, out: *wlr.Output) output_transform.Transform {
    return (configured(server, out) orelse return .normal).transform;
}

pub fn wlTransform(transform: output_transform.Transform) wl.Output.Transform {
    return switch (transform) {
        .normal => .normal,
        .@"90" => .@"90",
        .@"180" => .@"180",
        .@"270" => .@"270",
        .flipped => .flipped,
        .flipped_90 => .flipped_90,
        .flipped_180 => .flipped_180,
        .flipped_270 => .flipped_270,
    };
}

pub fn configuredScale(server: *Server, out: *wlr.Output) f32 {
    return scaleForDimensions(server, out, out.width, out.height);
}

pub fn scaleForMode(server: *Server, out: *wlr.Output, mode: ?*wlr.Output.Mode) f32 {
    return scaleForDimensions(server, out, if (mode) |m| m.width else out.width, if (mode) |m| m.height else out.height);
}

pub fn scaleForDimensions(server: *Server, out: *wlr.Output, width: i32, height: i32) f32 {
    if (server.scale_override) |scale| return scale;
    for (server.config.outputs) |config| {
        if (std.mem.eql(u8, config.name, std.mem.span(out.name))) {
            if (config.scale) |scale| return scale;
            break;
        }
    }
    return automaticScale(server, out, width, height);
}

pub fn automaticScale(server: *Server, out: *wlr.Output, width: i32, height: i32) f32 {
    if (server.scale_override) |scale| return scale;
    // Nested outputs describe a host window, not necessarily a physical panel.
    if (!out.isDrm()) return 1;
    return @import("../output_scale.zig").calculate(
        width,
        height,
        out.phys_width,
        out.phys_height,
    );
}

/// Resolve advertised modes first, then standard lower-resolution candidates.
pub fn configuredMode(server: *Server, out: *wlr.Output) ?@import("../output_modes.zig").Choice {
    for (server.config.outputs) |config| {
        if (!std.mem.eql(u8, config.name, std.mem.span(out.name))) continue;
        const width = config.width orelse continue;
        const height = config.height orelse continue;
        return resolveDisplayMode(out, width, height, config.refresh_mhz);
    }
    return null;
}

pub fn resolveDisplayMode(out: *wlr.Output, width: i32, height: i32, refresh: ?i32) ?@import("../output_modes.zig").Choice {
    var best: ?*wlr.Output.Mode = null;
    var it = out.modes.iterator(.forward);
    while (it.next()) |mode| {
        if (mode.width != width or mode.height != height) continue;
        if (refresh) |rate| {
            if (mode.refresh == rate) return @import("../output_modes.zig").Choice.fromMode(mode);
        } else if (best == null or mode.refresh > best.?.refresh) best = mode;
    }
    if (best) |mode| return @import("../output_modes.zig").Choice.fromMode(mode);
    return @import("../output_modes.zig").customChoice(out, width, height, refresh);
}
