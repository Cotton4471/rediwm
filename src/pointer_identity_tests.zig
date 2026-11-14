const std = @import("std");
const identity = @import("pointer_identity.zig");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

const mouse: identity.Facts = .{
    .bus = 3,
    .vendor = 0x046d,
    .product = 0xc077,
    .name = "Example mouse",
    .interface = "00",
};

test "persistent identity requires more than device name and model" {
    try expect(identity.build(mouse) == null);
    var empty = mouse;
    empty.serial = "";
    empty.uniq = "";
    empty.path = "";
    try expect(identity.build(empty) == null);
}

test "serial identity survives reconnect and port changes" {
    var first = mouse;
    first.serial = "A123";
    first.path = "pci-0000:00:14.0-usb-0:1:1.0";
    var reconnect = first;
    reconnect.path = "pci-0000:00:14.0-usb-0:5:1.0";
    const a = identity.build(first).?;
    const b = identity.build(reconnect).?;
    try expectEqualStrings(&a.key, &b.key);
    try expect(a.basis == .unique);
    try expectEqualStrings("pointer-v1:", a.key[0..11]);
    try expect(a.key.len == 75);
}

test "uniq is preferred over serial and changing connection paths" {
    var first = mouse;
    first.uniq = "11:22:33:44:55:66";
    first.serial = "receiver";
    var second = first;
    second.serial = "different-receiver";
    second.path = "different-port";
    const a = identity.build(first).?;
    const b = identity.build(second).?;
    try expectEqualStrings(&a.key, &b.key);
    second.uniq = "11:22:33:44:55:77";
    const other = identity.build(second).?;
    try expect(!std.mem.eql(u8, &a.key, &other.key));
}

test "identical unnumbered mice are distinguished by physical path" {
    var first = mouse;
    first.path = "pci-0000:00:14.0-usb-0:1:1.0";
    var second = first;
    second.path = "pci-0000:00:14.0-usb-0:2:1.0";
    const a = identity.build(first).?;
    const b = identity.build(second).?;
    try expect(a.basis == .path);
    try expect(!std.mem.eql(u8, &a.key, &b.key));
    const reconnected = identity.build(first).?;
    try expectEqualStrings(&a.key, &reconnected.key);
}

test "serials do not alias other models or logical interfaces" {
    var first = mouse;
    first.serial = "123";
    const a = identity.build(first).?;
    inline for (.{ "vendor", "product", "bus" }) |field| {
        var second = first;
        @field(second, field) += 1;
        const b = identity.build(second).?;
        try expect(!std.mem.eql(u8, &a.key, &b.key));
    }
    var second = first;
    second.interface = "01";
    const b = identity.build(second).?;
    try expect(!std.mem.eql(u8, &a.key, &b.key));
    second = first;
    second.name = "Different mouse";
    const c = identity.build(second).?;
    try expect(!std.mem.eql(u8, &a.key, &c.key));
}

test "identity frames strings rather than joining with delimiters" {
    var first = mouse;
    first.serial = "serial:123";
    first.interface = "01";
    var second = first;
    second.serial = "serial";
    second.interface = "123:01";
    const a = identity.build(first).?;
    const b = identity.build(second).?;
    try expect(!std.mem.eql(u8, &a.key, &b.key));
}
