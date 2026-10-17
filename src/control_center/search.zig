//! Global Settings search UI. The field outlives tree rebuilds and results own
//! their strings/widgets in a separate arena, never in a section's arena.
const std = @import("std");
const ui = @import("ui");
const W = ui.layout.Widget;
const panel = @import("panel.zig");
const CC = panel.ControlCenter;
const index = @import("search_index.zig");
const gpa = @import("../main.zig").gpa;

pub const State = struct {
    field: W = .{ .kind = .container },
    toolbar: W = .{ .kind = .container },
    toolbar_children: [2]W = undefined,
    initialized: bool = false,
    focused: bool = false,
    request_focus: bool = false,
    expanded: bool = false,
    active: bool = false,
    built_active: bool = false,
    selected: usize = 0,
    matches: [index.entries.len]usize = undefined,
    count: usize = 0,
    rows: []W = &.{},
    arena: std.heap.ArenaAllocator = .init(gpa),
    saved_scroll: ui.layout.ScrollState = .{},
    restore_scroll: bool = false,
    pending_result: ?usize = null,
    destination: ?usize = null,
    reveal: bool = false,
    unavailable: bool = false,
    reset_scroll: bool = false,

    pub fn deinit(s: *State) void {
        if (s.initialized) gpa.free(s.field.kind.text_input.value);
        s.arena.deinit();
    }

    pub fn capture(s: *State) void {
        s.focused = s.initialized and ui.input.current.focused == &s.field;
    }

    pub fn buildToolbar(s: *State, cc: *CC) void {
        if (!s.initialized) {
            const value = gpa.dupe(u8, "") catch return;
            s.field = .{ .name = "settings_search", .kind = .{ .text_input = .{
                .field = .{ .leading_icon = .search, .leading_icon_size = 14 },
                .placeholder = "Search settings…",
                .value = value,
                .owner = cc,
                .on_change = changed,
            } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } };
            s.initialized = true;
        }
        s.toolbar_children = .{
            .{ .kind = .container, .width = .{ .flex = 1 }, .children = (&s.field)[0..1] },
            .{ .name = "settings_search_clear", .kind = .{ .button = .{ .label = "×", .owner = cc, .on_click = clearClicked } }, .width = .{ .fixed = 30 }, .height = .{ .fixed = 36 } },
        };
        s.toolbar = .{ .kind = .container, .direction = .row, .gap = 4, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 }, .children = s.toolbar_children[0..if (s.query().len > 0) @as(usize, 2) else 1] };
    }

    pub fn query(s: *const State) []const u8 {
        return if (s.initialized) s.field.kind.text_input.value else "";
    }

    fn failed(s: *State) W {
        s.count = 0;
        s.rows = &.{};
        return panel.outOfMemory();
    }

    pub fn build(s: *State, cc: *CC) W {
        _ = s.arena.reset(.retain_capacity);
        const a = s.arena.allocator();
        s.count = 0;
        var scores: [index.entries.len]u32 = undefined;
        for (index.entries, 0..) |entry, id| {
            if (entry.page == .services and (cc.systemd_client == null or !cc.systemd_client.?.available())) continue;
            const rank = index.score(entry, s.query(), panel.page_labels[@intFromEnum(entry.page)]) orelse continue;
            var at = s.count;
            while (at > 0 and scores[at - 1] < rank) : (at -= 1) {
                scores[at] = scores[at - 1];
                s.matches[at] = s.matches[at - 1];
            }
            scores[at] = rank;
            s.matches[at] = id;
            s.count += 1;
        }
        s.selected = @min(s.selected, s.count -| 1);
        s.rows = a.alloc(W, s.count + 1) catch return s.failed();
        const t = panel.palette();
        const query_copy = a.dupe(u8, s.query()) catch return s.failed();
        s.rows[0] = panel.sectionTitle(if (s.count == 0) "No settings found" else "Search results");
        if (s.count == 0) {
            const children = a.dupe(W, &.{ s.rows[0], .{ .kind = .{ .text = .{ .content = "Try a setting name, such as volume, wallpaper or scroll.", .font_size = t.settings_description_size, .color = t.dim } } } }) catch return s.failed();
            return .{ .name = "settings_search_results", .kind = .container, .direction = .column, .gap = 12, .children = children };
        }
        for (s.matches[0..s.count], 0..) |id, i| {
            const entry = index.entries[id];
            const title = W{ .kind = .{ .text = .{ .content = entry.title, .font_size = t.app_text_size, .weight = 600, .color = t.fg, .highlight_query = query_copy } } };
            const path = panel.page_labels[@intFromEnum(entry.page)];
            const subtitle = W{ .kind = .{ .text = .{ .content = if (entry.target.len == 0) "Settings page" else path, .font_size = t.settings_description_size, .color = t.dim, .highlight_query = query_copy } } };
            const labels = a.dupe(W, &.{ title, subtitle }) catch return s.failed();
            const children = a.dupe(W, &.{.{ .kind = .container, .direction = .column, .width = .{ .flex = 1 }, .gap = 4, .children = labels }}) catch return s.failed();
            s.rows[i + 1] = .{ .name = entry.target, .kind = .{ .row = .{ .owner = cc, .id = id, .on_click = resultClicked, .selected = i == s.selected } }, .height = .{ .fixed = 64 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.all(10), .children = children };
        }
        return .{ .name = "settings_search_results", .kind = .container, .direction = .column, .gap = 6, .width = .{ .percent = 1 }, .children = s.rows };
    }
};

