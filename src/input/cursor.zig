//! Input cursor: theme, named shapes, busy cursor and holds.

const std = @import("std");
const Input = @import("../Input.zig");
const wlr = @import("wlroots");
const cursor_theme = @import("../cursor_theme.zig");
const log = std.log.scoped(.input);

pub fn createCursorManager(theme: []const u8, size: u32) ?*wlr.XcursorManager {
    var buf: [128]u8 = undefined;
    const name: ?[*:0]const u8 = if (cursor_theme.managerTheme(theme)) |t|
        (std.fmt.bufPrintSentinel(&buf, "{s}", .{t}, 0) catch return null).ptr
    else
        null;
    return wlr.XcursorManager.create(name, size) catch null;
}

pub fn rememberCursorTheme(input: *Input, theme: []const u8, size: u32) void {
    input.cursor_theme_len = @min(theme.len, input.cursor_theme_name.len);
    @memcpy(input.cursor_theme_name[0..input.cursor_theme_len], theme[0..input.cursor_theme_len]);
    input.cursor_theme_size = size;
}

pub fn cursorThemeName(input: *const Input) []const u8 {
    return input.cursor_theme_name[0..input.cursor_theme_len];
}

/// Config reload: switch to a changed `cursor_theme`/`cursor_size`.
pub fn applyCursorTheme(input: *Input, theme: []const u8, size: u32) void {
    applyCursorThemeImpl(input, theme, size, false);
}

/// An installed pack can replace cursor bytes without changing its name.
pub fn reloadCursorTheme(input: *Input) void {
    applyCursorThemeImpl(input, input.server.config.input.cursor_theme, input.server.config.input.cursor_size, true);
}

pub fn applyCursorThemeImpl(input: *Input, theme: []const u8, size: u32, force: bool) void {
    if (!force and size == input.cursor_theme_size and std.mem.eql(u8, theme, input.cursor_theme_name[0..input.cursor_theme_len])) return;
    const mgr = createCursorManager(theme, size) orelse {
        log.warn("cursor theme '{s}' at size {d}: could not create manager", .{ theme, size });
        return;
    };
    // wlr_cursor keeps the manager of its current xcursor image; drop that
    // image before destroying the old manager. Client surface cursors hold
    // no manager and stay.
    if (input.cursor_source == .default or input.cursor_source == .theme) input.cursor.unsetImage();
    input.cursor_mgr.destroy();
    input.cursor_mgr = mgr;
    input.rememberCursorTheme(theme, size);
    mgr.load(1) catch {};
    var it = input.server.outputs.iterator(.forward);
    while (it.next()) |out| mgr.load(out.wlr_output.scale) catch {};
    if (input.server.xwayland) |xwayland| xwayland.applyCursor();
    switch (input.cursor_source) {
        .theme => if (input.cursor_name) |name| input.showXcursor(name),
        .default => {
            input.default_cursor_applied = false;
            input.setDefaultCursor();
        },
        // A client surface cursor is not ours to replace; the next enter
        // or shape request picks up the new theme.
        .surface, .hidden => {},
    }
}

/// Load the configured theme at every output scale.
pub fn refreshOutputScales(input: *Input) void {
    var it = input.server.outputs.iterator(.forward);
    while (it.next()) |out| {
        input.cursor_mgr.load(out.wlr_output.scale) catch |err| {
            log.warn("cursor theme at scale {d}: {}", .{ out.wlr_output.scale, err });
        };
    }
}

pub fn setDefaultCursor(input: *Input) void {
    const busy = input.server.launch_feedback.busy() and input.cursor_mgr.getXcursor("progress", 1) != null;
    if (input.default_cursor_applied and input.default_cursor_busy == busy) return;
    input.default_cursor_busy = busy;
    input.default_cursor_applied = true;
    input.cursor_source = .default;
    if (busy) {
        // Launch feedback: an app is starting. wlroots animates the spinner.
        input.showXcursor("progress");
        input.cursor_name = "progress";
        return;
    }
    input.showXcursor("default");
    input.cursor_name = "default";
}

pub fn showXcursor(input: *Input, name: [*:0]const u8) void {
    if (!input.cursor_held) input.cursor.setXcursor(input.cursor_mgr, name);
}

/// Startup with native input still pending: no cursor image until
/// `releaseCursor`.
pub fn holdCursor(input: *Input) void {
    input.cursor_held = true;
    input.cursor.unsetImage();
}

/// Shows whatever image the held cursor would have had.
pub fn releaseCursor(input: *Input) void {
    if (!input.cursor_held) return;
    input.cursor_held = false;
    switch (input.cursor_source) {
        .theme => if (input.cursor_name) |name| input.showXcursor(name),
        // A client surface image was never applied; the next enter sets it.
        .default, .surface => {
            input.default_cursor_applied = false;
            input.setDefaultCursor();
        },
        .hidden => {},
    }
}

/// Launch feedback started or ended: swap the arrow for the progress cursor
/// (or back) wherever the default cursor is showing.
pub fn refreshBusyCursor(input: *Input) void {
    if (input.cursor_source == .default) input.setDefaultCursor();
}

/// Cursor over compositor-drawn UI: the text cursor over editable fields,
/// otherwise the arrow (buttons and menus keep the arrow, as on other desktops).
pub fn setShellCursor(input: *Input, over_text: bool) void {
    if (over_text) input.setNamedCursor("text") else input.setDefaultCursor();
}

pub fn setNamedCursor(input: *Input, name: [*:0]const u8) void {
    input.default_cursor_applied = false;
    input.showXcursor(name);
    input.cursor_source = .theme;
    input.cursor_name = name;
}
