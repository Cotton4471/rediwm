//! Taskbar clock: ticks, locale and the strings it shows.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const c_time = @import("../taskbar/c_time.zig").c;
const gpa = @import("../main.zig").gpa;
const text = @import("ui").text;
const ui_theme = @import("ui").theme;
const stats = @import("../ipc/stats.zig");
const nowMs = Taskbar.nowMs;
const log = std.log.scoped(.taskbar);
const paint_chips = Taskbar.paint_chips;
const paint_tray = Taskbar.paint_tray;
const paint_clock = Taskbar.paint_clock;
const paint_capture = Taskbar.paint_capture;
const clock_time_size = Taskbar.clock_time_size;
const clock_date_size = Taskbar.clock_date_size;
const clock_pieces_max = Taskbar.clock_pieces_max;
const ClockLine = Taskbar.ClockLine;

pub fn scheduleClockTick(bar: *Taskbar) void {
    var now: c_time.struct_timespec = undefined;
    if (c_time.clock_gettime(c_time.CLOCK_REALTIME, &now) != 0) {
        bar.timer.timerUpdate(1000) catch |err| {
            log.err("scheduleClockTick: clock_gettime failed: {}", .{err});
        };
        return;
    }
    // Wake just after the next displayed boundary, without accumulating drift.
    // A hidden clock only needs the shared minute wake for battery/calendar.
    const interval: c_time.time_t = if (bar.server.config.region.clock_show_seconds and bar.itemShown(.clock)) 1 else 60;
    const delay_ms: c_int = @intCast((interval - @mod(now.tv_sec, interval)) * 1000 - @divTrunc(now.tv_nsec, 1_000_000) + 25);
    bar.timer.timerUpdate(delay_ms) catch |err| {
        log.err("scheduleClockTick: could not reschedule clock timer: {}", .{err});
    };
}

pub fn updateClockLocale(bar: *Taskbar) void {
    const name = gpa.dupeSentinel(u8, bar.server.config.region.formats, 0) catch return;
    defer gpa.free(name);
    // Keep a private locale: changing the process locale would affect workers.
    const locale = c_time.newlocale(c_time.LC_TIME_MASK, name, null);
    if (bar.clock_locale) |old| c_time.freelocale(old);
    bar.clock_locale = locale;
}

pub fn refreshClockSettings(bar: *Taskbar) void {
    bar.updateClockLocale();
    bar.refreshClock(true);
    bar.scheduleClockTick();
}

/// `reset_width` forgets the widest the column has been (a new format, day
/// line or locale may fit a narrower one).
pub fn refreshClock(bar: *Taskbar, reset_width: bool) void {
    const previous_width = bar.clockColumnWidth();
    if (reset_width) bar.clock_width.valid = false;
    const changed = bar.updateClockStrings();
    const width_changed = previous_width != bar.clockColumnWidth();
    if (!changed and !width_changed) return;
    bar.clock_dirty = true;
    var causes: u8 = paint_clock;
    if (width_changed) {
        // A wider/narrower clock moves every item to its left, including the tray.
        bar.tray_dirty = @splat(true);
        bar.capture_dirty = true;
        const chips_changed = bar.reconcile(nowMs());
        causes |= paint_tray | paint_capture | (if (chips_changed) paint_chips else @as(u8, 0));
    }
    bar.markDirty(causes);
    bar.wlr_output.scheduleFrame();
    stats.recordTaskbarClockFrameRequest();
}

pub fn updateClockStrings(bar: *Taskbar) bool {
    var raw: c_time.time_t = c_time.time(null);
    var tm_storage: c_time.struct_tm = undefined;
    const tm = c_time.localtime_r(&raw, &tm_storage) orelse return false;

    var next_time: [16]u8 = undefined;
    var next_date: [128]u8 = @splat(0);
    const prefs = bar.server.config.region;
    if (c_time.strftime(&next_time, next_time.len, prefs.taskbarTimeFormat(), tm) == 0) return false;
    if (prefs.clock_show_day) {
        const len = if (bar.clock_locale) |locale|
            c_time.strftime_l(&next_date, next_date.len, "%x", tm, locale)
        else
            c_time.strftime(&next_date, next_date.len, "%x", tm);
        if (len == 0) return false;
    }

    const prev_time = std.mem.sliceTo(&bar.clock_time, 0);
    const prev_date = std.mem.sliceTo(&bar.clock_date, 0);
    const time = std.mem.sliceTo(&next_time, 0);
    const date = std.mem.sliceTo(&next_date, 0);
    if (std.mem.eql(u8, prev_time, time) and std.mem.eql(u8, prev_date, date)) return false;

    bar.clock_time = next_time;
    bar.clock_date = next_date;
    // The column is as wide as the widest text it has shown (AM against PM,
    // a longer date), never narrower, so only a real growth moves the items
    // beside it. A settings change starts it over in `refreshClockSettings`.
    const scale = bar.wlr_output.scale;
    if (bar.clock_width.get(scale)) |current| {
        const needed = bar.measureClockColumn() catch current;
        if (needed > current) _ = bar.clock_width.put(scale, needed);
    }
    return true;
}

