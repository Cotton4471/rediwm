// How a window frame looks, and the CPU rasterizer that draws it.
const std = @import("std");
const sdf = @import("ui").sdf;

const wlr = @import("wlroots");
const col = @import("color.zig");

const gpa = @import("main.zig").gpa;
const geometry = @import("geometry.zig");
const icon_service = @import("icon_service.zig");
const theme = @import("ui").theme;
const text = @import("ui").text;

const log = std.log.scoped(.chrome);

// App dialogs use these same decoration metrics and control hit targets.
const window_chrome = @import("ui").window_chrome;
pub const frame_border = window_chrome.frame_border;
pub const Metrics = window_chrome.Metrics;
pub const frameRadius = window_chrome.frameRadius;

/// At or above this effective titlebar alpha the blur behind it contributes
/// at most 2%, too little to repaint on every frame of an interactive move.
const glass_hold_min_alpha: f32 = 0.98;
pub fn titlebarGlassMayHold(opacity: f32) bool {
    return theme.global.window_bg[3] * opacity >= glass_hold_min_alpha;
}
const btn_radius = window_chrome.control_radius;
// Min/max/close glyphs are drawn 10% larger than the app icon scale.
const button_glyph_scale = window_chrome.button_glyph_scale;

// The app icon sits where the title text used to start; the title shifts
// right to make room for it when one is found.
const title_inset = window_chrome.title_inset;
pub const title_icon_size = window_chrome.title_icon_size;
const title_icon_gap = window_chrome.title_icon_gap;

/// Set once at startup, before any window exists, when the output pass built its
/// shaped programs (docs/plans/scene-graph-stage4.md). Then every decorated window
/// has a shape that clips the titlebar, the client and its subsurfaces together,
/// and the pass draws its corners, border ring and shadow. Without them (a driver
/// that cannot link the programs) windows are square, with no ring or shadow.
pub var shapes: bool = false;

pub const ControlKind = window_chrome.ControlKind;

const drm_format_argb8888: u32 = 0x34325241;

// Everything the rasterizer needs to reproduce a window's current appearance.
pub const ChromeState = struct {
    tabs: @import("chrome_tabs.zig").Strip = .{},
    active: bool = false,
    workspace_focus: bool = false,
    maximized: bool = false,
    density: f32 = 1,
    title: []const u8 = "",
    // Device pixels per logical pixel. Every metric here is logical; only the
    // sampling grid and the antialiasing ramp change with it.
    scale: f32 = 1,
    // 0 idle, 1 fully hovered; in-between is the border fade.
    hover: f32 = 0,
    // Window-button hover chip. `chip_pos` is a slot coordinate (0 minimize,
    // 1 maximize, 2 close, fractions in between) so it can glide between
    // buttons; `chip_alpha` fades it in and out independently.
    chip_pos: f32 = 0,
    chip_alpha: f32 = 0,
    // A real app icon found via icon_service.zig (see Toplevel.syncChrome),
    // drawn at the titlebar's top-left in place of nothing at all. Absent
    // clients just get the title text starting further left, same as today.
    icon: ?icon_service.Entry = null,

    fn titleFont(self: ChromeState) text.Font {
        return if (self.active) .manrope_bold else .manrope;
    }
};

