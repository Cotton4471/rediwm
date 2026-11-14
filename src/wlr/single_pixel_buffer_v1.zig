//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wl = @import("wayland").server.wl;

pub const SinglePixelBufferManagerV1 = extern struct {
    global: *wl.Global,

    const wlr_single_pixel_buffer_manager_v1_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*SinglePixelBufferManagerV1, c.wlr_single_pixel_buffer_manager_v1_create);
    pub fn create(server: *wl.Server) !*SinglePixelBufferManagerV1 {
        return wlr_single_pixel_buffer_manager_v1_create(server) orelse error.OutOfMemory;
    }
};

comptime {
    abi.assertFields(SinglePixelBufferManagerV1, c.wlr_single_pixel_buffer_manager_v1);
}
