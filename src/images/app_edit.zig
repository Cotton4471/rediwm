//! Editing: pending close or select, replacing the image, undo and cropping.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const decoder = @import("loader.zig");
const view = @import("view.zig");
const Rect = view.Rect;
const edit = @import("edit.zig");
const ui_theme = @import("ui").theme;
const app_mod = @import("app.zig");
const App = app_mod.App;
const setSource = app_mod.setSource;

pub fn requestClose(self: *App) void {
    if (self.operation != null) {
        self.message(tr("Please wait for the file operation to finish."));
        return;
    }
    self.cancelDrag();
    if (self.modified or self.hasCropSelection()) {
        self.pending = .close;
        self.dialog = .discard;
        self.notice_len = 0;
        self.dirty = true;
    } else self.closed = true;
}

pub fn requestSelect(self: *App, index: usize) void {
    if (index == self.selected or self.operation != null) return;
    self.cancelDrag();
    if (self.modified or self.hasCropSelection()) {
        self.pending = .{ .select = index };
        self.dialog = .discard;
        self.notice_len = 0;
        self.dirty = true;
    } else self.select(index);
}

pub fn finishPending(self: *App) void {
    const pending = self.pending;
    self.pending = .none;
    self.dialog = .none;
    switch (pending) {
        .none => {},
        .close => self.closed = true,
        .select => |index| self.select(index),
    }
    self.dirty = true;
}

pub fn replaceImage(self: *App, image: decoder.Image) void {
    self.cancelDrag();
    if (self.original == null) self.original = self.image else if (self.image) |im| im.deinit();
    self.image = image;
    self.modified = true;
    self.crop_mode = false;
    self.crop_drag = false;
    self.view.reset();
    self.storeThumb(self.selected, decoder.makeThumbnail(image) catch null);
    self.notice_len = 0;
    self.setTitle();
    self.dirty = true;
}

pub fn undo(self: *App) void {
    const original = self.original orelse return;
    if (self.image) |im| im.deinit();
    self.image = original;
    self.original = null;
    self.modified = false;
    self.crop_mode = false;
    self.crop_drag = false;
    self.view.reset();
    self.storeThumb(self.selected, decoder.makeThumbnail(original) catch null);
    self.message(tr("Edits undone."));
    self.setTitle();
}

pub fn imageRect(self: *const App) Rect {
    const box = self.canvas();
    const im = self.image orelse return box;
    const z = self.view.scale(box, @floatFromInt(im.w), @floatFromInt(im.h));
    const w = @as(f64, @floatFromInt(im.w)) * z;
    const h = @as(f64, @floatFromInt(im.h)) * z;
    return .{ .x = box.x + (box.w - w) / 2 + self.view.pan_x, .y = box.y + (box.h - h) / 2 + self.view.pan_y, .w = w, .h = h };
}

pub fn imagePoint(self: *const App, x: f64, y: f64) [2]f64 {
    const im = self.image.?;
    const r = self.imageRect();
    return .{ std.math.clamp((x - r.x) * @as(f64, @floatFromInt(im.w)) / r.w, 0, @as(f64, @floatFromInt(im.w))), std.math.clamp((y - r.y) * @as(f64, @floatFromInt(im.h)) / r.h, 0, @as(f64, @floatFromInt(im.h))) };
}

pub fn beginCrop(self: *App) void {
    const im = self.image orelse return;
    self.crop_mode = true;
    self.view.reset();
    self.dragging = false;
    self.crop_rect = .{ .x = 0, .y = 0, .w = @floatFromInt(im.w), .h = @floatFromInt(im.h) };
    self.notice_len = 0;
    self.dirty = true;
}

pub fn hasCropSelection(self: *const App) bool {
    const im = self.image orelse return false;
    const r = self.crop_rect;
    return self.crop_mode and r.w >= 1 and r.h >= 1 and
        (r.x >= 1 or r.y >= 1 or @ceil(r.x + r.w) < @as(f64, @floatFromInt(im.w)) or @ceil(r.y + r.h) < @as(f64, @floatFromInt(im.h)));
}

pub fn applyCrop(self: *App) void {
    const im = self.image orelse return;
    const r = self.crop_rect;
    const x: i32 = @intFromFloat(@floor(r.x));
    const y: i32 = @intFromFloat(@floor(r.y));
    const w: i32 = @min(im.w, @as(i32, @intFromFloat(@ceil(r.x + r.w)))) - x;
    const h: i32 = @min(im.h, @as(i32, @intFromFloat(@ceil(r.y + r.h)))) - y;
    if (r.w < 1 or r.h < 1) {
        self.message(tr("Drag a larger crop selection."));
        return;
    }
    if (x == 0 and y == 0 and w == im.w and h == im.h) {
        self.crop_mode = false;
        self.dirty = true;
        return;
    }
    self.replaceImage(edit.crop(im, x, y, w, h) catch {
        self.message(tr("Could not crop this selection."));
        return;
    });
}

pub fn drawCrop(self: *const App, cr: *c.cairo_t) void {
    const im = self.image orelse return;
    const image = self.imageRect();
    const z = image.w / @as(f64, @floatFromInt(im.w));
    const r = Rect{ .x = image.x + self.crop_rect.x * z, .y = image.y + self.crop_rect.y * z, .w = self.crop_rect.w * z, .h = self.crop_rect.h * z };
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    const box = self.canvas();
    c.cairo_rectangle(cr, box.x, box.y, box.w, box.h);
    c.cairo_clip(cr);
    c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_EVEN_ODD);
    c.cairo_rectangle(cr, image.x, image.y, image.w, image.h);
    c.cairo_rectangle(cr, r.x, r.y, r.w, r.h);
    setSource(cr, ui_theme.global.image_crop_shade);
    c.cairo_fill(cr);
    setSource(cr, ui_theme.global.image_crop_border);
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_rectangle(cr, r.x, r.y, r.w, r.h);
    c.cairo_stroke(cr);
    setSource(cr, ui_theme.global.image_crop_grid);
    c.cairo_set_line_width(cr, 1);
    for (1..3) |n| {
        const f = @as(f64, @floatFromInt(n)) / 3;
        c.cairo_move_to(cr, r.x + r.w * f, r.y);
        c.cairo_line_to(cr, r.x + r.w * f, r.y + r.h);
        c.cairo_move_to(cr, r.x, r.y + r.h * f);
        c.cairo_line_to(cr, r.x + r.w, r.y + r.h * f);
    }
    c.cairo_stroke(cr);
}
