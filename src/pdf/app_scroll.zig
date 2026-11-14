//! PDF viewer scrolling: bars, wheel, navigation and search jumps.

const std = @import("std");
const App = @import("app.zig").App;
const layout = @import("layout.zig");
const worker = @import("worker.zig");
const ui_theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const a = @import("app.zig").a;
const Rect = @import("app.zig").Rect;

/// Horizontal scrollbar along the canvas's bottom edge, or null when the
/// pages fit.
pub fn hbar(self: *const App) ?scrollbar.Geometry {
    if (self.doc_layout == null) return null;
    const cv = self.canvasRect();
    const strip = scrollbar.gutter(ui_theme.global.scrollbar_width);
    const track: scrollbar.Rect = .{ .x = @floatCast(cv.x), .y = @as(f32, @floatCast(cv.y + cv.h)) - strip, .w = @floatCast(cv.w), .h = strip };
    return scrollbar.Geometry.compute(.horizontal, track, @floatCast(cv.w), @floatCast(self.contentWidth()), @floatCast(self.scroll_x));
}

/// Advances the scrollbar's hover and scroll feedback.
pub fn stepBar(self: *App, now: i64) void {
    const bar = self.hbar();
    const hovered = if (bar) |b| b.overThumb(@floatCast(self.px), @floatCast(self.py)) else false;
    if (self.hbar_appearance.step(now, self.scroll_x != self.hbar_observed, hovered, self.hbar_drag.active, bar != null)) self.dirty = true;
    self.hbar_observed = self.scroll_x;
}

/// How long the event loop may sleep before the scrollbar needs a frame.
pub fn barTimeout(self: *const App, now: i64) ?u32 {
    if (self.hbar_appearance.active) return 16;
    if (self.hbar_appearance.deadline) |deadline| return @intCast(std.math.clamp(deadline - now, 0, 60_000));
    return null;
}

pub fn handleHorizontalScroll(self: *App, delta: f64) void {
    self.scroll_x = std.math.clamp(self.scroll_x + delta * 30.0, 0.0, self.maxScrollX());
    self.dirty = true;
}

pub fn goToPage(self: *App, page: usize) void {
    if (self.doc_layout == null or self.n_pages == 0) return;
    const p_idx = std.math.clamp(page, 0, self.n_pages - 1);
    self.current_page = p_idx;
    const dl = self.doc_layout.?;
    self.scroll_y = @max(0.0, dl.pages[p_idx].y_offset - 16.0);
    self.anchor = .{ .page_index = p_idx, .rel_y = 0.0 };
    self.updateTitle();
    self.dirty = true;
}

pub fn scrollToMatch(self: *App, match_idx: usize) void {
    if (self.search_matches.items.len == 0 or self.doc_layout == null) return;
    self.search_match_idx = match_idx % self.search_matches.items.len;
    const m = self.search_matches.items[self.search_match_idx];
    const dl = self.doc_layout.?;
    if (m.page_index < dl.pages.len) {
        const p = dl.pages[m.page_index];
        const match_y = p.y_offset + m.rect.y * layout.PTS_TO_LOGICAL * self.zoom;
        self.scroll_y = @max(0.0, match_y - 100.0);
        self.current_page = m.page_index;
        self.anchor = layout.anchorFromScroll(dl.pages, self.scroll_y, self.canvasRect().h);
        self.updateTitle();
        self.dirty = true;
    }
}

pub fn executeSearch(self: *App) void {
    const query = self.search_editor.text.items;
    self.search_matches.clearRetainingCapacity();
    self.search_match_idx = 0;
    if (query.len == 0 or self.n_pages == 0) {
        self.dirty = true;
        return;
    }

    const qz = a.dupeSentinel(u8, query, 0) catch return;
    defer a.free(qz);

    for (0..self.n_pages) |p| {
        self.worker.requestSearch(qz, p, self.generation) catch {};
    }
}

pub fn handleScroll(self: *App, delta: f64) void {
    const sb = self.sidebarRect();
    if (self.sidebar_open and sb.contains(self.px, self.py)) {
        const max_sb = if (self.sidebar_layout) |s| @max(0.0, s.total_height - sb.h) else 0.0;
        self.sidebar_scroll_y = std.math.clamp(self.sidebar_scroll_y + delta * 25.0, 0.0, max_sb);
        self.dirty = true;
        return;
    }

    const dl = self.doc_layout orelse return;
    const cv = self.canvasRect();
    const max_scroll = @max(0.0, dl.total_height - cv.h);
    self.scroll_y = std.math.clamp(self.scroll_y + delta * 30.0, 0.0, max_scroll);
    self.anchor = layout.anchorFromScroll(dl.pages, self.scroll_y, cv.h);
    if (self.anchor.page_index != self.current_page) {
        self.current_page = self.anchor.page_index;
        self.updateTitle();
    }
    self.dirty = true;
}

pub fn scrollViewport(self: *App, direction: f64) void {
    const dl = self.doc_layout orelse return;
    const cv = self.canvasRect();
    const distance = @max(100.0, cv.h * 0.85) * direction;
    const max_scroll = @max(0.0, dl.total_height - cv.h);
    self.scroll_y = std.math.clamp(self.scroll_y + distance, 0.0, max_scroll);
    self.anchor = layout.anchorFromScroll(dl.pages, self.scroll_y, cv.h);
    if (self.anchor.page_index != self.current_page) {
        self.current_page = self.anchor.page_index;
        self.updateTitle();
    }
    self.dirty = true;
}
