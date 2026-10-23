//! Pointer input and the buttons' click callbacks.

const anim = @import("ui").anim;
const Output = @import("../Output.zig");
const ui = @import("ui");
const StartMenu = @import("StartMenu.zig");
const onCardClick = StartMenu.onCardClick;

pub fn onRowClick(owner: ?*anyopaque, id: usize) void {
    if (owner) |o| {
        const menu: *StartMenu = @ptrCast(@alignCast(o));
        menu.model.selected_index = id;
        menu.activateResult(id);
    }
}

pub fn onCategoryAll(owner: ?*anyopaque, _: usize) void {
    const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
    const snap = menu.server.start_menu_catalog.retainSnapshot();
    defer snap.release();
    menu.model.setCategorySnapshot(.all, snap) catch {};
    menu.buildTree();
    menu.requestRepaint();
}

pub fn onCategoryApps(owner: ?*anyopaque, _: usize) void {
    const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
    const snap = menu.server.start_menu_catalog.retainSnapshot();
    defer snap.release();
    menu.model.setCategorySnapshot(.apps, snap) catch {};
    menu.buildTree();
    menu.requestRepaint();
}

pub fn onSettingsButtonClick(owner: ?*anyopaque, _: usize) void {
    const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
    if (Output.fromWlr(menu.wlr_output)) |output| {
        output.closeStartMenu();
        output.toggleControlCenter();
    }
}

pub fn onPowerButtonClick(owner: ?*anyopaque, _: usize) void {
    const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
    if (Output.fromWlr(menu.wlr_output)) |output| {
        output.closeStartMenu();
        output.openPowerMenu();
    }
}

pub fn pointerMotion(menu: *StartMenu, sx: f64, sy: f64) void {
    const revision = ui.layout.paint_revision;
    menu.dispatcher.pointerMotion(&menu.root, @floatCast(sx), @floatCast(sy));
    menu.syncHoverRow();
    // A click or a drag-select moves the caret, and the next
    // rebuild would otherwise put it back at the end.
    menu.syncQueryState();
    if (revision != ui.layout.paint_revision) menu.requestWidgetRepaint();
}

/// The application whose row or card the pointer is held down on, which
/// can be dragged to the dock. Valid until the results change.
pub fn pressedApp(menu: *StartMenu) ?struct { id: []const u8, icon: ?[]const u8 } {
    const widget = menu.dispatcher.pressed orelse return null;
    const index = switch (widget.kind) {
        .row => |data| if (data.owner == @as(?*anyopaque, menu) and (data.on_click == onRowClick or data.on_click == onCardClick)) data.id else return null,
        else => return null,
    };
    if (index >= menu.model.results.len) return null;
    const result = menu.model.results[index];
    if (result.app_entry == null) return null;
    return .{ .id = result.id, .icon = result.icon };
}

/// A press became a drag: rebuild so no row stays pressed and the release
/// is not a click.
pub fn cancelPress(menu: *StartMenu) void {
    const scroll = menu.currentScrollOffset();
    menu.buildTree();
    menu.restoreScrollOffset(scroll);
    menu.requestRepaint();
}

pub fn pointerButtonDown(menu: *StartMenu, sx: f64, sy: f64) void {
    menu.dispatcher.pointerButtonDown(&menu.root, @floatCast(sx), @floatCast(sy));
    // A click or a drag-select moves the caret, and the next
    // rebuild would otherwise put it back at the end.
    menu.syncQueryState();
    menu.requestRepaint();
}

/// The pointer is over something else: the scrollbar thumb stops being hovered.
pub fn pointerLeave(menu: *StartMenu) void {
    const revision = ui.layout.paint_revision;
    menu.dispatcher.pointerLeave(&menu.root);
    if (revision != ui.layout.paint_revision) menu.requestWidgetRepaint();
}

pub fn pointerButtonUp(menu: *StartMenu, sx: f64, sy: f64) void {
    menu.dispatcher.pointerButtonUp(&menu.root, @floatCast(sx), @floatCast(sy));
    // A click or a drag-select moves the caret, and the next
    // rebuild would otherwise put it back at the end.
    menu.syncQueryState();
    menu.requestRepaint();
}

/// `notch` is a detented wheel click, which glides; see `Dispatcher.scrollWheel`.
pub fn scrollWheel(menu: *StartMenu, sx: f64, sy: f64, delta_px: f32, notch: bool) void {
    const revision = ui.layout.paint_revision;
    if (menu.dispatcher.scrollWheel(&menu.root, @floatCast(sx), @floatCast(sy), delta_px, if (notch) anim.nowMs() else null)) {
        menu.scroll_gliding = true;
        menu.wlr_output.scheduleFrame();
    }
    if (revision != ui.layout.paint_revision) menu.requestWidgetRepaint();
}

pub fn containsPoint(menu: *StartMenu, lx: f64, ly: f64) bool {
    const box = menu.panel_box;
    return lx >= @as(f64, @floatFromInt(box.x)) and lx < @as(f64, @floatFromInt(box.x + box.width)) and
        ly >= @as(f64, @floatFromInt(box.y)) and ly < @as(f64, @floatFromInt(box.y + box.height));
}
