//! Per-launch Foot colours. No user terminal configuration is overwritten.
const std = @import("std");
const Theme = @import("ui").theme.Theme;
const A = std.mem.Allocator;

const names = .{ "bg", "fg", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "bright_black", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan", "bright_white" };
const options = .{ "background", "foreground", "regular0", "regular1", "regular2", "regular3", "regular4", "regular5", "regular6", "regular7", "bright0", "bright1", "bright2", "bright3", "bright4", "bright5", "bright6", "bright7" };

pub fn enabled(t: Theme) bool {
    inline for (names) |name| if (@field(t, "terminal_" ++ name) != null) return true;
    return t.terminal_cursor != null;
}

/// Uses the caller's short-lived launch arena; original arguments are borrowed.
/// The helper probes Foot's config dialect outside the compositor, then execs
/// Foot in the same process/scope. Other terminal emulators keep their argv.
pub fn wrap(a: A, io: std.Io, args: []const []const u8, t: Theme) ![]const []const u8 {
    if (args.len == 0 or !enabled(t) or !std.mem.eql(u8, std.fs.path.basename(args[0]), "foot")) return args;
    const directory = try std.process.executableDirPathAlloc(io, a);
    const result = try a.alloc([]const u8, args.len + 2);
    result[0] = try std.fs.path.join(a, &.{ directory, "rediwm-theme" });
    result[1] = "terminal";
    @memcpy(result[2..], args);
    return result;
}

fn hex(a: A, color: [4]f32) ![]const u8 {
    var rgb: [3]u8 = undefined;
    for (&rgb, color[0..3]) |*byte, value| byte.* = @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
    return std.fmt.allocPrint(a, "{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] });
}

/// Newer Foot has dark/light palettes; older Foot has a single [colors].
/// Strings are owned by the caller's arena. Pack overrides precede explicit
/// command-line overrides, so a custom launcher can still choose its colours.
pub fn argv(a: A, args: []const []const u8, t: Theme, modern: bool) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    try result.append(a, args[0]);
    const sections: []const []const u8 = if (modern) &.{ "colors-dark", "colors-light" } else &.{"colors"};
    for (sections) |section| {
        inline for (names, options) |name, option| {
            if (@field(t, "terminal_" ++ name)) |color| {
                try result.append(a, try std.fmt.allocPrint(a, "--override={s}.{s}={s}", .{ section, option, try hex(a, color) }));
            }
        }
        if (t.terminal_cursor) |color| {
            const bg = try hex(a, t.terminal_bg orelse t.window_bg);
            const fg = try hex(a, color);
            if (modern) try result.append(a, try std.fmt.allocPrint(a, "--override={s}.cursor={s} {s}", .{ section, bg, fg }));
        }
    }
    if (!modern) if (t.terminal_cursor) |color| {
        try result.append(a, try std.fmt.allocPrint(a, "--override=cursor.color={s} {s}", .{ try hex(a, t.terminal_bg orelse t.window_bg), try hex(a, color) }));
    };
    try result.appendSlice(a, args[1..]);
    return result.toOwnedSlice(a);
}

test "Foot palettes preserve arguments and support both config dialects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Theme = .{ .terminal_fg = .{ 1, 0.5, 0, 1 }, .terminal_bg = .{ 0, 0, 0, 1 }, .terminal_cursor = .{ 1, 1, 1, 1 } };
    const args: []const []const u8 = &.{ "foot", "-D", "/tmp/a b", "-e", "printf", "%s", "literal; text" };
    for ([_]bool{ false, true }) |modern| {
        const result = try argv(a, args, t, modern);
        try std.testing.expectEqualStrings("foot", result[0]);
        for (args[1..], result[result.len - (args.len - 1) ..]) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
        const expected = if (modern) "--override=colors-dark.foreground=ff8000" else "--override=colors.foreground=ff8000";
        var found = false;
        for (result) |arg| if (std.mem.eql(u8, arg, expected)) {
            found = true;
        };
        try std.testing.expect(found);
    }
    try std.testing.expect(!enabled(.{}));
    try std.testing.expectEqualSlices([]const u8, args, try wrap(a, std.testing.io, args, .{}));
}
