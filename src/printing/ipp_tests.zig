const std = @import("std");
const ipp = @import("ipp.zig");
const testing = std.testing;

const header = "\x02\x00\x00\x00\x00\x00\x00\x07";
const collection =
    "\x34\x00\x09media-col\x00\x00" ++
    "\x4a\x00\x00\x00\x0amedia-size" ++
    "\x34\x00\x00\x00\x00" ++
    "\x4a\x00\x00\x00\x0bx-dimension" ++
    "\x21\x00\x00\x00\x04\x00\x00\x52\x08" ++
    "\x37\x00\x00\x00\x00" ++
    "\x37\x00\x00\x00\x00";

test "IPP Get-Printers encoding matches wire bytes" {
    var encoder = try ipp.Encoder.init(testing.allocator, 0x4002, 7);
    defer encoder.deinit();
    try encoder.group(.operation);
    try encoder.string(.charset, "attributes-charset", "utf-8");
    try encoder.string(.natural_language, "attributes-natural-language", "en");
    try encoder.string(.keyword, "requested-attributes", "printer-name");
    try encoder.string(.keyword, "", "printer-state");
    const bytes = try encoder.finish();
    try testing.expectEqualStrings(
        "\x01\x01\x40\x02\x00\x00\x00\x07\x01" ++
            "\x47\x00\x12attributes-charset\x00\x05utf-8" ++
            "\x48\x00\x1battributes-natural-language\x00\x02en" ++
            "\x44\x00\x14requested-attributes\x00\x0cprinter-name" ++
            "\x44\x00\x00\x00\x0dprinter-state\x03",
        bytes,
    );
    try testing.expectEqualSlices(u8, bytes, try encoder.finish());
    var message = try ipp.decode(testing.allocator, bytes, .{});
    defer message.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 0x4002), message.code);
    try testing.expectEqual(@as(i32, 7), message.request_id);
    try testing.expectEqual(@as(usize, 4), message.attributes.len);
    try testing.expectEqualStrings("requested-attributes", message.attributes[3].name);
}

test "IPP repeated printer groups and continuation values stay separate" {
    const bytes = header ++ "\x01\x04" ++
        "\x42\x00\x0cprinter-name\x00\x03one" ++
        "\x23\x00\x0dprinter-state\x00\x04\x00\x00\x00\x03" ++
        "\x44\x00\x15printer-state-reasons\x00\x04none" ++
        "\x44\x00\x00\x00\x09toner-low" ++
        "\x04\x42\x00\x0cprinter-name\x00\x03two\x03payload";
    var message = try ipp.decode(testing.allocator, bytes, .{});
    defer message.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), message.group_count);
    try testing.expectEqual(@as(usize, 5), message.attributes.len);
    try testing.expectEqual(@as(usize, 1), message.attributes[0].group_index);
    try testing.expectEqual(@as(usize, 2), message.attributes[4].group_index);
    try testing.expectEqualStrings("printer-state-reasons", message.attributes[3].name);
    try testing.expectEqual(@as(?i32, 3), message.attributes[1].integer());
    try testing.expectEqualStrings("payload", message.data);
}

test "IPP duplicate named attributes require explicit compatibility and retain every bounded record" {
    var encoder = try ipp.Encoder.init(testing.allocator, 0, 7);
    defer encoder.deinit();
    try encoder.group(.operation);
    try encoder.group(.printer);
    try encoder.string(.name, "printer-resolution-default", "203dpi");
    const resolution = "\x00\x00\x01\x2c\x00\x00\x01\x2c\x03";
    try encoder.value(.resolution, "printer-resolution-default", resolution);
    try encoder.string(.keyword, "media-supported", "iso_a4_210x297mm");
    try encoder.string(.keyword, "", "na_letter_8.5x11in");
    const bytes = try encoder.finish();
    try testing.expectError(error.InvalidMessage, ipp.decode(testing.allocator, bytes, .{}));
    var message = try ipp.decode(testing.allocator, bytes, .{ .allow_duplicate_names = true });
    defer message.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), message.attributes.len);
    try testing.expectEqualStrings("203dpi", message.attributes[0].text().?);
    try testing.expectEqual(@as(i32, 300), message.attributes[1].resolution().?.x);
    try testing.expectEqualStrings(message.attributes[0].name, message.attributes[1].name);
    try testing.expectEqualStrings(message.attributes[2].name, message.attributes[3].name);
    try testing.expectEqual(message.attributes[0].group_index, message.attributes[1].group_index);
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .allow_duplicate_names = true, .max_attributes = 3 }));
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .allow_duplicate_names = true, .max_groups = 1 }));
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .allow_duplicate_names = true, .max_value = 5 }));
}

