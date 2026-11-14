//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const DataDeviceManager = extern struct {
    global: *wl.Global,
    data_sources: wl.list.Head(wl.DataSource, null),

    events: extern struct {
        destroy: wl.Signal(*DataDeviceManager),
    },

    data: ?*anyopaque,

    const wlr_data_device_manager_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*DataDeviceManager, c.wlr_data_device_manager_create);
    pub fn create(server: *wl.Server) !*DataDeviceManager {
        return wlr_data_device_manager_create(server) orelse error.OutOfMemory;
    }
};

pub const DataOffer = extern struct {
    pub const Type = enum(c_int) {
        selection = c.WLR_DATA_OFFER_SELECTION,
        drag = c.WLR_DATA_OFFER_DRAG,
    };

    resource: *wl.DataOffer,
    source: ?*DataSource,
    type: Type,
    /// wlr.Seat.selection_offers, wlr.Seat.drag_offers
    link: wl.list.Link,

    actions: u32,
    preferred_action: wl.DataDeviceManager.DndAction.Enum,
    in_ask: bool,
};

pub const DataSource = extern struct {
    pub const Impl = extern struct {
        send: *const fn (source: *DataSource, mime_type: [*:0]const u8, fd: i32) callconv(.c) void,
        accept: ?*const fn (source: *DataSource, serial: u32, mime_type: ?[*:0]const u8) callconv(.c) void,
        destroy: ?*const fn (source: *DataSource) callconv(.c) void,
        dnd_drop: ?*const fn (source: *DataSource) callconv(.c) void,
        dnd_finish: ?*const fn (source: *DataSource) callconv(.c) void,
        dnd_action: ?*const fn (source: *DataSource, wl.DataDeviceManager.DndAction.Enum) callconv(.c) void,
    };

    impl: *const Impl,

    mime_types: wl.Array,
    actions: i32,

    accepted: bool,

    current_dnd_action: wl.DataDeviceManager.DndAction.Enum,
    compositor_action: u32,

    events: extern struct {
        destroy: wl.Signal(*DataSource),
    },

    const wlr_data_source_init = abi.bind(fn (source: *DataSource, impl: *const Impl) callconv(.c) void, c.wlr_data_source_init);
    pub const init = wlr_data_source_init;

    const wlr_data_source_send = abi.bind(fn (source: *DataSource, mime_type: [*:0]const u8, fd: i32) callconv(.c) void, c.wlr_data_source_send);
    pub const send = wlr_data_source_send;

    const wlr_data_source_accept = abi.bind(fn (source: *DataSource, serial: u32, mime_type: ?[*:0]const u8) callconv(.c) void, c.wlr_data_source_accept);
    pub const accept = wlr_data_source_accept;

    const wlr_data_source_destroy = abi.bind(fn (source: *DataSource) callconv(.c) void, c.wlr_data_source_destroy);
    pub const destroy = wlr_data_source_destroy;

    const wlr_data_source_dnd_drop = abi.bind(fn (source: *DataSource) callconv(.c) void, c.wlr_data_source_dnd_drop);
    pub const dndDrop = wlr_data_source_dnd_drop;

    const wlr_data_source_dnd_finish = abi.bind(fn (source: *DataSource) callconv(.c) void, c.wlr_data_source_dnd_finish);
    pub const dndFinish = wlr_data_source_dnd_finish;

    const wlr_data_source_dnd_action = abi.bind(fn (source: *DataSource, action: wl.DataDeviceManager.DndAction.Enum) callconv(.c) void, c.wlr_data_source_dnd_action);
    pub const dndAction = wlr_data_source_dnd_action;
};

pub const Drag = extern struct {
    pub const Icon = extern struct {
        drag: *Drag,
        surface: *wlr.Surface,

        events: extern struct {
            destroy: wl.Signal(*Drag.Icon),
        },

        data: ?*anyopaque,
    };

    pub const GrabType = enum(c_int) {
        keyboard = c.WLR_DRAG_GRAB_KEYBOARD,
        keyboard_pointer = c.WLR_DRAG_GRAB_KEYBOARD_POINTER,
        keyboard_touch = c.WLR_DRAG_GRAB_KEYBOARD_TOUCH,
    };

    pub const event = struct {
        pub const Motion = extern struct {
            drag: *Drag,
            time: u32,
            sx: f64,
            sy: f64,
        };

        pub const Drop = extern struct {
            drag: *Drag,
            time: u32,
        };
    };

    grab_type: GrabType,
    keyboard_grab: wlr.Seat.KeyboardGrab,
    pointer_grab: wlr.Seat.PointerGrab,
    touch_grab: wlr.Seat.TouchGrab,

    seat: *wlr.Seat,
    seat_client: *wlr.Seat.Client,
    focus_client: ?*wlr.Seat.Client,

    icon: ?*Drag.Icon,
    focus: ?*wlr.Surface,
    source: ?*DataSource,

    started: bool,
    dropped: bool,
    cancelling: bool,
    grab_touch_id: i32,
    touch_id: i32,

    events: extern struct {
        focus: wl.Signal(*Drag),
        motion: wl.Signal(*event.Motion),
        drop: wl.Signal(*event.Drop),
        destroy: wl.Signal(*Drag),
    },

    data: ?*anyopaque,

    const wlr_drag_create = abi.bind(fn (
        seat_client: *wlr.Seat.Client,
        source: ?*DataSource,
        icon_surface: ?*wlr.Surface,
    ) callconv(.c) ?*Drag, c.wlr_drag_create);
    pub fn create(
        seat_client: *wlr.Seat.Client,
        source: ?*DataSource,
        icon_surface: ?*wlr.Surface,
    ) !*Drag {
        return wlr_drag_create(seat_client, source, icon_surface) orelse error.OutOfMemory;
    }
};

comptime {
    abi.assertFields(DataDeviceManager, c.wlr_data_device_manager);
    abi.assertFields(DataOffer, c.wlr_data_offer);
    abi.assertFields(DataSource, c.wlr_data_source);
    @import("signal.zig").assertSameLayout(DataSource, c.wlr_data_source);
    abi.assertFields(DataSource.Impl, c.wlr_data_source_impl);
    @import("signal.zig").assertSameLayout(DataSource.Impl, c.wlr_data_source_impl);
    abi.assertFields(Drag, c.wlr_drag);
    abi.assertFields(Drag.Icon, c.wlr_drag_icon);
    abi.assertFields(Drag.event.Motion, c.wlr_drag_motion_event);
    abi.assertFields(Drag.event.Drop, c.wlr_drag_drop_event);
}
