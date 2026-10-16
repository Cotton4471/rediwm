//! Drops stray clicks from bouncing mouse-wheel encoders. A worn or dusty
//! encoder sends a click the wrong way while it spins, as it stops, or as it
//! starts (2-40 ms after a real click, about one in sixteen on the mouse this
//! was measured on). Wheel glides read any reversal as the hand turning
//! round, so one stray click stops the glide dead and steps it back.
//!
//! A click against the run, within `window_ms` of the run's last click, is
//! held: no hand turns a detented wheel round that fast. If the run comes
//! back it bounced and is dropped; if nothing follows it is dropped too (a
//! bounce as the wheel settles). If clicks keep coming the new way past the
//! window, the held ones were a real reversal and go out with the click that
//! shows it. A wheel that never bounces never reaches the hold.
const std = @import("std");

const WheelDebounce = @This();

/// Sign of the run; 0 before the first click.
dir: i32 = 0,
/// When the run's last click was delivered.
last_ms: u32 = 0,
/// Clicks against the run, summed, and when the last of them came.
held: Notch = .{ .delta = 0, .discrete = 0 },
held_ms: u32 = 0,

pub const Notch = struct {
    delta: f64,
    discrete: i32,
};

/// Feeds one detented wheel event (value120 in `discrete`, nonzero). Returns
/// what to deliver now, or null when the event is held or dropped.
pub fn feed(self: *WheelDebounce, time_msec: u32, delta: f64, discrete: i32, window_ms: u32) ?Notch {
    const notch: Notch = .{ .delta = delta, .discrete = discrete };
    const dir = std.math.sign(discrete);
    if (window_ms == 0 or dir == 0) return notch;
    if (dir == self.dir) {
        // The run came back: whatever was held against it bounced.
        self.held = .{ .delta = 0, .discrete = 0 };
        self.last_ms = time_msec;
        return notch;
    }
    if (self.dir != 0 and time_msec -% self.last_ms < window_ms) {
        self.held.delta += delta;
        self.held.discrete += discrete;
        self.held_ms = time_msec;
        return null;
    }
    // A new run. Clicks held just before it, the same way, were its start.
    var out = notch;
    if (self.held.discrete != 0 and time_msec -% self.held_ms < window_ms) {
        out.delta += self.held.delta;
        out.discrete += self.held.discrete;
    }
    self.held = .{ .delta = 0, .discrete = 0 };
    self.dir = dir;
    self.last_ms = time_msec;
    return out;
}

/// Feeds whole clicks (`+1`/`-1` per entry) at the given times and returns
/// the value120 delivered for each, 0 when nothing was.
fn run(comptime n: usize, clicks: [n]struct { u32, i32 }, window_ms: u32) [n]i32 {
    var d: WheelDebounce = .{};
    var out: [n]i32 = undefined;
    for (clicks, &out) |click, *o| {
        const notch = d.feed(click[0], @floatFromInt(click[1] * 15), click[1] * 120, window_ms);
        o.* = if (notch) |got| got.discrete else 0;
    }
    return out;
}

test "a stray click inside a run is dropped" {
    // Recorded: v 27v 50v 6v 5^ 16v
    const got = run(6, .{ .{ 0, -1 }, .{ 27, -1 }, .{ 77, -1 }, .{ 83, -1 }, .{ 88, 1 }, .{ 104, -1 } }, 60);
    try std.testing.expectEqual([6]i32{ -120, -120, -120, -120, 0, -120 }, got);
}

test "two stray clicks in a row are dropped" {
    // Recorded: v 17v 15^ 9^ 35v
    const got = run(5, .{ .{ 0, -1 }, .{ 17, -1 }, .{ 32, 1 }, .{ 41, 1 }, .{ 76, -1 } }, 60);
    try std.testing.expectEqual([5]i32{ -120, -120, 0, 0, -120 }, got);
}

test "a stray click as the wheel stops is dropped, a later turn is not" {
    // Recorded: v 13v 17v 6^, then the hand scrolls up 300 ms later.
    const got = run(5, .{ .{ 0, -1 }, .{ 13, -1 }, .{ 30, -1 }, .{ 36, 1 }, .{ 336, 1 } }, 60);
    try std.testing.expectEqual([5]i32{ -120, -120, -120, 0, 120 }, got);
}

test "a deliberate reversal goes out at once" {
    const got = run(3, .{ .{ 0, -1 }, .{ 25, -1 }, .{ 215, 1 } }, 60);
    try std.testing.expectEqual([3]i32{ -120, -120, 120 }, got);
}

test "clicks that keep going the new way are delivered, not lost" {
    // Recorded: a run starting with a wrong-way click, ^ 14v 19v 21v 6v. The
    // stray ^ has already gone out; the real run must not be eaten.
    const got = run(5, .{ .{ 0, 1 }, .{ 14, -1 }, .{ 33, -1 }, .{ 54, -1 }, .{ 60, -1 } }, 60);
    try std.testing.expectEqual([5]i32{ 120, 0, 0, 0, -480 }, got);
}

test "window 0 passes everything through" {
    const got = run(3, .{ .{ 0, -1 }, .{ 5, 1 }, .{ 10, -1 } }, 0);
    try std.testing.expectEqual([3]i32{ -120, 120, -120 }, got);
}

test "held deltas travel with their clicks" {
    var d: WheelDebounce = .{};
    _ = d.feed(0, 15, 120, 60);
    try std.testing.expect(d.feed(10, -15, -120, 60) == null);
    const out = d.feed(65, -15, -120, 60).?;
    try std.testing.expectEqual(@as(i32, -240), out.discrete);
    try std.testing.expectEqual(@as(f64, -30), out.delta);
}
