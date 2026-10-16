//! Read-only USB printer inventory. Device nodes are stat'ed, never opened.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Roots = struct { sysfs: []const u8 = "/sys", dev: []const u8 = "/dev" };
pub const NodeKind = enum { missing, character, regular, other, unavailable };
pub const Node = struct {
    path: []const u8,
    kind: NodeKind,
};
pub const Device = struct {
    /// USB topology name, not the product string (which can be misleading).
    name: []const u8,
    vid: u16,
    pid: u16,
    printer_class: bool = true,
    manufacturer: []const u8,
    product: []const u8,
    serial: []const u8,
    driver: []const u8,
    /// Complete validated IEEE 1284 identity, never a display-truncated string.
    /// Empty means absent, unreadable, invalid, or conflicting interface IDs.
    device_id: []const u8 = "",
    nodes: []Node,

    pub fn deinit(self: Device, a: Allocator) void {
        a.free(self.name);
        a.free(self.manufacturer);
        a.free(self.product);
        a.free(self.serial);
        a.free(self.driver);
        a.free(self.device_id);
        for (self.nodes) |node| a.free(node.path);
        a.free(self.nodes);
    }
};
pub const Snapshot = struct {
    devices: []Device,
    /// False means unavailable, interrupted, or bounded; absence is then inconclusive.
    complete: bool,

    pub fn deinit(self: Snapshot, a: Allocator) void {
        for (self.devices) |device| device.deinit(a);
        a.free(self.devices);
    }
};

pub const Match = struct {
    device: ?*const Device = null,
    /// A complete scan plus a usable unique serial permits an absence verdict.
    conclusive: bool = false,
};

/// CUPS USB URIs identify a device by their percent-encoded `serial` query.
/// Model names and VID:PID cannot distinguish two printers of the same model.
/// Missing serials, duplicate serials and unavailable inventory stay unknown.
pub fn matchQueue(snapshot: *const Snapshot, uri: []const u8) Match {
    var serial_bytes: [256]u8 = undefined;
    const serial = queueSerial(uri, &serial_bytes) orelse return .{};
    var matched: ?*const Device = null;
    var unidentified = false;
    for (snapshot.devices) |*device| {
        if (device.serial.len == 0) unidentified = true;
        if (!std.mem.eql(u8, device.serial, serial)) continue;
        if (matched != null) return .{};
        matched = device;
    }
    if (matched) |device| return .{ .device = device, .conclusive = snapshot.complete };
    return .{ .conclusive = snapshot.complete and !unidentified };
}

fn queueSerial(uri: []const u8, output: []u8) ?[]const u8 {
    if (uri.len > 4096 or uri.len < 6 or !std.ascii.eqlIgnoreCase(uri[0..6], "usb://")) return null;
    const query = std.mem.indexOfScalar(u8, uri, '?') orelse return null;
    if (std.mem.indexOfScalar(u8, uri[query..], '#') != null) return null;
    var serial: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, uri[query + 1 ..], '&');
    var count: usize = 0;
    while (fields.next()) |field| {
        count += 1;
        if (count > 64) return null;
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (!std.mem.eql(u8, field[0..equals], "serial")) continue;
        if (serial != null) return null;
        serial = field[equals + 1 ..];
    }
    const encoded = serial orelse return null;
    if (encoded.len == 0) return null;
    var i: usize = 0;
    var len: usize = 0;
    while (i < encoded.len) {
        if (len == output.len) return null;
        const byte = encoded[i];
        if (byte == '%') {
            if (i + 2 >= encoded.len) return null;
            output[len] = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            // URI query values are not HTML forms: '+' is a literal plus.
            output[len] = byte;
            i += 1;
        }
        len += 1;
    }
    const view = std.unicode.Utf8View.init(output[0..len]) catch return null;
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |codepoint| if (forbiddenCodepoint(codepoint)) return null;
    return output[0..len];
}

