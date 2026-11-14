//! Typed wlroots header adapter. API shapes adapted from zig-wlroots;
//! see LICENSE.zig-wlroots for its MIT license.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

pub const LayerShellV1 = extern struct {
    global: *wl.Global,

    events: extern struct {
        new_surface: wl.Signal(*LayerSurfaceV1),
        destroy: wl.Signal(*LayerShellV1),
    },

    data: ?*anyopaque,

    const wlr_layer_shell_v1_create = abi.bind(fn (server: *wl.Server, version: u32) callconv(.c) ?*LayerShellV1, c.wlr_layer_shell_v1_create);
    pub fn create(server: *wl.Server, version: u32) !*LayerShellV1 {
        return wlr_layer_shell_v1_create(server, version) orelse error.OutOfMemory;
    }
};

pub const LayerSurfaceV1 = extern struct {
    pub const State = extern struct {
        pub const Fields = packed struct(u32) {
            desired_size: bool = false,
            anchor: bool = false,
            exclusive_zone: bool = false,
            margin: bool = false,
            keyboard_interactivity: bool = false,
            layer: bool = false,
            exclusive_edge: bool = false,
            _: u25 = 0,
        };

        committed: Fields,
        anchor: zwlr.LayerSurfaceV1.Anchor,
        exclusive_zone: i32,
        margin: extern struct {
            top: i32,
            right: i32,
            bottom: i32,
            left: i32,
        },
        keyboard_interactive: zwlr.LayerSurfaceV1.KeyboardInteractivity,
        desired_width: u32,
        desired_height: u32,
        layer: zwlr.LayerShellV1.Layer,
        exclusive_edge: u32,

        configure_serial: u32,
        actual_width: u32,
        actual_height: u32,
    };

    pub const Configure = extern struct {
        /// LayerSurfaceV1.configure_list
        link: wl.list.Link,
        serial: u32,

        width: u32,
        height: u32,
    };

    surface: *wlr.Surface,
    output: ?*wlr.Output,
    resource: *wl.Resource,
    shell: *LayerShellV1,
    /// wlr.XdgPopup.link
    popups: wl.list.Head(wlr.XdgPopup, .link),

    namespace: [*:0]u8,

    configured: bool,

    configure_list: wl.list.Head(LayerSurfaceV1.Configure, .link),

    current: State,
    pending: State,

    initialized: bool,
    initial_commit: bool,

    events: extern struct {
        destroy: wl.Signal(*LayerSurfaceV1),
        new_popup: wl.Signal(*wlr.XdgPopup),
    },

    data: ?*anyopaque,

    const wlr_layer_surface_v1_configure = abi.bind(fn (surface: *LayerSurfaceV1, width: u32, height: u32) callconv(.c) u32, c.wlr_layer_surface_v1_configure);
    pub const configure = wlr_layer_surface_v1_configure;

    pub const getExclusiveEdge = abi.bind(fn (surface: *LayerSurfaceV1) callconv(.c) wlr.Edges, c.wlr_layer_surface_v1_get_exclusive_edge);

    const wlr_layer_surface_v1_destroy = abi.bind(fn (surface: *LayerSurfaceV1) callconv(.c) void, c.wlr_layer_surface_v1_destroy);
    pub const destroy = wlr_layer_surface_v1_destroy;

    const wlr_layer_surface_v1_try_from_wlr_surface = abi.bind(fn (surface: *wlr.Surface) callconv(.c) ?*LayerSurfaceV1, c.wlr_layer_surface_v1_try_from_wlr_surface);
    pub const tryFromWlrSurface = wlr_layer_surface_v1_try_from_wlr_surface;

    const wlr_layer_surface_v1_for_each_surface = abi.bind(fn (
        surface: *LayerSurfaceV1,
        iterator: *const fn (*wlr.Surface, c_int, c_int, ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
    ) callconv(.c) void, c.wlr_layer_surface_v1_for_each_surface);
    pub inline fn forEachSurface(
        surface: *LayerSurfaceV1,
        comptime T: type,
        comptime iterator: fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: T) void,
        data: T,
    ) void {
        wlr_layer_surface_v1_for_each_surface(
            surface,
            struct {
                fn wrapper(s: *wlr.Surface, sx: c_int, sy: c_int, d: ?*anyopaque) callconv(.c) void {
                    iterator(s, sx, sy, @ptrCast(@alignCast(d)));
                }
            }.wrapper,
            data,
        );
    }

    const wlr_layer_surface_v1_for_each_popup_surface = abi.bind(fn (
        surface: *LayerSurfaceV1,
        iterator: *const fn (*wlr.Surface, c_int, c_int, ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
    ) callconv(.c) void, c.wlr_layer_surface_v1_for_each_popup_surface);
    pub inline fn forEachPopupSurface(
        surface: *LayerSurfaceV1,
        comptime T: type,
        comptime iterator: fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: T) void,
        data: T,
    ) void {
        wlr_layer_surface_v1_for_each_popup_surface(
            surface,
            struct {
                fn wrapper(s: *wlr.Surface, sx: c_int, sy: c_int, d: ?*anyopaque) callconv(.c) void {
                    iterator(s, sx, sy, @ptrCast(@alignCast(d)));
                }
            }.wrapper,
            data,
        );
    }

    const wlr_layer_surface_v1_surface_at = abi.bind(fn (surface: *LayerSurfaceV1, sx: f64, sy: f64, sub_x: *f64, sub_y: *f64) callconv(.c) ?*wlr.Surface, c.wlr_layer_surface_v1_surface_at);
    pub const surfaceAt = wlr_layer_surface_v1_surface_at;

    const wlr_layer_surface_v1_popup_surface_at = abi.bind(fn (surface: *LayerSurfaceV1, sx: f64, sy: f64, sub_x: *f64, sub_y: *f64) callconv(.c) ?*wlr.Surface, c.wlr_layer_surface_v1_popup_surface_at);
    pub const popupSurfaceAt = wlr_layer_surface_v1_popup_surface_at;

    const wlr_layer_surface_v1_from_resource = abi.bind(fn (resource: *wl.Resource) callconv(.c) ?*LayerSurfaceV1, c.wlr_layer_surface_v1_from_resource);
    pub const fromResource = wlr_layer_surface_v1_from_resource;
};

comptime {
    abi.assertFields(LayerShellV1, c.wlr_layer_shell_v1);
    abi.assertFields(LayerSurfaceV1, c.wlr_layer_surface_v1);
    abi.assertLayout(LayerSurfaceV1.State, c.wlr_layer_surface_v1_state);
    abi.assertLayout(LayerSurfaceV1.Configure, c.struct_wlr_layer_surface_v1_configure);
}
