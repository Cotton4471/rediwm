//! Server icon lookup, caching and prefetch.

const std = @import("std");
const Server = @import("../Server.zig");
const icon_service_mod = @import("../icon_service.zig");
const applications = @import("../start_menu/applications.zig");

/// Nonblocking icon lookup for titlebar/taskbar/start-menu rendering; see
/// `icon_service.zig`. `.missing` whenever the service failed to start,
/// matching how every other optional subsystem in this compositor degrades.
pub fn iconLookup(server: *Server, name: []const u8, size_px: i32) icon_service_mod.Lookup {
    const svc = server.icon_service orelse return .missing;
    // Resolve the canonical icon name: many apps advertise an app_id /
    // StartupWMClass that differs from their desktop Icon= name (e.g.
    // "brave-browser" → "brave-desktop", "dev.zed.Zed" → "zed").
    // Retain the snapshot for the duration of this call so any slice
    // borrowed from its arena stays valid until after svc.request().
    const snap = server.start_menu_catalog.retainSnapshot();
    defer snap.release();
    const icon_name = server.icon_names.resolve(snap, name);
    return svc.request(icon_name, size_px);
}

/// Returns the icon name that should be used for a given app_id / WM class.
/// Priority:
///   1. A catalog entry whose StartupWMClass= exactly matches `app_id` → use
///      that entry's Icon= name.
///   2. A catalog entry whose desktop-file ID (sans ".desktop") exactly
///      matches `app_id` → use its Icon= name.
///   3. Reverse-DNS strip: "com.example.App" → last component, tried against
///      catalog icon names.
///   4. Fall back to `app_id` unchanged.
/// The returned slice is either borrowed from `snap` arena memory or is a
/// sub-slice of `app_id`; the caller must keep `snap` retained until done.
pub fn iconNameForAppId(snap: *applications.Snapshot, app_id: []const u8) []const u8 {
    if (app_id.len == 0) return app_id;
    // The built-in settings window has no desktop entry.
    if (std.mem.eql(u8, app_id, @import("../Toplevel.zig").welcome_app_id)) return "builtin:redi-logo";
    if (std.mem.eql(u8, app_id, @import("../Toplevel.zig").settings_app_id)) return @import("ui").shell_icons.settings_icon_name;

    // Pass 1: exact StartupWMClass match → use the desktop file's Icon= name.
    for (snap.entries) |e| {
        if (e.startup_wm_class) |wmc| {
            if (std.mem.eql(u8, wmc, app_id)) {
                return e.icon orelse app_id;
            }
        }
    }

    // Pass 2: desktop-file ID (strip ".desktop" suffix) match.
    for (snap.entries) |e| {
        // e.id is the desktop file ID, e.g. "brave-browser.desktop" or
        // "dev.zed.Zed.desktop"; strip the suffix before comparing.
        const id = if (std.mem.endsWith(u8, e.id, ".desktop"))
            e.id[0 .. e.id.len - ".desktop".len]
        else
            e.id;
        if (std.mem.eql(u8, id, app_id)) {
            return e.icon orelse app_id;
        }
    }

    // Pass 3: reverse-DNS heuristic — "dev.zed.Zed" → last component "Zed".
    // Only fire when there are at least two dots (genuine reverse-DNS prefix).
    if (std.mem.lastIndexOfScalar(u8, app_id, '.')) |dot| {
        const last = app_id[dot + 1 ..];
        if (std.mem.indexOfScalar(u8, app_id[0..dot], '.') != null and last.len > 0) {
            // Try matching the last component against catalog icon names.
            for (snap.entries) |e| {
                const icon = e.icon orelse continue;
                if (std.mem.eql(u8, icon, last)) return icon;
            }
            // Return the last component so the theme lookup at least tries it
            // (e.g. "Zed" — some icon themes use that exact casing).
            return last;
        }
    }

    return app_id;
}

pub fn iconAcquire(server: *Server, id: u64) void {
    if (server.icon_service) |svc| svc.acquire(id);
}

pub fn iconRelease(server: *Server, id: u64) void {
    if (server.icon_service) |svc| svc.release(id);
}

/// Speculative scroll-ahead/initial-results prefetch (step 5); see
/// `IconService.prefetch`. Fire-and-forget, budget-gated, safe to call
/// every frame for names that may already be resolved.
pub fn iconPrefetch(server: *Server, name: []const u8, size_px: i32) void {
    if (server.icon_service) |svc| svc.prefetch(name, size_px);
}

/// Drops speculative work nothing is interested in anymore (a query/scroll
/// change); see `IconService.cancelSpeculative`.
pub fn iconCancelSpeculative(server: *Server) void {
    if (server.icon_service) |svc| svc.cancelSpeculative();
}

/// Forces every titlebar/chip/logo icon to redecode on its next repaint;
/// see `IconService.invalidateAll`. Nothing calls this automatically today
/// (no runtime icon-theme reload path exists in this compositor) — it's
/// available for a future explicit-refresh trigger.
pub fn iconInvalidateAll(server: *Server) void {
    if (server.icon_service) |svc| svc.invalidateAll();
}
