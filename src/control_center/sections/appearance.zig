const i18n = @import("i18n");
// Control center "Appearance" section: UI font, font size, and corner
// radius, all of which write back to REDIWM_THEME and hot-reload (design
// doc Part 3, Section 2), plus the apps' dark mode and the wallpaper, which
// are `[compositor] dark_mode` and `wallpaper` in config.toml.
//
// Widget callbacks carry their owning Section explicitly.
const std = @import("std");

const layout = @import("ui").layout;
const ui_slider = @import("ui").widgets.slider;
const theme = @import("ui").theme;
const theme_presets = @import("config").theme_pack;
const Widget = layout.Widget;
const main = @import("../../main.zig");
const panel = @import("../panel.zig");
const loader = @import("config").loader;
const Taskbar = @import("../../Taskbar.zig");
const dock_mod = @import("../../Dock.zig");
const taskbar_items = @import("config").taskbar_items;
const cursor_theme = @import("../../cursor_theme.zig");
const wallpapers = @import("../../wallpapers.zig");
const wallpaper_strip = @import("../../wallpaper_strip.zig");
const folder_picker = @import("../folder_picker.zig");
const wl = @import("wayland").server.wl;
const anim = @import("ui").anim;
const col = @import("../../color.zig");
const geometry = @import("../../geometry.zig");
const start_button = @import("../../taskbar/start_button.zig");
const menu_size = @import("../../start_menu/size.zig");
const wlr = @import("wlroots");
const app_theme = @import("config").app_theme;
const AppColorsJob = @import("../../config_runtime/app_theme.zig").Job;
const appearance_wallpaper = @import("appearance_wallpaper.zig");
const appearance_colors = @import("appearance_colors.zig");
const appearance_themes = @import("appearance_themes.zig");
const appearance_chrome = @import("appearance_chrome.zig");
const appearance_items = @import("appearance_items.zig");
const appearance_dock = @import("appearance_dock.zig");
pub const tile_w = appearance_wallpaper.tile_w;
pub const tile_h = appearance_wallpaper.tile_h;
pub const tile_pad = appearance_wallpaper.tile_pad;
pub const tile_extent = appearance_wallpaper.tile_extent;
pub const strip_gap = appearance_wallpaper.strip_gap;
pub const check_size = appearance_wallpaper.check_size;
pub const chosen_dir = appearance_wallpaper.chosen_dir;
pub const stripFolder = appearance_wallpaper.stripFolder;
pub const tildePath = appearance_wallpaper.tildePath;
pub const stopStrip = appearance_wallpaper.stopStrip;
pub const deinit = appearance_wallpaper.deinit;
pub const appColorsNote = appearance_colors.appColorsNote;
pub const onApplyAppColors = appearance_colors.onApplyAppColors;
pub const appColorsFailure = appearance_colors.appColorsFailure;
pub const finishAppColors = appearance_colors.finishAppColors;
pub const appColorsReady = appearance_colors.appColorsReady;
pub const stripWake = appearance_wallpaper.stripWake;
pub const restartStrip = appearance_wallpaper.restartStrip;
pub const buildWallpaper = appearance_wallpaper.buildWallpaper;
pub const buildStrip = appearance_wallpaper.buildStrip;
pub const onStripTile = appearance_wallpaper.onStripTile;
pub const onStripCheck = appearance_wallpaper.onStripCheck;
pub const pickStripEntry = appearance_wallpaper.pickStripEntry;
pub const onWallpaperPicked = appearance_wallpaper.onWallpaperPicked;
pub const applyWallpaper = appearance_wallpaper.applyWallpaper;
pub const onChooseWallpaperFolder = appearance_wallpaper.onChooseWallpaperFolder;
pub const onFolderChosen = appearance_wallpaper.onFolderChosen;
pub const applyThemeChange = appearance_themes.applyThemeChange;
pub const applyThemeChangeImpl = appearance_themes.applyThemeChangeImpl;
pub const saveThemeChange = appearance_themes.saveThemeChange;
pub const onChooseStartLogo = appearance_themes.onChooseStartLogo;
pub const onStartLogoChosen = appearance_themes.onStartLogoChosen;
pub const onAutoMenuSize = appearance_themes.onAutoMenuSize;
pub const onResetStartLogo = appearance_themes.onResetStartLogo;
pub const refreshTheme = appearance_themes.refreshTheme;
pub const onResetTheme = appearance_themes.onResetTheme;
pub const themeFailure = appearance_themes.themeFailure;
pub const onInstallTheme = appearance_themes.onInstallTheme;
pub const themeFileChosen = appearance_themes.themeFileChosen;
pub const onReplaceTheme = appearance_themes.onReplaceTheme;
pub const onRemoveTheme = appearance_themes.onRemoveTheme;
pub const onExportTheme = appearance_themes.onExportTheme;
pub const exportFileChosen = appearance_themes.exportFileChosen;
pub const onIconThemePicked = appearance_themes.onIconThemePicked;
pub const onThemePicked = appearance_themes.onThemePicked;
pub const onTaskbarThemePicked = appearance_themes.onTaskbarThemePicked;
pub const ClockStyle = appearance_chrome.ClockStyle;
pub const onFontFamilyChanged = appearance_chrome.onFontFamilyChanged;
pub const onFontSizeChanged = appearance_chrome.onFontSizeChanged;
pub const onRadiusChanged = appearance_chrome.onRadiusChanged;
pub const onShadowChanged = appearance_chrome.onShadowChanged;
pub const onBorderGlowChanged = appearance_chrome.onBorderGlowChanged;
pub const onChromeOpacityChanged = appearance_chrome.onChromeOpacityChanged;
pub const onChromeDarknessChanged = appearance_chrome.onChromeDarknessChanged;
pub const onInactiveDimChanged = appearance_chrome.onInactiveDimChanged;
pub const onInactiveOpacityChanged = appearance_chrome.onInactiveOpacityChanged;
pub const onTerminalOpacityChanged = appearance_chrome.onTerminalOpacityChanged;
pub const max_window_gap = appearance_chrome.max_window_gap;
pub const onWindowGapChanged = appearance_chrome.onWindowGapChanged;
pub const onTaskbarPositionChanged = appearance_chrome.onTaskbarPositionChanged;
pub const onFocusZoomChanged = appearance_chrome.onFocusZoomChanged;
pub const onDragFeedbackChanged = appearance_chrome.onDragFeedbackChanged;
pub const onDragScaleChanged = appearance_chrome.onDragScaleChanged;
pub const onAnimationsEnabledChanged = appearance_chrome.onAnimationsEnabledChanged;
pub const onAnimSpeedChanged = appearance_chrome.onAnimSpeedChanged;
pub const onReducedMotionChanged = appearance_chrome.onReducedMotionChanged;
pub const onCursorThemePicked = appearance_chrome.onCursorThemePicked;
pub const onDarkModeChanged = appearance_chrome.onDarkModeChanged;
pub const onSplashStartupChanged = appearance_chrome.onSplashStartupChanged;
pub const onDodgeFileDragsChanged = appearance_chrome.onDodgeFileDragsChanged;
pub const saveItems = appearance_items.saveItems;
pub const item_row_height = appearance_items.item_row_height;
pub const itemRowStyle = appearance_items.itemRowStyle;
pub const itemZoneStyle = appearance_items.itemZoneStyle;
pub const itemName = appearance_items.itemName;
pub const syncItems = appearance_items.syncItems;
pub const itemHandle = appearance_items.itemHandle;
pub const beginItemDrag = appearance_items.beginItemDrag;
pub const previewItems = appearance_items.previewItems;
pub const moveItemDrag = appearance_items.moveItemDrag;
pub const endItemDrag = appearance_items.endItemDrag;
pub const restoreItemFocus = appearance_items.restoreItemFocus;
pub const captureItemFocus = appearance_items.captureItemFocus;
pub const itemKey = appearance_items.itemKey;
pub const ItemToggle = appearance_items.ItemToggle;
pub const buildWindowTabs = appearance_dock.buildWindowTabs;
pub const onWindowTabsChanged = appearance_dock.onWindowTabsChanged;
pub const section = appearance_dock.section;
pub const onDockChanged = appearance_dock.onDockChanged;
pub const onDockAutoHideChanged = appearance_dock.onDockAutoHideChanged;
pub const onDockOpacityChanged = appearance_dock.onDockOpacityChanged;
pub const onDockActiveHighlightChanged = appearance_dock.onDockActiveHighlightChanged;
pub const onDockShowTrashChanged = appearance_dock.onDockShowTrashChanged;
pub const onDockPositionChanged = appearance_dock.onDockPositionChanged;
pub const onDockHeightChanged = appearance_dock.onDockHeightChanged;
pub const updateDockZoomLabel = appearance_dock.updateDockZoomLabel;
pub const onDockHoverZoomChanged = appearance_dock.onDockHoverZoomChanged;

