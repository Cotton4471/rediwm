//! Presentation protocol registration. Feedback sampling remains in the C
//! output pass; this facade only creates the display-owned manager.
const wl = @import("wayland").server.wl;
const wlr = @import("wlr.zig");
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub const Presentation = extern struct {
    global: *wl.Global,
    events: extern struct {
        destroy: wl.Signal(*Presentation),
    },

    pub fn create(server: *wl.Server, backend: *wlr.Backend, version: u32) !*Presentation {
        const raw = c.wlr_presentation_create(@ptrCast(server), @ptrCast(backend), version);
        return @as(?*Presentation, @ptrCast(raw)) orelse error.OutOfMemory;
    }

    comptime {
        const Real = c.wlr_presentation;
        for (.{ "global", "events" }) |field| {
            assertFieldOffset(Presentation, Real, field);
            assertSameLayout(@FieldType(Presentation, field), @FieldType(Real, field));
        }
        const Events = @FieldType(Presentation, "events");
        const RealEvents = @FieldType(Real, "events");
        assertFieldOffset(Events, RealEvents, "destroy");
        assertSameLayout(@FieldType(Events, "destroy"), c.wl_signal);
    }
};
