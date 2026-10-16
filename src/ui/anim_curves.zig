//! Animation curve math: settle times, spring, decay, duration and bezier sampling.

const std = @import("std");
const Ease = @import("anim.zig").Ease;
const Spring = @import("anim.zig").Spring;
const Decay = @import("anim.zig").Decay;
const Curve = @import("anim.zig").Curve;
const Anim = @import("anim.zig").Anim;

pub const SettleTimes = struct { settle: i64, clamped: i64 };

pub fn computeSettle(from: f32, to: f32, v0: f32, curve: Curve) SettleTimes {
    return switch (curve) {
        .off => .{ .settle = 0, .clamped = 0 },
        .duration => |d| .{ .settle = @max(d.ms, 0), .clamped = @max(d.ms, 0) },
        .spring => |s| springSettle(from, to, v0, s),
        .decay => |d| blk: {
            const ms = decayDurationMs(v0, d.rate, d.threshold);
            break :blk .{ .settle = ms, .clamped = ms };
        },
    };
}

pub const f32_eps: f64 = std.math.floatEps(f32);

pub const SpringMode = enum { critical, under, over };

pub const SpringEval = struct {
    to: f64,
    x0: f64,
    v0: f64,
    beta: f64,
    omega: f64,
    mode: SpringMode,
    epsilon: f64,
};

pub fn springEval(from: f32, to: f32, v0: f32, params: Spring) ?SpringEval {
    const k: f64 = params.stiffness;
    if (!(k > 0) or !std.math.isFinite(k)) return null;
    const ratio = @max(@as(f64, params.damping_ratio), 1e-3);
    const mass: f64 = 1.0;
    const critical = 2.0 * @sqrt(mass * k);
    const b = ratio * critical;
    const beta = b / (2.0 * mass);
    const omega0 = @sqrt(k / mass);
    const mode: SpringMode = if (@abs(beta - omega0) <= f32_eps)
        .critical
    else if (beta < omega0)
        .under
    else
        .over;
    const omega = switch (mode) {
        .critical => 0.0,
        .under => @sqrt(omega0 * omega0 - beta * beta),
        .over => @sqrt(beta * beta - omega0 * omega0),
    };
    return .{
        .to = to,
        .x0 = @as(f64, from) - @as(f64, to),
        .v0 = v0,
        .beta = beta,
        .omega = omega,
        .mode = mode,
        .epsilon = @max(@as(f64, params.epsilon), 1e-12),
    };
}

pub fn springOscillate(e: SpringEval, t: f64) f64 {
    const env = @exp(-e.beta * t);
    switch (e.mode) {
        .critical => return e.to + env * (e.x0 + (e.beta * e.x0 + e.v0) * t),
        .under => {
            const w = e.omega;
            const c = (e.beta * e.x0 + e.v0) / w;
            return e.to + env * (e.x0 * @cos(w * t) + c * @sin(w * t));
        },
        .over => {
            const w = e.omega;
            const d = (e.beta * e.x0 + e.v0) / w;
            const arg = w * t;
            const ch = std.math.cosh(arg);
            const sh = std.math.sinh(arg);
            const y = e.to + env * (e.x0 * ch + d * sh);
            if (!std.math.isFinite(y)) return e.to;
            return y;
        },
    }
}

pub fn springVelocityAt(e: SpringEval, t: f64) f64 {
    const env = @exp(-e.beta * t);
    switch (e.mode) {
        .critical => {
            const a = e.beta * e.x0 + e.v0;
            return env * (a - e.beta * (e.x0 + a * t));
        },
        .under => {
            const w = e.omega;
            const c = (e.beta * e.x0 + e.v0) / w;
            const wt = w * t;
            const cos_wt = @cos(wt);
            const sin_wt = @sin(wt);
            return env * (-e.beta * (e.x0 * cos_wt + c * sin_wt) + w * (c * cos_wt - e.x0 * sin_wt));
        },
        .over => {
            const w = e.omega;
            const d = (e.beta * e.x0 + e.v0) / w;
            const arg = w * t;
            const ch = std.math.cosh(arg);
            const sh = std.math.sinh(arg);
            const y = env * (-e.beta * (e.x0 * ch + d * sh) + w * (e.x0 * sh + d * ch));
            if (!std.math.isFinite(y)) return 0;
            return y;
        },
    }
}

