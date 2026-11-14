const std = @import("std");
const ui = @import("ui");
const cairo = ui.cairo;
const theme = ui.theme;
const W = ui.layout.Widget;
const c = @import("../files/c.zig").api;
const Model = @import("model.zig").Model;

/// Give the entry twice the usual large-button label size.
fn entrySize() f32 {
    return ui.widgets.button.metrics(.lg, theme.global).font_size * 2;
}

fn keypadTheme() theme.Theme {
    var palette = theme.shellPalette();
    palette.button_font_size *= 1.5;
    return palette;
}

const labels = [_][]const u8{
    "AC", "(", ")",
    "⌫", // Clear and editing.
    "±",
    "%",
    "÷",
    "×", // Unary and multiplicative operators.
    "7",
    "8",
    "9",
    "−",
    "4",
    "5",
    "6",
    "+",
    "1",
    "2",
    "3",
    "=",
    "0", ".", // Zero spans two columns; equals spans two rows.
};

pub const App = struct {
    model: Model = .{},
    w: i32 = 360,
    h: i32 = 500,
    scale: i32 = 1,
    density: f64 = 1,
    dirty: bool = true,
    closed: bool = false,
    suspended: bool = false,
    focused: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    px: f32 = -1,
    py: f32 = -1,
    root: W = .{ .kind = .container },
    buttons: [22]W = undefined,
    initialized: bool = false,
    dispatcher: ui.input.Dispatcher = .{},

    pub fn deinit(self: *App) void {
        self.dispatcher.reset();
    }
    pub fn getTitle(_: *App) [*:0]const u8 {
        return @import("i18n").trZ("Calculator");
    }
    pub fn requestClose(self: *App) void {
        self.closed = true;
    }
    pub fn setSuspended(self: *App, suspended: bool) void {
        self.suspended = suspended;
        if (suspended) self.cancelDrag();
        self.dirty = true;
    }
    fn ensureWidgets(self: *App) void {
        if (self.initialized) return;
        self.initialized = true;
        for (&self.buttons, labels, 0..) |*button, label, id| {
            button.* = .{ .kind = .{ .button = .{
                .label = label,
                .icon = if (id == 6) .divide else null,
                .size = .lg,
                .variant = if (id == 19) .primary else .secondary,
                .owner = self,
                .id = id,
                .on_click = clicked,
            } } };
        }
        self.root.children = &self.buttons;
        self.root.linkParents();
        self.layout();
    }
    fn layout(self: *App) void {
        if (!self.initialized) return;
        const width: f32 = @floatFromInt(self.w);
        const height: f32 = @floatFromInt(self.h);
        const gap: f32 = 8;
        const cell_w = (width - 32 - gap * 3) / 4;
        const top: f32 = @max(112, entrySize() + cairo.statusSize() + 56);
        const cell_h = @max(24, (height - top - 16 - gap * 5) / 6);
        const icon_size = ui.widgets.button.metrics(.lg, keypadTheme()).font_size;
        self.root.computed_width = width;
        self.root.computed_height = height;
        for (&self.buttons, 0..) |*button, id| {
            const row = id / 4;
            const col = id % 4;
            var x = 16 + @as(f32, @floatFromInt(col)) * (cell_w + gap);
            var y = top + @as(f32, @floatFromInt(row)) * (cell_h + gap);
            var w = cell_w;
            var h = cell_h;
            // The final row gives zero a double width; equals spans two rows.
            if (id == 19) h = cell_h * 2 + gap;
            if (id == 20) {
                x = 16;
                y = top + 5 * (cell_h + gap);
                w = cell_w * 2 + gap;
            }
            if (id == 21) {
                x = 16 + 2 * (cell_w + gap);
                y = top + 5 * (cell_h + gap);
            }
            ui.arrange.arrange(button, x, y, w, h);
            // Keep the operator icon at the label size when the keypad resizes.
            if (button.kind.button.icon != null) button.kind.button.icon_scale = icon_size / @min(w, h);
        }
    }
    pub fn resize(self: *App, width: i32, height: i32) void {
        self.w = @max(280, width);
        self.h = @max(420, height);
        self.layout();
        self.dirty = true;
    }
    fn clicked(owner: ?*anyopaque, id: usize) void {
        const self: *App = @ptrCast(@alignCast(owner.?));
        switch (id) {
            0 => self.model.clear(),
            3 => self.model.backspace(),
            4 => self.model.negate(),
            19 => self.model.equals(),
            else => self.model.input(switch (id) {
                1 => '(',
                2 => ')',
                5 => '%',
                6 => '/',
                7 => '*',
                11 => '-',
                15 => '+',
                20 => '0',
                21 => '.',
                else => labels[id][0],
            }),
        }
        self.dirty = true;
    }
    pub fn cancelDrag(self: *App) void {
        self.px = -1;
        self.py = -1;
        if (self.dispatcher.pressed) |button| ui.widgets.button.setState(button, .idle);
        self.dispatcher.pressed = null;
        if (self.initialized) self.dispatcher.pointerLeave(&self.root);
        self.dirty = true;
    }
    pub fn cursorName(self: *App) [*:0]const u8 {
        return if (self.dispatcher.hovered != null) "pointer" else "default";
    }
    pub fn handleMotion(self: *App, x: f64, y: f64) void {
        self.ensureWidgets();
        self.px = @floatCast(x);
        self.py = @floatCast(y);
        self.dispatcher.pointerMotion(&self.root, self.px, self.py);
        self.dirty = true;
    }
    pub fn handleButton(self: *App, code: u32, pressed: bool) void {
        self.ensureWidgets();
        if (code != 0x110) return;
        if (pressed) self.dispatcher.pointerButtonDown(&self.root, self.px, self.py) else self.dispatcher.pointerButtonUp(&self.root, self.px, self.py);
        self.dirty = true;
    }
    pub fn handleKey(self: *App, sym: u32, text: []const u8) void {
        self.ensureWidgets();
        self.dirty = true;
        if (self.ctrl and (sym == c.XKB_KEY_q or sym == c.XKB_KEY_w)) return self.requestClose();
        if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
            _ = self.dispatcher.focusNext(&self.root, self.shift or sym == c.XKB_KEY_ISO_Left_Tab);
            return;
        }
        if (self.ctrl or self.alt) return;
        switch (sym) {
            c.XKB_KEY_Escape, c.XKB_KEY_Delete, c.XKB_KEY_KP_Delete => self.model.clear(),
            c.XKB_KEY_BackSpace => self.model.backspace(),
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => self.model.equals(),
            c.XKB_KEY_space => {
                if (self.dispatcher.focused) |widget| ui.widgets.button.press(widget);
            },
            c.XKB_KEY_F9 => self.model.negate(),
            c.XKB_KEY_KP_Decimal, c.XKB_KEY_KP_Separator => self.model.input('.'),
            else => for (text) |char| {
                if (char == '=') self.model.equals() else if (char == ',') self.model.input('.') else self.model.input(char);
            },
        }
    }
    pub fn keyRepeats(self: *App, sym: u32, text: []const u8) bool {
        return !self.ctrl and !self.alt and (sym == c.XKB_KEY_BackSpace or (text.len == 1 and std.ascii.isDigit(text[0])));
    }
    fn textRight(self: *App, cr: *c.cairo_t, text: []const u8, y: f64, size: f64, bold: bool) void {
        const width: f64 = @floatFromInt(self.w - 32);
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        c.cairo_rectangle(cr, 16, y - size * 1.5, width, size * 2);
        c.cairo_clip(cr);
        cairo.setSource(cr, theme.global.window_fg);
        cairo.drawText(cr, text, @as(f64, @floatFromInt(self.w - 16)) - cairo.measureText(cr, text, size, bold), y, size, bold);
    }
    pub fn render(self: *App, cr: *c.cairo_t) void {
        self.ensureWidgets();
        self.layout();
        cairo.setSource(cr, theme.global.app_bg);
        c.cairo_paint(cr);
        const status = cairo.statusSize();
        const heading = entrySize();
        const history = if (self.model.notice.len > 0) self.model.notice else self.model.history[0..self.model.history_len];
        if (history.len > 0) self.textRight(cr, history, 16 + status, status, false);
        const expression = self.model.display();
        self.textRight(cr, if (expression.len == 0) "0" else expression, 28 + status + heading, heading, true);
        ui.input.active_dispatcher = &self.dispatcher;
        defer ui.input.active_dispatcher = null;
        if (cairo.Layer.begin(cr, .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) })) |value| {
            var layer = value;
            layer.renderer.palette = keypadTheme();
            ui.paint.paint(&self.root, &layer.renderer);
            layer.finish();
        }
    }
};
