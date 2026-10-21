//! Tests for the Files App: layout, hit testing, hover, scrolling and sidebar.

const std = @import("std");
const App = @import("app.zig").App;
const scrollbar = @import("ui").widgets.scrollbar;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const worker_mod = @import("worker.zig");
const history_mod = @import("history.zig");
const recent = @import("recent.zig");
const volumes_mod = @import("volumes.zig");
const icons = @import("../icon_cache.zig");
const deletion = @import("../delete_dialog.zig");
const header = @import("header.zig");
const ui_theme = @import("ui").theme;
const pins_mod = @import("pins.zig");
const column_labels = App.column_labels;
const places = App.places;
const places_start = App.places_start;
const pin_base = App.pin_base;
const MenuKind = @import("app_model.zig").MenuKind;
const FileAction = @import("app_model.zig").FileAction;
const Sort = @import("app_model.zig").Sort;
const SizeState = @import("app_model.zig").SizeState;
const ViewItem = @import("app_model.zig").ViewItem;
const nowMs = @import("app_draw.zig").nowMs;
const clipDamage = @import("app_draw.zig").clipDamage;
const measureText = @import("app_draw.zig").measureText;

test "grid hit testing respects gutters, scrolling and responsive columns" {
    var app = App{
        .allocator = std.testing.allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    app.w = 960;
    app.h = 640;
    app.list_view = false;
    app.scroll_y = 0;
    var items: [20]ViewItem = undefined;
    app.items = .{ .items = &items, .capacity = items.len };
    try std.testing.expectEqual(@as(i32, 3), app.columns());
    try std.testing.expectEqual(@as(?usize, 0), app.itemAt(250, 158));
    try std.testing.expectEqual(@as(?usize, 1), app.itemAt(490, 158));
    try std.testing.expectEqual(@as(?usize, 3), app.itemAt(250, 308));
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(220, 158));
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(450, 158));
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(250, 248));
    app.scroll_y = 156;
    try std.testing.expectEqual(@as(?usize, 3), app.itemAt(250, 158));
    app.revealIndex(19);
    try std.testing.expect(app.scroll_y > 156);
    app.resize(360, 240);
    try std.testing.expectEqual(@as(i32, 0), app.sidebarWidth());
    try std.testing.expectEqual(@as(i32, 1), app.columns());
    app.scroll_y = 0;
    try std.testing.expectEqual(@as(?usize, 0), app.itemAt(30, 180));
}

test "search and sorting preserve visible selection across snapshot rebuilds" {
    const allocator = std.testing.allocator;
    var source = [_]worker_mod.Item{
        .{ .name = "zeta.txt", .path = "/zeta.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 200, .mtime = 1, .icon_name = "" },
        .{ .name = "alpha.txt", .path = "/alpha.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 2, .icon_name = "" },
        .{ .name = "Documents", .path = "/Documents", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 3, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = "/", .items = &source };
    var app = App{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = std.heap.ArenaAllocator.init(allocator),
        .snapshot = &snap,
        .folder_sizes = std.StringHashMap(SizeState).init(allocator),
    };
    defer app.folder_sizes.deinit();
    defer app.items_arena.deinit();
    defer app.items.deinit(allocator);
    defer app.search.text.deinit(allocator);
    app.rebuildView();
    try std.testing.expectEqualStrings("Documents", app.items.items[0].name);
    app.items.items[1].selected = true;
    app.focused_index = 1;
    app.selection_anchor = 1;
    app.sort_mode = .size;
    app.rebuildView();
    try std.testing.expectEqualStrings("zeta.txt", app.items.items[1].name);
    try std.testing.expectEqual(@as(?usize, 2), app.focused_index);
    try std.testing.expect(app.items.items[2].selected);
    try app.search.text.appendSlice(allocator, "ALPHA");
    app.rebuildView();
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    try std.testing.expect(app.items.items[0].selected);
    app.folders_only = true;
    app.rebuildView();
    try std.testing.expectEqual(@as(usize, 0), app.items.items.len);
    try std.testing.expectEqual(@as(?usize, null), app.focused_index);
    app.search.text.clearRetainingCapacity();
    app.rebuildView();
    try std.testing.expectEqualStrings("Documents", app.items.items[0].name);
}

test "Unicode folder filtering and sorting retain folder size and date rules" {
    const listing = @import("app_listing.zig");
    var app: App = .{ .allocator = std.testing.allocator, .io = undefined, .environ = undefined, .theme_cfg = undefined, .worker = undefined, .history = .{ .allocator = std.testing.allocator, .current = "/" }, .home_dir = "/", .items_arena = undefined };
    defer app.search.text.deinit(app.allocator);
    const source: worker_mod.Item = .{ .name = "CÁMARA — Терминал", .path = "/name", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 20, .icon_name = "" };
    for ([_][]const u8{ "camara", "Cámara", "терм", "ТЕРМ" }) |query| {
        app.search.text.clearRetainingCapacity();
        try app.search.text.appendSlice(app.allocator, query);
        try std.testing.expect(app.matches(source));
    }
    var a: ViewItem = .{ .name = "z", .path = "/z", .sort_key = "a", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 20, .icon_name = "" };
    var b: ViewItem = .{ .name = "a", .path = "/a", .sort_key = "z", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 100, .mtime = 30, .icon_name = "" };
    try std.testing.expect(listing.lessThan(.name, a, b));
    try std.testing.expect(listing.lessThan(.size, a, b));
    try std.testing.expect(listing.lessThan(.modified, b, a));
    try std.testing.expect(listing.lessThan(.modified_asc, a, b));
    a.is_dir = false;
    try std.testing.expect(listing.lessThan(.name, a, b));
    try std.testing.expect(listing.lessThan(.name_desc, b, a));
    try std.testing.expect(listing.lessThan(.size, b, a));
    b.bytes = a.bytes;
    try std.testing.expect(listing.lessThan(.size, a, b));
}

test "context menu stays inside the client and keyboard activation closes it" {
    var app = App{
        .allocator = std.testing.allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    app.w = 360;
    for ([_]i32{ 240, 600 }) |height| {
        app.h = height;
        for ([_]MenuKind{ .file, .background }) |kind| {
            app.openMenu(kind, 359, @floatFromInt(height - 1));
            try std.testing.expect(app.menu_x >= 0 and app.menu_x + app.menuWidth() <= 360);
            try std.testing.expect(app.menu_y >= 0 and app.menu_y + app.menuHeight() <= @as(f64, @floatFromInt(height)));
            try std.testing.expectEqual(@as(?usize, null), app.menuHit(app.menu_x - 1, app.menu_y + 10));
            for (0..app.menuLabels().len) |i| {
                const row = app.menuRowRect(i);
                try std.testing.expectEqual(@as(?usize, i), app.menuHit(row.x + 20, row.y + row.h / 2));
                if (app.menuSeparatorBefore(i)) {
                    try std.testing.expectEqual(@as(?usize, null), app.menuHit(row.x + 20, row.y - 5));
                }
            }
        }
    }
    app.dialog = null;
    app.handleKey(c.XKB_KEY_Down, "");
    try std.testing.expectEqual(@as(usize, 1), app.menu_selected);
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expectEqual(@as(?MenuKind, null), app.menu);
}

fn testApp() !App {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = undefined,
        .theme_cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .worker = undefined,
        .history = try history_mod.History.init(std.testing.allocator, "/tmp"),
        .home_dir = "/tmp",
        .items_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .folder_sizes = std.StringHashMap(SizeState).init(std.testing.allocator),
    };
}

fn testItems(app: *App, count: usize) !void {
    for (0..count) |i| {
        const name = try std.fmt.allocPrint(app.items_arena.allocator(), "file-{d}.txt", .{i});
        try app.items.append(app.allocator, .{ .name = name, .path = name, .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = @intCast(i), .mtime = @intCast(i), .icon_name = "" });
    }
}

test "terminal drawer shares viewport geometry and preserves its preferred height" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 60);
    app.terminal.visible = true;
    app.terminal.requested_height = 220;
    app.terminal.pixels = 220;
    const bottom = app.contentBottom();
    try std.testing.expectEqual(app.h - app.footerHeight() - 220, bottom);
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(260, @floatFromInt(bottom + 1)));
    try std.testing.expect(app.overTerminalDivider(300, @floatFromInt(bottom)));
    try std.testing.expectEqualStrings("row-resize", std.mem.span(app.pointerCursor(300, @floatFromInt(bottom))));
    app.list_view = true;
    app.column_widths = .{ 1000, 120, 120, 160, 180 };
    try std.testing.expectEqual(bottom - app.scrollbarGutter(), app.contentBottom());
    try std.testing.expectEqual(@as(f32, @floatFromInt(app.contentBottom())), app.horizontalScrollbar().?.track.y);
    app.resize(360, 240);
    try std.testing.expectEqual(@as(i32, 220), app.terminal.requested_height);
    try std.testing.expect(app.terminalHeight() <= app.terminalMaximum());
    try std.testing.expectEqual(@as(i32, 0), app.terminalHeight());
    try std.testing.expectEqual(app.h - app.footerHeight() - app.scrollbarGutter(), app.contentBottom());
    app.resize(960, 540);
    try std.testing.expectEqual(@as(i32, 220), app.terminalHeight());
}

