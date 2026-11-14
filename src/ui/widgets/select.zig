//! A single-choice dropdown. Geometry is shared by painting and input; menus
//! stay inside the root panel and scroll when the options exceed its height.
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;

/// A page can refresh while its dropdown is open. Keep only a named control's
/// interaction, without retaining strings from the tree being destroyed.
pub const Saved = struct {
    name: [512]u8 = undefined,
    name_len: usize = 0,
    selected: ?usize = null,
    highlighted: usize = 0,
    first_visible: usize = 0,
    options: u64 = 0,
    owner: ?*anyopaque = null,
    id: usize = 0,
};

fn optionKey(labels: []const []const u8, disabled: []const usize, icons: []const layout.IconId) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (labels) |label| {
        const len = label.len;
        hash.update(std.mem.asBytes(&len));
        hash.update(label);
    }
    const count = labels.len;
    hash.update(std.mem.asBytes(&count));
    const disabled_count = disabled.len;
    hash.update(std.mem.asBytes(&disabled_count));
    hash.update(std.mem.sliceAsBytes(disabled));
    const icon_count = icons.len;
    hash.update(std.mem.asBytes(&icon_count));
    for (icons) |icon| {
        const tag: u32 = @backingInt(icon);
        hash.update(std.mem.asBytes(&tag));
    }
    return hash.final();
}

pub fn capture(root: *const Widget, saved: *Saved, focused: ?*const Widget) void {
    saved.* = .{};
    const widget = focused orelse return;
    if (widget.kind != .select or !widget.kind.select.open or widget.kind.select.disabled) return;
    // Focus must belong to this host's current tree.
    var top = widget;
    while (top.parent) |parent| top = parent;
    if (top != root) return;
    const name = widget.name orelse return;
    if (name.len == 0 or name.len > saved.name.len) return;
    @memcpy(saved.name[0..name.len], name);
    saved.name_len = name.len;
    const data = widget.kind.select;
    saved.selected = data.selected;
    saved.highlighted = data.highlighted;
    saved.first_visible = data.first_visible;
    saved.options = optionKey(data.labels, data.disabled_options, data.icons);
    saved.owner = data.owner;
    saved.id = data.id;
}

/// Restore after rebuilding the same page. Changed backend values or choices
/// invalidate the old menu; an unchanged menu can keep its uncommitted choice.
/// The host focuses the returned widget after resetting its input dispatcher.
pub fn restore(root: *Widget, saved: *const Saved) ?*Widget {
    if (saved.name_len == 0) return null;
    if (root.kind == .select) if (root.name) |name| {
        const data = &root.kind.select;
        if (std.mem.eql(u8, name, saved.name[0..saved.name_len]) and
            !data.disabled and data.selected == saved.selected and
            data.owner == saved.owner and data.id == saved.id and
            data.labels.len > saved.highlighted and
            optionKey(data.labels, data.disabled_options, data.icons) == saved.options)
        {
            data.open = true;
            data.highlighted = saved.highlighted;
            data.first_visible = @min(saved.first_visible, data.labels.len - 1);
            root.markPaintDirty();
            return root;
        }
    };
    for (root.children) |*child| if (restore(child, saved)) |widget| return widget;
    return null;
}

pub const padding: f32 = 5;
pub fn rowHeight() f32 {
    return @max(32, @import("../theme.zig").global.font_size * 1.2 + 14);
}
pub fn popupBounds(w: *const Widget) Widget.PaintBounds {
    var root = w;
    while (root.parent) |parent| root = parent;
    const below = @max(0, root.computed_y + root.computed_height - (w.computed_y + w.computed_height) - 6);
    const above = @max(0, w.computed_y - root.computed_y - 6);
    const desired = @as(f32, @floatFromInt(w.kind.select.labels.len)) * rowHeight() + padding * 2;
    const up = below < desired and above > below;
    const available = if (up) above else below;
    const rows = @max(0, @floor((available - padding * 2) / rowHeight()));
    const h = @min(desired, rows * rowHeight() + padding * 2);
    const width = @min(w.computed_width, root.computed_width);
    return .{ .x = std.math.clamp(w.computed_x, root.computed_x, root.computed_x + root.computed_width - width), .y = if (up) w.computed_y - 6 - h else w.computed_y + w.computed_height + 6, .w = width, .h = h };
}
pub fn visibleCount(w: *const Widget) usize {
    return @intFromFloat(@max(0, @floor((popupBounds(w).h - padding * 2) / rowHeight())));
}
pub fn optionAt(w: *const Widget, x: f32, y: f32) ?usize {
    const b = popupBounds(w);
    if (x < b.x + padding or x >= b.x + b.w - padding or y < b.y + padding) return null;
    if (y >= b.y + b.h - padding) return null;
    const row: usize = @intFromFloat(@floor((y - b.y - padding) / rowHeight()));
    if (row >= visibleCount(w)) return null;
    const index = w.kind.select.first_visible + row;
    return if (index < w.kind.select.labels.len) index else null;
}
pub fn open(w: *Widget) void {
    const d = &w.kind.select;
    if (d.disabled or d.labels.len == 0 or visibleCount(w) == 0) return;
    d.open = true;
    d.highlighted = @min(d.selected orelse 0, d.labels.len - 1);
    reveal(w);
    w.markPaintDirty();
}
pub fn close(w: *Widget) void {
    if (!w.kind.select.open) return;
    w.kind.select.open = false;
    w.markPaintDirty();
}
pub fn highlight(w: *Widget, index: usize) void {
    const d = &w.kind.select;
    if (d.labels.len == 0) return;
    const next = @min(index, d.labels.len - 1);
    if (d.highlighted == next) return;
    d.highlighted = next;
    reveal(w);
    w.markPaintDirty();
}
fn reveal(w: *Widget) void {
    const d = &w.kind.select;
    const count = @max(1, visibleCount(w));
    if (d.highlighted < d.first_visible) d.first_visible = d.highlighted;
    if (d.highlighted >= d.first_visible + count) d.first_visible = d.highlighted + 1 - count;
    d.first_visible = @min(d.first_visible, d.labels.len -| count);
}
pub fn commit(w: *Widget, index: usize) void {
    const d = &w.kind.select;
    if (d.disabled or index >= d.labels.len or std.mem.indexOfScalar(usize, d.disabled_options, index) != null) return;
    const changed = d.notify_on_reselect or d.selected == null or d.selected.? != index;
    const callback = d.on_change;
    const owner = d.owner;
    const id = d.id;
    d.selected = index;
    close(w);
    w.markPaintDirty();
    // Last operation: the callback is allowed to destroy this tree.
    if (changed) if (callback) |cb| cb(owner, id, index);
}

