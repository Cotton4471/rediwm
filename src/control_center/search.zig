//! Global Settings search navigates directly to matching controls. The field
//! owns its text across page rebuilds; only the visible page is built.
const i18n = @import("i18n");
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
    clear_button: W = .{ .kind = .container },
    initialized: bool = false,
    focused: bool = false,
    request_focus: bool = false,
    expanded: bool = false,
    active: bool = false,
    built_empty: bool = false,
    matches: [index.entries.len]usize = undefined,
    count: usize = 0,
    services_available: bool = false,
    empty_children: [2]W = undefined,
    saved_scroll: ui.layout.ScrollState = .{},
    restore_scroll: bool = false,
    pending_result: ?usize = null,
    destination: ?usize = null,
    reveal: bool = false,
    unavailable: bool = false,
    reset_scroll: bool = false,

    pub fn deinit(s: *State) void {
        if (s.initialized) gpa.free(s.field.kind.text_input.value);
    }

    pub fn capture(s: *State) void {
        s.focused = s.initialized and ui.input.current.focused == &s.field;
    }

    pub fn buildToolbar(s: *State, cc: *CC) void {
        if (!s.initialized) {
            const value = gpa.dupe(u8, "") catch return;
            s.field = .{ .name = "settings_search", .kind = .{ .text_input = .{
                .field = .{ .leading_icon = .search, .leading_icon_size = 20 },
                .placeholder = i18n.tr("Search settings…"),
                .value = value,
                .owner = cc,
                .on_change = changed,
            } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } };
            s.initialized = true;
        }
        s.field.kind.text_input.placeholder = i18n.tr("Search settings…");
        const has_query = s.query().len > 0;
        s.clear_button = .{ .name = "settings_search_clear", .kind = .{ .button = .{ .label = i18n.tr("Clear search"), .icon = .close, .variant = .ghost, .owner = cc, .on_click = clearClicked } }, .width = .{ .fixed = 30 }, .height = .{ .fixed = 30 } };
        s.field.kind.text_input.field.trailing = if (has_query) .accessory else .none;
        s.field.direction = .row;
        s.field.justify = .end;
        s.field.@"align" = .center;
        s.field.padding.right = 3;
        s.field.children = if (has_query) (&s.clear_button)[0..1] else &.{};
        s.toolbar = .{ .kind = .container, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 }, .children = (&s.field)[0..1] };
    }

    pub fn query(s: *const State) []const u8 {
        return if (s.initialized) s.field.kind.text_input.value else "";
    }

    pub fn empty(s: *const State) bool {
        return s.active and s.count == 0;
    }

    pub fn firstInPage(s: *const State, page: index.Page) ?usize {
        for (s.matches[0..s.count]) |id| {
            if (index.entries[id].page == page) return id;
        }
        return null;
    }

    fn collect(s: *State, cc: *CC) void {
        s.services_available = if (cc.systemd_client) |client| client.available() else false;
        s.count = 0;
        var scores: [index.entries.len]u32 = undefined;
        for (index.entries, 0..) |entry, id| {
            if (entry.page == .services and !s.services_available) continue;
            const rank = index.scoreLocalized(id, s.query(), panel.pageLabel(@intFromEnum(entry.page))) orelse continue;
            var at = s.count;
            while (at > 0 and scores[at - 1] < rank) : (at -= 1) {
                scores[at] = scores[at - 1];
                s.matches[at] = s.matches[at - 1];
            }
            scores[at] = rank;
            s.matches[at] = id;
            s.count += 1;
        }
    }

    pub fn syncAvailability(s: *State, cc: *CC) void {
        const available = if (cc.systemd_client) |client| client.available() else false;
        if (!s.active or available == s.services_available) return;
        s.collect(cc);
        if (s.firstInPage(cc.page) == null) {
            s.pending_result = if (s.count > 0) s.matches[0] else null;
            s.destination = null;
            s.unavailable = false;
        }
        cc.refresh();
    }

    pub fn noResults(s: *State) W {
        s.empty_children = .{
            panel.sectionTitle(i18n.tr("No settings found")),
            .{ .kind = .{ .text = .{ .content = i18n.tr("Try a setting name, such as volume, wallpaper or scroll."), .font_size = panel.palette().settings_description_size, .color = panel.palette().dim } } },
        };
        return .{ .name = "settings_search_empty", .kind = .container, .direction = .column, .gap = 12, .children = &s.empty_children };
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
    s.collect(cc);
    s.pending_result = if (s.active and s.count > 0) s.matches[0] else null;
    s.request_focus = true;
    s.reset_scroll = s.active;
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
    s.pending_result = null;
    s.destination = null;
    s.unavailable = false;
    s.request_focus = true;
    cc.refresh();
}

pub fn apply(cc: *CC) void {
    const s = &cc.search;
    const id = s.pending_result orelse return;
    s.pending_result = null;
    if (id >= index.entries.len) return;
    // Navigation runs after widget dispatch, so no callback rebuilds its tree.
    s.built_empty = false;
    s.restore_scroll = false;
    s.destination = id;
    s.unavailable = false;
    s.reveal = true;
    cc.selectSearchPage(index.entries[id].page);
}

pub fn key(cc: *CC, k: ui.input.Key, shift: bool) bool {
    const s = &cc.search;
    if (cc.is_welcome or !s.initialized) return false;
    if (s.pending_result != null) apply(cc);
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
    if (s.active and field_focused and (k == .down or k == .up)) {
        const rows = cc.sidebar_children[1].children;
        for (rows, 0..) |row, i| {
            if (row.kind.row.id != @intFromEnum(cc.page)) continue;
            const next = if (k == .down) @min(i + 1, rows.len - 1) else i -| 1;
            s.pending_result = s.firstInPage(@enumFromInt(rows[next].kind.row.id));
            apply(cc);
            break;
        }
        cc.requestWidgetRepaint();
        return true;
    }
    if (s.active and k == .enter) {
        // Enter in the field keeps the revealed control unchanged. Tab can
        // reach the clear button and filtered navigation without losing search.
        if (field_focused) return true;
        if (ui.input.current.focused) |widget| {
            switch (widget.kind) {
                .button => |data| {
                    if (widget != &s.clear_button) return false;
                    if (data.on_click) |callback| callback(data.owner, data.id);
                },
                .row => |data| {
                    const nav = &cc.sidebar_children[1];
                    if (widget.parent != nav) return false;
                    if (data.on_click) |callback| callback(data.owner, data.id);
                },
                else => return false,
            }
            apply(cc);
            cc.requestWidgetRepaint();
            return true;
        }
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

fn find(root: *W, target: []const u8, heading: []const u8) ?*W {
    if (target.len == 0) return null;
    if (target[0] == '@') {
        if (root.kind == .text and std.mem.eql(u8, root.kind.text.content, heading)) return root;
    } else if (root.name) |name| {
        if (std.mem.eql(u8, name, target)) return root;
    }
    for (root.children) |*child| if (find(child, target, heading)) |found| return found;
    return null;
}

/// Called after layout: reveal nested targets from the inside out, and paint
/// the containing row using the shared renderer. No control receives a click.
pub fn reveal(cc: *CC) void {
    const s = &cc.search;
    removeMarker(&cc.body_children[1]);
    const id = s.destination orelse return;
    if (index.entries[id].target.len == 0) return;
    const target = find(&cc.body_children[1], index.entries[id].target, index.targetLabel(id)) orelse {
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