const max_entries = 4096;
const max_devices = 256;
const max_nodes = 32;

/// Caller owns the snapshot and supplies Io; no worker, timers, or global state.
pub fn scan(a: Allocator, io: Io, roots: Roots) !Snapshot {
    const path = try std.fs.path.join(a, &.{ roots.sysfs, "bus/usb/devices" });
    defer a.free(path);
    var result: std.ArrayList(Device) = .empty;
    errdefer {
        for (result.items) |device| device.deinit(a);
        result.deinit(a);
    }
    var bus = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{
        .devices = try result.toOwnedSlice(a),
        .complete = false,
    };
    defer bus.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }
    var complete = true;
    var iterator = bus.iterate();
    while (true) {
        const entry = (iterator.next(io) catch {
            complete = false;
            break;
        }) orelse break;
        if (names.items.len == max_entries) {
            complete = false;
            break;
        }
        // Real sysfs names are short ASCII; reject fixture/path impostors too.
        if (!safeName(entry.name)) continue;
        const copy = try a.dupe(u8, entry.name);
        errdefer a.free(copy);
        try names.append(a, copy);
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        if (std.mem.indexOfScalar(u8, name, ':') != null) continue;
        var device_dir = bus.openDir(io, name, .{}) catch continue;
        defer device_dir.close(io);
        const vid = hexNumber(device_dir, io, "idVendor", u16) orelse continue;
        const pid = hexNumber(device_dir, io, "idProduct", u16) orelse continue;
        var printer = (hexNumber(device_dir, io, "bDeviceClass", u8) orelse 0) == 7;
        for (names.items) |interface| {
            if (!interfaceOf(name, interface)) continue;
            var interface_dir = bus.openDir(io, interface, .{}) catch {
                complete = false;
                continue;
            };
            defer interface_dir.close(io);
            if ((hexNumber(interface_dir, io, "bInterfaceClass", u8) orelse 0) == 7) printer = true;
        }
        if (!printer) continue;
        if (result.items.len == max_devices) {
            complete = false;
            break;
        }
        var nodes: std.ArrayList(Node) = .empty;
        var driver: []const u8 = try a.dupe(u8, "");
        var device_id: []const u8 = "";
        var id_conflict = false;
        errdefer {
            a.free(driver);
            a.free(device_id);
            for (nodes.items) |node| a.free(node.path);
            nodes.deinit(a);
        }
        for (names.items) |interface| {
            if (!interfaceOf(name, interface)) continue;
            var interface_dir = bus.openDir(io, interface, .{}) catch continue;
            defer interface_dir.close(io);
            if ((hexNumber(interface_dir, io, "bInterfaceClass", u8) orelse 0) != 7) continue;
            // Linux usblp exposes its cached ID on the printer interface:
            // drivers/usb/class/usblp.c ieee1284_id_show. Reading this attribute
            // never opens a print node or asks the printer for a new ID.
            mergeDeviceId(a, &device_id, &id_conflict, try readDeviceId(a, interface_dir, io, "ieee1284_id"));
            if (driver.len == 0) {
                var link: [1024]u8 = undefined;
                if (interface_dir.readLink(io, "driver", &link)) |len| {
                    const value = try sanitize(a, std.fs.path.basename(link[0..len]), 128);
                    a.free(driver);
                    driver = value;
                } else |_| {}
            }
            // The interface's own usbmisc children establish identity. Looking
            // for /dev/usb/lp0 globally can attribute another printer's node.
            var misc = interface_dir.openDir(io, "usbmisc", .{ .iterate = true }) catch continue;
            defer misc.close(io);
            var children = misc.iterate();
            while (true) {
                const child = (children.next(io) catch {
                    complete = false;
                    break;
                }) orelse break;
                if (!lpName(child.name)) continue;
                // Compatibility with layouts exposing the interface through
                // the interface-owned usbmisc child's device symlink.
                const id_path = try std.fs.path.join(a, &.{ child.name, "device/ieee1284_id" });
                defer a.free(id_path);
                mergeDeviceId(a, &device_id, &id_conflict, try readDeviceId(a, misc, io, id_path));
                if (nodes.items.len == max_nodes) {
                    complete = false;
                    break;
                }
                const node_path = try std.fs.path.join(a, &.{ roots.dev, "usb", child.name });
                errdefer a.free(node_path);
                var duplicate = false;
                for (nodes.items) |node| if (std.mem.eql(u8, node.path, node_path)) {
                    duplicate = true;
                    break;
                };
                if (duplicate) {
                    a.free(node_path);
                    continue;
                }
                const kind: NodeKind = if (Io.Dir.cwd().statFile(io, node_path, .{})) |stat| switch (stat.kind) {
                    .character_device => .character,
                    .file => .regular,
                    else => .other,
                } else |err| switch (err) {
                    error.FileNotFound => .missing,
                    else => .unavailable,
                };
                try nodes.append(a, .{ .path = node_path, .kind = kind });
            }
        }
        const device_name = try a.dupe(u8, name);
        errdefer a.free(device_name);
        const manufacturer = try readText(a, device_dir, io, "manufacturer");
        errdefer a.free(manufacturer);
        const product = try readText(a, device_dir, io, "product");
        errdefer a.free(product);
        const serial = try readText(a, device_dir, io, "serial");
        errdefer a.free(serial);
        const owned_nodes = try nodes.toOwnedSlice(a);
        errdefer {
            for (owned_nodes) |node| a.free(node.path);
            a.free(owned_nodes);
        }
        try result.append(a, .{
            .name = device_name,
            .vid = vid,
            .pid = pid,
            .manufacturer = manufacturer,
            .product = product,
            .serial = serial,
            .driver = driver,
            .device_id = device_id,
            .nodes = owned_nodes,
        });
    }
    return .{ .devices = try result.toOwnedSlice(a), .complete = complete };
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.' and byte != ':') return false;
    return !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}
