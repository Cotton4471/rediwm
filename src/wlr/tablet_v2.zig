//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

pub const TabletManagerV2 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_tablet_manager_v2);
    }

    wl_global: *wl.Global,
    clients: wl.list.Link, // private to wlroots
    seats: wl.list.Link, // private to wlroots

    events: extern struct {
        destroy: wl.Signal(void),
    },

    data: ?*anyopaque,

    WLR_PRIVATE: @FieldType(c.wlr_tablet_manager_v2, "WLR_PRIVATE"),

    const wlr_tablet_v2_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*TabletManagerV2, c.wlr_tablet_v2_create);
    pub fn create(server: *wl.Server) !*TabletManagerV2 {
        return wlr_tablet_v2_create(server) orelse error.OutOfMemory;
    }

    const wlr_tablet_create = abi.bind(fn (manager: *TabletManagerV2, wlr_seat: *wlr.Seat, wlr_device: *wlr.InputDevice) callconv(.c) ?*TabletV2Tablet, c.wlr_tablet_create);
    pub fn createTabletV2Tablet(manager: *TabletManagerV2, wlr_seat: *wlr.Seat, wlr_device: *wlr.InputDevice) !*TabletV2Tablet {
        return wlr_tablet_create(manager, wlr_seat, wlr_device) orelse error.OutOfMemory;
    }

    const wlr_tablet_pad_create = abi.bind(fn (manager: *TabletManagerV2, wlr_seat: *wlr.Seat, wlr_device: *wlr.InputDevice) callconv(.c) ?*TabletV2TabletPad, c.wlr_tablet_pad_create);
    pub fn createTabletV2TabletPad(manager: *TabletManagerV2, wlr_seat: *wlr.Seat, wlr_device: *wlr.InputDevice) !*TabletV2TabletPad {
        return wlr_tablet_pad_create(manager, wlr_seat, wlr_device) orelse error.OutOfMemory;
    }

    const wlr_tablet_tool_create = abi.bind(fn (manager: *TabletManagerV2, wlr_seat: *wlr.Seat, wlr_tool: *wlr.TabletTool) callconv(.c) ?*TabletV2TabletTool, c.wlr_tablet_tool_create);
    pub fn createTabletV2TabletTool(manager: *TabletManagerV2, wlr_seat: *wlr.Seat, wlr_tool: *wlr.TabletTool) !*TabletV2TabletTool {
        return wlr_tablet_tool_create(manager, wlr_seat, wlr_tool) orelse error.OutOfMemory;
    }
};

pub const TabletV2Tablet = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_tablet_v2_tablet);
    }

    link: wl.list.Link, // private to wlroots
    wlr_tablet: *wlr.Tablet,
    wlr_device: *wlr.InputDevice,
    clients: wl.list.Link, // private to wlroots

    current_client: ?*opaque {},

    WLR_PRIVATE: @FieldType(c.wlr_tablet_v2_tablet, "WLR_PRIVATE"),
};

