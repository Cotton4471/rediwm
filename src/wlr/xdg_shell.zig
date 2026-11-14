//! Typed wlroots header adapter. API shapes adapted from zig-wlroots;
//! see LICENSE.zig-wlroots for its MIT license.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

pub const XdgShell = extern struct {
    global: *wl.Global,
    version: u32,
    clients: wl.list.Head(XdgClient, .link),
    popup_grabs: wl.list.Head(XdgPopupGrab, .link),
    ping_timeout: u32,

    events: extern struct {
        new_surface: wl.Signal(*wlr.XdgSurface),
        new_toplevel: wl.Signal(*wlr.XdgToplevel),
        new_popup: wl.Signal(*wlr.XdgPopup),
        destroy: wl.Signal(*wlr.XdgShell),
    },

    data: ?*anyopaque,

    const wlr_xdg_shell_create = abi.bind(fn (server: *wl.Server, version: u32) callconv(.c) ?*wlr.XdgShell, c.wlr_xdg_shell_create);
    pub fn create(server: *wl.Server, version: u32) !*wlr.XdgShell {
        return wlr_xdg_shell_create(server, version) orelse error.OutOfMemory;
    }
};

pub const XdgClient = extern struct {
    shell: *wlr.XdgShell,
    resource: *xdg.WmBase,
    client: *wl.Client,
    surfaces: wl.list.Head(XdgSurface, .link),
    /// XdgShell.clients
    link: wl.list.Link,

    ping_serial: u32,
    ping_timer: *wl.EventSource,
};

pub const XdgPositioner = extern struct {
    pub const Rules = extern struct {
        anchor_rect: wlr.Box,
        anchor: xdg.Positioner.Anchor,
        gravity: xdg.Positioner.Gravity,
        constraint_adjustment: xdg.Positioner.ConstraintAdjustment,

        reactive: bool,

        has_parent_configure_serial: bool,
        parent_configure_serial: u32,

        size: extern struct {
            width: i32,
            height: i32,
        },
        parent_size: extern struct {
            width: i32,
            height: i32,
        },

        offset: extern struct {
            x: i32,
            y: i32,
        },

        const wlr_xdg_positioner_rules_get_geometry = abi.bind(fn (rules: *const Rules, box: *wlr.Box) callconv(.c) void, c.wlr_xdg_positioner_rules_get_geometry);
        pub const getGeometry = wlr_xdg_positioner_rules_get_geometry;

        const wlr_xdg_positioner_rules_unconstrain_box = abi.bind(fn (rules: *const Rules, constraint: *const wlr.Box, box: *wlr.Box) callconv(.c) void, c.wlr_xdg_positioner_rules_unconstrain_box);
        pub const unconstrainBox = wlr_xdg_positioner_rules_unconstrain_box;
    };

    resource: *xdg.Positioner,
    rules: Rules,

    const wlr_xdg_positioner_from_resource = abi.bind(fn (resource: *xdg.Positioner) callconv(.c) *XdgPositioner, c.wlr_xdg_positioner_from_resource);
    pub const fromResource = wlr_xdg_positioner_from_resource;
};

pub const XdgPopupGrab = extern struct {
    client: *wl.Client,

    pointer_grab: wlr.Seat.PointerGrab,
    keyboard_grab: wlr.Seat.KeyboardGrab,
    touch_grab: wlr.Seat.TouchGrab,
    seat: *wlr.Seat,

    popups: wl.list.Head(XdgPopup, .grab_link),
    /// XdgShell.popup_grabs
    link: wl.list.Link,
};

