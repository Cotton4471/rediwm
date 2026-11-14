//! Print requests and replies through the print helper, and publishing the clipboard.

const std = @import("std");
const c = @import("c.zig");
const a = std.heap.c_allocator;
const main_mod = @import("main.zig");
const Client = main_mod.Client;
const ClipboardSource = main_mod.ClipboardSource;

/// Asks the helper for the print dialog; it answers only on failure.
pub fn requestPrint(self: *Client) void {
    self.app.print_request = false;
    if (self.print_fd >= 0) {
        const request: u8 = 'p';
        if (c.api.write(self.print_fd, &request, 1) == 1) return;
        self.closePrint();
    }
    self.app.showMessage(@import("i18n").tr("Printing is not available."));
}

pub fn readPrintReplies(self: *Client) void {
    var buf: [16]u8 = undefined;
    const n = c.api.read(self.print_fd, &buf, buf.len);
    if (n <= 0) {
        if (n < 0 and std.posix.errno(n) == .INTR) return;
        return self.closePrint();
    }
    for (buf[0..@intCast(n)]) |reply| switch (reply) {
        'u' => self.app.showMessage(@import("i18n").tr("No print service answered (xdg-desktop-portal).")),
        'f' => self.app.showMessage(@import("i18n").tr("The document could not be printed.")),
        else => {},
    };
}

pub fn closePrint(self: *Client) void {
    if (self.print_fd < 0) return;
    _ = c.api.close(self.print_fd);
    self.print_fd = -1;
}

pub fn publishClipboard(self: *Client) void {
    const mgr = self.data_manager orelse return;
    const dev = self.data_device orelse return;
    const text = self.app.clipboard_text orelse return;

    const source = mgr.createDataSource() catch return;
    errdefer source.destroy();

    const clip = a.create(ClipboardSource) catch return;
    clip.* = .{
        .client = self,
        .proxy = source,
        .text = a.dupeSentinel(u8, text, 0) catch return,
    };
    source.setListener(*ClipboardSource, ClipboardSource.event, clip);
    source.offer("text/plain;charset=utf-8");
    source.offer("text/plain");

    dev.setSelection(source, self.input_serial);
    if (self.clipboard_source) |cs| cs.destroy();
    self.clipboard_source = clip;
    self.app.clipboard_request = false;
}
