//! Human-facing device descriptions. These never participate in identity or
//! configuration matching; udev's input tags determine the displayed kind.
const std = @import("std");

pub const Kind = enum { mouse, touchpad, trackball, pointer };

pub const Tags = struct {
    touchpad: bool = false,
    trackball: bool = false,
    mouse: bool = false,
    tap: bool = false,
};

pub fn classify(tags: Tags) Kind {
    if (tags.touchpad) return .touchpad;
    if (tags.trackball) return .trackball;
    if (tags.tap) return .touchpad;
    if (tags.mouse) return .mouse;
    return .pointer;
}

pub const Names = struct {
    primary: ?[]const u8 = null,
    vendor: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

/// Prefer the kernel/libinput's descriptive name. The udev model database is
/// only a fallback for unnamed devices, and never replaces an identity key.
pub fn friendlyName(a: std.mem.Allocator, names: Names) !?[]const u8 {
    if (try clean(a, names.primary, false)) |name| return name;
    const model = (try clean(a, names.model, true)) orelse return null;
    errdefer a.free(model);
    const vendor = (try clean(a, names.vendor, true)) orelse return model;
    defer a.free(vendor);
    if (std.ascii.startsWithIgnoreCase(model, vendor)) return model;
    const combined = try std.fmt.allocPrint(a, "{s} {s}", .{ vendor, model });
    a.free(model);
    return combined;
}

fn clean(a: std.mem.Allocator, input: ?[]const u8, underscores: bool) !?[]u8 {
    const text = input orelse return null;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var space = false;
    for (text) |byte| {
        if (byte <= ' ' or byte == 0x7f or (underscores and byte == '_')) {
            space = out.items.len > 0;
            continue;
        }
        if (space) try out.append(a, ' ');
        try out.append(a, byte);
        space = false;
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(a);
}

test {
    _ = @import("pointer_presentation_tests.zig");
}