pub const segmented_width: f32 = 180;
/// The dock's corner radius slider. A theme's `dock_radius` of zero means "the
/// window radius", so the slider starts at 1 px (square to the eye) and a
/// chosen value is never mistaken for it. Half the tallest dock caps it.
pub const dock_radius_min: f32 = 1;
pub const dock_radius_max: f32 = 48;

pub const font_values = [3]f32{ 12, 13, 14 };
pub const font_labels = [_]i18n.Message{ i18n.msg("Small"), i18n.msg("Medium"), i18n.msg("Large") };
pub const radius_labels = [_]i18n.Message{ i18n.msg("Sharp"), i18n.msg("Default"), i18n.msg("Round") };
pub const shadow_size_values = [3]f32{ 0, 16, 32 };
pub const shadow_alpha_values = [3]f32{ 0, 0.28, 0.45 };
pub const shadow_labels = [_]i18n.Message{ i18n.msg("None"), i18n.msg("Soft"), i18n.msg("Strong") };
pub const anim_speed_values = [4]f32{ 0.5, 1.0, 1.5, 2.0 };
pub const anim_speed_labels = [_][]const u8{ "0.5×", "1.0×", "1.5×", "2.0×" };
pub const reduced_motion_values = [3]anim.ReducedMotion{ .auto, .on, .off };
pub const reduced_motion_labels = [_]i18n.Message{ i18n.msg("Auto"), i18n.msg("On"), i18n.msg("Off") };
pub const focus_zoom_labels = [_]i18n.Message{ i18n.msg("Keep zoom"), i18n.msg("Boost window"), i18n.msg("Focus camera") };
pub const focus_zoom_descriptions = [_]i18n.Message{
    i18n.msg("Pan to the selected window without changing zoom."),
    i18n.msg("Temporarily show the selected window at full size; keep desktop zoom."),
    i18n.msg("Zoom the desktop to the selected window's level; fade windows passed by the camera."),
};

pub fn indexOfReducedMotion(m: anim.ReducedMotion) usize {
    return switch (m) {
        .auto => 0,
        .on => 1,
        .off => 2,
    };
}

/// One "label + value" slider row (e.g. "Taskbar size ... 54px"), keyed by
/// index into `Section.px` below. Grouped into an array instead of one field
/// per control since the pixel sliders
/// are otherwise identical boilerplate.
pub const PxControl = struct {
    header_children: [2]Widget = undefined,
    group_children: [2]Widget = undefined,
    value_buf: [16]u8 = undefined,
};

pub const px_taskbar_size = 0;
pub const px_chip_gap = 1;
pub const px_start_button_gap = 2;
pub const px_start_icon_size = 3;
pub const px_menu_left = 4;
pub const px_menu_bottom = 5;
pub const px_icon_left = 6;
pub const px_icon_bottom = 7;
pub const px_scrollbar_width = 8;
pub const px_chip_width = 9;
pub const px_window_gap = 10;
pub const px_chrome_height = 11;
pub const px_chrome_control_gap = 12;
pub const px_menu_width = 13;
pub const px_menu_height = 14;
pub const px_dock_height = 15;
pub const px_dock_hover_zoom = 16;
pub const px_taskbar_edge_gap = 17;
pub const px_taskbar_length = 18;
pub const px_taskbar_radius = 19;
pub const px_dock_opacity = 20;
pub const px_dock_radius = 21;

pub const Section = struct {
    cc: *panel.ControlCenter = undefined,
    root: Widget = undefined,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    presets: []const theme_presets.Pack = &.{},
    top_children: [2]Widget = undefined,
    font_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    font_families: ?[][]const u8 = null,
    /// Installed cursor themes, scanned once per section like the fonts.
    cursor_themes: ?[]cursor_theme.Theme = null,
    cursor_row_children: [2]Widget = undefined,
    family_row_children: [2]Widget = undefined,
    row_storage: [row_count]Widget = undefined,
    /// The page: `groups`, each one card with a title over its rows.
    group_storage: [row_count + groups.len]Widget = undefined,
    group_cards: [groups.len]Widget = undefined,
    dock_children: [2]Widget = undefined,
    dock_position_children: [2]Widget = undefined,
    dock_auto_hide_children: [2]Widget = undefined,
    dock_active_children: [2]Widget = undefined,
    dock_trash_children: [2]Widget = undefined,
    dock_group_children: [10]Widget = undefined,
    focus_zoom_children: [3]Widget = undefined,
    drag_feedback_children: [2]Widget = undefined,
    drag_scale_header_children: [2]Widget = undefined,
    drag_scale_children: [2]Widget = undefined,
    drag_scale_value_buf: [16]u8 = undefined,
    /// Rescanned on every build, so images added meanwhile show up.
    wallpapers: []const wallpapers.Entry = &.{},
    wallpaper_children: [3]Widget = undefined,
    /// What the wallpaper strip shows: the chosen folder's images, or
    /// the wallpaper directories'. Thumbnails decode on a worker.
    strip_entries: []const wallpapers.Entry = &.{},
    strip: ?*wallpaper_strip.Strip = null,
    strip_source: ?*wl.EventSource = null,
    /// `wallpaper_children[strip_index]` holds a scroll container to carry over.
    strip_built: bool = false,
    wallpaper_row_children: [2]Widget = undefined,
    wallpaper_footer_children: [2]Widget = undefined,
    theme_row_children: [2]Widget = undefined,
    theme_actions: [5]Widget = undefined,
    theme_preview_pending: bool = false,
    theme_message: []const u8 = "",
    theme_message_buf: [768]u8 = undefined,
    theme_pending_path: ?[]u8 = null,
    icon_theme_row: [2]Widget = undefined,
    icon_theme_names: []const []const u8 = &.{},

    taskbar_theme_row_children: [2]Widget = undefined,
    app_colors_children: [3]Widget = undefined,
    app_colors_buttons: [2]Widget = undefined,
    app_colors_job: ?*AppColorsJob = null,
    app_colors_source: ?*wl.EventSource = null,
    app_colors_message: []const u8 = "",
    app_colors_message_buf: [384]u8 = undefined,
    dark_row_children: [2]Widget = undefined,
    dark_label_children: [2]Widget = undefined,
    splash_row_children: [2]Widget = undefined,
    splash_label_children: [2]Widget = undefined,
    dodge_row_children: [2]Widget = undefined,
    dodge_label_children: [2]Widget = undefined,
    dim_row_children: [2]Widget = undefined,
    dim_label_children: [2]Widget = undefined,
    anim_enabled_row_children: [2]Widget = undefined,
    anim_enabled_label_children: [2]Widget = undefined,
    anim_speed_row_children: [2]Widget = undefined,
    reduced_motion_row_children: [2]Widget = undefined,
    font_row_children: [2]Widget = undefined,
    radius_row_children: [2]Widget = undefined,
    shadow_row_children: [2]Widget = undefined,
    glow_row_children: [2]Widget = undefined,
    glow_label_children: [2]Widget = undefined,
    opacity_header_children: [2]Widget = undefined,
    opacity_group_children: [2]Widget = undefined,
    opacity_value_buf: [16]u8 = undefined,
    darkness_header_children: [2]Widget = undefined,
    darkness_group_children: [2]Widget = undefined,
    darkness_value_buf: [16]u8 = undefined,
    /// Chrome geometry and tint share one card.
    chrome_group_children: [4]Widget = undefined,
    tabs_children: [3]Widget = undefined,
    tabs_built: bool = false,
    tabs_scroll: @import("ui").layout.ScrollState = .{},
    inactive_opacity_header_children: [2]Widget = undefined,
    inactive_opacity_group_children: [2]Widget = undefined,
    inactive_opacity_value_buf: [16]u8 = undefined,
    terminal_opacity_header_children: [2]Widget = undefined,
    terminal_opacity_group_children: [2]Widget = undefined,
    terminal_opacity_value_buf: [16]u8 = undefined,
    px: [22]PxControl = undefined,
    taskbar_section_children: [13]Widget = undefined,
    taskbar_position_children: [2]Widget = undefined,
    clock_bold_children: [2]Widget = undefined,
    clock_italic_children: [2]Widget = undefined,
    items_children: [6]Widget = undefined,
    /// Per section: its title and the well that holds its rows.
    items_section_children: [3][2]Widget = undefined,
    /// What an empty well shows instead of rows.
    items_placeholder: [3][1]Widget = undefined,
    /// Spacer, text, spacer: centred, since a lone text in a row is flexed.
    items_placeholder_body: [3][3]Widget = undefined,
    /// Rows follow `order`; `syncItems` hands each well its run of them.
    item_rows: [taskbar_items.count]Widget = undefined,
    /// Grip, label, visibility toggle.
    item_controls: [taskbar_items.count][3]Widget = undefined,
    item_drag: ?struct { index: usize, press_y: f32, moved: bool = false, items: taskbar_items.Config } = null,
    item_focus: ?taskbar_items.Item = null,
    start_menu_section_children: [9]Widget = undefined,
    start_size_children: [2]Widget = undefined,
    start_logo_children: [2]Widget = undefined,
    start_logo_body: [2]Widget = undefined,
    start_logo_tile: [1]Widget = undefined,
    start_logo_info: [2]Widget = undefined,
    start_logo_buttons: [2]Widget = undefined,
    start_logo_error: ?[]const u8 = null,
    /// The preview is waiting on the icon service; `iconsReady` rebuilds.
    start_logo_pending: bool = false,
};