test "terminal dropped paths quote shell metacharacters and reject lossy paste bytes" {
    const quotePaths = @import("app_terminal.zig").quotePaths;
    const allocator = std.testing.allocator;
    const quoted = try quotePaths(allocator, &.{ "/tmp/a space's 雪", "/tmp/\"$()`;\\" });
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("'/tmp/a space'\\''s 雪' '/tmp/\"$()`;\\' ", quoted);
    for ([_][]const u8{ "/tmp/new\nline", "/tmp/carriage\rreturn", "/tmp/tab\t", "/tmp/escape\x1b", "/tmp/delete\x7f" }) |path| {
        try std.testing.expectError(error.ControlCharacter, quotePaths(allocator, &.{ "/tmp/valid", path }));
    }
    try std.testing.expectError(error.InvalidPath, quotePaths(allocator, &.{"relative"}));
    const huge = try allocator.alloc(u8, @import("transfer.zig").limit);
    defer allocator.free(huge);
    @memset(huge, '\'');
    huge[0] = '/';
    try std.testing.expectError(error.TooLong, quotePaths(allocator, &.{huge}));
}

test "terminal keys, modal priority and chooser isolation" {
    const tc = @import("terminal/model.zig").c;
    var app = try testApp();
    defer app.deinit();
    app.terminal.session = tc.ft_new(4, 20) orelse return error.OutOfMemory;
    app.terminal.visible = true;
    app.focus = .terminal;
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_c, "\x03");
    var bytes: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\x03", bytes[0..tc.ft_take_output(app.terminal.session.?, &bytes, bytes.len)]);
    app.handleKey(c.XKB_KEY_l, "\x0c");
    try std.testing.expect(app.focus == .terminal);
    const sample = "copy";
    tc.ft_feed(app.terminal.session.?, sample, sample.len);
    app.terminal.selection = .{ .anchor = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 4 } };
    app.handleKey(c.XKB_KEY_Control_L, "");
    app.shift = true;
    app.handleKey(c.XKB_KEY_Shift_L, "");
    app.handleKey(c.XKB_KEY_C, "\x03");
    try std.testing.expectEqualStrings("copy", app.clipboard_text.items);
    app.ctrl = false;
    app.shift = false;
    try std.testing.expect(!app.keyRepeats(c.XKB_KEY_F4, ""));
    app.dialog = .{ .kind = .terminal_close, .title = "Close terminal?" };
    app.handleKey(c.XKB_KEY_F4, "");
    try std.testing.expect(app.terminal.visible);
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expect(app.focus == .terminal);
    app.handleKey(c.XKB_KEY_F4, "");
    try std.testing.expect(!app.terminal.visible);
    try std.testing.expect(app.focus == .file_view);
    app.chooser = .{ .mode = .open };
    app.handleKey(c.XKB_KEY_F4, "");
    try std.testing.expect(!app.terminal.visible);
    try std.testing.expectEqual(@as(?usize, null), app.terminalHit(940, 525));
}

test "address search and dialog share selection editing without file shortcuts" {
    var app = try testApp();
    defer app.deinit();
    try app.location.set(app.allocator, "/tmp/été");
    app.focus = .location_bar;
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_a, "a");
    app.handleKey(c.XKB_KEY_c, "c");
    try std.testing.expectEqualStrings("/tmp/été", app.clipboard_text.items);
    try std.testing.expect(app.clipboard_is_text);
    app.handleKey(c.XKB_KEY_x, "x");
    try std.testing.expectEqualStrings("", app.location.text.items);
    app.pasteText("/tmp/雪");
    app.ctrl = false;
    app.shift = true;
    app.handleKey(c.XKB_KEY_Left, "");
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_x, "x");
    try std.testing.expectEqualStrings("雪", app.clipboard_text.items);
    try std.testing.expectEqualStrings("/tmp/", app.location.text.items);
    app.handleKey(c.XKB_KEY_v, "v");
    try std.testing.expect(app.text_paste_requested and !app.paste_requested);
    app.ctrl = false;
    app.shift = false;
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expectEqualStrings("/tmp", app.location.text.items);
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_f, "f");
    app.pasteText("query");
    app.handleKey(c.XKB_KEY_a, "a");
    app.handleKey(c.XKB_KEY_c, "c");
    try std.testing.expectEqualStrings("query", app.clipboard_text.items);
    app.openNewFileDialog();
    app.handleKey(c.XKB_KEY_a, "a");
    app.pasteText("filename.txt");
    app.handleKey(c.XKB_KEY_c, "c"); // no selection: leave clipboard alone
    try std.testing.expectEqualStrings("query", app.clipboard_text.items);
    try std.testing.expectEqualStrings("filename.txt", app.dialog.?.edit.text.items);
}

test "pointer caret selection and long-path scrolling at both raster scales" {
    var app = try testApp();
    defer app.deinit();
    app.w = 360;
    app.h = 240;
    try app.location.set(app.allocator, "/tmp/abcdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz/雪");
    app.focus = .location_bar;
    for ([_]i32{ 1, 2 }) |scale| {
        app.scale = scale;
        const surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 720, 480).?;
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf).?;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(scale), @floatFromInt(scale));
        app.renderEditor(cr, &app.location, header.field(app.w), true, false);
        try std.testing.expect(app.location.scroll > 0);
        app.location.scroll = 0;
        app.placeCaret(App.textArea(header.field(app.w), false).x, false);
        try std.testing.expectEqual(@as(usize, 0), app.location.cursor);
        const pen = measureText(cr, "/tmp/", App.fieldFontSize(), false);
        app.placeCaret(App.textArea(header.field(app.w), false).x + pen, true);
        const sel = app.location.selection();
        try std.testing.expectEqualStrings("/tmp/", app.location.text.items[sel[0]..sel[1]]);
        app.location.move(app.location.text.items.len, false);
    }
}

test "keyboard ranges and focus-only movement in grid and list" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 60);
    for ([_]bool{ false, true }) |list| {
        app.list_view = list;
        app.ctrl = false;
        app.shift = false;
        app.handleKey(c.XKB_KEY_Home, "");
        app.shift = true;
        app.handleKey(c.XKB_KEY_Right, "");
        app.handleKey(c.XKB_KEY_Right, "");
        try std.testing.expect(app.items.items[0].selected and app.items.items[1].selected and app.items.items[2].selected);
        app.handleKey(c.XKB_KEY_Left, "");
        try std.testing.expect(!app.items.items[2].selected);
        app.shift = false;
        app.ctrl = true;
        app.handleKey(c.XKB_KEY_End, "");
        try std.testing.expectEqual(@as(?usize, 59), app.focused_index);
        try std.testing.expect(app.items.items[0].selected and !app.items.items[59].selected);
        app.ctrl = false;
        app.shift = true;
        app.handleKey(c.XKB_KEY_Page_Up, "");
        try std.testing.expectEqual(@as(?usize, 0), app.selection_anchor);
        try std.testing.expect(app.items.items[0].selected);
    }
}

test "history restores names and scroll while tolerating removed items" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 80);
    app.loading = false;
    app.scroll_y = 200;
    app.items.items[12].selected = true;
    app.items.items[13].selected = true;
    app.focused_index = 13;
    app.selection_anchor = 12;
    app.rememberView();
    try app.history.navigate("/elsewhere");
    _ = try app.history.back();
    _ = app.items.orderedRemove(13);
    for (app.items.items) |*item| item.selected = false;
    app.focused_index = null;
    app.selection_anchor = null;
    app.scroll_y = 0;
    app.restoreView();
    try std.testing.expectEqual(@as(i32, 200), app.scroll_y);
    try std.testing.expect(app.items.items[12].selected);
    try std.testing.expectEqual(@as(?usize, null), app.focused_index);
    try std.testing.expectEqual(@as(?usize, 12), app.selection_anchor);
}

