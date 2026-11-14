const std = @import("std");
const Document = @import("document.zig").Document;

test "replace all is literal, UTF-8 safe and one undoable edit" {
    var d = try Document.init("\xef\xbb\xbf雪 cat\r\ncat 雪\r\ncat");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), try d.replaceAll("cat", "猫cat"));
    try std.testing.expectEqualStrings("雪 猫cat\r\n猫cat 雪\r\n猫cat", d.text.items);
    try std.testing.expect(d.bom and d.crlf and d.modified());
    try d.undo(false);
    try std.testing.expectEqualStrings("雪 cat\r\ncat 雪\r\ncat", d.text.items);
    try std.testing.expect(!d.modified());
    try d.undo(true);
    try std.testing.expectEqualStrings("雪 猫cat\r\n猫cat 雪\r\n猫cat", d.text.items);
}

test "replace all handles empty, unchanged, absent and overlapping matches" {
    var d = try Document.init("aaaaa");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), try d.replaceAll("", "x"));
    try std.testing.expectEqual(@as(usize, 0), try d.replaceAll("missing", "x"));
    try std.testing.expectEqual(@as(usize, 2), try d.replaceAll("aa", "aa"));
    try std.testing.expect(!d.modified());
    try std.testing.expectEqual(@as(usize, 2), try d.replaceAll("aa", ""));
    try std.testing.expectEqualStrings("a", d.text.items);
    try d.undo(false);
    try std.testing.expectEqualStrings("aaaaa", d.text.items);
}

test "replace all refuses a borrowed save buffer without changing state" {
    var d = try Document.init("keep keep");
    defer d.deinit();
    d.move(2, false);
    d.locked = true;
    try std.testing.expectError(error.Busy, d.replaceAll("keep", "gone"));
    try std.testing.expectEqualStrings("keep keep", d.text.items);
    try std.testing.expectEqual(@as(usize, 2), d.cursor);
    try std.testing.expect(!d.modified());
}
