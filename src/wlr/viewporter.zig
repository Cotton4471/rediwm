//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const Viewporter = extern struct {
    global: *wl.Global,

    events: extern struct {
        destroy: wl.Signal(void),
    },

    const wlr_viewporter_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*Viewporter, c.wlr_viewporter_create);
    pub fn create(server: *wl.Server) !*Viewporter {
        return wlr_viewporter_create(server) orelse error.OutOfMemory;
    }
};

comptime {
    abi.assertFields(Viewporter, c.wlr_viewporter);
}
