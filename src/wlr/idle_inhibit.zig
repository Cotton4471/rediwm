//! wlr.IdleInhibitManagerV1 / wlr.IdleInhibitorV1, backed by translate-c
//! against wlr/types/wlr_idle_inhibit_v1.h. `events.destroy` on the
//! inhibitor type carries the surface, not the inhibitor itself (see
//! wlr-protocols) -- that's not a mistake, wlroots really does type it
//! that way, matching src/session/idle.zig's existing
//! `wl.Listener(*wlr.Surface)`.
const wl = @import("wayland").server.wl;
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub fn Types(comptime Surface: type) type {
    return struct {
        pub const IdleInhibitorV1 = extern struct {
            surface: *Surface,
            resource: *wl.Resource,
            /// IdleInhibitManagerV1.inhibitors
            link: wl.list.Link,

            events: extern struct {
                destroy: wl.Signal(*Surface),
            },

            data: ?*anyopaque,

            comptime {
                const Real = c.wlr_idle_inhibitor_v1;
                assertFieldOffset(IdleInhibitorV1, Real, "surface");
                assertFieldOffset(IdleInhibitorV1, Real, "resource");
                assertFieldOffset(IdleInhibitorV1, Real, "link");
                assertFieldOffset(IdleInhibitorV1, Real, "events");
                assertFieldOffset(IdleInhibitorV1, Real, "data");
                assertSameLayout(@FieldType(IdleInhibitorV1, "events"), @FieldType(Real, "events"));
            }
        };

        pub const IdleInhibitManagerV1 = extern struct {
            inhibitors: wl.list.Head(IdleInhibitorV1, .link),
            global: *wl.Global,

            events: extern struct {
                new_inhibitor: wl.Signal(*IdleInhibitorV1),
                destroy: wl.Signal(*IdleInhibitManagerV1),
            },

            data: ?*anyopaque,

            pub fn create(server: *wl.Server) !*IdleInhibitManagerV1 {
                const raw = c.wlr_idle_inhibit_v1_create(@ptrCast(server));
                return @as(?*IdleInhibitManagerV1, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            comptime {
                const Real = c.wlr_idle_inhibit_manager_v1;
                assertFieldOffset(IdleInhibitManagerV1, Real, "inhibitors");
                assertFieldOffset(IdleInhibitManagerV1, Real, "global");
                assertFieldOffset(IdleInhibitManagerV1, Real, "events");
                assertFieldOffset(IdleInhibitManagerV1, Real, "data");

                const Events = @FieldType(IdleInhibitManagerV1, "events");
                const RealEvents = @FieldType(Real, "events");
                assertSameLayout(@FieldType(Events, "new_inhibitor"), c.wl_signal);
                assertSameLayout(@FieldType(Events, "destroy"), c.wl_signal);
                assertFieldOffset(Events, RealEvents, "new_inhibitor");
                assertFieldOffset(Events, RealEvents, "destroy");
                assertSameLayout(wl.list.Head(IdleInhibitorV1, .link), c.wl_list);
            }
        };
    };
}
