//! Appearance window tabs and dock callbacks.

const std = @import("std");
const layout = @import("ui").layout;
const Widget = layout.Widget;
const main = @import("../../main.zig");
const setting_save = @import("config").setting_save;
const loader = @import("config").loader;
const dock_mod = @import("../../Dock.zig");
const px_dock_height = @import("appearance.zig").px_dock_height;
const px_dock_hover_zoom = @import("appearance.zig").px_dock_hover_zoom;
const px_dock_opacity = @import("appearance.zig").px_dock_opacity;
const Section = @import("appearance.zig").Section;
const labelWidget = @import("appearance.zig").labelWidget;
const valueWidget = @import("appearance.zig").valueWidget;

pub fn buildWindowTabs(out: *Section) Widget {
    const list = @import("ui").widgets.checkbox_list;
    const tabs = @import("../../window_tabs.zig");
    const a = out.arena.allocator();
    var items: std.ArrayList(list.Item) = .empty;
    {
        const server = out.cc.server;
        server.window_tabs.loadKnown(server);
        for (server.config.compositor.window_tab_apps) |id| _ = server.window_tabs.remember(id);
        const snapshot = server.start_menu_catalog.retainSnapshot();
        defer snapshot.release();
        for (server.window_tabs.known.items, 0..) |id, index| {
            const app = tabs.entry(snapshot.entries, id);
            var icon: @import("ui").layout.ImageData = .{};
            switch (server.iconLookup(id, 32)) {
                .ready => |image| {
                    icon = .{ .pixels = a.dupe(u32, image.pixels) catch null, .width = image.size, .height = image.size };
                },
                else => {},
            }
            items.append(a, .{
                .id = index,
                .name = std.fmt.allocPrint(a, "window_tabs:{s}", .{id}) catch id,
                .label = a.dupe(u8, if (app) |e| e.name else id) catch id,
                .icon = icon,
                .checked = tabs.enabled(server, id),
            }) catch break;
        }
    }
    std.mem.sort(list.Item, items.items, {}, struct {
        fn less(_: void, x: list.Item, y: list.Item) bool {
            return std.ascii.lessThanIgnoreCase(x.label, y.label);
        }
    }.less);
    out.tabs_children = .{
        labelWidget("Enable window tabs for these apps"),
        valueWidget(if (items.items.len == 0) "Open an app with RediWM chrome once to list it here." else "Use + in a window’s title bar to open another window as a tab."),
        list.build(a, items.items, out, onWindowTabsChanged, out.tabs_scroll) catch .{ .kind = .container },
    };
    out.tabs_built = true;
    return .{ .name = "window_tabs", .kind = .container, .direction = .column, .gap = 8, .children = &out.tabs_children };
}

pub fn onWindowTabsChanged(owner: ?*anyopaque, index: usize, checked: bool) void {
    const server = section(owner).cc.server;
    if (index >= server.window_tabs.known.items.len) return;
    const id = server.window_tabs.known.items[index];
    var arena = std.heap.ArenaAllocator.init(main.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var enabled: std.ArrayList([]const u8) = .empty;
    for (server.config.compositor.window_tab_apps) |app| {
        if (!std.mem.eql(u8, @import("../../window_tabs.zig").identity(app), id)) enabled.append(a, app) catch return;
    }
    if (checked) enabled.append(a, id) catch return;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "window_tab_apps", @as([]const []const u8, enabled.items)) catch |err| {
        std.log.warn("could not save window tabs: {}", .{err});
        return;
    };
    const owned = server.config.arena.allocator().alloc([]const u8, enabled.items.len) catch return;
    for (enabled.items, owned) |app, *dest| dest.* = server.config.arena.allocator().dupe(u8, app) catch return;
    server.config.compositor.window_tab_apps = owned;
    server.window_tabs.reconfigure(server);
}

pub fn section(owner: ?*anyopaque) *Section {
    return @ptrCast(@alignCast(owner.?));
}

pub fn onDockChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dock_enabled", on) catch |err| {
        std.log.warn("could not save dock: {}", .{err});
        section(owner).dock_children[1].kind.toggle.on = server.config.compositor.dock_enabled;
        section(owner).dock_children[1].markDirty();
        return;
    };
    const reserved = dock_mod.reserves(&server.config.compositor);
    server.config.compositor.dock_enabled = on;
    if (reserved or dock_mod.reserves(&server.config.compositor)) server.applyTaskbarPosition();
    server.scheduleFrames();
}

pub fn onDockAutoHideChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const s = section(owner);
    const server = s.cc.server;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dock_auto_hide", on) catch |err| {
        std.log.warn("could not save dock auto-hide: {}", .{err});
        s.dock_auto_hide_children[1].kind.toggle.on = server.config.compositor.dock_auto_hide;
        s.dock_auto_hide_children[1].markDirty();
        return;
    };
    const reserved = dock_mod.reserves(&server.config.compositor);
    server.config.compositor.dock_auto_hide = on;
    // A docked dock keeps windows out of its strip; one that hides does not.
    if (reserved or dock_mod.reserves(&server.config.compositor)) server.applyTaskbarPosition();
    if (server.input.window_menu.dock != null) server.input.window_menu.close();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
    // A parked dock schedules no frame of its own.
    server.scheduleFrames();
}