test "retained hover repairs match complete Cairo rasters at scale 1 and 1.5" {
    const saved_theme = ui_theme.global;
    defer ui_theme.global = saved_theme;
    // Exercise the illuminated selected row and rounder highlights, too.
    ui_theme.global.app_sidebar_selected_marker = .{ 1, 0.95, 0.84, 1 };
    ui_theme.global.app_sidebar_item_radius = 10;
    ui_theme.global.app_sidebar[3] = 0.5;
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    try testItems(&app, 12);
    for ([_]bool{ false, true }) |list| {
        app.list_view = list;
        for ([_]f64{ 1, 1.5 }) |scale| {
            const w: i32 = @intFromFloat(@as(f64, @floatFromInt(app.w)) * scale);
            const h: i32 = @intFromFloat(@as(f64, @floatFromInt(app.h)) * scale);
            const retained = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(retained);
            const reference = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(reference);
            const cr = c.cairo_create(retained).?;
            defer c.cairo_destroy(cr);
            const ref = c.cairo_create(reference).?;
            defer c.cairo_destroy(ref);
            c.cairo_scale(cr, scale, scale);
            c.cairo_scale(ref, scale, scale);
            app.stepHover(0);
            app.render(cr);
            c.cairo_surface_flush(retained);
            const sidebar_pixels: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(retained)));
            const sidebar_x: usize = @intFromFloat(2 * scale);
            const sidebar_y: usize = @intFromFloat(@as(f64, @floatFromInt(app.contentTop() + 2)) * scale);
            try std.testing.expectEqual(@as(u32, 128), sidebar_pixels[sidebar_y * @as(usize, @intCast(w)) + sidebar_x] >> 24);
            app.dirty = false;
            var points: std.ArrayList([2]f64) = .empty;
            defer points.deinit(std.testing.allocator);
            if (list) {
                for (App.column_labels, 0..) |_, i| {
                    const rect = app.listColumn(i);
                    try points.append(std.testing.allocator, .{ rect.x + rect.w / 2, rect.y + rect.h / 2 });
                }
            }
            for (std.meta.tags(header.Action)) |action| {
                const button = header.rect(app.w, false, action);
                try points.append(std.testing.allocator, .{ button.x + button.w / 2, button.y + button.h / 2 });
            }
            const field = header.field(app.w);
            try points.append(std.testing.allocator, .{ field.x + 12, field.y + 18 });
            // Items, the header, the current place, other places and outside.
            try points.appendSlice(std.testing.allocator, &.{ .{ 250, 160 }, .{ 490, 160 }, .{ 70, 140 }, .{ 70, 200 }, .{ 70, 240 }, .{ 70, 500 }, .{ 50, 80 }, .{ 250, 160 }, .{ 250, 300 }, .{ 0, 0 } });
            var clock: i64 = 1000;
            for (points.items, 0..) |point, point_index| {
                // Selection transitions must repair retained pixels just like hover.
                for (app.items.items, 0..) |*item, i| item.selected = i == point_index % app.items.items.len;
                app.invalidate(); // Selection also changes toolbar actions and status.
                if (list) app.startSortFeedback(clock);
                app.handleMotion(point[0], point[1]);
                // From the frame the pointer arrived to well after both glides settle.
                for ([_]i64{ 0, 16, 32, 64, 100, 160, 5000 }) |elapsed| {
                    app.stepHover(clock + elapsed);
                    if (app.dirty) {
                        c.cairo_save(cr);
                        if (app.paint_damage) |rect| clipDamage(cr, rect);
                        app.render(cr);
                        c.cairo_restore(cr);
                        app.dirty = false;
                    }
                    app.render(ref);
                    c.cairo_surface_flush(retained);
                    c.cairo_surface_flush(reference);
                    const len: usize = @intCast(w * h * 4);
                    const actual = c.cairo_image_surface_get_data(retained)[0..len];
                    const expected = c.cairo_image_surface_get_data(reference)[0..len];
                    if (!std.mem.eql(u8, actual, expected)) {
                        const mismatch = std.mem.indexOfDiff(u8, actual, expected).? / 4;
                        std.debug.print("hover mismatch scale={d} point={any} +{d}ms damage={any} pixel={d},{d}\n", .{ scale, point, elapsed, app.paint_damage, mismatch % @as(usize, @intCast(w)), mismatch / @as(usize, @intCast(w)) });
                        _ = c.cairo_surface_write_to_png(retained, "/tmp/files-hover-actual.png");
                        _ = c.cairo_surface_write_to_png(reference, "/tmp/files-hover-expected.png");
                        return error.TestUnexpectedResult;
                    }
                }
                clock += 6000;
            }
        }
    }
}

/// A point inside item `idx`'s card, wherever the layout put it.
fn pointOnItem(app: *App, idx: usize) [2]f64 {
    const per_row: usize = @intCast(app.columns());
    const box = app.itemHighlight(.{ .col = @floatFromInt(idx % per_row), .row = @floatFromInt(idx / per_row), .alpha = 1 });
    return .{ box.x + 10, box.y + 10 };
}

test "item hover glides between cells and rests without repaints or wakeups" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    try testItems(&app, 12);
    app.dirty = false;

    // Nothing under the pointer: no highlight, no frame clock.
    app.stepHover(1000);
    try std.testing.expect(!app.hover_active and !app.dirty);

    // It fades in where the pointer landed.
    const first = pointOnItem(&app, 0);
    app.handleMotion(first[0], first[1]);
    app.dirty = false;
    app.stepHover(1000);
    try std.testing.expect(app.hover_active);
    app.stepHover(1050);
    try std.testing.expect(app.dirty and app.paint_damage != null);
    try std.testing.expect(app.item_hover.frame.alpha > 0 and app.item_hover.frame.alpha < 1);
    const card = app.itemHighlight(app.item_hover.frame);
    try std.testing.expect(app.paint_damage.?.contains(card.x + 1, card.y + 1) and app.paint_damage.?.contains(card.x + card.w - 2, card.y + card.h - 2));
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 1), app.item_hover.frame.alpha);
    try std.testing.expect(!app.hover_active);

    // At rest nothing repaints, however often it is sampled.
    app.dirty = false;
    app.stepHover(4100);
    app.stepHover(9000);
    try std.testing.expect(!app.dirty and !app.hover_active);

    // Moving to another item glides there rather than hopping.
    const per_row: usize = @intCast(app.columns());
    const to = pointOnItem(&app, 5);
    app.handleMotion(to[0], to[1]);
    app.stepHover(9100);
    app.stepHover(9150);
    const mid = app.item_hover.frame;
    const end_col: f32 = @floatFromInt(5 % per_row);
    const end_row: f32 = @floatFromInt(5 / per_row);
    try std.testing.expect(mid.col <= end_col and mid.row <= end_row);
    try std.testing.expect(mid.col > 0 or mid.row > 0);
    try std.testing.expect(mid.col < end_col or mid.row < end_row);
    try std.testing.expectEqual(@as(f32, 1), mid.alpha);
    try std.testing.expect(app.hover_active);
    app.stepHover(12000);
    try std.testing.expectEqual(end_col, app.item_hover.frame.col);
    try std.testing.expectEqual(end_row, app.item_hover.frame.row);
    try std.testing.expect(!app.hover_active);

    // A selected item paints its own fill: the highlight fades out.
    app.items.items[5].selected = true;
    app.stepHover(12100);
    app.stepHover(15000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
    try std.testing.expect(!app.hover_active);

    // Leaving the window fades whatever is showing.
    app.items.items[5].selected = false;
    app.stepHover(15100);
    app.stepHover(18000);
    try std.testing.expectEqual(@as(f32, 1), app.item_hover.frame.alpha);
    app.handleMotion(-1, -1);
    app.stepHover(18100);
    app.stepHover(18150);
    try std.testing.expect(app.item_hover.frame.alpha < 1);
    app.stepHover(21000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
    try std.testing.expect(!app.hover_active);

    // Modal UI owns the pointer.
    app.handleMotion(first[0], first[1]);
    app.menu = .background;
    app.stepHover(21100);
    app.stepHover(24000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
}

test "sidebar hover glides between places and leaves the current one to its own fill" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    app.dirty = false;
    // Home is the current place (history starts at home_dir).
    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(0))) + 10);
    app.dirty = false;
    app.stepHover(1000);
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 0), app.nav_hover.frame.alpha);
    try std.testing.expect(!app.dirty and !app.hover_active);

    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(1))) + 10);
    app.stepHover(5000);
    app.stepHover(5050);
    try std.testing.expect(app.dirty and app.paint_damage != null);
    app.stepHover(8000);
    try std.testing.expectEqual(@as(f32, 1), app.nav_hover.frame.alpha);
    try std.testing.expectEqual(@as(f32, 1), app.nav_hover.frame.row);
    var box = app.navHighlight(app.nav_hover.frame);
    try std.testing.expectEqual(app.placeRect(1).y, box.y);

    // Every pixel between adjacent entries retains a hover target, at both pitches.
    const original_height = app.h;
    for ([_]i32{ 500, 700 }) |height| {
        app.h = height;
        const first = app.placeRect(App.places_start);
        const next = app.placeRect(App.places_start + 1);
        try std.testing.expectEqual(first.y + first.h, next.y);
        var y = first.y;
        while (y < next.y + next.h) : (y += 1) {
            app.mouse_y = y;
            try std.testing.expect(app.hoveredPlace() != null);
        }
    }
    app.h = original_height;

    // Three places down: partway, the highlight sits between the two rows.
    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(4))) + 10);
    app.stepHover(8100);
    app.stepHover(8150);
    const mid = app.nav_hover.frame;
    try std.testing.expect(mid.row > 1 and mid.row < 4);
    box = app.navHighlight(mid);
    try std.testing.expect(box.y > @as(f64, @floatFromInt(app.placeY(1))) and box.y < @as(f64, @floatFromInt(app.placeY(4))));
    try std.testing.expect(app.hover_active);
    app.stepHover(11000);
    try std.testing.expectEqual(@as(f32, 4), app.nav_hover.frame.row);
    try std.testing.expect(!app.hover_active);

    // Following scroll: the highlight is a place, not a pixel row.
    app.sidebar_scroll = 20;
    box = app.navHighlight(app.nav_hover.frame);
    try std.testing.expectEqual(app.placeRect(4).y, box.y);
}

