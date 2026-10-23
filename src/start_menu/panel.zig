// Compositor-drawn start menu panel.
//
// Taskbar menu and centered keyboard launcher, using the same themed widgets.
const i18n = @import("i18n");
const std = @import("std");
const Allocator = std.mem.Allocator;
const glass = @import("../glass.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const xkb = @import("xkbcommon");

const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const geometry = @import("../geometry.zig");
const panel_buffer = @import("../panel_buffer.zig");
const panel_paint = @import("../panel_paint.zig");
const panel_present = @import("../panel_present.zig");
const scene_data = @import("../scene_data.zig");
const PanelBuffer = panel_buffer.PanelBuffer;
const Taskbar = @import("../Taskbar.zig");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const icon_service = @import("../icon_service.zig");
const ui = @import("ui");
const layout = ui.layout;
const Widget = layout.Widget;
const theme = ui.theme;

const clipboard = @import("../clipboard.zig");
const applications = @import("applications.zig");
const AppEntry = applications.AppEntry;
const launch = @import("launch.zig");
const model_mod = @import("model.zig");
const size_mod = @import("size.zig");
const Model = model_mod.Model;
const Category = model_mod.Category;
const SearchResult = model_mod.SearchResult;

const Anim = anim.Anim;
const log = std.log.scoped(.start_menu);

pub const slide_distance: f32 = 20;

pub const State = enum { opening, open, closing };

pub const Highlights = struct { sel: f32 = 0, hover: f32 = 0, hover_alpha: f32 = 0 };

// Result row height + list gap; converts the pixel quantum to row units.
pub const row_pitch: f32 = 60;

pub const StartMenu = @import("StartMenu.zig");

// The service can evict unpinned rasters between paints. Never leave borrowed
// pixels in a row after lookup becomes pending/missing, and compare stable IDs
// rather than addresses (allocations can reuse an old raster's address).
pub fn updateIcon(image: *layout.ImageData, id: *?u64, lookup: icon_service.Lookup) bool {
    const previous = id.*;
    image.pixels = null;
    image.width = 0;
    image.height = 0;
    id.* = null;
    if (lookup == .ready) {
        const entry = lookup.ready;
        image.pixels = entry.pixels;
        image.width = entry.size;
        image.height = entry.size;
        id.* = entry.id;
    }
    return previous != id.*;
}

test "menu icon arrivals repaint only changed rasters and clear evicted pixels" {
    const pixels = [_]u32{0xff123456};
    var image = layout.ImageData{};
    var id: ?u64 = null;
    try std.testing.expect(!updateIcon(&image, &id, .pending));
    const ready: icon_service.Lookup = .{ .ready = .{ .id = 1, .pixels = &pixels, .size = 1 } };
    try std.testing.expect(updateIcon(&image, &id, ready));
    try std.testing.expect(!updateIcon(&image, &id, ready));
    // Same allocation address with a new lifetime must still be noticed.
    try std.testing.expect(updateIcon(&image, &id, .{ .ready = .{ .id = 2, .pixels = &pixels, .size = 1 } }));
    try std.testing.expect(updateIcon(&image, &id, .pending));
    try std.testing.expect(image.pixels == null and image.width == 0 and image.height == 0);
    try std.testing.expect(!updateIcon(&image, &id, .missing));
}

// Keep shared widgets neutral and red within this panel only.
pub fn menuPalette() theme.Theme {
    var t = theme.shellPalette();
    t.field_bg = t.start_menu_search_bg;
    return t;
}
