const std = @import("std");
const options = @import("options.zig");
const ipp = @import("ipp.zig");
const a = std.testing.allocator;

const ppd =
    \\*PPD-Adobe: "4.3"
    \\*DefaultResolution: 203dpi
    \\*OpenGroup: General/General options
    \\*OpenUI *PageSize/Paper size: PickOne
    \\*DefaultPageSize: Label
    \\*PageSize Label/4 x 6 inch: "malicious arbitrary PostScript ignored"
    \\*PageSize A4/A4: "<</PageSize[595 842]>>setpagedevice"
    \\*CloseUI: *PageSize
    \\*PaperDimension Label: "288 432"
    \\*ImageableArea Label: "18 12 264 402"
    \\*OpenUI *Resolution/Resolution: PickOne
    \\*Resolution 203dpi/203 dpi: "never execute this"
    \\*Resolution 300dpi/300 dpi: "never execute this either"
    \\*CloseUI: *Resolution
    \\*CloseGroup: General
    \\*OpenGroup: Label/Label controls
    \\*OpenUI *Darkness/Print darkness: PickOne
    \\*Darkness 5/Light: "unused"
    \\*Darkness 10/Normal: "unused"
    \\*CloseUI: *Darkness
    \\*CloseGroup: Label
;

test "PPD UI choices preserve driver groups without interpreting commands" {
    const groups = try options.parsePpd(a, ppd);
    defer options.deinit(a, groups);
    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqualStrings("General options", groups[0].label);
    try std.testing.expectEqualStrings("PageSize", groups[0].options[0].name);
    try std.testing.expectEqualStrings("Label", groups[0].options[0].default.?);
    try std.testing.expectEqualStrings("4 x 6 inch", groups[0].options[0].choices[0].label);
    try std.testing.expectEqualStrings("203dpi", groups[0].options[1].default.?);
    try std.testing.expectEqualStrings("Label controls", groups[1].label);
    try std.testing.expectEqualStrings("Darkness", groups[1].options[0].name);
    const media = options.ppdMediaDimensions(ppd, "Label").?;
    try std.testing.expectApproxEqAbs(@as(f64, 101.6), media.width_mm, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 152.4), media.height_mm, 0.0001);
    try std.testing.expect(options.ppdMediaDimensions(ppd, "Absent") == null);
    const margins = options.ppdMargins(ppd, "Label").?;
    try std.testing.expectApproxEqAbs(@as(f64, 6.35), margins.left_mm, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 8.46666667), margins.right_mm, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10.58333333), margins.top_mm, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 4.23333333), margins.bottom_mm, 0.0001);
    try std.testing.expect(options.ppdMargins(ppd, "Absent") == null);
}

test "PPD data is bounded and structurally incomplete options are rejected" {
    try std.testing.expectError(error.InvalidOptions, options.parsePpd(a, "not a PPD"));
    try std.testing.expectError(error.InvalidOptions, options.parsePpd(a, "*PPD-Adobe: \"4.3\"\n*OpenUI *X/X: PickOne\n"));
    try std.testing.expectError(error.InvalidOptions, options.parsePpd(a, "*PPD-Adobe: \"4.3\"\n*CloseGroup: X\n"));
    try std.testing.expect(options.ppdMediaDimensions("*PaperDimension A4: \"nan 842\"", "A4") == null);
    for ([_][]const u8{ "-1 0 288 432", "0 0 289 432", "0 0 288 433", "12 0 10 432", "0 5 288 5", "0 0 inf 432", "0 nan 288 432", "0 0 288", "0 0 288 432 1" }) |area| {
        const invalid = try std.fmt.allocPrint(a, "*PaperDimension Label: \"288 432\"\n*ImageableArea Label: \"{s}\"\n", .{area});
        defer a.free(invalid);
        try std.testing.expect(options.ppdMargins(invalid, "Label") == null);
    }
    try std.testing.expect(options.ppdMargins("*PaperDimension Label: \"288 432\"\n", "Label") == null);
    const borderless = options.ppdMargins("*PaperDimension Label: \"288 432\"\n*ImageableArea Label: \"0 0 288 432\"\n", "Label").?;
    try std.testing.expectEqual(options.Margins{ .left_mm = 0, .right_mm = 0, .top_mm = 0, .bottom_mm = 0 }, borderless);
}

