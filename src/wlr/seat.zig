//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const posix = @import("std").posix;

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const SerialRange = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_serial_range);
    }

    min_incl: u32,
    max_incl: u32,
};

pub const SerialRingset = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_serial_ringset);
    }

    data: [c.WLR_SERIAL_RINGSET_SIZE]SerialRange,
    end: c_int,
    count: c_int,
};

pub const TouchPoint = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_touch_point);
    }

    touch_id: i32,
    surface: ?*wlr.Surface,
    client: *wlr.Seat.Client,

    focus_surface: ?*wlr.Surface,
    focus_client: ?*wlr.Seat.Client,
    sx: f64,
    sy: f64,

    events: extern struct {
        destroy: wl.Signal(*TouchPoint),
    },

    /// Seat.TouchState.touch_points
    link: wl.list.Link,

    WLR_PRIVATE: @FieldType(c.wlr_touch_point, "WLR_PRIVATE"),
};

pub const Seat = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_seat);
    }

    pub const Client = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_seat_client);
        }

        client: *wl.Client,
        seat: *Seat,
        /// Seat.clients
        link: wl.list.Link,

        resources: wl.list.Head(wl.Seat, null),
        pointers: wl.list.Head(wl.Pointer, null),
        keyboards: wl.list.Head(wl.Keyboard, null),
        touches: wl.list.Head(wl.Touch, null),
        data_devices: wl.list.Head(wl.DataDevice, null),

        events: extern struct {
            destroy: wl.Signal(*Seat.Client),
        },

        serials: SerialRingset,
        needs_touch_frame: bool,

        value120: extern struct {
            acc_discrete: [2]i32,
            last_discrete: [2]i32,
            acc_axis: [2]f64,
        },

        const wlr_seat_client_next_serial = abi.bind(fn (client: *Client) callconv(.c) u32, c.wlr_seat_client_next_serial);
        pub const nextSerial = wlr_seat_client_next_serial;

        const wlr_seat_client_validate_event_serial = abi.bind(fn (client: *Client, serial: u32) callconv(.c) bool, c.wlr_seat_client_validate_event_serial);
        pub const validateEventSerial = wlr_seat_client_validate_event_serial;

        const wlr_seat_client_from_resource = abi.bind(fn (seat: *wl.Seat) callconv(.c) ?*Client, c.wlr_seat_client_from_resource);
        pub const fromWlSeat = wlr_seat_client_from_resource;

        const wlr_seat_client_from_pointer_resource = abi.bind(fn (pointer: *wl.Pointer) callconv(.c) ?*Client, c.wlr_seat_client_from_pointer_resource);
        pub const fromWlPointer = wlr_seat_client_from_pointer_resource;
    };

    pub const PointerGrab = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_seat_pointer_grab);
        }

        pub const Interface = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_grab_interface);
            }

            enter: *const fn (
                grab: *PointerGrab,
                surface: *wlr.Surface,
                sx: f64,
                sy: f64,
            ) callconv(.c) void,
            clear_focus: *const fn (grab: *PointerGrab) callconv(.c) void,
            motion: *const fn (grab: *PointerGrab, time_msec: u32, sx: f64, sy: f64) callconv(.c) void,
            button: *const fn (
                grab: *PointerGrab,
                time_msec: u32,
                button: u32,
                state: wl.Pointer.ButtonState,
            ) callconv(.c) u32,
            axis: *const fn (
                grab: *PointerGrab,
                time_msec: u32,
                orientation: wl.Pointer.Axis,
                value: f64,
                value_discrete: i32,
                source: wl.Pointer.AxisSource,
                relative_direction: wl.Pointer.AxisRelativeDirection,
            ) callconv(.c) void,
            frame: ?*const fn (grab: *PointerGrab) callconv(.c) void,
            cancel: ?*const fn (grab: *PointerGrab) callconv(.c) void,
        };

        interface: *const Interface,
        seat: *Seat,
        data: ?*anyopaque,
    };

    pub const KeyboardGrab = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_seat_keyboard_grab);
        }

        pub const Interface = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_keyboard_grab_interface);
            }

            enter: *const fn (
                grab: *KeyboardGrab,
                surface: *wlr.Surface,
                keycodes: ?[*]const u32,
                num_keycodes: usize,
                modifiers: ?*const wlr.Keyboard.Modifiers,
            ) callconv(.c) void,
            clear_focus: *const fn (grab: *KeyboardGrab) callconv(.c) void,
            key: *const fn (grab: *KeyboardGrab, time_msec: u32, key: u32, state: u32) callconv(.c) void,
            modifiers: *const fn (grab: *KeyboardGrab, modifiers: ?*const wlr.Keyboard.Modifiers) callconv(.c) void,
            cancel: ?*const fn (grab: *KeyboardGrab) callconv(.c) void,
        };

        interface: *const Interface,
        seat: *Seat,
        data: ?*anyopaque,
    };

    pub const TouchGrab = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_seat_touch_grab);
        }

        pub const Interface = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_touch_grab_interface);
            }

            down: *const fn (grab: *TouchGrab, time_msec: u32, point: *TouchPoint) callconv(.c) u32,
            up: *const fn (grab: *TouchGrab, time_msec: u32, point: *TouchPoint) callconv(.c) u32,
            motion: *const fn (grab: *TouchGrab, time_msec: u32, point: *TouchPoint) callconv(.c) void,
            enter: *const fn (grab: *TouchGrab, time_msec: u32, point: *TouchPoint) callconv(.c) void,
            frame: ?*const fn (grab: *TouchGrab) callconv(.c) void,
            cancel: ?*const fn (grab: *TouchGrab) callconv(.c) void,
            wl_cancel: ?*const fn (grab: *TouchGrab, seat_client: *wlr.Seat.Client) callconv(.c) void,
            clear_focus: ?*const fn (grab: *TouchGrab, time_msec: u32, point: *TouchPoint) callconv(.c) void,
        };

        interface: *const Interface,
        seat: *Seat,
        data: ?*anyopaque,
    };

    pub const PointerState = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_seat_pointer_state);
        }

        pub const Button = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_seat_pointer_button);
            }

            button: u32,
            n_pressed: usize,
        };

        seat: *Seat,
        focused_client: ?*Seat.Client,
        focused_surface: ?*wlr.Surface,
        sx: f64,
        sy: f64,

        grab: *PointerGrab,
        default_grab: *PointerGrab,

        sent_axis_source: bool,
        cached_axis_source: wl.Pointer.AxisSource,

        buttons: [16]Button,
        button_count: usize,
        grab_button: u32,
        grab_serial: u32,
        grab_time: u32,

        events: extern struct {
            focus_change: wl.Signal(*event.PointerFocusChange),
        },

        WLR_PRIVATE: @FieldType(c.wlr_seat_pointer_state, "WLR_PRIVATE"),
    };

    pub const KeyboardState = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_seat_keyboard_state);
        }

        seat: *Seat,
        keyboard: ?*wlr.Keyboard,

        focused_client: ?*Seat.Client,
        focused_surface: ?*wlr.Surface,

        grab: *KeyboardGrab,
        default_grab: *KeyboardGrab,

        events: extern struct {
            focus_change: wl.Signal(*event.KeyboardFocusChange),
        },

        WLR_PRIVATE: @FieldType(c.wlr_seat_keyboard_state, "WLR_PRIVATE"),
    };

    pub const TouchState = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_seat_touch_state);
        }

        seat: *Seat,
        touch_points: wl.list.Head(TouchPoint, .link),

        grab_serial: u32,
        grab_id: u32,

        grab: *TouchGrab,
        default_grab: *TouchGrab,
    };

    pub const event = struct {
        pub const PointerFocusChange = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_seat_pointer_focus_change_event);
            }

            seat: *Seat,
            old_surface: ?*wlr.Surface,
            new_surface: ?*wlr.Surface,
            sx: f64,
            sy: f64,
        };

        pub const KeyboardFocusChange = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_seat_keyboard_focus_change_event);
            }

            seat: *Seat,
            old_surface: ?*wlr.Surface,
            new_surface: ?*wlr.Surface,
        };

        pub const RequestSetCursor = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_seat_pointer_request_set_cursor_event);
            }

            seat_client: *Seat.Client,
            surface: ?*wlr.Surface,
            serial: u32,
            hotspot_x: i32,
            hotspot_y: i32,
        };

        pub const RequestSetSelection = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_seat_request_set_selection_event);
            }

            source: ?*wlr.DataSource,
            serial: u32,
        };

        pub const RequestSetPrimarySelection = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_seat_request_set_primary_selection_event);
            }

            source: ?*wlr.PrimarySelectionSource,
            serial: u32,
        };

        pub const RequestStartDrag = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_seat_request_start_drag_event);
            }

            drag: *wlr.Drag,
            origin: *wlr.Surface,
            serial: u32,
        };
    };

    global: *wl.Global,
    display: *wl.Server,
    clients: wl.list.Head(Seat.Client, .link),

    name: [*:0]u8,

    capabilities: u32,
    accumulated_capabilities: u32,

    selection_source: ?*wlr.DataSource,
    selection_serial: u32,
    /// wlr.DataOffer.link
    selection_offers: wl.list.Head(wlr.DataOffer, .link),

    primary_selection_source: ?*wlr.PrimarySelectionSource,
    primary_selection_serial: u32,

    drag: ?*wlr.Drag,
    drag_source: ?*wlr.DataSource,
    drag_serial: u32,
    /// wlr.DataOffer.link
    drag_offers: wl.list.Head(wlr.DataOffer, .link),

    pointer_state: PointerState,
    keyboard_state: KeyboardState,
    touch_state: TouchState,

    events: extern struct {
        pointer_grab_begin: wl.Signal(*PointerGrab),
        pointer_grab_end: wl.Signal(*PointerGrab),

        keyboard_grab_begin: wl.Signal(*KeyboardGrab),
        keyboard_grab_end: wl.Signal(*KeyboardGrab),

        touch_grab_begin: wl.Signal(*TouchGrab),
        touch_grab_end: wl.Signal(*TouchGrab),

        request_set_cursor: wl.Signal(*event.RequestSetCursor),

        request_set_selection: wl.Signal(*event.RequestSetSelection),
        set_selection: wl.Signal(*wlr.Seat),

        request_set_primary_selection: wl.Signal(*event.RequestSetPrimarySelection),
        set_primary_selection: wl.Signal(*wlr.Seat),

        request_start_drag: wl.Signal(*event.RequestStartDrag),
        start_drag: wl.Signal(*wlr.Drag),

        destroy: wl.Signal(*wlr.Seat),
    },

    data: ?*anyopaque,

    WLR_PRIVATE: @FieldType(c.wlr_seat, "WLR_PRIVATE"),

    const wlr_seat_create = abi.bind(fn (server: *wl.Server, name: [*:0]const u8) callconv(.c) ?*Seat, c.wlr_seat_create);
    pub fn create(server: *wl.Server, name: [*:0]const u8) !*Seat {
        return wlr_seat_create(server, name) orelse error.OutOfMemory;
    }

    const wlr_seat_destroy = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_destroy);
    pub const destroy = wlr_seat_destroy;

    const wlr_seat_client_for_wl_client = abi.bind(fn (seat: *Seat, wl_client: *wl.Client) callconv(.c) ?*Seat.Client, c.wlr_seat_client_for_wl_client);
    pub const clientForWlClient = wlr_seat_client_for_wl_client;

    const wlr_seat_set_capabilities = abi.bind(fn (seat: *Seat, capabilities: u32) callconv(.c) void, c.wlr_seat_set_capabilities);
    pub inline fn setCapabilities(seat: *Seat, capabilities: wl.Seat.Capability) void {
        wlr_seat_set_capabilities(seat, @as(u32, @bitCast(capabilities)));
    }

    const wlr_seat_set_name = abi.bind(fn (seat: *Seat, name: [*:0]const u8) callconv(.c) void, c.wlr_seat_set_name);
    pub const setName = wlr_seat_set_name;

    const wlr_seat_pointer_surface_has_focus = abi.bind(fn (seat: *Seat, surface: *wlr.Surface) callconv(.c) bool, c.wlr_seat_pointer_surface_has_focus);
    pub const pointerSurfaceHasFocus = wlr_seat_pointer_surface_has_focus;

    const wlr_seat_pointer_enter = abi.bind(fn (seat: *Seat, surface: ?*wlr.Surface, sx: f64, sy: f64) callconv(.c) void, c.wlr_seat_pointer_enter);
    pub const pointerEnter = wlr_seat_pointer_enter;

    const wlr_seat_pointer_clear_focus = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_pointer_clear_focus);
    pub const pointerClearFocus = wlr_seat_pointer_clear_focus;

    const wlr_seat_pointer_send_motion = abi.bind(fn (seat: *Seat, time_msec: u32, sx: f64, sy: f64) callconv(.c) void, c.wlr_seat_pointer_send_motion);
    pub const pointerSendMotion = wlr_seat_pointer_send_motion;

    const wlr_seat_pointer_send_button = abi.bind(fn (seat: *Seat, time_msec: u32, button: u32, state: wl.Pointer.ButtonState) callconv(.c) u32, c.wlr_seat_pointer_send_button);
    pub const pointerSendButton = wlr_seat_pointer_send_button;

    const wlr_seat_pointer_send_axis = abi.bind(fn (
        seat: *Seat,
        time_msec: u32,
        orientation: wl.Pointer.Axis,
        value: f64,
        value_discrete: i32,
        source: wl.Pointer.AxisSource,
        relative_direction: wl.Pointer.AxisRelativeDirection,
    ) callconv(.c) void, c.wlr_seat_pointer_send_axis);
    pub const pointerSendAxis = wlr_seat_pointer_send_axis;

    const wlr_seat_pointer_send_frame = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_pointer_send_frame);
    pub const pointerSendFrame = wlr_seat_pointer_send_frame;

    const wlr_seat_pointer_notify_enter = abi.bind(fn (seat: *Seat, surface: *wlr.Surface, sx: f64, sy: f64) callconv(.c) void, c.wlr_seat_pointer_notify_enter);
    pub const pointerNotifyEnter = wlr_seat_pointer_notify_enter;

    const wlr_seat_pointer_notify_clear_focus = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_pointer_notify_clear_focus);
    pub const pointerNotifyClearFocus = wlr_seat_pointer_notify_clear_focus;

    const wlr_seat_pointer_warp = abi.bind(fn (seat: *Seat, sx: f64, sy: f64) callconv(.c) void, c.wlr_seat_pointer_warp);
    pub const pointerWarp = wlr_seat_pointer_warp;

    const wlr_seat_pointer_notify_motion = abi.bind(fn (seat: *Seat, time_msec: u32, sx: f64, sy: f64) callconv(.c) void, c.wlr_seat_pointer_notify_motion);
    pub const pointerNotifyMotion = wlr_seat_pointer_notify_motion;

    const wlr_seat_pointer_notify_button = abi.bind(fn (seat: *Seat, time_msec: u32, button: u32, state: wl.Pointer.ButtonState) callconv(.c) u32, c.wlr_seat_pointer_notify_button);
    pub const pointerNotifyButton = wlr_seat_pointer_notify_button;

    const wlr_seat_pointer_notify_axis = abi.bind(fn (
        seat: *Seat,
        time_msec: u32,
        orientation: wl.Pointer.Axis,
        value: f64,
        value_discrete: i32,
        source: wl.Pointer.AxisSource,
        relative_direction: wl.Pointer.AxisRelativeDirection,
    ) callconv(.c) void, c.wlr_seat_pointer_notify_axis);
    pub const pointerNotifyAxis = wlr_seat_pointer_notify_axis;

    const wlr_seat_pointer_notify_frame = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_pointer_notify_frame);
    pub const pointerNotifyFrame = wlr_seat_pointer_notify_frame;

    const wlr_seat_pointer_start_grab = abi.bind(fn (seat: *Seat, grab: ?*PointerGrab) callconv(.c) void, c.wlr_seat_pointer_start_grab);
    pub const pointerStartGrab = wlr_seat_pointer_start_grab;

    const wlr_seat_pointer_end_grab = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_pointer_end_grab);
    pub const pointerEndGrab = wlr_seat_pointer_end_grab;

    const wlr_seat_pointer_has_grab = abi.bind(fn (seat: *Seat) callconv(.c) bool, c.wlr_seat_pointer_has_grab);
    pub const pointerHasGrab = wlr_seat_pointer_has_grab;

    const wlr_seat_set_keyboard = abi.bind(fn (seat: *Seat, keyboard: ?*wlr.Keyboard) callconv(.c) void, c.wlr_seat_set_keyboard);
    pub const setKeyboard = wlr_seat_set_keyboard;

    const wlr_seat_get_keyboard = abi.bind(fn (seat: *Seat) callconv(.c) ?*wlr.Keyboard, c.wlr_seat_get_keyboard);
    pub const getKeyboard = wlr_seat_get_keyboard;

    const wlr_seat_keyboard_send_key = abi.bind(fn (seat: *Seat, time_msec: u32, key: u32, state: u32) callconv(.c) void, c.wlr_seat_keyboard_send_key);
    pub const keyboardSendKey = wlr_seat_keyboard_send_key;

    const wlr_seat_keyboard_send_modifiers = abi.bind(fn (seat: *Seat, modifiers: ?*const wlr.Keyboard.Modifiers) callconv(.c) void, c.wlr_seat_keyboard_send_modifiers);
    pub const keyboardSendModifiers = wlr_seat_keyboard_send_modifiers;

    const wlr_seat_keyboard_enter = abi.bind(fn (seat: *Seat, surface: ?*wlr.Surface, keycodes: ?[*]const u32, num_keycodes: usize, modifiers: ?*const wlr.Keyboard.Modifiers) callconv(.c) void, c.wlr_seat_keyboard_enter);
    pub fn keyboardEnter(seat: *Seat, surface: ?*wlr.Surface, keycodes: []const u32, modifiers: ?*const wlr.Keyboard.Modifiers) void {
        wlr_seat_keyboard_enter(seat, surface, keycodes.ptr, keycodes.len, modifiers);
    }

    const wlr_seat_keyboard_clear_focus = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_keyboard_clear_focus);
    pub const keyboardClearFocus = wlr_seat_keyboard_clear_focus;

    const wlr_seat_keyboard_notify_key = abi.bind(fn (seat: *Seat, time_msec: u32, key: u32, state: u32) callconv(.c) void, c.wlr_seat_keyboard_notify_key);
    pub fn keyboardNotifyKey(seat: *Seat, time_msec: u32, key: u32, state: wl.Keyboard.KeyState) void {
        wlr_seat_keyboard_notify_key(seat, time_msec, key, @as(u32, @intCast(@intFromEnum(state))));
    }

    const wlr_seat_keyboard_notify_modifiers = abi.bind(fn (seat: *Seat, modifiers: ?*const wlr.Keyboard.Modifiers) callconv(.c) void, c.wlr_seat_keyboard_notify_modifiers);
    pub const keyboardNotifyModifiers = wlr_seat_keyboard_notify_modifiers;

    const wlr_seat_keyboard_notify_enter = abi.bind(fn (seat: *Seat, surface: *wlr.Surface, keycodes: ?[*]const u32, num_keycodes: usize, modifiers: ?*const wlr.Keyboard.Modifiers) callconv(.c) void, c.wlr_seat_keyboard_notify_enter);
    pub fn keyboardNotifyEnter(seat: *Seat, surface: *wlr.Surface, keycodes: []const u32, modifiers: ?*const wlr.Keyboard.Modifiers) void {
        wlr_seat_keyboard_notify_enter(seat, surface, keycodes.ptr, keycodes.len, modifiers);
    }

    const wlr_seat_keyboard_notify_clear_focus = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_keyboard_notify_clear_focus);
    pub const keyboardNotifyClearFocus = wlr_seat_keyboard_notify_clear_focus;

    const wlr_seat_keyboard_start_grab = abi.bind(fn (seat: *Seat, grab: *KeyboardGrab) callconv(.c) void, c.wlr_seat_keyboard_start_grab);
    pub const keyboardStartGrab = wlr_seat_keyboard_start_grab;

    const wlr_seat_keyboard_end_grab = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_keyboard_end_grab);
    pub const keyboardEndGrab = wlr_seat_keyboard_end_grab;

    const wlr_seat_keyboard_has_grab = abi.bind(fn (seat: *Seat) callconv(.c) bool, c.wlr_seat_keyboard_has_grab);
    pub const keyboardHasGrab = wlr_seat_keyboard_has_grab;

    const wlr_seat_touch_get_point = abi.bind(fn (seat: *Seat, touch_id: i32) callconv(.c) ?*TouchPoint, c.wlr_seat_touch_get_point);
    pub const touchGetPoint = wlr_seat_touch_get_point;

    const wlr_seat_touch_point_focus = abi.bind(fn (seat: *Seat, surface: *wlr.Surface, time_msec: u32, touch_id: i32, sx: f64, sy: f64) callconv(.c) void, c.wlr_seat_touch_point_focus);
    pub const touchPointFocus = wlr_seat_touch_point_focus;

    const wlr_seat_touch_point_clear_focus = abi.bind(fn (seat: *Seat, time_msec: u32, touch_id: i32) callconv(.c) void, c.wlr_seat_touch_point_clear_focus);
    pub const touchPointClearFocus = wlr_seat_touch_point_clear_focus;

    const wlr_seat_touch_send_down = abi.bind(fn (seat: *Seat, surface: *wlr.Surface, time_msec: u32, touch_id: i32, sx: f64, sy: f64) callconv(.c) u32, c.wlr_seat_touch_send_down);
    pub const touchSendDown = wlr_seat_touch_send_down;

    const wlr_seat_touch_send_up = abi.bind(fn (seat: *Seat, time_msec: u32, touch_id: i32) callconv(.c) u32, c.wlr_seat_touch_send_up);
    pub const touchSendUp = wlr_seat_touch_send_up;

    const wlr_seat_touch_send_motion = abi.bind(fn (seat: *Seat, time_msec: u32, touch_id: i32, sx: f64, sy: f64) callconv(.c) void, c.wlr_seat_touch_send_motion);
    pub const touchSendMotion = wlr_seat_touch_send_motion;

    const wlr_seat_touch_send_frame = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_touch_send_frame);
    pub const touchSendFrame = wlr_seat_touch_send_frame;

    const wlr_seat_touch_send_cancel = abi.bind(fn (seat: *Seat, seat_client: *wlr.Seat.Client) callconv(.c) void, c.wlr_seat_touch_send_cancel);
    pub const touchSendCancel = wlr_seat_touch_send_cancel;

    const wlr_seat_touch_notify_down = abi.bind(fn (seat: *Seat, surface: *wlr.Surface, time_msec: u32, touch_id: i32, sx: f64, sy: f64) callconv(.c) u32, c.wlr_seat_touch_notify_down);
    pub const touchNotifyDown = wlr_seat_touch_notify_down;

    const wlr_seat_touch_notify_up = abi.bind(fn (seat: *Seat, time_msec: u32, touch_id: i32) callconv(.c) u32, c.wlr_seat_touch_notify_up);
    pub const touchNotifyUp = wlr_seat_touch_notify_up;

    const wlr_seat_touch_notify_motion = abi.bind(fn (seat: *Seat, time_msec: u32, touch_id: i32, sx: f64, sy: f64) callconv(.c) void, c.wlr_seat_touch_notify_motion);
    pub const touchNotifyMotion = wlr_seat_touch_notify_motion;

    const wlr_seat_touch_notify_frame = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_touch_notify_frame);
    pub const touchNotifyFrame = wlr_seat_touch_notify_frame;

    const wlr_seat_touch_notify_cancel = abi.bind(fn (seat: *Seat, seat_client: *wlr.Seat.Client) callconv(.c) void, c.wlr_seat_touch_notify_cancel);
    pub const touchNotifyCancel = wlr_seat_touch_notify_cancel;

    const wlr_seat_touch_notify_clear_focus = abi.bind(fn (seat: *Seat, time_msec: u32, touch_id: i32) callconv(.c) void, c.wlr_seat_touch_notify_clear_focus);
    pub const touchNotifyClearFocus = wlr_seat_touch_notify_clear_focus;

    const wlr_seat_touch_num_points = abi.bind(fn (seat: *Seat) callconv(.c) c_int, c.wlr_seat_touch_num_points);
    pub const touchNumPoints = wlr_seat_touch_num_points;

    const wlr_seat_touch_start_grab = abi.bind(fn (seat: *Seat, grab: *TouchGrab) callconv(.c) void, c.wlr_seat_touch_start_grab);
    pub const touchStartGrab = wlr_seat_touch_start_grab;

    const wlr_seat_touch_end_grab = abi.bind(fn (seat: *Seat) callconv(.c) void, c.wlr_seat_touch_end_grab);
    pub const touchEndGrab = wlr_seat_touch_end_grab;

    const wlr_seat_touch_has_grab = abi.bind(fn (seat: *Seat) callconv(.c) bool, c.wlr_seat_touch_has_grab);
    pub const touchHasGrab = wlr_seat_touch_has_grab;

    const wlr_seat_validate_pointer_grab_serial = abi.bind(fn (seat: *Seat, origin: ?*wlr.Surface, serial: u32) callconv(.c) bool, c.wlr_seat_validate_pointer_grab_serial);
    pub const validatePointerGrabSerial = wlr_seat_validate_pointer_grab_serial;

    const wlr_seat_validate_touch_grab_serial = abi.bind(fn (seat: *Seat, origin: ?*wlr.Surface, serial: u32, point_ptr: ?**wlr.TouchPoint) callconv(.c) bool, c.wlr_seat_validate_touch_grab_serial);
    pub const validateTouchGrabSerial = wlr_seat_validate_touch_grab_serial;

    const wlr_seat_request_set_selection = abi.bind(fn (seat: *Seat, client: ?*Seat.Client, source: ?*wlr.DataSource, serial: u32) callconv(.c) void, c.wlr_seat_request_set_selection);
    pub const requestSetSelection = wlr_seat_request_set_selection;

    const wlr_seat_set_selection = abi.bind(fn (seat: *Seat, source: ?*wlr.DataSource, serial: u32) callconv(.c) void, c.wlr_seat_set_selection);
    pub const setSelection = wlr_seat_set_selection;

    const wlr_seat_request_set_primary_selection = abi.bind(fn (seat: *Seat, client: ?*Seat.Client, source: ?*wlr.PrimarySelectionSource, serial: u32) callconv(.c) void, c.wlr_seat_request_set_primary_selection);
    pub const requestSetPrimarySelection = wlr_seat_request_set_primary_selection;

    const wlr_seat_set_primary_selection = abi.bind(fn (seat: *Seat, source: ?*wlr.PrimarySelectionSource, serial: u32) callconv(.c) void, c.wlr_seat_set_primary_selection);
    pub const setPrimarySelection = wlr_seat_set_primary_selection;

    const wlr_seat_request_start_drag = abi.bind(fn (seat: *Seat, drag: *wlr.Drag, origin: *wlr.Surface, serial: u32) callconv(.c) void, c.wlr_seat_request_start_drag);
    pub const requestStartDrag = wlr_seat_request_start_drag;

    const wlr_seat_start_drag = abi.bind(fn (seat: *Seat, drag: *wlr.Drag, serial: u32) callconv(.c) void, c.wlr_seat_start_drag);
    pub const startDrag = wlr_seat_start_drag;

    const wlr_seat_start_pointer_drag = abi.bind(fn (seat: *Seat, drag: *wlr.Drag, serial: u32) callconv(.c) void, c.wlr_seat_start_pointer_drag);
    pub const startPointerDrag = wlr_seat_start_pointer_drag;

    const wlr_seat_start_touch_drag = abi.bind(fn (seat: *Seat, drag: *wlr.Drag, serial: u32, point: *TouchPoint) callconv(.c) void, c.wlr_seat_start_touch_drag);
    pub const startTouchDrag = wlr_seat_start_touch_drag;
};
