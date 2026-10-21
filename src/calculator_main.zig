const std = @import("std");

pub fn main(init: std.process.Init) !void {
    defer {
        if (@import("memory").deinit()) std.log.err("Calculator memory leaks reported above", .{});
    }
    defer @import("ui").text.deinit();
    defer @import("ui").shell_icons.deinit();
    const args = init.minimal.args.vector;
    if (args.len > 1) {
        const arg = std.mem.span(args[1]);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: rediwm-calculator\n\nCalculator for RediWM.\nType arithmetic and parentheses, then Enter or =.\nBackspace: undo digit  Escape/Delete: clear  F9: change sign\nPercent divides by 100. Ctrl+Q: close.\n", .{});
            return;
        }
        return error.UnexpectedArgument;
    }
    try @import("calculator/client.zig").run(init);
}