pub const XdgPopup = extern struct {
    pub const State = extern struct {
        geometry: wlr.Box,
        reactive: bool,
    };

    pub const Configure = extern struct {
        fields: u32,
        geometry: wlr.Box,
        rules: XdgPositioner.Rules,

        reposition_token: u32,
    };

    base: *wlr.XdgSurface,
    link: wl.list.Link,

    resource: *xdg.Popup,
    parent: ?*wlr.Surface,
    seat: ?*wlr.Seat,

    scheduled: Configure,

    current: State,
    pending: State,

    events: extern struct {
        destroy: wl.Signal(void),
        reposition: wl.Signal(void),
    },

    /// Grab.popups
    grab_link: wl.list.Link,

    const wlr_xdg_popup_from_resource = abi.bind(fn (resource: *xdg.Popup) callconv(.c) ?*wlr.XdgPopup, c.wlr_xdg_popup_from_resource);
    pub const fromResource = wlr_xdg_popup_from_resource;

    const wlr_xdg_popup_destroy = abi.bind(fn (popup: *wlr.XdgPopup) callconv(.c) void, c.wlr_xdg_popup_destroy);
    pub const destroy = wlr_xdg_popup_destroy;

    const wlr_xdg_popup_get_position = abi.bind(fn (popup: *XdgPopup, popup_sx: *f64, popup_sy: *f64) callconv(.c) void, c.wlr_xdg_popup_get_position);
    pub const getPosition = wlr_xdg_popup_get_position;

    const wlr_xdg_popup_get_toplevel_coords = abi.bind(fn (popup: *XdgPopup, popup_sx: c_int, popup_sy: c_int, toplevel_sx: *c_int, toplevel_sy: *c_int) callconv(.c) void, c.wlr_xdg_popup_get_toplevel_coords);
    pub const getToplevelCoords = wlr_xdg_popup_get_toplevel_coords;

    const wlr_xdg_popup_unconstrain_from_box = abi.bind(fn (popup: *XdgPopup, toplevel_space_box: *const wlr.Box) callconv(.c) void, c.wlr_xdg_popup_unconstrain_from_box);
    pub const unconstrainFromBox = wlr_xdg_popup_unconstrain_from_box;
};

