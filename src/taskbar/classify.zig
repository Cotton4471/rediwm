//! Taskbar chip classification: application kind, title and monogram.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const text = @import("ui").text;
const Toplevel = @import("../Toplevel.zig");
const AppKind = Taskbar.AppKind;

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn matchesAny(app_id: []const u8, title: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(app_id, needle) or containsIgnoreCase(title, needle)) return true;
    }
    return false;
}

// Fallback path for when icon_cache.get() finds no real XDG-theme icon for
// the client's app_id (see reconcile()): classifies by app_id/title against
// the demo suite this spec was drawn from, so there's still a themed tile
// with a recognizable glyph rather than a bare monogram in the common case.
pub fn classify(toplevel: *Toplevel) AppKind {
    const app_id = toplevel.appId();
    const title = toplevel.title();
    if (matchesAny(app_id, title, &.{ "term", "foot", "alacritty", "kitty", "konsole", "xterm" })) return .terminal;
    if (matchesAny(app_id, title, &.{ "file", "explorer", "nautilus", "files", "dolphin" })) return .file_explorer;
    if (matchesAny(app_id, title, &.{"note"})) return .notes;
    if (matchesAny(app_id, title, &.{ "setting", "config" })) return .settings;
    if (matchesAny(app_id, title, &.{ "browser", "firefox", "chrom", "web" })) return .browser;
    if (matchesAny(app_id, title, &.{ "text", "doc", "edit", "gedit", "vim", "emacs", "write" })) return .text_doc;
    return .other;
}

pub fn chipTitle(toplevel: *Toplevel) []const u8 {
    const window_title = toplevel.title();
    if (window_title.len > 0) return window_title;
    const app_id = toplevel.appId();
    if (app_id.len > 0) return app_id;
    return "";
}

pub fn monogramOf(toplevel: *Toplevel, storage: *[4]u8) []const u8 {
    const title = toplevel.title();
    const app_id = toplevel.appId();
    const source = if (title.len > 0) title else if (app_id.len > 0) app_id else "?";
    const first = source[0];
    if (first < 0x80) {
        storage[0] = std.ascii.toUpper(first);
        return storage[0..1];
    }
    var end: usize = 1;
    while (end < source.len and end < 4 and (source[end] & 0xc0) == 0x80) : (end += 1) {}
    @memcpy(storage[0..end], source[0..end]);
    return storage[0..end];
}
