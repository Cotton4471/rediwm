//! wlr.OutputPowerManagerV1 / wlr.OutputPowerV1, backed by translate-c
//! against wlr/types/wlr_output_power_management_v1.h.
//!
//! The struct bodies are hand-redeclared (unlike most future subsystems,
//! which can usually alias the translate-c type directly) only because
//! `events.*` needs to be retyped from the real `wl_signal` to
//! zig-wayland's `wl.Signal(T)` to get `.add()`/`.get()`/`.emit()` for
//! consumers -- the same reason zig-wlroots hand-declared this struct.
//! The comptime block below is the difference: it checks every
//! redeclared field's offset against the real translated struct, so a
//! future wlroots release that reorders or inserts a field fails the
//! build instead of silently corrupting memory.
//!
//! `Output` is supplied by wlr.zig and comes from the header-backed facade.
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub fn Types(comptime Output: type) type {
    return struct {
        pub const OutputPowerV1 = extern struct {
            resource: *wl.Resource,
            output: *Output,
            manager: *OutputPowerManagerV1,
            /// OutputPowerManagerV1.output_powers
            link: wl.list.Link,
            data: ?*anyopaque,

            comptime {
                const Real = c.wlr_output_power_v1;
                assertFieldOffset(OutputPowerV1, Real, "resource");
                assertFieldOffset(OutputPowerV1, Real, "output");
                assertFieldOffset(OutputPowerV1, Real, "manager");
                assertFieldOffset(OutputPowerV1, Real, "link");
                assertFieldOffset(OutputPowerV1, Real, "data");
            }
        };

        pub const OutputPowerManagerV1 = extern struct {
            pub const event = struct {
                pub const SetMode = extern struct {
                    output: *Output,
                    mode: zwlr.OutputPowerV1.Mode,
                };
            };

            global: *wl.Global,
            output_powers: wl.list.Head(OutputPowerV1, .link),

            events: extern struct {
                set_mode: wl.Signal(*event.SetMode),
                destroy: wl.Signal(*OutputPowerManagerV1),
            },

            data: ?*anyopaque,

            pub fn create(server: *wl.Server) !*OutputPowerManagerV1 {
                const raw = c.wlr_output_power_manager_v1_create(@ptrCast(server));
                return @as(?*OutputPowerManagerV1, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            comptime {
                const Real = c.wlr_output_power_manager_v1;
                assertFieldOffset(OutputPowerManagerV1, Real, "global");
                assertFieldOffset(OutputPowerManagerV1, Real, "output_powers");
                assertFieldOffset(OutputPowerManagerV1, Real, "events");
                assertFieldOffset(OutputPowerManagerV1, Real, "data");

                const Events = @FieldType(OutputPowerManagerV1, "events");
                const RealEvents = @FieldType(Real, "events");
                assertSameLayout(@FieldType(Events, "set_mode"), c.wl_signal);
                assertSameLayout(@FieldType(Events, "destroy"), c.wl_signal);
                assertFieldOffset(Events, RealEvents, "set_mode");
                assertFieldOffset(Events, RealEvents, "destroy");

                assertSameLayout(wl.list.Head(OutputPowerV1, .link), c.wl_list);
            }
        };
    };
}