pub fn secondsToMs(s: f64) i64 {
    if (!std.math.isFinite(s) or s >= 60) return 60_000;
    if (s <= 0) return 0;
    return @intFromFloat(@ceil(s * 1000.0));
}

pub fn springSettle(from: f32, to: f32, v0: f32, params: Spring) SettleTimes {
    const e = springEval(from, to, v0, params) orelse return .{ .settle = 0, .clamped = 0 };
    if (@abs(e.x0) <= e.epsilon and @abs(e.v0) <= e.epsilon) return .{ .settle = 0, .clamped = 0 };

    const settle_s = springDuration(e);
    const settle = secondsToMs(settle_s);
    const clamped_s = springClampedDuration(e) orelse settle_s;
    var clamped = secondsToMs(clamped_s);
    if (clamped > settle) clamped = settle;
    return .{ .settle = settle, .clamped = clamped };
}

pub fn springDuration(e: SpringEval) f64 {
    const delta: f64 = 0.001;
    if (@abs(e.beta) <= f32_eps or e.beta < 0) return 60;
    if (@abs(e.x0) <= e.epsilon and @abs(e.v0) <= e.epsilon) return 0;

    var x0 = -@log(e.epsilon) / e.beta;
    if (e.mode != .over) return x0;

    var y0 = springOscillate(e, x0);
    var m = (springOscillate(e, x0 + delta) - y0) / delta;
    if (@abs(m) < 1e-18 or !std.math.isFinite(m)) return x0;
    var x1 = (e.to - y0 + m * x0) / m;
    var y1 = springOscillate(e, x1);
    var i: usize = 0;
    while (@abs(e.to - y1) > e.epsilon) {
        if (i > 1000) return x0;
        x0 = x1;
        y0 = y1;
        m = (springOscillate(e, x0 + delta) - y0) / delta;
        if (@abs(m) < 1e-18 or !std.math.isFinite(m) or !std.math.isFinite(x0)) return x0;
        x1 = (e.to - y0 + m * x0) / m;
        y1 = springOscillate(e, x1);
        if (!std.math.isFinite(y1) or !std.math.isFinite(x1)) return x0;
        i += 1;
    }
    if (!std.math.isFinite(x1) or x1 < 0) return x0;
    return x1;
}

pub fn springClampedDuration(e: SpringEval) ?f64 {
    if (@abs(e.beta) <= f32_eps or e.beta < 0) return 60;
    if (@abs(e.x0) <= e.epsilon) return 0;
    const from = e.to + e.x0;
    var i: u16 = 1;
    var y = springOscillate(e, @as(f64, i) / 1000.0);
    while ((e.to - from > f32_eps and e.to - y > e.epsilon) or
        (from - e.to > f32_eps and y - e.to > e.epsilon))
    {
        if (i > 3000) return null;
        i += 1;
        y = springOscillate(e, @as(f64, i) / 1000.0);
    }
    return @as(f64, i) / 1000.0;
}

pub fn sampleSpring(from: f32, to: f32, v0: f32, params: Spring, t_s: f64) Anim.Sample {
    const e = springEval(from, to, v0, params) orelse return .{ .value = to, .velocity = 0 };
    const x = springOscillate(e, t_s);
    const v = springVelocityAt(e, t_s);
    // niri's numerical-stability clamp: 10× the travel, in case cosh blows up.
    const range = (@as(f64, to) - @as(f64, from)) * 10.0;
    const lo = @min(@as(f64, from) - range, @as(f64, to) + range);
    const hi = @max(@as(f64, from) - range, @as(f64, to) + range);
    const clamped = std.math.clamp(x, @min(lo, hi), @max(lo, hi));
    return .{
        .value = @floatCast(if (std.math.isFinite(clamped)) clamped else to),
        .velocity = @floatCast(if (std.math.isFinite(v)) v else 0),
    };
}

pub fn decayCoeff(rate: f32) f64 {
    const r = std.math.clamp(@as(f64, rate), 0.001, 0.999);
    return 1000.0 * @log(r);
}

pub fn decayResting(from: f32, v0: f32, rate: f32) f32 {
    const coeff = decayCoeff(rate);
    return @floatCast(@as(f64, from) - @as(f64, v0) / coeff);
}