pub const TabletV2TabletTool = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_tablet_v2_tablet_tool);
    }

    pub const event = struct {
        pub const SetCursor = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_tablet_v2_event_cursor);
            }

            surface: ?*wlr.Surface,
            serial: u32,
            hotspot_x: i32,
            hotspot_y: i32,
            seat_client: *wlr.Seat.Client,
        };
    };

    pub const Grab = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_tablet_tool_v2_grab);
        }

        pub const Interface = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_tablet_tool_v2_grab_interface);
            }

            proximity_in: ?*const fn (*Grab, *TabletV2Tablet, *wlr.Surface) callconv(.c) void,
            down: ?*const fn (*Grab) callconv(.c) void,
            up: ?*const fn (*Grab) callconv(.c) void,
            motion: ?*const fn (*Grab, f64, f64) callconv(.c) void,
            pressure: ?*const fn (*Grab, f64) callconv(.c) void,
            distance: ?*const fn (*Grab, f64) callconv(.c) void,
            tilt: ?*const fn (*Grab, f64, f64) callconv(.c) void,
            rotation: ?*const fn (*Grab, f64) callconv(.c) void,
            slider: ?*const fn (*Grab, f64) callconv(.c) void,
            wheel: ?*const fn (*Grab, f64, i32) callconv(.c) void,
            proximity_out: ?*const fn (*Grab) callconv(.c) void,
            button: ?*const fn (*Grab, u32, zwp.TabletToolV2.ButtonState) callconv(.c) void,
            cancel: ?*const fn (*Grab) callconv(.c) void,
        };
        interface: *const Interface,
        tool: *TabletV2TabletTool,
        data: ?*anyopaque,
    };

    link: wl.list.Link, // private to wlroots
    wlr_tool: *wlr.TabletTool,
    clients: wl.list.Link, // private to wlroots

    current_client: ?*opaque {},
    focused_surface: ?*wlr.Surface,

    grab: *Grab,
    default_grab: Grab,

    proximity_serial: u32,
    is_down: bool,
    down_serial: u32,
    num_buttons: usize,
    pressed_buttons: [c.WLR_TABLET_V2_TOOL_BUTTONS_CAP]u32,
    pressed_serials: [c.WLR_TABLET_V2_TOOL_BUTTONS_CAP]u32,

    events: extern struct {
        set_cursor: wl.Signal(*event.SetCursor),
    },

    WLR_PRIVATE: @FieldType(c.wlr_tablet_v2_tablet_tool, "WLR_PRIVATE"),

    const wlr_send_tablet_v2_tablet_tool_proximity_in = abi.bind(fn (tool: *TabletV2TabletTool, tablet: *TabletV2Tablet, surface: *wlr.Surface) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_proximity_in);
    pub const sendProximityIn = wlr_send_tablet_v2_tablet_tool_proximity_in;

    const wlr_send_tablet_v2_tablet_tool_down = abi.bind(fn (tool: *TabletV2TabletTool) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_down);
    pub const sendDown = wlr_send_tablet_v2_tablet_tool_down;

    const wlr_send_tablet_v2_tablet_tool_up = abi.bind(fn (tool: *TabletV2TabletTool) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_up);
    pub const sendUp = wlr_send_tablet_v2_tablet_tool_up;

    const wlr_send_tablet_v2_tablet_tool_motion = abi.bind(fn (tool: *TabletV2TabletTool, x: f64, y: f64) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_motion);
    pub const sendMotion = wlr_send_tablet_v2_tablet_tool_motion;

    const wlr_send_tablet_v2_tablet_tool_pressure = abi.bind(fn (tool: *TabletV2TabletTool, pressure: f64) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_pressure);
    pub const sendPressure = wlr_send_tablet_v2_tablet_tool_pressure;

    const wlr_send_tablet_v2_tablet_tool_distance = abi.bind(fn (tool: *TabletV2TabletTool, distance: f64) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_distance);
    pub const sendDistance = wlr_send_tablet_v2_tablet_tool_distance;

    const wlr_send_tablet_v2_tablet_tool_tilt = abi.bind(fn (tool: *TabletV2TabletTool, x: f64, y: f64) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_tilt);
    pub const sendTilt = wlr_send_tablet_v2_tablet_tool_tilt;

    const wlr_send_tablet_v2_tablet_tool_rotation = abi.bind(fn (tool: *TabletV2TabletTool, degrees: f64) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_rotation);
    pub const sendRotation = wlr_send_tablet_v2_tablet_tool_rotation;

    const wlr_send_tablet_v2_tablet_tool_slider = abi.bind(fn (tool: *TabletV2TabletTool, position: f64) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_slider);
    pub const sendSlider = wlr_send_tablet_v2_tablet_tool_slider;

    const wlr_send_tablet_v2_tablet_tool_wheel = abi.bind(fn (tool: *TabletV2TabletTool, degrees: f64, clicks: i32) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_wheel);
    pub const sendWheel = wlr_send_tablet_v2_tablet_tool_wheel;

    const wlr_send_tablet_v2_tablet_tool_proximity_out = abi.bind(fn (tool: *TabletV2TabletTool) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_proximity_out);
    pub const sendProximityOut = wlr_send_tablet_v2_tablet_tool_proximity_out;

    const wlr_send_tablet_v2_tablet_tool_button = abi.bind(fn (tool: *TabletV2TabletTool, button: u32, state: zwp.TabletToolV2.ButtonState) callconv(.c) void, c.wlr_send_tablet_v2_tablet_tool_button);
    pub const sendButton = wlr_send_tablet_v2_tablet_tool_button;

    const wlr_tablet_v2_tablet_tool_notify_proximity_in = abi.bind(fn (tool: *TabletV2TabletTool, tablet: *TabletV2Tablet, surface: *wlr.Surface) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_proximity_in);
    pub const notifyProximityIn = wlr_tablet_v2_tablet_tool_notify_proximity_in;

    const wlr_tablet_v2_tablet_tool_notify_down = abi.bind(fn (tool: *TabletV2TabletTool) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_down);
    pub const notifyDown = wlr_tablet_v2_tablet_tool_notify_down;

    const wlr_tablet_v2_tablet_tool_notify_up = abi.bind(fn (tool: *TabletV2TabletTool) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_up);
    pub const notifyUp = wlr_tablet_v2_tablet_tool_notify_up;

    const wlr_tablet_v2_tablet_tool_notify_motion = abi.bind(fn (tool: *TabletV2TabletTool, x: f64, y: f64) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_motion);
    pub const notifyMotion = wlr_tablet_v2_tablet_tool_notify_motion;

    const wlr_tablet_v2_tablet_tool_notify_pressure = abi.bind(fn (tool: *TabletV2TabletTool, pressure: f64) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_pressure);
    pub const notifyPressure = wlr_tablet_v2_tablet_tool_notify_pressure;

    const wlr_tablet_v2_tablet_tool_notify_distance = abi.bind(fn (tool: *TabletV2TabletTool, distance: f64) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_distance);
    pub const notifyDistance = wlr_tablet_v2_tablet_tool_notify_distance;

    const wlr_tablet_v2_tablet_tool_notify_tilt = abi.bind(fn (tool: *TabletV2TabletTool, x: f64, y: f64) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_tilt);
    pub const notifyTilt = wlr_tablet_v2_tablet_tool_notify_tilt;

    const wlr_tablet_v2_tablet_tool_notify_rotation = abi.bind(fn (tool: *TabletV2TabletTool, degrees: f64) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_rotation);
    pub const notifyRotation = wlr_tablet_v2_tablet_tool_notify_rotation;

    const wlr_tablet_v2_tablet_tool_notify_slider = abi.bind(fn (tool: *TabletV2TabletTool, position: f64) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_slider);
    pub const notifySlider = wlr_tablet_v2_tablet_tool_notify_slider;

    const wlr_tablet_v2_tablet_tool_notify_wheel = abi.bind(fn (tool: *TabletV2TabletTool, degrees: f64, clicks: i32) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_wheel);
    pub const notifyWheel = wlr_tablet_v2_tablet_tool_notify_wheel;

    const wlr_tablet_v2_tablet_tool_notify_proximity_out = abi.bind(fn (tool: *TabletV2TabletTool) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_proximity_out);
    pub const notifyProximityOut = wlr_tablet_v2_tablet_tool_notify_proximity_out;

    const wlr_tablet_v2_tablet_tool_notify_button = abi.bind(fn (tool: *TabletV2TabletTool, button: u32, state: zwp.TabletToolV2.ButtonState) callconv(.c) void, c.wlr_tablet_v2_tablet_tool_notify_button);
    pub const notifyButton = wlr_tablet_v2_tablet_tool_notify_button;

    const wlr_tablet_tool_v2_start_grab = abi.bind(fn (tool: *TabletV2TabletTool, grab: *Grab) callconv(.c) void, c.wlr_tablet_tool_v2_start_grab);
    pub const startGrab = wlr_tablet_tool_v2_start_grab;

    const wlr_tablet_tool_v2_end_grab = abi.bind(fn (tool: *TabletV2TabletTool) callconv(.c) void, c.wlr_tablet_tool_v2_end_grab);
    pub const endGrab = wlr_tablet_tool_v2_end_grab;

    const wlr_tablet_tool_v2_start_implicit_grab = abi.bind(fn (tool: *TabletV2TabletTool) callconv(.c) void, c.wlr_tablet_tool_v2_start_implicit_grab);
    pub const startImplicitGrab = wlr_tablet_tool_v2_start_implicit_grab;

    const wlr_tablet_tool_v2_has_implicit_grab = abi.bind(fn (tool: *TabletV2TabletTool) callconv(.c) bool, c.wlr_tablet_tool_v2_has_implicit_grab);
    pub const hasImplicitGrab = wlr_tablet_tool_v2_has_implicit_grab;
};

