//! Selection and the title, decode requests and results, and the filmstrip: thumbnails, animation and scrolling.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const decoder = @import("loader.zig");
const view = @import("view.zig");
const cache_mod = @import("cache.zig");
const Rect = view.Rect;
const scrollbar = @import("ui").widgets.scrollbar;
const ui_theme = @import("ui").theme;
const App = @import("app.zig").App;

pub fn setTitle(self: *App) void {
    const raw_name = std.fs.path.basename(self.paths[self.selected]);
    const name = if (std.unicode.utf8ValidateSlice(raw_name)) raw_name else tr("Image");
    _ = i18n.fmtZ(&self.title, tr("{modified}{name} — Images ({position}/{count})"), .{ .modified = if (self.modified) "* " else "", .name = name, .position = self.position() + 1, .count = self.count() }) catch {
        _ = i18n.fmtZ(&self.title, tr("Images ({position}/{count})"), .{ .position = self.position() + 1, .count = self.count() }) catch unreachable;
    };
    self.title_changed = true;
}

pub fn queueRequests(self: *App) void {
    var jobs: [8]decoder.Job = undefined;
    var job_count: usize = 0;

    if (self.image == null) {
        jobs[job_count] = .{ .index = self.selected };
        job_count += 1;
    }

    // Speculatively preload immediate neighbors so navigation is instant
    const pos = self.position();
    const neighbors = [_]usize{
        self.indexAt(@min(pos + 1, self.count() - 1)),
        self.indexAt(pos -| 1),
        self.indexAt(@min(pos + 2, self.count() - 1)),
        self.indexAt(pos -| 2),
    };

    for (neighbors) |idx| {
        if (idx == self.selected) continue;
        if (self.image_cache.contains(idx)) continue;
        var already = false;
        for (jobs[0..job_count]) |j| {
            if (j.index == idx) {
                already = true;
                break;
            }
        }
        if (!already and job_count < jobs.len) {
            jobs[job_count] = .{ .index = idx };
            job_count += 1;
        }
    }

    self.generation = self.loader.request(jobs[0..job_count]);
}

pub fn select(self: *App, index: usize) void {
    if (self.original) |original| {
        if (self.image) |im| im.deinit();
        self.storeThumb(self.selected, decoder.makeThumbnail(original) catch null);
        self.image_cache.put(self.selected, original, self.image_stamp);
        self.original = null;
    } else if (self.image) |im| self.image_cache.put(self.selected, im, self.image_stamp);
    self.modified = false;
    self.crop_mode = false;
    self.crop_drag = false;
    self.notice_len = 0;
    self.selected = index;
    self.image_stamp = cache_mod.Stamp.read(self.paths[index]);
    self.image = self.image_cache.take(index, self.image_stamp);
    self.error_message = null;
    self.view.reset();
    self.dragging = false;
    self.setTitle();
    self.queueRequests();
    if (!self.cached(index)) {
        if (self.image) |im| self.storeThumb(index, decoder.makeThumbnail(im) catch null);
    }
    self.revealSelected();
    self.requestThumbnails();
    self.dirty = true;
}

pub fn thumbCount(self: *const App) usize {
    return @min(self.count(), @as(usize, @intCast(std.math.clamp(@divTrunc(self.w - 20, 156), 1, 32))));
}

pub fn thumbStart(self: *const App) usize {
    const n = self.thumbCount();
    return @min(self.strip_start orelse (self.position() -| (n / 2)), self.count() - n);
}

pub fn thumbHeight(self: *const App) f64 {
    return if (self.h < 360) 56 else 84;
}

pub fn thumbRect(self: *const App, slot: usize) Rect {
    const n: f64 = @floatFromInt(self.thumbCount());
    const width = (@as(f64, @floatFromInt(self.w)) - 32 - (n - 1) * 12) / n;
    return .{ .x = (@as(f64, @floatFromInt(self.w)) - (width + 12) * n + 12) / 2 + @as(f64, @floatFromInt(slot)) * (width + 12), .y = @as(f64, @floatFromInt(self.h - 32)) - self.thumbHeight(), .w = width, .h = self.thumbHeight() };
}

pub fn cached(self: *const App, index: usize) bool {
    for (self.thumbs) |slot| if (slot) |t| {
        if (t.index == index) return true;
    };
    return false;
}

pub fn thumbImage(self: *const App, index: usize) ?decoder.Image {
    for (self.thumbs) |slot| if (slot) |t| {
        if (t.index == index) return t.image;
    };
    return null;
}

pub fn requestThumbnails(self: *App) void {
    // Resizing only changes thumbnail requests, never restarts the main decode.
    var jobs: [32]decoder.Job = undefined;
    var n: usize = 0;
    const start = self.thumbStart();
    for (start..start + self.thumbCount()) |pos| {
        const i = self.indexAt(pos);
        // Check only when the strip changes, not on every paint or motion.
        const stamp = cache_mod.Stamp.read(self.paths[i]);
        for (&self.thumbs) |*slot| if (slot.*) |t| {
            if (t.index == i and !std.meta.eql(t.stamp, stamp)) {
                if (t.image) |im| im.deinit();
                slot.* = null;
            }
        };
        if (!self.cached(i)) {
            if (i == self.selected) {
                if (self.image) |im| self.storeThumb(i, decoder.makeThumbnail(im) catch null);
            } else {
                jobs[n] = .{ .index = i, .thumbnail = true };
                n += 1;
            }
        }
    }
    self.thumbnail_generation = self.thumbnail_loader.request(jobs[0..n]);
}

