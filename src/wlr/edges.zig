//! wlr.Edges: `enum wlr_edges` (wlr/util/edges.h) is a plain bitmask
//! (WLR_EDGE_TOP = 1<<0, ...), not a C bitfield, so this is pure
//! ergonomic sugar over a u32 -- no translate-c struct to stay in sync with,
//! just the four bit positions the header defines.
pub const Edges = packed struct(u32) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _: u28 = 0,
};

comptime {
    const c = @import("c.zig").c;
    if (@as(u32, @bitCast(Edges{ .top = true })) != c.WLR_EDGE_TOP or
        @as(u32, @bitCast(Edges{ .bottom = true })) != c.WLR_EDGE_BOTTOM or
        @as(u32, @bitCast(Edges{ .left = true })) != c.WLR_EDGE_LEFT or
        @as(u32, @bitCast(Edges{ .right = true })) != c.WLR_EDGE_RIGHT)
        @compileError("wlroots edge bit values changed");
}
