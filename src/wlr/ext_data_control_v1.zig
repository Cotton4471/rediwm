//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const ExtDataControlManagerV1 = extern struct {
    global: *wl.Global,
    devices: wl.list.Head(ExtDataControlDeviceV1, .link),

    events: extern struct {
        destroy: wl.Signal(void),
        new_device: wl.Signal(*ExtDataControlDeviceV1),
    },

    const wlr_ext_data_control_manager_v1_create = abi.bind(fn (server: *wl.Server, version: u32) callconv(.c) ?*ExtDataControlManagerV1, c.wlr_ext_data_control_manager_v1_create);
    pub fn create(server: *wl.Server, version: u32) !*ExtDataControlManagerV1 {
        return wlr_ext_data_control_manager_v1_create(server, version) orelse error.OutOfMemory;
    }
};

pub const ExtDataControlDeviceV1 = extern struct {
    resource: *wl.Resource,
    manager: *ExtDataControlManagerV1,
    /// ExtDataControlManagerV1.devices
    link: wl.list.Link,

    seat: *wlr.Seat,
    selection_offer_resource: ?*wl.Resource,
    primary_selection_offer_resource: ?*wl.Resource,

    const wlr_ext_data_control_device_v1_destroy = abi.bind(fn (device: *ExtDataControlDeviceV1) callconv(.c) void, c.wlr_ext_data_control_device_v1_destroy);
    pub const destroy = wlr_ext_data_control_device_v1_destroy;
};

comptime {
    abi.assertFields(ExtDataControlManagerV1, c.wlr_ext_data_control_manager_v1);
    abi.assertFields(ExtDataControlDeviceV1, c.wlr_ext_data_control_device_v1);
}
