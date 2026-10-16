//! Animation tests.

const std = @import("std");
const sampleSpring = @import("anim_curves.zig").sampleSpring;
const cubicBezierY = @import("anim_curves.zig").cubicBezierY;
const Spring = @import("anim.zig").Spring;
const springs = @import("anim.zig").springs;
const desktopSwitchCurve = @import("anim.zig").desktopSwitchCurve;
const Target = @import("anim.zig").Target;
const Settings = @import("anim.zig").Settings;
const defaultSpec = @import("anim.zig").defaultSpec;
const epsilonBounds = @import("anim.zig").epsilonBounds;
const FrameBudget = @import("anim.zig").FrameBudget;
const beginFrame = @import("anim.zig").beginFrame;
const endFrame = @import("anim.zig").endFrame;
const rasterPixelQuantum = @import("anim.zig").rasterPixelQuantum;
const window_open_scale = @import("anim.zig").window_open_scale;
const windowMapScale = @import("anim.zig").windowMapScale;
const Curve = @import("anim.zig").Curve;
const reduced_opacity_ms = @import("anim.zig").reduced_opacity_ms;
const rubber_c = @import("anim.zig").rubber_c;
const Anim = @import("anim.zig").Anim;
const VelocityTracker = @import("anim.zig").VelocityTracker;
const rubber = @import("anim.zig").rubber;
const rubberClamp = @import("anim.zig").rubberClamp;
const observeBegin = @import("anim.zig").observeBegin;
const observeUnsettled = @import("anim.zig").observeUnsettled;
const observeNoteActive = @import("anim.zig").observeNoteActive;
const observeNoteChanged = @import("anim.zig").observeNoteChanged;
const observeActive = @import("anim.zig").observeActive;
const observeChanged = @import("anim.zig").observeChanged;
const observeLongestMs = @import("anim.zig").observeLongestMs;
const setNowMs = @import("anim.zig").setNowMs;
const clockOverridden = @import("anim.zig").clockOverridden;
const nowMs = @import("anim.zig").nowMs;
const setSpeed = @import("anim.zig").setSpeed;
const speed = @import("anim.zig").speed;
const setEnabled = @import("anim.zig").setEnabled;
const enabled = @import("anim.zig").enabled;
const setReducedMotion = @import("anim.zig").setReducedMotion;
const reducedMotion = @import("anim.zig").reducedMotion;
const curveFor = @import("anim.zig").curveFor;
const decayFor = @import("anim.zig").decayFor;
const setDesktopEnableAnimations = @import("anim.zig").setDesktopEnableAnimations;
const servedEnableAnimations = @import("anim.zig").servedEnableAnimations;
const applySettings = @import("anim.zig").applySettings;
const resetGlobals = @import("anim.zig").resetGlobals;

test "frame pressure is consecutive, per output and refresh aware" {
    var slow: FrameBudget = .{};
    var fast: FrameBudget = .{};
    for (0..2) |_| {
        slow.record(8_000_000, 144_000);
        fast.record(8_000_000, 60_000);
    }
    try std.testing.expect(!slow.coarse);
    slow.record(8_000_000, 144_000);
    try std.testing.expect(slow.coarse);
    try std.testing.expect(!fast.coarse);
    for (0..2) |_| slow.record(1_000_000, 144_000);
    try std.testing.expect(slow.coarse);
    slow.record(1_000_000, 144_000);
    try std.testing.expect(!slow.coarse);
    for (0..6) |i| slow.record(if (i % 2 == 0) 20_000_000 else 1, 0);
    try std.testing.expect(!slow.coarse);
}