test "a grid that reflows forgets its item highlight" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    try testItems(&app, 12);
    const on = pointOnItem(&app, 3);
    app.handleMotion(on[0], on[1]);
    app.stepHover(1000);
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 1), app.item_hover.frame.alpha);

    // Column 3 of a grid is off the edge of a list: it must not slide in.
    app.list_view = true;
    app.dirty = false;
    app.stepHover(4100);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
    try std.testing.expect(app.dirty and app.paint_damage == null);
    const row = pointOnItem(&app, 3);
    app.handleMotion(row[0], row[1]);
    app.stepHover(4200);
    app.stepHover(7000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.col);
    try std.testing.expectEqual(@as(f32, 3), app.item_hover.frame.row);
}

test "hover damage covers this repaint only" {
    var app = try testApp();
    defer app.deinit();
    // Left over from the last paint: not pending.
    app.dirty = false;
    app.paint_damage = .{ .x = 0, .y = 0, .w = 900, .h = 500 };
    app.addDamage(.{ .x = 10, .y = 10, .w = 5, .h = 5 });
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(header.Rect{ .x = 10, .y = 10, .w = 5, .h = 5 }, app.paint_damage.?);
    // Pending damage accumulates.
    app.addDamage(.{ .x = 100, .y = 100, .w = 5, .h = 5 });
    try std.testing.expectEqual(header.Rect{ .x = 10, .y = 10, .w = 95, .h = 95 }, app.paint_damage.?);
    // A queued full repaint absorbs it.
    app.invalidate();
    app.addDamage(.{ .x = 10, .y = 10, .w = 5, .h = 5 });
    try std.testing.expect(app.dirty and app.paint_damage == null);
}

test "Files wheel follows the shell spring, accumulates and reverses without lag" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.handleMotion(300, 200);
    app.handleWheel(40, 1000);
    try std.testing.expectEqual(@as(i32, 0), app.scroll_y);
    app.stepWheel(1040);
    try std.testing.expect(app.scroll_y > 0 and app.scroll_y < 40);
    app.handleWheel(40, 1040);
    try std.testing.expectEqual(@as(f32, 80), app.wheel_glide.to);
    app.stepWheel(1100);
    const at = app.wheel_glide.value(1100);
    app.handleWheel(-10, 1100);
    try std.testing.expectApproxEqAbs(at - 10, app.wheel_glide.to, 0.01);
    app.stepWheel(5000);
    try std.testing.expect(!app.wheel_glide.active());
    app.handleWheel(100000, 6000);
    app.stepWheel(10000);
    try std.testing.expectEqual(app.maxScroll(), app.scroll_y);
    app.handleWheel(-40, 11000);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.wheel_glide.active());
}

test "file drag threshold preserves multi-selection and ordinary release collapses it" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 10);
    app.items.items[0].selected = true;
    app.items.items[1].selected = true;
    app.handleMotion(310, 158);
    app.handleButton(0x110, true);
    try std.testing.expect(app.items.items[1].selected);
    app.handleMotion(313, 158);
    try std.testing.expect(!app.drag_ready);
    app.handleMotion(330, 158);
    try std.testing.expect(app.drag_ready);
    app.handleButton(0x110, false);
    try std.testing.expect(app.items.items[1].selected);
    app.handleMotion(310, 158);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.items.items[1].selected);

    app.ctrl = true;
    app.last_click_index = null;
    app.handleButton(0x110, true);
    try std.testing.expect(app.items.items[0].selected);
    app.handleMotion(330, 158);
    try std.testing.expect(app.drag_ready);
    app.handleButton(0x110, false);
    try std.testing.expect(app.items.items[0].selected);
    app.handleMotion(310, 158);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.items.items[0].selected);
}

test "single-click opening targets only visible icons and cancels for selection or dragging" {
    for ([_]bool{ false, true }) |list| {
        var app = try testApp();
        defer app.deinit();
        app.list_view = list;
        try testItems(&app, 20);
        const rect = app.itemIconRect(0);
        const x = rect.x + rect.w / 2;
        const y = rect.y + rect.h / 2;
        try std.testing.expectEqualStrings("pointer", std.mem.span(app.pointerCursor(x, y)));
        try std.testing.expectEqualStrings("default", std.mem.span(app.pointerCursor(rect.x + rect.w + 8, y)));
        app.handleMotion(x, y);
        app.handleButton(0x110, true);
        try std.testing.expectEqual(@as(?usize, 0), app.open_on_release);
        app.handleMotion(x + 9, y);
        try std.testing.expect(app.drag_ready and app.open_on_release == null);
        app.handleButton(0x110, false);
        app.handleMotion(x, y);
        for (0..3) |modifier| {
            app.ctrl = modifier == 0;
            app.shift = modifier == 1;
            app.alt = modifier == 2;
            app.handleButton(0x110, true);
            try std.testing.expect(app.open_on_release == null);
            app.handleButton(0x110, false);
        }
        app.ctrl = false;
        app.shift = false;
        app.alt = false;
        app.handleButton(0x110, true);
        app.cancelDrag();
        try std.testing.expect(app.open_on_release == null);
        app.single_click_open = false;
        try std.testing.expectEqualStrings("default", std.mem.span(app.pointerCursor(x, y)));
        app.handleButton(0x110, true);
        try std.testing.expect(app.open_on_release == null);
        app.cancelDrag();
        app.single_click_open = true;
        app.scroll_y = @intFromFloat(rect.y + rect.h - app.viewTop());
        try std.testing.expect(app.singleClickIconAt(x, @floatFromInt(app.viewTop() - 1)) == null);
        if (list) {
            app.scroll_y = 0;
            app.scroll_x = 12;
            const shifted = app.itemIconRect(0);
            try std.testing.expectEqualStrings("pointer", std.mem.span(app.pointerCursor(shifted.x + 1, y)));
        }
    }
}

test "Files reduced motion scrolls immediately" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    var settings = saved;
    settings.reduced_motion = .on;
    anim.applySettings(settings);
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.handleMotion(300, 200);
    app.handleWheel(40, 1000);
    try std.testing.expectEqual(@as(i32, 40), app.scroll_y);
    try std.testing.expect(!app.wheel_glide.active());
}

test "background drag selects in grid and list with modifiers and reverse motion" {
    for ([_]bool{ false, true }) |list| {
        var app = try testApp();
        defer app.deinit();
        app.list_view = list;
        try testItems(&app, 20);
        const top: f64 = @floatFromInt(app.viewTop() + app.itemInset());
        // The left gutter is empty in both layouts.
        app.handleMotion(215, top - 5);
        app.handleButton(0x110, true);
        app.handleMotion(300, top + 15);
        try std.testing.expect(app.selection_band.?.active);
        try std.testing.expect(app.items.items[0].selected);
        try std.testing.expect(!app.items.items[1].selected);
        try std.testing.expect(!app.drag_ready);
        // Shrinking the rectangle removes items again.
        app.handleMotion(220, top - 3);
        try std.testing.expect(!app.items.items[0].selected);
        app.handleMotion(300, top + 15);
        app.handleButton(0x110, false);
        try std.testing.expect(app.selection_band == null);
        try std.testing.expect(app.items.items[0].selected);

        app.ctrl = true;
        app.items.items[2].selected = true;
        app.handleMotion(215, top - 5);
        app.handleButton(0x110, true);
        app.handleMotion(300, top + 15);
        try std.testing.expect(!app.items.items[0].selected);
        try std.testing.expect(app.items.items[2].selected);
        app.handleMotion(301, top + 16);
        try std.testing.expect(!app.items.items[0].selected); // No repeated toggling.
        app.handleButton(0x110, false);
        app.ctrl = false;
        app.shift = true;
        app.handleMotion(215, top - 5);
        app.handleButton(0x110, true);
        app.handleMotion(300, top + 15);
        try std.testing.expect(app.items.items[0].selected and app.items.items[2].selected);
        app.handleKey(c.XKB_KEY_Escape, "");
        try std.testing.expect(app.selection_band == null);
        try std.testing.expect(!app.items.items[0].selected and app.items.items[2].selected);
    }
}

test "selection edge scroll keeps a content anchor and stops on release" {
    var app = try testApp();
    defer app.deinit();
    app.list_view = true;
    try testItems(&app, 100);
    app.handleMotion(215, 150);
    app.handleButton(0x110, true);
    const anchor = app.selection_band.?.y;
    app.handleMotion(300, @floatFromInt(app.h - 30));
    try std.testing.expect(app.selectionNeedsScroll());
    app.stepSelection(app.selection_band.?.last_ms + 50);
    try std.testing.expect(app.scroll_y > 0);
    try std.testing.expectEqual(anchor, app.selection_band.?.y);
    app.handleButton(0x110, false);
    const offset = app.scroll_y;
    app.stepSelection(nowMs() + 500);
    try std.testing.expectEqual(offset, app.scroll_y);
    try std.testing.expect(!app.selectionNeedsScroll());
}

