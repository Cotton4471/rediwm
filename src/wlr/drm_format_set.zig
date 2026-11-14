// Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");

pub const DrmFormat = extern struct {
    format: u32,
    len: usize,
    capacity: usize,
    modifiers: ?[*]u64,

    const wlr_drm_format_finish = abi.bind(fn (format: *DrmFormat) callconv(.c) void, c.wlr_drm_format_finish);
    pub const finish = wlr_drm_format_finish;
};

pub const DrmFormatSet = extern struct {
    len: usize,
    capacity: usize,
    formats: ?[*]DrmFormat,

    const wlr_drm_format_set_finish = abi.bind(fn (set: *DrmFormatSet) callconv(.c) void, c.wlr_drm_format_set_finish);
    pub const finish = wlr_drm_format_set_finish;

    const wlr_drm_format_set_get = abi.bind(fn (set: *const DrmFormatSet, format: u32) callconv(.c) ?*const DrmFormat, c.wlr_drm_format_set_get);
    pub const get = wlr_drm_format_set_get;

    const wlr_drm_format_set_remove = abi.bind(fn (set: *DrmFormatSet, format: u32, modifier: u64) callconv(.c) bool, c.wlr_drm_format_set_remove);
    pub const remove = wlr_drm_format_set_remove;

    const wlr_drm_format_set_has = abi.bind(fn (set: *const DrmFormatSet, format: u32, modifier: u64) callconv(.c) bool, c.wlr_drm_format_set_has);
    pub const has = wlr_drm_format_set_has;

    const wlr_drm_format_set_add = abi.bind(fn (set: *DrmFormatSet, format: u32, modifier: u64) callconv(.c) bool, c.wlr_drm_format_set_add);
    pub const add = wlr_drm_format_set_add;

    const wlr_drm_format_set_intersect = abi.bind(fn (dst: *DrmFormatSet, a: *const DrmFormatSet, b: *const DrmFormatSet) callconv(.c) bool, c.wlr_drm_format_set_intersect);
    pub const intersect = wlr_drm_format_set_intersect;

    const wlr_drm_format_set_union = abi.bind(fn (dst: *DrmFormatSet, a: *const DrmFormatSet, b: *const DrmFormatSet) callconv(.c) bool, c.wlr_drm_format_set_union);
    pub const @"union" = wlr_drm_format_set_union;
};

comptime {
    abi.assertLayout(DrmFormat, c.wlr_drm_format);
    abi.assertLayout(DrmFormatSet, c.wlr_drm_format_set);
}