test "IPP bounded collections preserve following scalar attributes" {
    const bytes = header ++ "\x01\x04" ++ collection ++
        "\x34\x00\x00\x00\x00\x37\x00\x00\x00\x00" ++
        "\x42\x00\x0cprinter-name\x00\x03two\x03";
    var message = try ipp.decode(testing.allocator, bytes, .{});
    defer message.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), message.attributes.len);
    try testing.expectEqual(ipp.Tag.begin_collection, message.attributes[0].tag);
    try testing.expectEqualStrings(collection[14..], message.attributes[0].value);
    try testing.expectEqualStrings("media-col", message.attributes[1].name);
    try testing.expectEqualStrings("two", message.attributes[2].text().?);
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .max_collection_depth = 1 }));
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .max_attributes = 4 }));
}

test "IPP numeric and localized text accessors" {
    var encoder = try ipp.Encoder.initVersion(testing.allocator, .{ 2, 2 }, 0, 1);
    defer encoder.deinit();
    try encoder.group(.operation);
    try encoder.group(.printer);
    try encoder.integer(.integer, "marker-levels", -1);
    try encoder.boolean("printer-is-accepting-jobs", true);
    try encoder.value(.resolution, "printer-resolution-default", &.{ 0, 0, 0, 203, 0, 0, 0, 203, 3 });
    try encoder.value(.range, "copies-supported", &.{ 0, 0, 0, 1, 0, 0, 0, 99 });
    try encoder.value(.text_with_language, "printer-info", "\x00\x02en\x00\x05Hello");
    var message = try ipp.decode(testing.allocator, try encoder.finish(), .{});
    defer message.deinit(testing.allocator);
    try testing.expectEqual(@as(?i32, -1), message.attributes[0].integer());
    try testing.expectEqual(@as(?bool, true), message.attributes[1].boolean());
    try testing.expectEqual(@as(i32, 203), message.attributes[2].resolution().?.x);
    try testing.expectEqual(@as(i32, 99), message.attributes[3].range().?.upper);
    try testing.expectEqualStrings("Hello", message.attributes[4].text().?);
    try testing.expect(message.attributes[0].text() == null);
    try testing.expect(message.attributes[1].integer() == null);
}