test "scrollbar gutter hover, outside drag, release and resize preserve layout" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.list_view = true;
    const column = app.listColumn(0);
    app.handleMotion(@floatFromInt(app.w - 7), @floatFromInt(app.viewTop() + 10));
    app.stepScrollbar(0);
    app.stepScrollbar(180);
    try std.testing.expectEqual(@as(f32, 1), app.scroll_appearance.wide);
    try std.testing.expectEqualDeep(column, app.listColumn(0));
    app.handleButton(0x110, true);
    try std.testing.expect(app.scroll_drag.active);
    app.handleMotion(-20, @floatFromInt(app.h + 100));
    app.stepScrollbar(200);
    try std.testing.expectEqual(app.maxScroll(), app.scroll_y);
    try std.testing.expectEqual(@as(f32, 1), app.scroll_appearance.accent);
    app.handleButton(0x110, false);
    app.stepScrollbar(220);
    app.stepScrollbar(600);
    app.stepScrollbar(800);
    try std.testing.expectEqual(@as(f32, 0), app.scroll_appearance.wide);
    try std.testing.expect(!app.scroll_appearance.active);
    app.h = 10000;
    app.clampScroll();
    app.stepScrollbar(1000);
    try std.testing.expectEqual(@as(i32, 0), app.scroll_y);
    try std.testing.expect(app.scroll_appearance.deadline == null);
}

test "viewport edge shadows at top middle bottom and when content fits" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.list_view = true;
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, app.w, app.h).?;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(cr);
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const pixels = c.cairo_image_surface_get_data(surface);
    const x: usize = @intCast(app.sidebarWidth() + 10);
    for ([_]i32{ 0, @divTrunc(app.maxScroll(), 2), app.maxScroll() }) |offset| {
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        app.scroll_y = offset;
        app.renderScrollEdges(cr, app.h - app.viewTop() - app.footerHeight());
        c.cairo_surface_flush(surface);
        const top: usize = @intCast(app.viewTop());
        const bottom: usize = @intCast(app.h - app.footerHeight() - 1);
        try std.testing.expectEqual(offset > 0, pixels[top * stride + x * 4 + 3] > 0);
        try std.testing.expectEqual(offset < app.maxScroll(), pixels[bottom * stride + x * 4 + 3] > 0);
        try std.testing.expectEqual(@as(u8, 0), pixels[(top - 1) * stride + x * 4 + 3]);
        try std.testing.expectEqual(@as(u8, 0), pixels[top * stride + 4 + 3]);
        try std.testing.expectEqual(@as(u8, 0), pixels[(top + 12) * stride + x * 4 + 3]);
    }
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    app.h = 10000;
    app.clampScroll();
    app.renderScrollEdges(cr, app.h - app.viewTop() - app.footerHeight());
    c.cairo_surface_flush(surface);
    try std.testing.expectEqual(@as(u8, 0), pixels[@as(usize, @intCast(app.viewTop())) * stride + x * 4 + 3]);
}

test "sidebar divider resizes within limits without selecting or sorting" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.resize(960, 540);
    app.stepLayout(0);
    app.items.items[0].selected = true;
    const sort = app.sort_mode;
    const y: f64 = @floatFromInt(app.contentTop() + 15);
    // Grab slightly off the line: starting a drag must not jump the width.
    app.handleMotion(210, y);
    try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(210, y)));
    app.handleButton(0x110, true);
    try std.testing.expect(app.sidebar_resize != null);
    app.handleMotion(210, y);
    try std.testing.expectEqual(@as(i32, 208), app.sidebarWidth());
    app.handleMotion(342, y);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    app.stepLayout(1000);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    app.handleMotion(10000, -50);
    try std.testing.expectEqual(@as(i32, 480), app.sidebarWidth());
    try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(10000, -50)));
    app.handleMotion(-10000, y);
    try std.testing.expectEqual(@as(i32, 160), app.sidebarWidth());
    app.handleMotion(342, y);
    app.handleButton(0x110, false);
    try std.testing.expect(app.sidebar_resize == null and app.selection_band == null and app.drag_origin == null);
    try std.testing.expect(app.items.items[0].selected and !app.items.items[1].selected);
    try std.testing.expectEqual(sort, app.sort_mode);
    app.handleMotion(400, y);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    // Window resizes clamp the drawn width but retain the user's preference.
    app.resize(500, 540);
    try std.testing.expectEqual(@as(i32, 250), app.sidebarWidth());
    app.resize(960, 540);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    app.handleMotion(340, y);
    app.handleButton(0x110, true);
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expect(app.sidebar_resize == null);
    app.handleMotion(500, y);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    app.openMenu(.background, 400, y);
    try std.testing.expect(!app.overSidebarDivider(340, y));
    app.menu = null;
    try std.testing.expect(!app.overSidebarDivider(340, 20));
    try std.testing.expect(app.overSidebarDivider(340, @floatFromInt(app.h - 1)));
    app.resize(360, 540);
    app.stepLayout(2000);
    app.stepLayout(3000);
    try std.testing.expectEqual(@as(i32, 0), app.sidebarWidth());
    try std.testing.expect(app.sidebarDivider() == null);
    app.resize(960, 540);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
}

test "sidebar scrollbar pages, drags outside and resets on resize" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.resize(700, 300);
    const bar = app.sidebarScrollbar().?;
    app.handleMotion(@as(f64, bar.thumb.x) + 5, @as(f64, bar.thumb.y) + 5);
    app.stepScrollbar(0);
    app.stepScrollbar(180);
    try std.testing.expectEqual(@as(f32, 1), app.sidebar_scroll_appearance.wide);
    app.handleButton(0x110, true);
    try std.testing.expect(app.sidebar_scroll_drag.active);
    app.handleMotion(-20, 600);
    try std.testing.expectEqual(@as(i32, @intFromFloat(bar.max_offset)), app.sidebar_scroll);
    try std.testing.expectEqual(@as(i32, 0), app.scroll_y);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.sidebar_scroll_drag.active);
    app.handleMotion(@as(f64, bar.track.x) + 5, @as(f64, bar.track.y) + 1);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(@as(f32, @floatFromInt(app.sidebar_scroll)) < bar.max_offset);
    app.resize(700, 900);
    app.stepScrollbar(1000);
    app.stepScrollbar(2000);
    try std.testing.expect(app.sidebarScrollbar() == null);
    try std.testing.expectEqual(@as(i32, 0), app.sidebar_scroll);
    try std.testing.expect(!app.sidebar_scroll_appearance.active);
    try std.testing.expect(app.sidebar_scroll_appearance.deadline == null);
    app.resize(360, 240);
    try std.testing.expect(app.sidebarScrollbar() == null);
}

test "file selection fades in and out while logical selection is immediate" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.mouse_x = -1;
    app.mouse_y = -1;
    app.items.items[0].selected = true;
    app.stepHover(1000);
    try std.testing.expect(app.items.items[0].selected);
    try std.testing.expectEqual(@as(f32, 0), app.items.items[0].selection_fill.alpha);
    app.stepHover(1050);
    const alpha = app.items.items[0].selection_fill.alpha;
    try std.testing.expect(alpha > 0 and alpha < 1);
    app.items.items[0].selected = false;
    app.stepHover(1050);
    try std.testing.expectEqual(alpha, app.items.items[0].selection_fill.alpha);
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 0), app.items.items[0].selection_fill.alpha);
    try std.testing.expect(!app.hover_active);
    app.items.items[1].selected = true;
    app.stepHover(5000);
    app.stepHover(8000);
    try std.testing.expectEqual(@as(f32, 1), app.items.items[1].selection_fill.alpha);
    app.dirty = false;
    app.stepHover(9000);
    try std.testing.expect(!app.dirty and !app.hover_active);
    anim.applySettings(.{ .enabled = false });
    app.items.items[1].selected = false;
    app.stepHover(10000);
    try std.testing.expectEqual(@as(f32, 0), app.items.items[1].selection_fill.alpha);
}