pub fn decayDurationMs(v0: f32, rate: f32, threshold: f32) i64 {
    const coeff = decayCoeff(rate);
    const vel = @abs(@as(f64, v0));
    const thresh = @max(@as(f64, threshold), 1e-6);
    if (vel <= thresh) return 0;
    const inner = -coeff * thresh / vel;
    if (inner <= 0) return 0;
    const seconds = @log(inner) / coeff;
    return secondsToMs(seconds);
}

pub fn sampleDecay(from: f32, v0: f32, d: Decay, t_s: f64) Anim.Sample {
    const coeff = decayCoeff(d.rate);
    const env = @exp(coeff * t_s);
    const x = @as(f64, from) + (@as(f64, v0) / coeff) * (env - 1.0);
    const v = @as(f64, v0) * env;
    return .{ .value = @floatCast(x), .velocity = @floatCast(v) };
}

pub fn sampleDuration(from: f32, to: f32, elapsed_ms: f64, duration_ms: i64, ease: Ease) Anim.Sample {
    if (duration_ms <= 0) return .{ .value = to, .velocity = 0 };
    const dur: f64 = @floatFromInt(duration_ms);
    if (elapsed_ms >= dur) return .{ .value = to, .velocity = 0 };
    const t = if (elapsed_ms <= 0) 0 else elapsed_ms / dur;
    const t32: f32 = @floatCast(t);
    const eased: f32 = switch (ease) {
        .out_cubic => 1 - std.math.pow(f32, 1 - t32, 3),
        .flip_bezier => cubicBezierY(t32, 0.22, 0.9, 0.3, 1),
        .in_out_sine => 0.5 - 0.5 * @cos(std.math.pi * t32),
    };
    const deriv = easeDeriv(ease, t);
    const vel = (to - from) * deriv * (1000.0 / dur);
    return .{
        .value = from + (to - from) * eased,
        .velocity = @floatCast(vel),
    };
}

pub fn easeDeriv(ease: Ease, t: f64) f64 {
    const tt = std.math.clamp(t, 0, 1);
    return switch (ease) {
        .out_cubic => 3.0 * (1.0 - tt) * (1.0 - tt),
        .flip_bezier => cubicBezierDeriv(tt, 0.22, 0.9, 0.3, 1.0),
        .in_out_sine => 0.5 * std.math.pi * @sin(std.math.pi * tt),
    };
}

pub fn bezierComponent64(u: f64, p1: f64, p2: f64) f64 {
    const mu = 1.0 - u;
    return 3.0 * mu * mu * u * p1 + 3.0 * mu * u * u * p2 + u * u * u;
}

pub fn bezierDeriv64(u: f64, p1: f64, p2: f64) f64 {
    const mu = 1.0 - u;
    return 3.0 * mu * mu * p1 + 6.0 * mu * u * (p2 - p1) + 3.0 * u * u * (1.0 - p2);
}

pub fn cubicBezierDeriv(t: f64, x1: f64, y1: f64, x2: f64, y2: f64) f64 {
    var lo: f64 = 0;
    var hi: f64 = 1;
    var u: f64 = t;
    for (0..24) |_| {
        const x = bezierComponent64(u, x1, x2);
        if (@abs(x - t) < 1e-6) break;
        if (x < t) lo = u else hi = u;
        u = (lo + hi) / 2.0;
    }
    const dx = bezierDeriv64(u, x1, x2);
    const dy = bezierDeriv64(u, y1, y2);
    if (@abs(dx) < 1e-12) return 0;
    return dy / dx;
}

pub fn bezierComponent(u: f32, p1: f32, p2: f32) f32 {
    const mu = 1 - u;
    return 3 * mu * mu * u * p1 + 3 * mu * u * u * p2 + u * u * u;
}

// Solves x(u) = t for the CSS-style cubic-bezier(x1,y1,x2,y2) easing curve
// (implicit endpoints (0,0) and (1,1)) and returns y(u). Bisection keeps this
// robust without needing the curve's derivative. Kept for the existing f32
// duration path's exact historical samples.
pub fn cubicBezierY(t: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    var lo: f32 = 0;
    var hi: f32 = 1;
    var u: f32 = t;
    for (0..20) |_| {
        const x = bezierComponent(u, x1, x2);
        if (@abs(x - t) < 1e-4) break;
        if (x < t) lo = u else hi = u;
        u = (lo + hi) / 2;
    }
    return bezierComponent(u, y1, y2);
}
