//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const wl = @import("wayland").server.wl;

pub const XcursorManagerTheme = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_xcursor_manager_theme);
    }

    scale: f32,
    theme: *wlr.XcursorTheme,
    /// XcursorManager.scaled_themes
    link: wl.list.Link,
};

pub const XcursorManager = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_xcursor_manager);
    }

    name: ?[*:0]u8,
    size: u32,
    scaled_themes: wl.list.Head(XcursorManagerTheme, .link),

    const wlr_xcursor_manager_create = abi.bind(fn (name: ?[*:0]const u8, size: u32) callconv(.c) ?*XcursorManager, c.wlr_xcursor_manager_create);
    pub fn create(name: ?[*:0]const u8, size: u32) !*XcursorManager {
        return wlr_xcursor_manager_create(name, size) orelse return error.OutOfMemory;
    }

    const wlr_xcursor_manager_destroy = abi.bind(fn (manager: *XcursorManager) callconv(.c) void, c.wlr_xcursor_manager_destroy);
    pub const destroy = wlr_xcursor_manager_destroy;

    const wlr_xcursor_manager_load = abi.bind(fn (manager: *XcursorManager, scale: f32) callconv(.c) bool, c.wlr_xcursor_manager_load);
    pub fn load(manager: *XcursorManager, scale: f32) !void {
        if (!wlr_xcursor_manager_load(manager, scale)) {
            return error.OutOfMemory;
        }
    }

    const wlr_xcursor_manager_get_xcursor = abi.bind(fn (manager: *XcursorManager, name: [*:0]const u8, scale: f32) callconv(.c) ?*wlr.Xcursor, c.wlr_xcursor_manager_get_xcursor);
    pub const getXcursor = wlr_xcursor_manager_get_xcursor;
};