test "raster degradation preserves sampling and settlement, and publishes endpoint" {
    resetGlobals();
    defer resetGlobals();
    const Clock = struct {
        fn read() u64 {
            return 0;
        }
    };
    var a = Anim.initDuration(0, 1, 0, 100, .out_cubic);
    const before = a.value(50);
    beginFrame(true, Clock.read, 0);
    defer _ = endFrame();
    try std.testing.expectEqual(@as(f32, 2), rasterPixelQuantum(1));
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 1.5), rasterPixelQuantum(1.5), 0.0001);
    try std.testing.expectEqual(before, a.value(50));
    try std.testing.expect(!a.settled(99));
    try std.testing.expect(a.settled(100));
    try std.testing.expect(a.sampleChanged(99, 1));
    try std.testing.expect(!a.sampleChanged(99, 1));
    try std.testing.expect(a.sampleChanged(100, 1));
    try std.testing.expect(!a.sampleChanged(100, 1));
    try std.testing.expect(!a.sampleChanged(100, 2.0 / 255.0));
}

test "sampling timer excludes work between samples and outside frames" {
    const Clock = struct {
        var ns: u64 = 0;
        fn read() u64 {
            ns += 10;
            return ns;
        }
    };
    Clock.ns = 0;
    const a = Anim.initDuration(0, 1, 0, 100, .out_cubic);
    beginFrame(false, Clock.read, 0);
    _ = a.value(20);
    Clock.ns += 1_000_000; // Raster work between samples.
    _ = a.velocity(20);
    try std.testing.expectEqual(@as(u64, 20), endFrame());
    _ = a.value(30);
    try std.testing.expectEqual(@as(u64, 20), endFrame());
    try std.testing.expectEqual(@as(f32, 1), rasterPixelQuantum(1));
}

test "window reveal eases through the old 33ms snap and reaches its destination" {
    const a = Anim.initCurve(0, 602, 1000, defaultSpec(.camera_reveal).curve);
    try std.testing.expect(!a.settled(1033));
    try std.testing.expect(@abs(a.value(1033) - a.value(1032)) < 6);
    try std.testing.expect(a.value(1160) > a.value(1033));
    try std.testing.expect(a.value(1160) < 602);
    try std.testing.expect(a.settled(1320));
    try std.testing.expectEqual(@as(f32, 602), a.value(1320));
}

test "retarget is a no-op when already animating toward the same target" {
    var a = Anim.initDuration(0, 1, 0, 100, .out_cubic);
    a.retarget(50, 1, 999, .out_cubic);
    try std.testing.expectEqual(@as(i64, 100), a.settle_ms);
    a.retarget(150, 1, 999, .out_cubic);
    try std.testing.expectEqual(@as(i64, 100), a.settle_ms);
    try std.testing.expect(a.settled(150));
}

test "pulse starts displaced and eases to rest" {
    var a: Anim = .{};
    a.pulse(0, 0.9, 1, 100);
    try std.testing.expectEqual(@as(f32, 0.9), a.value(0));
    try std.testing.expectEqual(@as(f32, 1), a.value(100));
}

test "setNowMs overrides the monotonic clock until cleared" {
    defer resetGlobals();
    setNowMs(1234);
    try std.testing.expect(clockOverridden());
    try std.testing.expectEqual(@as(i64, 1234), nowMs());
    setNowMs(null);
    try std.testing.expect(!clockOverridden());
}

test "out_cubic mid-duration matches the historical sample" {
    var a = Anim.initDuration(0.50, 0.55, 1000, 80, .out_cubic);
    try std.testing.expectApproxEqAbs(@as(f32, 0.54375), a.value(1040), 0.001);
    try std.testing.expect(!a.settled(1040));
    try std.testing.expect(a.settled(1080));
    try std.testing.expectEqual(@as(f32, 0.55), a.value(1080));
}

test "velocity at start_ms equals v0 for all three damping regimes" {
    const cases = [_]Spring{
        .{ .damping_ratio = 1.0, .stiffness = 800 },
        .{ .damping_ratio = 0.7, .stiffness = 800 },
        .{ .damping_ratio = 1.6, .stiffness = 800 },
    };
    const v0: f32 = 12.5;
    for (cases) |spring| {
        var a: Anim = .{};
        a.retargetWith(100, 1, .{ .spring = spring }, v0);
        try std.testing.expectApproxEqAbs(v0, a.velocity(100), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0), a.value(100), 1e-5);
    }
}

