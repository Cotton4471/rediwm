// Tracks pointer identity and settings for the lifetime of a connected device.
// Cursor motion itself is handled by wlr.Cursor directly.
const std = @import("std");
const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const Input = @import("Input.zig");
const gpa = @import("main.zig").gpa;
const libinput = @import("libinput.zig");
const identity_mod = @import("pointer_identity.zig");
const config_apply = @import("config_runtime/apply.zig");

const Pointer = @This();

input: *Input,
link: wl.list.Link = undefined,
device: *wlr.InputDevice,
id: u64,
identity: ?identity_mod.Identity,
/// Once a key collides, removing one peer cannot prove which device remains.
identity_ambiguous: bool = false,

destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),

pub fn create(input: *Input, device: *wlr.InputDevice) !void {
    const pointer = try gpa.create(Pointer);
    errdefer gpa.destroy(pointer); // listener add below is infallible; this covers any later try
    const id = input.next_pointer_id;
    input.next_pointer_id = std.math.add(u64, id, 1) catch return error.PointerIdExhausted;
    pointer.* = .{ .input = input, .device = device, .id = id, .identity = libinput.getIdentity(device) };
    device.events.destroy.add(&pointer.destroy);
    input.pointers.append(pointer);
    pointer.markIdentityCollisions();
    config_apply.applyPointerDevice(pointer);
    // A second indistinguishable device invalidates the first device's match,
    // too. Reset just those peers to defaults rather than sharing an override.
    pointer.reapplyIdentityPeers();
    refreshSettings(input);
}

pub fn find(input: *Input, id: u64) ?*Pointer {
    var it = input.pointers.iterator(.forward);
    while (it.next()) |pointer| if (pointer.id == id) return pointer;
    return null;
}

/// The returned key borrows this live Pointer, never the configuration arena.
/// Ambiguous keys must neither read nor write a persisted device override.
pub fn persistentId(pointer: *const Pointer) ?[]const u8 {
    if (pointer.identity_ambiguous) return null;
    const identity = if (pointer.identity) |*value| value else return null;
    var it = pointer.input.pointers.iterator(.forward);
    while (it.next()) |other| {
        if (other == pointer) continue;
        if (other.identity) |other_identity| {
            if (std.mem.eql(u8, &identity.key, &other_identity.key)) return null;
        }
    }
    return &identity.key;
}

fn markIdentityCollisions(pointer: *Pointer) void {
    const identity = pointer.identity orelse return;
    var it = pointer.input.pointers.iterator(.forward);
    while (it.next()) |other| {
        if (other == pointer) continue;
        if (other.identity) |other_identity| {
            if (std.mem.eql(u8, &identity.key, &other_identity.key)) {
                pointer.identity_ambiguous = true;
                other.identity_ambiguous = true;
            }
        }
    }
}

fn reapplyIdentityPeers(pointer: *const Pointer) void {
    const identity = pointer.identity orelse return;
    var it = pointer.input.pointers.iterator(.forward);
    while (it.next()) |other| {
        if (other == pointer) continue;
        if (other.identity) |other_identity| {
            if (std.mem.eql(u8, &identity.key, &other_identity.key)) config_apply.applyPointerDevice(other);
        }
    }
}

fn refreshSettings(input: *Input) void {
    if (input.open_control_center) |cc| {
        if (cc.showingPage(.input)) cc.refresh();
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const pointer: *Pointer = @fieldParentPtr("destroy", listener);
    if (pointer.input.zoom_device == pointer.device) {
        pointer.input.zoom_scroll.reset();
        pointer.input.zoom_device = null;
    }
    // Nested backends can destroy and recreate the pointer object mid-gesture
    // (e.g. when the cursor leaves and re-enters the host window), even while
    // a button is still physically held. Motion/release handling elsewhere
    // doesn't care which device delivers events, so as long as another
    // pointer remains to carry the gesture forward, just drop the stale
    // device identity instead of ending the gesture out from under the user
    // — killing it here silently converts an in-progress pan/resize to plain
    // passthrough with no way to resume short of releasing and reinitiating.
    // Only when this is the last pointer left (no device could ever deliver
    // a follow-up event again) do we tear the gesture down for real.
    const last_pointer = pointer.input.pointers.length() <= 1;
    if (pointer.input.resize_session) |*session| {
        if (session.initiating_device == pointer.device) {
            if (last_pointer) {
                pointer.input.cancelResize();
            } else {
                session.initiating_device = null;
            }
        }
    }
    if (pointer.input.pan_session) |*session| {
        if (session.initiating_device == pointer.device) {
            if (last_pointer) {
                pointer.input.endPan();
                pointer.input.pan_session = null;
            } else {
                session.initiating_device = null;
            }
        }
    }
    // Releases for this device will never arrive. Only force-clear button
    // state when no remaining device could ever deliver the matching
    // release — otherwise a still-held button is correctly left counted.
    if (last_pointer) {
        pointer.input.active_buttons = 0;
    }
    pointer.link.remove();
    pointer.destroy.link.remove();
    refreshSettings(pointer.input);
    gpa.destroy(pointer);
}

test {
    _ = @import("pointer_tests.zig");
}