test "IPP supported options preserve numeric quality and dpcm units" {
    var enc = try ipp.Encoder.init(a, 0, 1);
    defer enc.deinit();
    try enc.group(.operation);
    try enc.group(.printer);
    try enc.string(.keyword, "media-supported", "iso_a4_210x297mm");
    try enc.string(.keyword, "", "na_index-4x6_4x6in");
    try enc.string(.keyword, "media-default", "na_index-4x6_4x6in");
    try enc.string(.keyword, "sides-supported", "one-sided");
    try enc.string(.keyword, "", "two-sided-long-edge");
    try enc.integer(.enum_value, "print-quality-supported", 3);
    try enc.integer(.enum_value, "", 4);
    var resolution: [9]u8 = undefined;
    std.mem.writeInt(i32, resolution[0..4], 80, .big);
    std.mem.writeInt(i32, resolution[4..8], 80, .big);
    resolution[8] = 4;
    try enc.value(.resolution, "printer-resolution-supported", &resolution);
    var range: [8]u8 = undefined;
    std.mem.writeInt(i32, range[0..4], 1, .big);
    std.mem.writeInt(i32, range[4..8], 5, .big);
    try enc.value(.range, "print-darkness-supported", &range);
    var msg = try ipp.decode(a, try enc.finish(), .{});
    defer msg.deinit(a);
    const groups = try options.parseAttributes(a, msg.attributes);
    defer options.deinit(a, groups);
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    const list = groups[0].options;
    try std.testing.expectEqualStrings("media", list[0].name);
    try std.testing.expectEqualStrings("A4 (210.0 x 297.0 mm)", list[0].choices[0].label);
    try std.testing.expectEqualStrings("80dpcm", list[1].choices[0].value);
    try std.testing.expectEqualStrings("Two-sided, long edge", list[2].choices[1].label);
    try std.testing.expectEqualStrings("Draft", list[3].choices[0].label);
    try std.testing.expectEqual(@as(usize, 5), list[4].choices.len);
}

fn allocationFailure(mem: std.mem.Allocator) !void {
    const groups = try options.parsePpd(mem, ppd);
    defer options.deinit(mem, groups);
}
test "PPD parser cleans up every partially allocated result" {
    try std.testing.checkAllAllocationFailures(a, allocationFailure, .{});
}

test "resolution choice helpers preserve exact dpi and dpcm values for calibration" {
    try std.testing.expectEqual(ipp.Resolution{ .x = 203, .y = 203, .units = .dpi }, options.parseResolution("203dpi").?);
    try std.testing.expectEqual(ipp.Resolution{ .x = 300, .y = 600, .units = .dpi }, options.parseResolution("300x600dpi").?);
    try std.testing.expectEqual(ipp.Resolution{ .x = 80, .y = 80, .units = .dpcm }, options.parseResolution("80dpcm").?);
    for ([_][]const u8{ "Custom", "0dpi", "-203dpi", "300 dpi", "300x600x1200dpi", "300xdpi", "2147483647dpi", "nanDPI", "dpi" }) |invalid| try std.testing.expect(options.parseResolution(invalid) == null);
    const groups = try options.parsePpd(a, ppd);
    defer options.deinit(a, groups);
    const supported = try options.resolutionChoices(a, groups);
    defer a.free(supported);
    try std.testing.expectEqualSlices(ipp.Resolution, &.{ .{ .x = 203, .y = 203, .units = .dpi }, .{ .x = 300, .y = 300, .units = .dpi } }, supported);
}

