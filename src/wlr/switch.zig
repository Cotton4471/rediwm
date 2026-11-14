//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const SwitchType = enum(c_int) {
    lid = c.WLR_SWITCH_TYPE_LID,
    tablet_mode = c.WLR_SWITCH_TYPE_TABLET_MODE,
    keypad_slide = c.WLR_SWITCH_TYPE_KEYPAD_SLIDE,
};

pub const SwitchState = enum(c_int) {
    off = c.WLR_SWITCH_STATE_OFF,
    on = c.WLR_SWITCH_STATE_ON,
};

pub const Switch = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_switch);
    }

    pub const event = struct {
        pub const Toggle = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_switch_toggle_event);
            }

            time_msec: u32,
            switch_type: SwitchType,
            switch_state: SwitchState,
        };
    };

    const Impl = opaque {};

    base: wlr.InputDevice,

    impl: *const Impl,

    events: extern struct {
        toggle: wl.Signal(*event.Toggle),
    },

    data: ?*anyopaque,
};
