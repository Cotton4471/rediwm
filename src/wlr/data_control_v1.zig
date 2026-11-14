//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const DataControlManagerV1 = extern struct {
    global: *wl.Global,
    devices: wl.list.Head(DataControlDeviceV1, .link),

    events: extern struct {
        destroy: wl.Signal(*DataControlManagerV1),
        new_device: wl.Signal(*DataControlDeviceV1),
    },

    const wlr_data_control_manager_v1_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*DataControlManagerV1, c.wlr_data_control_manager_v1_create);
    pub fn create(server: *wl.Server) !*DataControlManagerV1 {
        return wlr_data_control_manager_v1_create(server) orelse error.OutOfMemory;
    }
};

pub const DataControlDeviceV1 = extern struct {
    resource: *wl.Resource,
    manager: *DataControlManagerV1,
    /// DataControlManagerV1.devices
    link: wl.list.Link,

    seat: *wlr.Seat,
    selection_offer_resource: ?*wl.Resource,
    primary_selection_offer_resource: ?*wl.Resource,

    const wlr_data_control_device_v1_destroy = abi.bind(fn (device: *DataControlDeviceV1) callconv(.c) void, c.wlr_data_control_device_v1_destroy);
    pub const destroy = wlr_data_control_device_v1_destroy;
};

comptime {
    abi.assertFields(DataControlManagerV1, c.wlr_data_control_manager_v1);
    abi.assertFields(DataControlDeviceV1, c.wlr_data_control_device_v1);
}
