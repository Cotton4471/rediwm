//! Keyboard: activating results, key handling, query editing and result navigation.

const i18n = @import("i18n");
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const Output = @import("../Output.zig");
const ui = @import("ui");
const clipboard = @import("../clipboard.zig");
const launch = @import("launch.zig");
const model_mod = @import("model.zig");
const Category = model_mod.Category;
const log = std.log.scoped(.start_menu);
const StartMenu = @import("StartMenu.zig");

pub fn activateSelected(menu: *StartMenu) void {
    if (menu.card_selection) |i| {
        if (i < menu.card_count) menu.activateResult(menu.card_indices[i]);
        return;
    }
    if (menu.model.selected_index < menu.model.results.len) {
        menu.activateResult(menu.model.selected_index);
    }
}

pub fn activateResult(menu: *StartMenu, index: usize) void {
    if (index >= menu.model.results.len or menu.model.launching) return;
    const result = menu.model.results[index];

    if (result.is_loading) return;

    if (result.is_settings) {
        if (Output.fromWlr(menu.wlr_output)) |output| {
            output.closeStartMenu();
            output.toggleControlCenter();
        }
        return;
    }

    if (result.app_entry) |entry| {
        menu.model.launching = true;
        launch.launch(gpa, menu.server, entry) catch |err| {
            menu.model.launching = false;
            log.err("launch failed: {s}", .{@errorName(err)});
            menu.model.error_msg = i18n.tr("Launch failed. The application may have been removed.");
            menu.buildTree();
            menu.requestRepaint();
            return;
        };

        // Spawn successful: close start menu
        if (Output.fromWlr(menu.wlr_output)) |output| {
            output.closeStartMenu();
        }
    }
}

pub fn handleKey(
    menu: *StartMenu,
    keysym: xkb.Keysym,
    state: wl.Keyboard.KeyState,
    utf8: ?[]const u8,
    mods: wlr.Keyboard.ModifierMask,
) bool {
    const edit_mods = ui.input.Mods{ .shift = mods.shift };
    if (state == .released) return true;

    // Left/right navigate the quick-launch strip; typing returns to search.
    if (menu.card_selection) |selected| {
        if (keysym == xkb.Keysym.Left or keysym == xkb.Keysym.Right) {
            menu.card_selection = if (keysym == xkb.Keysym.Left) selected -| 1 else @min(selected + 1, menu.card_count - 1);
            menu.buildTree();
            menu.requestRepaint();
            return true;
        }
    }
    // Pressed:
    switch (keysym) {
        xkb.Keysym.Escape => {
            if (Output.fromWlr(menu.wlr_output)) |output| output.closeStartMenu();
            return true;
        },
        xkb.Keysym.Return => {
            menu.activateSelected();
            return true;
        },
        xkb.Keysym.Up => {
            menu.navigateResults(-1);
            return true;
        },
        xkb.Keysym.Down => {
            menu.navigateResults(1);
            return true;
        },
        xkb.Keysym.Page_Up => {
            menu.navigateResults(-5);
            return true;
        },
        xkb.Keysym.Page_Down => {
            menu.navigateResults(5);
            return true;
        },
        xkb.Keysym.Tab => {
            if (menu.mode == .launcher) {
                menu.card_selection = if (menu.card_selection == null and menu.card_count > 0) 0 else null;
                menu.buildTree();
                menu.requestRepaint();
                return true;
            }
            // Cycle category
            const next_cat: Category = if (menu.model.category == .all) .apps else .all;
            const snap = menu.server.start_menu_catalog.retainSnapshot();
            defer snap.release();
            menu.model.setCategorySnapshot(next_cat, snap) catch {};
            menu.syncQueryState();
            menu.buildTree();
            menu.requestRepaint();
            return true;
        },
        xkb.Keysym.BackSpace => return menu.editKey(.backspace, edit_mods),
        xkb.Keysym.Delete => return menu.editKey(.delete, edit_mods),
        xkb.Keysym.Left => return menu.editKey(.left, edit_mods),
        xkb.Keysym.Right => return menu.editKey(.right, edit_mods),
        xkb.Keysym.Home => return menu.editKey(.home, edit_mods),
        xkb.Keysym.End => return menu.editKey(.end, edit_mods),
        else => {
            if (mods.ctrl) {
                // Match on the *unshifted* keysym so Ctrl+Shift+A is still
                // select-all, and accept both cases for layouts that
                // report them differently.
                switch (keysym) {
                    xkb.Keysym.a, xkb.Keysym.A => return menu.editKey(.select_all, edit_mods),
                    xkb.Keysym.c, xkb.Keysym.C => return menu.editKey(.copy, edit_mods),
                    xkb.Keysym.x, xkb.Keysym.X => return menu.editKey(.cut, edit_mods),
                    xkb.Keysym.v, xkb.Keysym.V => {
                        // Asynchronous: the text arrives from the seat's
                        // selection source down a pipe, and comes back
                        // through `onPasted` as a `.paste` key.
                        clipboard.requestText(menu.server, *StartMenu, onPasted, menu);
                        return true;
                    },
                    else => return false,
                }
            }
            if (utf8) |txt| {
                if (txt.len > 0 and txt[0] >= 32) {
                    return menu.editKey(.{ .char = txt }, edit_mods);
                }
            }
        },
    }
    return false;
}

