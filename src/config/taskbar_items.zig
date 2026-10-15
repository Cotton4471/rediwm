//! Ordered taskbar sections. Hidden items keep their section and order.
const std = @import("std");

pub const Section = enum { left, center, right };
pub const Item = enum {
    battery,
    network,
    volume,
    clock,
    start,
    windows,
    tray,
    power,
    capture,

    pub fn label(item: Item) []const u8 {
        return switch (item) {
            .battery => "Battery",
            .network => "Network",
            .volume => "Volume",
            .clock => "Clock",
            .start => "Start button",
            .windows => "Window list",
            .tray => "Application tray",
            .power => "Power",
            .capture => "Screen capture",
        };
    }
};
pub const count = std.meta.fields(Item).len;

pub const Config = struct {
    order: [count]Item = .{ .start, .windows, .capture, .tray, .battery, .network, .volume, .clock, .power },
    visible: [count]bool = .{ true, true, true, true, true, true, true, false, true },
    sections: [count]Section = .{ .right, .right, .right, .right, .left, .left, .right, .right, .right },

    /// One keyboard step: swap with the neighbour in the same section, or at
    /// a section's end step into the next section over (an empty one too).
    pub fn move(config: *Config, index: usize, right: bool) void {
        if (index >= count) return;
        const item = config.order[index];
        const other = if (right) index + 1 else index -% 1;
        if (other < count and config.section(config.order[other]) == config.section(item)) {
            std.mem.swap(Item, &config.order[index], &config.order[other]);
            return;
        }
        // The item is at its section's edge, so the order stays grouped.
        const zone = @intFromEnum(config.section(item));
        if (right and zone < 2) config.sections[@intFromEnum(item)] = @enumFromInt(zone + 1);
        if (!right and zone > 0) config.sections[@intFromEnum(item)] = @enumFromInt(zone - 1);
    }

    /// Puts the item at `from` into `zone` as its `slot`th item, counted
    /// without it (clamped to the end), and returns its new index.
    pub fn place(config: *Config, from: usize, zone: Section, slot: usize) usize {
        const item = config.order[from];
        var rest: [count - 1]Item = undefined;
        @memcpy(rest[0..from], config.order[0..from]);
        @memcpy(rest[from..], config.order[from + 1 ..]);
        var at: usize = 0;
        while (at < rest.len and @intFromEnum(config.section(rest[at])) < @intFromEnum(zone)) at += 1;
        var taken: usize = 0;
        while (at < rest.len and config.section(rest[at]) == zone and taken < slot) : (taken += 1) at += 1;
        config.sections[@intFromEnum(item)] = zone;
        @memcpy(config.order[0..at], rest[0..at]);
        config.order[at] = item;
        @memcpy(config.order[at + 1 ..], rest[at..]);
        return at;
    }

    pub fn section(config: Config, item: Item) Section {
        return config.sections[@intFromEnum(item)];
    }

    pub fn normalize(config: *Config) void {
        const previous = config.order;
        var index: usize = 0;
        for (std.enums.values(Section)) |zone| for (previous) |item| {
            if (config.section(item) != zone) continue;
            config.order[index] = item;
            index += 1;
        };
    }

    pub fn setSection(config: *Config, item: Item, zone: Section) void {
        config.sections[@intFromEnum(item)] = zone;
        config.normalize();
    }

    pub fn shown(config: Config, item: Item) bool {
        return config.visible[@intFromEnum(item)];
    }

    /// New lists use section:item. The original four-item lists remain valid.
    /// A minus prefix hides an item without forgetting its placement.
    pub fn parse(value: []const u8) !Config {
        const raw = std.mem.trim(u8, value, " \t\r");
        if (raw.len < 2 or raw[0] != '[' or raw[raw.len - 1] != ']') return error.InvalidValue;
        var result: Config = .{};
        var order: [count]Item = undefined;
        var seen = [_]bool{false} ** count;
        var legacy = true;
        var tokens = std.mem.splitScalar(u8, raw[1 .. raw.len - 1], ',');
        var index: usize = 0;
        while (tokens.next()) |token| {
            const entry = std.mem.trim(u8, token, " \t\r");
            if (index >= count or entry.len < 3 or entry[0] != '"' or entry[entry.len - 1] != '"') return error.InvalidValue;
            var name = entry[1 .. entry.len - 1];
            const visible = name[0] != '-';
            if (!visible) name = name[1..];
            var zone: ?Section = null;
            if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
                zone = std.meta.stringToEnum(Section, name[0..colon]) orelse return error.InvalidValue;
                name = name[colon + 1 ..];
                legacy = false;
            }
            const item = std.meta.stringToEnum(Item, name) orelse return error.InvalidValue;
            const id = @intFromEnum(item);
            if (seen[id]) return error.InvalidValue;
            if (id >= 4) legacy = false;
            seen[id] = true;
            order[index] = item;
            result.visible[id] = visible;
            if (zone) |s| result.sections[id] = s;
            index += 1;
        }
        if (legacy and index == 4) {
            result.order = .{ .start, .windows, .tray, order[0], order[1], order[2], order[3], .power, .capture };
        } else {
            // Older lists can omit Power and Screen capture. Every other
            // item remains required, so incomplete lists still fail closed.
            for (std.enums.values(Item)) |item| {
                if (item != .power and item != .capture and !seen[@intFromEnum(item)]) return error.InvalidValue;
            }
            @memcpy(result.order[0..index], order[0..index]);
            for ([_]Item{ .power, .capture }) |item| {
                if (seen[@intFromEnum(item)]) continue;
                result.order[index] = item;
                index += 1;
            }
        }
        result.normalize();
        if (!seen[@intFromEnum(Item.capture)]) {
            // Introduce the indicator at the start of the right section,
            // retaining the order, section and visibility of existing items.
            for (result.order, 0..) |item, i| {
                if (item == .capture) {
                    _ = result.place(i, .right, 0);
                    break;
                }
            }
        }
        return result;
    }

    pub fn serialize(config: Config, allocator: std.mem.Allocator) ![]u8 {
        var buffer: std.Io.Writer.Allocating = .init(allocator);
        errdefer buffer.deinit();
        try buffer.writer.writeByte('[');
        for (config.order, 0..) |item, i| {
            if (i > 0) try buffer.writer.writeAll(", ");
            try buffer.writer.print("\"{s}{s}:{s}\"", .{ if (config.shown(item)) "" else "-", @tagName(config.section(item)), @tagName(item) });
        }
        try buffer.writer.writeByte(']');
        return buffer.toOwnedSlice();
    }
};

