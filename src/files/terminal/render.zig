//! Cairo terminal rendering through the shared text rasterizer/font fallback.
const std = @import("std");
const ui = @import("ui");
const theme = ui.theme;
const shell = ui.cairo;
const c = @import("../c.zig").api;
const tc = @import("model.zig").c;
const App = @import("../app.zig").App;
const draw = @import("../app_draw.zig");
const button = ui.widgets.button;

pub fn applyPalette(session: *tc.FT) void {
    const t = theme.global;
    setColor(session, -1, t.terminal_fg orelse t.window_fg);
    setColor(session, -2, t.terminal_bg orelse t.app_bg);
    const names = .{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "bright_black", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan", "bright_white" };
    const defaults = [_][3]u8{
        .{ 24, 24, 24 },    .{ 205, 49, 49 },   .{ 13, 188, 121 }, .{ 229, 190, 11 },
        .{ 36, 114, 200 },  .{ 188, 63, 188 },  .{ 17, 168, 205 }, .{ 229, 229, 229 },
        .{ 102, 102, 102 }, .{ 241, 76, 76 },   .{ 35, 209, 139 }, .{ 245, 245, 67 },
        .{ 59, 142, 234 },  .{ 214, 112, 214 }, .{ 41, 184, 219 }, .{ 255, 255, 255 },
    };
    inline for (names, 0..) |name, i| {
        if (@field(t, "terminal_" ++ name)) |color| setColor(session, i, color) else {
            const color = defaults[i];
            tc.ft_palette(session, i, color[0], color[1], color[2]);
        }
    }
}
fn setColor(session: *tc.FT, index: c_int, color: [4]f32) void {
    tc.ft_palette(session, index, @intFromFloat(std.math.clamp(color[0], 0, 1) * 255), @intFromFloat(std.math.clamp(color[1], 0, 1) * 255), @intFromFloat(std.math.clamp(color[2], 0, 1) * 255));
}
fn rgb(color: [3]u8) [4]f32 {
    return .{ @as(f32, @floatFromInt(color[0])) / 255, @as(f32, @floatFromInt(color[1])) / 255, @as(f32, @floatFromInt(color[2])) / 255, 1 };
}
fn control(self: *App, cr: *c.cairo_t, index: usize, icon: ?ui.layout.IconId, label: []const u8) void {
    const rect = self.terminalControl(index);
    var layer = shell.Layer.begin(cr, .{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .w = @floatCast(rect.w), .h = @floatCast(rect.h) }) orelse return;
    button.paint(&layer.renderer, layer.local(), .{ .variant = .ghost, .icon = icon, .label = label, .icon_scale = 0.65 }, .{ .pointer = if (self.dialog == null and self.menu == null and rect.contains(self.mouse_x, self.mouse_y)) .hover else .idle, .selected = index == 0 and self.terminal.visible });
    layer.finish();
}
pub fn render(self: *App, cr: *c.cairo_t) void {
    if (self.chooser != null) return;
    control(self, cr, 0, .terminal, "Terminal · F4");
    const rect = self.terminalRect();
    if (rect.h > 0) {
        c.cairo_save(cr);
        c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
        c.cairo_clip(cr);
        shell.setSource(cr, theme.global.terminal_bg orelse theme.global.app_bg);
        c.cairo_paint(cr);
        shell.setSource(cr, theme.global.app_bar);
        c.cairo_rectangle(cr, rect.x, rect.y, rect.w, 32);
        c.cairo_fill(cr);
        var status_buf: [4608]u8 = undefined;
        const message = terminalLabel(self, &status_buf);
        if (shell.Layer.begin(cr, .{ .x = @floatCast(rect.x + 12), .y = @floatCast(rect.y + 8), .w = 16, .h = 16 })) |value| {
            var layer = value;
            layer.renderer.drawIcon(0, 0, 16, 16, .{ .id = .terminal, .color = theme.global.window_fg });
            layer.finish();
        }
        shell.setSource(cr, theme.global.window_fg);
        draw.drawEllipsis(cr, message, rect.x + 38, rect.y + 22, @max(0, rect.w - if (self.terminalRestartable()) @as(f64, 200) else 110), shell.statusSize(), false);
        control(self, cr, 1, .chevron_down, "Hide terminal");
        control(self, cr, 2, .open, "Open external terminal");
        if (self.terminalRestartable()) control(self, cr, 3, null, "Restart");
        if (self.terminal.session) |session| paintCells(self, cr, session);
        c.cairo_restore(cr);
        if (self.terminalDivider()) |divider| shell.drawSplitter(cr, divider, self.terminal.resize != null or self.overTerminalDivider(self.mouse_x, self.mouse_y));
    }
    if (self.dialog == null and self.menu == null) if (self.terminalHit(self.mouse_x, self.mouse_y)) |index| {
        const label: []const u8 = switch (index) {
            0 => "Terminal · F4",
            1 => "Hide terminal · F4",
            2 => "Open external terminal",
            else => "Restart terminal",
        };
        const w = shell.measureText(cr, label, shell.statusSize(), false) + 16;
        const control_rect = self.terminalControl(index);
        const x = @max(4, @min(control_rect.x, @as(f64, @floatFromInt(self.w)) - w - 4));
        const y = @max(4, control_rect.y - 28);
        draw.roundedRect(cr, x, y, w, 24, 4);
        shell.setSource(cr, theme.global.app_divider);
        c.cairo_fill(cr);
        shell.setSource(cr, theme.global.window_fg);
        shell.drawText(cr, label, x + 8, y + 17, shell.statusSize(), false);
    };
}
fn terminalLabel(self: *App, buffer: []u8) []const u8 {
    if (self.terminal.error_message) |message| return message;
    const s = self.terminal.session orelse return "Terminal";
    if (tc.ft_error(s)) |message| return std.mem.span(message);
    if (tc.ft_exited(s)) return std.fmt.bufPrint(buffer, "Terminal · Exited ({d})", .{tc.ft_exit_status(s)}) catch "Terminal exited";
    const status = tc.ft_status(s).*;
    const known = std.mem.sliceTo(&status.path, 0);
    const path = if (known.len > 0) known else self.terminal.directory orelse self.home_dir;
    // Paths may contain literal newlines/control bytes, but the header is one line.
    var clean: [4096]u8 = undefined;
    const len = @min(path.len, clean.len);
    for (path[0..len], clean[0..len]) |ch, *out| out.* = if (ch < 32 or ch == 127) ' ' else ch;
    const label = if (std.unicode.utf8ValidateSlice(clean[0..len])) clean[0..len] else "Directory";
    const suffix: []const u8 = if (tc.ft_channel(s) < 0) " · Following unavailable" else if (status.magic == 0) " · Starting…" else if (status.flags & tc.FT_ERROR != 0) " · Folder unavailable" else if (tc.ft_pending(s)) " · Following pending" else "";
    return std.fmt.bufPrint(buffer, "Terminal · {s}{s}", .{ label, suffix }) catch "Terminal";
}
fn cellBytes(cell: tc.FT_Cell, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (cell.chars) |ch| {
        if (ch == 0 or ch > 0x10ffff) break;
        var bytes: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(ch), &bytes) catch continue;
        if (len + n > buffer.len) break;
        @memcpy(buffer[len..][0..n], bytes[0..n]);
        len += n;
    }
    if (len == 0 and buffer.len > 0) {
        buffer[0] = ' ';
        len = 1;
    }
    return buffer[0..len];
}
fn paintCells(self: *App, cr: *c.cairo_t, session: *tc.FT) void {
    const body = self.terminalBody();
    if (body.h <= 0 or body.w <= 0) return;
    c.cairo_save(cr);
    c.cairo_rectangle(cr, body.x, body.y, body.w, body.h);
    c.cairo_clip(cr);
    const drawer = &self.terminal;
    const cw = drawer.cell_w;
    const ch = drawer.cell_h;
    const rows = @min(tc.ft_rows(session), @as(i32, @intFromFloat(@ceil(body.h / ch))));
    var row: i32 = 0;
    while (row < rows) : (row += 1) {
        var col: i32 = 0;
        while (col < tc.ft_cols(session)) {
            var cell: tc.FT_Cell = undefined;
            if (!tc.ft_cell(session, row, col, &cell)) break;
            if (cell.width == 0) {
                col += 1;
                continue;
            }
            const selected = if (drawer.selection) |selection| selection.contains(tc.ft_line(session) - tc.ft_offset(session) + row, col) else false;
            const reverse = cell.attrs & tc.FT_REVERSE != 0;
            const fg = if (reverse) cell.bg else cell.fg;
            const bg = if (reverse) cell.fg else cell.bg;
            const first_col = col;
            var bytes: [16384]u8 = undefined;
            var len: usize = 0;
            const ascii_run = cell.width == 1 and cell.chars[0] >= 32 and cell.chars[0] < 127 and cell.chars[1] == 0;
            while (col < tc.ft_cols(session)) {
                var next: tc.FT_Cell = undefined;
                if (!tc.ft_cell(session, row, col, &next)) break;
                if (next.width == 0) {
                    col += 1;
                    continue;
                }
                const next_selected = if (drawer.selection) |selection| selection.contains(tc.ft_line(session) - tc.ft_offset(session) + row, col) else false;
                if (next.attrs != cell.attrs or !std.mem.eql(u8, &next.fg, &cell.fg) or !std.mem.eql(u8, &next.bg, &cell.bg) or selected != next_selected) break;
                if (col != first_col and (!ascii_run or next.width != 1 or next.chars[0] < 32 or next.chars[0] >= 127 or next.chars[1] != 0)) break;
                const chunk = cellBytes(next, bytes[len..]);
                len += chunk.len;
                col += @max(1, next.width);
                if (!ascii_run) break;
            }
            const x = body.x + @as(f64, @floatFromInt(first_col)) * cw;
            const y = body.y + @as(f64, @floatFromInt(row)) * ch;
            const width = @as(f64, @floatFromInt(col - first_col)) * cw;
            shell.setSource(cr, rgb(bg));
            c.cairo_rectangle(cr, x, y, width, ch);
            c.cairo_fill(cr);
            if (selected) {
                shell.setSource(cr, theme.shellPalette().selectionColor());
                c.cairo_rectangle(cr, x, y, width, ch);
                c.cairo_fill(cr);
            }
            if (cell.attrs & tc.FT_CONCEAL == 0) {
                shell.setSource(cr, rgb(fg));
                c.cairo_save(cr);
                c.cairo_rectangle(cr, x, y, width, ch);
                c.cairo_clip(cr);
                shell.drawStyledText(cr, bytes[0..len], x, y + drawer.ascent, shell.textSize(), if (cell.attrs & tc.FT_BOLD != 0) .mono_bold else .mono, cell.attrs & tc.FT_ITALIC != 0);
                c.cairo_restore(cr);
                if (cell.attrs & tc.FT_UNDERLINE != 0) {
                    c.cairo_rectangle(cr, x, y + drawer.ascent + 1, width, 1);
                    c.cairo_fill(cr);
                }
                if (cell.attrs & tc.FT_STRIKE != 0) {
                    c.cairo_rectangle(cr, x, y + drawer.ascent * 0.6, width, 1);
                    c.cairo_fill(cr);
                }
            }
        }
    }
    var cursor_row: c_int = 0;
    var cursor_col: c_int = 0;
    var shape: c_int = 0;
    if (tc.ft_cursor(session, &cursor_row, &cursor_col, &shape) and drawer.focused) {
        const x = body.x + @as(f64, @floatFromInt(cursor_col)) * cw;
        const y = body.y + @as(f64, @floatFromInt(cursor_row)) * ch;
        const cursor_color = theme.global.terminal_cursor orelse theme.shellPalette().caretColor();
        shell.setSource(cr, cursor_color);
        c.cairo_rectangle(cr, x, y + if (shape == 2) ch - 2 else 0, if (shape == 3) 2 else cw, if (shape == 2) 2 else ch);
        c.cairo_fill(cr);
        if (shape == 1) {
            var cell: tc.FT_Cell = undefined;
            if (tc.ft_cell(session, cursor_row, cursor_col, &cell)) {
                var text: [24]u8 = undefined;
                shell.setSource(cr, theme.global.terminal_bg orelse theme.global.app_bg);
                shell.drawTextFont(cr, cellBytes(cell, &text), x, y + drawer.ascent, shell.textSize(), .mono);
            }
        }
        if (drawer.preedit.items.len > 0) {
            shell.setSource(cr, theme.global.terminal_fg orelse theme.global.window_fg);
            shell.drawTextFont(cr, drawer.preedit.items, x, y + drawer.ascent, shell.textSize(), .mono);
        }
    }
    c.cairo_restore(cr);
    if (self.terminalScrollbar()) |bar| shell.drawScrollbar(cr, ui.widgets.scrollbar.look(bar, drawer.bar, self.scrollbar_width, theme.shellPalette()));
}
