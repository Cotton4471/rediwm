//! Safety net for the facade's one necessary hand-declared shape: the
//! `events` block of a wlr struct, where a field has to be retyped from
//! translate-c's raw `wl_signal` to zig-wayland's `wl.Signal(T)` to get
//! `.add()`/`.get()`/`.emit()` for free. That retyping is safe only
//! because `struct wl_signal` is just one `wl_list` (two pointers) and
//! always will be -- these asserts turn any future drift (a struct
//! reordered, a field inserted ahead of where we stopped mirroring it)
//! into a compile error instead of silent memory corruption.
const std = @import("std");

pub fn assertSameLayout(comptime A: type, comptime B: type) void {
    if (@sizeOf(A) != @sizeOf(B) or @alignOf(A) != @alignOf(B)) {
        @compileError(@typeName(A) ++ " and " ++ @typeName(B) ++ " no longer have matching size/align");
    }
}

pub fn assertFieldOffset(comptime Ours: type, comptime Real: type, comptime field: []const u8) void {
    if (@offsetOf(Ours, field) != @offsetOf(Real, field)) {
        @compileError(@typeName(Ours) ++ "." ++ field ++ " offset drifted from " ++ @typeName(Real));
    }
}
