//! wlr.IdleNotifierV1, backed by translate-c against
//! wlr/types/wlr_idle_notify_v1.h. Every field but `global` is
//! WLR_PRIVATE in the real struct, so there's nothing else to redeclare
//! or assert beyond it -- `global` is the struct's first field, so its
//! offset is always 0 regardless.
const wl = @import("wayland").server.wl;
const c = @import("c.zig").c;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub fn Types(comptime Seat: type) type {
    return struct {
        pub const IdleNotifierV1 = extern struct {
            global: *wl.Global,

            pub fn create(server: *wl.Server) !*IdleNotifierV1 {
                const raw = c.wlr_idle_notifier_v1_create(@ptrCast(server));
                return @as(?*IdleNotifierV1, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            pub fn setInhibited(notifier: *IdleNotifierV1, inhibited: bool) void {
                c.wlr_idle_notifier_v1_set_inhibited(@ptrCast(notifier), inhibited);
            }

            pub fn notifyActivity(notifier: *IdleNotifierV1, seat: *Seat) void {
                c.wlr_idle_notifier_v1_notify_activity(@ptrCast(notifier), @ptrCast(seat));
            }

            comptime {
                assertFieldOffset(IdleNotifierV1, c.wlr_idle_notifier_v1, "global");
            }
        };
    };
}
