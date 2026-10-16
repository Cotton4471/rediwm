//! Pure setup validation. A discovered backend is evidence from CUPS, never an
//! arbitrary program, filesystem path, credential-bearing URI or guessed driver.
const std = @import("std");
const A = std.mem.Allocator;

pub const max_name = 127;
pub const max_uri = 8192;

pub fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > max_name or !std.unicode.utf8ValidateSlice(value) or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    var iter = std.unicode.Utf8View.initUnchecked(value).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (cp < 128) {
            const ch: u8 = @intCast(cp);
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
        } else if (cp <= 0x9f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) return false;
    }
    return true;
}

pub fn nameExists(value: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.ascii.eqlIgnoreCase(value, name)) return true;
    return false;
}

/// CUPS queue names are case-insensitive. Explicit suffixes avoid replacing an
/// existing queue, including when truncating a long model name.
pub fn uniqueName(a: A, model: []const u8, names: []const []const u8) ![]const u8 {
    var base: [max_name]u8 = undefined;
    var len: usize = 0;
    for (model) |ch| {
        if (len == base.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-') {
            base[len] = ch;
            len += 1;
        } else if (len > 0 and base[len - 1] != '-') {
            base[len] = '-';
            len += 1;
        }
    }
    while (len > 0 and (base[len - 1] == '-' or base[len - 1] == '.')) len -= 1;
    if (len == 0) {
        @memcpy(base[0..7], "Printer");
        len = 7;
    }
    if (!nameExists(base[0..len], names)) return a.dupe(u8, base[0..len]);
    var candidate: [max_name]u8 = undefined;
    for (2..10000) |suffix| {
        var ending: [12]u8 = undefined;
        const tail = try std.fmt.bufPrint(&ending, "-{d}", .{suffix});
        const prefix_len = @min(len, max_name - tail.len);
        @memcpy(candidate[0..prefix_len], base[0..prefix_len]);
        @memcpy(candidate[prefix_len..][0..tail.len], tail);
        const name = candidate[0 .. prefix_len + tail.len];
        if (!nameExists(name, names)) return a.dupe(u8, name);
    }
    return error.NoUniqueName;
}

fn validEscapes(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        if (ch < 0x21 or ch > 0x7e or ch == '\\' or ch == '#') return false;
        if (ch != '%') continue;
        if (i + 2 >= value.len) return false;
        const high = std.fmt.charToDigit(value[i + 1], 16) catch return false;
        const low = std.fmt.charToDigit(value[i + 2], 16) catch return false;
        const decoded: u8 = high * 16 + low;
        if (decoded < 0x20 or decoded == 0x7f or decoded == '\\') return false;
        i += 2;
    }
    return true;
}

