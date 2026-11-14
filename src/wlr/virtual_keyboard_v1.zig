//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

pub const VirtualKeyboardManagerV1 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_virtual_keyboard_manager_v1);
    }

    global: *wl.Global,
    virtual_keyboards: wl.list.Head(VirtualKeyboardV1, .link),

    events: extern struct {
        new_virtual_keyboard: wl.Signal(*VirtualKeyboardV1),
        destroy: wl.Signal(*VirtualKeyboardManagerV1),
    },

    WLR_PRIVATE: @FieldType(c.wlr_virtual_keyboard_manager_v1, "WLR_PRIVATE"),

    const wlr_virtual_keyboard_manager_v1_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*VirtualKeyboardManagerV1, c.wlr_virtual_keyboard_manager_v1_create);
    pub fn create(server: *wl.Server) !*VirtualKeyboardManagerV1 {
        return wlr_virtual_keyboard_manager_v1_create(server) orelse error.OutOfMemory;
    }
};

pub const VirtualKeyboardV1 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_virtual_keyboard_v1);
    }

    keyboard: wlr.Keyboard,
    resource: *zwp.VirtualKeyboardV1,
    seat: *wlr.Seat,
    has_keymap: bool,

    /// VirtualKeyboardManagerV1.virtual_keyboards
    link: wl.list.Link,

    WLR_PRIVATE: @FieldType(c.wlr_virtual_keyboard_v1, "WLR_PRIVATE"),

    const wlr_virtual_keyboard_v1_from_resource = abi.bind(fn (resource: *zwp.VirtualKeyboardV1) callconv(.c) ?*VirtualKeyboardV1, c.wlr_virtual_keyboard_v1_from_resource);
    pub const fromResource = wlr_virtual_keyboard_v1_from_resource;
};
