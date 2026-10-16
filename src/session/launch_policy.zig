//! Pure launch/session environment policy, shared with poll-based app clients.
const std = @import("std");

pub const EnvView = struct {
    nested_flag: ?[]const u8 = null,
    backends: ?[]const u8 = null,
    import_flag: ?[]const u8 = null,
    config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    login_session: ?[]const u8 = null,
    primary: ?[]const u8 = null,
    host_display: ?[]const u8 = null,
};

pub fn viewFromEnviron(environ: std.process.Environ) EnvView {
    return .{
        .nested_flag = environ.getPosix("REDIWM_NESTED"),
        .backends = environ.getPosix("WLR_BACKENDS"),
        .import_flag = environ.getPosix("REDIWM_IMPORT_ACTIVATION_ENV"),
        .config_home = environ.getPosix("XDG_CONFIG_HOME"),
        .home = environ.getPosix("HOME"),
        .login_session = environ.getPosix("REDIWM_LOGIN_SESSION"),
        .primary = environ.getPosix("REDIWM_SESSION_PRIMARY"),
        .host_display = environ.getPosix("WAYLAND_DISPLAY"),
    };
}

pub fn isTruthy(text: ?[]const u8) bool {
    const value = text orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

pub fn isFalsy(text: ?[]const u8) bool {
    const value = text orelse return false;
    return std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false");
}

/// Nested Wayland, headless test backends, or an explicit REDIWM_NESTED flag.
/// A DRM login typically leaves WLR_BACKENDS unset (or "drm") — not nested.
pub fn isNested(view: EnvView) bool {
    if (isTruthy(view.nested_flag)) return true;
    const backends = view.backends orelse return view.host_display != null;
    return std.mem.indexOf(u8, backends, "wayland") != null or
        std.mem.indexOf(u8, backends, "headless") != null;
}