// Inputs that produced the titlebar currently on screen. `rasterize` also reads
// `theme.global`; those are snapshotted here so a live reskin cannot be skipped.
pub const TitlebarMemo = struct {
    font_generation: u32 = 0,
    tabs_hash: u64 = 0,
    width: i32,
    height: i32,
    density: f32 = 1,
    active: bool = false,
    workspace_focus: bool = false,
    workspace_active_border: [4]f32 = @splat(0),
    // wlroots strdup's the title on set_title, so pointer equality implies
    // content equality without owning a copy of the string.
    title_ptr: ?[*:0]const u8,
    scale: f32,
    hover: f32,
    chip_pos: f32,
    chip_alpha: f32,
    maximized: bool,
    icon: ?icon_service.Entry,
    glass: [4]f32,
    border: [4]f32,
    border_soft: [4]f32,
    fg: [4]f32,
    dim: [4]f32,
    border_hover: [4]f32,
    surface_hover: [4]f32,
    danger: [4]f32,
    close_fg: [4]f32 = .{ 1, 1, 1, 1 },
    close_hover_alpha: f32 = 0.85,
    title_size: f32,
    chrome_height: f32 = 46,
    chrome_control_gap: f32 = 4,
    chrome_round_buttons: bool = false,

    pub fn capture(width: i32, height: i32, title_ptr: ?[*:0]const u8, state: ChromeState) TitlebarMemo {
        const t = theme.global;
        return .{
            .font_generation = text.font_generation,
            .width = width,
            .height = height,
            .density = state.density,
            .active = state.active,
            .workspace_focus = state.workspace_focus,
            .workspace_active_border = t.workspace_active_border,
            .title_ptr = title_ptr,
            .tabs_hash = @import("chrome_tabs.zig").hash(state.tabs),
            .scale = state.scale,
            .hover = state.hover,
            .chip_pos = state.chip_pos,
            .chip_alpha = state.chip_alpha,
            .maximized = state.maximized,
            .icon = state.icon,
            .glass = t.window_bg,
            .border = t.window_border,
            .border_soft = t.window_divider,
            .fg = t.window_fg,
            .dim = t.window_dim,
            .border_hover = t.window_border_hover,
            .surface_hover = t.surface_hover,
            .danger = t.window_close_hover,
            .close_fg = t.window_close_fg,
            .close_hover_alpha = t.window_close_hover_alpha,
            .title_size = t.title_size,
            .chrome_height = t.chrome_height,
            .chrome_control_gap = t.chrome_control_gap,
            .chrome_round_buttons = t.chrome_round_buttons,
        };
    }

    pub fn stableEql(a: TitlebarMemo, b: TitlebarMemo) bool {
        var normalized = a;
        normalized.hover = b.hover;
        normalized.chip_pos = b.chip_pos;
        normalized.chip_alpha = b.chip_alpha;
        return normalized.eql(b);
    }

    /// Whether `ChromeBuffer.createUpdated` can derive `b` from the buffer
    /// painted for `a`: only hover, focus, the hovered control, title or weight differ.
    pub fn reusableFor(a: TitlebarMemo, b: TitlebarMemo) bool {
        var normalized = a;
        normalized.title_ptr = b.title_ptr;
        normalized.tabs_hash = b.tabs_hash;
        normalized.active = b.active;
        normalized.workspace_focus = b.workspace_focus;
        return normalized.stableEql(b);
    }

    pub fn eql(a: TitlebarMemo, b: TitlebarMemo) bool {
        if (a.font_generation != b.font_generation) return false;
        if (a.width != b.width) return false;
        if (a.height != b.height) return false;
        if (a.density != b.density) return false;
        if (a.active != b.active) return false;
        if (a.workspace_focus != b.workspace_focus) return false;
        if (a.title_ptr != b.title_ptr or a.tabs_hash != b.tabs_hash) return false;
        if (a.scale != b.scale) return false;
        if (a.hover != b.hover) return false;
        if (a.chip_pos != b.chip_pos or a.chip_alpha != b.chip_alpha) return false;
        if (a.maximized != b.maximized) return false;
        if (!iconEql(a.icon, b.icon)) return false;
        inline for (.{ "glass", "border", "border_soft", "fg", "dim", "border_hover", "surface_hover", "danger", "close_fg", "workspace_active_border" }) |field| {
            if (!rgbaEql(@field(a, field), @field(b, field))) return false;
        }
        return a.close_hover_alpha == b.close_hover_alpha and a.title_size == b.title_size and a.chrome_height == b.chrome_height and a.chrome_control_gap == b.chrome_control_gap and a.chrome_round_buttons == b.chrome_round_buttons;
    }
};

fn rgbaEql(a: [4]f32, b: [4]f32) bool {
    return std.mem.eql(f32, &a, &b);
}

fn iconEql(a: ?icon_service.Entry, b: ?icon_service.Entry) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    // Compare the service's stable handle id, not `pixels.ptr`: once
    // eviction lands, a freed buffer's address could be reused for a
    // different icon, which a raw pointer comparison would miss.
    return left.id == right.id;
}

pub const Rect = window_chrome.Rect;

/// Where a control sits on the hover chip's glide axis.
pub fn controlSlot(kind: ControlKind) f32 {
    return switch (kind) {
        .minimize => 0,
        .maximize => 1,
        .close => 2,
    };
}

inline fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub const controlRect = window_chrome.controlRect;
pub const controlRectScaled = window_chrome.controlRectScaled;