pub const Layout = struct {
    x: [count]?f32 = @splat(null),
    widths: [count]f32 = @splat(0),
};

fn spacing(a: Item, b: Item, gap: f32, clock_gap: f32) f32 {
    return if (a == .clock or b == .clock) clock_gap else gap;
}

/// Center the middle group on the output, moving it only to avoid the edges.
/// The window list gives up width before any fixed control does.
pub fn arrange(config: Config, left: f32, right: f32, center: f32, widths: [count]f32, gap: f32, clock_gap: f32) Layout {
    var result: Layout = .{};
    var totals: [3]f32 = @splat(0);
    var previous: [3]?Item = @splat(null);
    for (config.order) |item| {
        const id = @intFromEnum(item);
        if (!config.shown(item) or widths[id] <= 0) continue;
        const zone = @intFromEnum(config.section(item));
        if (previous[zone]) |p| totals[zone] += spacing(p, item, gap, clock_gap);
        totals[zone] += widths[id];
        result.widths[id] = widths[id];
        previous[zone] = item;
    }
    var groups: usize = 0;
    for (totals) |total| if (total > 0) {
        groups += 1;
    };
    const zones_gap = @as(f32, @floatFromInt(groups -| 1)) * clock_gap;
    const overflow = @max(0, totals[0] + totals[1] + totals[2] + zones_gap - (right - left));
    const wid = @intFromEnum(Item.windows);
    const shrink = @min(result.widths[wid], overflow);
    result.widths[wid] -= shrink;
    totals[@intFromEnum(config.section(.windows))] -= shrink;
    const middle_min = left + totals[0] + (if (totals[0] > 0) clock_gap else @as(f32, 0));
    const middle_max = right - totals[2] - (if (totals[2] > 0) clock_gap else @as(f32, 0)) - totals[1];
    var cursor = [3]f32{ left, std.math.clamp(center - totals[1] / 2, middle_min, @max(middle_min, middle_max)), right - totals[2] };
    previous = @splat(null);
    for (config.order) |item| {
        const id = @intFromEnum(item);
        if (!config.shown(item) or widths[id] <= 0) continue;
        const zone = @intFromEnum(config.section(item));
        if (previous[zone]) |p| cursor[zone] += spacing(p, item, gap, clock_gap);
        result.x[id] = cursor[zone];
        cursor[zone] += result.widths[id];
        previous[zone] = item;
    }
    return result;
}