pub const TabletV2TabletPad = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_tablet_v2_tablet_pad);
    }

    pub const event = struct {
        pub const Feedback = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_tablet_v2_event_feedback);
            }

            description: [*:0]const u8,
            index: usize,
            serial: u32,
        };
    };

    pub const Grab = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_tablet_pad_v2_grab);
        }

        pub const Interface = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_tablet_pad_v2_grab_interface);
            }

            enter: ?*const fn (*Grab, *TabletV2Tablet, *wlr.Surface) callconv(.c) u32,
            button: ?*const fn (*Grab, usize, u32, zwp.TabletPadV2.ButtonState) callconv(.c) void,
            strip: ?*const fn (*Grab, u32, f64, bool, u32) callconv(.c) void,
            ring: ?*const fn (*Grab, u32, f64, bool, u32) callconv(.c) void,
            leave: ?*const fn (*Grab, *wlr.Surface) callconv(.c) u32,
            mode: ?*const fn (*Grab, usize, u32, u32) callconv(.c) u32,
            cancel: ?*const fn (*Grab) callconv(.c) void,
        };

        interface: *const Interface,
        pad: *TabletV2TabletPad,
        data: ?*anyopaque,
    };

    link: wl.list.Link, // private to wlroots
    wlr_pad: *wlr.TabletPad,
    wlr_device: *wlr.InputDevice,
    clients: wl.list.Link, // private to wlroots

    group_count: usize,
    groups: [*]u32,

    current_client: ?*opaque {},

    grab: *Grab,
    default_grab: Grab,

    events: extern struct {
        button_feedback: wl.Signal(*event.Feedback),
        strip_feedback: wl.Signal(*event.Feedback),
        ring_feedback: wl.Signal(*event.Feedback),
    },

    WLR_PRIVATE: @FieldType(c.wlr_tablet_v2_tablet_pad, "WLR_PRIVATE"),

    const wlr_send_tablet_v2_tablet_pad_enter = abi.bind(fn (pad: *TabletV2TabletPad, tablet: *TabletV2Tablet, surface: *wlr.Surface) callconv(.c) u32, c.wlr_send_tablet_v2_tablet_pad_enter);
    pub const sendEnter = wlr_send_tablet_v2_tablet_pad_enter;

    const wlr_send_tablet_v2_tablet_pad_button = abi.bind(fn (pad: *TabletV2TabletPad, button: usize, time: u32, state: zwp.TabletPadV2.ButtonState) callconv(.c) void, c.wlr_send_tablet_v2_tablet_pad_button);
    pub const sendButton = wlr_send_tablet_v2_tablet_pad_button;

    const wlr_send_tablet_v2_tablet_pad_strip = abi.bind(fn (pad: *TabletV2TabletPad, strip: u32, position: f64, finger: bool, time: u32) callconv(.c) void, c.wlr_send_tablet_v2_tablet_pad_strip);
    pub const sendStrip = wlr_send_tablet_v2_tablet_pad_strip;

    const wlr_send_tablet_v2_tablet_pad_ring = abi.bind(fn (pad: *TabletV2TabletPad, ring: u32, position: f64, finger: bool, time: u32) callconv(.c) void, c.wlr_send_tablet_v2_tablet_pad_ring);
    pub const sendRing = wlr_send_tablet_v2_tablet_pad_ring;

    const wlr_send_tablet_v2_tablet_pad_leave = abi.bind(fn (pad: *TabletV2TabletPad, surface: *wlr.Surface) callconv(.c) u32, c.wlr_send_tablet_v2_tablet_pad_leave);
    pub const sendLeave = wlr_send_tablet_v2_tablet_pad_leave;

    const wlr_send_tablet_v2_tablet_pad_mode = abi.bind(fn (pad: *TabletV2TabletPad, group: usize, mode: u32, time: u32) callconv(.c) u32, c.wlr_send_tablet_v2_tablet_pad_mode);
    pub const sendMode = wlr_send_tablet_v2_tablet_pad_mode;

    const wlr_tablet_v2_tablet_pad_notify_enter = abi.bind(fn (pad: *TabletV2TabletPad, tablet: *TabletV2Tablet, surface: *wlr.Surface) callconv(.c) u32, c.wlr_tablet_v2_tablet_pad_notify_enter);
    pub const notifyEnter = wlr_tablet_v2_tablet_pad_notify_enter;

    const wlr_tablet_v2_tablet_pad_notify_button = abi.bind(fn (pad: *TabletV2TabletPad, button: usize, time: u32, state: zwp.TabletPadV2.ButtonState) callconv(.c) void, c.wlr_tablet_v2_tablet_pad_notify_button);
    pub const notifyButton = wlr_tablet_v2_tablet_pad_notify_button;

    const wlr_tablet_v2_tablet_pad_notify_strip = abi.bind(fn (pad: *TabletV2TabletPad, strip: u32, position: f64, finger: bool, time: u32) callconv(.c) void, c.wlr_tablet_v2_tablet_pad_notify_strip);
    pub const notifyStrip = wlr_tablet_v2_tablet_pad_notify_strip;

    const wlr_tablet_v2_tablet_pad_notify_ring = abi.bind(fn (pad: *TabletV2TabletPad, ring: u32, position: f64, finger: bool, time: u32) callconv(.c) void, c.wlr_tablet_v2_tablet_pad_notify_ring);
    pub const notifyRing = wlr_tablet_v2_tablet_pad_notify_ring;

    const wlr_tablet_v2_tablet_pad_notify_leave = abi.bind(fn (pad: *TabletV2TabletPad, surface: *wlr.Surface) callconv(.c) u32, c.wlr_tablet_v2_tablet_pad_notify_leave);
    pub const notifyLeave = wlr_tablet_v2_tablet_pad_notify_leave;

    const wlr_tablet_v2_tablet_pad_notify_mode = abi.bind(fn (pad: *TabletV2TabletPad, group: usize, mode: u32, time: u32) callconv(.c) u32, c.wlr_tablet_v2_tablet_pad_notify_mode);
    pub const notifyMode = wlr_tablet_v2_tablet_pad_notify_mode;

    const wlr_tablet_v2_end_grab = abi.bind(fn (pad: *TabletV2TabletPad) callconv(.c) void, c.wlr_tablet_v2_end_grab);
    pub const endGrab = wlr_tablet_v2_end_grab;

    const wlr_tablet_v2_start_grab = abi.bind(fn (pad: *TabletV2TabletPad, grab: *Grab) callconv(.c) void, c.wlr_tablet_v2_start_grab);
    pub const startGrab = wlr_tablet_v2_start_grab;
};
