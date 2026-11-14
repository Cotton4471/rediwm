//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const std = @import("std");
const wl = @import("wayland").server.wl;

pub const ForeignToplevelManagerV1 = extern struct {
    event_loop: *wl.EventLoop,
    global: *wl.Global,
    resources: wl.list.Head(wl.Resource, null),
    toplevels: wl.list.Head(ForeignToplevelHandleV1, .link),

    events: extern struct {
        destroy: wl.Signal(*ForeignToplevelManagerV1),
    },

    data: ?*anyopaque,

    const wlr_foreign_toplevel_manager_v1_create = abi.bind(fn (wl_server: *wl.Server) callconv(.c) ?*ForeignToplevelManagerV1, c.wlr_foreign_toplevel_manager_v1_create);
    pub fn create(wl_server: *wl.Server) !*ForeignToplevelManagerV1 {
        return wlr_foreign_toplevel_manager_v1_create(wl_server) orelse error.OutOfMemory;
    }
};

pub const ForeignToplevelHandleV1 = extern struct {
    pub const State = packed struct(u32) {
        maximized: bool = false,
        minimized: bool = false,
        activated: bool = false,
        fullscreen: bool = false,
        _: u28 = 0,
    };

    pub const Output = extern struct {
        link: wl.list.Link,
        output: *wlr.Output,
        toplevel: *ForeignToplevelHandleV1,
    };

    pub const event = struct {
        pub const Maximized = extern struct {
            toplevel: *ForeignToplevelHandleV1,
            maximized: bool,
        };

        pub const Minimized = extern struct {
            toplevel: *ForeignToplevelHandleV1,
            minimized: bool,
        };

        pub const Activated = extern struct {
            toplevel: *ForeignToplevelHandleV1,
            seat: *wlr.Seat,
        };

        pub const Fullscreen = extern struct {
            toplevel: *ForeignToplevelHandleV1,
            fullscreen: bool,
            output: ?*wlr.Output,
        };

        pub const SetRectangle = extern struct {
            toplevel: *ForeignToplevelHandleV1,
            surface: *wlr.Surface,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        };
    };

    manager: *ForeignToplevelManagerV1,
    resources: wl.list.Head(wl.Resource, null),
    link: wl.list.Link,
    idle_source: ?*wl.EventSource,

    title: ?[*:0]u8,
    app_id: ?[*:0]u8,
    parent: ?*ForeignToplevelHandleV1,
    outputs: wl.list.Head(ForeignToplevelHandleV1.Output, .link),
    state: State,

    events: extern struct {
        request_maximize: wl.Signal(*event.Maximized),
        request_minimize: wl.Signal(*event.Minimized),
        request_activate: wl.Signal(*event.Activated),
        request_fullscreen: wl.Signal(*event.Fullscreen),
        request_close: wl.Signal(*ForeignToplevelHandleV1),
        set_rectangle: wl.Signal(*event.SetRectangle),
        destroy: wl.Signal(*ForeignToplevelHandleV1),
    },

    data: ?*anyopaque,

    const wlr_foreign_toplevel_handle_v1_create = abi.bind(fn (manager: *ForeignToplevelManagerV1) callconv(.c) ?*ForeignToplevelHandleV1, c.wlr_foreign_toplevel_handle_v1_create);
    pub fn create(manager: *ForeignToplevelManagerV1) !*ForeignToplevelHandleV1 {
        return wlr_foreign_toplevel_handle_v1_create(manager) orelse error.OutOfMemory;
    }

    const wlr_foreign_toplevel_handle_v1_destroy = abi.bind(fn (toplevel: *ForeignToplevelHandleV1) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_destroy);
    pub const destroy = wlr_foreign_toplevel_handle_v1_destroy;

    const wlr_foreign_toplevel_handle_v1_set_title = abi.bind(fn (toplevel: *ForeignToplevelHandleV1, title: [*:0]const u8) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_set_title);
    pub const setTitle = wlr_foreign_toplevel_handle_v1_set_title;

    const wlr_foreign_toplevel_handle_v1_set_app_id = abi.bind(fn (toplevel: *ForeignToplevelHandleV1, app_id: [*:0]const u8) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_set_app_id);
    pub const setAppId = wlr_foreign_toplevel_handle_v1_set_app_id;

    const wlr_foreign_toplevel_handle_v1_output_enter = abi.bind(fn (toplevel: *ForeignToplevelHandleV1, output: *wlr.Output) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_output_enter);
    pub const outputEnter = wlr_foreign_toplevel_handle_v1_output_enter;

    const wlr_foreign_toplevel_handle_v1_output_leave = abi.bind(fn (toplevel: *ForeignToplevelHandleV1, output: *wlr.Output) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_output_leave);
    pub const outputLeave = wlr_foreign_toplevel_handle_v1_output_leave;

    const wlr_foreign_toplevel_handle_v1_set_maximized = abi.bind(fn (toplevel: *ForeignToplevelHandleV1, maximized: bool) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_set_maximized);
    pub const setMaximized = wlr_foreign_toplevel_handle_v1_set_maximized;

    const wlr_foreign_toplevel_handle_v1_set_minimized = abi.bind(fn (toplevel: *ForeignToplevelHandleV1, minimized: bool) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_set_minimized);
    pub const setMinimized = wlr_foreign_toplevel_handle_v1_set_minimized;

    const wlr_foreign_toplevel_handle_v1_set_activated = abi.bind(fn (toplevel: *ForeignToplevelHandleV1, activated: bool) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_set_activated);
    pub const setActivated = wlr_foreign_toplevel_handle_v1_set_activated;

    const wlr_foreign_toplevel_handle_v1_set_fullscreen = abi.bind(fn (toplevel: *ForeignToplevelHandleV1, fullscreen: bool) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_set_fullscreen);
    pub const setFullscreen = wlr_foreign_toplevel_handle_v1_set_fullscreen;

    const wlr_foreign_toplevel_handle_v1_set_parent = abi.bind(fn (toplevel: *ForeignToplevelHandleV1, parent: ?*ForeignToplevelHandleV1) callconv(.c) void, c.wlr_foreign_toplevel_handle_v1_set_parent);
    pub const setParent = wlr_foreign_toplevel_handle_v1_set_parent;
};

