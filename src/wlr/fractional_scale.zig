//! wlr.FractionalScaleManagerV1, backed by translate-c against
//! wlr/types/wlr_fractional_scale_v1.h.
const wl = @import("wayland").server.wl;
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub fn Types(comptime Surface: type) type {
    return struct {
        pub const FractionalScaleManagerV1 = extern struct {
            global: *wl.Global,

            events: extern struct {
                destroy: wl.Signal(void),
            },

            pub fn create(server: *wl.Server, version: u32) !*FractionalScaleManagerV1 {
                const raw = c.wlr_fractional_scale_manager_v1_create(@ptrCast(server), version);
                return @as(?*FractionalScaleManagerV1, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            pub fn notifyScale(surface: *Surface, scale: f64) void {
                c.wlr_fractional_scale_v1_notify_scale(@ptrCast(surface), scale);
            }

            comptime {
                const Real = c.wlr_fractional_scale_manager_v1;
                assertFieldOffset(FractionalScaleManagerV1, Real, "global");
                assertFieldOffset(FractionalScaleManagerV1, Real, "events");
                assertSameLayout(@FieldType(FractionalScaleManagerV1, "events"), @FieldType(Real, "events"));
            }
        };
    };
}
