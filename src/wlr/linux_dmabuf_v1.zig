//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const std = @import("std");
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

pub const DmabufBufferV1 = extern struct {
    base: wlr.Buffer,

    resource: ?*wl.Resource,
    attributes: wlr.DmabufAttributes,

    const wlr_dmabuf_v1_buffer_try_from_buffer_resource = abi.bind(fn (buffer_resource: *wl.Resource) callconv(.c) ?*DmabufBufferV1, c.wlr_dmabuf_v1_buffer_try_from_buffer_resource);
    pub const tryFromBufferResource = wlr_dmabuf_v1_buffer_try_from_buffer_resource;
};

pub const LinuxDmabufFeedbackV1 = extern struct {
    pub const Tranche = extern struct {
        target_device: posix.dev_t,
        flags: zwp.LinuxDmabufFeedbackV1.TrancheFlags,
        formats: wlr.DrmFormatSet,
    };

    main_device: posix.dev_t,
    tranches: wl.Array,

    const wlr_linux_dmabuf_feedback_add_tranche = abi.bind(fn (feedback: *LinuxDmabufFeedbackV1) callconv(.c) ?*Tranche, c.wlr_linux_dmabuf_feedback_add_tranche);
    pub fn addTranche(feedback: *LinuxDmabufFeedbackV1) !*Tranche {
        return wlr_linux_dmabuf_feedback_add_tranche(feedback) orelse error.OutOfMemory;
    }

    const wlr_linux_dmabuf_feedback_v1_finish = abi.bind(fn (feedback: *LinuxDmabufFeedbackV1) callconv(.c) void, c.wlr_linux_dmabuf_feedback_v1_finish);
    pub const finish = wlr_linux_dmabuf_feedback_v1_finish;

    pub const InitOptions = extern struct {
        main_renderer: *wlr.Renderer,
        scanout_primary_output: ?*wlr.Output,
        // TODO: Bind wlr_output_layer and related structs
        output_layer_feedback_event: ?*const anyopaque,
    };
    const wlr_linux_dmabuf_feedback_v1_init_with_options = abi.bind(fn (feedback: *LinuxDmabufFeedbackV1, options: *const InitOptions) callconv(.c) bool, c.wlr_linux_dmabuf_feedback_v1_init_with_options);
    pub const initWithOptions = wlr_linux_dmabuf_feedback_v1_init_with_options;
};

pub const LinuxDmabufFeedbackV1Compiled = opaque {};

pub const LinuxDmabufV1 = extern struct {
    global: *wl.Global,

    events: extern struct {
        destroy: wl.Signal(*LinuxDmabufV1),
    },

    const wlr_linux_dmabuf_v1_create = abi.bind(fn (server: *wl.Server, version: u32, default_feedback: *const LinuxDmabufFeedbackV1) callconv(.c) ?*LinuxDmabufV1, c.wlr_linux_dmabuf_v1_create);
    pub fn create(server: *wl.Server, version: u32, default_feedback: *const LinuxDmabufFeedbackV1) !*LinuxDmabufV1 {
        return wlr_linux_dmabuf_v1_create(server, version, default_feedback) orelse error.OutOfMemory;
    }

    const wlr_linux_dmabuf_v1_create_with_renderer = abi.bind(fn (server: *wl.Server, version: u32, renderer: *wlr.Renderer) callconv(.c) ?*LinuxDmabufV1, c.wlr_linux_dmabuf_v1_create_with_renderer);
    pub fn createWithRenderer(server: *wl.Server, version: u32, renderer: *wlr.Renderer) !*LinuxDmabufV1 {
        return wlr_linux_dmabuf_v1_create_with_renderer(server, version, renderer) orelse error.OutOfMemory;
    }

    const wlr_linux_dmabuf_v1_set_surface_feedback = abi.bind(fn (linux_dmabuf: *LinuxDmabufV1, surface: *wlr.Surface, feedback: ?*const LinuxDmabufFeedbackV1) callconv(.c) bool, c.wlr_linux_dmabuf_v1_set_surface_feedback);
    pub const setSurfaceFeedback = wlr_linux_dmabuf_v1_set_surface_feedback;
};

comptime {
    abi.assertFields(DmabufBufferV1, c.wlr_dmabuf_v1_buffer);
    abi.assertFields(LinuxDmabufFeedbackV1, c.wlr_linux_dmabuf_feedback_v1);
    @import("signal.zig").assertSameLayout(LinuxDmabufFeedbackV1, c.wlr_linux_dmabuf_feedback_v1);
    abi.assertFields(LinuxDmabufFeedbackV1.Tranche, c.wlr_linux_dmabuf_feedback_v1_tranche);
    @import("signal.zig").assertSameLayout(LinuxDmabufFeedbackV1.Tranche, c.wlr_linux_dmabuf_feedback_v1_tranche);
    abi.assertFields(LinuxDmabufFeedbackV1.InitOptions, c.wlr_linux_dmabuf_feedback_v1_init_options);
    @import("signal.zig").assertSameLayout(LinuxDmabufFeedbackV1.InitOptions, c.wlr_linux_dmabuf_feedback_v1_init_options);
    abi.assertFields(LinuxDmabufV1, c.wlr_linux_dmabuf_v1);
}