/// Wheel input scrolls the viewport immediately, independently of the hover.
pub fn scroll(w: *Widget, delta: f32) void {
    const d = &w.kind.select;
    const count = @max(1, visibleCount(w));
    const max_first = d.labels.len -| count;
    const first = if (delta > 0) @min(max_first, d.first_visible +| 1) else d.first_visible -| 1;
    if (delta == 0 or first == d.first_visible) return;
    d.first_visible = first;
    d.highlighted = std.math.clamp(d.highlighted, first, @min(d.labels.len, first + count) -| 1);
    w.markPaintDirty();
}

test "an open dropdown survives destruction of its old page and commits its highlighted choice" {
    const input = @import("../input.zig");
    const Fixture = struct {
        selected: ?usize = null,
        calls: usize = 0,
        fn changed(raw: ?*anyopaque, _: usize, index: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.selected = index;
            self.calls += 1;
        }
    };
    var fixture: Fixture = .{};
    var saved: Saved = .{};
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const children = try a.alloc(Widget, 1);
        children[0] = .{ .name = try a.dupe(u8, "notify:alpha.service"), .kind = .{ .select = .{
            .labels = &.{ "simple", "notify", "oneshot", "idle" },
            .selected = 2,
            .highlighted = 1,
            .first_visible = 1,
            .open = true,
            .owner = &fixture,
            .on_change = Fixture.changed,
        } } };
        var old: Widget = .{ .kind = .container, .children = children };
        old.linkParents();
        capture(&old, &saved, &children[0]);
    }
    var children = [_]Widget{.{ .name = "notify:alpha.service", .kind = .{ .select = .{
        .labels = &.{ "simple", "notify", "oneshot", "idle" },
        .selected = 2,
        .owner = &fixture,
        .on_change = Fixture.changed,
    } } }};
    var rebuilt: Widget = .{ .kind = .container, .children = &children };
    rebuilt.linkParents();
    const restored = restore(&rebuilt, &saved).?;
    try std.testing.expect(restored.kind.select.open);
    try std.testing.expectEqual(@as(?usize, 2), restored.kind.select.selected);
    try std.testing.expectEqual(@as(usize, 1), restored.kind.select.first_visible);
    var dispatcher: input.Dispatcher = .{};
    dispatcher.focus(&rebuilt, restored);
    _ = try dispatcher.keyEvent(std.testing.allocator, .enter, .{});
    try std.testing.expectEqual(@as(?usize, 1), fixture.selected);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!restored.kind.select.open);
}

test "a refreshed dropdown keeps authoritative values and refuses incompatible saved menus" {
    var old: Widget = .{ .name = "choice", .kind = .{ .select = .{ .labels = &.{ "A", "B" }, .selected = 0, .highlighted = 1, .open = true } } };
    var saved: Saved = .{};
    capture(&old, &saved, &old);
    var changed: Widget = .{ .name = "choice", .kind = .{ .select = .{ .labels = &.{ "A", "B" }, .selected = 1 } } };
    try std.testing.expect(restore(&changed, &saved) == null);
    try std.testing.expectEqual(@as(?usize, 1), changed.kind.select.selected);
    changed.kind.select.selected = 0;
    changed.kind.select.labels = &.{ "B", "A" };
    try std.testing.expect(restore(&changed, &saved) == null);
    changed.kind.select.labels = &.{ "A", "B" };
    changed.kind.select.disabled_options = &.{1};
    try std.testing.expect(restore(&changed, &saved) == null);
    changed.kind.select.disabled_options = &.{};
    changed.kind.select.icons = &.{ .mouse, .touchpad };
    try std.testing.expect(restore(&changed, &saved) == null);
    changed.kind.select.icons = &.{};
    changed.kind.select.disabled = true;
    try std.testing.expect(restore(&changed, &saved) == null);
    changed.kind.select.disabled = false;
    changed.name = "other";
    try std.testing.expect(restore(&changed, &saved) == null);
}
