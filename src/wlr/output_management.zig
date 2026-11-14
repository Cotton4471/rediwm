//! Output management uses the facade's Output and Output.State throughout,
//! including client configurations received through the apply/test signals.
//! Only wlroots allocates the manager and heads, so their private tails are
//! omitted; the embedded head state and complete configuration retain their
//! full C layouts.
const wl = @import("wayland").server.wl;
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub fn Types(comptime Output: type) type {
    return struct {
        pub const OutputManagerV1 = extern struct {
            server: *wl.Server,
            global: *wl.Global,
            resources: wl.list.Head(wl.Resource, null),
            heads: wl.list.Head(OutputHeadV1, .link),
            serial: u32,
            current_configuration_dirty: bool,

            events: extern struct {
                apply: wl.Signal(*OutputConfigurationV1),
                @"test": wl.Signal(*OutputConfigurationV1),
                destroy: wl.Signal(*OutputManagerV1),
            },

            data: ?*anyopaque,

            pub fn create(server: *wl.Server) !*OutputManagerV1 {
                const raw = c.wlr_output_manager_v1_create(@ptrCast(server));
                return @as(?*OutputManagerV1, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            /// Transfers ownership of the configuration to wlroots.
            pub fn setConfiguration(manager: *OutputManagerV1, config: *OutputConfigurationV1) void {
                c.wlr_output_manager_v1_set_configuration(@ptrCast(manager), @ptrCast(config));
            }

            comptime {
                const Real = c.wlr_output_manager_v1;
                if (@offsetOf(OutputManagerV1, "server") != @offsetOf(Real, "display"))
                    @compileError("OutputManagerV1.server offset drifted from wlr_output_manager_v1.display");
                assertSameLayout(@FieldType(OutputManagerV1, "server"), @FieldType(Real, "display"));
                for (.{ "global", "resources", "heads", "serial", "current_configuration_dirty", "events", "data" }) |field| {
                    assertFieldOffset(OutputManagerV1, Real, field);
                    assertSameLayout(@FieldType(OutputManagerV1, field), @FieldType(Real, field));
                }

                const Events = @FieldType(OutputManagerV1, "events");
                const RealEvents = @FieldType(Real, "events");
                for (.{ "apply", "test", "destroy" }) |field| {
                    assertFieldOffset(Events, RealEvents, field);
                    assertSameLayout(@FieldType(Events, field), c.wl_signal);
                }
            }
        };

        pub const OutputHeadV1 = extern struct {
            pub const State = extern struct {
                output: *Output,
                enabled: bool,
                mode: ?*Output.Mode,
                custom_mode: @FieldType(c.wlr_output_head_v1_state, "custom_mode"),
                x: i32,
                y: i32,
                transform: wl.Output.Transform,
                scale: f32,
                adaptive_sync_enabled: bool,

                pub fn apply(state: *const State, output_state: *Output.State) void {
                    c.wlr_output_head_v1_state_apply(@ptrCast(state), @ptrCast(output_state));
                }

                comptime {
                    const Real = c.wlr_output_head_v1_state;
                    assertSameLayout(State, Real);
                    for (@typeInfo(State).@"struct".field_names) |field_name| {
                        assertFieldOffset(State, Real, field_name);
                        assertSameLayout(@FieldType(State, field_name), @FieldType(Real, field_name));
                    }
                }
            };

            state: State,
            manager: *OutputManagerV1,
            link: wl.list.Link,
            resources: wl.list.Head(wl.Resource, null),
            mode_resources: wl.list.Head(wl.Resource, null),

            comptime {
                const Real = c.wlr_output_head_v1;
                for (@typeInfo(OutputHeadV1).@"struct".field_names) |field_name| {
                    assertFieldOffset(OutputHeadV1, Real, field_name);
                    assertSameLayout(@FieldType(OutputHeadV1, field_name), @FieldType(Real, field_name));
                }
            }
        };

        pub const OutputConfigurationV1 = extern struct {
            pub const Head = extern struct {
                state: OutputHeadV1.State,
                config: *OutputConfigurationV1,
                link: wl.list.Link,
                resource: ?*wl.Resource,

                pub fn create(config: *OutputConfigurationV1, output: *Output) !*Head {
                    const raw = c.wlr_output_configuration_head_v1_create(@ptrCast(config), @ptrCast(output));
                    return @as(?*Head, @ptrCast(raw)) orelse error.OutOfMemory;
                }

                comptime {
                    const Real = c.wlr_output_configuration_head_v1;
                    for (@typeInfo(Head).@"struct".field_names) |field_name| {
                        assertFieldOffset(Head, Real, field_name);
                        assertSameLayout(@FieldType(Head, field_name), @FieldType(Real, field_name));
                    }
                }
            };

            heads: wl.list.Head(Head, .link),
            manager: ?*OutputManagerV1,
            serial: u32,
            finalized: bool,
            finished: bool,
            resource: ?*wl.Resource,

            pub fn create() !*OutputConfigurationV1 {
                const raw = c.wlr_output_configuration_v1_create();
                return @as(?*OutputConfigurationV1, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            pub fn destroy(config: *OutputConfigurationV1) void {
                c.wlr_output_configuration_v1_destroy(@ptrCast(config));
            }

            pub fn sendSucceeded(config: *OutputConfigurationV1) void {
                c.wlr_output_configuration_v1_send_succeeded(@ptrCast(config));
            }

            pub fn sendFailed(config: *OutputConfigurationV1) void {
                c.wlr_output_configuration_v1_send_failed(@ptrCast(config));
            }

            comptime {
                const Real = c.wlr_output_configuration_v1;
                assertSameLayout(OutputConfigurationV1, Real);
                for (@typeInfo(OutputConfigurationV1).@"struct".field_names) |field_name| {
                    assertFieldOffset(OutputConfigurationV1, Real, field_name);
                    assertSameLayout(@FieldType(OutputConfigurationV1, field_name), @FieldType(Real, field_name));
                }
            }
        };
    };
}
