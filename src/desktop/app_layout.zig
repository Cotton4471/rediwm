//! Desktop grid geometry: cells, occupancy and resize.

const std = @import("std");
const App = @import("app.zig").App;
const grid = @import("grid.zig");
const watcher = @import("watcher.zig");
const rename = @import("rename.zig");

/// Re-reads the reserved bottom strip, e.g. after the taskbar resized.
pub fn refreshBottom(self: *App) void {
    self.geometry.bottom = self.bottom_config orelse self.host.bottomExclusion() orelse 64;
}

/// Home and Trash start in the top-left corner (cells count from the right).
pub fn defaultCell(self: *App, builtin: watcher.Builtin) grid.Cell {
    return .{ .col = self.geometry.cols() - 1, .row = @as(i32, @intFromEnum(builtin)) - 1 };
}

pub fn valid(self: *App, cell: grid.Cell) bool {
    return cell.col >= 0 and cell.row >= 0 and cell.col < self.geometry.cols() and cell.row < self.geometry.rows();
}

pub fn occupied(self: *App, cell: grid.Cell, skip: ?usize) bool {
    for (self.icons.items, 0..) |ic, i| if (skip != i and ic.cell.col == cell.col and ic.cell.row == cell.row and ic.removed == null) return true;
    return false;
}

pub fn firstEmpty(self: *App) grid.Cell {
    var i: usize = 0;
    while (i <= self.icons.items.len) : (i += 1) {
        const cell = self.geometry.cell(i);
        if (!self.occupied(cell, null)) return cell;
    }
    return self.geometry.cell(i);
}

pub fn resize(self: *App, w: i32, h: i32) void {
    var unmoved: [2]bool = @splat(false);
    for (self.icons.items) |ic| if (ic.item.builtin != .none and ic.removed == null) {
        const cell = self.defaultCell(ic.item.builtin);
        unmoved[@intFromEnum(ic.item.builtin) - 1] = ic.cell.col == cell.col and ic.cell.row == cell.row;
    };
    self.geometry.w = w;
    self.geometry.h = h;
    for (self.icons.items) |*ic| if (ic.item.builtin != .none and unmoved[@intFromEnum(ic.item.builtin) - 1]) {
        ic.cell = self.defaultCell(ic.item.builtin);
    };
    for (self.icons.items, 0..) |*ic, i| if (!self.valid(ic.cell) or self.occupied(ic.cell, i)) {
        ic.cell = self.firstEmpty();
    };
    self.invalidate();
}

pub fn hit(self: *App, x: f64, y: f64) ?usize {
    for (self.icons.items, 0..) |ic, i| if (ic.removed == null and self.geometry.rect(ic.cell).contains(x, y)) return i;
    return null;
}

pub fn renameGeometry(self: *App) ?rename.Geometry {
    if (self.edit != .rename) return null;
    for (self.icons.items) |ic| {
        if (ic.selected and ic.removed == null) return rename.Geometry.init(self.geometry.rect(ic.cell), self.geometry);
    }
    return null;
}
