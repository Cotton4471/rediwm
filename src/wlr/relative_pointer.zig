//! wlr.RelativePointerManagerV1 / wlr.RelativePointerV1, backed by
//! translate-c against wlr/types/wlr_relative_pointer_v1.h.
//! RelativePointerV1 is not referenced by name anywhere in RediWM, but
//! its layout still has to be right: the manager's `relative_pointers`
//! list and `events.new_relative_pointer` signal are typed in terms of
//! it, and getting its field order wrong would misplace `link` for
//! anyone who ever does walk that list.
const wl = @import("wayland").server.wl;
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub fn Types(comptime Seat: type) type {
    return struct {
        pub const RelativePointerV1 = extern struct {
            resource: *wl.Resource,
            pointer_resource: *wl.Resource,
            seat: *Seat,
            /// RelativePointerManagerV1.relative_pointers
            link: wl.list.Link,

            events: extern struct {
                destroy: wl.Signal(*RelativePointerV1),
            },

            data: ?*anyopaque,

            comptime {
                const Real = c.wlr_relative_pointer_v1;
                assertFieldOffset(RelativePointerV1, Real, "resource");
                assertFieldOffset(RelativePointerV1, Real, "pointer_resource");
                assertFieldOffset(RelativePointerV1, Real, "seat");
                assertFieldOffset(RelativePointerV1, Real, "link");
                assertFieldOffset(RelativePointerV1, Real, "events");
                assertFieldOffset(RelativePointerV1, Real, "data");
                assertSameLayout(@FieldType(RelativePointerV1, "events"), @FieldType(Real, "events"));
            }
        };

        pub const RelativePointerManagerV1 = extern struct {
            global: *wl.Global,
            relative_pointers: wl.list.Head(RelativePointerV1, .link),

            events: extern struct {
                destroy: wl.Signal(*RelativePointerManagerV1),
                new_relative_pointer: wl.Signal(*RelativePointerV1),
            },

            data: ?*anyopaque,

            pub fn create(server: *wl.Server) !*RelativePointerManagerV1 {
                const raw = c.wlr_relative_pointer_manager_v1_create(@ptrCast(server));
                return @as(?*RelativePointerManagerV1, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            pub fn sendRelativeMotion(
                manager: *RelativePointerManagerV1,
                seat: *Seat,
                time_usec: u64,
                dx: f64,
                dy: f64,
                dx_unaccel: f64,
                dy_unaccel: f64,
            ) void {
                c.wlr_relative_pointer_manager_v1_send_relative_motion(
                    @ptrCast(manager),
                    @ptrCast(seat),
                    time_usec,
                    dx,
                    dy,
                    dx_unaccel,
                    dy_unaccel,
                );
            }

            comptime {
                const Real = c.wlr_relative_pointer_manager_v1;
                assertFieldOffset(RelativePointerManagerV1, Real, "global");
                assertFieldOffset(RelativePointerManagerV1, Real, "relative_pointers");
                assertFieldOffset(RelativePointerManagerV1, Real, "events");
                assertFieldOffset(RelativePointerManagerV1, Real, "data");

                const Events = @FieldType(RelativePointerManagerV1, "events");
                const RealEvents = @FieldType(Real, "events");
                assertSameLayout(@FieldType(Events, "destroy"), c.wl_signal);
                assertSameLayout(@FieldType(Events, "new_relative_pointer"), c.wl_signal);
                assertFieldOffset(Events, RealEvents, "destroy");
                assertFieldOffset(Events, RealEvents, "new_relative_pointer");
                assertSameLayout(wl.list.Head(RelativePointerV1, .link), c.wl_list);
            }
        };
    };
}
