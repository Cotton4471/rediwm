//! Dispatcher key handling: focus traversal, activation and text editing keys.

const std = @import("std");
const Allocator = std.mem.Allocator;
const anim = @import("anim.zig");
const text_input_widget = @import("widgets/text_input.zig");
const select_widget = @import("widgets/select.zig");
const input_mod = @import("input.zig");
const Dispatcher = input_mod.Dispatcher;
const Key = input_mod.Key;
const Mods = input_mod.Mods;
const KeyOutcome = input_mod.KeyOutcome;

pub fn keyEvent(self: *Dispatcher, allocator: Allocator, key: Key, mods: Mods) !KeyOutcome {
    const widget = self.focused orelse return .{};
    if (widget.kind == .select) {
        if (widget.kind.select.disabled) return .{};
        switch (key) {
            .escape, .tab => select_widget.close(widget),
            .enter => if (widget.kind.select.open) {
                select_widget.commit(widget, widget.kind.select.highlighted);
            } else {
                select_widget.open(widget);
            },
            .char => |chars| {
                if (std.mem.eql(u8, chars, " ")) {
                    if (widget.kind.select.open) select_widget.commit(widget, widget.kind.select.highlighted) else select_widget.open(widget);
                } else if (chars.len > 0) {
                    if (!widget.kind.select.open) select_widget.open(widget);
                    const d = widget.kind.select;
                    for (0..d.labels.len) |offset| {
                        const i = (d.highlighted + 1 + offset) % d.labels.len;
                        if (std.ascii.startsWithIgnoreCase(d.labels[i], chars)) {
                            select_widget.highlight(widget, i);
                            break;
                        }
                    }
                }
            },
            .up, .down, .home, .end, .page_up, .page_down => {
                if (!widget.kind.select.open) {
                    select_widget.open(widget);
                    return .{};
                }
                const d = widget.kind.select;
                const next = switch (key) {
                    .up => d.highlighted -| 1,
                    .down => d.highlighted +| 1,
                    .home => 0,
                    .end => d.labels.len -| 1,
                    .page_up => d.highlighted -| select_widget.visibleCount(widget),
                    else => d.highlighted +| select_widget.visibleCount(widget),
                };
                select_widget.highlight(widget, next);
            },
            else => {},
        }
        return .{};
    }
    if (widget.kind == .secret_input) {
        const input = widget.kind.secret_input.input;
        self.caret.noteEdit(anim.nowMs());
        switch (key) {
            .char => |utf8| _ = input.insert(utf8),
            .backspace => input.backspace(),
            .delete => input.delete(),
            .left => input.left(),
            .right => input.right(),
            .home => input.cursor = 0,
            .end, .select_all => input.cursor = input.len,
            // Secret values never use the clipboard.
            .copy, .cut, .paste => return .{},
            .enter, .up, .down, .page_up, .page_down, .tab, .escape => return .{},
        }
        widget.markDirty();
        return .{};
    }
    if (std.meta.activeTag(widget.kind) != .text_input) return .{};
    // Before the edit: `insertText` and friends call `on_change`, which is
    // what rebuilds the start menu's tree, and the rebuild must already
    // see the caret held solid.
    const now = anim.nowMs();
    switch (key) {
        // These land somewhere unrelated to where the caret was, so they
        // snap rather than sweeping the width of the field.
        .home, .end, .select_all => self.caret.noteJump(now),
        .char, .paste => self.caret.noteInsert(now),
        .backspace, .delete, .left, .right, .cut => self.caret.noteEdit(now),
        .copy, .enter, .up, .down, .page_up, .page_down, .tab, .escape => {},
    }
    switch (key) {
        .char => |utf8| try text_input_widget.insertText(allocator, widget, utf8),
        .paste => |utf8| try text_input_widget.insertText(allocator, widget, utf8),
        .backspace => try text_input_widget.backspace(allocator, widget),
        .delete => try text_input_widget.deleteForward(allocator, widget),
        .left => text_input_widget.moveCursorLeft(widget, mods.shift),
        .right => text_input_widget.moveCursorRight(widget, mods.shift),
        .home => text_input_widget.moveCursorHome(widget, mods.shift),
        .end => text_input_widget.moveCursorEnd(widget, mods.shift),
        .select_all => text_input_widget.selectAll(widget),
        // Null, not an empty slice: Ctrl+C or Ctrl+X with nothing selected
        // must leave the clipboard alone rather than blanking it, and that
        // is easier to get right here than at every caller.
        .copy => {
            const selected = widget.kind.text_input.selectedText();
            if (selected.len == 0) return .{};
            return .{ .copy = try allocator.dupe(u8, selected) };
        },
        .cut => {
            // Duplicated before the delete, which frees the buffer the
            // selection points into.
            const selected = widget.kind.text_input.selectedText();
            if (selected.len == 0) return .{};
            const owned = try allocator.dupe(u8, selected);
            errdefer allocator.free(owned);
            _ = try text_input_widget.deleteSelection(allocator, widget);
            return .{ .copy = owned };
        },
        .enter, .up, .down, .page_up, .page_down, .tab, .escape => {},
    }
    return .{};
}
