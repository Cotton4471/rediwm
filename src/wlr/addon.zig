// Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const AddonSet = extern struct {
    WLR_PRIVATE: @FieldType(c.wlr_addon_set, "WLR_PRIVATE"),

    const wlr_addon_set_init = abi.bind(fn (set: *AddonSet) callconv(.c) void, c.wlr_addon_set_init);
    pub const init = wlr_addon_set_init;

    const wlr_addon_set_finish = abi.bind(fn (set: *AddonSet) callconv(.c) void, c.wlr_addon_set_finish);
    pub const deinit = wlr_addon_set_finish;

    const wlr_addon_find = abi.bind(fn (set: *AddonSet, owner: ?*const anyopaque, impl: *const Addon.Interface) callconv(.c) ?*Addon, c.wlr_addon_find);
    pub const find = wlr_addon_find;
};

pub const Addon = extern struct {
    pub const Interface = extern struct {
        name: [*:0]const u8,
        destroy: *const fn (*Addon) callconv(.c) void,
    };

    impl: *const Interface,

    WLR_PRIVATE: @FieldType(c.wlr_addon, "WLR_PRIVATE"),

    const wlr_addon_init = abi.bind(fn (addon: *Addon, set: *AddonSet, owner: ?*const anyopaque, impl: *const Interface) callconv(.c) void, c.wlr_addon_init);
    pub const init = wlr_addon_init;

    const wlr_addon_finish = abi.bind(fn (addon: *Addon) callconv(.c) void, c.wlr_addon_finish);
    pub const deinit = wlr_addon_finish;
};

comptime {
    abi.assertLayout(AddonSet, c.wlr_addon_set);
    abi.assertLayout(Addon, c.wlr_addon);
    abi.assertLayout(Addon.Interface, c.wlr_addon_interface);
}