/// The slider is 0-100 %. At 0 the dock is only its icons over the glass.
pub fn onDockOpacityChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const server = s.cc.server;
    const opacity = std.math.clamp(@round(value), 0, 100) / 100;
    if (server.config.compositor.dock_opacity) |current| if (current == opacity) return;
    server.config.compositor.dock_opacity = opacity;
    s.px[px_dock_opacity].header_children[1].kind.text.content = std.fmt.bufPrint(&s.px[px_dock_opacity].value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(opacity * 100)))}) catch "?";
    s.px[px_dock_opacity].header_children[1].markDirty();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
    server.scheduleFrames();
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dock_opacity", opacity) catch |err| {
        std.log.warn("could not save dock_opacity: {}", .{err});
    };
}

pub fn onDockActiveHighlightChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const s = section(owner);
    const server = s.cc.server;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dock_active_highlight", on) catch |err| {
        std.log.warn("could not save dock active highlight: {}", .{err});
        s.dock_active_children[1].kind.toggle.on = server.config.compositor.dock_active_highlight;
        s.dock_active_children[1].markDirty();
        return;
    };
    server.config.compositor.dock_active_highlight = on;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
    server.scheduleFrames();
}

pub fn onDockShowTrashChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const s = section(owner);
    const server = s.cc.server;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dock_show_trash", on) catch |err| {
        std.log.warn("could not save dock_show_trash: {}", .{err});
        s.dock_trash_children[1].kind.toggle.on = server.config.compositor.dock_show_trash;
        s.dock_trash_children[1].markDirty();
        return;
    };
    server.config.compositor.dock_show_trash = on;
    if (server.input.window_menu.dock != null) server.input.window_menu.close();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
    server.scheduleFrames();
}

pub fn onDockPositionChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index >= 4) return;
    const s = section(owner);
    const server = s.cc.server;
    const position: @TypeOf(server.config.compositor.dock_position) = @enumFromInt(index);
    if (position == server.config.compositor.dock_position) return;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dock_position", position) catch |err| {
        std.log.warn("could not save dock position: {}", .{err});
        s.dock_position_children[1].kind.segmented.selected = @intFromEnum(server.config.compositor.dock_position);
        s.dock_position_children[1].markDirty();
        return;
    };
    const reserved = dock_mod.reserves(&server.config.compositor);
    server.config.compositor.dock_position = position;
    if (reserved) server.applyTaskbarPosition();
    if (server.input.window_menu.dock != null) server.input.window_menu.close();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
    server.scheduleFrames();
}

pub fn onDockHeightChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const server = s.cc.server;
    const height: u32 = @intFromFloat(std.math.clamp(@round(value), @as(f32, @floatFromInt(loader.dock_height_min)), @as(f32, @floatFromInt(loader.dock_height_max))));
    if (height == server.config.compositor.dock_height) return;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dock_height", height) catch |err| {
        std.log.warn("could not save dock height: {}", .{err});
        s.px[px_dock_height].group_children[1].kind.slider.value = @floatFromInt(server.config.compositor.dock_height);
        s.px[px_dock_height].group_children[1].markDirty();
        return;
    };
    const reserved = dock_mod.reserves(&server.config.compositor);
    server.config.compositor.dock_height = height;
    if (reserved) server.applyTaskbarPosition();
    const formatted = std.fmt.bufPrint(&s.px[px_dock_height].value_buf, "{d}px", .{height}) catch "?";
    s.px[px_dock_height].header_children[1].kind.text.content = formatted;
    s.px[px_dock_height].header_children[1].markDirty();
    if (server.input.window_menu.dock != null) server.input.window_menu.close();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
    server.scheduleFrames();
}

pub fn updateDockZoomLabel(s: *Section) void {
    s.px[px_dock_hover_zoom].header_children[1].kind.text.content = std.fmt.bufPrint(&s.px[px_dock_hover_zoom].value_buf, "{d:.2}×", .{s.cc.server.config.compositor.dock_hover_zoom}) catch "?";
    s.px[px_dock_hover_zoom].header_children[1].markDirty();
}

pub fn onDockHoverZoomChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const server = s.cc.server;
    const zoom = std.math.clamp(@round(value * 20) / 20, 1, loader.dock_hover_zoom_max);
    if (zoom == server.config.compositor.dock_hover_zoom) return;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dock_hover_zoom", zoom) catch |err| {
        std.log.warn("could not save dock hover zoom: {}", .{err});
        s.px[px_dock_hover_zoom].group_children[1].kind.slider.value = server.config.compositor.dock_hover_zoom;
        s.px[px_dock_hover_zoom].group_children[1].markDirty();
        return;
    };
    server.config.compositor.dock_hover_zoom = zoom;
    updateDockZoomLabel(s);
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.dock.invalidate();
    server.scheduleFrames();
}