test "taskbar sections and hidden state round trip, migrate old lists and reject malformed lists" {
    var config: Config = .{};
    try std.testing.expect(!config.shown(.power));
    try std.testing.expect(config.shown(.capture));
    try std.testing.expectEqual(Section.right, config.section(.capture));
    try std.testing.expectEqual(Item.capture, config.order[2]);
    try std.testing.expectEqual(Section.right, config.section(.power));
    const previous = try Config.parse("[\"left:start\", \"left:windows\", \"right:tray\", \"right:battery\", \"right:network\", \"right:volume\", \"right:clock\"]");
    try std.testing.expectEqualDeep(config, previous);
    const previous_eight = try Config.parse("[\"left:start\", \"left:windows\", \"right:tray\", \"right:battery\", \"right:network\", \"right:volume\", \"right:clock\", \"-right:power\"]");
    try std.testing.expectEqualDeep(config, previous_eight);
    config.visible[@intFromEnum(Item.power)] = true;
    config.visible[@intFromEnum(Item.capture)] = false;
    config.setSection(.capture, .center);
    config.setSection(.volume, .left);
    config.move(1, false);
    config.visible[@intFromEnum(Item.volume)] = false;
    const encoded = try config.serialize(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualDeep(config, try Config.parse(encoded));
    const legacy = try Config.parse("[\"clock\", \"-network\", \"battery\", \"volume\"]");
    try std.testing.expectEqual(Section.left, legacy.section(.start));
    try std.testing.expectEqual(Section.left, legacy.section(.windows));
    try std.testing.expectEqual(Item.clock, legacy.order[4]);
    try std.testing.expect(legacy.shown(.capture));
    try std.testing.expectEqual(Item.capture, legacy.order[2]);
    try std.testing.expect(!legacy.shown(.network));
    try std.testing.expect(!legacy.shown(.power));
    // Drops land anywhere; keyboard steps cross into the next section at an edge.
    var moved: Config = .{};
    try std.testing.expectEqual(@as(usize, 1), moved.place(7, .left, 1));
    try std.testing.expectEqualSlices(Item, &.{ .start, .clock, .windows, .capture, .tray, .battery, .network, .volume, .power }, &moved.order);
    try std.testing.expectEqual(Section.left, moved.section(.clock));
    moved.move(2, true);
    try std.testing.expectEqual(Section.center, moved.section(.windows));
    try std.testing.expectEqual(@as(usize, 8), moved.place(2, .right, 9));
    try std.testing.expectEqual(Item.windows, moved.order[8]);
    for ([_][]const u8{ "[]", "[\"battery\", \"network\", \"volume\", \"volume\"]", "[\"battery\", \"network\", \"volume\", \"chevron\"]", "[\"left:battery\", \"network\", \"volume\", \"clock\"]" }) |bad| {
        try std.testing.expectError(error.InvalidValue, Config.parse(bad));
    }
}

test "taskbar defaults windows left, supports centering and shrinks windows before fixed items" {
    var config: Config = .{};
    const widths = [count]f32{ 0, 34, 34, 96, 42, 200, 0, 34, 120 };
    const defaults = arrange(config, 4, 980, 500, widths, 6, 16);
    try std.testing.expectEqual(@as(?f32, 52), defaults.x[@intFromEnum(Item.windows)]);
    try std.testing.expect(defaults.x[@intFromEnum(Item.capture)].? + 120 <= defaults.x[@intFromEnum(Item.network)].?);
    config.setSection(.windows, .center);
    const full = arrange(config, 4, 980, 500, widths, 6, 16);
    try std.testing.expectEqual(@as(?f32, 400), full.x[@intFromEnum(Item.windows)]);
    try std.testing.expectEqual(@as(?f32, 884), full.x[@intFromEnum(Item.clock)]);
    config.setSection(.clock, .center);
    config.setSection(.network, .left);
    const moved = arrange(config, 4, 980, 500, widths, 6, 16);
    try std.testing.expectEqual(@as(?f32, 52), moved.x[@intFromEnum(Item.network)]);
    const crowded = arrange(config, 4, 400, 200, .{ 0, 34, 34, 96, 42, 1000, 0, 34, 120 }, 6, 16);
    try std.testing.expect(crowded.widths[@intFromEnum(Item.windows)] < 1000);
    try std.testing.expect(crowded.x[@intFromEnum(Item.clock)].? + 96 <= crowded.x[@intFromEnum(Item.volume)].? - 16);
    config.visible = @splat(false);
    try std.testing.expectEqualDeep(Layout{}, arrange(config, 4, 980, 500, widths, 6, 16));
}