// The titlebar: a plain band. The window's shape gives it its corners and the
// output pass draws the border ring over it, so no pixel here is shaped.
pub const ChromeBuffer = struct {
    // wlroots imports this data-pointer buffer as a texture for the scene.
    base: wlr.Buffer,
    // The buffer is device pixels; the frame it draws is logical ones.
    width: i32,
    height: i32,
    logical_width: i32,
    state: ChromeState,
    pixels: []u32,
    // Logical width from the title rect's left edge that the drawn title can
    // cover, so a title change repaints only the old and new text.
    title_extent: i32 = 0,
    tabs_layout_hash: u64 = 0,
    tabs_titles: [128]u64 = @splat(0),

    fn rememberTabs(frame: *ChromeBuffer) void {
        frame.tabs_layout_hash = @import("chrome_tabs.zig").layoutHash(frame.state.tabs);
        for (frame.state.tabs.tabs, 0..) |tab, i| frame.tabs_titles[i] = std.hash.Wyhash.hash(0, tab.title);
    }

    const impl = wlr.Buffer.Impl{
        .destroy = destroy,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginDataPtrAccess,
        .end_data_ptr_access = endDataPtrAccess,
    };

    pub fn create(logical_width: i32, state: ChromeState) !*ChromeBuffer {
        const frame = try gpa.create(ChromeBuffer);
        errdefer gpa.destroy(frame);

        const width = devicePixels(logical_width, state.scale);
        const height = devicePixels((Metrics{ .density = state.density }).titlebarHeight(), state.scale);
        const length: usize = @intCast(width * height);
        const pixels = try gpa.alloc(u32, length);
        errdefer gpa.free(pixels);

        frame.* = .{
            .base = undefined,
            .width = width,
            .height = height,
            .logical_width = logical_width,
            .state = state,
            .pixels = pixels,
        };
        frame.base.init(&impl, width, height);
        try frame.rasterize(null);
        frame.title_extent = frame.titleExtent();
        frame.rememberTabs();
        // The title belongs to wlroots and can change while this buffer lives.
        frame.state.title = "";
        frame.state.tabs.tabs = &.{};
        return frame;
    }

    /// Reuse stable fill, title and icon pixels. The old buffer remains
    /// immutable while wlroots may still be sampling it. `title_changed`
    /// repaints the span covering the old and new title (terminals animate
    /// their titles several times a second; a full raster evaluates every
    /// control and corner SDF again for pixels that cannot change).
    pub fn createUpdated(previous: *const ChromeBuffer, state: ChromeState, title_changed: bool) !*ChromeBuffer {
        const frame = try gpa.create(ChromeBuffer);
        errdefer gpa.destroy(frame);
        const pixels = try gpa.dupe(u32, previous.pixels);
        errdefer gpa.free(pixels);
        frame.* = previous.*;
        frame.pixels = pixels;
        frame.state = state;
        frame.base.init(&impl, frame.width, frame.height);
        if (state.tabs.tabs.len > 0) {
            const tabs = @import("chrome_tabs.zig");
            if (previous.tabs_layout_hash == tabs.layoutHash(state.tabs) and
                previous.state.hover == state.hover and previous.state.chip_pos == state.chip_pos and previous.state.chip_alpha == state.chip_alpha and previous.state.maximized == state.maximized)
            {
                const geom = tabs.geometry(frame.logical_width, state.density, state.tabs);
                for (state.tabs.tabs[geom.first..][0..geom.count], 0..) |tab, i| {
                    if (previous.tabs_titles[geom.first + i] == std.hash.Wyhash.hash(0, tab.title)) continue;
                    const rect = geom.tab(i);
                    const left: i32 = @intFromFloat(@floor(rect.x));
                    const right: i32 = @intFromFloat(@ceil(rect.x + rect.w));
                    try frame.rasterize(.{ .x = left, .y = 0, .w = right - left, .h = frame.height });
                }
            } else try frame.rasterize(null);
            frame.rememberTabs();
            frame.state.tabs.tabs = &.{};
            frame.state.title = "";
            return frame;
        }
        const controls_changed = previous.state.chip_pos != state.chip_pos or previous.state.chip_alpha != state.chip_alpha or previous.state.maximized != state.maximized;
        const Span = struct { x0: i32, x1: i32 };
        var spans: [2]Span = undefined;
        var count: usize = 0;
        if (title_changed or previous.state.active != state.active) {
            frame.title_extent = frame.titleExtent();
            const rect = titleRect(frame.logical_width, state);
            const extent = @max(previous.title_extent, frame.title_extent);
            if (extent > 0) {
                spans[count] = .{ .x0 = rect.x, .x1 = rect.x + extent };
                count += 1;
            }
        }
        var right = frame.logical_width;
        if (controls_changed) right = @min(right, @max(0, controlRectScaled(frame.logical_width, .minimize, frame.state.density).x - 1));
        if (right < frame.logical_width) {
            spans[count] = .{ .x0 = right, .x1 = frame.logical_width };
            count += 1;
        }
        std.mem.sort(Span, spans[0..count], {}, struct {
            fn less(_: void, a: Span, b: Span) bool {
                return a.x0 < b.x0;
            }
        }.less);
        // A narrow frame can make the regions overlap. Rasterize their union
        // once, so text coverage is never composited twice.
        const band_h = (Metrics{ .density = state.density }).titlebarHeight();
        var i: usize = 0;
        while (i < count) {
            var span = spans[i];
            i += 1;
            while (i < count and spans[i].x0 <= span.x1) : (i += 1) span.x1 = @max(span.x1, spans[i].x1);
            try frame.rasterize(.{ .x = span.x0, .y = 0, .w = span.x1 - span.x0, .h = band_h });
        }
        frame.state.title = "";
        frame.state.tabs.tabs = &.{};
        return frame;
    }

    /// The span the title can occupy: after the app icon, before the controls.
    fn titleRect(logical_width: i32, state: ChromeState) text.Rect {
        const m: Metrics = .{ .density = state.density };
        const title_left: i32 = if (state.icon != null) m.length(title_inset) + m.iconSize() + m.length(title_icon_gap) else m.length(title_inset);
        const controls_left = controlRectScaled(logical_width, .minimize, state.density).x;
        return .{ .x = title_left, .y = 0, .w = @max(0, controls_left - title_left), .h = m.titlebarHeight() - frame_border };
    }

    /// Logical width the current title can ink, measured from the title
    /// rect's left edge: its advance plus a margin for glyph overhang and
    /// antialiasing, capped by the rect (long titles are ellipsized to it).
    fn titleExtent(frame: *const ChromeBuffer) i32 {
        if (frame.state.title.len == 0) return 0;
        const rect = titleRect(frame.logical_width, frame.state);
        const m: Metrics = .{ .density = frame.state.density };
        const width = text.measureWidth(frame.state.title, frame.state.titleFont(), theme.global.title_size * m.density, frame.state.scale) catch return rect.w;
        return @min(rect.w, width + 2);
    }

    fn destroy(base: *wlr.Buffer) callconv(.c) void {
        const frame: *ChromeBuffer = @fieldParentPtr("base", base);
        gpa.free(frame.pixels);
        gpa.destroy(frame);
    }

    fn beginDataPtrAccess(
        base: *wlr.Buffer,
        _: u32,
        data: **anyopaque,
        format: *u32,
        stride: *usize,
    ) callconv(.c) bool {
        const frame: *ChromeBuffer = @fieldParentPtr("base", base);
        data.* = @ptrCast(frame.pixels.ptr);
        format.* = drm_format_argb8888;
        stride.* = @as(usize, @intCast(frame.width)) * @sizeOf(u32);
        return true;
    }

    fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}

    fn rasterize(frame: *ChromeBuffer, clip: ?Rect) !void {
        const scale = frame.state.scale;
        const m: Metrics = .{ .density = frame.state.density };
        const min_btn = controlRectScaled(frame.logical_width, .minimize, frame.state.density);
        const max_btn = controlRectScaled(frame.logical_width, .maximize, frame.state.density);
        const close_btn = controlRectScaled(frame.logical_width, .close, frame.state.density);
        // All glyphs fit inside their buttons. Include a full device pixel
        // around the group for antialiasing, including fractional scales.
        const control_left = @as(f32, @floatFromInt(min_btn.x)) - 1 / scale;
        const control_right = @as(f32, @floatFromInt(close_btn.x + close_btn.w)) + 1 / scale;
        const control_top = @as(f32, @floatFromInt(min_btn.y)) - 1 / scale;
        const control_bottom = @as(f32, @floatFromInt(min_btn.y + min_btn.h)) + 1 / scale;
        const diag = std.math.sqrt1_2;
        const icon_left: f32 = @floatFromInt(m.length(title_inset));
        const icon_top: f32 = @floatFromInt(@divTrunc(m.titlebarHeight() - m.iconSize(), 2));
        const base = Color.chrome();
        // Away from the controls and the icon every pixel in a row has the same
        // fill. Pack that colour once instead of repeating four rounded float
        // conversions across the bar.
        const stride: usize = @intCast(frame.width);

        const x0: usize = if (clip) |box| @intCast(@min(frame.width, @max(0, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(box.x)) * scale)))))) else 0;
        const x1: usize = if (clip) |box| @intCast(@min(frame.width, @max(0, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(box.x + box.w)) * scale)))))) else stride;
        for (0..@intCast(frame.height)) |device_y| {
            const py = (@as(f32, @floatFromInt(device_y)) + 0.5) / scale;
            const yi: i32 = @intFromFloat(@floor(py));
            const row = device_y * stride;
            var row_color = base;
            if (yi == m.titlebarHeight() - 1) row_color = Color.divider().over(row_color);
            const flat_color = row_color.argb();
            const control_row = py >= control_top and py <= control_bottom;
            const icon_row = frame.state.tabs.tabs.len == 0 and frame.state.icon != null and
                py >= icon_top and py < icon_top + @as(f32, @floatFromInt(m.iconSize()));
            for (x0..x1) |x| {
                const px = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
                const in_controls = control_row and px >= control_left and px <= control_right;
                const in_icon = icon_row and px >= icon_left and px < icon_left + @as(f32, @floatFromInt(m.iconSize()));
                if (!in_controls and !in_icon) {
                    frame.pixels[row + x] = flat_color;
                    continue;
                }

                var color = row_color;
                if (in_controls) {
                    color = paintControls(
                        color,
                        px,
                        py,
                        min_btn,
                        max_btn,
                        close_btn,
                        frame.state.chip_pos,
                        frame.state.chip_alpha,
                        diag,
                        scale,
                        m.contentScale(),
                        frame.state.maximized,
                    );
                }

                if (if (frame.state.tabs.tabs.len == 0) frame.state.icon else null) |icon| {
                    if (px >= icon_left and px < icon_left + @as(f32, @floatFromInt(m.iconSize())) and
                        py >= icon_top and py < icon_top + @as(f32, @floatFromInt(m.iconSize())))
                    {
                        const ix: i32 = @intFromFloat(@floor((px - icon_left) * scale));
                        const iy: i32 = @intFromFloat(@floor((py - icon_top) * scale));
                        if (ix >= 0 and ix < icon.size and iy >= 0 and iy < icon.size) {
                            const sample = icon.pixels[@intCast(iy * icon.size + ix)];
                            color = Color.fromPremultiplied(sample).over(color);
                        }
                    }
                }

                frame.pixels[row + x] = color.argb();
            }
        }

        if (frame.state.tabs.tabs.len > 0) {
            @import("chrome_tabs.zig").paint(Color, frame.pixels, frame.width, frame.height, frame.logical_width, frame.state.density, scale, frame.state.tabs, frame.state.icon, clip);
            return;
        }
        const text_rect = titleRect(frame.logical_width, frame.state);
        var text_clip = text_rect;
        if (clip) |box| {
            const left = @max(text_rect.x, box.x);
            const right = @min(text_rect.x + text_rect.w, box.x + box.w);
            if (right <= left) return;
            text_clip.x = left;
            text_clip.w = right - left;
        }
        try text.drawOpts(
            frame.pixels,
            frame.width,
            frame.height,
            frame.state.title,
            .{ .r = Color.text().r, .g = Color.text().g, .b = Color.text().b, .a = Color.text().a },
            scale,
            frame.state.titleFont(),
            theme.global.title_size * m.density,
            .{ .rect = text_rect, .clip = text_clip },
        );
    }
};