test "list column resize pushes following columns and scrolls in Files and chooser" {
    for ([_]bool{ false, true }) |chooser| {
        var app = try testApp();
        defer app.deinit();
        if (chooser) try app.configureChooser(.{ .mode = .open });
        app.list_view = true;
        try testItems(&app, 20);
        const original = app.listWidths();
        const last = app.listColumn(4);
        const rect = app.listColumn(3);
        const x = rect.x + rect.w;
        const y = rect.y + 15;
        try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(x, y)));
        app.handleMotion(x, y);
        app.handleButton(0x110, true);
        app.handleMotion(x + 120, y + 100);
        const widths = app.listWidths();
        for (original, 0..) |width, i| {
            try std.testing.expectApproxEqAbs(width + (if (i == 3) @as(f64, 120) else 0), widths[i], 0.001);
        }
        try std.testing.expectApproxEqAbs(last.x + 120, app.listColumn(4).x, 0.001);
        app.handleButton(0x110, false);
        try std.testing.expect(app.column_resize == null);
        try std.testing.expectEqual(Sort.name, app.sort_mode);
        const bar = app.horizontalScrollbar().?;
        try std.testing.expectEqual(@as(?usize, null), app.itemAt(bar.track.x + 40, bar.track.y + 1));
        try std.testing.expectEqual(@as(?[]const u8, null), app.dropDirectoryAt(bar.track.x + 40, bar.track.y + 1));
        const thumb_x = bar.thumb.x + bar.thumb.w / 2;
        const thumb_y = bar.thumb.y + bar.thumb.h / 2;
        app.handleMotion(thumb_x, thumb_y);
        app.handleButton(0x110, true);
        try std.testing.expect(app.horizontal_drag.active);
        app.handleMotion(@floatFromInt(app.w + 100), thumb_y);
        try std.testing.expectApproxEqAbs(@as(f64, 120), app.horizontalOffset(), 0.001);
        try std.testing.expectApproxEqAbs(last.x, app.listColumn(4).x, 0.001);
        app.handleButton(0x110, false);
        try std.testing.expect(!app.horizontal_drag.active);
        app.shift = true;
        app.handleWheel(-60, 1000);
        try std.testing.expectApproxEqAbs(@as(f64, 60), app.horizontalOffset(), 0.001);
        app.shift = false;
        app.handleHorizontalScroll(-1000);
        try std.testing.expectEqual(@as(f64, 0), app.horizontalOffset());
        app.resize(360, 400);
        try std.testing.expectEqualDeep(widths, app.listWidths());
        try std.testing.expect(app.horizontalScrollbar() != null);
        app.resize(1600, 600);
        try std.testing.expect(app.horizontalScrollbar() == null);
        try std.testing.expectEqual(@as(f64, 0), app.horizontalOffset());
        // Shrinking clamps only the dragged column.
        const name = app.listColumn(0);
        app.handleMotion(name.x + name.w, name.y + 15);
        app.handleButton(0x110, true);
        app.handleMotion(-1000, name.y + 15);
        app.handleButton(0x110, false);
        try std.testing.expectEqual(@as(f64, 64), app.listWidths()[0]);
        try std.testing.expectEqualSlices(f64, widths[1..], app.listWidths()[1..]);
        app.list_view = false;
        try std.testing.expect(app.horizontalScrollbar() == null);
    }
}

test "sidebar menus unpin only Places and close gaps without changing selection" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.items.items[0].selected = true;
    const y = app.placeY(App.places_start);
    const last_place_y = app.placeY(App.pin_base - 1);
    app.handleMotion(70, @floatFromInt(y + 10));
    app.handleButton(0x111, true);
    try std.testing.expectEqual(MenuKind.sidebar, app.menu.?);
    try std.testing.expectEqualStrings("Open in New Window", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Unpin", app.menuLabels()[2]);
    try std.testing.expectEqualStrings("Properties", app.menuLabels()[3]);
    app.runMenu(3); // Properties must not alter pinned places.
    app.closeDialog();
    try std.testing.expect(app.placeVisible(App.places_start));
    app.openMenu(.sidebar, 70, @floatFromInt(y));
    app.runMenu(2);
    try std.testing.expect(!app.placeVisible(App.places_start));
    try std.testing.expectEqual(y, app.placeY(App.places_start + 1));
    try std.testing.expectEqual(@as(?usize, App.places_start + 1), app.placeAt(70, @floatFromInt(y + 10)));
    try std.testing.expectEqual(last_place_y - app.placeStep(), app.placeY(App.pin_base - 1));
    try std.testing.expect(app.items.items[0].selected);
    for ([_]usize{ 0, 1 }) |index| {
        app.menu_place = index;
        app.openMenu(.sidebar, 70, 140);
        try std.testing.expectEqual(@as(usize, if (index == 1) 4 else 3), app.menuLabels().len);
        try std.testing.expectEqualStrings("Properties", app.menuLabels()[app.menuLabels().len - 1]);
        if (index == 1) {
            try std.testing.expectEqualStrings("Empty Trash…", app.menuLabels()[2]);
            app.runMenu(2);
            try std.testing.expect(app.dialog.?.deletion.empty_trash);
            try std.testing.expect(app.dialog.?.deletion.permanent);
            try std.testing.expectEqual(deletion.Action.none, app.dialog.?.deletion.key(c.XKB_KEY_Tab));
            try std.testing.expectEqual(deletion.Action.confirm, app.dialog.?.deletion.key(c.XKB_KEY_Return));
            app.deleteAction(.toggle);
            try std.testing.expect(app.dialog.?.deletion.permanent);
            app.deleteAction(.cancel);
            try std.testing.expect(app.dialog == null);
            app.openMenu(.sidebar, 70, 140);
        }
        app.runMenu(app.menuLabels().len - 1);
        try std.testing.expect(app.placeVisible(index));
    }
    app.menu_place = 2;
    app.openMenu(.sidebar, 70, 210);
    try std.testing.expectEqualStrings("Open", app.menuLabels()[0]);
    try std.testing.expectEqualStrings("Open in New Window", app.menuLabels()[1]);
    try std.testing.expectEqual(@as(usize, 0), app.menuSeparatorSpace());
    app.menu = null;
    try std.testing.expect(app.placeVisible(2));
    try std.testing.expectEqual(app.placeY(1) + app.placeStep(), app.placeY(2));
    for (App.places_start..App.pin_base) |index| {
        app.menu_place = index;
        app.openMenu(.sidebar, 70, 140);
        app.runMenu(2);
    }
    try std.testing.expectEqual(@as(u8, 0x7f), app.unpinned_places);
    try std.testing.expectEqual(@as(?usize, null), app.placeAt(70, @floatFromInt(y + 10)));
    app.closeDialog();
    try app.history.navigate(recent.location);
    try std.testing.expect(!app.history.canUp());
    try std.testing.expect(!app.toolbarButtonEnabled(.new));
    try std.testing.expect(!app.toolbarButtonEnabled(.paste));
    try std.testing.expectEqual(Sort.modified, app.effectiveSort());
    try std.testing.expectEqual(@as(?[]const u8, null), app.dropDirectoryAt(500, 300));
    app.openNewFolderDialog();
    try std.testing.expect(app.dialog == null);
    try std.testing.expect(app.placeActive(2));
}

test "pins sit after Projects, take drops by gap and keep the rows in drawn order" {
    var app = try testApp();
    defer app.deinit();
    app.h = 1000;
    const step = app.placeStep();
    const places_bottom = app.placeY(App.pin_base - 1);
    app.pinDropped(0, &.{ "/usr", "/dev/null", "/usr/", "/nonexistent-rediwm-pin", "relative" });
    try std.testing.expectEqual(@as(usize, 2), app.pins.items.items.len);
    try std.testing.expectEqualStrings("usr", app.pins.items.items[0].name());
    try std.testing.expectEqual(pins_mod.Kind.file, app.pins.items.items[1].kind);

    // Pins take the rows after Projects; the devices follow.
    try std.testing.expectEqual(App.pin_base + 2, app.deviceBase());
    try std.testing.expectEqual(app.placeY(App.pin_base - 1) + step, app.placeY(App.pin_base));
    try std.testing.expectEqual(places_bottom + 2 * step, app.placeY(App.pin_base + 1));
    const volumes = [_]volumes_mod.Volume{.{ .id = "/b/sdb1", .label = "STICK", .mount = null, .size = 1 << 30, .kind = .stick }};
    app.device_list.items = &volumes;
    try std.testing.expectEqual(App.pin_base + 2, app.deviceBase());
    try std.testing.expectEqual(app.placeY(App.pin_base + 1) + 44 + step, app.placeY(app.deviceBase()));
    try std.testing.expectEqual(@as(?usize, App.pin_base + 1), app.placeAt(70, @floatFromInt(app.placeY(App.pin_base + 1) + 10)));
    app.handleMotion(70, @floatFromInt(app.placeY(App.pin_base + 1) + 10));
    try std.testing.expectEqual(@as(usize, 801), app.hoverKey());
    app.device_list.items = &.{};

    // A drag snaps to the nearest gap from anywhere on PLACES, and only there.
    const desktop: f64 = @floatFromInt(app.placeY(App.places_start) + 10);
    const first_gap = app.pinBoundary(0);
    try std.testing.expectEqual(@as(?usize, 0), app.pinSlotAt(70, desktop));
    try std.testing.expectEqual(@as(?usize, 0), app.pinSlotAt(70, first_gap + 4));
    try std.testing.expectEqual(@as(?usize, 1), app.pinSlotAt(70, app.pinBoundary(1) - 4));
    try std.testing.expectEqual(@as(?usize, 2), app.pinSlotAt(70, app.pinBoundary(2) + 10));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(70, @floatFromInt(app.placeY(0) + 10)));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(70, app.pinBoundary(2) + 40));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(400, desktop));
    try std.testing.expect(app.dropMotion(70, first_gap + 4));
    try std.testing.expectEqual(@as(?usize, 0), app.pin_drop);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(?usize, 0), app.takePinDrop());
    try std.testing.expectEqual(@as(?usize, null), app.pin_drop);
    try std.testing.expect(!app.dropMotion(400, desktop));

    // Dropping on a gap inserts there; what is listed already, built in or
    // gone is refused.
    app.pinDropped(1, &.{"/etc"});
    try std.testing.expectEqualStrings("etc", app.pins.items.items[1].name());
    try std.testing.expectEqual(@as(usize, 3), app.pins.items.items.len);
    // The test app's home is /tmp.
    app.pinDropped(0, &.{"/tmp"});
    try std.testing.expectEqual(@as(usize, 3), app.pins.items.items.len);
    try std.testing.expectEqualStrings("Already in Places", app.status_notice.?);

    // Only a pin offers removal, which closes the gap again.
    app.menu_place = App.pin_base + 1;
    app.openMenu(.sidebar, 70, 140);
    try std.testing.expectEqualStrings("Open in New Window", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Remove from Places", app.menuLabels()[2]);
    app.runMenu(2);
    try std.testing.expectEqual(@as(usize, 2), app.pins.items.items.len);
    try std.testing.expectEqualStrings("null", app.pins.items.items[1].name());
    app.menu = .sidebar;
    try std.testing.expectEqualStrings("Remove from Places", app.menuLabels()[1]); // File pins keep their file actions.
    app.pins.items.items[1].kind = .missing;
    try std.testing.expectEqualStrings("Remove from Places", app.menuLabels()[1]);
    app.chooser = .{ .mode = .open };
    app.menu_place = App.pin_base;
    try std.testing.expectEqualStrings("Remove from Places", app.menuLabels()[1]);
    app.menu_place = 0;
    try std.testing.expectEqualStrings("Properties", app.menuLabels()[1]);
    try std.testing.expectEqual(places_bottom + 2 * step, app.placeY(App.pin_base + 1));
}