fn interfaceOf(device: []const u8, interface: []const u8) bool {
    return interface.len > device.len and std.mem.startsWith(u8, interface, device) and interface[device.len] == ':';
}
fn lpName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "lp") or name.len < 3 or name.len > 16) return false;
    for (name[2..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}
fn hexNumber(dir: Io.Dir, io: Io, name: []const u8, comptime T: type) ?T {
    var bytes: [32]u8 = undefined;
    const raw = dir.readFile(io, name, &bytes) catch return null;
    return std.fmt.parseInt(T, std.mem.trim(u8, raw, " \t\r\n"), 16) catch null;
}
fn readText(a: Allocator, dir: Io.Dir, io: Io, name: []const u8) ![]const u8 {
    var bytes: [1024]u8 = undefined;
    const raw = dir.readFile(io, name, &bytes) catch return a.dupe(u8, "");
    return sanitize(a, std.mem.trimEnd(u8, raw, "\r\n"), 256);
}

fn readDeviceId(a: Allocator, dir: Io.Dir, io: Io, name: []const u8) ![]const u8 {
    // The extra bytes distinguish an oversized/truncated file from a complete
    // 8192-byte identity with an optional sysfs line ending. Never turn a
    // truncated CMD:NOT_TSPL tail into a different complete language token.
    var bytes: [8195]u8 = undefined;
    const raw = dir.readFile(io, name, &bytes) catch return a.dupe(u8, "");
    if (raw.len == bytes.len) return a.dupe(u8, "");
    const value = std.mem.trimEnd(u8, raw, "\r\n");
    if (value.len == 0 or value.len > 8192) return a.dupe(u8, "");
    const view = std.unicode.Utf8View.init(value) catch return a.dupe(u8, "");
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |codepoint| if (forbiddenCodepoint(codepoint)) return a.dupe(u8, "");
    return a.dupe(u8, value);
}

fn mergeDeviceId(a: Allocator, current: *[]const u8, conflict: *bool, candidate: []const u8) void {
    if (conflict.* or candidate.len == 0) {
        a.free(candidate);
        return;
    }
    if (current.len == 0) {
        a.free(current.*);
        current.* = candidate;
        return;
    }
    if (!std.mem.eql(u8, current.*, candidate)) {
        a.free(current.*);
        current.* = "";
        conflict.* = true;
    }
    a.free(candidate);
}

fn forbiddenCodepoint(codepoint: u21) bool {
    return codepoint < 0x20 or codepoint == 0x7f or (codepoint >= 0x80 and codepoint <= 0x9f) or (codepoint >= 0x202a and codepoint <= 0x202e) or (codepoint >= 0x2066 and codepoint <= 0x2069);
}

/// Keep valid UTF-8, remove controls, and cap without splitting a codepoint.
pub fn sanitize(a: Allocator, raw: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < raw.len and out.items.len < limit) {
        const byte = raw[i];
        if (byte < 0x20 or byte == 0x7f) {
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try out.append(a, '?');
            i += 1;
            continue;
        };
        if (i + len > raw.len or !std.unicode.utf8ValidateSlice(raw[i .. i + len])) {
            try out.append(a, '?');
            i += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(raw[i .. i + len]) catch unreachable;
        // C1 controls and directional formatting have no place in labels.
        if (forbiddenCodepoint(codepoint)) {
            i += len;
            continue;
        }
        if (out.items.len + len > limit) break;
        try out.appendSlice(a, raw[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice(a);
}

fn fixture(dir: Io.Dir, io: Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = content });
}

test "USB class comes from interfaces; nodes belong to that device and regular files are detected" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const sys = try std.fs.path.join(a, &.{ root, "sys" });
    defer a.free(sys);
    const dev = try std.fs.path.join(a, &.{ root, "dev" });
    defer a.free(dev);
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-2/idVendor", "0416\n");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-2/idProduct", "5011\n");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-2/product", "Virtual\x00 Com Port\n");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-2:1.0/bInterfaceClass", "07\n");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-2:1.0/ieee1284_id", "MFG:Example;MDL:Label;CMD:TSPL;\n");
    try tmp.dir.createDirPath(io, "sys/bus/usb/devices/1-2:1.0/usbmisc/lp3");
    try fixture(tmp.dir, io, "dev/usb/lp3", "impostor");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-20/idVendor", "1234");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-20/idProduct", "abcd");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-20:1.0/bInterfaceClass", "07");
    try tmp.dir.createDirPath(io, "sys/bus/usb/devices/1-20:1.0/usbmisc/lp4");
    // No dev/usb/lp4: it must never inherit 1-2's lp3.
    try fixture(tmp.dir, io, "sys/bus/usb/devices/2-1/idVendor", "8888");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/2-1/idProduct", "9999");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/2-1/product", "Printer");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/2-1:1.0/bInterfaceClass", "ff");
    const snapshot = try scan(a, io, .{ .sysfs = sys, .dev = dev });
    defer snapshot.deinit(a);
    try std.testing.expect(snapshot.complete);
    try std.testing.expectEqual(@as(usize, 2), snapshot.devices.len);
    try std.testing.expectEqualStrings("Virtual Com Port", snapshot.devices[0].product);
    try std.testing.expectEqualStrings("MFG:Example;MDL:Label;CMD:TSPL;", snapshot.devices[0].device_id);
    try std.testing.expectEqualStrings("", snapshot.devices[1].device_id);
    try std.testing.expectEqual(NodeKind.regular, snapshot.devices[0].nodes[0].kind);
    try std.testing.expectEqual(NodeKind.missing, snapshot.devices[1].nodes[0].kind);
    const original = try tmp.dir.readFileAlloc(io, "dev/usb/lp3", a, .limited(32));
    defer a.free(original);
    try std.testing.expectEqualStrings("impostor", original);
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-2:1.1/bInterfaceClass", "07\n");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-2:1.1/ieee1284_id", "MFG:Different;MDL:Language;CMD:ZPL;\n");
    const conflicting = try scan(a, io, .{ .sysfs = sys, .dev = dev });
    defer conflicting.deinit(a);
    try std.testing.expectEqualStrings("", conflicting.devices[0].device_id);
}

