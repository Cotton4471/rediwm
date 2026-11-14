//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const Cursor = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_cursor);
    }

    pub const State = opaque {};

    state: *State,
    x: f64,
    y: f64,

    events: extern struct {
        motion: wl.Signal(*wlr.Pointer.event.Motion),
        motion_absolute: wl.Signal(*wlr.Pointer.event.MotionAbsolute),
        button: wl.Signal(*wlr.Pointer.event.Button),
        axis: wl.Signal(*wlr.Pointer.event.Axis),
        frame: wl.Signal(*Cursor),
        swipe_begin: wl.Signal(*wlr.Pointer.event.SwipeBegin),
        swipe_update: wl.Signal(*wlr.Pointer.event.SwipeUpdate),
        swipe_end: wl.Signal(*wlr.Pointer.event.SwipeEnd),
        pinch_begin: wl.Signal(*wlr.Pointer.event.PinchBegin),
        pinch_update: wl.Signal(*wlr.Pointer.event.PinchUpdate),
        pinch_end: wl.Signal(*wlr.Pointer.event.PinchEnd),
        hold_begin: wl.Signal(*wlr.Pointer.event.HoldBegin),
        hold_end: wl.Signal(*wlr.Pointer.event.HoldEnd),

        touch_up: wl.Signal(*wlr.Touch.event.Up),
        touch_down: wl.Signal(*wlr.Touch.event.Down),
        touch_motion: wl.Signal(*wlr.Touch.event.Motion),
        touch_cancel: wl.Signal(*wlr.Touch.event.Cancel),
        touch_frame: wl.Signal(void),

        tablet_tool_axis: wl.Signal(*wlr.Tablet.event.Axis),
        tablet_tool_proximity: wl.Signal(*wlr.Tablet.event.Proximity),
        tablet_tool_tip: wl.Signal(*wlr.Tablet.event.Tip),
        tablet_tool_button: wl.Signal(*wlr.Tablet.event.Button),
    },

    data: ?*anyopaque,

    const wlr_cursor_create = abi.bind(fn () callconv(.c) ?*Cursor, c.wlr_cursor_create);
    pub fn create() !*Cursor {
        return wlr_cursor_create() orelse error.OutOfMemory;
    }

    const wlr_cursor_destroy = abi.bind(fn (cur: *Cursor) callconv(.c) void, c.wlr_cursor_destroy);
    pub const destroy = wlr_cursor_destroy;

    const wlr_cursor_warp = abi.bind(fn (cur: *Cursor, dev: ?*wlr.InputDevice, lx: f64, ly: f64) callconv(.c) bool, c.wlr_cursor_warp);
    pub const warp = wlr_cursor_warp;

    const wlr_cursor_absolute_to_layout_coords = abi.bind(fn (cur: *Cursor, dev: ?*wlr.InputDevice, x: f64, y: f64, lx: *f64, ly: *f64) callconv(.c) void, c.wlr_cursor_absolute_to_layout_coords);
    pub const absoluteToLayoutCoords = wlr_cursor_absolute_to_layout_coords;

    const wlr_cursor_warp_closest = abi.bind(fn (cur: *Cursor, dev: ?*wlr.InputDevice, x: f64, y: f64) callconv(.c) void, c.wlr_cursor_warp_closest);
    pub const warpClosest = wlr_cursor_warp_closest;

    const wlr_cursor_warp_absolute = abi.bind(fn (cur: *Cursor, dev: ?*wlr.InputDevice, x: f64, y: f64) callconv(.c) void, c.wlr_cursor_warp_absolute);
    pub const warpAbsolute = wlr_cursor_warp_absolute;

    const wlr_cursor_move = abi.bind(fn (cur: *Cursor, dev: ?*wlr.InputDevice, delta_x: f64, delta_y: f64) callconv(.c) void, c.wlr_cursor_move);
    pub const move = wlr_cursor_move;

    const wlr_cursor_set_buffer = abi.bind(fn (cur: *Cursor, buffer: *wlr.Buffer, hotspot_x: i32, hotspot_y: i32, scale: f32) callconv(.c) void, c.wlr_cursor_set_buffer);
    pub const setBuffer = wlr_cursor_set_buffer;

    const wlr_cursor_unset_image = abi.bind(fn (cur: *Cursor) callconv(.c) void, c.wlr_cursor_unset_image);
    pub const unsetImage = wlr_cursor_unset_image;

    const wlr_cursor_set_xcursor = abi.bind(fn (cur: *Cursor, manager: *wlr.XcursorManager, name: [*:0]const u8) callconv(.c) void, c.wlr_cursor_set_xcursor);
    pub const setXcursor = wlr_cursor_set_xcursor;

    const wlr_cursor_set_surface = abi.bind(fn (cur: *Cursor, surface: ?*wlr.Surface, hotspot_x: i32, hotspot_y: i32) callconv(.c) void, c.wlr_cursor_set_surface);
    pub const setSurface = wlr_cursor_set_surface;

    const wlr_cursor_attach_input_device = abi.bind(fn (cur: *Cursor, dev: *wlr.InputDevice) callconv(.c) void, c.wlr_cursor_attach_input_device);
    pub const attachInputDevice = wlr_cursor_attach_input_device;

    const wlr_cursor_detach_input_device = abi.bind(fn (cur: *Cursor, dev: *wlr.InputDevice) callconv(.c) void, c.wlr_cursor_detach_input_device);
    pub const detachInputDevice = wlr_cursor_detach_input_device;

    const wlr_cursor_attach_output_layout = abi.bind(fn (cur: *Cursor, l: *wlr.OutputLayout) callconv(.c) void, c.wlr_cursor_attach_output_layout);
    pub const attachOutputLayout = wlr_cursor_attach_output_layout;

    const wlr_cursor_map_to_output = abi.bind(fn (cur: *Cursor, output: *wlr.Output) callconv(.c) void, c.wlr_cursor_map_to_output);
    pub const mapToOutput = wlr_cursor_map_to_output;

    const wlr_cursor_map_input_to_output = abi.bind(fn (cur: *Cursor, dev: *wlr.InputDevice, output: ?*wlr.Output) callconv(.c) void, c.wlr_cursor_map_input_to_output);
    pub const mapInputToOutput = wlr_cursor_map_input_to_output;

    const wlr_cursor_map_to_region = abi.bind(fn (cur: *Cursor, box: *const wlr.Box) callconv(.c) void, c.wlr_cursor_map_to_region);
    pub const mapToRegion = wlr_cursor_map_to_region;

    const wlr_cursor_map_input_to_region = abi.bind(fn (cur: *Cursor, dev: *wlr.InputDevice, box: *const wlr.Box) callconv(.c) void, c.wlr_cursor_map_input_to_region);
    pub const mapInputToRegion = wlr_cursor_map_input_to_region;
};
