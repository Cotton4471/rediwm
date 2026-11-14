//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const VirtualPointerManagerV1 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_virtual_pointer_manager_v1);
    }

    pub const event = struct {
        pub const NewPointer = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_virtual_pointer_v1_new_pointer_event);
            }

            new_pointer: *VirtualPointerV1,
            suggested_seat: ?*wlr.Seat,
            suggested_output: ?*wlr.Output,
        };
    };

    global: *wl.Global,
    virtual_pointers: wl.list.Head(VirtualPointerV1, .link),

    events: extern struct {
        new_virtual_pointer: wl.Signal(*event.NewPointer),
        destroy: wl.Signal(*VirtualPointerManagerV1),
    },

    WLR_PRIVATE: @FieldType(c.wlr_virtual_pointer_manager_v1, "WLR_PRIVATE"),

    const wlr_virtual_pointer_manager_v1_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*VirtualPointerManagerV1, c.wlr_virtual_pointer_manager_v1_create);
    pub fn create(server: *wl.Server) !*VirtualPointerManagerV1 {
        return wlr_virtual_pointer_manager_v1_create(server) orelse error.OutOfMemory;
    }
};

pub const VirtualPointerV1 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_virtual_pointer_v1);
    }

    pointer: wlr.Pointer,
    resource: *wl.Resource,

    axis_event: [2]wlr.Pointer.event.Axis,
    axis: wl.Pointer.Axis,
    axis_valid: [2]bool,

    /// VirtualPointerManagerV1.virtual_pointers
    link: wl.list.Link,
};
