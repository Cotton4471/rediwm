//! Input devices and client requests: new devices, virtual pointers, cursor and selection requests.

const std = @import("std");
const Input = @import("../Input.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Keyboard = @import("../Keyboard.zig");
const Pointer = @import("../Pointer.zig");
const log = std.log.scoped(.input);

/// Marks virtual-pointer-v1 devices in `wlr.InputDevice.data`.
var virtual_pointer_tag: u8 = 0;

pub fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const input: *Input = @fieldParentPtr("new_input", listener);
    input.addDevice(device);
}

/// wayvnc, KDE Connect and similar remote-input clients. Their pointer shares
/// the cursor with hardware, and like virtual keyboards never reaches the lock
/// screen or an authentication dialog (`blockedVirtual`).
pub fn newVirtualPointer(listener: *wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer), event: *wlr.VirtualPointerManagerV1.event.NewPointer) void {
    const input: *Input = @fieldParentPtr("new_virtual_pointer", listener);
    const device = &event.new_pointer.pointer.base;
    device.data = &virtual_pointer_tag;
    input.addDevice(device);
    if (event.suggested_output) |output| input.cursor.mapInputToOutput(device, output);
}

/// Lock surfaces of an ext-session-lock client follow the pointer; the
/// polkit dialog is not shown over a lock, but it keeps priority if it is.
pub fn lockClientMotion(input: *Input, time_msec: u32) void {
    if (input.server.polkit_dialog != null) return;
    const lock = input.server.locker orelse return;
    lock.pointerMoved(input.cursor.x, input.cursor.y);
    const client = lock.client orelse return;
    _ = client.pointerMotion(time_msec);
}

pub fn blockedVirtual(input: *const Input, device: *wlr.InputDevice) bool {
    return device.data == @as(?*anyopaque, &virtual_pointer_tag) and
        (input.server.locker != null or input.server.polkit_dialog != null);
}

pub fn addDevice(input: *Input, device: *wlr.InputDevice) void {
    switch (device.type) {
        .keyboard => Keyboard.create(input.server, device) catch |err| {
            log.err("newInput: could not create keyboard: {}", .{err});
            return;
        },
        .pointer => {
            input.cursor.attachInputDevice(device);
            Pointer.create(input, device) catch |err| {
                log.err("newInput: could not track pointer device: {}", .{err});
            };
        },
        .touch => input.touch.addDevice(device),
        .tablet => input.tablet.addTablet(device),
        .tablet_pad => input.tablet.addPad(device),
        .@"switch" => input.lid.addDevice(device),
    }
    input.updateCapabilities();
    @import("../session/greeter_ready.zig").check(input.server);
}

pub fn requestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    const input: *Input = @fieldParentPtr("request_set_cursor", listener);
    if (input.clientMaySetCursor(event.seat_client)) {
        input.default_cursor_applied = false;
        if (!input.cursor_held) input.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
        input.cursor_source = if (event.surface != null) .surface else .hidden;
        input.cursor_name = null;
    }
}

pub fn clientMaySetCursor(input: *Input, client: *wlr.Seat.Client) bool {
    return (input.server.locker == null and input.server.polkit_dialog == null) and input.server.screenshot_selector.output == null and input.cursor_mode == .passthrough and
        input.hovered_resize_edges == null and
        client == input.seat.pointer_state.focused_client;
}

pub fn requestSetShape(
    listener: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape),
    event: *wlr.CursorShapeManagerV1.event.RequestSetShape,
) void {
    const input: *Input = @fieldParentPtr("request_set_shape", listener);
    if (event.device_type != .pointer or !input.clientMaySetCursor(event.seat_client)) return;
    if (input.cursor_serial.enter_serial == null or event.serial != input.cursor_serial.enter_serial.?) return;

    const name = wlr.CursorShapeManagerV1.shapeName(event.shape);
    if (event.shape == .default or input.cursor_mgr.getXcursor(name, 1) == null) {
        input.setDefaultCursor();
    } else {
        input.setNamedCursor(name);
    }
}

pub fn requestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const input: *Input = @fieldParentPtr("request_set_selection", listener);
    if (input.server.locker != null or input.server.polkit_dialog != null) return;
    input.seat.setSelection(event.source, event.serial);
}

pub fn requestSetPrimarySelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection),
    event: *wlr.Seat.event.RequestSetPrimarySelection,
) void {
    const input: *Input = @fieldParentPtr("request_set_primary_selection", listener);
    if (input.server.locker != null or input.server.polkit_dialog != null) return;
    input.seat.setPrimarySelection(event.source, event.serial);
}
