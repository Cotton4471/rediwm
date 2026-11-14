//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

pub const XcursorImage = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_xcursor_image);
    }

    width: u32,
    height: u32,
    hotspot_x: u32,
    hotspot_y: u32,
    delay: u32,
    buffer: [*]u8,

    WLR_PRIVATE: @FieldType(c.wlr_xcursor_image, "WLR_PRIVATE"),

    const wlr_xcursor_image_get_buffer = abi.bind(fn (image: *XcursorImage) callconv(.c) *wlr.Buffer, c.wlr_xcursor_image_get_buffer);
    pub const getBuffer = wlr_xcursor_image_get_buffer;
};

pub const Xcursor = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_xcursor);
    }

    image_count: c_uint,
    images: [*]*XcursorImage,
    name: [*:0]u8,
    total_delay: u32,

    const wlr_xcursor_frame = abi.bind(fn (cursor: *Xcursor, time: u32) callconv(.c) c_int, c.wlr_xcursor_frame);
    pub const frame = wlr_xcursor_frame;

    // kinda ugly, wlroots decided to use the enum directly here instead of
    // a uint32_t which has the ABI of an int
    const wlr_xcursor_get_resize_name = abi.bind(fn (edges: c_int) callconv(.c) [*:0]const u8, c.wlr_xcursor_get_resize_name);
    pub fn getResizeName(edges: wlr.Edges) [*:0]const u8 {
        return wlr_xcursor_get_resize_name(@as(c_int, @bitCast(edges)));
    }
};

pub const XcursorTheme = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_xcursor_theme);
    }

    cursor_count: c_uint,
    cursors: [*]*Xcursor,
    name: [*:0]u8,
    size: c_int,

    const wlr_xcursor_theme_load = abi.bind(fn (name: [*:0]const u8, size: c_int) callconv(.c) ?*XcursorTheme, c.wlr_xcursor_theme_load);
    pub const load = wlr_xcursor_theme_load;

    const wlr_xcursor_theme_destroy = abi.bind(fn (theme: *XcursorTheme) callconv(.c) void, c.wlr_xcursor_theme_destroy);
    pub const destroy = wlr_xcursor_theme_destroy;

    const wlr_xcursor_theme_get_cursor = abi.bind(fn (theme: *XcursorTheme, name: [*:0]const u8) callconv(.c) ?*Xcursor, c.wlr_xcursor_theme_get_cursor);
    pub const getCursor = wlr_xcursor_theme_get_cursor;
};
