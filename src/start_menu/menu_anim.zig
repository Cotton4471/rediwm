//! The frame tick, the selection and hover highlight glides, and the search caret.

const std = @import("std");
const anim = @import("ui").anim;
const ui = @import("ui");
const layout = ui.layout;
const Widget = layout.Widget;
const theme = ui.theme;
const Anim = anim.Anim;
const panel = @import("panel.zig");
const Highlights = panel.Highlights;
const row_pitch = panel.row_pitch;
const StartMenu = @import("StartMenu.zig");
const onRowClick = StartMenu.onRowClick;

pub fn tick(menu: *StartMenu, now_ms: i64) bool {
    // Before the caret check: this is what promotes `.opening` to `.open`
    // once the slide settles, and the caret only blinks while open.
    menu.applyPresentation(now_ms);
    const caret = menu.caretState(now_ms);
    // Both terms are edge-triggered on what would actually be drawn: a
    // blink repaints on a phase flip, a glide on a changed offset.
    // Repainting on "is animating" instead would cost a whole panel raster
    // per refresh for identical pixels — and under a pinned test clock,
    // where an in-flight glide never settles, it would repaint forever.
    const caret_quantum = anim.rasterPixelQuantum(menu.wlr_output.scale);
    if (menu.scroll_gliding) {
        const revision = ui.layout.paint_revision;
        menu.scroll_gliding = ui.widgets.scroll_container.stepGlides(&menu.root, now_ms, caret_quantum);
        if (revision != ui.layout.paint_revision) menu.dirty = true;
    }
    {
        const revision = ui.layout.paint_revision;
        menu.bars = ui.widgets.scroll_container.stepBars(&menu.root, now_ms);
        if (revision != ui.layout.paint_revision) menu.dirty = true;
    }
    const caret_moved = if (menu.dispatcher.caret.x.settled(now_ms))
        caret.offset != menu.caret_offset
    else
        @round(caret.offset / caret_quantum) != @round(menu.caret_offset / caret_quantum);
    if (caret.visible != menu.caret_shown or caret_moved) {
        menu.caret_shown = caret.visible;
        menu.caret_offset = caret.offset;
        if (menu.dispatcher.focused) |field| field.markPaintDirty();
        menu.dirty = true;
    }
    if (menu.stepHighlights(now_ms)) menu.dirty = true;
    if (menu.dirty) {
        menu.paintContent();
        // A blink phase flip or caret glide repaints without touching any
        // curve, so `sampleChanged` never sees it.
        anim.observeNoteChanged();
    }
    _ = menu.slide.sampleChanged(now_ms, anim.quantum_alpha);
    // The blink is a phase timer, not an Anim: it holds the output awake
    // for the whole timeout window and would otherwise report nothing.
    if (caret.animating) anim.observeNoteActive(menu.dispatcher.caret.last_edit_ms, now_ms);
    const animating = !menu.slide.settled(now_ms) or caret.animating or menu.scroll_gliding or menu.bars.pending() or
        !menu.sel_pos.settled(now_ms) or !menu.hover_pos.settled(now_ms) or !menu.hover_alpha.settled(now_ms);
    // A frozen test clock must not spin the output; the fixture advances
    // time and schedules the next frame itself. A failed paint stays dirty
    // so a later frame can retry.
    return menu.dirty or (animating and !anim.clockOverridden());
}

/// Samples the highlight glides; true when what would be painted (the
/// quantised position or opacity) changed, in which case the results list
/// repaints (only it). Edge-triggered on drawn state rather than on
/// `Anim.sampleChanged`: a jump of a pinned test clock must not repaint an
/// idle list.
pub fn stepHighlights(menu: *StartMenu, now_ms: i64) bool {
    const q = anim.rasterPixelQuantum(menu.wlr_output.scale) / row_pitch;
    const next: Highlights = .{
        .sel = quantised(menu.sel_pos, now_ms, q),
        .hover = quantised(menu.hover_pos, now_ms, q),
        .hover_alpha = quantised(menu.hover_alpha, now_ms, anim.rasterAlphaQuantum()),
    };
    if (std.meta.eql(next, menu.hl)) return false;
    menu.hl = next;
    if (menu.resultsScroll()) |scroll| scroll.markPaintDirty();
    return true;
}

/// In flight, snapped to `quantum`; at rest, the exact endpoint.
pub fn quantised(a: Anim, now_ms: i64, quantum: f32) f32 {
    const v = a.value(now_ms);
    return if (a.settled(now_ms)) v else @round(v / quantum) * quantum;
}

pub fn resultsScroll(menu: *StartMenu) ?*Widget {
    for (menu.root.children) |*kid| {
        if (std.meta.activeTag(kid.kind) == .scroll_container) return kid;
    }
    return null;
}

/// The selection glides only for keyboard navigation (`navigateResults`
/// retargets before rebuilding); any other change of selection or result
/// set jumps, since the rows underneath are different ones.
pub fn syncSelectionGlide(menu: *StartMenu) void {
    const index: f32 = @floatFromInt(menu.model.selected_index);
    if (menu.sel_pos.to != index) menu.sel_pos.cancel(index);
}

