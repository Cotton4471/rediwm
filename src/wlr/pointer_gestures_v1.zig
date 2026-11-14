//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

pub const PointerGesturesV1 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_pointer_gestures_v1);
    }

    global: *wl.Global,
    swipes: wl.list.Head(zwp.PointerGestureSwipeV1, null),
    pinches: wl.list.Head(zwp.PointerGesturePinchV1, null),
    holds: wl.list.Head(zwp.PointerGestureHoldV1, null),

    events: extern struct {
        destroy: wl.Signal(*PointerGesturesV1),
    },

    data: ?*anyopaque,

    WLR_PRIVATE: @FieldType(c.wlr_pointer_gestures_v1, "WLR_PRIVATE"),

    const wlr_pointer_gestures_v1_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*PointerGesturesV1, c.wlr_pointer_gestures_v1_create);
    pub fn create(server: *wl.Server) !*PointerGesturesV1 {
        return wlr_pointer_gestures_v1_create(server) orelse error.OutOfMemory;
    }

    const wlr_pointer_gestures_v1_send_swipe_begin = abi.bind(fn (
        pointer_gestures: *PointerGesturesV1,
        seat: *wlr.Seat,
        time_msec: u32,
        fingers: u32,
    ) callconv(.c) void, c.wlr_pointer_gestures_v1_send_swipe_begin);
    pub const sendSwipeBegin = wlr_pointer_gestures_v1_send_swipe_begin;

    const wlr_pointer_gestures_v1_send_swipe_update = abi.bind(fn (
        pointer_gestures: *PointerGesturesV1,
        seat: *wlr.Seat,
        time_msec: u32,
        dx: f64,
        dy: f64,
    ) callconv(.c) void, c.wlr_pointer_gestures_v1_send_swipe_update);
    pub const sendSwipeUpdate = wlr_pointer_gestures_v1_send_swipe_update;

    const wlr_pointer_gestures_v1_send_swipe_end = abi.bind(fn (
        pointer_gestures: *PointerGesturesV1,
        seat: *wlr.Seat,
        time_msec: u32,
        cancelled: bool,
    ) callconv(.c) void, c.wlr_pointer_gestures_v1_send_swipe_end);
    pub const sendSwipeEnd = wlr_pointer_gestures_v1_send_swipe_end;

    const wlr_pointer_gestures_v1_send_pinch_begin = abi.bind(fn (
        pointer_gestures: *PointerGesturesV1,
        seat: *wlr.Seat,
        time_msec: u32,
        fingers: u32,
    ) callconv(.c) void, c.wlr_pointer_gestures_v1_send_pinch_begin);
    pub const sendPinchBegin = wlr_pointer_gestures_v1_send_pinch_begin;

    const wlr_pointer_gestures_v1_send_pinch_update = abi.bind(fn (
        pointer_gestures: *PointerGesturesV1,
        seat: *wlr.Seat,
        time_msec: u32,
        dx: f64,
        dy: f64,
        scale: f64,
        rotation: f64,
    ) callconv(.c) void, c.wlr_pointer_gestures_v1_send_pinch_update);
    pub const sendPinchUpdate = wlr_pointer_gestures_v1_send_pinch_update;

    const wlr_pointer_gestures_v1_send_pinch_end = abi.bind(fn (
        pointer_gestures: *PointerGesturesV1,
        seat: *wlr.Seat,
        time_msec: u32,
        cancelled: bool,
    ) callconv(.c) void, c.wlr_pointer_gestures_v1_send_pinch_end);
    pub const sendPinchEnd = wlr_pointer_gestures_v1_send_pinch_end;

    const wlr_pointer_gestures_v1_send_hold_begin = abi.bind(fn (
        pointer_gestures: *PointerGesturesV1,
        seat: *wlr.Seat,
        time_msec: u32,
        fingers: u32,
    ) callconv(.c) void, c.wlr_pointer_gestures_v1_send_hold_begin);
    pub const sendHoldBegin = wlr_pointer_gestures_v1_send_hold_begin;

    const wlr_pointer_gestures_v1_send_hold_end = abi.bind(fn (
        pointer_gestures: *PointerGesturesV1,
        seat: *wlr.Seat,
        time_msec: u32,
        cancelled: bool,
    ) callconv(.c) void, c.wlr_pointer_gestures_v1_send_hold_end);
    pub const sendHoldEnd = wlr_pointer_gestures_v1_send_hold_end;
};
