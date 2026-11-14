//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const InputDevice = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_input_device);
    }

    pub const Type = enum(c_int) {
        keyboard = c.WLR_INPUT_DEVICE_KEYBOARD,
        pointer = c.WLR_INPUT_DEVICE_POINTER,
        touch = c.WLR_INPUT_DEVICE_TOUCH,
        tablet = c.WLR_INPUT_DEVICE_TABLET,
        tablet_pad = c.WLR_INPUT_DEVICE_TABLET_PAD,
        @"switch" = c.WLR_INPUT_DEVICE_SWITCH,
    };

    type: Type,
    name: ?[*:0]u8,

    events: extern struct {
        destroy: wl.Signal(*InputDevice),
    },

    data: ?*anyopaque,

    const wlr_keyboard_from_input_device = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) *wlr.Keyboard, c.wlr_keyboard_from_input_device);
    pub const toKeyboard = wlr_keyboard_from_input_device;

    const wlr_pointer_from_input_device = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) *wlr.Pointer, c.wlr_pointer_from_input_device);
    pub const toPointer = wlr_pointer_from_input_device;

    const wlr_touch_from_input_device = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) *wlr.Touch, c.wlr_touch_from_input_device);
    pub const toTouch = wlr_touch_from_input_device;

    const wlr_switch_from_input_device = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) *wlr.Switch, c.wlr_switch_from_input_device);
    pub const toSwitch = wlr_switch_from_input_device;

    const wlr_tablet_from_input_device = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) *wlr.Tablet, c.wlr_tablet_from_input_device);
    pub const toTablet = wlr_tablet_from_input_device;

    const wlr_tablet_pad_from_input_device = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) *wlr.TabletPad, c.wlr_tablet_pad_from_input_device);
    pub const toTabletPad = wlr_tablet_pad_from_input_device;

    const wlr_input_device_get_virtual_keyboard = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) ?*wlr.VirtualKeyboardV1, c.wlr_input_device_get_virtual_keyboard);
    pub const getVirtualKeyboard = wlr_input_device_get_virtual_keyboard;

    const wlr_input_device_is_libinput = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) bool, c.wlr_input_device_is_libinput);
    pub const isLibinput = wlr_input_device_is_libinput;

    const wlr_libinput_get_device_handle = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) *LibinputDevice, c.wlr_libinput_get_device_handle);
    pub fn getLibinputDevice(wlr_dev: *InputDevice) ?*LibinputDevice {
        if (!wlr_input_device_is_libinput(wlr_dev)) return null;
        return wlr_libinput_get_device_handle(wlr_dev);
    }

    const wlr_input_device_is_wl = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) bool, c.wlr_input_device_is_wl);
    pub const isWl = wlr_input_device_is_wl;

    const wlr_input_device_is_x11 = abi.bind(fn (wlr_dev: *InputDevice) callconv(.c) bool, c.wlr_input_device_is_x11);
    pub const isX11 = wlr_input_device_is_x11;
};

const LibinputDevice = opaque {};