pub fn focus(cc: *CC) void {
    if (cc.is_welcome) return;
    const s = &cc.search;
    s.expanded = true;
    s.request_focus = true;
    s.active = std.mem.trim(u8, s.query(), " \t\r\n").len > 0;
    // Focus after the rebuild, whose dispatcher reset would otherwise lose it.
    s.buildToolbar(cc);
    cc.relayout();
    ui.input.current.focus(&cc.root, &s.field);
    _ = ui.input.current.keyEvent(gpa, .select_all, .{}) catch {};
    cc.requestWidgetRepaint();
}

pub fn focusClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *CC = @ptrCast(@alignCast(owner orelse return));
    cc.search.expanded = true;
    cc.search.request_focus = true;
    cc.search.active = std.mem.trim(u8, cc.search.query(), " \t\r\n").len > 0;
    cc.refresh();
}

fn changed(owner: ?*anyopaque, _: usize, value: []const u8) void {
    const cc: *CC = @ptrCast(@alignCast(owner orelse return));
    const s = &cc.search;
    s.active = std.mem.trim(u8, value, " \t\r\n").len > 0;
    s.selected = 0;
    s.reset_scroll = true;
    s.destination = null;
    s.unavailable = false;
    cc.refresh();
}

fn clearClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *CC = @ptrCast(@alignCast(owner orelse return));
    clear(cc);
}

pub fn clear(cc: *CC) void {
    const s = &cc.search;
    if (!s.initialized) return;
    const empty = gpa.dupe(u8, "") catch return;
    gpa.free(s.field.kind.text_input.value);
    s.field.kind.text_input.value = empty;
    s.field.kind.text_input.cursor_pos = 0;
    s.field.kind.text_input.selection_anchor = null;
    s.active = false;
    s.destination = null;
    s.unavailable = false;
    s.request_focus = true;
    cc.refresh();
}

fn resultClicked(owner: ?*anyopaque, id: usize) void {
    const cc: *CC = @ptrCast(@alignCast(owner orelse return));
    cc.search.pending_result = id;
}

pub fn apply(cc: *CC) void {
    const s = &cc.search;
    const id = s.pending_result orelse return;
    s.pending_result = null;
    if (id >= index.entries.len) return;
    s.active = false;
    s.built_active = false;
    s.restore_scroll = false;
    s.focused = false;
    s.request_focus = false;
    ui.input.current.focused = null;
    s.destination = id;
    s.unavailable = false;
    s.reveal = true;
    cc.selectPage(index.entries[id].page);
}