test "analytic spring matches RK4 integration" {
    const cases = [_]Spring{
        .{ .damping_ratio = 1.0, .stiffness = 800, .epsilon = 1e-4 },
        .{ .damping_ratio = 0.7, .stiffness = 800, .epsilon = 1e-4 },
        .{ .damping_ratio = 1.6, .stiffness = 800, .epsilon = 1e-4 },
    };
    for (cases) |spring| {
        var a: Anim = .{};
        a.retargetTo(0, 1, .{ .spring = spring });
        const Acc = struct {
            b: f64,
            k: f64,
            to: f64,
            fn call(self: @This(), x: f64, v: f64) f64 {
                return -self.b * v - self.k * (x - self.to);
            }
        };
        const k: f64 = spring.stiffness;
        const ratio: f64 = spring.damping_ratio;
        const acc = Acc{ .b = ratio * 2.0 * @sqrt(k), .k = k, .to = 1 };
        const dt: f64 = 0.0001;
        var t_ms: i64 = 0;
        const end = a.settle_ms;
        while (t_ms <= end) : (t_ms += 8) {
            const t_s = @as(f64, @floatFromInt(t_ms)) / 1000.0;
            var x: f64 = 0;
            var v: f64 = 0;
            var t: f64 = 0;
            while (t < t_s) {
                const step = @min(dt, t_s - t);
                const k1x = v;
                const k1v = acc.call(x, v);
                const k2x = v + 0.5 * step * k1v;
                const k2v = acc.call(x + 0.5 * step * k1x, v + 0.5 * step * k1v);
                const k3x = v + 0.5 * step * k2v;
                const k3v = acc.call(x + 0.5 * step * k2x, v + 0.5 * step * k2v);
                const k4x = v + step * k3v;
                const k4v = acc.call(x + step * k3x, v + step * k3v);
                x += step / 6.0 * (k1x + 2 * k2x + 2 * k3x + k4x);
                v += step / 6.0 * (k1v + 2 * k2v + 2 * k3v + k4v);
                t += step;
            }
            try std.testing.expectApproxEqAbs(@as(f32, @floatCast(x)), a.value(t_ms), 1e-3);
        }
    }
}

test "retarget is velocity-continuous" {
    const spring = Spring{ .damping_ratio = 0.85, .stiffness = 700 };
    var a: Anim = .{};
    a.retargetTo(0, 1, .{ .spring = spring });
    const mid: i64 = 40;
    const v = a.velocity(mid);
    const x = a.value(mid);
    a.retargetTo(mid, 0, .{ .spring = spring });
    try std.testing.expectApproxEqAbs(v, a.velocity(mid), 1e-4);
    try std.testing.expectApproxEqAbs(x, a.value(mid), 1e-5);
    try std.testing.expectApproxEqAbs(v, a.v0, 1e-4);

    const start = a.start_ms;
    a.retargetTo(mid + 5, 0, .{ .spring = spring });
    try std.testing.expectEqual(start, a.start_ms);

    a.cancel(0);
    a.retargetTo(1000, 1, .{ .spring = spring });
    try std.testing.expectApproxEqAbs(@as(f32, 0), a.v0, 1e-5);
}

