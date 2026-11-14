//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wl = @import("wayland").server.wl;

pub const Touch = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_touch);
    }

    pub const event = struct {
        pub const Down = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_touch_down_event);
            }

            touch: *wlr.Touch,
            time_msec: u32,
            touch_id: i32,
            /// From 0..1
            x: f64,
            /// From 0..1
            y: f64,
        };

        pub const Up = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_touch_up_event);
            }

            touch: *wlr.Touch,
            time_msec: u32,
            touch_id: i32,
        };

        pub const Motion = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_touch_motion_event);
            }

            touch: *wlr.Touch,
            time_msec: u32,
            touch_id: i32,
            /// From 0..1
            x: f64,
            /// From 0..1
            y: f64,
        };

        pub const Cancel = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_touch_cancel_event);
            }

            touch: *wlr.Touch,
            time_msec: u32,
            touch_id: i32,
        };
    };

    const Impl = opaque {};

    base: wlr.InputDevice,

    impl: *const Impl,

    output_name: ?[*:0]u8,
    width_mm: f64,
    height_mm: f64,

    events: extern struct {
        down: wl.Signal(*event.Down),
        up: wl.Signal(*event.Up),
        motion: wl.Signal(*event.Motion),
        cancel: wl.Signal(*event.Cancel),
        frame: wl.Signal(void),
    },

    data: ?*anyopaque,
};
