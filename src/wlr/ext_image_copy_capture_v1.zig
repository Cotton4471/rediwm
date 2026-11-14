//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const posix = @import("std").posix;

const wayland = @import("wayland");
const wl = wayland.server.wl;
const ext = wayland.server.ext;

const pixman = @import("pixman");

pub const ExtImageCopyCaptureManagerV1 = extern struct {
    global: *wl.Global,

    events: extern struct {
        new_session: wl.Signal(*ExtImageCopyCaptureSessionV1),
    },

    const wlr_ext_image_copy_capture_manager_v1_create = abi.bind(fn (
        display: *wl.Server,
        version: u32,
    ) callconv(.c) ?*ExtImageCopyCaptureManagerV1, c.wlr_ext_image_copy_capture_manager_v1_create);
    pub fn create(
        display: *wl.Server,
        version: u32,
    ) !*ExtImageCopyCaptureManagerV1 {
        return wlr_ext_image_copy_capture_manager_v1_create(display, version) orelse error.OutOfMemory;
    }
};

pub const ExtImageCopyCaptureSessionV1 = extern struct {
    resource: *wl.Resource,
    source: *wlr.ExtImageCaptureSourceV1,
    frame: ?*ExtImageCopyCaptureFrameV1,

    events: extern struct {
        destroy: wl.Signal(void),
    },
};

pub const ExtImageCopyCaptureFrameV1 = extern struct {
    resource: *wl.Resource,
    capturing: bool,
    buffer: ?*wlr.Buffer,
    buffer_damage: pixman.Region32,

    events: extern struct {
        destroy: wl.Signal(void),
    },

    const wlr_ext_image_copy_capture_frame_v1_ready = abi.bind(fn (
        frame: *ExtImageCopyCaptureFrameV1,
        transform: wl.Output.Transform,
        presentation_time: *const posix.timespec,
    ) callconv(.c) void, c.wlr_ext_image_copy_capture_frame_v1_ready);
    pub const ready = wlr_ext_image_copy_capture_frame_v1_ready;

    const wlr_ext_image_copy_capture_frame_v1_fail = abi.bind(fn (
        frame: *ExtImageCopyCaptureFrameV1,
        reason: ext.ImageCopyCaptureFrameV1.FailureReason,
    ) callconv(.c) void, c.wlr_ext_image_copy_capture_frame_v1_fail);
    pub const fail = wlr_ext_image_copy_capture_frame_v1_fail;

    const wlr_ext_image_copy_capture_frame_v1_copy_buffer = abi.bind(fn (
        frame: *ExtImageCopyCaptureFrameV1,
        src: *wlr.Buffer,
        renderer: *wlr.Renderer,
    ) callconv(.c) bool, c.wlr_ext_image_copy_capture_frame_v1_copy_buffer);
    /// False means wlroots reported failure and destroyed the frame.
    /// Only call ready() after a successful copy.
    pub const copyBuffer = wlr_ext_image_copy_capture_frame_v1_copy_buffer;
};

comptime {
    abi.assertFields(ExtImageCopyCaptureManagerV1, c.wlr_ext_image_copy_capture_manager_v1);
    abi.assertFields(ExtImageCopyCaptureSessionV1, c.wlr_ext_image_copy_capture_session_v1);
    abi.assertFields(ExtImageCopyCaptureFrameV1, c.wlr_ext_image_copy_capture_frame_v1);
}
