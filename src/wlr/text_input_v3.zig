//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const TextInputManagerV3 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_text_input_manager_v3);
    }

    global: *wl.Global,
    text_inputs: wl.list.Head(TextInputV3, .link),

    events: extern struct {
        new_text_input: wl.Signal(*wlr.TextInputV3),
        destroy: wl.Signal(void),
    },

    WLR_PRIVATE: @FieldType(c.wlr_text_input_manager_v3, "WLR_PRIVATE"),

    const wlr_text_input_manager_v3_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*wlr.TextInputManagerV3, c.wlr_text_input_manager_v3_create);
    pub fn create(server: *wl.Server) !*wlr.TextInputManagerV3 {
        return wlr_text_input_manager_v3_create(server) orelse error.OutOfMemory;
    }
};

pub const TextInputV3 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_text_input_v3);
    }

    pub const Features = packed struct(u32) {
        surrounding_text: bool = false,
        content_type: bool = false,
        cursor_rectangle: bool = false,
        _: u29 = 0,
    };

    pub const State = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_text_input_v3_state);
        }

        surrounding: extern struct {
            text: ?[*:0]u8,
            cursor: u32,
            anchor: u32,
        },

        text_change_cause: u32,

        content_type: extern struct {
            hint: u32,
            purpose: u32,
        },

        cursor_rectangle: wlr.Box,

        features: Features,
    };

    seat: ?*wlr.Seat,
    resource: *wl.Resource,
    focused_surface: ?*wlr.Surface,
    pending: wlr.TextInputV3.State,
    current: wlr.TextInputV3.State,
    current_serial: u32,
    pending_enabled: bool,
    current_enabled: bool,
    active_features: Features,

    link: wl.list.Link,

    events: extern struct {
        enable: wl.Signal(void),
        commit: wl.Signal(void),
        disable: wl.Signal(void),
        destroy: wl.Signal(void),
    },

    WLR_PRIVATE: @FieldType(c.wlr_text_input_v3, "WLR_PRIVATE"),

    const wlr_text_input_v3_send_enter = abi.bind(fn (text_input: *wlr.TextInputV3, surface: *wlr.Surface) callconv(.c) void, c.wlr_text_input_v3_send_enter);
    pub const sendEnter = wlr_text_input_v3_send_enter;

    const wlr_text_input_v3_send_leave = abi.bind(fn (text_input: *wlr.TextInputV3) callconv(.c) void, c.wlr_text_input_v3_send_leave);
    pub const sendLeave = wlr_text_input_v3_send_leave;

    const wlr_text_input_v3_send_preedit_string = abi.bind(fn (text_input: *wlr.TextInputV3, text: [*:0]const u8, cursor_begin: i32, cursor_end: i32) callconv(.c) void, c.wlr_text_input_v3_send_preedit_string);
    pub const sendPreeditString = wlr_text_input_v3_send_preedit_string;

    const wlr_text_input_v3_send_commit_string = abi.bind(fn (text_input: *wlr.TextInputV3, text: [*:0]const u8) callconv(.c) void, c.wlr_text_input_v3_send_commit_string);
    pub const sendCommitString = wlr_text_input_v3_send_commit_string;

    const wlr_text_input_v3_send_delete_surrounding_text = abi.bind(fn (text_input: *wlr.TextInputV3, before_length: u32, after_length: u32) callconv(.c) void, c.wlr_text_input_v3_send_delete_surrounding_text);
    pub const sendDeleteSurroundingText = wlr_text_input_v3_send_delete_surrounding_text;

    const wlr_text_input_v3_send_done = abi.bind(fn (text_input: *wlr.TextInputV3) callconv(.c) void, c.wlr_text_input_v3_send_done);
    pub const sendDone = wlr_text_input_v3_send_done;
};