test "IPP every truncated prefix fails without leaking" {
    const bytes = header ++ "\x01\x04" ++ collection ++ "\x03";
    for (0..bytes.len) |length| {
        if (ipp.decode(testing.allocator, bytes[0..length], .{})) |value| {
            var message = value;
            defer message.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "IPP rejects malformed groups names values and collections" {
    const invalid = [_][]const u8{
        // Missing operation group, reserved delimiter, attributes outside a group.
        "\x04\x03",
        "\x00\x03",
        "\x21\x00\x01a\x00\x04\x00\x00\x00\x00\x03",
        "\x01\x04\x01\x03",
        "\x01\x44\x00\x00\x00\x01a\x03",
        "\x01\x44\x00\x01A\x00\x01a\x03",
        "\x01\x44\x00\x01a\x00\x01a\x44\x00\x01a\x00\x01b\x03",
        "\x01\x44\x00\x01a\x00\x01a\x04\x44\x00\x00\x00\x01b\x03",
        "\x01\x21\x00\x01a\x00\x01a\x03",
        "\x01\x22\x00\x01a\x00\x01\x02\x03",
        "\x01\x12\x00\x01a\x00\x01a\x03",
        "\x01\x41\x00\x01a\x00\x02\xc0\xaf\x03",
        "\x01\x42\x00\x01a\x00\x01\x00\x03",
        "\x01\x35\x00\x01a\x00\x07\x00\x02en\x00\x05x\x03",
        "\x01\x7f\x00\x01a\x00\x01a\x03",
        "\x01\x37\x00\x00\x00\x00\x03",
        "\x01\x4a\x00\x00\x00\x01a\x03",
        "\x01\x34\x00\x01a\x00\x00\x03",
        "\x01\x34\x00\x01a\x00\x01a\x37\x00\x00\x00\x00\x03",
        "\x01\x34\x00\x01a\x00\x00\x21\x00\x00\x00\x04\x00\x00\x00\x00\x37\x00\x00\x00\x00\x03",
        "\x01\x34\x00\x01a\x00\x00\x4a\x00\x00\x00\x01a\x37\x00\x00\x00\x00\x03",
    };
    inline for (invalid) |suffix| try testing.expectError(error.InvalidMessage, ipp.decode(testing.allocator, header ++ suffix, .{}));
}

test "IPP enforces message field group and record bounds" {
    const bytes = header ++ "\x01\x04\x44\x00\x01a\x00\x03one\x03";
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .max_bytes = bytes.len - 1 }));
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .max_groups = 1 }));
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .max_attributes = 0 }));
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .max_name = 0 }));
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, bytes, .{ .max_value = 2 }));
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, header ++ "\x01\x44\x80\x00", .{}));
    try testing.expectError(error.TooLarge, ipp.decode(testing.allocator, header ++ "\x01\x44\x00\x01a\xff\xff", .{}));
    try testing.expectError(error.InvalidMessage, ipp.decode(testing.allocator, "\x01\x01\x00\x00\x00\x00\x00\x00\x01\x03", .{}));
    try testing.expectError(error.InvalidMessage, ipp.decode(testing.allocator, "\x01\x01\x00\x00\xff\xff\xff\xff\x01\x03", .{}));
    try testing.expectError(error.UnsupportedVersion, ipp.decode(testing.allocator, "\x03\x00\x00\x00\x00\x00\x00\x01\x01\x03", .{}));
}

test "IPP encoder rejects invalid sequencing and typed data" {
    try testing.expectError(error.InvalidMessage, ipp.Encoder.init(testing.allocator, 2, 0));
    var encoder = try ipp.Encoder.init(testing.allocator, 2, 1);
    defer encoder.deinit();
    try testing.expectError(error.InvalidMessage, encoder.finish());
    try testing.expectError(error.InvalidMessage, encoder.group(.printer));
    try testing.expectError(error.InvalidMessage, encoder.string(.keyword, "name", "value"));
    try encoder.group(.operation);
    try testing.expectError(error.InvalidMessage, encoder.string(.keyword, "", "value"));
    try testing.expectError(error.InvalidMessage, encoder.integer(.text, "name", 3));
    try testing.expectError(error.InvalidMessage, encoder.value(.range, "name", &.{ 0, 0, 0, 5, 0, 0, 0, 1 }));
    try encoder.string(.keyword, "name", "value");
    _ = try encoder.finish();
    try testing.expectError(error.InvalidMessage, encoder.group(.printer));
    try testing.expectError(error.InvalidMessage, encoder.string(.keyword, "other", "value"));
}

test "IPP decoder releases partial groups and collections on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const bytes = header ++ "\x01\x04" ++ collection ++
                "\x42\x00\x0cprinter-name\x00\x03one" ++
                "\x04\x42\x00\x0cprinter-name\x00\x03two\x03";
            var message = try ipp.decode(allocator, bytes, .{});
            defer message.deinit(allocator);
            try testing.expectEqual(@as(usize, 3), message.attributes.len);
        }
    }.run, .{});
}
