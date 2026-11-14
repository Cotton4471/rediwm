// Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");

pub const DmabufAttributes = extern struct {
    width: i32,
    height: i32,
    format: u32,
    modifier: u64,

    n_planes: c_int,
    offset: [4]u32,
    stride: [4]u32,
    fd: [4]c_int,

    const wlr_dmabuf_attributes_finish = abi.bind(fn (attribs: *DmabufAttributes) callconv(.c) void, c.wlr_dmabuf_attributes_finish);
    pub const finish = wlr_dmabuf_attributes_finish;

    const wlr_dmabuf_attributes_copy = abi.bind(fn (dst: *DmabufAttributes, src: *const DmabufAttributes) callconv(.c) bool, c.wlr_dmabuf_attributes_copy);
    pub const copy = wlr_dmabuf_attributes_copy;
};

comptime {
    abi.assertLayout(DmabufAttributes, c.wlr_dmabuf_attributes);
}
