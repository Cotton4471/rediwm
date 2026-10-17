//! Static setting destinations. Searching never builds pages or queries hardware.
const std = @import("std");
pub const Page = enum { general, input, displays, audio, network, appearance, shortcuts, desktop, bluetooth, region, users, printers, services };
pub const Entry = struct {
    page: Page,
    title: []const u8,
    /// Empty for a page; @ prefixes a visible heading, otherwise a widget name.
    target: []const u8 = "",
    keywords: []const u8 = "",
};
pub const entries = [_]Entry{
    .{ .page = .general, .title = "General", .target = "", .keywords = "" },
    .{ .page = .input, .title = "Input", .target = "", .keywords = "" },
    .{ .page = .displays, .title = "Displays", .target = "", .keywords = "" },
    .{ .page = .audio, .title = "Audio", .target = "", .keywords = "" },
    .{ .page = .network, .title = "Network", .target = "", .keywords = "" },
    .{ .page = .appearance, .title = "Appearance", .target = "", .keywords = "" },
    .{ .page = .shortcuts, .title = "Keyboard Shortcuts", .target = "", .keywords = "" },
    .{ .page = .desktop, .title = "Desktop", .target = "", .keywords = "" },
    .{ .page = .bluetooth, .title = "Bluetooth", .target = "", .keywords = "" },
    .{ .page = .region, .title = "Region & Language", .target = "", .keywords = "" },
    .{ .page = .users, .title = "Users", .target = "", .keywords = "" },
    .{ .page = .printers, .title = "Printers", .target = "", .keywords = "" },
    .{ .page = .services, .title = "Services", .target = "", .keywords = "" },
    .{ .page = .general, .title = "Brightness", .target = "@Brightness", .keywords = "backlight screen light" },
    .{ .page = .general, .title = "Open files with a single click", .target = "files_single_click_open", .keywords = "double click folders" },
    .{ .page = .input, .title = "Mouse speed", .target = "mouse_speed", .keywords = "pointer acceleration sensitivity" },
    .{ .page = .input, .title = "Touchpad speed", .target = "touchpad_speed", .keywords = "trackpad acceleration sensitivity" },
    .{ .page = .input, .title = "Disable touchpad while typing", .target = "touchpad_disable_while_typing", .keywords = "keyboard trackpad" },
    .{ .page = .input, .title = "Natural scroll", .target = "natural_scroll", .keywords = "scrolling direction reverse invert mouse touchpad" },
    .{ .page = .input, .title = "Tap to click", .target = "tap_to_click", .keywords = "touchpad trackpad" },
    .{ .page = .input, .title = "Canvas pan speed", .target = "pan_speed", .keywords = "desktop panning" },
    .{ .page = .input, .title = "Keyboard repeat delay", .target = "repeat_delay", .keywords = "typing keys" },
    .{ .page = .input, .title = "Keyboard repeat rate", .target = "repeat_rate", .keywords = "typing keys speed" },
    .{ .page = .displays, .title = "Monitor", .target = "monitor", .keywords = "screen output" },
    .{ .page = .displays, .title = "Display arrangement", .target = "@Arrangement", .keywords = "screen position monitors main display" },
    .{ .page = .displays, .title = "Resolution", .target = "resolution", .keywords = "screen size pixels" },
    .{ .page = .displays, .title = "Refresh rate", .target = "refresh_rate", .keywords = "screen frequency hz" },
    .{ .page = .displays, .title = "Display scale", .target = "scale", .keywords = "screen scaling dpi zoom" },
    .{ .page = .displays, .title = "Xwayland scale", .target = "xwayland_scale", .keywords = "x11 legacy apps scaling" },
    .{ .page = .displays, .title = "Rotation", .target = "transform", .keywords = "orientation portrait landscape screen" },
    .{ .page = .displays, .title = "Night light", .target = "night_light", .keywords = "blue light warm screen" },
    .{ .page = .displays, .title = "Night light temperature", .target = "night_light_temperature", .keywords = "warmth colour color" },
    .{ .page = .displays, .title = "Lid close action", .target = "lid_close", .keywords = "laptop suspend sleep" },
    .{ .page = .audio, .title = "Output volume", .target = "output_volume", .keywords = "sound speakers loudness mute" },
    .{ .page = .audio, .title = "Microphone volume", .target = "input_volume", .keywords = "sound input recording mute" },
    .{ .page = .audio, .title = "Output balance", .target = "output_balance", .keywords = "left right speakers" },
    .{ .page = .audio, .title = "Bass boost", .target = "bass_boost", .keywords = "sound equalizer low frequencies" },
    .{ .page = .audio, .title = "Treble", .target = "treble", .keywords = "sound equalizer high frequencies" },
    .{ .page = .audio, .title = "Audio output device", .target = "@Audio output", .keywords = "speakers headphones sound default" },
    .{ .page = .network, .title = "Wi-Fi", .target = "wifi_card", .keywords = "wireless internet wlan hotspot hidden network" },
    .{ .page = .network, .title = "Ethernet", .target = "ethernet_card", .keywords = "wired internet adapter" },
    .{ .page = .appearance, .title = "Wallpaper", .target = "@Wallpaper", .keywords = "background desktop image folder" },
    .{ .page = .appearance, .title = "Theme", .target = "@Theme", .keywords = "colors colours dark light preset" },
    .{ .page = .appearance, .title = "Icon theme", .target = "icon_theme", .keywords = "icons pack" },
    .{ .page = .appearance, .title = "Animations", .target = "animations", .keywords = "effects motion" },
    .{ .page = .appearance, .title = "Animation speed", .target = "anim_speed", .keywords = "motion duration" },
    .{ .page = .appearance, .title = "Reduced motion", .target = "reduced_motion", .keywords = "accessibility animations" },
    .{ .page = .appearance, .title = "Focus zoom", .target = "focus_zoom", .keywords = "window focus" },
    .{ .page = .appearance, .title = "Drag feedback", .target = "drag_feedback", .keywords = "window moving" },
    .{ .page = .appearance, .title = "Drag scale", .target = "drag_scale", .keywords = "window moving size" },
    .{ .page = .appearance, .title = "Font", .target = "font", .keywords = "typeface text" },
    .{ .page = .appearance, .title = "Cursor theme", .target = "cursor_theme", .keywords = "pointer mouse" },
    .{ .page = .appearance, .title = "Font size", .target = "font_size", .keywords = "text size accessibility" },
    .{ .page = .appearance, .title = "Corner radius", .target = "radius", .keywords = "rounded windows" },
    .{ .page = .appearance, .title = "Window shadow", .target = "shadow", .keywords = "shadows" },
    .{ .page = .appearance, .title = "Border glow", .target = "border_glow", .keywords = "window borders" },
    .{ .page = .appearance, .title = "Window opacity", .target = "chrome_opacity", .keywords = "transparency chrome" },
    .{ .page = .appearance, .title = "Window darkness", .target = "chrome_darkness", .keywords = "chrome tint" },
    .{ .page = .appearance, .title = "Titlebar height", .target = "chrome_height", .keywords = "window chrome" },
    .{ .page = .appearance, .title = "Window control spacing", .target = "chrome_control_gap", .keywords = "buttons close maximize minimize" },
    .{ .page = .appearance, .title = "Inactive window opacity", .target = "inactive_opacity", .keywords = "transparency unfocused" },
    .{ .page = .appearance, .title = "Terminal opacity", .target = "terminal_opacity", .keywords = "transparency" },
    .{ .page = .appearance, .title = "Taskbar position", .target = "taskbar_position", .keywords = "panel top bottom" },
    .{ .page = .appearance, .title = "Taskbar edge gap", .target = "taskbar_edge_gap", .keywords = "panel margin" },
    .{ .page = .appearance, .title = "Taskbar length", .target = "taskbar_length", .keywords = "panel width" },
    .{ .page = .appearance, .title = "Taskbar corner radius", .target = "taskbar_radius", .keywords = "panel rounded" },
    .{ .page = .appearance, .title = "Taskbar items", .target = "@Taskbar", .keywords = "clock battery tray notifications capture" },
    .{ .page = .appearance, .title = "Bold clock", .target = "clock_bold", .keywords = "time taskbar font" },
    .{ .page = .appearance, .title = "Italic clock", .target = "clock_italic", .keywords = "time taskbar font" },
    .{ .page = .appearance, .title = "Start menu size", .target = "start_menu_width", .keywords = "launcher width" },
    .{ .page = .appearance, .title = "Start menu height", .target = "start_menu_height", .keywords = "launcher size" },
    .{ .page = .appearance, .title = "Start menu logo", .target = "start_logo_tile", .keywords = "launcher icon image" },
    .{ .page = .appearance, .title = "Dock", .target = "dock_enabled", .keywords = "enable apps launcher" },
    .{ .page = .appearance, .title = "Dock position", .target = "dock_position", .keywords = "top bottom left right" },
    .{ .page = .appearance, .title = "Dock auto hide", .target = "dock_auto_hide", .keywords = "hide automatically" },
    .{ .page = .appearance, .title = "Dock height", .target = "dock_height", .keywords = "size" },
    .{ .page = .appearance, .title = "Dock hover zoom", .target = "dock_hover_zoom", .keywords = "magnification mouse" },
    .{ .page = .appearance, .title = "Dock opacity", .target = "dock_opacity", .keywords = "transparency" },
    .{ .page = .appearance, .title = "Dock corner radius", .target = "dock_radius", .keywords = "rounded" },
    .{ .page = .appearance, .title = "Dock active highlight", .target = "dock_active_highlight", .keywords = "running apps indicator" },
    .{ .page = .appearance, .title = "Dock trash", .target = "dock_show_trash", .keywords = "recycle bin" },
    .{ .page = .shortcuts, .title = "Keyboard shortcuts", .target = "@Keyboard Shortcuts", .keywords = "hotkeys keybindings bindings terminal screenshot volume brightness workspaces" },
    .{ .page = .desktop, .title = "Desktop mode", .target = "desktop_mode", .keywords = "canvas workspaces tiling" },
    .{ .page = .desktop, .title = "Canvas size", .target = "@Canvas Size", .keywords = "rows columns panning area" },
    .{ .page = .desktop, .title = "Desktop switching", .target = "@Desktop Switching", .keywords = "edge pan transitions" },
    .{ .page = .desktop, .title = "Mini map", .target = "mini_map_enabled", .keywords = "minimap overview" },
    .{ .page = .desktop, .title = "Mini map position", .target = "mini_map_position", .keywords = "overview location" },
    .{ .page = .desktop, .title = "Mini map hide delay", .target = "mini_map_hide_ms", .keywords = "overview timeout" },
    .{ .page = .desktop, .title = "Fixed desktop icons", .target = "desktop_icons_fixed", .keywords = "keep icons in place" },
    .{ .page = .desktop, .title = "Workspace layout", .target = "@Workspace layout", .keywords = "tiling master stack" },
    .{ .page = .desktop, .title = "Window spacing", .target = "@Window spacing", .keywords = "gaps tiling" },
    .{ .page = .desktop, .title = "Floating apps", .target = "@Floating apps", .keywords = "rules tiling windows" },
    .{ .page = .bluetooth, .title = "Bluetooth devices", .target = "@Bluetooth", .keywords = "wireless pairing paired headphones mouse keyboard" },
    .{ .page = .region, .title = "Application language", .target = "language", .keywords = "locale translation" },
    .{ .page = .region, .title = "Regional formats", .target = "formats", .keywords = "locale numbers currency dates" },
    .{ .page = .region, .title = "24-hour clock", .target = "clock_24h", .keywords = "time am pm" },
    .{ .page = .region, .title = "Clock seconds", .target = "clock_show_seconds", .keywords = "time" },
    .{ .page = .region, .title = "Clock day", .target = "clock_show_day", .keywords = "date weekday" },
    .{ .page = .region, .title = "First day of week", .target = "first_day_of_week", .keywords = "calendar monday sunday" },
    .{ .page = .users, .title = "Accounts", .target = "@Accounts", .keywords = "users login password administrator groups" },
    .{ .page = .users, .title = "Automatic login", .target = "@Automatic login", .keywords = "autologin boot" },
    .{ .page = .printers, .title = "Printers", .target = "@Printers", .keywords = "printing cups add queue jobs paper driver label" },
    .{ .page = .services, .title = "Services", .target = "services_search", .keywords = "systemd startup boot daemon unit enabled failed slow" },
    .{ .page = .general, .title = "Desktop portals", .target = "portal_default", .keywords = "backend gtk kde dialogs" },
    .{ .page = .general, .title = "File dialogs", .target = "portal_file_chooser", .keywords = "chooser portal" },
    .{ .page = .general, .title = "Default file manager", .target = "default_file_manager", .keywords = "files folders application" },
    .{ .page = .general, .title = "Default terminal", .target = "default_terminal", .keywords = "application shell console" },
    .{ .page = .appearance, .title = "Taskbar theme", .target = "taskbar_theme", .keywords = "panel colors colours" },
    .{ .page = .appearance, .title = "Dark mode", .target = "dark_mode", .keywords = "light appearance theme" },
    .{ .page = .appearance, .title = "Apply GTK colors", .target = "apply_gtk_colors", .keywords = "application colours theme" },
    .{ .page = .appearance, .title = "Apply Qt colors", .target = "apply_qt_colors", .keywords = "application colours theme" },
    .{ .page = .appearance, .title = "Launch splash", .target = "launch_splash", .keywords = "startup welcome animation" },
    .{ .page = .appearance, .title = "Dodge file drags", .target = "dodge_file_drags", .keywords = "drag drop windows" },
    .{ .page = .appearance, .title = "Dim inactive windows", .target = "inactive_dim", .keywords = "unfocused darkness" },
    .{ .page = .appearance, .title = "Window tabs", .target = "window_tabs", .keywords = "applications titlebar grouping" },
    .{ .page = .appearance, .title = "Snapped window gap", .target = "@Snapped window gap", .keywords = "spacing tiled margin" },
    .{ .page = .appearance, .title = "Scrollbar width", .target = "@Scrollbar width", .keywords = "thickness scrolling accessibility" },
    .{ .page = .appearance, .title = "Taskbar size", .target = "@Taskbar size", .keywords = "panel height" },
    .{ .page = .appearance, .title = "Window item width", .target = "@Window item width", .keywords = "taskbar chip size" },
    .{ .page = .appearance, .title = "Window item gap", .target = "@Window item gap", .keywords = "taskbar chip spacing" },
    .{ .page = .appearance, .title = "Start button gap", .target = "@Start button gap", .keywords = "taskbar launcher spacing" },
    .{ .page = .appearance, .title = "Start button icon size", .target = "@Start button icon size", .keywords = "logo launcher" },
    .{ .page = .appearance, .title = "Menu left padding", .target = "@Menu left padding", .keywords = "start menu spacing" },
    .{ .page = .appearance, .title = "Menu bottom padding", .target = "@Menu bottom padding", .keywords = "start menu spacing" },
    .{ .page = .appearance, .title = "Icon left padding", .target = "@Icon left padding", .keywords = "start menu spacing" },
    .{ .page = .appearance, .title = "Icon bottom padding", .target = "@Icon bottom padding", .keywords = "start menu spacing" },
    .{ .page = .appearance, .title = "Install theme", .target = "theme_install", .keywords = "import pack" },
    .{ .page = .appearance, .title = "Remove theme", .target = "theme_remove", .keywords = "delete pack" },
    .{ .page = .appearance, .title = "Save theme", .target = "theme_export", .keywords = "export look" },
    .{ .page = .appearance, .title = "Reset theme", .target = "theme_reset", .keywords = "defaults restore" },
};

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// All words must match, including words supplied by the page or aliases.
/// Label matches outrank aliases; longer queries remain allocation-free.
pub fn score(entry: Entry, query: []const u8, page_label: []const u8) ?u32 {
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var total: u32 = 0;
    var count: usize = 0;
    while (words.next()) |word| {
        count += 1;
        if (contains(entry.title, word)) total += 8 else if (contains(page_label, word)) total += 2 else if (contains(entry.keywords, word)) total += 1 else return null;
    }
    if (count == 0) return null;
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(entry.title, trimmed)) total += 100;
    if (entry.target.len > 0) total += 1;
    return total;
}

test "settings search ranks labels, combines words and resolves aliases" {
    const entry: Entry = .{ .page = .input, .title = "Natural scroll", .target = "natural_scroll", .keywords = "reverse direction touchpad" };
    try std.testing.expect(score(entry, "  SCROLL input  ", "Input") != null);
    try std.testing.expect(score(entry, "reverse touchpad", "Input") != null);
    try std.testing.expect(score(entry, "scroll printer", "Input") == null);
    try std.testing.expect(score(entry, "  ", "Input") == null);
    try std.testing.expect(score(entry, "natural scroll", "Input").? > score(entry, "direction", "Input").?);
    // Targets are unique within a page, apart from explicit page entries.
    for (entries, 0..) |a, i| for (entries[i + 1 ..]) |b| {
        try std.testing.expect(a.page != b.page or !std.mem.eql(u8, a.target, b.target));
    };
}
