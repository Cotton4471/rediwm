//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const InputMethodManagerV2 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_input_method_manager_v2);
    }

    global: *wl.Global,
    input_methods: wl.list.Head(InputMethodV2, .link),

    events: extern struct {
        new_input_method: wl.Signal(*wlr.InputMethodV2),
        destroy: wl.Signal(void),
    },

    WLR_PRIVATE: @FieldType(c.wlr_input_method_manager_v2, "WLR_PRIVATE"),

    const wlr_input_method_manager_v2_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*wlr.InputMethodManagerV2, c.wlr_input_method_manager_v2_create);
    pub fn create(server: *wl.Server) !*wlr.InputMethodManagerV2 {
        return wlr_input_method_manager_v2_create(server) orelse error.OutOfMemory;
    }
};

pub const InputMethodV2 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_input_method_v2);
    }

    pub const PreeditString = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_input_method_v2_preedit_string);
        }

        text: ?[*:0]u8,
        cursor_begin: i32,
        cursor_end: i32,
    };

    pub const DeleteSurroundingText = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_input_method_v2_delete_surrounding_text);
        }

        before_length: u32,
        after_length: u32,
    };

    pub const State = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_input_method_v2_state);
        }

        preedit: wlr.InputMethodV2.PreeditString,
        commit_text: ?[*:0]u8,
        delete: wlr.InputMethodV2.DeleteSurroundingText,
    };

    pub const KeyboardGrab = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_input_method_keyboard_grab_v2);
        }

        resource: *wl.Resource,
        input_method: *wlr.InputMethodV2,
        keyboard: ?*wlr.Keyboard,

        events: extern struct {
            destroy: wl.Signal(void),
        },

        WLR_PRIVATE: @FieldType(c.wlr_input_method_keyboard_grab_v2, "WLR_PRIVATE"),

        const wlr_input_method_keyboard_grab_v2_send_key = abi.bind(fn (keyboard_grab: *wlr.InputMethodV2.KeyboardGrab, time: u32, key: u32, state: u32) callconv(.c) void, c.wlr_input_method_keyboard_grab_v2_send_key);
        pub fn sendKey(keyboard_grab: *wlr.InputMethodV2.KeyboardGrab, time: u32, key: u32, state: wl.Keyboard.KeyState) void {
            wlr_input_method_keyboard_grab_v2_send_key(keyboard_grab, time, key, @as(u32, @intCast(@intFromEnum(state))));
        }

        const wlr_input_method_keyboard_grab_v2_send_modifiers = abi.bind(fn (keyboard_grab: *wlr.InputMethodV2.KeyboardGrab, modifiers: *const wlr.Keyboard.Modifiers) callconv(.c) void, c.wlr_input_method_keyboard_grab_v2_send_modifiers);
        pub const sendModifiers = wlr_input_method_keyboard_grab_v2_send_modifiers;

        const wlr_input_method_keyboard_grab_v2_set_keyboard = abi.bind(fn (keyboard_grab: *wlr.InputMethodV2.KeyboardGrab, keyboard: ?*wlr.Keyboard) callconv(.c) void, c.wlr_input_method_keyboard_grab_v2_set_keyboard);
        pub const setKeyboard = wlr_input_method_keyboard_grab_v2_set_keyboard;

        const wlr_input_method_keyboard_grab_v2_destroy = abi.bind(fn (keyboard_grab: *wlr.InputMethodV2.KeyboardGrab) callconv(.c) void, c.wlr_input_method_keyboard_grab_v2_destroy);
        pub const destroy = wlr_input_method_keyboard_grab_v2_destroy;
    };

    resource: *wl.Resource,
    seat: *wlr.Seat,
    seat_client: *wlr.Seat.Client,

    pending: wlr.InputMethodV2.State,
    current: wlr.InputMethodV2.State,
    active: bool,
    client_active: bool,
    current_serial: u32,

    popup_surfaces: wl.list.Head(InputPopupSurfaceV2, .link),
    keyboard_grab: ?*KeyboardGrab,

    link: wl.list.Link,

    events: extern struct {
        commit: wl.Signal(void),
        new_popup_surface: wl.Signal(*wlr.InputPopupSurfaceV2),
        grab_keyboard: wl.Signal(*wlr.InputMethodV2.KeyboardGrab),
        destroy: wl.Signal(void),
    },

    WLR_PRIVATE: @FieldType(c.wlr_input_method_v2, "WLR_PRIVATE"),

    const wlr_input_method_v2_send_activate = abi.bind(fn (input_method: *wlr.InputMethodV2) callconv(.c) void, c.wlr_input_method_v2_send_activate);
    pub const sendActivate = wlr_input_method_v2_send_activate;

    const wlr_input_method_v2_send_deactivate = abi.bind(fn (input_method: *wlr.InputMethodV2) callconv(.c) void, c.wlr_input_method_v2_send_deactivate);
    pub const sendDeactivate = wlr_input_method_v2_send_deactivate;

    const wlr_input_method_v2_send_surrounding_text = abi.bind(fn (input_method: *wlr.InputMethodV2, text: [*:0]const u8, cursor: u32, anchor: u32) callconv(.c) void, c.wlr_input_method_v2_send_surrounding_text);
    pub const sendSurroundingText = wlr_input_method_v2_send_surrounding_text;

    const wlr_input_method_v2_send_content_type = abi.bind(fn (input_method: *wlr.InputMethodV2, hint: u32, purpose: u32) callconv(.c) void, c.wlr_input_method_v2_send_content_type);
    pub const sendContentType = wlr_input_method_v2_send_content_type;

    const wlr_input_method_v2_send_text_change_cause = abi.bind(fn (input_method: *wlr.InputMethodV2, cause: u32) callconv(.c) void, c.wlr_input_method_v2_send_text_change_cause);
    pub const sendTextChangeCause = wlr_input_method_v2_send_text_change_cause;

    const wlr_input_method_v2_send_done = abi.bind(fn (input_method: *wlr.InputMethodV2) callconv(.c) void, c.wlr_input_method_v2_send_done);
    pub const sendDone = wlr_input_method_v2_send_done;

    const wlr_input_method_v2_send_unavailable = abi.bind(fn (input_method: *wlr.InputMethodV2) callconv(.c) void, c.wlr_input_method_v2_send_unavailable);
    pub const sendUnavailable = wlr_input_method_v2_send_unavailable;
};

pub const InputPopupSurfaceV2 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_input_popup_surface_v2);
    }

    resource: *wl.Resource,
    input_method: *InputMethodV2,
    link: wl.list.Link,

    surface: *wlr.Surface,

    events: extern struct {
        destroy: wl.Signal(void),
    },

    data: ?*anyopaque,

    const wlr_input_popup_surface_v2_try_from_wlr_surface = abi.bind(fn (surface: *wlr.Surface) callconv(.c) ?*wlr.InputPopupSurfaceV2, c.wlr_input_popup_surface_v2_try_from_wlr_surface);
    pub const tryFromWlrSurface = wlr_input_popup_surface_v2_try_from_wlr_surface;

    const wlr_input_popup_surface_v2_send_text_input_rectangle = abi.bind(fn (popup_surface: *wlr.InputPopupSurfaceV2, box: *wlr.Box) callconv(.c) void, c.wlr_input_popup_surface_v2_send_text_input_rectangle);
    pub const sendTextInputRectangle = wlr_input_popup_surface_v2_send_text_input_rectangle;
};
