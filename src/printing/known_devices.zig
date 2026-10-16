//! Hardware observations, never an automatic language or resolution choice.
//! Shared USB IDs cover differently branded and configured hardware.
const std = @import("std");
const tools = @import("tools.zig");

pub const Device = struct {
    vid: u16,
    pid: u16,
    language_hint: tools.Language,
    resolution_hint_dpi: u16,
    provisional: bool,
    note: []const u8,
    driver_project: []const u8,
};

pub const devices = [_]Device{.{
    .vid = 0x0416,
    .pid = 0x5011,
    .language_hint = .tspl,
    .resolution_hint_dpi = 203,
    .provisional = true,
    .driver_project = "Third-party TSPL driver: RunTheWall/tspl-cups-driver — https://github.com/RunTheWall/tspl-cups-driver . Review model compatibility; RediWM does not install it.",
    .note = "One field report associates this USB ID with TSPL and 4 x 6 inch labels. The unit advertised 300 dpi but reportedly sized correctly at 203 dpi. Rebranded devices may differ; confirm language and resolution on its self-test sheet. This observation has not completed hardware qualification.",
}};

pub fn lookup(vid: u16, pid: u16) ?*const Device {
    for (&devices) |*device| if (device.vid == vid and device.pid == pid) return device;
    return null;
}

test "a shared USB ID is explicitly provisional evidence" {
    const hint = lookup(0x0416, 0x5011).?;
    try std.testing.expect(hint.provisional);
    try std.testing.expect(std.mem.indexOf(u8, hint.note, "203") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint.note, "300") != null);
    try std.testing.expect(lookup(0x0416, 0x5012) == null);
}
