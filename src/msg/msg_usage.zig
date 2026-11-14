//! rediwm-msg usage and per-command help.

const std = @import("std");
const protocol = @import("protocol");

pub const local_commands = .{
    .raw = .{ .synopsis = "[JSON|-]", .description = "Send raw JSON from an argument or stdin" },
    .doctor = .{ .synopsis = "", .description = "Run compositor and environment diagnostics" },
    .action = .{ .synopsis = "<command> [args]", .description = "Run one of the actions below" },
};

pub const TopCommandTag = blk: {
    @setEvalBranchQuota(20_000);
    for (protocol.commands.specs) |s| {
        if (s.cli) |cli| {
            for (@typeInfo(@TypeOf(local_commands)).@"struct".field_names) |local| {
                for (&[_][]const u8{cli.name} ++ cli.aliases) |name| {
                    if (std.mem.eql(u8, local, name)) @compileError("CLI name shadows local command: " ++ name);
                }
            }
        }
    }
    var names: []const []const u8 = &.{};
    for (@typeInfo(@TypeOf(local_commands)).@"struct".field_names) |name| names = names ++ .{name};
    for (@typeInfo(protocol.commands.CliTag(false)).@"enum".field_names) |name| names = names ++ .{name};
    break :blk @Enum(u8, .exhaustive, names, &std.simd.iota(u8, names.len));
};

pub fn lookupTopCommand(name: []const u8) ?TopCommandTag {
    inline for (@typeInfo(@TypeOf(local_commands)).@"struct".field_names) |local| {
        if (std.mem.eql(u8, name, local)) return @field(TopCommandTag, local);
    }
    const tag = protocol.commands.lookupCli(false, name) orelse return null;
    return @enumFromInt(@intFromEnum(tag) + @typeInfo(@TypeOf(local_commands)).@"struct".field_names.len);
}

pub fn printUsage() void {
    std.debug.print(
        \\rediwm-msg: IPC CLI for rediwm
        \\
        \\Usage: rediwm-msg [options] <command>
        \\
        \\Options:
        \\  -s, --socket <PATH>   Path to IPC Unix domain socket
        \\  -t, --timeout <MS>    Socket request/response timeout in ms
        \\  --raw [JSON]          Send raw JSON payload (from arg or stdin)
        \\  --json                Output JSON payload
        \\  -h, --help            Show help
        \\
        \\Commands:
        \\
    , .{});
    inline for (@typeInfo(@TypeOf(local_commands)).@"struct".field_names) |name| {
        const c = @field(local_commands, name);
        std.debug.print("  {s} {s}  {s}\n", .{ name, c.synopsis, c.description });
    }
    inline for (protocol.commands.specs) |s| {
        if (comptime s.cli) |cli| printCommandHelp("", cli, s.description);
    }
    std.debug.print("\nActions:\n", .{});
    inline for (protocol.commands.specs) |s| {
        if (comptime s.action_cli) |cli| printCommandHelp("action ", cli, s.description);
    }
    std.debug.print(
        "\nOther IPC commands (via raw JSON):\n" ++
            "  rediwm-msg raw '{{\"version\":1,\"command\":\"get_theme\"}}'\n" ++
            "  rediwm-msg raw '{{\"version\":1,\"command\":\"set_dnd\",\"params\":{{\"enabled\":true}}}}'\n",
        .{},
    );
    inline for (protocol.commands.specs) |s| {
        if (comptime s.cli == null and s.action_cli == null)
            std.debug.print("  {s}  {s}\n", .{ s.wire(), s.description });
    }
    std.debug.print("  Use 'rediwm-msg describe' for parameter schemas.\n", .{});
}

pub fn printCommandHelp(prefix: []const u8, cli: protocol.commands.CliSpec, description: []const u8) void {
    std.debug.print("  {s}{s} {s}  {s}", .{ prefix, cli.name, cli.synopsis, description });
    if (cli.aliases.len > 0) {
        std.debug.print(" (aliases:", .{});
        for (cli.aliases) |alias| std.debug.print(" {s}", .{alias});
        std.debug.print(")", .{});
    }
    std.debug.print("\n", .{});
}