// What the window's analytic shadow was last set from (Toplevel.syncShadow).
pub const ShadowMemo = struct {
    width: i32,
    height: i32,
    radius: f32,
    color: [4]f32,
    softness: f32,
    offset_y: f32,
    scale: f32,
    disabled: bool,

    pub fn capture(width: i32, height: i32, radius: f32, scale: f32, disabled: bool) ShadowMemo {
        const t = theme.global;
        return .{
            .width = width,
            .height = height,
            .radius = radius,
            .color = t.shadow,
            .softness = t.shadow_size,
            .offset_y = t.shadow_offset_y,
            .scale = scale,
            .disabled = disabled,
        };
    }

    pub fn eql(a: ShadowMemo, b: ShadowMemo) bool {
        if (a.disabled != b.disabled) return false;
        if (a.disabled) return true;
        return a.width == b.width and
            a.height == b.height and
            a.radius == b.radius and
            rgbaEql(a.color, b.color) and
            a.softness == b.softness and
            a.offset_y == b.offset_y and
            a.scale == b.scale;
    }
};

test "titlebar glass holds only while the titlebar is at least 98% opaque" {
    const saved = theme.global.window_bg;
    defer theme.global.window_bg = saved;
    theme.global.window_bg[3] = 0.98;
    try std.testing.expect(titlebarGlassMayHold(1));
    try std.testing.expect(!titlebarGlassMayHold(0.9));
    theme.global.window_bg[3] = 250.0 / 255.0; // #rrggbbfa
    try std.testing.expect(titlebarGlassMayHold(1));
    theme.global.window_bg[3] = 0.97;
    try std.testing.expect(!titlebarGlassMayHold(1));
}

