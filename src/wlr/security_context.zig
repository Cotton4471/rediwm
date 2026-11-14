//! wlr.SecurityContextManagerV1 / wlr.SecurityContextV1State, backed by
//! translate-c against wlr/types/wlr_security_context_v1.h. Read
//! src/global_filter.zig and the top-level AGENTS.md's security-context
//! note before changing this: it's what hides privileged globals from
//! sandboxed clients.
const wl = @import("wayland").server.wl;
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub const SecurityContextV1State = extern struct {
    sandbox_engine: ?[*:0]u8,
    app_id: ?[*:0]u8,
    instance_id: ?[*:0]u8,

    comptime {
        const Real = c.wlr_security_context_v1_state;
        assertFieldOffset(SecurityContextV1State, Real, "sandbox_engine");
        assertFieldOffset(SecurityContextV1State, Real, "app_id");
        assertFieldOffset(SecurityContextV1State, Real, "instance_id");
        assertSameLayout(SecurityContextV1State, Real);
    }
};

pub const SecurityContextManagerV1 = extern struct {
    pub const event = struct {
        pub const Commit = extern struct {
            state: *const SecurityContextV1State,
            parent_client: *wl.Client,

            comptime {
                const Real = c.wlr_security_context_v1_commit_event;
                assertFieldOffset(Commit, Real, "state");
                assertFieldOffset(Commit, Real, "parent_client");
                assertSameLayout(Commit, Real);
            }
        };
    };

    global: *wl.Global,

    events: extern struct {
        destroy: wl.Signal(void),
        commit: wl.Signal(*event.Commit),
    },

    data: ?*anyopaque,

    pub fn create(server: *wl.Server) !*SecurityContextManagerV1 {
        const raw = c.wlr_security_context_manager_v1_create(@ptrCast(server));
        return @as(?*SecurityContextManagerV1, @ptrCast(raw)) orelse error.OutOfMemory;
    }

    pub fn lookupClient(manager: *SecurityContextManagerV1, client: *const wl.Client) ?*const SecurityContextV1State {
        const raw = c.wlr_security_context_manager_v1_lookup_client(@ptrCast(manager), @ptrCast(client));
        return @ptrCast(raw);
    }

    comptime {
        const Real = c.wlr_security_context_manager_v1;
        assertFieldOffset(SecurityContextManagerV1, Real, "global");
        assertFieldOffset(SecurityContextManagerV1, Real, "events");
        assertFieldOffset(SecurityContextManagerV1, Real, "data");

        const Events = @FieldType(SecurityContextManagerV1, "events");
        const RealEvents = @FieldType(Real, "events");
        assertSameLayout(@FieldType(Events, "destroy"), c.wl_signal);
        assertSameLayout(@FieldType(Events, "commit"), c.wl_signal);
        assertFieldOffset(Events, RealEvents, "destroy");
        assertFieldOffset(Events, RealEvents, "commit");
    }
};