pub const XdgToplevel = extern struct {
    pub const State = extern struct {
        maximized: bool,
        fullscreen: bool,
        resizing: bool,
        activated: bool,
        suspended: bool,
        tiled: wlr.Edges,
        constrained: wlr.Edges,
        width: i32,
        height: i32,
        max_width: i32,
        max_height: i32,
        min_width: i32,
        min_height: i32,
    };

    pub const WmCapabilities = packed struct(u32) {
        window_menu: bool = false,
        maximize: bool = false,
        fullscreen: bool = false,
        minimize: bool = false,
        _: u28 = 0,
    };

    pub const Configure = extern struct {
        pub const Fields = packed struct(u32) {
            bounds: bool = false,
            wm_capabilities: bool = false,
            _: u30 = 0,
        };

        fields: Fields,
        maximized: bool,
        fullscreen: bool,
        resizing: bool,
        activated: bool,
        suspended: bool,
        tiled: wlr.Edges,
        constrained: wlr.Edges,
        width: i32,
        height: i32,
        bounds: extern struct {
            width: i32,
            height: i32,
        },
        wm_capabilities: WmCapabilities,
    };

    pub const Requested = extern struct {
        maximized: bool,
        minimized: bool,
        fullscreen: bool,

        fullscreen_output: ?*wlr.Output,

        WLR_PRIVATE: @FieldType(c.wlr_xdg_toplevel_requested, "WLR_PRIVATE"),
    };

    pub const event = struct {
        pub const Move = extern struct {
            toplevel: *wlr.XdgToplevel,
            seat: *wlr.Seat.Client,
            serial: u32,
        };

        pub const Resize = extern struct {
            toplevel: *wlr.XdgToplevel,
            seat: *wlr.Seat.Client,
            serial: u32,
            edges: wlr.Edges,
        };

        pub const ShowWindowMenu = extern struct {
            toplevel: *wlr.XdgToplevel,
            seat: *wlr.Seat.Client,
            serial: u32,
            x: i32,
            y: i32,
        };
    };

    resource: *xdg.Toplevel,
    base: *wlr.XdgSurface,
    parent: ?*wlr.XdgToplevel,

    current: State,
    pending: State,
    scheduled: Configure,
    requested: Requested,

    title: ?[*:0]u8,
    app_id: ?[*:0]u8,
    events: extern struct {
        destroy: wl.Signal(void),
        request_maximize: wl.Signal(void),
        request_fullscreen: wl.Signal(void),
        request_minimize: wl.Signal(void),
        request_move: wl.Signal(*event.Move),
        request_resize: wl.Signal(*event.Resize),
        request_show_window_menu: wl.Signal(*event.ShowWindowMenu),
        set_parent: wl.Signal(void),
        set_title: wl.Signal(void),
        set_app_id: wl.Signal(void),
    },

    const wlr_xdg_toplevel_from_resource = abi.bind(fn (resource: *xdg.Toplevel) callconv(.c) ?*wlr.XdgToplevel, c.wlr_xdg_toplevel_from_resource);
    pub const fromResource = wlr_xdg_toplevel_from_resource;

    const wlr_xdg_toplevel_configure = abi.bind(fn (toplevel: *wlr.XdgToplevel, configure: *const Configure) callconv(.c) u32, c.wlr_xdg_toplevel_configure);
    pub const configure = wlr_xdg_toplevel_configure;

    const wlr_xdg_toplevel_set_size = abi.bind(fn (toplevel: *wlr.XdgToplevel, width: i32, height: i32) callconv(.c) u32, c.wlr_xdg_toplevel_set_size);
    pub const setSize = wlr_xdg_toplevel_set_size;

    const wlr_xdg_toplevel_set_activated = abi.bind(fn (toplevel: *wlr.XdgToplevel, activated: bool) callconv(.c) u32, c.wlr_xdg_toplevel_set_activated);
    pub const setActivated = wlr_xdg_toplevel_set_activated;

    const wlr_xdg_toplevel_set_maximized = abi.bind(fn (toplevel: *wlr.XdgToplevel, maximized: bool) callconv(.c) u32, c.wlr_xdg_toplevel_set_maximized);
    pub const setMaximized = wlr_xdg_toplevel_set_maximized;

    const wlr_xdg_toplevel_set_fullscreen = abi.bind(fn (toplevel: *wlr.XdgToplevel, fullscreen: bool) callconv(.c) u32, c.wlr_xdg_toplevel_set_fullscreen);
    pub const setFullscreen = wlr_xdg_toplevel_set_fullscreen;

    const wlr_xdg_toplevel_set_resizing = abi.bind(fn (toplevel: *wlr.XdgToplevel, resizing: bool) callconv(.c) u32, c.wlr_xdg_toplevel_set_resizing);
    pub const setResizing = wlr_xdg_toplevel_set_resizing;

    const wlr_xdg_toplevel_set_tiled = abi.bind(fn (toplevel: *wlr.XdgToplevel, tiled_edges: u32) callconv(.c) u32, c.wlr_xdg_toplevel_set_tiled);
    pub fn setTiled(toplevel: *wlr.XdgToplevel, tiled_edges: wlr.Edges) u32 {
        return wlr_xdg_toplevel_set_tiled(toplevel, @bitCast(tiled_edges));
    }

    const wlr_xdg_toplevel_set_constrained = abi.bind(fn (toplevel: *wlr.XdgToplevel, constrained_edges: u32) callconv(.c) u32, c.wlr_xdg_toplevel_set_constrained);
    pub fn setConstrained(toplevel: *wlr.XdgToplevel, constrained_edges: wlr.Edges) u32 {
        return wlr_xdg_toplevel_set_constrained(toplevel, @bitCast(constrained_edges));
    }

    const wlr_xdg_toplevel_set_bounds = abi.bind(fn (toplevel: *wlr.XdgToplevel, width: i32, height: i32) callconv(.c) u32, c.wlr_xdg_toplevel_set_bounds);
    pub const setBounds = wlr_xdg_toplevel_set_bounds;

    const wlr_xdg_toplevel_set_wm_capabilities = abi.bind(fn (toplevel: *wlr.XdgToplevel, caps: WmCapabilities) callconv(.c) u32, c.wlr_xdg_toplevel_set_wm_capabilities);
    pub const setWmCapabilities = wlr_xdg_toplevel_set_wm_capabilities;

    const wlr_xdg_toplevel_set_suspended = abi.bind(fn (toplevel: *wlr.XdgToplevel, suspended: bool) callconv(.c) u32, c.wlr_xdg_toplevel_set_suspended);
    pub const setSuspended = wlr_xdg_toplevel_set_suspended;

    const wlr_xdg_toplevel_send_close = abi.bind(fn (toplevel: *wlr.XdgToplevel) callconv(.c) void, c.wlr_xdg_toplevel_send_close);
    pub const sendClose = wlr_xdg_toplevel_send_close;

    const wlr_xdg_toplevel_set_parent = abi.bind(fn (toplevel: *wlr.XdgToplevel, parent: ?*wlr.XdgToplevel) callconv(.c) bool, c.wlr_xdg_toplevel_set_parent);
    pub const setParent = wlr_xdg_toplevel_set_parent;
};