test "spring settle time is finite and from==to is immediate" {
    const ratios = [_]f32{ 0.1, 0.5, 1.0, 2.0, 5.0, 10.0 };
    var prev_under: i64 = std.math.maxInt(i64);
    for (ratios) |ratio| {
        var a: Anim = .{};
        a.retargetTo(0, 1, .{ .spring = .{ .damping_ratio = ratio, .stiffness = 800, .epsilon = 1e-4 } });
        try std.testing.expect(a.settle_ms > 0);
        try std.testing.expect(a.settle_ms < 60_000);
        if (ratio <= 1.0) {
            try std.testing.expect(a.settle_ms <= prev_under);
            prev_under = a.settle_ms;
        }
    }

    var same: Anim = .{};
    same.retargetTo(0, 0, .{ .spring = .{ .damping_ratio = 1.15, .stiffness = 850, .epsilon = 0.0001 } });
    try std.testing.expectEqual(@as(i64, 0), same.settle_ms);
    try std.testing.expect(same.settled(0));

    var stiff: Anim = .{};
    stiff.retargetTo(0, 1, .{ .spring = .{ .damping_ratio = 6, .stiffness = 1200, .epsilon = 0.0001 } });
    try std.testing.expect(std.math.isFinite(@as(f32, @floatFromInt(stiff.settle_ms))));
    const late = sampleSpring(0, 1, 0, .{ .damping_ratio = 6, .stiffness = 1200, .epsilon = 0.0001 }, 10.0);
    try std.testing.expect(std.math.isFinite(late.value));
}

test "decay resting value, duration and 2-D angle" {
    const rate: f32 = 0.998;
    const v0: f32 = 800;
    var a: Anim = .{};
    a.retargetWith(0, 0, .{ .decay = .{ .rate = rate, .threshold = 0.5 } }, v0);
    const rest = a.restingValue();
    try std.testing.expectApproxEqAbs(rest, a.to, 1e-4);
    const far = a.settle_ms * 2;
    try std.testing.expectApproxEqAbs(rest, a.value(@max(far, a.settle_ms)), 0.6);
    try std.testing.expect(a.settled(a.settle_ms));
    try std.testing.expect(@abs(a.velocity(a.settle_ms)) <= 0.5 + 1e-3);

    var ax: Anim = .{};
    var ay: Anim = .{};
    ax.retargetWith(0, 0, .{ .decay = .{ .rate = rate, .threshold = 0.5 } }, 300);
    ay.retargetWith(0, 0, .{ .decay = .{ .rate = rate, .threshold = 0.5 } }, 400);
    const ang0 = std.math.atan2(@as(f64, 400), @as(f64, 300));
    var t: i64 = 8;
    while (t < ax.settle_ms) : (t += 16) {
        const ang = std.math.atan2(@as(f64, ay.value(t)), @as(f64, ax.value(t)));
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(ang0)), @as(f32, @floatCast(ang)), 1e-5);
    }
}

test "rubber band is monotone, bounded and continuous at zero" {
    try std.testing.expectEqual(@as(f32, 0), rubber(0, 800, rubber_c));
    var prev: f32 = 0;
    const d: f32 = 800;
    const xs = [_]f32{ 0, 1, 10, 50, 200, 800, 4000 };
    for (xs) |x| {
        const y = rubber(x, d, rubber_c);
        try std.testing.expect(y >= prev);
        try std.testing.expect(y < d);
        prev = y;
    }
    try std.testing.expectEqual(@as(f32, 100), rubberClamp(100, 0, 400, 400, rubber_c));
    const just_out = rubberClamp(401, 0, 400, 400, rubber_c);
    try std.testing.expect(just_out > 400);
    try std.testing.expect(just_out < 401);
}

test "sampleChanged observe tracks activity, change and longest" {
    defer resetGlobals();
    observeBegin();
    var a: Anim = .{};
    a.retargetTo(0, 10, .{ .spring = .{ .damping_ratio = 1.0, .stiffness = 800, .epsilon = 1e-4 } });
    try std.testing.expect(a.sampleChanged(0, 1));
    try std.testing.expect(observeActive());
    try std.testing.expect(observeChanged());
    try std.testing.expectEqual(@as(i64, 0), observeLongestMs());

    observeBegin();
    try std.testing.expect(!a.sampleChanged(0, 1));
    try std.testing.expect(observeActive());
    try std.testing.expect(!observeChanged());

    observeBegin();
    try std.testing.expect(a.sampleChanged(50, 1));
    try std.testing.expect(observeActive());
    try std.testing.expect(observeChanged());
    try std.testing.expectEqual(@as(i64, 50), observeLongestMs());

    try std.testing.expectEqualStrings("spring", a.curveName());
    try std.testing.expectEqualStrings("off", (Anim{ .curve = .off }).curveName());
}

