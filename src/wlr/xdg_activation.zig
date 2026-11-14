//! Typed wlroots header adapter. API shapes adapted from zig-wlroots;
//! see LICENSE.zig-wlroots for its MIT license.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const XdgActivationV1 = extern struct {
    pub const event = struct {
        pub const RequestActivate = extern struct {
            activation: *wlr.XdgActivationV1,
            token: *wlr.XdgActivationTokenV1,
            surface: *wlr.Surface,
        };
    };

    global: *wl.Global,

    /// token timeout in milliseconds (0 to disable)
    token_timeout_msec: u32,

    tokens: wl.list.Head(XdgActivationTokenV1, .link),

    events: extern struct {
        destroy: wl.Signal(*XdgActivationV1),
        request_activate: wl.Signal(*XdgActivationV1.event.RequestActivate),
        new_token: wl.Signal(*XdgActivationTokenV1),
    },

    const wlr_xdg_activation_v1_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*XdgActivationV1, c.wlr_xdg_activation_v1_create);
    pub fn create(server: *wl.Server) !*XdgActivationV1 {
        return wlr_xdg_activation_v1_create(server) orelse error.OutOfMemory;
    }

    const wlr_xdg_activation_token_v1_create = abi.bind(fn (activation: *XdgActivationV1) callconv(.c) ?*XdgActivationTokenV1, c.wlr_xdg_activation_token_v1_create);
    pub const createToken = wlr_xdg_activation_token_v1_create;

    const wlr_xdg_activation_v1_find_token = abi.bind(fn (activation: *XdgActivationV1, token_str: [*:0]const u8) callconv(.c) ?*XdgActivationTokenV1, c.wlr_xdg_activation_v1_find_token);
    pub const findToken = wlr_xdg_activation_v1_find_token;

    const wlr_xdg_activation_v1_add_token = abi.bind(fn (activation: *XdgActivationV1, token_str: [*:0]const u8) callconv(.c) ?*XdgActivationTokenV1, c.wlr_xdg_activation_v1_add_token);
    pub const addToken = wlr_xdg_activation_v1_add_token;
};

pub const XdgActivationTokenV1 = extern struct {
    activation: *wlr.XdgActivationV1,
    surface: ?*wlr.Surface,
    seat: ?*wlr.Seat,

    /// Invalid if seat is null
    serial: u32,
    app_id: ?[*:0]u8,

    link: wl.list.Link,

    data: ?*anyopaque,

    events: extern struct {
        destroy: wl.Signal(void),
    },

    const wlr_xdg_activation_token_v1_destroy = abi.bind(fn (token: *XdgActivationTokenV1) callconv(.c) void, c.wlr_xdg_activation_token_v1_destroy);
    pub const destroy = wlr_xdg_activation_token_v1_destroy;

    const wlr_xdg_activation_token_v1_get_name = abi.bind(fn (token: *XdgActivationTokenV1) callconv(.c) [*:0]const u8, c.wlr_xdg_activation_token_v1_get_name);
    pub const name = wlr_xdg_activation_token_v1_get_name;
};

comptime {
    abi.assertFields(XdgActivationV1, c.wlr_xdg_activation_v1);
    abi.assertFields(XdgActivationTokenV1, c.wlr_xdg_activation_token_v1);
    abi.assertLayout(XdgActivationV1.event.RequestActivate, c.wlr_xdg_activation_v1_request_activate_event);
}
