//! wlr.PointerConstraintsV1 / wlr.PointerConstraintV1, backed by
//! translate-c against wlr/types/wlr_pointer_constraints_v1.h.
const std = @import("std");
const wl = @import("wayland").server.wl;
const zwp = @import("wayland").server.zwp;
const pixman = @import("pixman");
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub fn Types(comptime Surface: type, comptime Seat: type) type {
    return struct {
        pub const PointerConstraintV1 = extern struct {
            pub const Type = enum(c_int) {
                locked,
                confined,
            };

            pub const State = extern struct {
                committed: u32,
                region: pixman.Region32,

                cursor_hint: extern struct {
                    enabled: bool,
                    x: f64,
                    y: f64,
                },

                comptime {
                    const Real = c.wlr_pointer_constraint_v1_state;
                    assertFieldOffset(State, Real, "committed");
                    assertFieldOffset(State, Real, "region");
                    assertFieldOffset(State, Real, "cursor_hint");
                    assertSameLayout(State, Real);
                }
            };

            pointer_constraints: *PointerConstraintsV1,
            resource: *wl.Resource,
            surface: *Surface,
            seat: *Seat,
            lifetime: zwp.PointerConstraintsV1.Lifetime,
            type: Type,
            region: pixman.Region32,

            current: State,
            pending: State,

            /// PointerConstraintsV1.constraints
            link: wl.list.Link,

            events: extern struct {
                set_region: wl.Signal(void),
                destroy: wl.Signal(*PointerConstraintV1),
            },

            data: ?*anyopaque,

            pub fn sendActivated(constraint: *PointerConstraintV1) void {
                c.wlr_pointer_constraint_v1_send_activated(@ptrCast(constraint));
            }

            pub fn sendDeactivated(constraint: *PointerConstraintV1) void {
                c.wlr_pointer_constraint_v1_send_deactivated(@ptrCast(constraint));
            }

            comptime {
                const Real = c.wlr_pointer_constraint_v1;
                assertFieldOffset(PointerConstraintV1, Real, "pointer_constraints");
                assertFieldOffset(PointerConstraintV1, Real, "resource");
                assertFieldOffset(PointerConstraintV1, Real, "surface");
                assertFieldOffset(PointerConstraintV1, Real, "seat");
                assertFieldOffset(PointerConstraintV1, Real, "lifetime");
                assertFieldOffset(PointerConstraintV1, Real, "type");
                assertFieldOffset(PointerConstraintV1, Real, "region");
                assertFieldOffset(PointerConstraintV1, Real, "current");
                assertFieldOffset(PointerConstraintV1, Real, "pending");
                assertFieldOffset(PointerConstraintV1, Real, "link");
                assertFieldOffset(PointerConstraintV1, Real, "events");
                assertFieldOffset(PointerConstraintV1, Real, "data");
                assertSameLayout(@FieldType(PointerConstraintV1, "events"), @FieldType(Real, "events"));
                assertSameLayout(Type, c.wlr_pointer_constraint_v1_type);
            }
        };

        pub const PointerConstraintsV1 = extern struct {
            global: *wl.Global,
            constraints: wl.list.Head(PointerConstraintV1, .link),

            events: extern struct {
                destroy: wl.Signal(void),
                new_constraint: wl.Signal(*PointerConstraintV1),
            },

            data: ?*anyopaque,

            pub fn create(server: *wl.Server) !*PointerConstraintsV1 {
                const raw = c.wlr_pointer_constraints_v1_create(@ptrCast(server));
                return @as(?*PointerConstraintsV1, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            pub fn constraintForSurface(manager: *PointerConstraintsV1, surface: *Surface, seat: *Seat) ?*PointerConstraintV1 {
                const raw = c.wlr_pointer_constraints_v1_constraint_for_surface(@ptrCast(manager), @ptrCast(surface), @ptrCast(seat));
                return @ptrCast(raw);
            }

            comptime {
                const Real = c.wlr_pointer_constraints_v1;
                assertFieldOffset(PointerConstraintsV1, Real, "global");
                assertFieldOffset(PointerConstraintsV1, Real, "constraints");
                assertFieldOffset(PointerConstraintsV1, Real, "events");
                assertFieldOffset(PointerConstraintsV1, Real, "data");

                const Events = @FieldType(PointerConstraintsV1, "events");
                const RealEvents = @FieldType(Real, "events");
                assertSameLayout(@FieldType(Events, "destroy"), c.wl_signal);
                assertSameLayout(@FieldType(Events, "new_constraint"), c.wl_signal);
                assertFieldOffset(Events, RealEvents, "destroy");
                assertFieldOffset(Events, RealEvents, "new_constraint");
                assertSameLayout(wl.list.Head(PointerConstraintV1, .link), c.wl_list);
            }
        };
    };
}