/// Typed addresses use a fixed network scheme allow-list. Installed USB/vendor
/// backends require an exact current CUPS discovery match in admin.Manager too.
/// No resolver, backend executable or network probe runs here.
pub fn validateUri(uri: []const u8, discovered: bool) !void {
    if (uri.len == 0 or uri.len > max_uri or !validEscapes(uri)) return error.InvalidUri;
    if (discovered and std.mem.indexOf(u8, uri, "://") == null) {
        const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return error.InvalidUri;
        const backend = uri[0..colon];
        for ([_][]const u8{ "ipp", "ipps", "socket", "lpd", "usb", "dnssd" }) |standard| if (std.mem.eql(u8, backend, standard)) return error.InvalidUri;
        if (backend.len == 0 or backend.len > 64 or !std.ascii.isLower(backend[0])) return error.InvalidUri;
        for (backend) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-' and ch != '_' and ch != '+') return error.InvalidUri;
        for ([_][]const u8{ "file", "smb", "smbs", "pdf", "pipe", "exec", "command", "beh", "hpfax", "mailto" }) |forbidden| if (std.mem.eql(u8, backend, forbidden)) return error.UnsupportedScheme;
        const path = uri[colon + 1 ..];
        if (path.len < 2 or path[0] != '/' or path[1] == '/' or std.mem.indexOfScalar(u8, path, '@') != null) return error.InvalidUri;
        return;
    }
    const split = std.mem.indexOf(u8, uri, "://") orelse return error.InvalidUri;
    const scheme = uri[0..split];
    const network = std.mem.eql(u8, scheme, "ipp") or std.mem.eql(u8, scheme, "ipps") or
        std.mem.eql(u8, scheme, "socket") or std.mem.eql(u8, scheme, "lpd");
    if (!network and !(discovered and (std.mem.eql(u8, scheme, "usb") or std.mem.eql(u8, scheme, "dnssd")))) return error.UnsupportedScheme;
    const rest = uri[split + 3 ..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUri;
    if (!network) return;
    // Percent encoding in a network authority can conceal credentials or alter
    // the host interpreted by a backend. DNS-SD service names are different.
    if (std.mem.indexOfScalar(u8, authority, '%') != null) return error.InvalidUri;
    var host = authority;
    var port: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUri;
        if (close < 3) return error.InvalidUri;
        host = authority[1..close];
        _ = std.Io.net.IpAddress.parseIp6(host, 631) catch return error.InvalidUri;
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return error.InvalidUri;
            port = authority[close + 2 ..];
        }
    } else {
        if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port = authority[colon + 1 ..];
        }
        if (host.len == 0 or host[0] == '.' or host[host.len - 1] == '-') return error.InvalidUri;
        for (host) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '.') return error.InvalidUri;
        _ = std.Io.net.HostName.init(host) catch return error.InvalidUri;
    }
    if (port) |text| {
        if (text.len == 0) return error.InvalidUri;
        for (text) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidUri;
        if ((std.fmt.parseInt(u16, text, 10) catch return error.InvalidUri) == 0) return error.InvalidUri;
    }
}

pub const Ppd = struct {
    name: []const u8,
    make_model: []const u8 = "",
    device_id: []const u8 = "",
};

fn idField(id: []const u8, keys: []const []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, id, ';');
    var found: ?[]const u8 = null;
    while (fields.next()) |field| {
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse continue;
        const key = std.mem.trim(u8, field[0..colon], " \t");
        for (keys) |candidate| if (std.ascii.eqlIgnoreCase(key, candidate)) {
            const value = std.mem.trim(u8, field[colon + 1 ..], " \t");
            // Conflicting duplicate identity fields are not evidence of a match.
            if (found) |previous| {
                if (!std.ascii.eqlIgnoreCase(previous, value)) return null;
            }
            found = value;
        };
    }
    if (found) |value| if (value.len > 0) return value;
    return null;
}

fn sameDevice(left: []const u8, right: []const u8) bool {
    const mfg = &.{ "MFG", "MANUFACTURER" };
    const model = &.{ "MDL", "MODEL" };
    const lm = idField(left, mfg) orelse return false;
    const rm = idField(right, mfg) orelse return false;
    const ld = idField(left, model) orelse return false;
    const rd = idField(right, model) orelse return false;
    if (!std.ascii.eqlIgnoreCase(lm, rm) or !std.ascii.eqlIgnoreCase(ld, rd)) return false;
    const commands = &.{ "CMD", "COMMAND SET" };
    const lc = idField(left, commands) orelse return true;
    const rc = idField(right, commands) orelse return true;
    var left_commands = std.mem.splitScalar(u8, lc, ',');
    while (left_commands.next()) |left_command| {
        var right_commands = std.mem.splitScalar(u8, rc, ',');
        while (right_commands.next()) |right_command| {
            const l = std.mem.trim(u8, left_command, " \t");
            const r = std.mem.trim(u8, right_command, " \t");
            if (l.len > 0 and std.ascii.eqlIgnoreCase(l, r)) return true;
        }
    }
    return false;
}

/// Only a unique exact IEEE-1284 manufacturer+model match is automatic.
/// make_model display text, VID:PID and undocumented ppd-match scores are never
/// used to guess compatibility. Ambiguous candidates require an explicit choice.
pub fn driverMatch(device_id: []const u8, ppds: []const Ppd) ?usize {
    if (device_id.len > max_uri) return null;
    var result: ?usize = null;
    for (ppds, 0..) |ppd, index| {
        if (!sameDevice(device_id, ppd.device_id)) continue;
        if (result != null) return null;
        result = index;
    }
    return result;
}

test {
    _ = @import("setup_tests.zig");
}