pub const XdgSurface = extern struct {
    pub const Role = enum(c_int) {
        none = c.WLR_XDG_SURFACE_ROLE_NONE,
        toplevel = c.WLR_XDG_SURFACE_ROLE_TOPLEVEL,
        popup = c.WLR_XDG_SURFACE_ROLE_POPUP,
    };

    pub const State = extern struct {
        committed: packed struct(u32) {
            geometry: bool = false,
            _: u31 = 0,
        },

        geometry: wlr.Box,

        configure_serial: u32,
    };

    pub const Configure = extern struct {
        surface: *wlr.XdgSurface,
        /// XdgSurface.configure_list
        link: wl.list.Link,
        serial: u32,

        role: extern union {
            toplevel: *wlr.XdgToplevel.Configure,
            popup: *wlr.XdgPopup.Configure,
        },
    };

    client: *wlr.XdgClient,
    resource: *xdg.Surface,
    surface: *wlr.Surface,
    /// XdgClient.surfaces
    link: wl.list.Link,

    role: Role,
    role_resource: ?*wl.Resource,
    role_data: extern union {
        toplevel: ?*wlr.XdgToplevel,
        popup: ?*wlr.XdgPopup,
    },

    popups: wl.list.Head(XdgPopup, .link),

    configured: bool,
    configure_idle: ?*wl.EventSource,
    scheduled_serial: u32,
    configure_list: wl.list.Head(XdgSurface.Configure, .link),

    current: State,
    pending: State,

    initialized: bool,
    initial_commit: bool,

    geometry: wlr.Box,

    events: extern struct {
        destroy: wl.Signal(void),
        ping_timeout: wl.Signal(void),
        new_popup: wl.Signal(*wlr.XdgPopup),
        configure: wl.Signal(*wlr.XdgSurface.Configure),
        ack_configure: wl.Signal(*wlr.XdgSurface.Configure),
    },

    data: ?*anyopaque,

    const wlr_xdg_surface_from_resource = abi.bind(fn (resource: *xdg.Surface) callconv(.c) ?*wlr.XdgSurface, c.wlr_xdg_surface_from_resource);
    pub const fromResource = wlr_xdg_surface_from_resource;

    const wlr_xdg_surface_ping = abi.bind(fn (surface: *wlr.XdgSurface) callconv(.c) void, c.wlr_xdg_surface_ping);
    pub const ping = wlr_xdg_surface_ping;

    const wlr_xdg_surface_surface_at = abi.bind(fn (surface: *wlr.XdgSurface, sx: f64, sy: f64, sub_x: *f64, sub_y: *f64) callconv(.c) ?*wlr.Surface, c.wlr_xdg_surface_surface_at);
    pub const surfaceAt = wlr_xdg_surface_surface_at;

    const wlr_xdg_surface_popup_surface_at = abi.bind(fn (surface: *wlr.XdgSurface, sx: f64, sy: f64, sub_x: *f64, sub_y: *f64) callconv(.c) ?*wlr.Surface, c.wlr_xdg_surface_popup_surface_at);
    pub const popupSurfaceAt = wlr_xdg_surface_popup_surface_at;

    const wlr_xdg_surface_try_from_wlr_surface = abi.bind(fn (surface: *wlr.Surface) callconv(.c) ?*wlr.XdgSurface, c.wlr_xdg_surface_try_from_wlr_surface);
    pub const tryFromWlrSurface = wlr_xdg_surface_try_from_wlr_surface;

    const wlr_xdg_surface_for_each_surface = abi.bind(fn (
        surface: *wlr.XdgSurface,
        iterator: *const fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
    ) callconv(.c) void, c.wlr_xdg_surface_for_each_surface);
    pub inline fn forEachSurface(
        surface: *wlr.XdgSurface,
        comptime T: type,
        comptime iterator: fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: T) void,
        data: T,
    ) void {
        wlr_xdg_surface_for_each_surface(
            surface,
            struct {
                fn wrapper(s: *wlr.Surface, sx: c_int, sy: c_int, d: ?*anyopaque) callconv(.c) void {
                    iterator(s, sx, sy, @ptrCast(@alignCast(d)));
                }
            }.wrapper,
            data,
        );
    }

    const wlr_xdg_surface_for_each_popup_surface = abi.bind(fn (
        surface: *wlr.XdgSurface,
        iterator: *const fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
    ) callconv(.c) void, c.wlr_xdg_surface_for_each_popup_surface);
    pub inline fn forEachPopupSurface(
        surface: *wlr.XdgSurface,
        comptime T: type,
        comptime iterator: fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: T) void,
        data: T,
    ) void {
        wlr_xdg_surface_for_each_popup_surface(
            surface,
            struct {
                fn wrapper(s: *wlr.Surface, sx: c_int, sy: c_int, d: ?*anyopaque) callconv(.c) void {
                    iterator(s, sx, sy, @ptrCast(@alignCast(d)));
                }
            }.wrapper,
            data,
        );
    }

    const wlr_xdg_surface_schedule_configure = abi.bind(fn (surface: *wlr.XdgSurface) callconv(.c) u32, c.wlr_xdg_surface_schedule_configure);
    pub const scheduleConfigure = wlr_xdg_surface_schedule_configure;
};