/// Slider ranges for the start menu's size. They only bound what the sliders
/// offer: `StartMenu.relayout` caps both to the output and floors them at
/// 320 x 240, which a hand-edited theme can still reach but leaves one row.
/// Until a slider is moved the theme holds 0 and the menu is sized to the
/// output (`start_menu/size.zig`); the sliders show that size.
pub const menu_width_min = menu_size.min_width;
pub const menu_width_max: f32 = 900;
pub const menu_height_min = menu_size.min_height;
pub const menu_height_max: f32 = 900;
pub const start_logo_tile_size: f32 = 56;

pub const StartLogo = struct {
    image: layout.ImageData,
    /// Logical size the image is drawn at.
    size: i32,
    /// A chosen file failed to load, so `image` is the bundled logo.
    failed: bool,
};

/// The logo the taskbar is showing: the chosen file, else the bundled R (also
/// when the file cannot be loaded), with the bundled one tinted the way
/// `Taskbar.paintPartPixel` tints it. Mirrors `Taskbar.refreshStartLogo`.
/// Pixels are copied into `a`, so nothing is pinned in the icon service.
pub fn startLogoImage(out: *Section, a: std.mem.Allocator, logical: i32) StartLogo {
    const server = out.cc.server;
    const custom = theme.global.start_button_icon;
    const size_px = geometry.devicePixels(logical, out.cc.toplevel.render_scale);
    var result: StartLogo = .{ .image = .{ .fallback_icon = null }, .size = logical, .failed = false };
    out.start_logo_pending = false;

    var lookup = server.iconLookup(if (custom.len > 0) custom else start_button.builtin_logo, size_px);
    if (lookup == .missing and custom.len > 0) {
        result.failed = true;
        lookup = server.iconLookup(start_button.builtin_logo, size_px);
    }
    const entry = switch (lookup) {
        .ready => |e| e,
        .pending => {
            out.start_logo_pending = true;
            return result;
        },
        .missing => return result,
    };
    const pixels = a.dupe(u32, entry.pixels) catch return result;
    if (custom.len == 0) {
        if (theme.taskbar(.start_button_logo_color)) |tint| {
            for (pixels) |*pixel| {
                var c = col.Straight.fromRgba(tint);
                c.a *= @as(f32, @floatFromInt(pixel.* >> 24)) / 255.0;
                pixel.* = c.argb();
            }
        }
    }
    result.image = .{ .pixels = pixels, .width = entry.size, .height = entry.size, .fallback_icon = null };
    return result;
}

/// A decode finished: a preview that was waiting for one can now show it.
pub fn iconsReady(s: *Section) void {
    if ((s.start_logo_pending or s.theme_preview_pending) and s.cc.page == .appearance) s.cc.refresh();
}

pub fn indexOfNearest(values: []const f32, v: f32) usize {
    var best: usize = 0;
    var best_d = @abs(values[0] - v);
    for (values, 0..) |candidate, i| {
        const d = @abs(candidate - v);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

pub fn labelWidget(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = theme.global.app_text_size, .weight = 600, .color = t.fg } } };
}

pub fn valueWidget(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = theme.global.app_text_size, .color = t.dim } } };
}

/// The readout beside a slider, in a rounded label.
pub fn pillWidget(content: []const u8) Widget {
    return ui_slider.valuePill(content, theme.global.app_text_size, panel.palette().dim);
}

pub fn sectionLabel(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = theme.global.app_heading_size, .weight = 700, .color = t.dim } } };
}

/// Builds one "label ... value / slider" pixel-value row and formats its
/// initial value into `out.px[idx].value_buf`.
pub fn pxGroup(out: *Section, idx: usize, label_text: []const u8, value: f32, min: f32, max: f32, step: f32, on_change: *const fn (?*anyopaque, usize, f32) void) Widget {
    return unitGroup(out, idx, label_text, value, min, max, step, on_change, "px");
}

/// `pxGroup` for a value that isn't in pixels, such as a percentage.
pub fn unitGroup(out: *Section, idx: usize, label_text: []const u8, value: f32, min: f32, max: f32, step: f32, on_change: *const fn (?*anyopaque, usize, f32) void, unit: []const u8) Widget {
    const formatted = std.fmt.bufPrint(&out.px[idx].value_buf, "{d}{s}", .{ @as(i32, @intFromFloat(@round(value))), unit }) catch "?";
    out.px[idx].header_children = .{ labelWidget(label_text), pillWidget(formatted) };
    const header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.px[idx].header_children };
    const slider: Widget = .{ .kind = .{ .slider = .{ .value = value, .min = min, .max = max, .step = step, .owner = out, .on_change = on_change } } };
    out.px[idx].group_children = .{ header, slider };
    return .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.px[idx].group_children };
}

/// Comptime-specialized `on_change` handler for `Section.px[idx]`, writing
/// straight to `theme.global.<field>`. Each (idx, field) instantiation is a
/// distinct function; the callback owner identifies the section.
/// `taskbar_geometry` picks
/// which of applyThemeChange's two taskbar-refresh paths to use: the
/// fields that resize taskbar items (taskbar_size, chip_width, chip_gap,
/// start_button_gap, start_button_icon_size) need the full relayout since
/// they can change item sizes without changing `bar.box.height`, the only
/// thing the cheap height-guarded refresh notices; the start-menu-popup
/// padding fields don't touch taskbar geometry at all.
pub fn PxHandler(comptime idx: usize, comptime field: []const u8, comptime taskbar_geometry: bool) type {
    return UnitHandler(idx, field, taskbar_geometry, "px");
}

pub fn UnitHandler(comptime idx: usize, comptime field: []const u8, comptime taskbar_geometry: bool, comptime unit: []const u8) type {
    return struct {
        pub fn changed(owner: ?*anyopaque, _: usize, value: f32) void {
            const s = section(owner);
            @field(theme.global, field) = value;
            const formatted = std.fmt.bufPrint(&s.px[idx].value_buf, "{d}" ++ unit, .{@as(i32, @intFromFloat(@round(value)))}) catch "?";
            s.px[idx].header_children[1].kind.text.content = formatted;
            s.px[idx].header_children[1].markDirty();
            applyThemeChangeImpl(section(owner), taskbar_geometry);
        }
    };
}

