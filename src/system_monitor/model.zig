const std = @import("std");
const collector = @import("collector.zig");
const proc = @import("proc.zig");
pub const Sort = enum { name, pid, user, cpu, memory, state };
pub const Model = struct {
    allocator: std.mem.Allocator,
    snapshot: ?*collector.Snapshot = null,
    rows: std.ArrayList(usize) = .empty,
    selected: ?proc.Identity = null,
    scroll: f64 = 0,
    query: []const u8 = "",
    mine: bool = true,
    uid: u32,
    sort: Sort = .cpu,
    descending: bool = true,

    pub fn deinit(self: *Model) void {
        self.rows.deinit(self.allocator);
        if (self.snapshot) |snap| snap.deinit();
    }
    pub fn update(self: *Model, snapshot: *collector.Snapshot) !void {
        if (self.snapshot) |old| old.deinit();
        self.snapshot = snapshot;
        try self.filter();
    }
    pub fn filter(self: *Model) !void {
        self.rows.clearRetainingCapacity();
        const snap = self.snapshot orelse return;
        for (snap.processes, 0..) |row, i| {
            if (self.mine and (row.uids == null or row.uids.?[0] != self.uid)) continue;
            if (self.query.len > 0) {
                var pid_buf: [32]u8 = undefined;
                const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{row.identity.pid}) catch unreachable;
                if (std.ascii.findIgnoreCase(row.name, self.query) == null and std.ascii.findIgnoreCase(row.user, self.query) == null and std.mem.indexOf(u8, pid, self.query) == null) continue;
            }
            try self.rows.append(self.allocator, i);
        }
        std.mem.sort(usize, self.rows.items, self, less);
        if (self.selectedIndex() == null) self.selected = null;
        // The UI only clamps at the new end. Reordering never scrolls to the
        // selected process; keyboard navigation explicitly reveals it.
    }
    pub fn selectedIndex(self: *const Model) ?usize {
        const identity = self.selected orelse return null;
        const snap = self.snapshot orelse return null;
        for (self.rows.items, 0..) |index, i| if (snap.processes[index].identity.eql(identity)) return i;
        return null;
    }
    pub fn selectedProcess(self: *const Model) ?collector.Process {
        const index = self.selectedIndex() orelse return null;
        return self.snapshot.?.processes[self.rows.items[index]];
    }
    pub fn setSort(self: *Model, sort: Sort) void {
        self.descending = if (sort == self.sort) !self.descending else sort == .cpu or sort == .memory;
        self.sort = sort;
        self.filter() catch {};
    }
    fn less(self: *Model, ai: usize, bi: usize) bool {
        const a = self.snapshot.?.processes[ai];
        const b = self.snapshot.?.processes[bi];
        const order: std.math.Order = switch (self.sort) {
            .name => std.ascii.orderIgnoreCase(a.name, b.name),
            .pid => std.math.order(a.identity.pid, b.identity.pid),
            .user => std.ascii.orderIgnoreCase(a.user, b.user),
            .cpu => optionalOrder(f64, a.cpu_percent, b.cpu_percent),
            .memory => optionalOrder(u64, a.resident_bytes, b.resident_bytes),
            .state => std.math.order(a.state, b.state),
        };
        if (order == .eq) return a.identity.pid < b.identity.pid;
        return if (self.descending) order == .gt else order == .lt;
    }
};
fn optionalOrder(comptime T: type, a: ?T, b: ?T) std.math.Order {
    if (a == null) return if (b == null) .eq else .lt;
    if (b == null) return .gt;
    return std.math.order(a.?, b.?);
}

pub const Point = struct { at_ns: u64, cpu: ?f64, memory: ?f64 };
pub const History = struct {
    points: [60]Point = undefined,
    count: usize = 0,
    pub fn append(self: *History, snap: *const collector.Snapshot) void {
        var keep: usize = 0;
        for (self.points[0..self.count]) |point| {
            if (snap.at_ns -| point.at_ns < 60_000_000_000) {
                self.points[keep] = point;
                keep += 1;
            }
        }
        self.count = keep;
        if (self.count == self.points.len) {
            std.mem.copyForwards(Point, self.points[0..59], self.points[1..60]);
            self.count -= 1;
        }
        self.points[self.count] = .{ .at_ns = snap.at_ns, .cpu = snap.cpu_percent, .memory = if (snap.memory) |mem| if (mem.total > 0) @as(f64, @floatFromInt(mem.used())) * 100 / @as(f64, @floatFromInt(mem.total)) else null else null };
        self.count += 1;
    }
};

pub fn stateName(state: u8) []const u8 {
    return switch (state) {
        'R' => "Running",
        'S' => "Sleeping",
        'D' => "Disk wait",
        'T', 't' => "Stopped",
        'Z' => "Zombie",
        'I' => "Idle",
        'X', 'x' => "Exited",
        else => "Unknown",
    };
}
