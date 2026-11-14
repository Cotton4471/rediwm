//! The allocator's public layout and lifecycle, backed by wlroots headers.
//! RediWM uses wlroots-created allocators; their implementation callbacks
//! remain C types because the compositor never supplies an implementation.
const wl = @import("wayland").server.wl;
const wlr = @import("wlr.zig");
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub const Allocator = extern struct {
    impl: *const c.wlr_allocator_interface,
    buffer_caps: u32,
    events: extern struct {
        destroy: wl.Signal(void),
    },

    pub fn autocreate(backend: *wlr.Backend, renderer: *wlr.Renderer) !*Allocator {
        const raw = c.wlr_allocator_autocreate(@ptrCast(backend), @ptrCast(renderer));
        return @as(?*Allocator, @ptrCast(raw)) orelse error.AllocatorCreateFailed;
    }

    pub fn destroy(allocator: *Allocator) void {
        c.wlr_allocator_destroy(@ptrCast(allocator));
    }

    comptime {
        const Real = c.wlr_allocator;
        assertSameLayout(Allocator, Real);
        for (@typeInfo(Allocator).@"struct".field_names) |field_name| {
            assertFieldOffset(Allocator, Real, field_name);
            assertSameLayout(@FieldType(Allocator, field_name), @FieldType(Real, field_name));
        }
        const Events = @FieldType(Allocator, "events");
        assertFieldOffset(Events, @FieldType(Real, "events"), "destroy");
        assertSameLayout(@FieldType(Events, "destroy"), c.wl_signal);
    }
};