pub fn build(out: *Section, cc: *panel.ControlCenter) void {
    out.item_drag = null;
    out.cc = cc;
    if (out.tabs_built and out.tabs_children[2].kind == .scroll_container) out.tabs_scroll = out.tabs_children[2].kind.scroll_container;
    _ = out.arena.reset(.free_all);
    const t = theme.global;
    const server = out.cc.server;
    const arena = out.arena.allocator();

    out.presets = theme_presets.list(arena, out.cc.server.io, out.cc.server.environ, out.cc.server.config.path) catch &.{};
    var preset_labels: [][]const u8 = &.{};
    var matched_index: ?usize = null;
    if (arena.alloc([]const u8, out.presets.len)) |labels| {
        preset_labels = labels;
        for (out.presets, 0..) |preset, i| {
            preset_labels[i] = preset.name;
            if (std.mem.eql(u8, preset.id, out.cc.server.config.theme_base)) matched_index = i;
        }
    } else |_| {}
    out.theme_row_children = .{
        labelWidget(i18n.tr("Theme")),
        .{
            .name = "theme",
            .kind = .{ .select = .{
                .labels = preset_labels,
                .selected = matched_index,
                .placeholder = i18n.tr("Custom"),
                .disabled = preset_labels.len == 0,
                .owner = out,
                .on_change = &onThemePicked,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };

    // The same presets for the taskbar alone, led by a choice that follows
    // the theme above. Its tokens are compared, not the whole theme.
    var taskbar_labels: [][]const u8 = &.{};
    var taskbar_selected: ?usize = null;
    if (arena.alloc([]const u8, out.presets.len + 1)) |labels| {
        taskbar_labels = labels;
        labels[0] = i18n.tr("Same as theme");
        if (theme.taskbar_override == null) taskbar_selected = 0;
        for (out.presets, 1..) |preset, i| {
            labels[i] = preset.name;
            const chosen = theme.taskbar_override orelse continue;
            if (taskbar_selected != null) continue;
            const parsed = preset.tokens;
            if (theme.taskbarTokensEql(parsed, chosen)) taskbar_selected = i;
        }
    } else |_| {}
    out.taskbar_theme_row_children = .{
        labelWidget(i18n.tr("Taskbar theme")),
        .{
            .name = "taskbar_theme",
            .kind = .{ .select = .{
                .labels = taskbar_labels,
                .selected = taskbar_selected,
                .placeholder = i18n.tr("Custom"),
                .disabled = taskbar_labels.len == 0,
                .owner = out,
                .on_change = &onTaskbarThemePicked,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };

    buildWallpaper(out, arena);

    const pal = panel.palette();
    out.app_colors_buttons = .{
        .{ .name = "apply_gtk_colors", .kind = .{ .button = .{ .label = i18n.tr("Apply GTK colors"), .owner = out, .id = 0, .on_click = &onApplyAppColors, .state = if (out.app_colors_job != null) .disabled else .idle } }, .width = .{ .flex = 1 }, .height = .{ .fixed = 32 } },
        .{ .name = "apply_qt_colors", .kind = .{ .button = .{ .label = i18n.tr("Apply Qt colors"), .owner = out, .id = 1, .on_click = &onApplyAppColors, .state = if (out.app_colors_job != null) .disabled else .idle } }, .width = .{ .flex = 1 }, .height = .{ .fixed = 32 } },
    };
    out.app_colors_children = .{
        labelWidget(i18n.tr("App colors")),
        .{ .kind = .container, .direction = .row, .gap = 8, .children = &out.app_colors_buttons },
        appColorsNote(out, arena, pal.dim),
    };
    const dark_mode = out.cc.server.config.compositor.dark_mode;
    out.dark_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Dark mode"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Apps and web pages"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.dark_row_children = .{
        // Flex like the other rows' text labels: an auto-width column is only
        // as wide as its measured text, which fractional scales ellipsize.
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.dark_label_children },
        .{ .name = "dark_mode", .kind = .{ .toggle = .{ .on = dark_mode, .owner = out, .on_change = &onDarkModeChanged } } },
    };

    const splash_on = out.cc.server.config.compositor.placeholder_delay_ms > 0;
    out.splash_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Show launch splash"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Brief placeholder while apps start"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.splash_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.splash_label_children },
        .{ .name = "launch_splash", .kind = .{ .toggle = .{ .on = splash_on, .owner = out, .on_change = &onSplashStartupChanged } } },
    };

    const dodge_on = out.cc.server.config.compositor.dodge_file_drags;
    out.dodge_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Move file manager aside"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("While dragging a file out of it"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.dodge_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.dodge_label_children },
        .{ .name = "dodge_file_drags", .kind = .{ .toggle = .{ .on = dodge_on, .owner = out, .on_change = &onDodgeFileDragsChanged } } },
    };

    out.dim_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Dim inactive windows"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Slightly darken and mute windows that are not focused"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.dim_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.dim_label_children },
        .{ .name = "inactive_dim", .kind = .{ .toggle = .{ .on = out.cc.server.config.compositor.inactive_dim, .owner = out, .on_change = &onInactiveDimChanged } } },
    };

    const anim_enabled = out.cc.server.config.animations.enabled;
    out.anim_enabled_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Animations"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Window and panel transitions"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.anim_enabled_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.anim_enabled_label_children },
        .{ .name = "animations", .kind = .{ .toggle = .{ .on = anim_enabled, .owner = out, .on_change = &onAnimationsEnabledChanged } } },
    };

    const anim_speed = out.cc.server.config.animations.speed;
    out.anim_speed_row_children = .{
        labelWidget(i18n.tr("Animation speed")),
        .{
            .name = "anim_speed",
            .kind = .{ .segmented = .{ .labels = &anim_speed_labels, .selected = indexOfNearest(&anim_speed_values, anim_speed), .owner = out, .on_change = &onAnimSpeedChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    const reduced_motion = out.cc.server.config.animations.reduced_motion;
    out.reduced_motion_row_children = .{
        labelWidget(i18n.tr("Reduced motion")),
        .{
            .name = "reduced_motion",
            .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&reduced_motion_labels), .selected = indexOfReducedMotion(reduced_motion), .owner = out, .on_change = &onReducedMotionChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    const focus_zoom = out.cc.server.config.compositor.focus_zoom;
    out.focus_zoom_children = .{
        labelWidget(i18n.tr("Window switching zoom")),
        .{ .name = "focus_zoom", .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&focus_zoom_labels), .selected = @intFromEnum(focus_zoom), .owner = out, .on_change = &onFocusZoomChanged } }, .width = .{ .percent = 1 } },
        .{ .kind = .{ .text = .{ .content = focus_zoom_descriptions[@intFromEnum(focus_zoom)].get(), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };

    out.drag_feedback_children = .{
        labelWidget(i18n.tr("Drag feedback")),
        .{ .name = "drag_feedback", .kind = .{ .toggle = .{ .on = out.cc.server.config.compositor.drag_feedback, .owner = out, .on_change = &onDragFeedbackChanged } } },
    };
    const drag_scale = out.cc.server.config.compositor.drag_scale;
    const drag_formatted = std.fmt.bufPrint(&out.drag_scale_value_buf, "{d:.3}×", .{drag_scale}) catch "?";
    out.drag_scale_header_children = .{ labelWidget(i18n.tr("Drag lift scale")), pillWidget(drag_formatted) };
    out.drag_scale_children = .{
        .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.drag_scale_header_children },
        .{ .name = "drag_scale", .kind = .{ .slider = .{
            .value = drag_scale,
            .min = loader.drag_scale_min,
            .max = loader.drag_scale_max,
            .step = 0.001,
            .owner = out,
            .on_change = &onDragScaleChanged,
        } } },
    };

    if (out.font_families == null) {
        out.font_families = @import("ui").font_fallback.listFamilies(out.font_arena.allocator()) catch null;
    }
    const families = out.font_families orelse &.{};
    var family_index: ?usize = null;
    for (families, 0..) |family, i| {
        if (std.ascii.eqlIgnoreCase(family, t.font)) {
            family_index = i;
            break;
        }
    }
    out.family_row_children = .{
        labelWidget(i18n.tr("UI font")),
        .{
            .name = "font",
            .kind = .{ .select = .{
                .labels = families,
                .selected = family_index,
                .placeholder = arena.dupe(u8, t.font) catch i18n.tr("Current font"),
                .disabled = families.len == 0,
                .owner = out,
                .on_change = &onFontFamilyChanged,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };
    if (out.cursor_themes == null) {
        out.cursor_themes = cursor_theme.list(out.font_arena.allocator(), out.cc.server.io) catch null;
    }
    const cursor_themes = out.cursor_themes orelse &.{};
    var cursor_labels: [][]const u8 = &.{};
    if (arena.alloc([]const u8, cursor_themes.len)) |labels| {
        for (cursor_themes, labels) |ct, *l| l.* = ct.label;
        cursor_labels = labels;
    } else |_| {}
    const active_cursor = out.cc.server.input.cursorThemeName();
    out.cursor_row_children = .{
        labelWidget(i18n.tr("Cursor theme")),
        .{
            .name = "cursor_theme",
            .kind = .{ .select = .{
                .labels = cursor_labels,
                .selected = cursor_theme.indexOf(cursor_themes, active_cursor),
                .placeholder = arena.dupe(u8, active_cursor) catch i18n.tr("Current theme"),
                .disabled = cursor_labels.len == 0,
                .owner = out,
                .on_change = &onCursorThemePicked,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };
    out.font_row_children = .{
        labelWidget(i18n.tr("Font size")),
        .{
            .name = "font_size",
            .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&font_labels), .selected = indexOfNearest(&font_values, t.font_size), .owner = out, .on_change = &onFontSizeChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };
    out.radius_row_children = .{
        labelWidget(i18n.tr("Radius")),
        .{
            .name = "radius",
            .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&radius_labels), .selected = if (theme.radiusPreset(t)) |preset| @intFromEnum(preset) else radius_labels.len, .owner = out, .on_change = &onRadiusChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };
    out.shadow_row_children = .{
        labelWidget(i18n.tr("Shadow")),
        .{
            .name = "shadow",
            .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&shadow_labels), .selected = indexOfNearest(&shadow_size_values, t.shadow_size), .owner = out, .on_change = &onShadowChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    out.glow_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Edge glow"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Light the active window's edge near the pointer"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.glow_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.glow_label_children },
        .{ .name = "border_glow", .kind = .{ .toggle = .{ .on = t.border_glow_enabled, .owner = out, .on_change = &onBorderGlowChanged } } },
    };

    const opacity_val = std.math.clamp(t.window_bg[3], 0.0, 1.0);
    const opacity_formatted = std.fmt.bufPrint(&out.opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(opacity_val * 100.0)))}) catch "?";
    out.opacity_header_children = .{ labelWidget(i18n.tr("Window chrome opacity")), pillWidget(opacity_formatted) };
    const opacity_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.opacity_header_children };
    const opacity_slider: Widget = .{
        .name = "chrome_opacity",
        .kind = .{ .slider = .{
            .value = opacity_val,
            .min = 0.0,
            .max = 1.0,
            .step = 0.01,
            .owner = out,
            .on_change = &onChromeOpacityChanged,
        } },
    };
    out.opacity_group_children = .{ opacity_header, opacity_slider };
    const opacity_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.opacity_group_children };

    const darkness_val = theme.chromeDarkness(t.window_bg);
    const darkness_formatted = std.fmt.bufPrint(&out.darkness_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(darkness_val * 100.0)))}) catch "?";
    out.darkness_header_children = .{ labelWidget(i18n.tr("Window chrome darkness")), pillWidget(darkness_formatted) };
    const darkness_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.darkness_header_children };
    const darkness_slider: Widget = .{
        .name = "chrome_darkness",
        .kind = .{ .slider = .{
            .value = darkness_val,
            .min = 0.0,
            .max = 1.0,
            .step = 0.01,
            .owner = out,
            .on_change = &onChromeDarknessChanged,
        } },
    };
    out.darkness_group_children = .{ darkness_header, darkness_slider };
    const darkness_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.darkness_group_children };
    const chrome_height_row = pxGroup(out, px_chrome_height, i18n.tr("Window chrome height"), t.chrome_height, 28, 84, 1, &PxHandler(px_chrome_height, "chrome_height", false).changed);
    out.px[px_chrome_height].group_children[1].name = "chrome_height";
    const chrome_gap_row = pxGroup(out, px_chrome_control_gap, i18n.tr("Window control gap"), t.chrome_control_gap, 0, 24, 1, &PxHandler(px_chrome_control_gap, "chrome_control_gap", false).changed);
    out.px[px_chrome_control_gap].group_children[1].name = "chrome_control_gap";
    out.chrome_group_children = .{ chrome_height_row, chrome_gap_row, opacity_row, darkness_row };
    const chrome_row: Widget = .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.chrome_group_children };

    const inactive_val = std.math.clamp(out.cc.server.config.compositor.inactive_opacity, 0.0, 1.0);
    const inactive_formatted = std.fmt.bufPrint(&out.inactive_opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(inactive_val * 100.0)))}) catch "?";
    out.inactive_opacity_header_children = .{ labelWidget(i18n.tr("Inactive window opacity")), pillWidget(inactive_formatted) };
    const inactive_opacity_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.inactive_opacity_header_children };
    const inactive_opacity_slider: Widget = .{
        .name = "inactive_opacity",
        .kind = .{ .slider = .{
            .value = inactive_val,
            .min = 0.0,
            .max = 1.0,
            .step = 0.01,
            .owner = out,
            .on_change = &onInactiveOpacityChanged,
        } },
    };
    out.inactive_opacity_group_children = .{ inactive_opacity_header, inactive_opacity_slider };
    const inactive_opacity_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.inactive_opacity_group_children };

    // Unset means a terminal keeps its own alpha; the slider then shows opaque.
    const terminal_val = std.math.clamp(out.cc.server.config.compositor.terminal_opacity orelse 1.0, 0.0, 1.0);
    const terminal_formatted = std.fmt.bufPrint(&out.terminal_opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(terminal_val * 100.0)))}) catch "?";
    out.terminal_opacity_header_children = .{ labelWidget(i18n.tr("Terminal opacity (new windows)")), pillWidget(terminal_formatted) };
    const terminal_opacity_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.terminal_opacity_header_children };
    const terminal_opacity_slider: Widget = .{
        .name = "terminal_opacity",
        .kind = .{ .slider = .{
            .value = terminal_val,
            .min = 0.0,
            .max = 1.0,
            .step = 0.01,
            .owner = out,
            .on_change = &onTerminalOpacityChanged,
        } },
    };
    out.terminal_opacity_group_children = .{ terminal_opacity_header, terminal_opacity_slider };
    const terminal_opacity_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.terminal_opacity_group_children };

    const gap_val: f32 = @floatFromInt(@min(out.cc.server.config.compositor.windowGap(), max_window_gap));
    const window_gap_row = pxGroup(out, px_window_gap, i18n.tr("Snapped window gap"), gap_val, 0, max_window_gap, 1, &onWindowGapChanged);

    out.taskbar_position_children = .{
        labelWidget(i18n.tr("Taskbar position")),
        .{ .name = "taskbar_position", .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Top"), i18n.msg("Bottom") }), .selected = @intFromEnum(out.cc.server.config.compositor.taskbar_position), .owner = out, .on_change = &onTaskbarPositionChanged } }, .width = .{ .fixed = segmented_width } },
    };
    const position_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.taskbar_position_children };
    const taskbar_min: f32 = @floatFromInt(Taskbar.min_bar_height);
    const taskbar_row = pxGroup(out, px_taskbar_size, i18n.tr("Taskbar size"), std.math.clamp(t.taskbar_size, taskbar_min, 84.0), taskbar_min, 84, 2, &PxHandler(px_taskbar_size, "taskbar_size", true).changed);
    // A floating bar: its gap from the edge, its length and its corners. At
    // 0 px, 100 % and 0 px it is the original flush, full-width, square bar.
    const edge_gap_row = pxGroup(out, px_taskbar_edge_gap, i18n.tr("Taskbar gap from edge"), std.math.clamp(t.taskbar_edge_gap, 0.0, 48.0), 0, 48, 2, &PxHandler(px_taskbar_edge_gap, "taskbar_edge_gap", true).changed);
    out.px[px_taskbar_edge_gap].group_children[1].name = "taskbar_edge_gap";
    const length_row = unitGroup(out, px_taskbar_length, i18n.tr("Taskbar length"), std.math.clamp(t.taskbar_length, 30.0, 100.0), 30, 100, 2, &UnitHandler(px_taskbar_length, "taskbar_length", true, "%").changed, "%");
    out.px[px_taskbar_length].group_children[1].name = "taskbar_length";
    const radius_row = pxGroup(out, px_taskbar_radius, i18n.tr("Taskbar corner radius"), std.math.clamp(t.taskbar_radius, 0.0, 42.0), 0, 42, 1, &PxHandler(px_taskbar_radius, "taskbar_radius", true).changed);
    out.px[px_taskbar_radius].group_children[1].name = "taskbar_radius";
    // Also sets each pill's top/bottom margin within the bar (capped) —
    // see Taskbar.chipVerticalMargin — so this one slider spaces chips on
    // every side at once instead of only widening the horizontal gap.
    const chip_width_row = pxGroup(out, px_chip_width, i18n.tr("Window item width"), t.chip_width, 64, 400, 4, &PxHandler(px_chip_width, "chip_width", true).changed);
    const chip_gap_row = pxGroup(out, px_chip_gap, i18n.tr("Window item gap"), std.math.clamp(t.chip_gap, 0.0, 24.0), 0, 24, 2, &PxHandler(px_chip_gap, "chip_gap", true).changed);
    const start_gap_row = pxGroup(out, px_start_button_gap, i18n.tr("Start button gap"), std.math.clamp(t.start_button_gap, 0.0, 40.0), 0, 40, 2, &PxHandler(px_start_button_gap, "start_button_gap", true).changed);
    const start_icon_row = pxGroup(out, px_start_icon_size, i18n.tr("Start button icon size"), std.math.clamp(t.start_button_icon_size, 16.0, 42.0), 16, 42, 2, &PxHandler(px_start_icon_size, "start_button_icon_size", true).changed);
    out.clock_bold_children = .{
        labelWidget(i18n.tr("Bold clock text")),
        .{ .name = "clock_bold", .kind = .{ .toggle = .{ .on = theme.taskbar(.clock_bold), .owner = out, .on_change = &ClockStyle("clock_bold").changed } } },
    };
    out.clock_italic_children = .{
        labelWidget(i18n.tr("Italic clock text")),
        .{ .name = "clock_italic", .kind = .{ .toggle = .{ .on = theme.taskbar(.clock_italic), .owner = out, .on_change = &ClockStyle("clock_italic").changed } } },
    };
    const clock_bold_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.clock_bold_children };
    const clock_italic_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.clock_italic_children };
    // Each section is an inset well of raised rows; a whole row is its grip.
    inline for (0..taskbar_items.count) |i| {
        out.item_controls[i] = .{
            .{ .kind = .{ .button = .{ .label = i18n.tr("Drag to move"), .icon = .drag_handle, .variant = .ghost, .owner = out, .id = i } }, .width = .{ .fixed = 28 }, .height = .{ .fixed = 28 } },
            .{ .kind = .{ .text = .{ .content = "", .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } }, .width = .{ .flex = 1 } },
            .{ .kind = .{ .toggle = .{ .on = false, .owner = out, .on_change = &ItemToggle(i).changed } } },
        };
        out.item_rows[i] = .{ .kind = .{ .rect = itemRowStyle(false) }, .direction = .row, .gap = 8, .@"align" = .center, .padding = .{ .top = 6, .right = 10, .bottom = 6, .left = 6 }, .children = &out.item_controls[i] };
    }
    inline for (.{ i18n.msg("LEFT"), i18n.msg("CENTER"), i18n.msg("RIGHT") }, .{ "left", "center", "right" }, 0..) |label, name, zone| {
        out.items_placeholder_body[zone] = .{
            .{ .kind = .container, .width = .{ .flex = 1 } },
            // Slack: a fractional raster scale hints wider than the logical measure.
            .{ .kind = .{ .text = .{ .content = i18n.tr("Drag items here"), .font_size = theme.global.settings_description_size, .color = pal.dim } }, .min_width = @import("ui").measure.textNatural(i18n.tr("Drag items here"), .sans, 400, theme.global.settings_description_size).w + 6 },
            .{ .kind = .container, .width = .{ .flex = 1 } },
        };
        out.items_placeholder[zone] = .{.{ .kind = .container, .height = .{ .fixed = item_row_height }, .@"align" = .center, .children = &out.items_placeholder_body[zone] }};
        out.items_section_children[zone] = .{
            sectionLabel(label.get()),
            .{ .name = "taskbar_zone_" ++ name, .kind = .{ .rect = itemZoneStyle(false) }, .direction = .column, .gap = 6, .padding = layout.Edges.all(6), .@"align" = .stretch },
        };
    }
    _ = syncItems(out, out.cc.server.config.compositor.taskbar_items, null);
    out.items_children = .{
        labelWidget(i18n.tr("Taskbar sections")),
        .{ .kind = .{ .text = .{ .content = i18n.tr("Drag an item to reorder it or move it to another section. Switch it off to hide it. Battery appears when available."), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
        .{ .kind = .container, .direction = .column, .gap = 6, .@"align" = .stretch, .children = &out.items_section_children[0] },
        .{ .kind = .container, .direction = .column, .gap = 6, .@"align" = .stretch, .children = &out.items_section_children[1] },
        .{ .kind = .container, .direction = .column, .gap = 6, .@"align" = .stretch, .children = &out.items_section_children[2] },
        .{ .name = "taskbar_capture_notice", .kind = .{ .text = .{ .content = if (out.cc.server.config.compositor.taskbar_items.shown(.capture))
            i18n.tr("Screen capture appears while recording or sharing your screen. Keeping it enabled is recommended.")
        else
            i18n.tr("Warning: Screen capture is hidden. Recording and screen sharing can continue without a visible indicator or Stop sharing button. Hiding it is not recommended."), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    const items_group: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .@"align" = .stretch, .children = &out.items_children };
    out.taskbar_section_children = .{ panel.sectionTitle(i18n.tr("Taskbar")), position_row, taskbar_row, edge_gap_row, length_row, radius_row, chip_width_row, chip_gap_row, start_gap_row, start_icon_row, clock_bold_row, clock_italic_row, items_group };
    const taskbar_section: Widget = .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.taskbar_section_children };

    var output_box: wlr.Box = undefined;
    out.cc.server.output_layout.getBox(out.cc.wlr_output, &output_box);
    const menu_now = menu_size.wanted(t, @floatFromInt(output_box.width), @floatFromInt(output_box.height));
    const menu_pinned = t.start_menu_width > 0 or t.start_menu_max_height > 0;
    const menu_width_row = pxGroup(out, px_menu_width, i18n.tr("Menu width"), std.math.clamp(menu_now.width, menu_width_min, menu_width_max), menu_width_min, menu_width_max, 10, &PxHandler(px_menu_width, "start_menu_width", false).changed);
    out.px[px_menu_width].group_children[1].name = "start_menu_width";
    const menu_height_row = pxGroup(out, px_menu_height, i18n.tr("Menu height"), std.math.clamp(menu_now.height, menu_height_min, menu_height_max), menu_height_min, menu_height_max, 10, &PxHandler(px_menu_height, "start_menu_max_height", false).changed);
    out.px[px_menu_height].group_children[1].name = "start_menu_height";
    const menu_left_row = pxGroup(out, px_menu_left, i18n.tr("Menu left padding"), std.math.clamp(t.start_menu_left_pad, 0.0, 40.0), 0, 40, 2, &PxHandler(px_menu_left, "start_menu_left_pad", false).changed);
    const menu_bottom_row = pxGroup(out, px_menu_bottom, i18n.tr("Menu bottom padding"), std.math.clamp(t.start_menu_bottom_pad, 0.0, 40.0), 0, 40, 2, &PxHandler(px_menu_bottom, "start_menu_bottom_pad", false).changed);
    const icon_left_row = pxGroup(out, px_icon_left, i18n.tr("Icon left padding"), std.math.clamp(t.start_menu_icon_left_pad, 0.0, 32.0), 0, 32, 2, &PxHandler(px_icon_left, "start_menu_icon_left_pad", false).changed);
    const icon_bottom_row = pxGroup(out, px_icon_bottom, i18n.tr("Icon bottom padding"), std.math.clamp(t.start_menu_icon_bottom_pad, 0.0, 24.0), 0, 24, 2, &PxHandler(px_icon_bottom, "start_menu_icon_bottom_pad", false).changed);
    out.start_logo_buttons = .{
        .{ .name = "start_logo_choose", .kind = .{ .button = .{ .label = i18n.tr("Choose file…"), .owner = out, .on_click = &onChooseStartLogo, .state = if (folder_picker.running()) .disabled else .idle } }, .width = .auto, .min_width = 124, .height = .{ .fixed = 30 } },
        .{ .name = "start_logo_reset", .kind = .{ .button = .{ .label = i18n.tr("Reset to default"), .owner = out, .on_click = &onResetStartLogo, .state = if (t.start_button_icon.len == 0 or folder_picker.running()) .disabled else .idle } }, .width = .auto, .min_width = 140, .height = .{ .fixed = 30 } },
    };
    const logo = startLogoImage(out, arena, Taskbar.startIconSize());
    const logo_note: []const u8 = out.start_logo_error orelse blk: {
        if (t.start_button_icon.len == 0) break :blk i18n.tr("Default R logo · PNG or SVG");
        const name = std.fs.path.basename(t.start_button_icon);
        if (logo.failed) break :blk i18n.allocPrint(arena, i18n.tr("{name} could not be loaded · showing the default R"), .{ .name = name }) catch name;
        break :blk name;
    };
    // The logo sits on the taskbar, so it is shown on the taskbar's colour.
    var tile_bg = theme.taskbar(.taskbar_bg);
    tile_bg[3] = 1;
    out.start_logo_tile = .{.{
        .name = "start_logo_preview",
        .kind = .{ .image = logo.image },
        .width = .{ .fixed = @floatFromInt(logo.size) },
        .height = .{ .fixed = @floatFromInt(logo.size) },
    }};
    out.start_logo_info = .{
        .{ .name = "start_logo_file", .kind = .{ .text = .{ .content = logo_note, .font_size = theme.global.settings_description_size, .color = pal.dim } } },
        .{ .kind = .container, .direction = .row, .gap = 8, .children = &out.start_logo_buttons },
    };
    out.start_logo_body = .{
        .{
            .name = "start_logo_tile",
            .kind = .{ .rect = .{ .color = tile_bg, .radius = 10, .border_width = 1, .border_color = pal.border_soft } },
            .width = .{ .fixed = start_logo_tile_size },
            .height = .{ .fixed = start_logo_tile_size },
            .justify = .center,
            .@"align" = .center,
            .children = &out.start_logo_tile,
        },
        .{ .kind = .container, .direction = .column, .gap = 8, .justify = .center, .width = .{ .flex = 1 }, .children = &out.start_logo_info },
    };
    out.start_logo_children = .{
        labelWidget(i18n.tr("Start button logo")),
        .{ .kind = .container, .direction = .row, .gap = 12, .@"align" = .center, .children = &out.start_logo_body },
    };
    const logo_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.start_logo_children };
    out.start_size_children = .{
        .{ .name = "start_menu_size_note", .kind = .{ .text = .{ .content = if (menu_pinned) i18n.tr("Custom size") else i18n.tr("Sized to fit your screen · move a slider to set your own"), .font_size = theme.global.settings_description_size, .color = pal.dim } }, .width = .{ .flex = 1 } },
        .{ .name = "start_menu_size_auto", .kind = .{ .button = .{ .label = i18n.tr("Size to screen"), .owner = out, .on_click = &onAutoMenuSize, .state = if (menu_pinned) .idle else .disabled } }, .width = .auto, .min_width = 124, .height = .{ .fixed = 30 } },
    };
    const menu_size_row: Widget = .{ .kind = .container, .direction = .row, .gap = 8, .@"align" = .center, .children = &out.start_size_children };
    out.start_menu_section_children = .{ panel.sectionTitle(i18n.tr("Start menu")), logo_row, menu_width_row, menu_height_row, menu_size_row, menu_left_row, menu_bottom_row, icon_left_row, icon_bottom_row };
    const start_menu_section: Widget = .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.start_menu_section_children };

    out.theme_actions = .{
        .{ .name = "theme_reset", .kind = .{ .button = .{ .label = i18n.tr("Reset to theme"), .owner = out, .on_click = &onResetTheme } }, .height = .{ .fixed = 32 } },
        .{ .name = "theme_install", .kind = .{ .button = .{ .label = i18n.tr("Install theme…"), .owner = out, .on_click = &onInstallTheme } }, .height = .{ .fixed = 32 } },
        .{ .name = "theme_remove", .kind = .{ .button = .{ .label = i18n.tr("Remove"), .owner = out, .on_click = &onRemoveTheme, .state = if (matched_index != null and out.presets[matched_index.?].user_installed) .idle else .disabled } }, .height = .{ .fixed = 32 } },
        .{ .name = "theme_export", .kind = .{ .button = .{ .label = i18n.tr("Save look…"), .owner = out, .on_click = &onExportTheme } }, .height = .{ .fixed = 32 } },
        .{ .name = "theme_replace", .kind = .{ .button = .{ .label = i18n.tr("Replace installed theme"), .owner = out, .on_click = &onReplaceTheme, .state = if (out.theme_pending_path != null) .idle else .disabled } }, .height = .{ .fixed = 32 } },
    };
    var pack_preview: Widget = .{ .kind = .container };
    out.theme_preview_pending = false;
    if (server.config.theme_pack) |pack| {
        if (pack.root.len > 0) {
            if (theme_presets.asset(arena, server.io, pack.root, "preview.png")) |path| {
                const result = server.iconLookup(path, 192);
                if (result == .ready) {
                    const entry = result.ready;
                    if (arena.dupe(u32, entry.pixels)) |pixels| {
                        pack_preview = .{ .name = "theme_preview", .kind = .{ .image = .{ .pixels = pixels, .width = entry.size, .height = entry.size, .fallback_icon = null } }, .width = .{ .fixed = 160 }, .height = .{ .fixed = 100 } };
                    } else |_| {}
                } else if (result == .pending) out.theme_preview_pending = true;
            } else |_| {}
        }
    }
    const pack_controls = arena.dupe(Widget, &.{
        .{ .kind = .container, .direction = .row, .gap = 8, .children = out.theme_actions[0..4] },
        .{ .kind = .{ .text = .{ .content = if (out.theme_message.len > 0) out.theme_message else i18n.tr("Packs include colours and artwork. Personal edits are saved as overrides."), .font_size = theme.global.app_status_size, .color = pal.dim } } },
        .{ .kind = .container, .children = if (out.theme_pending_path != null) out.theme_actions[4..5] else &.{} },
        pack_preview,
    }) catch @constCast(&[_]Widget{});
    const icon_themes = @import("../../icon_theme.zig").listNames(arena, server.io, server.icon_theme_cfg) catch &.{};
    out.icon_theme_names = icon_themes;
    const icon_labels = arena.dupe([]const u8, icon_themes) catch @constCast(icon_themes);
    if (icon_labels.len > 0) icon_labels[0] = i18n.tr("System default");
    var icon_selected: ?usize = null;
    for (icon_themes, 0..) |name, i| if (std.mem.eql(u8, name, server.config.compositor.icon_theme)) {
        icon_selected = i;
    };
    out.icon_theme_row = .{
        labelWidget(i18n.tr("Icon theme")),
        .{ .name = "icon_theme", .kind = .{ .select = .{ .labels = icon_labels, .selected = icon_selected, .placeholder = i18n.tr("Pack or system default"), .owner = out, .on_change = &onIconThemePicked } }, .width = .{ .fixed = segmented_width } },
    };
    out.dock_children = .{
        labelWidget(i18n.tr("RediWM dock")),
        .{ .name = "dock_enabled", .kind = .{ .toggle = .{ .on = out.cc.server.config.compositor.dock_enabled, .owner = out, .on_change = &onDockChanged } } },
    };
    out.dock_position_children = .{
        labelWidget(i18n.tr("Dock position")),
        .{ .name = "dock_position", .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Top"), i18n.msg("Bottom"), i18n.msg("Left"), i18n.msg("Right") }), .selected = @intFromEnum(server.config.compositor.dock_position), .owner = out, .on_change = &onDockPositionChanged } }, .width = .{ .fixed = segmented_width } },
    };
    out.dock_auto_hide_children = .{
        labelWidget(i18n.tr("Auto-hide dock")),
        .{ .name = "dock_auto_hide", .kind = .{ .toggle = .{ .on = server.config.compositor.dock_auto_hide, .owner = out, .on_change = &onDockAutoHideChanged } } },
    };
    const dock_height_row = pxGroup(out, px_dock_height, i18n.tr("Dock size"), @floatFromInt(server.config.compositor.dock_height), @floatFromInt(loader.dock_height_min), @floatFromInt(loader.dock_height_max), 2, &onDockHeightChanged);
    out.px[px_dock_height].group_children[1].name = "dock_height";
    const dock_zoom_row = pxGroup(out, px_dock_hover_zoom, i18n.tr("Dock hover zoom (1.00× disables)"), server.config.compositor.dock_hover_zoom, 1, loader.dock_hover_zoom_max, 0.05, &onDockHoverZoomChanged);
    out.px[px_dock_hover_zoom].group_children[1].name = "dock_hover_zoom";
    updateDockZoomLabel(out);
    // The slider shows the opacity the dock is drawn with, whether the theme or
    // `dock_opacity` set it; the radius, whether it is the dock's own or the windows'.
    const dock_pal = theme.shellPalette();
    const dock_opacity_row = unitGroup(out, px_dock_opacity, i18n.tr("Dock opacity"), @round(dock_mod.background(&server.config.compositor, dock_pal)[3] * 100), 0, 100, 1, &onDockOpacityChanged, "%");
    out.px[px_dock_opacity].group_children[1].name = "dock_opacity";
    const dock_radius_row = pxGroup(out, px_dock_radius, i18n.tr("Dock corner radius"), std.math.clamp(dock_mod.cornerRadius(dock_pal), dock_radius_min, dock_radius_max), dock_radius_min, dock_radius_max, 1, &PxHandler(px_dock_radius, "dock_radius", false).changed);
    out.px[px_dock_radius].group_children[1].name = "dock_radius";
    out.dock_active_children = .{
        labelWidget(i18n.tr("Highlight active app")),
        .{ .name = "dock_active_highlight", .kind = .{ .toggle = .{ .on = server.config.compositor.dock_active_highlight, .owner = out, .on_change = &onDockActiveHighlightChanged } } },
    };
    out.dock_trash_children = .{
        labelWidget(i18n.tr("Show Trash")),
        .{ .name = "dock_show_trash", .kind = .{ .toggle = .{ .on = server.config.compositor.dock_show_trash, .owner = out, .on_change = &onDockShowTrashChanged } } },
    };
    out.dock_group_children = .{
        panel.sectionTitle(i18n.tr("Dock")),
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_position_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_auto_hide_children },
        dock_height_row,
        dock_zoom_row,
        dock_opacity_row,
        dock_radius_row,
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_active_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_trash_children },
    };
    out.row_storage = .{
        .{ .kind = .container, .direction = .column, .gap = 8, .children = pack_controls },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.icon_theme_row },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.theme_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.taskbar_theme_row_children },
        .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.app_colors_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dark_row_children },
        .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.wallpaper_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.splash_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dodge_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.anim_enabled_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.anim_speed_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.reduced_motion_row_children },
        .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.focus_zoom_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.drag_feedback_children },
        .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.drag_scale_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.cursor_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.family_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.font_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.radius_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.shadow_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.glow_row_children },
        chrome_row,
        buildWindowTabs(out),
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dim_row_children },
        inactive_opacity_row,
        terminal_opacity_row,
        window_gap_row,
        pxGroup(out, px_scrollbar_width, i18n.tr("Scrollbar width"), t.scrollbar_width, 4, 24, 1, &PxHandler(px_scrollbar_width, "scrollbar_width", false).changed),
        .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.dock_group_children },
        taskbar_section,
        start_menu_section,
    };
    var at: usize = 0;
    for (groups, &out.group_cards) |group, *card| {
        const start = at;
        if (group.title) |title| {
            out.group_storage[at] = panel.sectionTitle(title.get());
            at += 1;
        }
        for (group.rows) |row| {
            out.group_storage[at] = out.row_storage[@intFromEnum(row)];
            at += 1;
        }
        // An untitled group is one row that brings its own title.
        card.* = if (group.title == null) out.group_storage[start] else .{ .kind = .container, .direction = .column, .gap = 16, .children = out.group_storage[start..at] };
    }
    out.top_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("APPEARANCE"), .font_size = theme.global.app_heading_size, .weight = 700, .color = pal.dim } } },
        .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.group_cards },
    };
    out.root = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.top_children };
}

