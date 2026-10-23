//! Rendering: shm buffers, the frame and the client-side titlebar.

const std = @import("std");
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const a = std.heap.c_allocator;
const main = @import("main.zig");
const Buffer = main.Buffer;
const Client = @import("Client.zig");

pub fn acquireBuffer(self: *Client, w: i32, h: i32) !*Buffer {
    var i: usize = 0;
    while (i < self.buffers.items.len) {
        const buffer = self.buffers.items[i];
        if (!buffer.busy and (buffer.w != w or buffer.h != h)) {
            _ = self.buffers.swapRemove(i);
            buffer.destroy();
        } else i += 1;
    }
    for (self.buffers.items) |buffer| {
        if (!buffer.busy) return buffer;
    }
    const buffer = try Buffer.create(self, w, h);
    errdefer buffer.destroy();
    try self.buffers.append(a, buffer);
    return buffer;
}

pub fn render(self: *Client) !void {
    if (!self.configured or !self.app.dirty or self.outstanding >= 2) return;

    const tbh = self.titlebarHeight();
    const w = self.app.w;
    const h = self.app.h + tbh;
    const bw = w * self.scale;
    const bh = h * self.scale;
    const buffer = try self.acquireBuffer(bw, bh);

    const partial = self.retained.items.len == buffer.len and self.retained_w == bw and self.applied_scale == self.scale and self.app.paint_damage != null;
    if (partial) {
        const pixels: [*]u8 = @ptrCast(buffer.memory);
        @memcpy(pixels[0..buffer.len], self.retained.items);
        c.cairo_surface_mark_dirty(buffer.image);
    }
    const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
    defer c.cairo_destroy(cr);

    c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));
    if (partial) {
        var rect = self.app.paint_damage.?;
        rect.y += @floatFromInt(tbh);
        app_mod.clipDamage(cr, rect);
    }

    if (tbh > 0) self.renderTitlebar(cr, w, tbh);

    c.cairo_save(cr);
    c.cairo_translate(cr, 0, @floatFromInt(tbh));
    self.app.render(cr);
    c.cairo_restore(cr);

    c.cairo_surface_flush(buffer.image);

    const bytes: []const u8 = @as([*]const u8, @ptrCast(buffer.memory))[0..buffer.len];
    var x1 = bw;
    var y1 = bh;
    var x2: i32 = 0;
    var y2: i32 = 0;
    if (self.retained.items.len != bytes.len or self.retained_w != bw or self.applied_scale != self.scale) {
        x1 = 0;
        y1 = 0;
        x2 = bw;
        y2 = bh;
    } else {
        // Compare against the last published image, never against this recycled buffer.
        const stride: usize = @intCast(bw * 4);
        for (0..@intCast(bh)) |row| {
            const offset = row * stride;
            if (std.mem.eql(u8, bytes[offset..][0..stride], self.retained.items[offset..][0..stride])) continue;
            y1 = @min(y1, @as(i32, @intCast(row)));
            y2 = @as(i32, @intCast(row + 1));
            var left: usize = 0;
            while (left < stride and std.mem.eql(u8, bytes[offset + left ..][0..4], self.retained.items[offset + left ..][0..4])) : (left += 4) {}
            var right = stride;
            while (right > left and std.mem.eql(u8, bytes[offset + right - 4 ..][0..4], self.retained.items[offset + right - 4 ..][0..4])) : (right -= 4) {}
            x1 = @min(x1, @as(i32, @intCast(left / 4)));
            x2 = @max(x2, @as(i32, @intCast(right / 4)));
        }
    }
    try self.retained.resize(a, bytes.len);
    @memcpy(self.retained.items, bytes);
    self.retained_w = bw;
    if (self.applied_scale != self.scale) {
        self.surface.setBufferScale(self.scale);
        self.applied_scale = self.scale;
    }
    if (x2 > x1 and y2 > y1) {
        self.xdg_surface.setWindowGeometry(0, 0, w, h);
        self.surface.attach(buffer.wl_buffer, 0, 0);
        self.surface.damageBuffer(x1, y1, x2 - x1, y2 - y1);
        self.surface.commit();
        buffer.busy = true;
        self.outstanding += 1;
    } else if (self.ack_uncommitted) {
        // Keep the attached buffer; the commit only applies the ack.
        self.xdg_surface.setWindowGeometry(0, 0, w, h);
        self.surface.commit();
    }
    self.ack_uncommitted = false;
    self.app.dirty = false;
}

pub fn renderTitlebar(self: *Client, cr: *c.cairo_t, w: i32, h: i32) void {
    const w_f: f64 = @floatFromInt(w);
    const h_f: f64 = @floatFromInt(h);

    shell_ui.setSource(cr, ui_theme.global.window_bg);
    c.cairo_rectangle(cr, 0, 0, w_f, h_f);
    c.cairo_fill(cr);

    shell_ui.setSource(cr, ui_theme.global.app_divider);
    c.cairo_set_line_width(cr, 1);
    c.cairo_move_to(cr, 0, h_f - 0.5);
    c.cairo_line_to(cr, w_f, h_f - 0.5);
    c.cairo_stroke(cr);

    const title = std.mem.span(self.app.getTitle());
    shell_ui.setSource(cr, ui_theme.global.window_fg);
    const tw = app_mod.measureText(cr, title, 12, true);
    app_mod.drawText(cr, title, (w_f - tw) / 2.0, h_f / 2.0 + 4, 12, true);

    const close_w: f64 = @min(h_f, 32);
    const hovered = self.inside and self.pointer_y < h_f and self.pointer_x >= w_f - close_w;
    if (hovered) {
        shell_ui.setSource(cr, ui_theme.global.window_close_hover);
        c.cairo_rectangle(cr, w_f - close_w, 0, close_w, h_f);
        c.cairo_fill(cr);
        c.cairo_set_source_rgb(cr, 1, 1, 1);
    } else {
        shell_ui.setSource(cr, ui_theme.global.window_dim);
    }
    const cx = w_f - close_w / 2.0;
    const cy = h_f / 2.0;
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_move_to(cr, cx - 5, cy - 5);
    c.cairo_line_to(cr, cx + 5, cy + 5);
    c.cairo_move_to(cr, cx + 5, cy - 5);
    c.cairo_line_to(cr, cx - 5, cy + 5);
    c.cairo_stroke(cr);
}
