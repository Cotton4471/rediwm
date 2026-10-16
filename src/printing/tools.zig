//! Explicit, single-page diagnostic documents. No transport or automatic print.
//! These tiny language samples are not a print driver or a raster converter.
const std = @import("std");
const ipp = @import("ipp.zig");
const A = std.mem.Allocator;

pub const Language = enum {
    tspl,
    zpl,
    epl,
    cpcl,
    pcl,
    postscript,

    pub fn label(self: Language) []const u8 {
        return switch (self) {
            .tspl => "TSPL",
            .zpl => "ZPL",
            .epl => "EPL",
            .cpcl => "CPCL",
            .pcl => "PCL",
            .postscript => "PostScript",
        };
    }
};

/// The UI must confirm each language separately and ask about physical output
/// before offering another. A USB ID or guessed model is not CMD evidence.
pub const probe_languages = [_]Language{ .tspl, .zpl, .epl, .cpcl, .pcl, .postscript };
pub const self_test_help = "Check the printer's manual for its self-test procedure (often hold FEED while powering on). The sheet can identify its command language and physical resolution. A wrong language may print literal commands, waste paper, or require a power cycle; send only one confirmed probe at a time.";

/// Only complete IEEE 1284 CMD/COMMAND SET tokens count. Never substring-match
/// model names, generic language claims in other fields, or a shared VID:PID.
pub fn detectLanguages(a: A, device_id: []const u8) ![]Language {
    if (device_id.len > 16384) return error.TooLarge;
    var result: std.ArrayList(Language) = .empty;
    errdefer result.deinit(a);
    var fields = std.mem.splitScalar(u8, device_id, ';');
    while (fields.next()) |field| {
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse continue;
        const key = std.mem.trim(u8, field[0..colon], " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(key, "CMD") and !std.ascii.eqlIgnoreCase(key, "COMMAND SET")) continue;
        var tokens = std.mem.tokenizeAny(u8, field[colon + 1 ..], ", \t\r\n");
        while (tokens.next()) |token| {
            const language: Language = if (std.ascii.eqlIgnoreCase(token, "TSPL") or std.ascii.eqlIgnoreCase(token, "TSPL2")) .tspl else if (std.ascii.eqlIgnoreCase(token, "ZPL") or std.ascii.eqlIgnoreCase(token, "ZPLII")) .zpl else if (std.ascii.eqlIgnoreCase(token, "EPL") or std.ascii.eqlIgnoreCase(token, "EPL2")) .epl else if (std.ascii.eqlIgnoreCase(token, "CPCL")) .cpcl else if (std.ascii.eqlIgnoreCase(token, "PCL") or std.ascii.eqlIgnoreCase(token, "PCL5") or std.ascii.eqlIgnoreCase(token, "PCL5e") or std.ascii.eqlIgnoreCase(token, "PCL5c")) .pcl else if (std.ascii.eqlIgnoreCase(token, "POSTSCRIPT") or std.ascii.eqlIgnoreCase(token, "POSTSCRIPT2") or std.ascii.eqlIgnoreCase(token, "POSTSCRIPT3")) .postscript else continue;
            if (std.mem.indexOfScalar(Language, result.items, language) == null) try result.append(a, language);
        }
    }
    return result.toOwnedSlice(a);
}

pub const Media = struct {
    width_mm: f64,
    height_mm: f64,

    pub fn valid(self: Media) bool {
        return std.math.isFinite(self.width_mm) and std.math.isFinite(self.height_mm) and
            self.width_mm >= 12.7 and self.height_mm >= 12.7 and self.width_mm <= 1500 and self.height_mm <= 1500;
    }
};
pub const PdfKind = enum { page, ruler };
pub const ruler_width_mm = 50.8;
pub const ruler_height_mm = 76.2;

/// PWG media names end in physical dimensions, for example
/// iso_a4_210x297mm / na_index-4x6_4x6in / custom_label_101.6x152.4mm.
/// Legacy PPD names have no such guarantee and require the PPD dimensions.
pub fn mediaFromKeyword(keyword: []const u8) ?Media {
    if (keyword.len > 255) return null;
    const suffix = keyword[(std.mem.lastIndexOfScalar(u8, keyword, '_') orelse return null) + 1 ..];
    const unit: f64 = if (std.mem.endsWith(u8, suffix, "mm")) 1 else if (std.mem.endsWith(u8, suffix, "in")) 25.4 else return null;
    const dims = suffix[0 .. suffix.len - 2];
    const x = std.mem.indexOfScalar(u8, dims, 'x') orelse return null;
    const media: Media = .{
        .width_mm = (std.fmt.parseFloat(f64, dims[0..x]) catch return null) * unit,
        .height_mm = (std.fmt.parseFloat(f64, dims[x + 1 ..]) catch return null) * unit,
    };
    return if (media.valid()) media else null;
}

/// Supply actual queue media dimensions, never silently assume Letter/A4.
/// PDF points are physical 1/72-inch units. Print at 100%, without fit-to-page.
pub fn testPdf(a: A, media: Media, kind: PdfKind) ![]u8 {
    if (!media.valid()) return error.InvalidMedia;
    const w = media.width_mm * 72 / 25.4;
    const h = media.height_mm * 72 / 25.4;
    if (kind == .ruler and (w < 160 or h < 232)) return error.MediaTooSmall;
    if (kind == .page and (w < 88 or h < 110)) return error.MediaTooSmall;
    var stream: std.Io.Writer.Allocating = .init(a);
    defer stream.deinit();
    const sw = &stream.writer;
    try sw.print("0 G 0.5 w 8 8 {d:.3} {d:.3} re S\n", .{ w - 16, h - 16 });
    if (kind == .ruler) {
        try sw.writeAll("12 12 144 216 re S\nBT /F1 9 Tf 16 222 Td (2 x 3 inches / 50.8 x 76.2 mm) Tj ET\n");
        // Quarter-inch tick marks along the known-size rectangle.
        for (1..8) |n| try sw.print("{d} 12 m {d} 17 l S\n", .{ 12 + n * 18, 12 + n * 18 });
        for (1..12) |n| try sw.print("12 {d} m 17 {d} l S\n", .{ 12 + n * 18, 12 + n * 18 });
    } else {
        try sw.writeAll("12 12 72 72 re S\nBT /F1 9 Tf 12 92 Td (1 inch / 25.4 mm square) Tj ET\n");
        try sw.print("BT /F1 10 Tf 12 {d:.3} Td (RediWM printer test - print at 100%) Tj ET\n", .{h - 24});
    }
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("%PDF-1.4\n");
    var offsets: [6]usize = @splat(0);
    offsets[1] = out.written().len;
    try writer.writeAll("1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n");
    offsets[2] = out.written().len;
    try writer.writeAll("2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n");
    offsets[3] = out.written().len;
    try writer.print("3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.3} {d:.3}] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >> endobj\n", .{ w, h });
    offsets[4] = out.written().len;
    try writer.writeAll("4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n");
    offsets[5] = out.written().len;
    try writer.print("5 0 obj << /Length {d} >> stream\n", .{stream.written().len});
    try writer.writeAll(stream.written());
    try writer.writeAll("endstream\nendobj\n");
    const xref = out.written().len;
    try writer.writeAll("xref\n0 6\n0000000000 65535 f \n");
    for (offsets[1..]) |offset| try writer.print("{d:0>10} 00000 n \n", .{offset});
    try writer.print("trailer << /Size 6 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{xref});
    return out.toOwnedSlice();
}

/// Exactly one tiny sample, no downloaded fonts, bitmaps, firmware, language
/// switching, saved settings or persistent calibration commands.
/// References: TSC TSPL/TSPL2 manual; Zebra ZPL/EPL/CPCL programming guides;
/// HP PCL 5 Printer Language Technical Reference; Adobe PLRM (showpage).
pub fn rawTest(a: A, language: Language, media: Media, dpi: u32) ![]u8 {
    if (!media.valid()) return error.InvalidMedia;
    if (dpi < 72 or dpi > 1200) return error.InvalidResolution;
    const w: u32 = @intFromFloat(@round(media.width_mm * @as(f64, @floatFromInt(dpi)) / 25.4));
    const h: u32 = @intFromFloat(@round(media.height_mm * @as(f64, @floatFromInt(dpi)) / 25.4));
    return switch (language) {
        .tspl => std.fmt.allocPrint(a, "SIZE {d:.3} mm,{d:.3} mm\r\nCLS\r\nTEXT 10,10,\"1\",0,1,1,\"RediWM TSPL test\"\r\nPRINT 1,1\r\n", .{ media.width_mm, media.height_mm }),
        .zpl => std.fmt.allocPrint(a, "^XA^PW{d}^LL{d}^FO10,10^A0N,24,20^FDRediWM ZPL test^FS^PQ1^XZ\r\n", .{ w, h }),
        .epl => std.fmt.allocPrint(a, "\nN\nq{d}\nQ{d},0\nA10,10,0,2,1,1,N,\"RediWM EPL test\"\nP1\n", .{ w, h }),
        .cpcl => std.fmt.allocPrint(a, "! 0 {d} {d} {d} 1\r\nTEXT 0 0 10 10 RediWM CPCL test\r\nFORM\r\nPRINT\r\n", .{ dpi, dpi, h }),
        .pcl => a.dupe(u8, "\x1bERediWM PCL test\r\n\x0c\x1bE"),
        .postscript => std.fmt.allocPrint(a, "%!PS-Adobe-3.0\n%%Pages: 1\n<< /PageSize [{d:.3} {d:.3}] >> setpagedevice\n/Helvetica findfont 10 scalefont setfont\n10 10 moveto (RediWM PostScript test) show\nshowpage\n%%EOF\n", .{ media.width_mm * 72 / 25.4, media.height_mm * 72 / 25.4 }),
    };
}

pub fn dpiValue(resolution: ipp.Resolution) ?struct { x: f64, y: f64 } {
    if (resolution.x <= 0 or resolution.y <= 0) return null;
    const factor: f64 = if (resolution.units == .dpcm) 2.54 else 1;
    const x = @as(f64, @floatFromInt(resolution.x)) * factor;
    const y = @as(f64, @floatFromInt(resolution.y)) * factor;
    if (x < 36 or y < 36 or x > 9600 or y > 9600) return null;
    return .{ .x = x, .y = y };
}

/// A current 300dpi job measuring 1.478 times too large suggests 203dpi:
/// current * expected / measured. Both axes must agree within 8%; the chosen
/// supported resolution must explain both measurements within 8%. Never invent
/// an unsupported choice, or "fix" fit-to-page/aspect/margin errors with dpi.
pub fn suggestResolution(current: ipp.Resolution, supported: []const ipp.Resolution, measured_width_mm: f64, measured_height_mm: f64) ?ipp.Resolution {
    if (!std.math.isFinite(measured_width_mm) or !std.math.isFinite(measured_height_mm) or measured_width_mm < 1 or measured_height_mm < 1 or measured_width_mm > 5000 or measured_height_mm > 5000) return null;
    const current_dpi = dpiValue(current) orelse return null;
    const rx = measured_width_mm / ruler_width_mm;
    const ry = measured_height_mm / ruler_height_mm;
    if (@abs(rx / ry - 1) > 0.08 or (@abs(rx - 1) < 0.03 and @abs(ry - 1) < 0.03)) return null;
    const target_x = current_dpi.x / rx;
    const target_y = current_dpi.y / ry;
    var best: ?ipp.Resolution = null;
    var best_error: f64 = 0.08;
    var ambiguous = false;
    for (supported[0..@min(supported.len, 256)]) |candidate| {
        const value = dpiValue(candidate) orelse continue;
        const err = @max(@abs(value.x / target_x - 1), @abs(value.y / target_y - 1));
        if (err > 0.08) continue;
        if (best != null and @abs(err - best_error) < 0.01) {
            const old = dpiValue(best.?).?;
            if (@abs(old.x - value.x) > 1 or @abs(old.y - value.y) > 1) ambiguous = true;
        } else if (err < best_error) {
            best = candidate;
            best_error = err;
            ambiguous = false;
        }
    }
    return if (ambiguous) null else best;
}

test {
    _ = @import("tools_tests.zig");
}
