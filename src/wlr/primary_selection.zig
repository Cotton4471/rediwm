//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");

const wl = @import("wayland").server.wl;

pub const PrimarySelectionSource = extern struct {
    pub const Impl = extern struct {
        send: *const fn (source: *PrimarySelectionSource, mime_type: [*:0]const u8, fd: c_int) callconv(.c) void,
        destroy: ?*const fn (source: *PrimarySelectionSource) callconv(.c) void,
    };

    impl: *const Impl,

    mime_types: wl.Array,

    events: extern struct {
        destroy: wl.Signal(*PrimarySelectionSource),
    },

    data: ?*anyopaque,

    const wlr_primary_selection_source_init = abi.bind(fn (source: *PrimarySelectionSource, impl: *const PrimarySelectionSource.Impl) callconv(.c) void, c.wlr_primary_selection_source_init);
    pub const init = wlr_primary_selection_source_init;

    const wlr_primary_selection_source_destroy = abi.bind(fn (source: *PrimarySelectionSource) callconv(.c) void, c.wlr_primary_selection_source_destroy);
    pub const destroy = wlr_primary_selection_source_destroy;

    const wlr_primary_selection_source_send = abi.bind(fn (source: *PrimarySelectionSource, mime_type: [*:0]const u8, fd: c_int) callconv(.c) void, c.wlr_primary_selection_source_send);
    pub const send = wlr_primary_selection_source_send;
};

comptime {
    abi.assertLayout(PrimarySelectionSource, c.wlr_primary_selection_source);
    abi.assertLayout(PrimarySelectionSource.Impl, c.wlr_primary_selection_source_impl);
}
