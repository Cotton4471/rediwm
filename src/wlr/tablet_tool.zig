//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

pub const TabletTool = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_tablet_tool);
    }

    pub const Type = enum(c_int) {
        pen = c.WLR_TABLET_TOOL_TYPE_PEN,
        eraser = c.WLR_TABLET_TOOL_TYPE_ERASER,
        brush = c.WLR_TABLET_TOOL_TYPE_BRUSH,
        pencil = c.WLR_TABLET_TOOL_TYPE_PENCIL,
        airbrush = c.WLR_TABLET_TOOL_TYPE_AIRBRUSH,
        mouse = c.WLR_TABLET_TOOL_TYPE_MOUSE,
        lens = c.WLR_TABLET_TOOL_TYPE_LENS,
        totem = c.WLR_TABLET_TOOL_TYPE_TOTEM,
    };

    pub const Axes = packed struct(u32) {
        x: bool = false,
        y: bool = false,
        distance: bool = false,
        pressure: bool = false,
        tilt_x: bool = false,
        tilt_y: bool = false,
        rotation: bool = false,
        slider: bool = false,
        wheel: bool = false,
        _: u23 = 0,
    };

    type: Type,
    hardware_serial: u64,
    hardware_wacom: u64,

    tilt: bool,
    pressure: bool,
    distance: bool,
    rotation: bool,
    slider: bool,
    wheel: bool,

    events: extern struct {
        destroy: wl.Signal(*TabletTool),
    },

    data: ?*anyopaque,
};

pub const Tablet = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_tablet);
    }

    pub const event = struct {
        pub const Axis = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_tablet_tool_axis_event);
            }

            tablet: *wlr.Tablet,
            tool: *TabletTool,

            time_msec: u32,
            updated_axes: wlr.TabletTool.Axes,
            /// From 0..1
            x: f64,
            /// From 0..1
            y: f64,
            /// Relative to last event
            dx: f64,
            /// Relative to last event
            dy: f64,
            pressure: f64,
            distance: f64,
            tilt_x: f64,
            tilt_y: f64,
            rotation: f64,
            slider: f64,
            wheel_delta: f64,
        };

        pub const Proximity = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_tablet_tool_proximity_event);
            }

            pub const State = enum(c_int) {
                out = c.WLR_TABLET_TOOL_PROXIMITY_OUT,
                in = c.WLR_TABLET_TOOL_PROXIMITY_IN,
            };

            tablet: *wlr.Tablet,
            tool: *TabletTool,

            time_msec: u32,
            x: f64,
            y: f64,
            state: Proximity.State,
        };

        pub const Tip = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_tablet_tool_tip_event);
            }

            pub const State = enum(c_int) {
                up = c.WLR_TABLET_TOOL_TIP_UP,
                down = c.WLR_TABLET_TOOL_TIP_DOWN,
            };

            tablet: *wlr.Tablet,
            tool: *TabletTool,

            time_msec: u32,
            x: f64,
            y: f64,
            state: Tip.State,
        };

        pub const Button = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_tablet_tool_button_event);
            }

            tablet: *wlr.Tablet,
            tool: *TabletTool,

            time_msec: u32,
            button: u32,
            state: zwp.TabletToolV2.ButtonState,
        };
    };

    const Impl = opaque {};

    base: wlr.InputDevice,

    impl: *const Impl,

    usb_vendor_id: u16,
    usb_product_id: u16,
    width_mm: f64,
    height_mm: f64,

    events: extern struct {
        axis: wl.Signal(*event.Axis),
        proximity: wl.Signal(*event.Proximity),
        tip: wl.Signal(*event.Tip),
        button: wl.Signal(*event.Button),
    },

    paths: wl.Array,

    data: ?*anyopaque,
};