pub fn sync(self: *App) void {
    self.syncOperation();
    if (self.closed) return;
    while (self.loader.take()) |result| {
        if (result.generation != self.generation) {
            if (result.image) |im| im.deinit();
        } else if (result.job.index == self.selected) {
            self.image = result.image;
            self.storeThumb(self.selected, if (self.image) |im| decoder.makeThumbnail(im) catch null else null);
            // Only cache pixels if the file remained unchanged throughout decoding.
            if (!std.meta.eql(self.image_stamp, cache_mod.Stamp.read(self.paths[self.selected]))) self.image_stamp = null;
            self.error_message = if (result.err) |err| switch (err) {
                error.ImageTooLarge => tr("Image exceeds the 32 megapixel preview limit"),
                error.UnsupportedImage => tr("Unsupported image, missing decoder, or file unavailable"),
                else => tr("Could not read this image"),
            } else null;
            self.dirty = true;
        } else {
            // Preloaded neighbor completed: cache it for instant display when navigated to
            if (result.image) |im| {
                const stamp = cache_mod.Stamp.read(self.paths[result.job.index]);
                if (std.meta.eql(stamp, result.stamp) and !self.cached(result.job.index)) {
                    self.storeThumbStamped(result.job.index, decoder.makeThumbnail(im) catch null, result.stamp);
                    self.dirty = true;
                }
                self.image_cache.put(result.job.index, im, if (std.meta.eql(stamp, result.stamp)) stamp else null);
            }
        }
    }
    while (self.thumbnail_loader.take()) |result| {
        if (result.generation != self.thumbnail_generation) {
            if (result.image) |im| im.deinit();
        } else {
            self.storeThumbStamped(result.job.index, result.image, result.stamp);
            self.dirty = true;
        }
    }
}

pub fn storeThumb(self: *App, index: usize, image: ?decoder.Image) void {
    self.storeThumbStamped(index, image, if (index == self.selected) self.image_stamp else cache_mod.Stamp.read(self.paths[index]));
}

pub fn storeThumbStamped(self: *App, index: usize, image: ?decoder.Image, stamp: ?cache_mod.Stamp) void {
    var slot: usize = self.thumbs.len - 1;
    for (self.thumbs, 0..) |entry, i| {
        if (entry == null) {
            slot = i;
            break;
        }
    }
    // Invalidated thumbnails leave holes; find an existing entry first.
    for (self.thumbs, 0..) |entry, i| {
        if (entry != null and entry.?.index == index) {
            slot = i;
            break;
        }
    }
    if (self.thumbs[slot]) |old| if (old.image) |im| im.deinit();
    var i = slot;
    while (i > 0) : (i -= 1) self.thumbs[i] = self.thumbs[i - 1];
    self.thumbs[0] = .{ .index = index, .image = image, .stamp = stamp };
}

pub fn stepAnimations(self: *App, now: i64) void {
    if (self.count() == 0) {
        self.animation_active = false;
        self.strip_appearance = .{};
        return;
    }
    const start = self.thumbStart();
    const pos = self.position();
    const visible = pos >= start and pos < start + self.thumbCount();
    self.selection_glide.setTarget(now, if (visible) .{ .col = @intCast(pos - start), .row = 0 } else null);
    const pitch: f32 = @floatCast(self.thumbRect(0).w + 12);
    if (self.selection_glide.step(now, 1 / (pitch * @as(f32, @floatFromInt(self.scale))), 1)) self.dirty = true;
    const bar = self.stripBar();
    const hovered = self.dialog == .none and if (bar) |b| b.overThumb(@floatCast(self.px), @floatCast(self.py)) else false;
    if (self.strip_appearance.step(now, start != self.strip_observed, hovered, self.strip_drag.active, bar != null)) self.dirty = true;
    self.strip_observed = start;
    self.animation_active = self.selection_glide.animating(now) or self.strip_appearance.active;
}

pub fn animationTimeout(self: *const App, now: i64) ?u32 {
    if (self.animation_active) return 16;
    if (self.strip_appearance.deadline) |deadline| return @intCast(std.math.clamp(deadline - now, 0, 60_000));
    return null;
}

/// The filmstrip's bar, centred in the margin under the thumbnails and
/// scrolling by thumbnail; null while they all fit.
pub fn stripBar(self: *const App) ?scrollbar.Geometry {
    if (self.count() == 0) return null;
    const strip = scrollbar.gutter(ui_theme.global.scrollbar_width);
    const track: scrollbar.Rect = .{ .x = 16, .y = @as(f32, @floatFromInt(self.h)) - 21 - strip / 2, .w = @floatFromInt(self.w - 32), .h = strip };
    return scrollbar.Geometry.compute(.horizontal, track, @floatFromInt(self.thumbCount()), @floatFromInt(self.count()), @floatFromInt(self.thumbStart()));
}

pub fn scrollStrip(self: *App, start: usize) void {
    const next = @min(start, self.count() - self.thumbCount());
    if (next == self.thumbStart()) return;
    self.strip_start = next;
    self.requestThumbnails();
    self.dirty = true;
}

pub fn dragStrip(self: *App, x: f64, y: f64) void {
    const bar = self.stripBar() orelse return;
    self.scrollStrip(@intFromFloat(@round(self.strip_drag.offsetAt(bar, @floatCast(x), @floatCast(y)))));
}
