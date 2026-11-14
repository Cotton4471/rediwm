//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const Pointer = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_pointer);
    }

    pub const event = struct {
        pub const Motion = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_motion_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            delta_x: f64,
            delta_y: f64,
            unaccel_dx: f64,
            unaccel_dy: f64,
        };

        pub const MotionAbsolute = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_motion_absolute_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            x: f64,
            y: f64,
        };

        pub const Button = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_button_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            button: u32,
            state: wl.Pointer.ButtonState,
        };

        pub const Axis = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_axis_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            source: wl.Pointer.AxisSource,
            orientation: wl.Pointer.Axis,
            relative_direction: wl.Pointer.AxisRelativeDirection,
            delta: f64,
            delta_discrete: i32,
        };

        pub const SwipeBegin = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_swipe_begin_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            fingers: u32,
        };

        pub const SwipeUpdate = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_swipe_update_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            fingers: u32,
            dx: f64,
            dy: f64,
        };

        pub const SwipeEnd = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_swipe_end_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            cancelled: bool,
        };

        pub const PinchBegin = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_pinch_begin_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            fingers: u32,
        };

        pub const PinchUpdate = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_pinch_update_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            fingers: u32,
            dx: f64,
            dy: f64,
            scale: f64,
            rotation: f64,
        };

        pub const PinchEnd = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_pinch_end_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            cancelled: bool,
        };

        pub const HoldBegin = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_hold_begin_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            fingers: u32,
        };

        pub const HoldEnd = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_pointer_hold_end_event);
            }

            pointer: *wlr.Pointer,
            time_msec: u32,
            cancelled: bool,
        };
    };

    pub const Impl = extern struct {
        name: [*:0]const u8,
        comptime {
            abi.assertLayout(@This(), c.wlr_pointer_impl);
        }
    };

    base: wlr.InputDevice,

    impl: *const Impl,

    output_name: ?[*:0]u8,

    buttons: [c.WLR_POINTER_BUTTONS_CAP]u32,
    button_count: usize,

    events: extern struct {
        motion: wl.Signal(*event.Motion),
        motion_absolute: wl.Signal(*event.MotionAbsolute),
        button: wl.Signal(*event.Button),
        axis: wl.Signal(*event.Axis),
        frame: wl.Signal(*Pointer),

        swipe_begin: wl.Signal(*event.SwipeBegin),
        swipe_update: wl.Signal(*event.SwipeUpdate),
        swipe_end: wl.Signal(*event.SwipeEnd),

        pinch_begin: wl.Signal(*event.PinchBegin),
        pinch_update: wl.Signal(*event.PinchUpdate),
        pinch_end: wl.Signal(*event.PinchEnd),

        hold_begin: wl.Signal(*event.HoldBegin),
        hold_end: wl.Signal(*event.HoldEnd),
    },
    data: ?*anyopaque,

    pub const init = abi.bind(fn (*Pointer, *const Impl, [*:0]const u8) callconv(.c) void, c.wlr_pointer_init);
    pub const finish = abi.bind(fn (*Pointer) callconv(.c) void, c.wlr_pointer_finish);
};
