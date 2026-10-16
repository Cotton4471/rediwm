//! PDF viewer layout: page layout, zoom and tiling.

const std = @import("std");
const App = @import("app.zig").App;
const layout = @import("layout.zig");
const a = @import("app.zig").a;
const Rect = @import("app.zig").Rect;
const ZoomMode = @import("app.zig").ZoomMode;
const rasterTiled = @import("app.zig").rasterTiled;
const tile_px = @import("app.zig").tile_px;
const TileSpan = @import("app.zig").TileSpan;
const page_margin = App.page_margin;

pub fn recomputeLayout(self: *App) !void {
    if (self.page_sizes.items.len == 0) return;
    const cv_w = self.canvasRect().w;
    const old_content = self.contentWidth();
    // Fraction of the content sitting at the viewport centre, so zoom and
    // resize keep the same spot in view.
    const centre_frac: f64 = if (old_content > cv_w and old_content > 0)
        (self.scroll_x + cv_w / 2.0) / old_content
    else
        0.5;
    if (self.doc_layout) |l| l.deinit();
    self.doc_layout = try layout.computeDocumentLayout(
        a,
        self.page_sizes.items,
        self.zoom,
        self.rotation,
        16.0,
    );

    self.scroll_x = std.math.clamp(centre_frac * self.contentWidth() - cv_w / 2.0, 0.0, self.maxScrollX());

    if (self.sidebar_layout) |s| s.deinit();
    self.sidebar_layout = try layout.computeSidebarLayout(
        a,
        self.page_sizes.items,
        self.rotation,
        self.sidebar_w - 32.0,
    );
}

/// Lays the pages out again after a zoom, rotation or size change and
/// returns to the same reading position.
pub fn relayout(self: *App) void {
    self.recomputeLayout() catch {};
    if (self.doc_layout) |dl| {
        const cv_h = self.canvasRect().h;
        const anchored = layout.scrollToAnchor(dl.pages, self.anchor, cv_h);
        self.scroll_y = @min(anchored, @max(0.0, dl.total_height - cv_h));
    }
    self.dirty = true;
}

pub fn setZoomMode(self: *App, mode: ZoomMode) void {
    self.zoom_mode = mode;
    self.updateEffectiveZoom();
    self.relayout();
}

pub fn zoomBy(self: *App, factor: f64) void {
    if (self.doc_layout == null) return;
    self.zoom_mode = .manual;
    self.zoom = std.math.clamp(self.zoom * factor, 0.2, 5.0);
    self.relayout();
}

/// Ctrl+wheel: a 15-unit wheel notch zooms 1.2x, like the buttons;
/// touchpads zoom smoothly in proportion.
pub fn handleZoomScroll(self: *App, delta: f64) void {
    self.zoomBy(std.math.pow(f64, 1.2, -delta / 15.0));
}

pub fn isTiled(self: *const App, p: layout.PageLayout) bool {
    const s: f64 = @floatFromInt(self.scale);
    return rasterTiled(@ceil(p.logical_width * s), @ceil(p.logical_height * s));
}

/// The visible tiles of page `p`, or null when it renders whole.
pub fn tileSpan(self: *const App, cv: Rect, p: layout.PageLayout) ?TileSpan {
    if (!self.isTiled(p)) return null;
    const s: f64 = @floatFromInt(self.scale);
    var span: TileSpan = .{ .raster_w = @ceil(p.logical_width * s), .raster_h = @ceil(p.logical_height * s) };
    // The canvas in page coordinates, clamped to the page.
    const page_x = self.pageX(cv, p);
    const page_y = cv.y + p.y_offset - self.scroll_y;
    const x0 = @max(0.0, cv.x - page_x) * s;
    const x1 = @min(p.logical_width, cv.x + cv.w - page_x) * s;
    const y0 = @max(0.0, cv.y - page_y) * s;
    const y1 = @min(p.logical_height, cv.y + cv.h - page_y) * s;
    if (x1 <= x0 or y1 <= y0) return span;
    const cols = @ceil(span.raster_w / tile_px);
    const rows = @ceil(span.raster_h / tile_px);
    span.x0 = @intFromFloat(@floor(x0 / tile_px));
    span.x1 = @intFromFloat(@min(cols, @ceil(x1 / tile_px)));
    span.y0 = @intFromFloat(@floor(y0 / tile_px));
    span.y1 = @intFromFloat(@min(rows, @ceil(y1 / tile_px)));
    return span;
}

pub fn updateEffectiveZoom(self: *App) void {
    // Nothing to fit before the document opens (first configure, password prompt).
    if (self.page_sizes.items.len == 0) return;
    const canvas = self.canvasRect();
    var max_w: f64 = 0;
    for (self.page_sizes.items) |sz| {
        const rsz = layout.rotatedPageSize(sz, self.rotation);
        if (rsz.width > max_w) max_w = rsz.width;
    }
    if (max_w <= 0) max_w = 612.0;

    switch (self.zoom_mode) {
        .fit_width => {
            self.zoom = layout.fitWidth(max_w, canvas.w, 24.0);
        },
        .fit_page => {
            const cur_sz = if (self.current_page < self.page_sizes.items.len)
                self.page_sizes.items[self.current_page]
            else
                self.page_sizes.items[0];
            const rsz = layout.rotatedPageSize(cur_sz, self.rotation);
            // Never enlarge past 100%: a small page keeps its real size.
            self.zoom = @min(1.0, layout.fitPage(rsz.width, rsz.height, canvas.w, canvas.h, 24.0));
        },
        .manual => {},
    }
    self.zoom = std.math.clamp(self.zoom, 0.2, 5.0);
}

// Geometry helpers
pub fn toolbarRect(self: *const App) Rect {
    return .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = 44.0 };
}

pub fn sidebarRect(self: *const App) Rect {
    if (!self.sidebar_open) return .{ .x = 0, .y = 44.0, .w = 0, .h = @max(0, @as(f64, @floatFromInt(self.h)) - 44.0) };
    return .{ .x = 0, .y = 44.0, .w = self.sidebar_w, .h = @max(0, @as(f64, @floatFromInt(self.h)) - 44.0) };
}

pub fn canvasRect(self: *const App) Rect {
    const sb_w = if (self.sidebar_open) self.sidebar_w else 0.0;
    return .{
        .x = sb_w,
        .y = 44.0,
        .w = @max(0, @as(f64, @floatFromInt(self.w)) - sb_w),
        .h = @max(0, @as(f64, @floatFromInt(self.h)) - 44.0),
    };
}

pub fn contentWidth(self: *const App) f64 {
    const dl = self.doc_layout orelse return 0;
    return dl.max_width + page_margin * 2.0;
}

pub fn maxScrollX(self: *const App) f64 {
    return @max(0.0, self.contentWidth() - self.canvasRect().w);
}

/// Left edge of a page in window coordinates. Pages centre while they fit;
/// once the widest page overflows the canvas they scroll horizontally.
pub fn pageX(self: *const App, cv: Rect, p: layout.PageLayout) f64 {
    const dl = self.doc_layout.?;
    if (self.maxScrollX() <= 0) return cv.x + (cv.w - p.logical_width) / 2.0;
    return cv.x + page_margin + (dl.max_width - p.logical_width) / 2.0 - self.scroll_x;
}

pub fn searchBarRect(self: *const App) Rect {
    const cv = self.canvasRect();
    return .{
        .x = cv.x + @max(10.0, cv.w - 300.0),
        .y = cv.y + 10.0,
        .w = 290.0,
        .h = 36.0,
    };
}