test "Sidebar lists devices under Places; only mounted ones eject" {
    var app = try testApp();
    defer app.deinit();
    app.h = 1000;
    const extent = app.sidebarExtent();
    const last_place_y = app.placeY(App.pin_base - 1);
    const volumes = [_]volumes_mod.Volume{
        .{ .id = "/b/sdb1", .label = "STICK", .mount = "/run/media/user/STICK", .size = 1 << 30, .kind = .stick },
        .{ .id = "/b/sda1", .label = "", .mount = null, .size = 500 << 30, .kind = .drive },
    };
    app.device_list.items = &volumes;
    const mounted = app.deviceBase();
    const unmounted = mounted + 1;
    const step = app.placeStep();
    try std.testing.expectEqual(last_place_y + 44 + step, app.placeY(mounted));
    try std.testing.expectEqual(app.placeY(mounted) + step, app.placeY(unmounted));
    try std.testing.expectEqual(extent + 44 + 2 * step, app.sidebarExtent());

    const row_y: f64 = @floatFromInt(app.placeY(mounted) + 10);
    try std.testing.expectEqual(@as(?usize, mounted), app.placeAt(70, row_y));
    const button = app.ejectRect(mounted);
    try std.testing.expectEqual(@as(?usize, 0), app.ejectAt(button.x + 5, button.y + 5));
    try std.testing.expectEqual(@as(?usize, null), app.ejectAt(70, row_y));
    const other = app.ejectRect(unmounted);
    try std.testing.expectEqual(@as(?usize, null), app.ejectAt(other.x + 5, other.y + 5));
    app.handleMotion(button.x + 5, button.y + 5);
    try std.testing.expectEqual(@as(usize, 700), app.hoverKey());
    app.handleMotion(70, row_y);
    try std.testing.expectEqual(@as(usize, 600), app.hoverKey());
    app.handleMotion(70, @floatFromInt(app.placeY(unmounted) + 10));
    try std.testing.expectEqual(@as(usize, 601), app.hoverKey());

    app.menu = .device;
    app.menu_place = mounted;
    try std.testing.expectEqualStrings("Open in New Window", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Eject", app.menuLabels()[2]);
    app.menu_place = unmounted;
    try std.testing.expectEqual(@as(usize, 1), app.menuLabels().len);
    try std.testing.expectEqualStrings("Mount", app.menuLabels()[0]);

    // Results end the operation and say what happened; a mount only opens
    // the volume if the view has not moved on meanwhile.
    var result = std.mem.zeroes(volumes_mod.Result);
    @memcpy(result.object[0..7], "/b/sdb1");
    app.device_op = .{ .id = try std.testing.allocator.dupe(u8, "/b/sdb1"), .unmount = true, .open = false, .navigation = app.navigation_count };
    result.ok = 1;
    app.deviceResult(&result);
    try std.testing.expect(app.device_op == null);
    try std.testing.expectEqualStrings("STICK can be safely removed", app.status_notice.?);
    app.device_op = .{ .id = try std.testing.allocator.dupe(u8, "/b/sdb1"), .unmount = true, .open = false, .navigation = app.navigation_count };
    result.ok = 0;
    @memcpy(result.code[0.."org.freedesktop.UDisks2.Error.DeviceBusy".len], "org.freedesktop.UDisks2.Error.DeviceBusy");
    app.deviceResult(&result);
    try std.testing.expectEqualStrings("STICK is busy", app.status_notice.?);
    result = std.mem.zeroes(volumes_mod.Result);
    @memcpy(result.object[0..7], "/b/sda1");
    @memcpy(result.path[0..6], "/mnt/a");
    result.ok = 1;
    app.device_op = .{ .id = try std.testing.allocator.dupe(u8, "/b/sda1"), .unmount = false, .open = true, .navigation = app.navigation_count -% 1 };
    app.deviceResult(&result);
    try std.testing.expectEqualStrings("500.0 GB Volume mounted", app.status_notice.?);
}

test "File context actions distinguish files, folders and symlinks" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.items.items[0].selected = true;
    app.items.items[0].is_dir = false;
    app.menu = .file;
    try std.testing.expectEqual(@as(usize, 8), app.menuLabels().len);
    try std.testing.expectEqualStrings("Open With…", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Cut", app.menuLabels()[2]);
    try std.testing.expectEqualStrings("Properties", app.menuLabels()[7]);
    try std.testing.expectEqualStrings("F2", app.menuHint(5).?);
    try std.testing.expectEqual(@as(usize, 14), app.menuSeparatorSpace());
    app.items.items[0].is_symlink = true;
    try std.testing.expect(app.canOpenWith());
    app.items.items[0].is_broken = true;
    try std.testing.expect(!app.canOpenWith());
    app.items.items[0].is_broken = false;
    app.items.items[1].selected = true;
    app.items.items[1].is_dir = true;
    try std.testing.expectEqualStrings("Calculate size", app.menuLabels()[6]);
    try std.testing.expectEqualStrings("Cut", app.menuLabels()[1]);
    app.items.items[1].is_symlink = true;
    try std.testing.expectEqual(@as(usize, 7), app.menuLabels().len);
    app.items.items[1].selected = false;
    app.items.items[0].name = "Hub.AppImage";
    app.items.items[0].path = "/Hub.AppImage";
    try std.testing.expectEqualStrings("/Hub.AppImage", app.selectedAppImage().?);
    try std.testing.expectEqualStrings("Add to applications", app.menuLabels()[2]);
    app.items.items[1].selected = true;
    try std.testing.expect(app.selectedAppImage() == null);
    app.items.items[1].selected = false;
    app.items.items[0].missing = true;
    try std.testing.expect(app.selectedAppImage() == null);
    app.items.items[0].missing = false;
    app.chooser = .{ .mode = .open };
    try std.testing.expect(app.selectedAppImage() == null);
    app.chooser = null;
    app.items.items[0].name = "example.ZIP";
    app.items.items[0].path = "/example.ZIP";
    try std.testing.expectEqualStrings("Extract", app.menuLabels()[2]);
    try std.testing.expectEqualStrings("Extract to…", app.menuLabels()[3]);
    try std.testing.expectEqual(FileAction.rename, app.fileActions()[7]);
    app.items.items[1].selected = true;
    try std.testing.expect(app.selectedArchive() == null);
    app.items.items[1].selected = false;
    try app.history.navigateLocation("/example.ZIP", "/example.ZIP".len);
    app.menu = .file;
    try std.testing.expectEqualSlices(FileAction, &.{.open}, app.fileActions());
    app.openNewFolderDialog();
    app.openRenameDialog();
    try std.testing.expect(app.dialog == null);
    try std.testing.expect(!app.executePaste(.copy, &.{"/tmp/a"}));
}

test "Git layout has two columns, scrollable sidebar and display-only deleted rows" {
    var app = try testApp();
    defer app.deinit();
    var snap: worker_mod.Snapshot = .{ .arena = undefined, .request_id = 1, .dir = "/repo", .items = &.{}, .repository = .{ .root = "/repo", .directory = "/repo", .branch = "main" } };
    app.snapshot = &snap;
    defer app.snapshot = null;
    app.list_view = true;
    try std.testing.expectEqual(@as(usize, 2), app.columnLabels().len);
    try std.testing.expectEqualStrings("Git", app.columnLabels()[1]);
    try std.testing.expectEqual(@as(f64, 164), app.listColumn(1).w);
    try std.testing.expectEqual(@as(f64, 0), app.listColumn(2).w);
    const boundary = app.listColumn(0);
    const boundary_x = boundary.x + boundary.w;
    const boundary_y = boundary.y + 10;
    try std.testing.expectEqual(@as(?usize, 0), app.columnBoundary(boundary_x, boundary_y));
    const sort = app.sort_mode;
    app.handleMotion(boundary_x, boundary_y);
    app.handleButton(0x110, true);
    app.handleMotion(boundary_x - 40, boundary_y + 100);
    try std.testing.expectApproxEqAbs(@as(f64, 164), app.listColumn(1).w, 0.001);
    try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(boundary_x - 40, boundary_y + 100)));
    app.handleMotion(boundary_x + 1000, boundary_y);
    try std.testing.expectApproxEqAbs(@as(f64, 164), app.listColumn(1).w, 0.001);
    app.handleButton(0x110, false);
    try std.testing.expect(app.column_resize == null);
    try std.testing.expectEqual(sort, app.sort_mode);
    app.resize(360, 300);
    const widths = app.listWidths();
    try std.testing.expect(widths[0] >= 96 and widths[1] >= 64);
    try std.testing.expect(widths[0] + widths[1] > @as(f64, @floatFromInt(app.cellWidth() - 20)));
    try std.testing.expect(app.horizontalScrollbar() != null);
    app.resize(960, 540);
    app.sortByColumn(1);
    try std.testing.expectEqual(sort, app.sort_mode);
    // Turning Git View off presents the repository as an ordinary folder.
    const gone: worker_mod.Item = .{ .name = "gone.txt", .path = "/repo/gone.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = "", .git_status = .deleted, .missing = true };
    try std.testing.expect(app.matches(gone));
    app.git_view = false;
    try std.testing.expect(app.repository() == null and app.inRepository());
    try std.testing.expectEqual(@as(usize, 5), app.columnLabels().len);
    try std.testing.expectEqual(@as(i32, 0), app.gitSidebarHeight());
    try std.testing.expect(!app.matches(gone));
    app.git_view = true;
    // Changed files list flat; search matches the path shown, and full paths can be turned off.
    const nested: worker_mod.Item = .{ .name = "omega.txt", .label = "zdir/inner/omega.txt", .path = "/repo/zdir/inner/omega.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 6, .mtime = 1, .icon_name = "", .git_status = .untracked };
    try app.search.text.appendSlice(app.allocator, "zdir");
    try std.testing.expect(app.matches(nested));
    app.full_paths = false;
    try std.testing.expect(!app.matches(nested));
    app.full_paths = true;
    app.changed_only = false;
    try std.testing.expect(!app.matches(nested));
    app.changed_only = true;
    app.search.text.clearRetainingCapacity();
    // The Git card is the last sidebar section, below the final place.
    try std.testing.expect(app.gitCard().y > @as(f64, @floatFromInt(app.placeY(App.pin_base - 1))));
    const expanded_extent = app.sidebarExtent();
    app.git_expanded = false;
    // Collapsing hides the current-branch row and the "New branch" row (28px each) and the 4px padding.
    try std.testing.expectEqual(expanded_extent - 60, app.sidebarExtent());
    try testItems(&app, 1);
    app.items.items[0].missing = true;
    app.items.items[0].selected = true;
    app.focused_index = 0;
    app.copySelected();
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    app.openRenameDialog();
    try std.testing.expect(app.dialog == null);
    app.openTrashConfirmDialog();
    try std.testing.expect(app.dialog == null);
    app.previewSelected();
    try std.testing.expect(app.editor_path == null);
}

test "Transfers uses list geometry and isolates file actions while preserving the folder view" {
    var app = App{
        .allocator = std.testing.allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    // These records are only counted. File actions must never read them
    // while the transfer pane is active.
    var files: [32]ViewItem = undefined;
    var transfers: [32]@import("torrents.zig").Transfer = undefined;
    app.items = .{ .items = &files, .capacity = files.len };
    app.torrents.snapshot = .{ .arena = undefined, .value = .{ .transfers = &transfers } };
    app.list_view = false;
    app.transfer_view = .{ .active = true, .folder_scroll = 77, .folder_search_visible = true };
    try std.testing.expectEqual(@as(i32, 1), app.columns());
    try std.testing.expectEqual(@as(i32, 38), app.rowHeight());
    try std.testing.expectEqualStrings("Status", app.columnLabels()[1]);
    try std.testing.expect(app.scrollbarGeometry() != null);
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(260, 180));
    try std.testing.expectEqual(@as(?[]const u8, null), app.dropDirectoryAt(260, 180));
    app.handleKey(c.XKB_KEY_Delete, "");
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_v, "v");
    try std.testing.expect(!app.paste_requested);
    try std.testing.expect(app.dialog == null);
    app.ctrl = false;
    app.transferPaneKey(c.XKB_KEY_End);
    try std.testing.expectEqual(@as(?usize, 31), app.transfer_view.row);
    try std.testing.expect(app.scroll_y > 0);
    app.back();
    try std.testing.expect(!app.transfer_view.active);
    try std.testing.expect(!app.list_view);
    try std.testing.expect(app.search_visible);
    try std.testing.expectEqual(@as(i32, 77), app.scroll_y);
}

