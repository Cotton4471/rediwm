//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const LinuxDrmSyncobjManagerV1 = extern struct {
    global: *wl.Global,

    const wlr_linux_drm_syncobj_manager_v1_create = abi.bind(fn (server: *wl.Server, version: u32, drm_fd: c_int) callconv(.c) ?*LinuxDrmSyncobjManagerV1, c.wlr_linux_drm_syncobj_manager_v1_create);
    pub const create = wlr_linux_drm_syncobj_manager_v1_create;
};

comptime {
    abi.assertFields(LinuxDrmSyncobjManagerV1, c.wlr_linux_drm_syncobj_manager_v1);
}
