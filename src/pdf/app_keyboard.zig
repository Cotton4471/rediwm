//! PDF viewer keyboard input and actions.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig");
const a = @import("app.zig").a;
const Action = @import("app.zig").Action;

pub fn triggerAction(self: *App, act: Action) void {
    switch (act) {
        .toggle_sidebar => {
            self.sidebar_open = !self.sidebar_open;
            if (self.zoom_mode != .manual) self.updateEffectiveZoom();
            self.relayout();
        },
        .prev_page => {
            if (self.current_page > 0) self.goToPage(self.current_page - 1);
        },
        .next_page => {
            if (self.current_page + 1 < self.n_pages) self.goToPage(self.current_page + 1);
        },
        .zoom_out => self.zoomBy(1.0 / 1.2),
        .zoom_in => self.zoomBy(1.2),
        .fit_width => self.setZoomMode(.fit_width),
        .fit_page => self.setZoomMode(.fit_page),
        .rotate => {
            self.rotation = self.rotation.rotateClockwise();
            if (self.zoom_mode != .manual) self.updateEffectiveZoom();
            self.relayout();
        },
        .open_dialog => {
            self.dialog = .information;
            self.focus = .none;
            self.error_message = tr("Open another PDF from Files in a new window.");
        },
        .find_toggle => {
            self.search_open = !self.search_open;
            if (self.search_open) {
                self.focus = .search;
            } else {
                self.focus = .none;
            }
        },
        .find_prev => {
            if (self.search_matches.items.len > 0) {
                self.scrollToMatch(if (self.search_match_idx == 0) self.search_matches.items.len - 1 else self.search_match_idx - 1);
            }
        },
        .find_next => {
            if (self.search_matches.items.len > 0) {
                self.scrollToMatch(self.search_match_idx + 1);
            }
        },
        .find_close => {
            self.search_open = false;
            self.focus = .none;
        },
        .print => if (self.n_pages > 0 and !self.loading) {
            self.print_request = true;
        },
    }
    self.dirty = true;
}

pub fn handleKey(self: *App, sym: u32, utf8: []const u8) void {
    // Ctrl+W closes immediately regardless of focus
    if (self.ctrl and (sym == 'w' or sym == 'W')) {
        self.closed = true;
        return;
    }

    // Esc clears modal dialogs, search, or selection
    if (sym == 0xff1b) { // Escape
        if (self.dialog != .none) {
            self.dialog = .none;
            self.focus = .none;
            self.password_input.clear();
        } else if (self.search_open) {
            self.search_open = false;
            self.focus = .none;
        } else if (self.selection_active or self.selection_dragging) {
            self.selection_active = false;
            self.selection_dragging = false;
            self.selection_page = null;
            self.selection_range = null;
            self.clearSelectionText();
        }
        self.dirty = true;
        return;
    }

    // Active text fields
    switch (self.focus) {
        .page_number => {
            if (sym == 0xff0d) { // Enter
                const txt = self.editor.text.items;
                if (std.fmt.parseInt(usize, txt, 10)) |num| {
                    if (num >= 1) self.goToPage(num - 1);
                } else |_| {}
                self.focus = .none;
                self.dirty = true;
                return;
            }
            self.editor.key(a, sym, utf8, self.ctrl, self.shift, self.alt);
            self.dirty = true;
            return;
        },
        .password => {
            if (sym == 0xff0d) { // Enter
                self.submitPassword();
                return;
            } else if (sym == 0xff08) { // Backspace
                self.password_input.backspace();
                self.dirty = true;
                return;
            } else if (utf8.len > 0) {
                _ = self.password_input.insert(utf8);
                self.dirty = true;
                return;
            }
            return;
        },
        .search => {
            if (sym == 0xff0d) { // Enter
                if (self.shift) {
                    self.triggerAction(.find_prev);
                } else {
                    self.triggerAction(.find_next);
                }
                return;
            }
            self.search_editor.key(a, sym, utf8, self.ctrl, self.shift, self.alt);
            self.executeSearch();
            self.dirty = true;
            return;
        },
        .none => {},
    }

    // Global / reader shortcuts
    if (self.ctrl) {
        switch (sym) {
            'w', 'W' => self.closed = true,
            'o', 'O' => self.triggerAction(.open_dialog),
            'f', 'F' => self.triggerAction(.find_toggle),
            'p', 'P' => self.triggerAction(.print),
            'l', 'L' => {
                self.focus = .page_number;
                self.editor.text.clearRetainingCapacity();
                var buf: [16]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{self.current_page + 1}) catch "";
                self.editor.insert(a, str) catch {};
                self.dirty = true;
            },
            'c', 'C' => {
                if (if (self.selection_active) self.selected_text else null) |txt| {
                    if (self.clipboard_text) |c_prev| a.free(c_prev);
                    self.clipboard_text = a.dupeSentinel(u8, txt, 0) catch null;
                    self.clipboard_request = true;
                }
            },
            0xff50 => self.goToPage(0), // Ctrl+Home
            0xff57 => if (self.n_pages > 0) self.goToPage(self.n_pages - 1), // Ctrl+End
            '+', '=' => self.triggerAction(.zoom_in),
            '-', '_' => self.triggerAction(.zoom_out),
            else => {},
        }
        return;
    }

    switch (sym) {
        'r', 'R' => self.triggerAction(.rotate),
        '+', '=' => self.triggerAction(.zoom_in),
        '-' => self.triggerAction(.zoom_out),
        '0' => self.triggerAction(.fit_width),
        '9' => self.triggerAction(.fit_page),
        0xffbe => { // F3
            if (self.shift) {
                self.triggerAction(.find_prev);
            } else {
                self.triggerAction(.find_next);
            }
        },
        0xff55 => self.triggerAction(.prev_page), // PageUp
        0xff56 => self.triggerAction(.next_page), // PageDown
        ' ' => {
            if (self.shift) {
                self.scrollViewport(-1.0);
            } else {
                self.scrollViewport(1.0);
            }
        },
        // Left/Right pan while the pages overflow horizontally, otherwise turn pages.
        0xff51 => if (self.maxScrollX() > 0) self.handleHorizontalScroll(-2.0) else self.triggerAction(.prev_page),
        0xff53 => if (self.maxScrollX() > 0) self.handleHorizontalScroll(2.0) else self.triggerAction(.next_page),
        'p', 'P' => self.triggerAction(.prev_page),
        'n', 'N' => self.triggerAction(.next_page),
        0xff52 => self.handleScroll(-2.0), // Up arrow
        0xff54 => self.handleScroll(2.0), // Down arrow
        0xff50 => self.goToPage(0), // Home
        0xff57 => if (self.n_pages > 0) self.goToPage(self.n_pages - 1), // End
        else => {},
    }
}

pub fn keyRepeats(self: *const App, sym: u32, _: []const u8) bool {
    if (self.focus != .none) return false;
    return switch (sym) {
        0xff51, 0xff52, 0xff53, 0xff54, 0xff55, 0xff56, ' ', '+', '-', '=', 0xffbe => true,
        else => false,
    };
}
