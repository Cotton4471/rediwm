const std = @import("std");
const tools = @import("tools.zig");
const ipp = @import("ipp.zig");
const a = std.testing.allocator;

test "language detection requires exact complete CMD tokens" {
    const none = try tools.detectLanguages(a, "MFG:TSPL;MDL:ZPL II;CMD:NOTTSPL, PCLXL, XPOSTSCRIPT;");
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const found = try tools.detectLanguages(a, "MFG:Acme;CMD:TSPL2,ZPLII,EPL2,CPCL,PCL5e,POSTSCRIPT3,TSPL;MDL:Other;");
    defer a.free(found);
    try std.testing.expectEqualSlices(tools.Language, &tools.probe_languages, found);
}

test "media and PDF use actual physical queue dimensions and valid xref offsets" {
    const media = tools.mediaFromKeyword("na_index-4x6_4x6in").?;
    try std.testing.expectApproxEqAbs(@as(f64, 101.6), media.width_mm, 0.00001);
    try std.testing.expect(tools.mediaFromKeyword("4x5.Borderless") == null);
    try std.testing.expect(tools.mediaFromKeyword("custom_bad_nanx200mm") == null);
    const pdf = try tools.testPdf(a, media, .ruler);
    defer a.free(pdf);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/MediaBox [0 0 288.000 432.000]") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "12 12 144 216 re S") != null);
    const xref = std.mem.indexOf(u8, pdf, "xref\n0 6\n").?;
    var rows = std.mem.splitScalar(u8, pdf[xref..], '\n');
    _ = rows.next();
    _ = rows.next();
    _ = rows.next();
    for (1..6) |n| {
        const line = rows.next().?;
        const offset = try std.fmt.parseInt(usize, line[0..10], 10);
        var buffer: [24]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&buffer, "{d} 0 obj", .{n});
        try std.testing.expect(std.mem.startsWith(u8, pdf[offset..], prefix));
    }
    const page = try tools.testPdf(a, media, .page);
    defer a.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "12 12 72 72 re S") != null);
    try std.testing.expectError(error.MediaTooSmall, tools.testPdf(a, .{ .width_mm = 30, .height_mm = 40 }, .ruler));
}

test "raw language samples are bounded single documents without automatic transport" {
    for (tools.probe_languages) |language| {
        const raw = try tools.rawTest(a, language, .{ .width_mm = 101.6, .height_mm = 152.4 }, 203);
        defer a.free(raw);
        try std.testing.expect(raw.len > 10 and raw.len < 512);
        try std.testing.expect(std.mem.indexOf(u8, raw, "RediWM") != null);
    }
    try std.testing.expectError(error.InvalidResolution, tools.rawTest(a, .tspl, .{ .width_mm = 100, .height_mm = 150 }, 0));
    try std.testing.expectError(error.InvalidMedia, tools.rawTest(a, .tspl, .{ .width_mm = std.math.inf(f64), .height_mm = 150 }, 203));
}

test "calibration suggests only supported resolution consistent with both physical axes" {
    const r203: ipp.Resolution = .{ .x = 203, .y = 203, .units = .dpi };
    const r300: ipp.Resolution = .{ .x = 300, .y = 300, .units = .dpi };
    const supported = [_]ipp.Resolution{ r203, r300, .{ .x = 600, .y = 600, .units = .dpi } };
    const ratio: f64 = 300.0 / 203.0;
    const suggestion = tools.suggestResolution(r300, &supported, 50.8 * ratio, 76.2 * ratio).?;
    try std.testing.expectEqual(r203, suggestion);
    try std.testing.expect(tools.suggestResolution(r300, &supported, 50.8, 76.2) == null);
    try std.testing.expect(tools.suggestResolution(r300, &supported, 50.8 * ratio, 76.2) == null);
    try std.testing.expect(tools.suggestResolution(r300, &.{r300}, 50.8 * ratio, 76.2 * ratio) == null);
    try std.testing.expect(tools.suggestResolution(r300, &supported, std.math.nan(f64), 76.2) == null);
    const dpcm: ipp.Resolution = .{ .x = 80, .y = 80, .units = .dpcm };
    try std.testing.expectEqual(dpcm, tools.suggestResolution(r300, &.{dpcm}, 50.8 * 300 / 203.2, 76.2 * 300 / 203.2).?);
}