test "a settled()-only keep-awake is invisible until it reports itself" {
    defer resetGlobals();
    var a: Anim = .{};
    a.retargetTo(0, 10, .{ .spring = .{ .damping_ratio = 0.9, .stiffness = 700, .epsilon = 1e-3 } });
    try std.testing.expect(a.settle_ms > 60);

    // The regression: a live curve that a frame only ever asks `settled()`
    // leaves the frame looking idle, so `anim_frames_scheduled` read zero while
    // the output was being re-armed every refresh.
    observeBegin();
    try std.testing.expect(!a.settled(50));
    try std.testing.expect(!observeActive());
    try std.testing.expectEqual(@as(i64, 0), observeLongestMs());

    observeBegin();
    try std.testing.expect(observeUnsettled(a, 50));
    try std.testing.expect(observeActive());
    try std.testing.expectEqual(@as(i64, 50), observeLongestMs());
    // Still not a *visible* change: that stays `sampleChanged`'s to report,
    // so such a frame is correctly counted as a wasted wakeup.
    try std.testing.expect(!observeChanged());

    // Past the settle point it must stop claiming the output.
    observeBegin();
    try std.testing.expect(!observeUnsettled(a, a.settle_ms));
    try std.testing.expect(!observeActive());
}

test "non-curve keep-awakes report activity and change" {
    defer resetGlobals();
    observeBegin();
    try std.testing.expect(!observeActive());
    try std.testing.expect(!observeChanged());

    // A caret blink is a phase timer, not an Anim; it still owns the output.
    observeNoteActive(1000, 1400);
    try std.testing.expect(observeActive());
    try std.testing.expectEqual(@as(i64, 400), observeLongestMs());

    observeNoteChanged();
    try std.testing.expect(observeChanged());

    observeBegin();
    try std.testing.expect(!observeActive());
    try std.testing.expect(!observeChanged());
    try std.testing.expectEqual(@as(i64, 0), observeLongestMs());
}

test "sampleChanged reports each quantum crossing once" {
    var a = Anim.initDuration(0, 10, 0, 1000, .out_cubic);
    try std.testing.expect(a.sampleChanged(0, 1));
    try std.testing.expect(!a.sampleChanged(0, 1));
    var saw_one = false;
    var t: i64 = 1;
    while (t <= 1000) : (t += 1) {
        const changed = a.sampleChanged(t, 1);
        const bucket = @round(a.value(t));
        if (bucket == 1 and changed) {
            try std.testing.expect(!saw_one);
            saw_one = true;
        }
    }
    try std.testing.expect(saw_one);
}

test "speed scales elapsed time; reduced_motion keeps opacity" {
    defer resetGlobals();
    const spring = Spring{ .damping_ratio = 1.0, .stiffness = 800 };
    var slow: Anim = .{};
    slow.retargetTo(0, 1, .{ .spring = spring });
    const at100 = slow.value(100);

    setSpeed(2);
    var fast: Anim = .{};
    fast.retargetTo(0, 1, .{ .spring = spring });
    try std.testing.expectApproxEqAbs(at100, fast.value(50), 1e-4);
    setSpeed(1);

    setReducedMotion(true);
    var motion: Anim = .{ .property = .motion };
    motion.retargetTo(0, 1, .{ .spring = spring });
    try std.testing.expect(motion.settled(0));
    try std.testing.expectEqual(@as(f32, 1), motion.value(0));

    var fade: Anim = .{ .property = .opacity };
    fade.retargetTo(0, 1, .{ .spring = spring });
    try std.testing.expect(!fade.settled(0));
    try std.testing.expect(fade.value(0) < 1);
    try std.testing.expect(fade.settled(reduced_opacity_ms));
    try std.testing.expectEqual(@as(f32, 1), fade.value(reduced_opacity_ms));
}