/// translate-c gives anonymous unions generated field names. Match these by
/// position and validate each alternative instead of baking that name in.
fn assertWithAnonymousUnion(comptime T: type, comptime C: type) void {
    const real = @typeInfo(C).@"struct";
    for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, 0..) |name, FieldType, index| {
        const actual_name = real.field_names[index];
        const Actual = real.field_types[index];
        if (@offsetOf(T, name) != @offsetOf(C, actual_name))
            @compileError("XDG field offset changed: " ++ @typeName(T) ++ "." ++ name);
        abi.assertValue(FieldType, Actual);
        if (@typeInfo(FieldType) == .@"union") {
            const ours = @typeInfo(FieldType).@"union".field_types;
            const theirs = @typeInfo(Actual).@"union".field_types;
            if (ours.len != theirs.len) @compileError("XDG union alternatives changed");
            for (ours, theirs) |Ours, Theirs| abi.assertValue(Ours, Theirs);
        } else if (!@import("std").mem.eql(u8, name, actual_name)) {
            @compileError("XDG field changed: " ++ name);
        }
    }
}

comptime {
    @setEvalBranchQuota(10000);
    abi.assertFields(XdgShell, c.wlr_xdg_shell);
    abi.assertLayout(XdgClient, c.wlr_xdg_client);
    abi.assertLayout(XdgPositioner, c.wlr_xdg_positioner);
    abi.assertLayout(XdgPositioner.Rules, c.wlr_xdg_positioner_rules);
    abi.assertFields(XdgPopupGrab, c.wlr_xdg_popup_grab);
    abi.assertFields(XdgPopup, c.wlr_xdg_popup);
    abi.assertLayout(XdgPopup.State, c.wlr_xdg_popup_state);
    abi.assertLayout(XdgPopup.Configure, c.wlr_xdg_popup_configure);
    abi.assertFields(XdgToplevel, c.wlr_xdg_toplevel);
    abi.assertLayout(XdgToplevel.State, c.wlr_xdg_toplevel_state);
    abi.assertLayout(XdgToplevel.Configure, c.struct_wlr_xdg_toplevel_configure);
    abi.assertLayout(XdgToplevel.Requested, c.wlr_xdg_toplevel_requested);
    abi.assertLayout(XdgToplevel.event.Move, c.wlr_xdg_toplevel_move_event);
    abi.assertLayout(XdgToplevel.event.Resize, c.wlr_xdg_toplevel_resize_event);
    abi.assertLayout(XdgToplevel.event.ShowWindowMenu, c.wlr_xdg_toplevel_show_window_menu_event);
    assertWithAnonymousUnion(XdgSurface, c.wlr_xdg_surface);
    assertWithAnonymousUnion(XdgSurface.Configure, c.wlr_xdg_surface_configure);
    @import("signal.zig").assertSameLayout(XdgSurface.Configure, c.wlr_xdg_surface_configure);
    abi.assertLayout(XdgSurface.State, c.wlr_xdg_surface_state);
}
