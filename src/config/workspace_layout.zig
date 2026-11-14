//! Versioned, bounded workspace snapshots. No compositor or scene dependencies.
const std = @import("std");
pub const Geometry = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Canvas = struct {
    geometry: Geometry,
    zoom_index: usize = 0,
    maximized: bool = false,
    tile: ?[]const u8 = null,
    fullscreen: bool = false,
    maximize_restore: ?Geometry = null,
    tile_restore: ?Geometry = null,
    fullscreen_restore: ?Geometry = null,
};
pub const Reinsert = struct {
    anchor: u64,
    group: bool = false,
    axis: enum { horizontal, vertical } = .horizontal,
    ratio: f64 = 0.5,
    before: bool = false,
};
pub const Window = struct {
    app_id: []const u8,
    title: []const u8 = "",
    backend: []const u8 = "xdg",
    instance: []const u8 = "",
    ordinal: usize = 0,
    workspace: u8,
    order: u64,
    group: u64 = 0,
    tab_active: bool = true,
    floating: bool = false,
    floating_override: ?bool = null,
    reinsert: ?Reinsert = null,
    geometry: Geometry,
    auto_restore: ?Geometry = null,
    maximize_restore: ?Geometry = null,
    fullscreen_restore: ?Geometry = null,
    tile: ?[]const u8 = null,
    tile_restore: ?Geometry = null,
    maximized: bool = false,
    fullscreen: bool = false,
    minimized: bool = false,
    canvas: ?Canvas = null,
};
/// Preorder binary tree. A leaf stores a stable insertion or tab-group ID.
pub const Node = struct {
    id: ?u64 = null,
    group: bool = false,
    axis: enum { horizontal, vertical } = .horizontal,
    ratio: f64 = 0.5,
};
pub const Workspace = struct {
    id: u8,
    automatic: bool = true,
    output: []const u8 = "",
    visible: bool = false,
    focus_order: ?u64 = null,
    nodes: []const Node = &.{},
};
pub const Camera = struct { offset_x: f64 = 0, offset_y: f64 = 0, zoom_index: usize = 0 };
pub const Bounds = struct { max_x: f64 = 0, max_y: f64 = 0, origin_x: f64 = 0, origin_y: f64 = 0, width: f64 = 0, height: f64 = 0 };
pub const Saved = struct {
    version: u32 = 2,
    camera: Camera = .{},
    bounds: Bounds = .{},
    workspaces: []const Workspace,
    windows: []const Window,
};
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Saved) {
    const parsed = try std.json.parseFromSlice(Saved, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const s = parsed.value;
    if (s.version != 2) return error.UnsupportedLayoutVersion;
    if (s.workspaces.len > 32 or s.windows.len > 4096) return error.InvalidLayout;
    if (!std.math.isFinite(s.camera.offset_x) or !std.math.isFinite(s.camera.offset_y)) return error.InvalidLayout;
    inline for (@typeInfo(Bounds).@"struct".field_names) |name| if (!std.math.isFinite(@field(s.bounds, name))) return error.InvalidLayout;
    var seen: [32]bool = @splat(false);
    for (s.workspaces) |w| {
        if (w.id == 0 or w.id > 32 or seen[w.id - 1] or w.nodes.len > 8191) return error.InvalidLayout;
        seen[w.id - 1] = true;
        for (w.nodes, 0..) |node, index| if (node.id) |id| {
            for (w.nodes[0..index]) |prior| if (prior.id == id and prior.group == node.group) return error.InvalidLayout;
        };
        var cursor: usize = 0;
        if (w.nodes.len > 0) try validateTree(w.nodes, &cursor, 0);
        if (cursor != w.nodes.len) return error.InvalidLayout;
    }
    for (s.windows, 0..) |w, i| {
        if (w.workspace == 0 or w.workspace > 32 or !seen[w.workspace - 1] or w.order == 0 or w.order == std.math.maxInt(u64) or !validGeometry(w.geometry)) return error.InvalidLayout;
        if (w.app_id.len > 4096 or w.title.len > 16384) return error.InvalidLayout;
        for (s.windows[0..i]) |previous| if (previous.order == w.order) return error.InvalidLayout;
        if (w.reinsert) |r| if (r.anchor == 0 or !std.math.isFinite(r.ratio) or r.ratio < 0.05 or r.ratio > 0.95) return error.InvalidLayout;
        if (w.auto_restore) |g| if (!validGeometry(g)) return error.InvalidLayout;
        if (w.maximize_restore) |g| if (!validGeometry(g)) return error.InvalidLayout;
        if (w.fullscreen_restore) |g| if (!validGeometry(g)) return error.InvalidLayout;
        if (w.tile_restore) |g| if (!validGeometry(g)) return error.InvalidLayout;
        if (w.canvas) |c| {
            if (!validGeometry(c.geometry)) return error.InvalidLayout;
            if (c.maximize_restore) |g| if (!validGeometry(g)) return error.InvalidLayout;
            if (c.tile_restore) |g| if (!validGeometry(g)) return error.InvalidLayout;
            if (c.fullscreen_restore) |g| if (!validGeometry(g)) return error.InvalidLayout;
        }
    }
    return parsed;
}
fn validGeometry(g: Geometry) bool {
    return g.width > 0 and g.height > 0 and g.width <= 65536 and g.height <= 65536 and @abs(@as(i64, g.x)) < (1 << 28) and @abs(@as(i64, g.y)) < (1 << 28);
}
fn validateTree(nodes: []const Node, cursor: *usize, depth: usize) !void {
    if (cursor.* >= nodes.len or depth > 128) return error.InvalidLayout;
    const node = nodes[cursor.*];
    cursor.* += 1;
    if (node.id) |id| {
        if (id == 0) return error.InvalidLayout;
        return;
    }
    if (!std.math.isFinite(node.ratio) or node.ratio < 0.05 or node.ratio > 0.95) return error.InvalidLayout;
    try validateTree(nodes, cursor, depth + 1);
    try validateTree(nodes, cursor, depth + 1);
}

test "workspace saves reject unsupported versions and malformed trees" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedLayoutVersion, parse(a, "{\"version\":3,\"workspaces\":[],\"windows\":[]}"));
    try std.testing.expectError(error.InvalidLayout, parse(a, "{\"workspaces\":[{\"id\":1,\"nodes\":[{}]}],\"windows\":[]}"));
    var valid = try parse(a, "{\"workspaces\":[{\"id\":2,\"nodes\":[{}, {\"id\":1}, {\"id\":2}]}],\"windows\":[]}");
    defer valid.deinit();
    try std.testing.expectEqual(@as(usize, 3), valid.value.workspaces[0].nodes.len);
}

