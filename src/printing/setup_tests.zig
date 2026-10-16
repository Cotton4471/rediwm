const std = @import("std");
const t = std.testing;
const setup = @import("setup.zig");

test "printer URI allow-list preserves full identity and excludes credential or file backends" {
    for ([_][]const u8{ "ipp://printer.local/ipp/print", "ipps://print.example:443/ipp/print", "socket://192.0.2.4:9100", "lpd://print.example/queue", "ipp://[2001:db8::4]:631/ipp/print" }) |uri| try setup.validateUri(uri, false);
    try setup.validateUri("usb://Acme/Label?serial=123", true);
    try setup.validateUri("dnssd://Office%20Printer._ipp._tcp.local./?uuid=123", true);
    try setup.validateUri("tspl:/dev/usb/lp0", true);
    try setup.validateUri("hp:/usb/Printer?serial=123", true);
    for ([_][]const u8{ "tspl:/dev/usb/lp0", "hp:/usb/Printer?serial=123" }) |uri| {
        if (setup.validateUri(uri, false)) return error.TestUnexpectedResult else |_| {}
    }
    for ([_][]const u8{ "file:/dev/usb/lp0", "pipe:/tmp/x", "exec:/usr/bin/x", "beh:/1/2/3/usb:x", "../backend:/dev/usb/lp0", "tspl:relative", "smb://host/queue" }) |uri| {
        if (setup.validateUri(uri, true)) return error.TestUnexpectedResult else |_| {}
    }
    for ([_][]const u8{ "file:/tmp/output", "smb://host/queue", "https://host/", "usb://Acme/Label", "dnssd://printer._ipp._tcp.local/", "ipp://user:secret@host/print", "ipp://user%40host/print", "ipp://host/print\n", "ipp://host/%0a", "ipp://host/%00", "ipp://host/%7f", "ipp://host/%5cpath", "ipp://host/%", "ipp://host/#fragment", "ipp://host:0/", "ipp://host:65536/", "ipp://:631/", "ipp:///print", "ipp://[x:1]/", "ipp://[::::]/", "ipp://host:abc/", "ipp://host\\other/", "ipp://host/%zz" }) |uri| {
        if (setup.validateUri(uri, false)) return error.TestUnexpectedResult else |_| {}
    }
    var long: [setup.max_uri + 1]u8 = @splat('a');
    @memcpy(long[0..6], "ipp://");
    try t.expectError(error.InvalidUri, setup.validateUri(&long, true));
}

test "queue names never silently collide after normalization truncation or case folding" {
    try t.expect(setup.validName("Office-Printer_2.1"));
    try t.expect(setup.validName("Impressora_é"));
    try t.expect(setup.validName("打印机"));
    for ([_][]const u8{ "", ".", "..", "queue/name", "name with spaces", "name#tag", "name\n", "-name?" }) |name| try t.expect(!setup.validName(name));
    const name = try setup.uniqueName(t.allocator, "Office / Printer", &.{ "Office-Printer", "office-printer-2" });
    defer t.allocator.free(name);
    try t.expectEqualStrings("Office-Printer-3", name);
    const fallback = try setup.uniqueName(t.allocator, "../../", &.{"Printer"});
    defer t.allocator.free(fallback);
    try t.expectEqualStrings("Printer-2", fallback);
    const model: [300]u8 = @splat('X');
    const first = try setup.uniqueName(t.allocator, &model, &.{});
    defer t.allocator.free(first);
    const next = try setup.uniqueName(t.allocator, &model, &.{first});
    defer t.allocator.free(next);
    try t.expect(setup.validName(next));
    try t.expect(next.len == setup.max_name);
    try t.expect(std.mem.endsWith(u8, next, "-2"));
}

test "driver matching requires unique full manufacturer and model device identity" {
    const ppds = [_]setup.Ppd{
        .{ .name = "acme-laser.ppd", .make_model = "Acme Laser 10", .device_id = "MFG:Acme;MDL:Laser 10;CMD:POSTSCRIPT;" },
        .{ .name = "other.ppd", .make_model = "Acme Laser 10", .device_id = "MFG:Other;MDL:Laser 10;" },
    };
    try t.expectEqual(@as(?usize, 0), setup.driverMatch("MANUFACTURER:acme;MODEL:Laser 10;", &ppds));
    try t.expectEqual(@as(?usize, null), setup.driverMatch("MFG:Acme;MDL:Laser 100;", &ppds));
    try t.expectEqual(@as(?usize, null), setup.driverMatch("MDL:Laser 10;", &ppds));
    try t.expectEqual(@as(?usize, null), setup.driverMatch("MFG:Acme;MDL:Laser 10;MODEL:Other;", &ppds));
    try t.expectEqual(@as(?usize, null), setup.driverMatch("MFG:Acme;MDL:Laser 10;CMD:TSPL;", &ppds));
    try t.expectEqual(@as(?usize, 0), setup.driverMatch("MFG:Acme;MDL:Laser 10;CMD:PCL,POSTSCRIPT;", &ppds));
    try t.expectEqual(@as(?usize, null), setup.driverMatch("MFG:Acme;MDL:Laser 10;", &.{ ppds[0], ppds[0] }));
    try t.expectEqual(@as(?usize, null), setup.driverMatch("Acme Laser 10", &ppds));
}