pub fn setHoverRow(menu: *StartMenu, row: ?usize) void {
    if (menu.hover_row == row) return;
    menu.hover_row = row;
    const now_ms = anim.nowMs();
    if (row) |r| {
        const pos: f32 = @floatFromInt(r);
        // Appear in place; only glide if the highlight is still visible.
        if (menu.hover_alpha.value(now_ms) <= 0.01) {
            menu.hover_pos.cancel(pos);
        } else {
            menu.hover_pos.retargetTo(now_ms, pos, anim.curveFor(.start_glide));
        }
        menu.hover_alpha.retargetTo(now_ms, 1, anim.curveFor(.start_glide_fade));
    } else {
        menu.hover_alpha.retargetTo(now_ms, 0, anim.curveFor(.start_glide_fade));
    }
    menu.wlr_output.scheduleFrame();
}

pub fn syncHoverRow(menu: *StartMenu) void {
    const row: ?usize = if (menu.dispatcher.hovered) |w| switch (w.kind) {
        .row => |data| if (data.owner == @as(?*anyopaque, menu) and data.on_click == onRowClick) data.id else null,
        else => null,
    } else null;
    menu.setHoverRow(row);
}

/// Scroll-container underlay: the selected and hover fills, drawn at
/// fractional row positions so they can sit between two rows mid-glide.
pub fn paintHighlights(owner: ?*anyopaque, scroll: *const Widget, renderer: *ui.paint.Renderer) void {
    const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
    const t = renderer.palette orelse theme.global;
    if (scroll.children.len == 0) return;
    if (menu.mode == .launcher) {
        for (scroll.children) |*row| renderer.fillRect(row.computed_x + 8, row.computed_y + row.computed_height + 1, @max(0, row.computed_width - 16), 1, .{ .color = t.border_soft });
    }
    // Fades out as it reaches the selected row, which draws its own fill.
    const apart = std.math.clamp(@abs(menu.hl.hover - menu.hl.sel), 0, 1);
    const hover_alpha = std.math.clamp(menu.hl.hover_alpha, 0, 1) * apart;
    if (hover_alpha > 0) {
        const box = rowBox(scroll, menu.hl.hover);
        renderer.fillRect(box.x, box.y, box.w, box.h, .{
            .color = scaleAlpha(t.surface_hover, hover_alpha),
            .radius = t.radius,
            .border_width = 1,
            .border_color = scaleAlpha(t.border_soft, hover_alpha),
        });
    }
    if (menu.model.results.len == 0 or menu.card_selection != null) return;
    const box = rowBox(scroll, menu.hl.sel);
    renderer.fillRect(box.x, box.y, box.w, box.h, .{
        .color = t.start_menu_selected_bg,
        .radius = t.radius,
        .border_width = 1,
        .border_color = t.start_menu_selected_border,
    });
    const marker_h = @max(10, box.h - 18);
    renderer.fillRect(box.x + 3, box.y + (box.h - marker_h) / 2, 3, marker_h, .{
        .color = t.start_menu_selected_marker,
        .radius = 1.5,
    });
}

pub const RowBox = struct { x: f32, y: f32, w: f32, h: f32 };

/// Rect of the (possibly fractional) row `pos`, interpolated between the
/// two neighbouring rows' actual layout so scrolling stays exact.
pub fn rowBox(scroll: *const Widget, pos: f32) RowBox {
    const last: f32 = @floatFromInt(scroll.children.len - 1);
    const clamped = std.math.clamp(pos, 0, last);
    const lo: usize = @intFromFloat(@floor(clamped));
    const hi = @min(lo + 1, scroll.children.len - 1);
    const f = clamped - @as(f32, @floatFromInt(lo));
    const a = &scroll.children[lo];
    const b = &scroll.children[hi];
    return .{
        .x = a.computed_x,
        .y = a.computed_y + (b.computed_y - a.computed_y) * f,
        .w = a.computed_width,
        .h = a.computed_height,
    };
}

pub fn scaleAlpha(color: [4]f32, k: f32) [4]f32 {
    return .{ color[0], color[1], color[2], color[3] * k };
}

/// Blink phase and whether the caret still wants frames. Idle unless a
/// text input actually has focus in a fully open menu: nothing blinks
/// mid-slide (the caret would be repainting the panel against its own
/// open/close animation, which is what `panel_present` exists to avoid),
/// and a menu with no focused field costs no frames at all — which is what
/// makes `caret_blink_timeout` able to stop the pump.
pub fn caretState(menu: *StartMenu, now_ms: i64) CaretState {
    const idle = CaretState{ .visible = menu.caret_shown, .offset = menu.caret_offset, .animating = false };
    if (menu.state != .open) return idle;
    const focused = menu.dispatcher.focused orelse return idle;
    if (std.meta.activeTag(focused.kind) != .text_input) return idle;
    return .{
        .visible = menu.dispatcher.caret.visible(now_ms),
        .offset = menu.dispatcher.caret.offset(now_ms),
        .animating = menu.dispatcher.caret.animating(now_ms),
    };
}

pub const CaretState = struct { visible: bool, offset: f32, animating: bool };
