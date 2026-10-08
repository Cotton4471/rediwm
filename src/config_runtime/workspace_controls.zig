//! Shared Settings/IPC setters. Save before applying, so a failed write leaves
//! the live configuration unchanged.
const std = @import("std");
const Server = @import("../Server.zig");
const config = @import("config");
const gpa = @import("../main.zig").gpa;
pub fn mode(server: *Server, value: config.loader.DesktopMode, persist: bool) !void {
    if (persist) try config.setting_save.saveCompositor(gpa, server.io, server.config.path, "desktop_mode", value);
    server.config.compositor.desktop_mode = value;
    server.world.workspaces.setMode(server, value == .workspaces);
}
pub fn gap(server: *Server, value: u32, persist: bool) !void {
    if (value > 512) return error.InvalidGap;
    if (persist) try config.setting_save.saveCompositor(gpa, server.io, server.config.path, "window_gap", value);
    server.config.compositor.window_gap = value;
    server.world.workspaces.tiler.schedule(server);
    if (server.input.open_control_center) |cc| cc.refresh();
}
pub fn floatingApps(server: *Server, values: []const []const u8, persist: bool) !void {
    const a = server.config.arena.allocator();
    const owned = try a.alloc([]const u8, values.len);
    for (values, owned) |value, *dest| dest.* = try a.dupe(u8, value);
    if (persist) try config.setting_save.saveCompositor(gpa, server.io, server.config.path, "floating_apps", values);
    server.config.compositor.floating_apps = owned;
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| @import("../auto_tiling.zig").observe(top);
    server.world.workspaces.tiler.schedule(server);
    if (server.input.open_control_center) |cc| cc.refresh();
}
pub fn automatic(server: *Server, id: u8, value: bool) void {
    if (id == 0 or id > 32 or !server.world.workspaces.active) return;
    var transaction = @import("../layout_undo.zig").Transaction.begin(server, &.{id});
    defer transaction.finish();
    const slot = &server.world.workspaces.slots[id - 1];
    if (!slot.exists) {
        slot.exists = true;
        slot.output = server.getDefaultOutput();
        if (slot.output) |out| slot.box = out.usableBox();
    }
    slot.automatic = value;
    server.world.workspaces.tiler.schedule(server);
    if (server.input.open_control_center) |cc| cc.refresh();
}
