const std = @import("std");
const wlr = @import("wlr.zig");

test "initializing and finishing embedded input devices preserves adjacent storage" {
    const Guarded = extern struct {
        before: u64,
        pointer: wlr.Pointer,
        between: u64,
        keyboard: wlr.Keyboard,
        after: u64,
    };
    const sentinel: u64 = 0x8192_a3b4_c5d6_e7f8;
    var guarded: Guarded = .{
        .before = sentinel,
        .pointer = undefined,
        .between = sentinel,
        .keyboard = undefined,
        .after = sentinel,
    };
    const pointer_impl: wlr.Pointer.Impl = .{ .name = "binding-test-pointer" };
    const keyboard_impl: wlr.Keyboard.Impl = .{ .name = "binding-test-keyboard" };
    wlr.Pointer.init(&guarded.pointer, &pointer_impl, "binding-test-pointer");
    wlr.Keyboard.init(&guarded.keyboard, &keyboard_impl, "binding-test-keyboard");
    const initialized = guarded.before == sentinel and guarded.between == sentinel and guarded.after == sentinel;
    wlr.Pointer.finish(&guarded.pointer);
    wlr.Keyboard.finish(&guarded.keyboard);
    try std.testing.expect(initialized);
    try std.testing.expectEqual(sentinel, guarded.before);
    try std.testing.expectEqual(sentinel, guarded.between);
    try std.testing.expectEqual(sentinel, guarded.after);
}
