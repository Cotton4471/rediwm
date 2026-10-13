//! Explicit pack actions share one path between Appearance and IPC.
const std = @import("std");
const Server = @import("../Server.zig");
const config = @import("config");
const main = @import("../main.zig");

pub fn apply(server: *Server, id: []const u8) !void {
    if (server.greeter_mode or server.locker != null) return error.SessionLocked;
    var arena = std.heap.ArenaAllocator.init(main.gpa);
    defer arena.deinit();
    const p = (try config.theme_pack.find(arena.allocator(), server.io, server.environ, server.config.path, id)) orelse return error.ThemeNotFound;
    if (server.config.path.len == 0) return error.NoConfigPath;
    try config.setting_save.resetThemeLayout(main.gpa, server.io, server.config.path);
    config.loader.replaceThemeOverrides(main.gpa, server.io, server.config.path, p.tokens, p.tokens, id);
    config.loader.replaceTaskbarThemeSection(main.gpa, server.io, server.config.path, p.taskbar);
    // Empty wallpaper means the pack default. Explicit later choices pin it.
    config.setting_save.saveCompositor(main.gpa, server.io, server.config.path, "wallpaper", "") catch return error.SaveFailed;
    if (p.color_scheme) |dark| config.setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dark_mode", dark) catch return error.SaveFailed;
    {
        const name = if (p.cursor_theme.len == 0) "default" else if (std.mem.eql(u8, p.cursor_theme, "pack")) try std.fmt.allocPrint(arena.allocator(), "rediwm-{s}-cursors", .{p.id}) else p.cursor_theme;
        config.setting_save.saveInput(main.gpa, server.io, server.config.path, "cursor_theme", name) catch return error.SaveFailed;
    }
    const loaded = try config.loader.load(server.config.path, main.gpa, server.io, server.environ);
    if (!std.mem.eql(u8, loaded.theme_base, id)) {
        var failed = loaded;
        failed.deinit();
        return error.SaveFailed;
    }
    @import("watcher.zig").applyLoadedConfig(server, loaded);
}

pub fn wallpaperPath(server: *Server, a: std.mem.Allocator) ![]u8 {
    if (server.config.compositor.wallpaper.len == 0) {
        if (server.config.theme_pack) |p| if (p.wallpaper.len > 0) {
            // Built-in presets have no root: their wallpaper is a bundled name.
            if (p.root.len == 0) return @import("../wallpapers.zig").resolve(a, server.io, p.wallpaper);
            const rel = try std.fs.path.join(a, &.{ "wallpapers", p.wallpaper });
            defer a.free(rel);
            if (config.theme_pack.asset(a, server.io, p.root, rel)) |path| return @constCast(path) else |_| {}
        };
    }
    return @import("../wallpapers.zig").resolve(a, server.io, server.config.compositor.wallpaper);
}

pub fn configureIcons(server: *Server) void {
    var cfg = server.icon_theme_cfg;
    cfg.generation += 1;
    cfg.override_root = if (server.config.theme_pack) |p| p.root else "";
    cfg.theme_name = if (server.config.theme_pack) |p| (if (p.icon_theme.len > 0) p.icon_theme else server.config.compositor.icon_theme) else server.config.compositor.icon_theme;
    if (cfg.theme_name.len == 0) cfg.theme_name = server.environ.getPosix("REDIWM_ICON_THEME") orelse "Adwaita";
    if (server.icon_service) |svc| {
        defer server.icon_theme_cfg = svc.cfg;
        svc.reconfigure(cfg) catch |err| {
            std.log.warn("icon theme reload: {s}", .{@errorName(err)});
            return;
        };
        server.icon_theme_cfg = svc.cfg;
        if (server.desktop) |desktop| desktop.app.worker.updateTheme(svc.cfg);
    }
}