comptime {
    std.debug.assert(@as(u32, @bitCast(ForeignToplevelHandleV1.State{ .maximized = true })) == c.WLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED);
    std.debug.assert(@as(u32, @bitCast(ForeignToplevelHandleV1.State{ .minimized = true })) == c.WLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED);
    std.debug.assert(@as(u32, @bitCast(ForeignToplevelHandleV1.State{ .activated = true })) == c.WLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED);
    std.debug.assert(@as(u32, @bitCast(ForeignToplevelHandleV1.State{ .fullscreen = true })) == c.WLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN);
    abi.assertFields(ForeignToplevelManagerV1, c.wlr_foreign_toplevel_manager_v1);
    abi.assertFields(ForeignToplevelHandleV1, c.wlr_foreign_toplevel_handle_v1);
    abi.assertFields(ForeignToplevelHandleV1.Output, c.wlr_foreign_toplevel_handle_v1_output);
    abi.assertFields(ForeignToplevelHandleV1.event.Maximized, c.wlr_foreign_toplevel_handle_v1_maximized_event);
    abi.assertFields(ForeignToplevelHandleV1.event.Minimized, c.wlr_foreign_toplevel_handle_v1_minimized_event);
    abi.assertFields(ForeignToplevelHandleV1.event.Activated, c.wlr_foreign_toplevel_handle_v1_activated_event);
    abi.assertFields(ForeignToplevelHandleV1.event.Fullscreen, c.wlr_foreign_toplevel_handle_v1_fullscreen_event);
    abi.assertFields(ForeignToplevelHandleV1.event.SetRectangle, c.wlr_foreign_toplevel_handle_v1_set_rectangle_event);
}