test "pinned clock: settled flips at stored settle_ms and sampleChanged terminates" {
    defer resetGlobals();
    setNowMs(1000);
    var a: Anim = .{};
    a.retargetTo(1000, 1, .{ .spring = .{ .damping_ratio = 1.0, .stiffness = 800, .epsilon = 1e-4 } });
    try std.testing.expect(a.settle_ms > 0);
    try std.testing.expect(!a.settled(1000));
    try std.testing.expect(!a.settled(1000 + a.settle_ms - 1));
    try std.testing.expect(a.settled(1000 + a.settle_ms));

    var paints: usize = 0;
    while (a.sampleChanged(1000, 0.01)) {
        paints += 1;
        if (paints > 8) return error.DidNotTerminate;
    }
    try std.testing.expect(paints >= 1);
}

test "active and cancel replace the duration_ms sentinel" {
    var a: Anim = .{};
    try std.testing.expect(!a.active());
    a.retarget(0, 1, 160, .out_cubic);
    try std.testing.expect(a.active());
    try std.testing.expect(!a.settled(0));
    a.cancel(1);
    try std.testing.expect(!a.active());
    try std.testing.expect(a.settled(0));
    try std.testing.expectEqual(@as(f32, 1), a.value(50));

    var s: Anim = .{};
    s.retargetTo(0, 1, .{ .spring = .{ .damping_ratio = 1, .stiffness = 800 } });
    try std.testing.expect(s.active());
    s.cancel(0.25);
    try std.testing.expect(!s.active());
    try std.testing.expectEqual(@as(f32, 0.25), s.value(0));
}

test "velocity tracker least-squares and pause" {
    var tr: VelocityTracker = .{};
    try std.testing.expectEqual(@as(f32, 0), tr.velocity(0));
    tr.push(0, 0);
    try std.testing.expectEqual(@as(f32, 0), tr.velocity(10));
    tr.push(10, 20);
    tr.push(20, 40);
    tr.push(30, 60);
    try std.testing.expectApproxEqAbs(@as(f32, 2000), tr.velocity(30), 1);
    try std.testing.expectEqual(@as(f32, 0), tr.velocity(90));
}

test "critical-damping window does not divide by zero" {
    var a: Anim = .{};
    a.retargetWith(0, 1, .{ .spring = .{ .damping_ratio = 1.0, .stiffness = 800 } }, 3);
    var t: i64 = 0;
    while (t <= a.settle_ms) : (t += 4) {
        const v = a.value(t);
        const vel = a.velocity(t);
        try std.testing.expect(std.math.isFinite(v));
        try std.testing.expect(std.math.isFinite(vel));
    }
}

test "enabled false and speed 0 complete instantly" {
    defer resetGlobals();
    var a: Anim = .{};
    a.retargetTo(0, 1, .{ .spring = .{ .damping_ratio = 1, .stiffness = 800 } });
    setEnabled(false);
    try std.testing.expect(a.settled(0));
    try std.testing.expectEqual(@as(f32, 1), a.value(0));
    setEnabled(true);
    setSpeed(0);
    try std.testing.expect(a.settled(0));
    try std.testing.expectEqual(@as(f32, 1), a.value(0));
}

// Keep the f32 bezier solver referenced so a future duration path that still
// wants bit-identical historical samples can call it without the compiler
// folding the function away.
test "flip_bezier f32 solver stays wired" {
    const y = cubicBezierY(0.5, 0.22, 0.9, 0.3, 1);
    try std.testing.expect(y > 0.5);
    try std.testing.expect(y < 1);
}