fn borderFill(hover: f32) Color {
    const t = clamp01(hover);
    if (t <= 0) return Color.border();
    if (t >= 1) return Color.border_hover();
    return Color.lerp(Color.border(), Color.border_hover(), t);
}

/// Straight border edges, matching the rasterized corner arcs.
pub fn borderColor(hover: f32) col.Premul {
    return borderFill(hover).straight().premultiply();
}

fn windowBorderFill(hover: f32, workspace_focus: bool) Color {
    return if (workspace_focus) Color.fromRgba(theme.global.workspace_active_border) else borderFill(hover);
}

pub fn windowBorderColor(hover: f32, workspace_focus: bool) col.Premul {
    return windowBorderFill(hover, workspace_focus).straight().premultiply();
}

/// Chrome backing beneath the border, shared by the header and client sides.
pub fn fillColor() col.Premul {
    return Color.chrome().straight().premultiply();
}

const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    // Decoration-specific colors leave the rest of the shell independent.
    fn chrome() Color {
        return fromRgba(theme.global.window_bg);
    }
    fn border() Color {
        return fromRgba(theme.global.window_border);
    }
    fn divider() Color {
        return fromRgba(theme.global.window_divider);
    }
    fn text_dim() Color {
        return fromRgba(theme.global.window_dim);
    }

    // .window:hover border, .win-btn:hover, .win-btn.close:hover and --text.
    fn border_hover() Color {
        return fromRgba(theme.global.window_border_hover);
    }
    fn control_hover() Color {
        return fromRgba(theme.global.surface_hover);
    }
    fn close_hover() Color {
        var c = fromRgba(theme.global.window_close_hover);
        c.a *= theme.global.window_close_hover_alpha;
        return c;
    }
    fn text() Color {
        return fromRgba(theme.global.window_fg);
    }
    fn textOnClose() Color {
        return Color.fromRgba(theme.global.window_close_fg);
    }

    pub fn fromRgba(rgba: [4]f32) Color {
        return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
    }

    // Unpacks a premultiplied 0xAARRGGBB sample (icon_cache.Entry.pixels'
    // format) back to this struct's straight alpha. Mirrors
    // Taskbar.Color.fromPremultiplied; the two Color types are private to
    // each file, so this is a small, deliberate duplicate rather than a
    // shared one.
    pub fn fromPremultiplied(sample: u32) Color {
        const a: f32 = @as(f32, @floatFromInt((sample >> 24) & 0xff)) / 255.0;
        if (a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const r: f32 = @as(f32, @floatFromInt((sample >> 16) & 0xff)) / 255.0;
        const g: f32 = @as(f32, @floatFromInt((sample >> 8) & 0xff)) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(sample & 0xff)) / 255.0;
        return .{ .r = r / a, .g = g / a, .b = b / a, .a = a };
    }

    pub fn over(source: Color, destination: Color) Color {
        const alpha = source.a + destination.a * (1 - source.a);
        if (alpha == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .r = (source.r * source.a + destination.r * destination.a * (1 - source.a)) / alpha,
            .g = (source.g * source.a + destination.g * destination.a * (1 - source.a)) / alpha,
            .b = (source.b * source.a + destination.b * destination.a * (1 - source.a)) / alpha,
            .a = alpha,
        };
    }

    pub fn lerp(from: Color, to: Color, t: f32) Color {
        return .{
            .r = from.r + (to.r - from.r) * t,
            .g = from.g + (to.g - from.g) * t,
            .b = from.b + (to.b - from.b) * t,
            .a = from.a + (to.a - from.a) * t,
        };
    }

    pub fn scaled(color: Color, alpha: f32) Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a * alpha };
    }

    fn straight(color: Color) col.Straight {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    }

    pub fn argb(color: Color) u32 {
        return color.straight().argb();
    }
};

