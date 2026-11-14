//! Replace nonoverlapping literal matches in one history entry. Build the
//! changed span once, so repeated matches never memmove the document's tail.
const std = @import("std");
const document = @import("document.zig");
const Document = document.Document;
const a = std.heap.c_allocator;

pub fn replaceAll(d: *Document, query: []const u8, replacement: []const u8) !usize {
    if (d.locked) return error.Busy;
    if (query.len == 0) return 0;
    try Document.validate(query);
    try Document.validate(replacement);
    const text = d.text.items;
    const first = std.mem.indexOf(u8, text, query) orelse return 0;
    var end = first;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, text, end, query)) |at| {
        count += 1;
        end = at + query.len;
    }
    if (std.mem.eql(u8, query, replacement)) return count;
    const added = std.math.mul(usize, count, replacement.len) catch return error.FileTooLarge;
    const size = std.math.add(usize, text.len - count * query.len, added) catch return error.FileTooLarge;
    if (size > document.limit) return error.FileTooLarge;
    const result = try a.alloc(u8, end - first - count * query.len + added);
    defer a.free(result);
    var from = first;
    var to: usize = 0;
    while (std.mem.indexOfPos(u8, text[0..end], from, query)) |at| {
        @memcpy(result[to..][0 .. at - from], text[from..at]);
        to += at - from;
        @memcpy(result[to..][0..replacement.len], replacement);
        to += replacement.len;
        from = at + query.len;
    }
    const cursor = d.cursor;
    const anchor = d.anchor;
    d.anchor = first;
    d.cursor = end;
    errdefer {
        d.cursor = cursor;
        d.anchor = anchor;
    }
    try d.insert(result);
    return count;
}

test {
    _ = @import("document_search_tests.zig");
}
