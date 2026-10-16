//! Input drag and drop: start, icon, cancel and tiling grab end.

const std = @import("std");
const Input = @import("../Input.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

pub fn positionDragIcon(input: *Input) void {
    if (input.drag_icon_tree) |tree| {
        tree.node.setPosition(@intFromFloat(@floor(input.cursor.x)), @intFromFloat(@floor(input.cursor.y)));
    }
}

pub fn startDrag(listener: *wl.Listener(*wlr.Drag), drag: *wlr.Drag) void {
    const input: *Input = @fieldParentPtr("start_drag", listener);
    input.drag_dodge.begin(drag);
    if (drag.grab_type != .keyboard_pointer) return;
    const icon = drag.icon orelse return;
    if (input.drag_icon_tree) |tree| tree.node.destroy();
    // wlroots gives drag icons an empty input region, so they cannot steal
    // the drop target. This tree stays in output coordinates, outside the camera.
    const tree = input.server.overlay_tree.createSceneDragIcon(icon) catch return;
    input.drag_icon_tree = tree;
    tree.node.events.destroy.add(&input.drag_icon_destroy);
    input.positionDragIcon();
}

/// Escape during a drag abandons it. Destroying the source tells its client the
/// drag was cancelled, and ending the grab then leaves the target, hides the
/// icon and forgets the drag. The button is still held; its release reaches
/// the client under the pointer like any other, so nothing is dropped.
pub fn finishTilingGrab(input: *Input, commit: bool) void {
    @import("../tiling_grab.zig").finish(input, commit);
}

pub fn cancelDrag(input: *Input) bool {
    if (input.dock_drag.active()) {
        input.dock_drag.cancel(input);
        return true;
    }
    if (input.tiling_grab != null) {
        input.finishTilingGrab(false);
        input.processCursorMotion(0);
        return true;
    }
    const drag = input.seat.drag orelse return false;
    if (drag.grab_type != .keyboard_pointer) return false;
    if (drag.source) |source| source.destroy();
    input.seat.pointerEndGrab();
    return true;
}

pub fn dragIconDestroyed(listener: *wl.Listener(void)) void {
    const input: *Input = @fieldParentPtr("drag_icon_destroy", listener);
    input.drag_icon_destroy.link.remove();
    input.drag_icon_tree = null;
}

pub fn requestStartDrag(listener: *wl.Listener(*wlr.Seat.event.RequestStartDrag), event: *wlr.Seat.event.RequestStartDrag) void {
    const input: *Input = @fieldParentPtr("request_start_drag", listener);
    if (input.server.locker != null or input.server.polkit_dialog != null) {
        if (event.drag.source) |source| source.destroy();
        return;
    }
    if (input.seat.validatePointerGrabSerial(event.origin, event.serial)) {
        input.seat.startPointerDrag(event.drag, event.serial);
    } else if (event.drag.source) |source| source.destroy();
}
