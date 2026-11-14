//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;
const ext = wayland.server.ext;

pub const SessionLockManagerV1 = extern struct {
    global: *wl.Global,

    events: extern struct {
        new_lock: wl.Signal(*SessionLockV1),
        destroy: wl.Signal(void),
    },

    data: ?*anyopaque,

    const wlr_session_lock_manager_v1_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*SessionLockManagerV1, c.wlr_session_lock_manager_v1_create);
    pub fn create(server: *wl.Server) !*SessionLockManagerV1 {
        return wlr_session_lock_manager_v1_create(server) orelse error.OutOfMemory;
    }
};

pub const SessionLockV1 = extern struct {
    resource: *ext.SessionLockV1,

    surfaces: wl.list.Head(SessionLockSurfaceV1, .link),

    events: extern struct {
        new_surface: wl.Signal(*SessionLockSurfaceV1),
        unlock: wl.Signal(void),
        destroy: wl.Signal(void),
    },

    data: ?*anyopaque,

    const wlr_session_lock_v1_send_locked = abi.bind(fn (lock: *SessionLockV1) callconv(.c) void, c.wlr_session_lock_v1_send_locked);
    pub const sendLocked = wlr_session_lock_v1_send_locked;

    const wlr_session_lock_v1_destroy = abi.bind(fn (lock: *SessionLockV1) callconv(.c) void, c.wlr_session_lock_v1_destroy);
    pub const destroy = wlr_session_lock_v1_destroy;
};

pub const SessionLockSurfaceV1 = extern struct {
    pub const State = extern struct {
        width: u32,
        height: u32,
        configure_serial: u32,
    };

    pub const Configure = extern struct {
        /// SessionLockSurfaceV1.configure_list
        link: wl.list.Link,
        serial: u32,
        width: u32,
        height: u32,
    };

    resource: *ext.SessionLockSurfaceV1,
    /// SessionLockV1.surfaces
    link: wl.list.Link,

    output: *wlr.Output,
    surface: *wlr.Surface,

    configured: bool,

    configure_list: wl.list.Head(Configure, .link),

    current: State,
    pending: State,

    events: extern struct {
        destroy: wl.Signal(void),
    },

    data: ?*anyopaque,

    const wlr_session_lock_surface_v1_configure = abi.bind(fn (lock_surface: *SessionLockSurfaceV1, width: u32, height: u32) callconv(.c) u32, c.wlr_session_lock_surface_v1_configure);
    pub const configure = wlr_session_lock_surface_v1_configure;

    const wlr_session_lock_surface_v1_try_from_wlr_surface = abi.bind(fn (surface: *wlr.Surface) callconv(.c) ?*SessionLockSurfaceV1, c.wlr_session_lock_surface_v1_try_from_wlr_surface);
    pub const tryFromWlrSurface = wlr_session_lock_surface_v1_try_from_wlr_surface;
};

comptime {
    abi.assertFields(SessionLockManagerV1, c.wlr_session_lock_manager_v1);
    abi.assertFields(SessionLockV1, c.wlr_session_lock_v1);
    abi.assertFields(SessionLockSurfaceV1, c.wlr_session_lock_surface_v1);
    abi.assertFields(SessionLockSurfaceV1.State, c.wlr_session_lock_surface_v1_state);
    @import("signal.zig").assertSameLayout(SessionLockSurfaceV1.State, c.wlr_session_lock_surface_v1_state);
    abi.assertFields(SessionLockSurfaceV1.Configure, c.struct_wlr_session_lock_surface_v1_configure);
    @import("signal.zig").assertSameLayout(SessionLockSurfaceV1.Configure, c.struct_wlr_session_lock_surface_v1_configure);
}
