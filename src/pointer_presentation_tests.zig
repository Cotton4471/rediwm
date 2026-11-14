const std = @import("std");
const presentation = @import("pointer_presentation.zig");
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "input tags identify touchpads, mice and trackballs without name guesses" {
    try expectEqual(.touchpad, presentation.classify(.{ .touchpad = true, .mouse = true }));
    try expectEqual(.trackball, presentation.classify(.{ .trackball = true, .mouse = true }));
    try expectEqual(.mouse, presentation.classify(.{ .mouse = true }));
    try expectEqual(.touchpad, presentation.classify(.{ .tap = true }));
    try expectEqual(.pointer, presentation.classify(.{}));
}

test "friendly device names retain real product names and have no event suffix" {
    const a = std.testing.allocator;
    const result = (try presentation.friendlyName(a, .{
        .primary = " Logitech MX Master 3S ",
        .vendor = "Generic vendor",
        .model = "USB_receiver",
    })).?;
    defer a.free(result);
    try expectEqualStrings("Logitech MX Master 3S", result);
}

test "unnamed devices use readable udev vendor and model names" {
    const a = std.testing.allocator;
    const result = (try presentation.friendlyName(a, .{
        .primary = " \n\t",
        .vendor = "Kensington",
        .model = "Expert_Mouse",
    })).?;
    defer a.free(result);
    try expectEqualStrings("Kensington Expert Mouse", result);
    const repeated = (try presentation.friendlyName(a, .{ .vendor = "Logitech", .model = "Logitech_MX_Ergo" })).?;
    defer a.free(repeated);
    try expectEqualStrings("Logitech MX Ergo", repeated);
}

test "presentation collapses control whitespace and leaves missing names unset" {
    const a = std.testing.allocator;
    const result = (try presentation.friendlyName(a, .{ .primary = "A\t\n Mouse\x7fDevice" })).?;
    defer a.free(result);
    try expectEqualStrings("A Mouse Device", result);
    try expectEqual(@as(?[]const u8, null), try presentation.friendlyName(a, .{}));
}
