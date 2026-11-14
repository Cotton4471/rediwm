//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const PrimarySelectionDeviceManagerV1 = extern struct {
    global: *wl.Global,
    /// PrimarySelectionV1Device.link
    devices: wl.list.Head(PrimarySelectionDeviceV1, .link),

    events: extern struct {
        destroy: wl.Signal(*PrimarySelectionDeviceManagerV1),
    },

    data: ?*anyopaque,

    const wlr_primary_selection_v1_device_manager_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*PrimarySelectionDeviceManagerV1, c.wlr_primary_selection_v1_device_manager_create);
    pub fn create(server: *wl.Server) !*PrimarySelectionDeviceManagerV1 {
        return wlr_primary_selection_v1_device_manager_create(server) orelse error.OutOfMemory;
    }
};

pub const PrimarySelectionDeviceV1 = extern struct {
    manager: *PrimarySelectionDeviceManagerV1,
    seat: *wlr.Seat,
    /// PrimarySelectionDeviceManagerV1.devices
    link: wl.list.Link,
    resources: wl.list.Head(wl.Resource, null),

    offers: wl.list.Head(wl.Resource, null),

    data: ?*anyopaque,
};

comptime {
    abi.assertFields(PrimarySelectionDeviceManagerV1, c.wlr_primary_selection_v1_device_manager);
    abi.assertFields(PrimarySelectionDeviceV1, c.wlr_primary_selection_v1_device);
}