/// Which held keys `Keyboard` repeats into the menu: typing and caret
/// keys in the search box, and moving through the results. Home/End are
/// already at the extremes; Return, Escape and Tab are actions.
pub fn keyRepeats(_: *const StartMenu, keysym: xkb.Keysym, utf8: []const u8) bool {
    const repeat_keys = @import("../input/repeat_keys.zig");
    return repeat_keys.editing(keysym, utf8) or repeat_keys.navigation(keysym);
}

/// Runs one editing key against the focused field, then does whatever it
/// asked for: put text on the clipboard, rebuild the results if the value
/// changed, or just repaint if only the caret moved.
pub fn editKey(menu: *StartMenu, key: ui.input.Key, mods: ui.input.Mods) bool {
    const allocator = menu.tree_arena.allocator();
    const outcome = menu.dispatcher.keyEvent(allocator, key, mods) catch return true;
    // Before any rebuild: this is arena memory, and `onQueryEdited` is
    // about to reset the arena under it. `copyText` keeps its own copy.
    if (outcome.copy) |text| {
        defer allocator.free(text);
        clipboard.copyText(menu.server, text);
    }
    menu.syncQueryState();
    if (editsValue(key)) menu.onQueryEdited() else menu.requestRepaint();
    return true;
}

pub fn editsValue(key: ui.input.Key) bool {
    return switch (key) {
        .char, .paste, .backspace, .delete, .cut => true,
        else => false,
    };
}

/// Copies the caret and selection out of the widget, which the next
/// `buildTree` will destroy, and into the menu, which outlives it.
pub fn syncQueryState(menu: *StartMenu) void {
    const focused = menu.dispatcher.focused orelse return;
    if (std.meta.activeTag(focused.kind) != .text_input) return;
    menu.query_cursor = focused.kind.text_input.cursor_pos;
    menu.query_anchor = focused.kind.text_input.selection_anchor;
}

/// Clipboard text arriving some frames after the Ctrl+V that asked for
/// it. The menu may be gone by then; `clipboard` drops the request when
/// its owner is destroyed, so reaching here means it is still alive.
pub fn onPasted(menu: *StartMenu, text: []const u8) void {
    if (text.len == 0) return;
    // Newlines would be invisible in a one-line field and a tab would
    // read as a category switch; take the first line, as GTK does.
    const first_line = text[0 .. std.mem.indexOfAny(u8, text, "\r\n") orelse text.len];
    if (first_line.len == 0) return;
    _ = menu.editKey(.{ .paste = first_line }, .{});
}

pub fn navigateResults(menu: *StartMenu, delta: isize) void {
    const was_card = menu.card_selection != null;
    menu.card_selection = null;
    if (menu.model.moveSelection(delta) or was_card) {
        menu.sel_pos.retargetTo(anim.nowMs(), @floatFromInt(menu.model.selected_index), anim.curveFor(.start_glide));
        menu.syncQueryState();
        menu.buildTree();
        menu.ensureSelectedVisible();
        menu.requestRepaint();
    }
}

pub fn ensureSelectedVisible(menu: *StartMenu) void {
    // Find scroll container and ensure selected row is visible
    const root_kids = menu.root.children;
    for (root_kids) |*kid| {
        if (std.meta.activeTag(kid.kind) == .scroll_container) {
            if (menu.model.selected_index < kid.children.len) {
                const row_child = &kid.children[menu.model.selected_index];
                ui.widgets.scroll_container.ensureVisibleChild(kid, row_child);
            }
            break;
        }
    }
}

pub fn onQueryEdited(menu: *StartMenu) void {
    menu.card_selection = null;
    // Read text input value back into model
    if (menu.dispatcher.focused) |focused| {
        if (std.meta.activeTag(focused.kind) == .text_input) {
            const val = focused.kind.text_input.value;
            const snap = menu.server.start_menu_catalog.retainSnapshot();
            defer snap.release();
            menu.model.setQuerySnapshot(val, snap) catch {};
            menu.buildTree();
            menu.requestRepaint();
        }
    }
}

pub fn onQueryChanged(_: ?*anyopaque, _: usize, _: []const u8) void {}
