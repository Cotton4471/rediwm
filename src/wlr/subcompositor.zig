//! Typed wlroots header adapter. API shapes adapted from zig-wlroots;
//! see LICENSE.zig-wlroots for its MIT license.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const Subcompositor = extern struct {
    global: *wl.Global,

    events: extern struct {
        destroy: wl.Signal(*Subcompositor),
    },

    const wlr_subcompositor_create = abi.bind(fn (server: *wl.Server) callconv(.c) ?*Subcompositor, c.wlr_subcompositor_create);
    pub fn create(server: *wl.Server) !*Subcompositor {
        return wlr_subcompositor_create(server) orelse error.OutOfMemory;
    }
};

pub const Subsurface = extern struct {
    pub const ParentState = extern struct {
        x: i32,
        y: i32,
        /// wlr.Surface.State.subsurfaces_above/subsurfaces_below
        link: wl.list.Link,

        WLR_PRIVATE: @FieldType(c.wlr_subsurface_parent_state, "WLR_PRIVATE"),
    };

    resource: *wl.Subsurface,
    surface: *wlr.Surface,
    parent: *wlr.Surface,

    current: ParentState,
    pending: ParentState,

    cached_seq: u32,
    has_cache: bool,

    synchronized: bool,
    added: bool,

    events: extern struct {
        destroy: wl.Signal(*Subsurface),
    },

    data: ?*anyopaque,

    const wlr_subsurface_try_from_wlr_surface = abi.bind(fn (surface: *wlr.Surface) callconv(.c) ?*wlr.Subsurface, c.wlr_subsurface_try_from_wlr_surface);
    pub const tryFromWlrSurface = wlr_subsurface_try_from_wlr_surface;
};

comptime {
    abi.assertFields(Subcompositor, c.wlr_subcompositor);
    abi.assertFields(Subsurface, c.wlr_subsurface);
    // ParentState is embedded twice in Subsurface and must retain its full
    // header-derived private tail so pending and following fields line up.
    abi.assertLayout(Subsurface.ParentState, c.wlr_subsurface_parent_state);
}