pub fn clockFont() text.Font {
    return if (ui_theme.taskbar(.clock_bold)) .manrope_heavy else .manrope;
}

pub fn clockStyleChanged(bar: *Taskbar) void {
    const style = @as(u8, @intFromBool(ui_theme.taskbar(.clock_bold))) | (@as(u8, @intFromBool(ui_theme.taskbar(.clock_italic))) << 1);
    if (style == bar.clock_style) return;
    bar.clock_style = style;
    bar.clock_digit.valid = false;
    bar.clock_width.valid = false;
}

/// The widest digit's advance. Every digit of the time sits in a cell this
/// wide, so the seconds ticking over change neither the line's width nor where
/// its other glyphs are (Manrope's digits are proportional).
pub fn clockDigitCell(bar: *Taskbar) !i32 {
    const scale = bar.wlr_output.scale;
    if (bar.clock_digit.get(scale)) |cell| return @intFromFloat(cell);
    var widest: i32 = 0;
    for ("0123456789") |*digit| widest = @max(widest, try text.measureWidth(digit[0..1], clockFont(), clock_time_size, scale));
    return @intFromFloat(bar.clock_digit.put(scale, @floatFromInt(widest)));
}

pub fn clockLine(bar: *Taskbar, time: []const u8) !ClockLine {
    const scale = bar.wlr_output.scale;
    const cell = try bar.clockDigitCell();
    var line: ClockLine = .{};
    var i: usize = 0;
    while (i < time.len and line.count < clock_pieces_max) {
        const digit = std.ascii.isDigit(time[i]);
        var end = i + 1;
        if (!digit) {
            while (end < time.len and !std.ascii.isDigit(time[end])) end += 1;
        }
        const piece = time[i..end];
        const w = try text.measureWidth(piece, clockFont(), clock_time_size, scale);
        line.pieces[line.count] = .{ .text = piece, .x = line.width + if (digit) @divTrunc(cell - w, 2) else 0, .w = w };
        line.count += 1;
        line.width += if (digit) cell else w;
        i = end;
    }
    return line;
}

/// Logical width the clock column needs for the current strings.
pub fn measureClockColumn(bar: *Taskbar) !f32 {
    const scale = bar.wlr_output.scale;
    const raw = std.mem.sliceTo(&bar.clock_time, 0);
    const time = std.mem.trimStart(u8, raw, " ");
    var time_w = (try bar.clockLine(time)).width;
    // "%l" pads the hours 1-9 with a blank: keep the room of the second digit
    // so that 9:59 turning 10:00 does not resize the column.
    if (time.len < raw.len) time_w += try bar.clockDigitCell();
    const date_w = try text.measureWidth(std.mem.sliceTo(&bar.clock_date, 0), clockFont(), clock_date_size, scale);
    // Fit the displayed lines so unused column space cannot widen the left gap.
    const overhang: i32 = if (ui_theme.taskbar(.clock_italic)) @intFromFloat(@ceil(clock_time_size * 0.22) + 1) else 0;
    return @floatFromInt(@max(time_w, date_w) + 1 + 2 * overhang);
}

pub fn clockColumnWidth(bar: *Taskbar) f32 {
    bar.clockStyleChanged();
    const scale = bar.wlr_output.scale;
    if (bar.clock_width.get(scale)) |width| return width;
    // A failed measurement is retried next time rather than remembered.
    const width = bar.measureClockColumn() catch return bar.clock_width.width;
    return bar.clock_width.put(scale, width);
}
