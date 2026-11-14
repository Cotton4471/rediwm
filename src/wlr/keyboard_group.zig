//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wl = @import("wayland").server.wl;

pub const KeyboardGroup = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_keyboard_group);
    }

    keyboard: wlr.Keyboard,

    // these are technically list heads, but their usage is internal to wlroots
    devices: wl.list.Link,
    keys: wl.list.Link,

    events: extern struct {
        /// wl.Array of u32 keycodes
        enter: wl.Signal(*wl.Array),
        /// wl.Array of u32 keycodes
        leave: wl.Signal(*wl.Array),
    },

    data: ?*anyopaque,

    const wlr_keyboard_group_create = abi.bind(fn () callconv(.c) ?*KeyboardGroup, c.wlr_keyboard_group_create);
    pub fn create() !*KeyboardGroup {
        return wlr_keyboard_group_create() orelse error.OutOfMemory;
    }

    const wlr_keyboard_group_from_wlr_keyboard = abi.bind(fn (keyboard: *wlr.Keyboard) callconv(.c) ?*KeyboardGroup, c.wlr_keyboard_group_from_wlr_keyboard);
    pub const fromKeyboard = wlr_keyboard_group_from_wlr_keyboard;

    const wlr_keyboard_group_add_keyboard = abi.bind(fn (group: *KeyboardGroup, keyboard: *wlr.Keyboard) callconv(.c) bool, c.wlr_keyboard_group_add_keyboard);
    pub const addKeyboard = wlr_keyboard_group_add_keyboard;

    const wlr_keyboard_group_remove_keyboard = abi.bind(fn (group: *KeyboardGroup, keyboard: *wlr.Keyboard) callconv(.c) void, c.wlr_keyboard_group_remove_keyboard);
    pub const removeKeyboard = wlr_keyboard_group_remove_keyboard;

    const wlr_keyboard_group_destroy = abi.bind(fn (group: *KeyboardGroup) callconv(.c) void, c.wlr_keyboard_group_destroy);
    pub const destroy = wlr_keyboard_group_destroy;
};