test "missing sysfs is inconclusive; sanitization is bounded valid UTF-8" {
    const a = std.testing.allocator;
    const snapshot = try scan(a, std.testing.io, .{ .sysfs = "/this-path-does-not-exist-rediwm" });
    defer snapshot.deinit(a);
    try std.testing.expect(!snapshot.complete);
    const clean = try sanitize(a, "A\x00\xff\xc3\xa9\xe2\x80\xaeB", 4);
    defer a.free(clean);
    try std.testing.expectEqualStrings("A?é", clean);
}

test "USB inventory follows sysfs links and releases partial snapshots on allocation failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const sys = try std.fs.path.join(a, &.{ root, "sys" });
    defer a.free(sys);
    const dev = try std.fs.path.join(a, &.{ root, "dev" });
    defer a.free(dev);
    try fixture(tmp.dir, io, "hardware/3-1/idVendor", "0416");
    try fixture(tmp.dir, io, "hardware/3-1/idProduct", "5011");
    try fixture(tmp.dir, io, "hardware/3-1/3-1:1.0/bInterfaceClass", "07");
    try fixture(tmp.dir, io, "hardware/3-1/3-1:1.0/ieee1284_id", "MFG:Example;MDL:Label;CMD:TSPL;\n");
    try tmp.dir.createDirPath(io, "hardware/3-1/3-1:1.0/usbmisc/lp7");
    try tmp.dir.symLink(io, "../..", "hardware/3-1/3-1:1.0/usbmisc/lp7/device", .{ .is_directory = true });
    try tmp.dir.createDirPath(io, "sys/bus/usb/devices");
    try tmp.dir.symLink(io, "../../../../hardware/3-1", "sys/bus/usb/devices/3-1", .{ .is_directory = true });
    try tmp.dir.symLink(io, "../../../../hardware/3-1/3-1:1.0", "sys/bus/usb/devices/3-1:1.0", .{ .is_directory = true });
    try tmp.dir.symLink(io, "../../../../drivers/usblp", "hardware/3-1/3-1:1.0/driver", .{ .is_directory = true });
    try tmp.dir.createDirPath(io, "dev/usb");
    // A real character device can be stat'ed without opening it or root/mknod.
    try tmp.dir.symLink(io, "/dev/null", "dev/usb/lp7", .{});
    const Case = struct {
        fn run(allocator: Allocator, roots: Roots) !void {
            const snapshot = try scan(allocator, std.testing.io, roots);
            defer snapshot.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 1), snapshot.devices.len);
            try std.testing.expectEqualStrings("usblp", snapshot.devices[0].driver);
            try std.testing.expectEqualStrings("MFG:Example;MDL:Label;CMD:TSPL;", snapshot.devices[0].device_id);
            try std.testing.expectEqual(NodeKind.character, snapshot.devices[0].nodes[0].kind);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Case.run, .{Roots{ .sysfs = sys, .dev = dev }});
}

