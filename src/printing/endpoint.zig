//! Complete endpoint identity, without credentials, redirects or TLS downgrade.
const std = @import("std");

pub const Endpoint = struct {
    unix: ?[]const u8 = null,
    host: []const u8 = "localhost",
    authority: []const u8 = "localhost",
    server: []const u8 = "localhost",
    uri: []const u8 = "",
    port: u16 = 631,
    resource: []const u8 = "/",
    version_minor: u8 = 1,
};

/// CUPS_SERVER / ServerName accepts a Unix socket or host[:port][/version=1.1].
/// IPP versions are retained so requests can honour an explicit 1.0 selection.
pub fn parseServer(value: []const u8) !Endpoint {
    if (value.len == 0 or value.len > 1024) return error.UnsupportedServer;
    if (value[0] == '/') {
        if (value.len >= 108 or std.mem.indexOfScalar(u8, value, 0) != null) return error.UnsupportedServer;
        return .{ .unix = value, .server = value };
    }
    const rest = if (std.mem.startsWith(u8, value, "ipp://")) value[6..] else value;
    if (std.mem.indexOf(u8, rest, "://") != null) return error.UnsupportedServer;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var result = try authority(rest[0..slash]);
    const suffix = rest[slash..];
    if (suffix.len != 0 and !std.mem.eql(u8, suffix, "/")) {
        if (std.mem.eql(u8, suffix, "/version=1.0")) result.version_minor = 0 else if (!std.mem.eql(u8, suffix, "/version=1.1")) return error.UnsupportedServer;
    }
    return result;
}

/// Only direct IPP is probed. ipps remains unavailable until TLS can validate
/// certificates; interpreting it as cleartext would disclose private traffic.
pub fn parsePrinterUri(uri: []const u8) !Endpoint {
    if (uri.len > 2048 or !std.mem.startsWith(u8, uri, "ipp://")) return error.UnsupportedServer;
    const rest = uri[6..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var result = try authority(rest[0..slash]);
    result.resource = if (slash == rest.len) "/" else rest[slash..];
    result.uri = uri;
    try validateResource(result.resource);
    return result;
}

pub fn validateResource(value: []const u8) !void {
    if (value.len == 0 or value[0] != '/' or value.len > 2048) return error.InvalidResource;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e or byte == '#') return error.InvalidResource;
}

fn authority(value: []const u8) !Endpoint {
    if (value.len == 0 or value.len > 320) return error.UnsupportedServer;
    for (value) |byte| if (byte <= 0x20 or byte >= 0x7f or byte == '@' or byte == '\\' or byte == '?' or byte == '#') return error.UnsupportedServer;
    var host = value;
    var port: u16 = 631;
    if (value[0] == '[') {
        const end = std.mem.indexOfScalar(u8, value, ']') orelse return error.UnsupportedServer;
        host = value[1..end];
        // Interface identifiers require OS lookup and are deliberately not
        // accepted in this initial bounded transport.
        _ = std.Io.net.IpAddress.parseIp6(host, 631) catch return error.UnsupportedServer;
        if (end + 1 < value.len) {
            if (value[end + 1] != ':') return error.UnsupportedServer;
            port = try parsePort(value[end + 2 ..]);
        }
    } else {
        if (std.mem.indexOfScalar(u8, value, ':')) |colon| {
            host = value[0..colon];
            port = try parsePort(value[colon + 1 ..]);
        }
        _ = std.Io.net.HostName.init(host) catch return error.UnsupportedServer;
    }
    return .{ .host = host, .authority = value, .server = value, .port = port };
}

fn parsePort(value: []const u8) !u16 {
    if (value.len == 0) return error.UnsupportedServer;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return error.UnsupportedServer;
    const port = std.fmt.parseInt(u16, value, 10) catch return error.UnsupportedServer;
    if (port == 0) return error.UnsupportedServer;
    return port;
}

test "CUPS endpoints retain identity and reject encryption, credentials and ambiguity" {
    const t = std.testing;
    try t.expectEqualStrings("/tmp/cups.sock", (try parseServer("/tmp/cups.sock")).unix.?);
    const remote = try parseServer("printer.example:8631/version=1.0");
    try t.expectEqualStrings("printer.example", remote.host);
    try t.expectEqual(@as(u16, 8631), remote.port);
    try t.expectEqual(@as(u8, 0), remote.version_minor);
    try t.expectEqual(@as(u16, 631), (try parseServer("ipp://[::1]/version=1.1")).port);
    const printer = try parsePrinterUri("ipp://127.0.0.1:8631/ipp/print?queue=1");
    try t.expectEqualStrings("/ipp/print?queue=1", printer.resource);
    for ([_][]const u8{ "", "ipps://printer", "https://printer", "user@printer", "printer:0", "printer:65536", "printer\r\nHost: x", "printer/path", "::1", "[::1]:bad", "printer/version=2.0" }) |bad| try t.expectError(error.UnsupportedServer, parseServer(bad));
    try t.expectError(error.UnsupportedServer, parsePrinterUri("ipps://printer/ipp/print"));
    try t.expectError(error.UnsupportedServer, parsePrinterUri("ipp://user:secret@printer/ipp/print"));
    try t.expectError(error.InvalidResource, parsePrinterUri("ipp://printer/ipp/print#fragment"));
}
