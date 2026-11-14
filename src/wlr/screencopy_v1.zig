//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const ScreencopyManagerV1 = extern struct {
    global: *wl.Global,
    frames: wl.list.Head(ScreencopyFrameV1, .link),

    events: extern struct {
        destroy: wl.Signal(*ScreencopyManagerV1),
    },

    data: ?*anyopaque,

    const wlr_screencopy_manager_v1_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*ScreencopyManagerV1, c.wlr_screencopy_manager_v1_create);
    pub fn create(server: *wl.Server) !*ScreencopyManagerV1 {
        return wlr_screencopy_manager_v1_create(server) orelse error.OutOfMemory;
    }
};

pub const ScreencopyClientV1 = extern struct {
    ref: c_int,
    manager: *ScreencopyManagerV1,
    // A list head, but usage is internal to wlroots
    damages: wl.list.Link,
};

pub const ScreencopyFrameV1 = extern struct {
    resource: *wl.Resource,
    client: *ScreencopyClientV1,
    /// ScreencopyManagerV1.frames
    link: wl.list.Link,

    shm_format: u32,
    dmabuf_format: u32,
    box: wlr.Box,
    shm_stride: c_int,

    overlay_cursor: bool,
    cursor_locked: bool,

    with_damage: bool,

    buffer_cap: wlr.BufferCap,
    buffer: ?*wlr.Buffer,

    output: *wlr.Output,

    data: ?*anyopaque,
};

comptime {
    abi.assertFields(ScreencopyManagerV1, c.wlr_screencopy_manager_v1);
    abi.assertFields(ScreencopyClientV1, c.wlr_screencopy_v1_client);
    abi.assertFields(ScreencopyFrameV1, c.wlr_screencopy_frame_v1);
}
