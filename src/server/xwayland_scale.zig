//! Server Xwayland scale: configured, computed and pending.

const std = @import("std");
const Server = @import("../Server.zig");

pub fn configuredXwaylandNativeScaling(server: *Server) bool {
    return server.config.compositor.xwayland_native_scaling or server.config.compositor.xwayland_scale != 0;
}

pub fn computeXwaylandScale(server: *Server) f64 {
    if (server.config.compositor.xwayland_scale != 0) return server.config.compositor.xwayland_scale;
    if (!server.config.compositor.xwayland_native_scaling) return 1;
    var factor: f64 = 1;
    var have_output = false;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.isLogicallyEnabled() and output.wlr_output.enabled) {
            have_output = true;
            factor = @max(factor, @as(f64, @ceil(output.wlr_output.scale)));
        }
    }
    if (!have_output and server.config.compositor.xwayland_native_scaling) {
        if (server.scale_override) |scale| factor = @ceil(scale);
    }
    return factor;
}

pub fn xwaylandScale(server: *Server) f64 {
    if (server.xwayland) |xw| return xw.scale;
    return server.computeXwaylandScale();
}

pub fn xwaylandScalePending(server: *Server) ?f64 {
    const xwayland = server.xwayland orelse return null;
    const desired = server.computeXwaylandScale();
    if (desired != xwayland.scale or server.configuredXwaylandNativeScaling() != xwayland.native_scaling) return desired;
    return null;
}