test "desktop switches respond immediately and settle at the requested time" {
    for ([_]u32{ 220, 400, 1500 }) |ms| {
        var a: Anim = .{};
        a.retargetTo(0, 1000, desktopSwitchCurve(ms));
        // A tenth of the duration should already cover over a quarter of the
        // distance: no spring-style acceleration delay on a keyboard action.
        try std.testing.expect(a.value(@intCast(ms / 10)) > 250);
        try std.testing.expect(a.velocity(0) > 0);
        try std.testing.expect(!a.settled(ms - 1));
        try std.testing.expect(a.settled(ms));
        try std.testing.expectEqual(@as(f32, 1000), a.value(ms));
    }
}

test "panel_slide spring double-toggle is velocity-continuous" {
    const curve = Curve{ .spring = springs.panel_slide };
    var a: Anim = .{};
    a.retargetTo(0, 1, curve);
    try std.testing.expect(a.active());
    const mid: i64 = 80;
    const v = a.velocity(mid);
    const x = a.value(mid);
    a.retargetTo(mid, 0, curve);
    try std.testing.expectApproxEqAbs(v, a.velocity(mid), 1e-4);
    try std.testing.expectApproxEqAbs(x, a.value(mid), 1e-5);
    try std.testing.expect(a.settle_ms > 0);
}

test "windowMapScale interpolates from open scale to rest" {
    try std.testing.expectEqual(window_open_scale, windowMapScale(0));
    try std.testing.expectEqual(@as(f32, 1.0), windowMapScale(1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.96), windowMapScale(0.5), 1e-6);
}

test "every animation target has a compiled-in default" {
    inline for (std.meta.tags(Target)) |tag| {
        const spec = defaultSpec(tag);
        try std.testing.expect(std.meta.activeTag(spec.curve) != .off or tag == .taskbar_press);
        _ = curveFor(tag);
        _ = decayFor(tag);
        const bounds = epsilonBounds(tag);
        try std.testing.expect(bounds.min > 0);
        try std.testing.expect(bounds.max > bounds.min);
    }
}

test "applySettings overlays speed enabled and reduced_motion auto" {
    defer resetGlobals();
    var cfg: Settings = .{};
    cfg.speed = 0.5;
    cfg.enabled = true;
    cfg.reduced_motion = .auto;
    setDesktopEnableAnimations(true);
    applySettings(cfg);
    try std.testing.expectEqual(@as(f32, 0.5), speed());
    try std.testing.expect(enabled());
    try std.testing.expect(!reducedMotion());

    setDesktopEnableAnimations(false);
    applySettings(cfg);
    try std.testing.expect(reducedMotion());

    cfg.reduced_motion = .off;
    applySettings(cfg);
    try std.testing.expect(!reducedMotion());
    try std.testing.expectEqual(@as(?bool, true), servedEnableAnimations(cfg));

    cfg.reduced_motion = .on;
    applySettings(cfg);
    try std.testing.expect(reducedMotion());
    try std.testing.expectEqual(@as(?bool, false), servedEnableAnimations(cfg));

    cfg.enabled = false;
    cfg.reduced_motion = .auto;
    try std.testing.expectEqual(@as(?bool, false), servedEnableAnimations(cfg));
}

test "config overlay continueFrom keeps velocity" {
    defer resetGlobals();
    const soft = Curve{ .spring = .{ .damping_ratio = 1.0, .stiffness = 400, .epsilon = 1e-4 } };
    const stiff = Curve{ .spring = .{ .damping_ratio = 1.0, .stiffness = 2000, .epsilon = 1e-4 } };
    var a: Anim = .{};
    a.retargetTo(0, 1, soft);
    const mid: i64 = 80;
    const x = a.value(mid);
    const v = a.velocity(mid);
    a.continueFrom(mid, x, 1, v, stiff);
    try std.testing.expectApproxEqAbs(x, a.value(mid), 1e-5);
    try std.testing.expectApproxEqAbs(v, a.velocity(mid), 1e-4);
    try std.testing.expect(a.settle_ms > 0);
    try std.testing.expect(a.settle_ms != blk: {
        var b: Anim = .{};
        b.retargetTo(0, 1, soft);
        break :blk b.settle_ms;
    });
}