pub const LegacyWindow = struct {
    app_id: []const u8 = "",
    x: i32 = 0,
    y: i32 = 0,
    zoom_index: usize = 0,
};
/// Unversioned canvas TOML from earlier releases. Retain its coordinate/zoom
/// semantics; old width/height described chrome rather than client geometry.
pub fn parseLegacy(a: std.mem.Allocator, bytes: []const u8) ![]const LegacyWindow {
    var list: std.ArrayList(LegacyWindow) = .empty;
    errdefer list.deinit(a);
    var current: LegacyWindow = .{};
    var have = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "[[window]]")) {
            if (have) try list.append(a, current);
            current = .{};
            have = false;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "app_id")) {
            const unquoted = try @import("ui").theme.unquote(value);
            current.app_id = try a.dupe(u8, unquoted);
            have = true;
        } else if (std.mem.eql(u8, key, "x")) current.x = try std.fmt.parseInt(i32, value, 10) else if (std.mem.eql(u8, key, "y")) current.y = try std.fmt.parseInt(i32, value, 10) else if (std.mem.eql(u8, key, "zoom_index")) current.zoom_index = try std.fmt.parseInt(usize, value, 10);
    }
    if (have) try list.append(a, current);
    return list.toOwnedSlice(a);
}

/// The saved rows of a flat (non-workspace) layout, each claimable by one window.
/// Reads both the legacy `[[window]]` TOML and the canvas rows of a workspace
/// snapshot. No compositor dependencies: the startup restore keeps one of these
/// for its whole run (session/layout_autosave.zig).
pub const Flat = struct {
    rows: []Row,

    pub const Row = struct {
        app_id: []const u8,
        x: i32,
        y: i32,
        /// Only canvas rows of a workspace snapshot carry a size; legacy rows
        /// restore position and zoom.
        geometry: ?Geometry = null,
        zoom_index: usize = 0,
        claimed: bool = false,
    };

    /// `a` owns the result (it is meant to be an arena).
    pub fn fromBytes(a: std.mem.Allocator, bytes: []const u8) !Flat {
        var rows: std.ArrayList(Row) = .empty;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, bytes, " \t\r\n"), "{")) {
            var saved = try parse(a, bytes);
            defer saved.deinit();
            for (saved.value.windows) |window| {
                const canvas = window.canvas orelse continue;
                try rows.append(a, .{
                    .app_id = try a.dupe(u8, window.app_id),
                    .x = canvas.geometry.x,
                    .y = canvas.geometry.y,
                    .geometry = canvas.geometry,
                    .zoom_index = canvas.zoom_index,
                });
            }
        } else for (try parseLegacy(a, bytes)) |window| {
            try rows.append(a, .{ .app_id = window.app_id, .x = window.x, .y = window.y, .zoom_index = window.zoom_index });
        }
        return .{ .rows = try rows.toOwnedSlice(a) };
    }

    /// The first unclaimed row for `app_id`, marked claimed: separate windows of
    /// one app get their rows in saved order, and never the same row twice.
    pub fn claim(self: *Flat, app_id: []const u8) ?*const Row {
        for (self.rows) |*row| {
            if (row.claimed or !std.mem.eql(u8, row.app_id, app_id)) continue;
            row.claimed = true;
            return row;
        }
        return null;
    }

    /// Whether some row has not found its window yet.
    pub fn pending(self: *const Flat) bool {
        for (self.rows) |row| if (!row.claimed) return true;
        return false;
    }
};

