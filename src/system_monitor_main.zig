const std = @import("std");
pub fn main(init: std.process.Init) !void {
    defer {
        if (@import("memory").deinit()) std.log.err("System Monitor memory leaks reported above", .{});
    }
    defer @import("ui").text.deinit();
    defer @import("ui").shell_icons.deinit();
    const args = init.minimal.args.vector;
    if (args.len > 1) {
        const arg = std.mem.span(args[1]);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: rediwm-monitor\n\nSystem Monitor for RediWM.\nCtrl+F: search  Arrows: select  Delete: end process\nShift+Delete: force quit (confirmation)  Ctrl+Q: close\n", .{});
            return;
        }
        return error.UnexpectedArgument;
    }
    try @import("system_monitor/client.zig").run(init);
}