fn inlineTransferFixture() @import("torrents.zig").Transfer {
    return .{
        .id = "abc",
        .name = "bundle",
        .source = "/Downloads/bundle.torrent",
        .download_directory = "/Downloads",
        .destination = "/Downloads",
        .storage = "/Downloads/.rediwm-partials/abc",
        .pending = false,
        .metadata = true,
        .paused = false,
        .finished = false,
        .published = false,
        .progress = 420000,
        .download_rate = 100,
        .upload_rate = 50,
        .total = 1000,
        .done = 420,
        .ratio = 1,
        .limit = 1024,
        .@"error" = "",
        .files = &.{},
        .peers = 4,
        .known_peers = 8,
        .seeds = 2,
    };
}

test "folder transfer rows match full paths, avoid duplicates and exclude staging from file operations" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var app = App{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = allocator, .current = "/Downloads" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    defer app.items.deinit(allocator);
    var transfers = [_]@import("torrents.zig").Transfer{inlineTransferFixture()};
    app.torrents.snapshot = .{ .arena = undefined, .value = .{ .transfers = &transfers } };
    const old = std.StringHashMap(ViewItem).init(allocator);
    app.appendTorrentRows(arena.allocator(), &old);
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    try std.testing.expect(app.items.items[0].transfer_stub and app.items.items[0].missing);
    try std.testing.expectEqualStrings("abc", app.torrentForItem(0).?.id);
    app.list_view = true;
    try std.testing.expect(app.inlineTorrentWidth(0) > 0);
    try std.testing.expect(app.sizeButtonRect(0) == null);
    app.items.items[0].selected = true;
    app.copySelected();
    app.openRenameDialog();
    app.openTrashConfirmDialog();
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    try std.testing.expect(app.dialog == null);
    app.activateItem(0);
    try std.testing.expectEqual(@import("app_model.zig").DialogKind.transfers, app.dialog.?.kind);
    app.closeDialog();

    app.items.items[0].transfer_stub = false;
    app.items.items[0].missing = false;
    app.items.items[0].path = "/Downloads/bundle.torrent";
    app.appendTorrentRows(arena.allocator(), &old);
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    app.items.items[0].path = "/Elsewhere/bundle.torrent";
    try std.testing.expect(app.torrentForItem(0) == null);
    transfers[0].published = true;
    transfers[0].destination = "/Downloads/bundle.download";
    app.items.items[0].path = "/Downloads/bundle.download/file.bin";
    try std.testing.expect(app.torrentForItem(0) != null);
    app.items.items[0].path = "/Downloads/bundle.download-other/file.bin";
    try std.testing.expect(app.torrentForItem(0) == null);
}

test "torrent ETA uses remaining selected bytes and is unknown while paused or stalled" {
    const eta = @import("torrents.zig").etaSeconds;
    var transfer = inlineTransferFixture();
    try std.testing.expectEqual(@as(?i64, 6), eta(transfer));
    transfer.download_rate = 0;
    try std.testing.expect(eta(transfer) == null);
    transfer.download_rate = 100;
    transfer.paused = true;
    try std.testing.expect(eta(transfer) == null);
    transfer.finished = true;
    try std.testing.expectEqual(@as(?i64, 0), eta(transfer));
    transfer.pending = true;
    try std.testing.expect(eta(transfer) == null);
}
