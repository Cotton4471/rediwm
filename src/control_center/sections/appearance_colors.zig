//! Appearance app colours: applying the accent to GTK and Qt apps and reporting the result.

const std = @import("std");
const layout = @import("ui").layout;
const theme = @import("ui").theme;
const Widget = layout.Widget;
const wl = @import("wayland").server.wl;
const app_theme = @import("config").app_theme;
const AppColorsJob = @import("../../config_runtime/app_theme.zig").Job;
const section = @import("appearance_dock.zig").section;
const Section = @import("appearance.zig").Section;

pub fn appColorsNote(s: *Section, a: std.mem.Allocator, color: [4]f32) Widget {
    const text = @import("ui").text;
    const width: f32 = @floatFromInt(@max(120, s.cc.panel_box.width - @as(i32, if (s.cc.panel_box.width < 660) 70 else 238) - 100));
    var lines: std.ArrayList(Widget) = .empty;
    var start: usize = 0;
    var words = std.mem.tokenizeScalar(u8, s.app_colors_message, ' ');
    var end: usize = 0;
    while (words.next()) |word| {
        const next = @intFromPtr(word.ptr) - @intFromPtr(s.app_colors_message.ptr) + word.len;
        const measured = text.measureWidthF(s.app_colors_message[start..next], .manrope, theme.global.settings_description_size, 1) catch 0;
        if (end > start and measured > width) {
            lines.append(a, .{ .name = std.fmt.allocPrint(a, "app_colors_status_{d}", .{lines.items.len}) catch "app_colors_status_line", .kind = .{ .text = .{ .content = s.app_colors_message[start..end], .font_size = theme.global.settings_description_size, .color = color } } }) catch break;
            start = next - word.len;
        }
        end = next;
    }
    if (end > start) lines.append(a, .{ .name = std.fmt.allocPrint(a, "app_colors_status_{d}", .{lines.items.len}) catch "app_colors_status_line", .kind = .{ .text = .{ .content = s.app_colors_message[start..end], .font_size = theme.global.settings_description_size, .color = color } } }) catch {};
    return .{ .name = "app_colors_status", .kind = .container, .direction = .column, .gap = 2, .children = lines.toOwnedSlice(a) catch &.{} };
}

pub fn onApplyAppColors(owner: ?*anyopaque, id: usize) void {
    const s = section(owner);
    if (s.app_colors_job != null or s.cc.server.greeter_mode) return;
    const job = AppColorsJob.create(s.cc.server.io, s.cc.server.environ, if (id == 0) .gtk else .qt, app_theme.Palette.fromTheme(theme.global)) catch |err| {
        appColorsFailure(s, err);
        return;
    };
    const source = s.cc.server.wl_server.getEventLoop().addFd(*Section, job.fd, .{ .readable = true }, appColorsReady, s) catch |err| {
        job.deinit();
        appColorsFailure(s, err);
        return;
    };
    job.start() catch |err| {
        source.remove();
        job.deinit();
        appColorsFailure(s, err);
        return;
    };
    s.app_colors_job = job;
    s.app_colors_source = source;
    s.app_colors_message = "Applying app colors…";
    s.cc.refresh();
}

pub fn appColorsFailure(s: *Section, err: anyerror) void {
    s.app_colors_message = switch (err) {
        error.QtToolsMissing => "Install qt5ct for Qt 5 apps or qt6ct for Qt 6 apps, then apply again.",
        error.ManagedSymlink => "A toolkit config folder is a symlink. Apply the colors in its real location, or make it a regular folder.",
        error.InvalidManagedCss => "The RediWM block in gtk.css is incomplete. Repair it before applying colors.",
        else => std.fmt.bufPrint(&s.app_colors_message_buf, "Could not apply app colors: {s}. Check your configuration files and permissions.", .{@errorName(err)}) catch "Could not apply app colors. Check your configuration files and permissions.",
    };
    std.log.warn("app colors export failed: {}", .{err});
    s.cc.refresh();
}

pub fn finishAppColors(s: *Section, refresh: bool) void {
    if (s.app_colors_source) |source| source.remove();
    s.app_colors_source = null;
    const job = s.app_colors_job orelse return;
    s.app_colors_job = null;
    job.join();
    defer job.deinit();
    const support = job.result catch |err| {
        if (refresh) appColorsFailure(s, err);
        return;
    };
    if (job.toolkit == .qt) s.cc.server.qt_app_colors = true;
    if (!refresh) return;
    s.app_colors_message = switch (job.toolkit) {
        .gtk => "GTK colors applied. Restart GTK apps. Apps with their own styles or sandbox settings may differ.",
        .qt => if (support.qt5 and support.qt6)
            "Qt 5 and Qt 6 colors applied. Restart apps; sign in again if their colors do not change."
        else if (support.qt6)
            "Qt 6 colors applied. Install qt5ct for Qt 5 apps. Restart apps; sign in again if their colors do not change."
        else
            "Qt 5 colors applied. Install qt6ct for Qt 6 apps. Restart apps; sign in again if their colors do not change.",
    };
    s.cc.refresh();
}

pub fn appColorsReady(_: c_int, _: wl.EventMask, s: *Section) c_int {
    finishAppColors(s, true);
    return 0;
}