fn paintControls(
    base: Color,
    px: f32,
    py: f32,
    min_btn: Rect,
    max_btn: Rect,
    close_btn: Rect,
    chip_pos: f32,
    chip_alpha: f32,
    diag: f32,
    scale: f32,
    density: f32,
    maximized: bool,
) Color {
    var color = base;

    // Window-control hover chip, drawn under the glyph. One chip
    // slides between the buttons; its rect and red-ness are interpolated
    // from the slot coordinate.
    if (chip_alpha > 0) {
        const pos = std.math.clamp(chip_pos, 0, 2);
        const from_max = pos >= 1;
        const a_btn = if (from_max) max_btn else min_btn;
        const b_btn = if (from_max) close_btn else max_btn;
        const t = if (from_max) pos - 1 else pos;
        const chip_width = mix(@floatFromInt(a_btn.w), @floatFromInt(b_btn.w), t);
        const chip_height = mix(@floatFromInt(a_btn.h), @floatFromInt(b_btn.h), t);
        const fill = Color.lerp(Color.control_hover(), Color.close_hover(), clamp01(pos - 1));
        const chip = edgeCoverage(sdRoundedBox(
            px,
            py,
            mix(@floatFromInt(a_btn.x), @floatFromInt(b_btn.x), t),
            mix(@floatFromInt(a_btn.y), @floatFromInt(b_btn.y), t),
            chip_width,
            chip_height,
            window_chrome.cornerRadius(theme.global.chrome_round_buttons, chip_width, chip_height, btn_radius * density),
        ), scale);
        if (chip > 0) color = fill.scaled(chip * clamp01(chip_alpha)).over(color);
    }

    // Enlarge glyphs within the existing hover chips and hit targets.
    const glyph_scale = density * button_glyph_scale;
    const min_cov = minimizeIconCoverage(min_btn.centerX() + (px - min_btn.centerX()) / glyph_scale, min_btn.centerY() + (py - min_btn.centerY()) / glyph_scale, min_btn, scale * glyph_scale);
    if (min_cov > 0) color = iconColor(chip_pos, chip_alpha, .minimize).scaled(min_cov).over(color);
    const max_cov = maximizeIconCoverage(max_btn.centerX() + (px - max_btn.centerX()) / glyph_scale, max_btn.centerY() + (py - max_btn.centerY()) / glyph_scale, max_btn, scale * glyph_scale, maximized);
    if (max_cov > 0) color = iconColor(chip_pos, chip_alpha, .maximize).scaled(max_cov).over(color);
    const close_cov = closeIconCoverage(close_btn.centerX() + (px - close_btn.centerX()) / glyph_scale, close_btn.centerY() + (py - close_btn.centerY()) / glyph_scale, close_btn, diag, scale * glyph_scale);
    if (close_cov > 0) color = iconColor(chip_pos, chip_alpha, .close).scaled(close_cov).over(color);
    return color;
}

// Resting glyphs use neutral dim ink, --text on hover, #fff over close red.
fn iconColor(chip_pos: f32, chip_alpha: f32, kind: ControlKind) Color {
    // Keep the theme's dim brightness without its blue tint on the controls.
    const dim = Color.text_dim();
    const luminance = dim.r * 0.2126 + dim.g * 0.7152 + dim.b * 0.0722;
    const resting = Color{ .r = luminance, .g = luminance, .b = luminance, .a = dim.a };
    const weight = clamp01(1 - @abs(chip_pos - controlSlot(kind))) * clamp01(chip_alpha);
    return Color.lerp(resting, if (kind == .close) Color.textOnClose() else Color.text(), weight);
}

fn minimizeIconCoverage(px: f32, py: f32, btn: Rect, scale: f32) f32 {
    // A 12px dash at the lower edge of the glyph area.
    const cx = btn.centerX();
    const cy = btn.centerY() + 5;
    return edgeCoverage(sdRoundedBox(px, py, cx - 6, cy - 0.85, 12, 1.7, 0.85), scale);
}

fn maximizeIconCoverage(px: f32, py: f32, btn: Rect, scale: f32, maximized: bool) f32 {
    // A 10px outlined square, balanced against the dash and close glyph.
    const cx = btn.centerX();
    const cy = btn.centerY();
    if (!maximized) return outlineSquare(px, py, cx, cy, scale);
    // The lower-left window shows only its left and bottom edges, leaving
    // a clear gap around the complete upper-right window.
    const lower = edgeCoverage(@min(
        sdRoundedBox(px, py, cx - 7, cy - 3, 1.5, 10, 0.5),
        sdRoundedBox(px, py, cx - 7, cy + 5.5, 10, 1.5, 0.5),
    ), scale);
    return @max(lower, outlineSquare(px - 2, py + 2, cx, cy, scale));
}

fn outlineSquare(px: f32, py: f32, cx: f32, cy: f32, scale: f32) f32 {
    const outer = edgeCoverage(sdRoundedBox(px, py, cx - 5, cy - 5, 10, 10, 1), scale);
    const inner = edgeCoverage(sdRoundedBox(px, py, cx - 3.5, cy - 3.5, 7, 7, 0.5), scale);
    return clamp01(outer - inner);
}

