const std = @import("std");
const Input = @import("Input.zig");
const Pointer = @import("Pointer.zig");
const identity = @import("pointer_identity.zig");

test "pointer selection tokens do not follow removal or reused storage" {
    var input: Input = undefined;
    input.pointers.init();
    var pointer: Pointer = .{ .input = &input, .device = undefined, .id = 1, .identity = null };
    input.pointers.append(&pointer);
    try std.testing.expect(Pointer.find(&input, 1) == &pointer);
    pointer.link.remove();
    try std.testing.expect(Pointer.find(&input, 1) == null);
    // Reusing exactly the same address must not revive a stale UI selection.
    pointer.id = 2;
    input.pointers.append(&pointer);
    try std.testing.expect(Pointer.find(&input, 1) == null);
    try std.testing.expect(Pointer.find(&input, 2) == &pointer);
    try std.testing.expect(pointer.persistentId() == null);
}

test "pointer identities reject live collisions and match distinct connection paths" {
    var input: Input = undefined;
    input.pointers.init();
    const facts: identity.Facts = .{ .bus = 3, .vendor = 1, .product = 2, .name = "Identical Mouse", .path = "pci-usb-1" };
    var other_facts = facts;
    other_facts.path = "pci-usb-2";
    var first: Pointer = .{ .input = &input, .device = undefined, .id = 1, .identity = identity.build(facts) };
    var second: Pointer = .{ .input = &input, .device = undefined, .id = 2, .identity = identity.build(other_facts) };
    input.pointers.append(&first);
    input.pointers.append(&second);
    try std.testing.expect(first.persistentId() != null);
    try std.testing.expect(second.persistentId() != null);
    try std.testing.expect(!std.mem.eql(u8, first.persistentId().?, second.persistentId().?));
    second.identity = first.identity;
    try std.testing.expect(first.persistentId() == null);
    try std.testing.expect(second.persistentId() == null);
    // Collision state remains conservative after one of the peers goes away.
    first.identity_ambiguous = true;
    second.link.remove();
    try std.testing.expect(first.persistentId() == null);
}
