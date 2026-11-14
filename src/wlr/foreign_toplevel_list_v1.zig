//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wl = @import("wayland").server.wl;

pub const ExtForeignToplevelListV1 = extern struct {
    global: *wl.Global,
    resources: wl.list.Head(wl.Resource, null),
    toplevels: wl.list.Head(ExtForeignToplevelHandleV1, .link),

    events: extern struct {
        destroy: wl.Signal(void),
    },

    data: ?*anyopaque,

    const wlr_ext_foreign_toplevel_list_v1_create = abi.bind(fn (
        display: *wl.Server,
        version: u32,
    ) callconv(.c) ?*ExtForeignToplevelListV1, c.wlr_ext_foreign_toplevel_list_v1_create);
    pub fn create(
        display: *wl.Server,
        version: u32,
    ) !*ExtForeignToplevelListV1 {
        return wlr_ext_foreign_toplevel_list_v1_create(display, version) orelse error.OutOfMemory;
    }
};

pub const ExtForeignToplevelHandleV1 = extern struct {
    list: *ExtForeignToplevelListV1,
    resources: wl.list.Head(wl.Resource, null),
    link: wl.list.Link,

    title: ?[*:0]const u8,
    app_id: ?[*:0]const u8,
    identifier: [*:0]const u8,

    events: extern struct {
        destroy: wl.Signal(void),
    },

    data: ?*anyopaque,

    pub const State = extern struct {
        title: ?[*:0]const u8,
        app_id: ?[*:0]const u8,
    };

    const wlr_ext_foreign_toplevel_handle_v1_create = abi.bind(fn (
        list: *ExtForeignToplevelListV1,
        state: *const State,
    ) callconv(.c) ?*ExtForeignToplevelHandleV1, c.wlr_ext_foreign_toplevel_handle_v1_create);
    pub fn create(
        list: *ExtForeignToplevelListV1,
        state: *const State,
    ) !*ExtForeignToplevelHandleV1 {
        return wlr_ext_foreign_toplevel_handle_v1_create(list, state) orelse error.ToplevelHandleCreateFailed;
    }

    const wlr_ext_foreign_toplevel_handle_v1_from_resource = abi.bind(fn (
        resource: *wl.Resource,
    ) callconv(.c) ?*ExtForeignToplevelHandleV1, c.wlr_ext_foreign_toplevel_handle_v1_from_resource);
    pub const fromResource = wlr_ext_foreign_toplevel_handle_v1_from_resource;

    const wlr_ext_foreign_toplevel_handle_v1_destroy = abi.bind(fn (
        toplevel: *ExtForeignToplevelHandleV1,
    ) callconv(.c) void, c.wlr_ext_foreign_toplevel_handle_v1_destroy);
    pub const destroy = wlr_ext_foreign_toplevel_handle_v1_destroy;

    const wlr_ext_foreign_toplevel_handle_v1_update_state = abi.bind(fn (
        toplevel: *ExtForeignToplevelHandleV1,
        state: *const State,
    ) callconv(.c) void, c.wlr_ext_foreign_toplevel_handle_v1_update_state);
    pub const updateState = wlr_ext_foreign_toplevel_handle_v1_update_state;
};

comptime {
    abi.assertFields(ExtForeignToplevelListV1, c.wlr_ext_foreign_toplevel_list_v1);
    abi.assertFields(ExtForeignToplevelHandleV1, c.wlr_ext_foreign_toplevel_handle_v1);
    abi.assertFields(ExtForeignToplevelHandleV1.State, c.wlr_ext_foreign_toplevel_handle_v1_state);
    @import("signal.zig").assertSameLayout(ExtForeignToplevelHandleV1.State, c.wlr_ext_foreign_toplevel_handle_v1_state);
}