pub fn key(cc: *CC, k: ui.input.Key, shift: bool) bool {
    const s = &cc.search;
    if (cc.is_welcome or !s.initialized) return false;
    if (s.active and cc.refresh_pending and (k == .up or k == .down or k == .enter or k == .tab)) cc.relayout();
    const field_focused = ui.input.current.focused == &s.field;
    if (k == .escape and (s.active or field_focused or s.destination != null)) {
        if (s.query().len > 0 or s.destination != null) clear(cc) else {
            s.expanded = false;
            s.focused = false;
            ui.input.current.focused = null;
            cc.refresh();
        }
        return true;
    }
    if (s.active and (k == .down or k == .up)) {
        if (s.count > 0) {
            ui.input.current.focus(&cc.root, &s.field);
            s.selected = if (k == .down) @min(s.selected + 1, s.count - 1) else s.selected -| 1;
            for (s.rows[1..], 0..) |*row, i| {
                row.kind.row.selected = i == s.selected;
                row.markPaintDirty();
            }
            ui.widgets.scroll_container.ensureVisibleChild(&cc.body_children[1], &s.rows[s.selected + 1]);
        }
        cc.requestWidgetRepaint();
        return true;
    }
    if (s.active and k == .enter) {
        // Tab can leave the field: activate the focused clear button, category
        // or result rather than opening the arrow-key selection unexpectedly.
        if (!field_focused and ui.input.current.focused != null) {
            if (ui.input.current.focused) |widget| switch (widget.kind) {
                .button => |data| {
                    if (data.state != .disabled) if (data.on_click) |callback| callback(data.owner, data.id);
                },
                .row => |data| {
                    if (data.state != .disabled) if (data.on_click) |callback| callback(data.owner, data.id);
                },
                else => {},
            };
        } else if (s.count > 0) s.pending_result = s.matches[s.selected];
        if (cc.pending_page) |page| {
            cc.pending_page = null;
            cc.selectPage(page);
        } else apply(cc);
        cc.requestWidgetRepaint();
        return true;
    }
    if (s.active and k == .tab) {
        _ = ui.input.current.focusNext(&cc.root, shift);
        cc.requestWidgetRepaint();
        return true;
    }
    if (field_focused) {
        _ = ui.input.current.keyEvent(gpa, k, .{ .shift = shift }) catch {};
        cc.requestWidgetRepaint();
        return true;
    }
    return false;
}

fn find(root: *W, target: []const u8) ?*W {
    if (target.len == 0) return null;
    if (target[0] == '@') {
        if (root.kind == .text and std.mem.eql(u8, root.kind.text.content, target[1..])) return root;
    } else if (root.name) |name| {
        if (std.mem.eql(u8, name, target)) return root;
    }
    for (root.children) |*child| if (find(child, target)) |found| return found;
    return null;
}

/// Called after layout: reveal nested targets from the inside out, and paint
/// the containing row using the shared renderer. No control receives a click.
pub fn reveal(cc: *CC) void {
    const s = &cc.search;
    if (s.active) return;
    const id = s.destination orelse return;
    if (index.entries[id].target.len == 0) return;
    const target = find(&cc.body_children[1], index.entries[id].target) orelse {
        // A hardware-dependent control may be absent; its page still explains
        // the unavailable device. Never redirect to another setting.
        s.reveal = false;
        if (!s.unavailable) {
            s.unavailable = true;
            cc.refresh();
        }
        return;
    };
    if (s.unavailable) {
        s.unavailable = false;
        cc.refresh();
    }
    var row = target;
    if (target.parent) |parent| {
        if (parent.direction == .row or target.kind == .text) row = parent;
    }
    if (row.computed_height > cc.body_children[1].computed_height and target.kind == .text) row = target;
    row.underlay = .{ .owner = cc, .paint = paintDestination };
    if (!s.reveal) return;
    s.reveal = false;
    var ancestor = row.parent;
    while (ancestor) |parent| : (ancestor = parent.parent) {
        if (parent.kind == .scroll_container) ui.widgets.scroll_container.ensureVisibleChild(parent, row);
    }
}

fn paintDestination(_: ?*anyopaque, row: *const W, r: *ui.paint.Renderer) void {
    const t = r.palette orelse panel.palette();
    r.fillRect(row.computed_x, row.computed_y, row.computed_width, row.computed_height, .{
        .color = .{ t.accent[0], t.accent[1], t.accent[2], 0.10 },
        .radius = t.radius,
        .border_width = 1,
        .border_color = .{ t.accent[0], t.accent[1], t.accent[2], 0.7 },
    });
}

/// Dismiss the destination marker on the next content interaction without
/// rebuilding a page or changing a control under the pointer.
pub fn dismiss(cc: *CC) void {
    if (cc.search.destination == null) return;
    cc.search.destination = null;
    if (cc.search.unavailable) {
        cc.search.unavailable = false;
        cc.refresh();
    }
    removeMarker(&cc.body_children[1]);
}

fn removeMarker(root: *W) void {
    if (root.underlay) |under| if (under.paint == paintDestination) {
        root.underlay = null;
        root.markPaintDirty();
    };
    for (root.children) |*child| removeMarker(child);
}