pub const strip_index = 1;

/// `row_storage`, in the order `build` fills it.
pub const Row = enum {
    theme_pack,
    icon_theme,
    theme,
    taskbar_theme,
    app_colors,
    dark_mode,
    wallpaper,
    launch_splash,
    dodge_file_drags,
    animations,
    animation_speed,
    reduced_motion,
    focus_zoom,
    drag_feedback,
    drag_scale,
    cursor,
    font_family,
    font_size,
    radius,
    shadow,
    edge_glow,
    chrome_opacity,
    window_tabs,
    inactive_dim,
    inactive_opacity,
    terminal_opacity,
    window_gap,
    scrollbar_width,
    dock,
    taskbar,
    start_menu,
};
pub const row_count = std.meta.fields(Row).len;

pub const groups = [_]struct { title: ?i18n.Message, rows: []const Row }{
    .{ .title = i18n.msg("Themes & colours"), .rows = &.{ .theme, .taskbar_theme, .theme_pack, .icon_theme, .dark_mode, .app_colors } },
    .{ .title = i18n.msg("Wallpaper"), .rows = &.{.wallpaper} },
    .{ .title = i18n.msg("Fonts & cursor"), .rows = &.{ .font_family, .font_size, .cursor } },
    .{ .title = i18n.msg("Windows"), .rows = &.{ .radius, .shadow, .edge_glow, .chrome_opacity, .window_tabs, .inactive_dim, .inactive_opacity, .terminal_opacity, .window_gap, .scrollbar_width } },
    .{ .title = i18n.msg("Motion & feedback"), .rows = &.{ .animations, .animation_speed, .reduced_motion, .focus_zoom, .drag_feedback, .drag_scale, .dodge_file_drags, .launch_splash } },
    .{ .title = null, .rows = &.{.dock} },
    .{ .title = null, .rows = &.{.taskbar} },
    .{ .title = null, .rows = &.{.start_menu} },
};

comptime {
    // Every row is shown exactly once.
    var seen = [_]bool{false} ** row_count;
    for (groups) |group| for (group.rows) |row| {
        if (seen[@intFromEnum(row)]) @compileError("row in two groups: " ++ @tagName(row));
        seen[@intFromEnum(row)] = true;
    };
    for (seen, 0..) |shown, i| if (!shown) @compileError("row in no group: " ++ @tagName(@as(Row, @enumFromInt(i))));
}
