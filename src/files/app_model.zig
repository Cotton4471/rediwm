//! Files view model: the enums and records the App and its parts share.

const std = @import("std");
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const git = @import("git.zig");
const dirsize = @import("dirsize.zig");
const deletion = @import("../delete_dialog.zig");
const header = @import("header.zig");
const IconId = @import("ui").layout.IconId;
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const Editor = @import("editor.zig").Editor;

pub const DeviceOp = struct { id: []u8, unmount: bool, open: bool, navigation: u32 };

pub const MenuKind = enum { new, sort, filter, file, background, sidebar, device, chooser_filter };
pub const PlaceAction = enum {
    open,
    open_window,
    empty_trash,
    unpin,
    remove_pin,
    properties,
    mount,
    eject,

    pub fn label(self: PlaceAction) []const u8 {
        return switch (self) {
            .open => "Open",
            .open_window => "Open in New Window",
            .empty_trash => "Empty Trash…",
            .unpin => "Unpin",
            .remove_pin => "Remove from Places",
            .properties => "Properties",
            .mount => "Mount",
            .eject => "Eject",
        };
    }
};
pub const FileAction = enum {
    open,
    open_with,
    extract,
    extract_to,
    cut,
    copy,
    paste,
    rename,
    trash,
    size,
    properties,
    pub fn label(self: FileAction) []const u8 {
        return switch (self) {
            .open => "Open",
            .open_with => "Open With…",
            .extract => "Extract",
            .extract_to => "Extract to…",
            .cut => "Cut",
            .copy => "Copy",
            .paste => "Paste",
            .rename => "Rename",
            .trash => "Move to Trash",
            .size => "Calculate size",
            .properties => "Properties",
        };
    }
    pub fn icon(self: FileAction) IconId {
        return switch (self) {
            .open => .chevron_right,
            .open_with => .grid,
            .extract, .extract_to => .folder,
            .cut => .cut,
            .copy => .copy,
            .paste => .paste,
            .rename => .edit,
            .trash => .trash,
            .size, .properties => .view_list,
        };
    }
};
pub const Sort = enum { name, name_desc, size, modified, type, size_asc, modified_asc, type_desc };

pub const SizeState = union(enum) {
    running: *dirsize.Job,
    done: struct {
        bytes: i64,
        partial: bool,
    },
};

pub const SelectionFade = @import("ui").hover_glide.Fade;

// Titlebar timing, with a rectangle that also fits labelled toolbar buttons.
pub const ToolbarHover = struct {
    geometry: [4]anim.Anim = @splat(.{}),
    alpha: anim.Anim = .{ .property = .opacity },
    frame: [4]f32 = @splat(0),
    opacity: f32 = 0,

    pub fn step(self: *ToolbarHover, now: i64, target: ?header.Rect, pixel: f32) bool {
        if (target) |r| {
            const values = [4]f32{ @floatCast(r.x), @floatCast(r.y), @floatCast(r.w), @floatCast(r.h) };
            for (&self.geometry, values) |*a, value| {
                if (self.alpha.value(now) <= 0.01) a.cancel(value) else if (a.to != value)
                    a.retargetTo(now, value, anim.curveFor(.titlebar_chip));
            }
        }
        const opacity: f32 = if (target != null) 1 else 0;
        if (self.alpha.to != opacity) self.alpha.retargetTo(now, opacity, anim.curveFor(.titlebar_chip_fade));
        const old_frame = self.frame;
        const old_opacity = self.opacity;
        for (&self.geometry, &self.frame) |*a, *value| {
            value.* = if (a.settled(now)) a.value(now) else @round(a.value(now) / pixel) * pixel;
        }
        const quantum = anim.rasterAlphaQuantum();
        self.opacity = if (self.alpha.settled(now)) self.alpha.value(now) else @round(self.alpha.value(now) / quantum) * quantum;
        return (old_opacity > 0 or self.opacity > 0) and
            (old_opacity != self.opacity or !std.meta.eql(old_frame, self.frame));
    }

    pub fn active(self: ToolbarHover, now: i64) bool {
        if (!self.alpha.settled(now)) return true;
        for (self.geometry) |a| if (!a.settled(now)) return true;
        return false;
    }
};

pub const ViewItem = struct {
    git_status: git.Status = .clean,
    git_lines: ?git.LineCounts = null,
    missing: bool = false,
    name: []const u8,
    /// Path from the listed folder, shown instead of `name` in the Git view's
    /// flat list. `name` stays the file's own name: renaming and opening use it.
    label: []const u8 = "",
    path: []const u8,
    is_dir: bool,
    is_symlink: bool,
    is_broken: bool,
    bytes: i64,
    mtime: i64,
    opened: i64 = 0,
    mode: c.mode_t = 0,
    permissions_text: []const u8 = "",
    icon_name: []const u8,
    icon_candidates: []const []const u8 = &.{},
    selected: bool = false,
    selection_fill: SelectionFade = .{},
    selection_border: SelectionFade = .{},
    selected_before_band: bool = false,

    /// What the Name column shows and sorts by.
    pub fn text(self: ViewItem) []const u8 {
        return if (self.label.len > 0) self.label else self.name;
    }
};

/// The part of the view the last thumbnail request described.
pub const ThumbRequest = struct {
    revision: u64 = std.math.maxInt(u64),
    row0: i32 = 0,
    row1: i32 = 0,
    cols: i32 = 0,
};

pub const Focus = enum {
    terminal,
    file_view,
    location_bar,
    search,
    filename,
    chooser_accept,
    chooser_cancel,
    chooser_filter,
    chooser_choice,
};

pub const DialogKind = enum {
    terminal_close,
    new_folder,
    new_file,
    new_branch,
    rename,
    trash_confirm,
    conflict,
    open_with,
    properties,
};

pub const Dialog = struct {
    kind: DialogKind,
    edit: Editor = .{},
    title: []const u8,
    target_path: ?[]u8 = null,
    conflict_name: ?[]u8 = null,
    deletion: deletion.State = .{},
    applications: ?open_with.State = null,
    properties: ?properties.State = null,
};

pub const RenameCard = struct { panel: header.Rect, field: header.Rect, confirm: header.Rect, cancel: header.Rect };
