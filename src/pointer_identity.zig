//! Persistent pointer identity, independent of libinput and the event loop.
//! Hardware uniq/serial survives port changes. Without one, ID_PATH identifies
//! the physical connection: identical unnumbered peripherals swapped between
//! ports cannot be distinguished. Callers must reject duplicate live keys.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const prefix = "pointer-v1:";
pub const Identity = struct {
    key: [prefix.len + Sha256.digest_length * 2]u8,
    basis: enum { unique, path },
};

pub const Facts = struct {
    bus: u32,
    vendor: u32,
    product: u32,
    name: []const u8,
    uniq: ?[]const u8 = null,
    serial: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub fn build(facts: Facts) ?Identity {
    const source: []const u8, const stable: []const u8 = if (nonempty(facts.uniq)) |value|
        .{ "uniq", value }
    else if (nonempty(facts.serial)) |value|
        .{ "serial", value }
    else if (nonempty(facts.path)) |value|
        .{ "path", value }
    else
        return null;
    var hash = Sha256.init(.{});
    hash.update(prefix);
    var ids: [12]u8 = undefined;
    std.mem.writeInt(u32, ids[0..4], facts.bus, .little);
    std.mem.writeInt(u32, ids[4..8], facts.vendor, .little);
    std.mem.writeInt(u32, ids[8..12], facts.product, .little);
    hash.update(&ids);
    // Length framing prevents hardware strings containing separators from
    // accidentally identifying a different combination of fields.
    for ([_][]const u8{ facts.name, source, stable, nonempty(facts.interface) orelse "" }) |field| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, @intCast(field.len), .little);
        hash.update(&len);
        hash.update(field);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return .{
        .key = prefix.* ++ std.fmt.bytesToHex(digest, .lower),
        .basis = if (std.mem.eql(u8, source, "path")) .path else .unique,
    };
}

fn nonempty(value: ?[]const u8) ?[]const u8 {
    const bytes = value orelse return null;
    return if (bytes.len != 0) bytes else null;
}

test {
    _ = @import("pointer_identity_tests.zig");
}