test "USB IEEE 1284 identity stays complete and rejects oversized malformed or controlled data" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const sys = try std.fs.path.join(a, &.{ root, "sys" });
    defer a.free(sys);
    const dev = try std.fs.path.join(a, &.{ root, "dev" });
    defer a.free(dev);
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-1/idVendor", "0416");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-1/idProduct", "5011");
    try fixture(tmp.dir, io, "sys/bus/usb/devices/1-1:1.0/bInterfaceClass", "07");
    // The usbmisc fallback is scoped to this interface, not a global lp path.
    const id_path = "sys/bus/usb/devices/1-1:1.0/usbmisc/lp0/device/ieee1284_id";
    try fixture(tmp.dir, io, id_path, "MFG:Example;MDL:Label;CMD:TSPL;");
    {
        const snapshot = try scan(a, io, .{ .sysfs = sys, .dev = dev });
        defer snapshot.deinit(a);
        try std.testing.expectEqualStrings("MFG:Example;MDL:Label;CMD:TSPL;", snapshot.devices[0].device_id);
    }
    for ([_][]const u8{ "MFG:Example;CMD:TS\x00PL;", "MFG:Example;CMD:TS\x1bPL;", "MFG:Example;CMD:TS\xffPL;", "MFG:Example;CMD:TS\xe2\x80\xaePL;" }) |invalid| {
        try fixture(tmp.dir, io, id_path, invalid);
        const snapshot = try scan(a, io, .{ .sysfs = sys, .dev = dev });
        defer snapshot.deinit(a);
        try std.testing.expectEqualStrings("", snapshot.devices[0].device_id);
    }
    var long: [8192]u8 = @splat('x');
    long[0..4].* = "DES:".*;
    const tail = ";CMD:TSPL;";
    @memcpy(long[long.len - tail.len ..], tail);
    try fixture(tmp.dir, io, id_path, &long);
    {
        const snapshot = try scan(a, io, .{ .sysfs = sys, .dev = dev });
        defer snapshot.deinit(a);
        try std.testing.expectEqualStrings(&long, snapshot.devices[0].device_id);
    }
    const oversized = try std.mem.concat(a, u8, &.{ &long, "FAKE" });
    defer a.free(oversized);
    try fixture(tmp.dir, io, id_path, oversized);
    const snapshot = try scan(a, io, .{ .sysfs = sys, .dev = dev });
    defer snapshot.deinit(a);
    try std.testing.expectEqualStrings("", snapshot.devices[0].device_id);
}

