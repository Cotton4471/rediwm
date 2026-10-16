//! Files clipboard and file operations: copy, cut, paste, size and delete.

const std = @import("std");
const App = @import("app.zig").App;
const recent = @import("recent.zig");
const ops_mod = @import("ops.zig");
const clipboard_mod = @import("clipboard.zig");
const deletion = @import("../delete_dialog.zig");

pub fn copySelected(self: *App) void {
    if (self.history.archive_len > 0) return;
    if (!self.hasSelection()) return;
    self.clipboard_is_text = false;
    self.clearClipboard();
    for (self.items.items) |it| {
        if (it.selected and !it.missing) {
            self.clipboard_paths.append(self.allocator, self.allocator.dupe(u8, it.path) catch continue) catch continue;
        }
    }
    if (self.clipboard_paths.items.len > 0) {
        self.clipboard_cut = false;
        self.clipboard_revision += 1;
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Copied {d} item(s)", .{self.clipboard_paths.items.len}) catch "Copied";
        self.setStatusNotice(msg, false);
        self.invalidate();
    }
}

pub fn cutSelected(self: *App) void {
    if (self.history.archive_len > 0) return;
    if (!self.hasSelection()) return;
    self.clipboard_is_text = false;
    self.clearClipboard();
    for (self.items.items) |it| {
        if (it.selected and !it.missing) {
            self.clipboard_paths.append(self.allocator, self.allocator.dupe(u8, it.path) catch continue) catch continue;
        }
    }
    if (self.clipboard_paths.items.len > 0) {
        self.clipboard_cut = true;
        self.clipboard_revision += 1;
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Cut {d} item(s)", .{self.clipboard_paths.items.len}) catch "Cut";
        self.setStatusNotice(msg, false);
        self.invalidate();
    }
}

pub fn calculateSizeSelected(self: *App) void {
    if (self.history.archive_len > 0) return;
    var any = false;
    for (self.items.items, 0..) |it, idx| {
        if (it.selected and it.is_dir and !it.is_symlink) {
            self.startFolderSize(idx);
            any = true;
        }
    }
    if (!any) {
        if (self.focused_index) |idx| {
            if (idx < self.items.items.len) {
                const it = self.items.items[idx];
                if (it.is_dir and !it.is_symlink) {
                    self.startFolderSize(idx);
                }
            }
        }
    }
}

pub fn executePaste(self: *App, kind: ops_mod.OpKind, paths: []const []const u8) bool {
    if (self.isRecent()) return false;
    return self.executeTransfer(kind, paths, self.history.current, true);
}

pub fn executeTransfer(self: *App, kind: ops_mod.OpKind, paths: []const []const u8, directory: []const u8, clipboard: bool) bool {
    if (self.history.archive_len > 0 or recent.isLocation(directory)) return false;
    if (paths.len == 0) return false;
    const runner = self.job_runner orelse return false;
    runner.start(kind, paths, directory, .ask) catch {
        self.setStatusNotice("Failed to start transfer job", true);
        return false;
    };
    self.job_cut_revision = if (clipboard and kind == .move and self.clipboard_cut) self.clipboard_revision else null;
    self.job_was_running = true;
    self.invalidate();
    return true;
}

pub fn executePasteLocal(self: *App) void {
    if (self.clipboard_paths.items.len == 0) return;
    const kind: ops_mod.OpKind = if (self.clipboard_cut) .move else .copy;
    _ = self.executePaste(kind, self.clipboard_paths.items);
}

pub fn executePasteExternal(self: *App, mode: clipboard_mod.ClipboardMode, paths: []const []const u8) void {
    const kind: ops_mod.OpKind = if (mode == .cut) .move else .copy;
    if (!self.executePaste(kind, paths)) return;
    // Retain external cut entries too; completion republishes only remaining items.
    if (mode == .cut) {
        self.clearClipboard();
        for (paths) |path| {
            const owned = self.allocator.dupe(u8, path) catch continue;
            self.clipboard_paths.append(self.allocator, owned) catch self.allocator.free(owned);
        }
        self.clipboard_cut = true;
        self.clipboard_is_text = false;
        self.clipboard_revision += 1;
        self.job_cut_revision = self.clipboard_revision;
    }
}

pub fn deleteAction(self: *App, action: deletion.Action) void {
    switch (action) {
        .cancel => self.closeDialog(),
        .confirm => self.confirmDialog(),
        .toggle => {
            if (self.dialog.?.deletion.empty_trash) return;
            self.dialog.?.deletion.permanent = !self.dialog.?.deletion.permanent;
            self.dialog.?.deletion.focus = .toggle;
        },
        .none => {},
    }
    self.invalidate();
}

pub fn executeDeletion(self: *App) void {
    const state = &self.dialog.?.deletion;
    const result = if (state.empty_trash) ops_mod.emptyTrash(self.io) else if (state.permanent) ops_mod.deleteItems(self.io, state.paths.items) else ops_mod.trashItems(self.io, state.paths.items);
    result catch |err| {
        self.setStatusNotice(if (state.empty_trash) "Could not empty Trash" else if (state.permanent) "Could not delete all items" else if (err == error.GioNotAvailable) "Trash unavailable (gio not installed)" else "Could not move all items to Trash", true);
        self.refresh();
        return;
    };
    self.setStatusNotice(if (state.empty_trash) "Trash emptied" else if (state.permanent) "Items permanently deleted" else "Items moved to Trash", false);
    self.refresh();
}
