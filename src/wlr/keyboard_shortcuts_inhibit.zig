//! wlr.KeyboardShortcutsInhibitManagerV1 / wlr.KeyboardShortcutsInhibitorV1,
//! backed by translate-c against wlr/types/wlr_keyboard_shortcuts_inhibit_v1.h.
const wl = @import("wayland").server.wl;
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub fn Types(comptime Surface: type, comptime Seat: type) type {
    return struct {
        pub const KeyboardShortcutsInhibitorV1 = extern struct {
            surface: *Surface,
            seat: *Seat,
            active: bool,
            resource: *wl.Resource,
            /// KeyboardShortcutsInhibitManagerV1.inhibitors
            link: wl.list.Link,

            events: extern struct {
                destroy: wl.Signal(*KeyboardShortcutsInhibitorV1),
            },

            data: ?*anyopaque,

            pub fn activate(inhibitor: *KeyboardShortcutsInhibitorV1) void {
                c.wlr_keyboard_shortcuts_inhibitor_v1_activate(@ptrCast(inhibitor));
            }

            pub fn deactivate(inhibitor: *KeyboardShortcutsInhibitorV1) void {
                c.wlr_keyboard_shortcuts_inhibitor_v1_deactivate(@ptrCast(inhibitor));
            }

            comptime {
                const Real = c.wlr_keyboard_shortcuts_inhibitor_v1;
                assertFieldOffset(KeyboardShortcutsInhibitorV1, Real, "surface");
                assertFieldOffset(KeyboardShortcutsInhibitorV1, Real, "seat");
                assertFieldOffset(KeyboardShortcutsInhibitorV1, Real, "active");
                assertFieldOffset(KeyboardShortcutsInhibitorV1, Real, "resource");
                assertFieldOffset(KeyboardShortcutsInhibitorV1, Real, "link");
                assertFieldOffset(KeyboardShortcutsInhibitorV1, Real, "events");
                assertFieldOffset(KeyboardShortcutsInhibitorV1, Real, "data");
                assertSameLayout(@FieldType(KeyboardShortcutsInhibitorV1, "events"), @FieldType(Real, "events"));
            }
        };

        pub const KeyboardShortcutsInhibitManagerV1 = extern struct {
            inhibitors: wl.list.Head(KeyboardShortcutsInhibitorV1, .link),
            global: *wl.Global,

            events: extern struct {
                new_inhibitor: wl.Signal(*KeyboardShortcutsInhibitorV1),
                destroy: wl.Signal(*KeyboardShortcutsInhibitManagerV1),
            },

            data: ?*anyopaque,

            pub fn create(server: *wl.Server) !*KeyboardShortcutsInhibitManagerV1 {
                const raw = c.wlr_keyboard_shortcuts_inhibit_v1_create(@ptrCast(server));
                return @as(?*KeyboardShortcutsInhibitManagerV1, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            comptime {
                const Real = c.wlr_keyboard_shortcuts_inhibit_manager_v1;
                assertFieldOffset(KeyboardShortcutsInhibitManagerV1, Real, "inhibitors");
                assertFieldOffset(KeyboardShortcutsInhibitManagerV1, Real, "global");
                assertFieldOffset(KeyboardShortcutsInhibitManagerV1, Real, "events");
                assertFieldOffset(KeyboardShortcutsInhibitManagerV1, Real, "data");

                const Events = @FieldType(KeyboardShortcutsInhibitManagerV1, "events");
                const RealEvents = @FieldType(Real, "events");
                assertSameLayout(@FieldType(Events, "new_inhibitor"), c.wl_signal);
                assertSameLayout(@FieldType(Events, "destroy"), c.wl_signal);
                assertFieldOffset(Events, RealEvents, "new_inhibitor");
                assertFieldOffset(Events, RealEvents, "destroy");
                assertSameLayout(wl.list.Head(KeyboardShortcutsInhibitorV1, .link), c.wl_list);
            }
        };
    };
}