test "CUPS USB identity needs a unique decoded serial; model names never establish identity" {
    const template: Device = .{ .name = "1-2", .vid = 0x0416, .pid = 0x5011, .manufacturer = "", .product = "", .serial = "A B+C", .driver = "", .nodes = &.{} };
    var devices = [_]Device{template};
    var snapshot: Snapshot = .{ .devices = &devices, .complete = true };
    const found = matchQueue(&snapshot, "usb://Vendor/Model?serial=A%20B%2bC&interface=1");
    try std.testing.expect(found.conclusive);
    try std.testing.expect(found.device == &devices[0]);
    try std.testing.expect(matchQueue(&snapshot, "usb://Vendor/Model?serial=unplugged").conclusive);
    try std.testing.expect(!matchQueue(&snapshot, "usb://Vendor/Model").conclusive);
    try std.testing.expect(!matchQueue(&snapshot, "usb://Vendor/Model?serial=%ZZ").conclusive);
    try std.testing.expect(!matchQueue(&snapshot, "usb://Vendor/Model?serial=A%00").conclusive);
    try std.testing.expect(!matchQueue(&snapshot, "usb://Vendor/Model?serial=A&serial=B").conclusive);
    snapshot.complete = false;
    try std.testing.expect(!matchQueue(&snapshot, "usb://Vendor/Model?serial=unplugged").conclusive);
    snapshot.complete = true;
    devices[0].serial = "";
    try std.testing.expect(!matchQueue(&snapshot, "usb://Vendor/Model?serial=unplugged").conclusive);
    var duplicates = [_]Device{ template, template };
    snapshot.devices = &duplicates;
    try std.testing.expect(!matchQueue(&snapshot, "usb://Vendor/Model?serial=A%20B%2BC").conclusive);
    try std.testing.expect(matchQueue(&snapshot, "usb://Vendor/Model?serial=A%20B%2BC").device == null);
}
