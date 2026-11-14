//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wp = wayland.server.wp;

pub const CursorShapeManagerV1 = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_cursor_shape_manager_v1);
    }

    global: *wl.Global,

    events: extern struct {
        request_set_shape: wl.Signal(*event.RequestSetShape),
        destroy: wl.Signal(void),
    },

    data: ?*anyopaque,

    WLR_PRIVATE: @FieldType(c.wlr_cursor_shape_manager_v1, "WLR_PRIVATE"),

    pub const DeviceType = enum(c_int) {
        pointer = c.WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_POINTER,
        tablet_tool = c.WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_TABLET_TOOL,
    };

    pub const event = struct {
        pub const RequestSetShape = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_cursor_shape_manager_v1_request_set_shape_event);
            }

            seat_client: *wlr.Seat.Client,
            device_type: DeviceType,
            tablet_tool: ?*wlr.TabletV2TabletTool,
            serial: u32,
            shape: wp.CursorShapeDeviceV1.Shape,
        };
    };

    const wlr_cursor_shape_manager_v1_create = abi.bind(fn (server: *wl.Server, version: u32) callconv(.c) ?*CursorShapeManagerV1, c.wlr_cursor_shape_manager_v1_create);
    pub fn create(server: *wl.Server, version: u32) !*CursorShapeManagerV1 {
        return wlr_cursor_shape_manager_v1_create(server, version) orelse error.OutOfMemory;
    }

    const wlr_cursor_shape_v1_name = abi.bind(fn (shape: wp.CursorShapeDeviceV1.Shape) callconv(.c) [*:0]const u8, c.wlr_cursor_shape_v1_name);
    pub const shapeName = wlr_cursor_shape_v1_name;
};