const closeIconCoverage = window_chrome.closeIconCoverage;

// Shared with ui/paint.zig, which must not depend on the compositor.
pub const sdQuad = sdf.sdQuad;
pub const sdRoundedBox = sdf.sdRoundedBox;
pub const coverage = sdf.coverage;

// Same ramp, but for a distance measured in logical pixels while sampling on a
// denser grid: the edge stays one device pixel wide however far it is scaled.
inline fn edgeCoverage(distance: f32, scale: f32) f32 {
    return clamp01(0.5 - distance * scale);
}

pub fn devicePixels(logical: i32, scale: f32) i32 {
    return geometry.devicePixels(logical, scale);
}

inline fn clamp01(value: f32) f32 {
    return @max(0, @min(1, value));
}

fn sampleTitlebarMemo() TitlebarMemo {
    return .{
        .width = 200,
        .height = 100,
        .title_ptr = null,
        .scale = 1,
        .hover = 0,
        .chip_pos = 0,
        .chip_alpha = 0,
        .maximized = false,
        .icon = null,
        .glass = .{ 0, 0, 0, 1 },
        .border = .{ 1, 1, 1, 0.09 },
        .border_soft = .{ 1, 1, 1, 0.06 },
        .fg = .{ 1, 1, 1, 1 },
        .dim = .{ 0.5, 0.5, 0.5, 1 },
        .border_hover = .{ 1, 1, 1, 0.22 },
        .surface_hover = .{ 1, 1, 1, 0.08 },
        .danger = .{ 1, 0, 0, 1 },
        .title_size = 13.5,
    };
}

test "TitlebarMemo.eql is true for identical inputs" {
    try std.testing.expect(sampleTitlebarMemo().eql(sampleTitlebarMemo()));
    const inactive = sampleTitlebarMemo();
    var active = inactive;
    active.active = true;
    try std.testing.expect(!inactive.eql(active));
    try std.testing.expect(inactive.reusableFor(active));
}

test "TitlebarMemo.eql compares the title pointer, not the string contents" {
    var a_buf = [_:0]u8{ 'h', 'e', 'l', 'l', 'o' };
    var b_buf = [_:0]u8{ 'h', 'e', 'l', 'l', 'o' };
    var left = sampleTitlebarMemo();
    var right = sampleTitlebarMemo();
    left.title_ptr = &a_buf;
    right.title_ptr = &b_buf;
    try std.testing.expect(!left.eql(right));
    right.title_ptr = &a_buf;
    try std.testing.expect(left.eql(right));
}

test "TitlebarMemo.eql compares icon identity by id, not pixel pointer" {
    var pixels_a = [_]u32{0xFF000000};
    var pixels_b = [_]u32{0xFF000000};
    var left = sampleTitlebarMemo();
    var right = sampleTitlebarMemo();

    // Same id, different backing pixel buffers: still the same icon.
    left.icon = .{ .id = 1, .pixels = &pixels_a, .size = 1 };
    right.icon = .{ .id = 1, .pixels = &pixels_b, .size = 1 };
    try std.testing.expect(left.eql(right));

    // Different id, even sharing a pixel buffer: a different icon. A raw
    // pointer comparison would get this wrong once eviction can free and
    // reuse a buffer's address for a different icon.
    right.icon = .{ .id = 2, .pixels = &pixels_a, .size = 1 };
    try std.testing.expect(!left.eql(right));
}

test "TitlebarMemo.eql detects font, title size and close control appearance" {
    var left = sampleTitlebarMemo();
    var right = sampleTitlebarMemo();
    right.font_generation +%= 1;
    try std.testing.expect(!left.eql(right));
    try std.testing.expect(!left.reusableFor(right));
    right = left;
    right.title_size = 14;
    try std.testing.expect(!left.eql(right));
    right = left;
    right.close_fg = .{ 0, 1, 0, 1 };
    try std.testing.expect(!left.eql(right));
    right = left;
    right.close_hover_alpha = 0.4;
    try std.testing.expect(!left.eql(right));
}

test "TitlebarMemo.capture reads title_size from theme.global" {
    const saved = theme.global;
    defer theme.global = saved;
    theme.global.title_size = 19.25;
    const memo = TitlebarMemo.capture(10, 10, null, .{ .scale = 1 });
    try std.testing.expectEqual(@as(f32, 19.25), memo.title_size);
}

test "chrome geometry changes invalidate retained titlebar pixels" {
    const saved = theme.global;
    defer theme.global = saved;
    const before = TitlebarMemo.capture(400, 320, null, .{});
    theme.global.chrome_control_gap += 1;
    const spaced = TitlebarMemo.capture(400, 320, null, .{});
    try std.testing.expect(!before.eql(spaced));
    try std.testing.expect(!before.reusableFor(spaced));
    theme.global.chrome_control_gap = saved.chrome_control_gap;
    theme.global.chrome_height += 1;
    const taller = TitlebarMemo.capture(400, 320, null, .{});
    try std.testing.expect(!before.reusableFor(taller));
    theme.global.chrome_height = saved.chrome_height;
    theme.global.chrome_round_buttons = !saved.chrome_round_buttons;
    const round = TitlebarMemo.capture(400, 320, null, .{});
    try std.testing.expect(!before.eql(round));
    try std.testing.expect(!before.reusableFor(round));
}