test "IPP duplicate defaults keep the first CUPS override without discarding typed evidence" {
    var encoder = try ipp.Encoder.init(a, 0, 1);
    defer encoder.deinit();
    try encoder.group(.operation);
    try encoder.group(.printer);
    try encoder.string(.name, "printer-resolution-default", "203dpi");
    const resolution = "\x00\x00\x01\x2c\x00\x00\x01\x2c\x03";
    try encoder.value(.resolution, "printer-resolution-default", resolution);
    try encoder.value(.resolution, "printer-resolution-supported", resolution);
    try encoder.string(.keyword, "media-default", "na_index-4x6_4x6in");
    try encoder.string(.keyword, "media-default", "iso_a4_210x297mm");
    try encoder.string(.keyword, "media-supported", "na_index-4x6_4x6in");
    var message = try ipp.decode(a, try encoder.finish(), .{ .allow_duplicate_names = true });
    defer message.deinit(a);
    const groups = try options.parseAttributes(a, message.attributes);
    defer options.deinit(a, groups);
    try std.testing.expectEqualStrings("na_index-4x6_4x6in", groups[0].options[0].default.?);
    try std.testing.expectEqualStrings("203dpi", groups[0].options[1].default.?);
    try std.testing.expectEqual(@as(i32, 300), message.attributes[1].resolution().?.x);
}

test "queue editability requires an actual selectable PPD counterpart for IPP job capabilities" {
    const groups = try options.parsePpd(a, ppd);
    defer options.deinit(a, groups);
    try std.testing.expect(options.queueEditable(.{ .name = "PageSize", .source = .ppd }, &.{}));
    try std.testing.expect(options.queueEditable(.{ .name = "media" }, groups));
    try std.testing.expect(options.queueEditable(.{ .name = "printer-resolution" }, groups));
    try std.testing.expect(!options.queueEditable(.{ .name = "sides" }, groups));
    try std.testing.expect(!options.queueEditable(.{ .name = "print-darkness" }, groups));
    try std.testing.expect(!options.queueEditable(.{ .name = "print-speed", .range = .{ .lower = 1, .upper = 100 } }, groups));
    const driverless = try options.parsePpd(a,
        \\*PPD-Adobe: "4.3"
        \\*DefaultResolution: 300dpi
        \\*OpenUI *PageSize/Paper: PickOne
        \\*PageSize A4/A4: "unused"
        \\*CloseUI: *PageSize
    );
    defer options.deinit(a, driverless);
    // A DefaultResolution line does not make the generated PPD selectable.
    try std.testing.expect(!options.queueEditable(.{ .name = "printer-resolution" }, driverless));
    const aliases = try options.parsePpd(a,
        \\*PPD-Adobe: "4.3"
        \\*OpenUI *SetResolution/Resolution: PickOne
        \\*SetResolution 300dpi/300 dpi: "unused"
        \\*CloseUI: *SetResolution
        \\*OpenUI *Duplex/Sides: PickOne
        \\*Duplex None/One-sided: "unused"
        \\*CloseUI: *Duplex
        \\*OpenUI *ColorModel/Colour: PickOne
        \\*ColorModel RGB/Colour: "unused"
        \\*CloseUI: *ColorModel
        \\*OpenUI *cupsPrintQuality/Quality: PickOne
        \\*cupsPrintQuality Normal/Normal: "unused"
        \\*CloseUI: *cupsPrintQuality
        \\*OpenUI *print-speed/Speed: PickOne
        \\*print-speed 5/5: "unused"
        \\*CloseUI: *print-speed
    );
    defer options.deinit(a, aliases);
    for ([_][]const u8{ "printer-resolution", "sides", "print-color-mode", "print-quality", "print-speed" }) |name| try std.testing.expect(options.queueEditable(.{ .name = name }, aliases));
}

