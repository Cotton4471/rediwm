// Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");

const pixman = @import("pixman");

const wayland = @import("wayland");
const wl = wayland.server.wl;

const wlr_region_scale = abi.bind(fn (dst: *pixman.Region32, src: *const pixman.Region32, scale: f32) callconv(.c) void, c.wlr_region_scale);
pub const scale = wlr_region_scale;

const wlr_region_scale_xy = abi.bind(fn (dst: *pixman.Region32, src: *const pixman.Region32, scale_x: f32, scale_y: f32) callconv(.c) void, c.wlr_region_scale_xy);
pub const scaleXY = wlr_region_scale_xy;

const wlr_region_transform = abi.bind(fn (dst: *pixman.Region32, src: *const pixman.Region32, transform: wl.Output.Transform, width: c_int, height: c_int) callconv(.c) void, c.wlr_region_transform);
pub const transform = wlr_region_transform;

const wlr_region_expand = abi.bind(fn (dst: *pixman.Region32, src: *const pixman.Region32, distance: c_int) callconv(.c) void, c.wlr_region_expand);
pub const expand = wlr_region_expand;

const wlr_region_rotated_bounds = abi.bind(fn (dst: *pixman.Region32, src: *const pixman.Region32, rotation: f32, ox: c_int, oy: c_int) callconv(.c) void, c.wlr_region_rotated_bounds);
pub const rotatedBounds = wlr_region_rotated_bounds;

const wlr_region_confine = abi.bind(fn (region: *const pixman.Region32, x1: f64, y1: f64, x2: f64, y2: f64, x2_out: *f64, y2_out: *f64) callconv(.c) bool, c.wlr_region_confine);
pub const confine = wlr_region_confine;