test "flat layout rows are claimed once, in order, per app" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var flat = try Flat.fromBytes(arena.allocator(), "[[window]]\napp_id = \"a\"\nx = 1\n[[window]]\napp_id = \"b\"\nx = 2\n[[window]]\napp_id = \"a\"\nx = 3\n");
    try std.testing.expectEqual(@as(usize, 3), flat.rows.len);
    try std.testing.expect(flat.pending());
    try std.testing.expectEqual(@as(i32, 1), flat.claim("a").?.x);
    try std.testing.expectEqual(@as(i32, 3), flat.claim("a").?.x);
    try std.testing.expect(flat.claim("a") == null);
    try std.testing.expect(flat.claim("missing") == null);
    try std.testing.expect(flat.pending());
    try std.testing.expectEqual(@as(i32, 2), flat.claim("b").?.x);
    try std.testing.expect(!flat.pending());
}

test "flat layout reads canvas rows of a workspace snapshot and skips the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"workspaces":[{"id":1,"nodes":[]}],"windows":[
        \\{"app_id":"x","workspace":1,"order":1,"geometry":{"x":0,"y":0,"width":9,"height":9},
        \\ "canvas":{"geometry":{"x":10,"y":20,"width":300,"height":200},"zoom_index":2}},
        \\{"app_id":"y","workspace":1,"order":2,"geometry":{"x":0,"y":0,"width":9,"height":9}}]}
    ;
    var flat = try Flat.fromBytes(arena.allocator(), json);
    try std.testing.expectEqual(@as(usize, 1), flat.rows.len);
    const row = flat.claim("x").?;
    try std.testing.expectEqual(@as(i32, 20), row.y);
    try std.testing.expectEqual(@as(i32, 300), row.geometry.?.width);
    try std.testing.expectEqual(@as(usize, 2), row.zoom_index);
}

test "legacy layout keeps separate occurrences of an app" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseLegacy(arena.allocator(), "[[window]]\napp_id = \"app\"\nx = 10\n[[window]]\napp_id = \"app\"\nx = 20\n");
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(i32, 20), rows[1].x);
}