test "chrome controls fit and stay centered at every supported height and density" {
    const saved = theme.global;
    defer theme.global = saved;
    for ([_]f32{ 28, 55, 84 }) |height| {
        theme.global.chrome_height = height;
        for ([_]f32{ 1, 0.75 }) |density| {
            const m: Metrics = .{ .density = density };
            for ([_]f32{ 0, 4, 24 }) |gap| {
                theme.global.chrome_control_gap = gap;
                const min = controlRectScaled(400, .minimize, density);
                const max = controlRectScaled(400, .maximize, density);
                const close = controlRectScaled(400, .close, density);
                try std.testing.expectEqual(m.controlGap(), max.x - (min.x + min.w));
                try std.testing.expectEqual(m.controlGap(), close.x - (max.x + max.w));
                try std.testing.expect(min.y >= 0 and min.y + min.h < m.titlebarHeight());
                try std.testing.expect(@abs(2 * min.y + min.h - m.titlebarHeight()) <= 1);
                try std.testing.expect(m.iconSize() < min.h);
                try std.testing.expect(min.x > m.length(title_inset) + m.iconSize() + m.length(title_icon_gap));
            }
        }
    }
}

test "ShadowMemo.eql ignores geometry while the shadow is disabled" {
    const a = ShadowMemo{
        .width = 10,
        .height = 10,
        .radius = 0,
        .color = .{ 0, 0, 0, 0 },
        .softness = 0,
        .offset_y = 0,
        .scale = 1,
        .disabled = true,
    };
    var b = a;
    b.width = 999;
    try std.testing.expect(a.eql(b));
    b.disabled = false;
    try std.testing.expect(!a.eql(b));
}

test "ShadowMemo.eql is false when softness changes" {
    const a = ShadowMemo{
        .width = 200,
        .height = 100,
        .radius = 10,
        .color = .{ 0, 0, 0, 0.35 },
        .softness = 24,
        .offset_y = 8,
        .scale = 1,
        .disabled = false,
    };
    var b = a;
    try std.testing.expect(a.eql(b));
    b.softness = 32;
    try std.testing.expect(!a.eql(b));
}

test "cached chrome updates exactly match complete rasters across hover controls and scales" {
    for ([_]i32{ 20, 200, 640 }) |width| {
        for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
            for ([_]f32{ 1, 0.75, 1.0 / 1.7 }) |density| {
                var state: ChromeState = .{ .density = density, .scale = scale, .title = "Cached window title" };
                var previous = try ChromeBuffer.create(width, state);
                defer previous.base.drop();
                // Titles change alone and together with hover and
                // controls: growing, shrinking, ellipsized, fallback
                // glyphs (a terminal spinner) and empty.
                const titles = [_][]const u8{
                    "Cached window title",
                    "\u{280b} Working on a task that is long enough to be ellipsized before the controls",
                    "Short",
                    "Short",
                    "",
                    "\u{2819} Working \u{2014} claude",
                };
                var step: usize = 0;
                for ([_]f32{ 0.35, 1, 0 }) |hover| {
                    for ([_]?ControlKind{ .minimize, .maximize, .close, null }) |control| {
                        const previous_title = state.title;
                        state.hover = hover;
                        state.chip_pos = if (control) |kind| controlSlot(kind) else 0.5;
                        state.chip_alpha = if (control == null) 0.35 else 1;
                        state.title = titles[step % titles.len];
                        state.active = step % 2 == 0;
                        state.workspace_focus = step % 3 == 0;
                        step += 1;
                        const expected = try ChromeBuffer.create(width, state);
                        defer expected.base.drop();
                        const updated = try ChromeBuffer.createUpdated(previous, state, !std.mem.eql(u8, previous_title, state.title));
                        errdefer updated.base.drop();
                        try std.testing.expectEqualSlices(u32, expected.pixels, updated.pixels);
                        previous.base.drop();
                        previous = updated;
                    }
                }
            }
        }
    }
}

test "tab title updates preserve neighbouring pixels and match a full raster" {
    const Tab = @import("chrome_tabs.zig").Tab;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const before = [_]Tab{ .{ .id = 1, .title = "A longer title", .active = true, .attention = false }, .{ .id = 2, .title = "Untouched", .active = false, .attention = false } };
        var state: ChromeState = .{ .scale = scale, .tabs = .{ .tabs = &before } };
        const old = try ChromeBuffer.create(600, state);
        defer old.base.drop();
        var after = before;
        after[0].title = "Short";
        state.tabs.tabs = &after;
        const updated = try ChromeBuffer.createUpdated(old, state, true);
        defer updated.base.drop();
        const full = try ChromeBuffer.create(600, state);
        defer full.base.drop();
        try std.testing.expectEqualSlices(u32, full.pixels, updated.pixels);
        const geom = @import("chrome_tabs.zig").geometry(600, 1, state.tabs);
        const untouched = geom.tab(1);
        for (0..@intCast(old.height)) |y| {
            const start: usize = y * @as(usize, @intCast(old.width)) + @as(usize, @intFromFloat(@ceil(untouched.x * scale)));
            const end: usize = y * @as(usize, @intCast(old.width)) + @as(usize, @intFromFloat(@floor((untouched.x + untouched.w) * scale)));
            try std.testing.expectEqualSlices(u32, old.pixels[start..end], updated.pixels[start..end]);
        }
    }
}