test "fresh setting verification uses typed CUPS defaults and exact PPD defaults without trusting name overrides" {
    const groups = try options.parsePpd(a, ppd);
    defer options.deinit(a, groups);
    var encoder = try ipp.Encoder.init(a, 0, 1);
    defer encoder.deinit();
    try encoder.group(.operation);
    try encoder.group(.printer);
    try encoder.string(.name, "printer-resolution-default", "203dpi");
    const r300 = "\x00\x00\x01\x2c\x00\x00\x01\x2c\x03";
    try encoder.value(.resolution, "printer-resolution-default", r300);
    try encoder.string(.name, "media-default", "na_index-4x6_4x6in");
    try encoder.string(.keyword, "media-default", "iso_a4_210x297mm");
    try encoder.string(.name, "sides-default", "two-sided-long-edge");
    try encoder.string(.keyword, "sides-default", "one-sided");
    try encoder.string(.name, "print-color-mode-default", "color");
    try encoder.string(.keyword, "print-color-mode-default", "monochrome");
    try encoder.string(.name, "print-quality-default", "5");
    try encoder.integer(.enum_value, "print-quality-default", 4);
    var message = try ipp.decode(a, try encoder.finish(), .{ .allow_duplicate_names = true });
    defer message.deinit(a);
    try std.testing.expectEqual(@as(?bool, false), options.settingMatches(groups, message.attributes, .{ .name = "printer-resolution" }, "203dpi"));
    try std.testing.expectEqual(@as(?bool, true), options.settingMatches(groups, message.attributes, .{ .name = "printer-resolution" }, "300dpi"));
    try std.testing.expectEqual(@as(?bool, true), options.settingMatches(groups, message.attributes, .{ .name = "Resolution", .source = .ppd }, "203dpi"));
    try std.testing.expectEqual(@as(?bool, false), options.settingMatches(groups, message.attributes, .{ .name = "Resolution", .source = .ppd }, "300dpi"));
    try std.testing.expectEqual(@as(?bool, true), options.settingMatches(groups, message.attributes, .{ .name = "media" }, "iso_a4_210x297mm"));
    try std.testing.expectEqual(@as(?bool, false), options.settingMatches(groups, message.attributes, .{ .name = "media" }, "na_index-4x6_4x6in"));
    try std.testing.expectEqual(@as(?bool, false), options.settingMatches(groups, message.attributes, .{ .name = "sides" }, "two-sided-long-edge"));
    try std.testing.expectEqual(@as(?bool, true), options.settingMatches(groups, message.attributes, .{ .name = "print-color-mode" }, "monochrome"));
    try std.testing.expectEqual(@as(?bool, true), options.settingMatches(groups, message.attributes, .{ .name = "print-quality" }, "4"));
    try std.testing.expectEqual(@as(?bool, null), options.settingMatches(groups, message.attributes, .{ .name = "unknown" }, "anything"));
    try std.testing.expectEqual(@as(?bool, null), options.settingMatches(groups, &.{}, .{ .name = "printer-resolution" }, "300dpi"));
    const quality = try options.parsePpd(a,
        \\*PPD-Adobe: "4.3"
        \\*OpenUI *cupsPrintQuality/Quality: PickOne
        \\*DefaultcupsPrintQuality: High
        \\*cupsPrintQuality High/High: "unused"
        \\*CloseUI: *cupsPrintQuality
    );
    defer options.deinit(a, quality);
    try std.testing.expectEqual(@as(?bool, true), options.settingMatches(quality, message.attributes, .{ .name = "print-quality" }, "5"));
    try std.testing.expectEqual(@as(?bool, false), options.settingMatches(quality, message.attributes, .{ .name = "print-quality" }, "4"));
    const dpcm: ipp.Attribute = .{ .group = .printer, .group_index = 0, .name = "printer-resolution-default", .tag = .resolution, .value = "\x00\x00\x00\x50\x00\x00\x00\x50\x04" };
    try std.testing.expectEqual(@as(?bool, true), options.settingMatches(&.{}, &.{dpcm}, .{ .name = "printer-resolution" }, "203dpi"));
    try std.testing.expectEqual(@as(?bool, false), options.settingMatches(&.{}, &.{dpcm}, .{ .name = "printer-resolution" }, "203x300dpi"));
}
