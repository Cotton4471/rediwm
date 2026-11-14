//! Typed wlroots header adapter. API shapes adapted from zig-wlroots;
//! see LICENSE.zig-wlroots for its MIT license.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zxdg = wayland.server.zxdg;

pub const XdgDecorationManagerV1 = extern struct {
    global: *wl.Global,
    decorations: wl.list.Head(XdgToplevelDecorationV1, .link),

    events: extern struct {
        new_toplevel_decoration: wl.Signal(*XdgToplevelDecorationV1),
        destroy: wl.Signal(*XdgDecorationManagerV1),
    },

    data: ?*anyopaque,

    const wlr_xdg_decoration_manager_v1_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*XdgDecorationManagerV1, c.wlr_xdg_decoration_manager_v1_create);
    pub fn create(server: *wl.Server) !*XdgDecorationManagerV1 {
        return wlr_xdg_decoration_manager_v1_create(server) orelse error.OutOfMemory;
    }
};

pub const XdgToplevelDecorationV1 = extern struct {
    pub const Mode = enum(c_int) {
        none = c.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_NONE,
        client_side = c.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE,
        server_side = c.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE,
    };

    pub const State = extern struct {
        mode: Mode,
    };

    pub const Configure = extern struct {
        /// XdgToplevelDecorationV1.configure_list
        link: wl.list.Link,
        surface_configure: *wlr.XdgSurface.Configure,
        mode: Mode,
    };

    resource: *zxdg.ToplevelDecorationV1,
    toplevel: *wlr.XdgToplevel,
    manager: *XdgDecorationManagerV1,
    /// XdgDecorationManagerV1.decorations
    link: wl.list.Link,

    current: State,
    pending: State,

    scheduled_mode: Mode,
    requested_mode: Mode,

    configure_list: wl.list.Head(XdgToplevelDecorationV1.Configure, .link),

    events: extern struct {
        destroy: wl.Signal(*XdgToplevelDecorationV1),
        request_mode: wl.Signal(*XdgToplevelDecorationV1),
    },

    data: ?*anyopaque,

    const wlr_xdg_toplevel_decoration_v1_set_mode = abi.bind(fn (decoration: *XdgToplevelDecorationV1, mode: Mode) callconv(.c) u32, c.wlr_xdg_toplevel_decoration_v1_set_mode);
    pub const setMode = wlr_xdg_toplevel_decoration_v1_set_mode;
};

comptime {
    abi.assertFields(XdgDecorationManagerV1, c.wlr_xdg_decoration_manager_v1);
    abi.assertFields(XdgToplevelDecorationV1, c.wlr_xdg_toplevel_decoration_v1);
    abi.assertLayout(XdgToplevelDecorationV1.State, c.wlr_xdg_toplevel_decoration_v1_state);
    abi.assertLayout(XdgToplevelDecorationV1.Configure, c.wlr_xdg_toplevel_decoration_v1_configure);
}
