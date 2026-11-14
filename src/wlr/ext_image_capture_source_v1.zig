//! Header-checked wlroots protocol API. Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const posix = @import("std").posix;

const wayland = @import("wayland");
const wl = wayland.server.wl;

const pixman = @import("pixman");

pub const ExtImageCaptureSourceV1 = extern struct {
    pub const Interface = extern struct {
        start: ?*const fn (source: *ExtImageCaptureSourceV1, with_cursors: bool) callconv(.c) void,
        stop: ?*const fn (source: *ExtImageCaptureSourceV1) callconv(.c) void,
        request_frame: ?*const fn (source: *ExtImageCaptureSourceV1, schedule_frame: bool) callconv(.c) void,
        copy_frame: *const fn (
            source: *ExtImageCaptureSourceV1,
            dst_frame: *wlr.ExtImageCopyCaptureFrameV1,
            frame_event: *event.Frame,
        ) callconv(.c) void,
        get_pointer_cursor: ?*const fn (source: *ExtImageCaptureSourceV1, seat: *wlr.Seat) callconv(.c) *Cursor,
    };

    pub const event = struct {
        pub const Frame = extern struct {
            damage: *const pixman.Region32,
        };
    };

    impl: *const Interface,
    resources: wl.list.Head(wl.Resource, null),

    width: u32,
    height: u32,

    shm_formats: ?[*]u32,
    shm_formats_len: usize,

    dmabuf_device: posix.dev_t,
    dmabuf_formats: wlr.DrmFormatSet,

    events: extern struct {
        constraints_update: wl.Signal(void),
        frame: wl.Signal(*event.Frame),
        destroy: wl.Signal(void),
    },

    const wlr_ext_image_capture_source_v1_init = abi.bind(fn (source: *ExtImageCaptureSourceV1, impl: *const Interface) callconv(.c) void, c.wlr_ext_image_capture_source_v1_init);
    pub const init = wlr_ext_image_capture_source_v1_init;

    const wlr_ext_image_capture_source_v1_finish = abi.bind(fn (source: *ExtImageCaptureSourceV1) callconv(.c) void, c.wlr_ext_image_capture_source_v1_finish);
    pub const finish = wlr_ext_image_capture_source_v1_finish;

    const wlr_ext_image_capture_source_v1_create_resource = abi.bind(fn (
        source: *ExtImageCaptureSourceV1,
        client: *wl.Client,
        new_id: u32,
    ) callconv(.c) bool, c.wlr_ext_image_capture_source_v1_create_resource);
    pub const createResource = wlr_ext_image_capture_source_v1_create_resource;

    const wlr_ext_image_capture_source_v1_set_constraints_from_swapchain = abi.bind(fn (
        source: *ExtImageCaptureSourceV1,
        swapchain: *wlr.Swapchain,
        renderer: *wlr.Renderer,
    ) callconv(.c) bool, c.wlr_ext_image_capture_source_v1_set_constraints_from_swapchain);
    pub const setContraintsFromSwapchain = wlr_ext_image_capture_source_v1_set_constraints_from_swapchain;

    const wlr_ext_image_capture_source_v1_from_resource = abi.bind(fn (resource: *wl.Resource) callconv(.c) ?*ExtImageCaptureSourceV1, c.wlr_ext_image_capture_source_v1_from_resource);
    pub const fromResource = wlr_ext_image_capture_source_v1_from_resource;

    pub const Cursor = extern struct {
        base: ExtImageCaptureSourceV1,

        entered: bool,
        x: i32,
        y: i32,
        hotspot: extern struct {
            x: i32,
            y: i32,
        },

        events: extern struct {
            update: wl.Signal(void),
        },

        const wlr_ext_image_capture_source_v1_cursor_init = abi.bind(fn (source_cursor: *Cursor, impl: *const Interface) callconv(.c) void, c.wlr_ext_image_capture_source_v1_cursor_init);
        pub const init = wlr_ext_image_capture_source_v1_cursor_init;

        const wlr_ext_image_capture_source_v1_cursor_finish = abi.bind(fn (source_cursor: *Cursor) callconv(.c) void, c.wlr_ext_image_capture_source_v1_cursor_finish);
        pub const finish = wlr_ext_image_capture_source_v1_cursor_finish;
    };

    const wlr_output_try_from_ext_image_capture_source_v1 = abi.bind(fn (source: *ExtImageCaptureSourceV1) callconv(.c) ?*wlr.Output, c.wlr_output_try_from_ext_image_capture_source_v1);
    pub const toOutput = wlr_output_try_from_ext_image_capture_source_v1;

    const wlr_ext_image_capture_source_v1_create_with_scene_node = abi.bind(fn (
        node: *wlr.SceneNode,
        event_loop: *wl.EventLoop,
        allocator: *wlr.Allocator,
        renderer: *wlr.Renderer,
    ) callconv(.c) ?*ExtImageCaptureSourceV1, c.wlr_ext_image_capture_source_v1_create_with_scene_node);
    pub fn createWithSceneNode(
        node: *wlr.SceneNode,
        event_loop: *wl.EventLoop,
        allocator: *wlr.Allocator,
        renderer: *wlr.Renderer,
    ) !*ExtImageCaptureSourceV1 {
        return wlr_ext_image_capture_source_v1_create_with_scene_node(
            node,
            event_loop,
            allocator,
            renderer,
        ) orelse error.OutOfMemory;
    }
};

pub const ExtOutputImageCaptureSourceManagerV1 = extern struct {
    global: *wl.Global,

    const wlr_ext_output_image_capture_source_manager_v1_create = abi.bind(fn (
        server: *wl.Server,
        version: u32,
    ) callconv(.c) ?*ExtOutputImageCaptureSourceManagerV1, c.wlr_ext_output_image_capture_source_manager_v1_create);
    pub fn create(server: *wl.Server, version: u32) !*ExtOutputImageCaptureSourceManagerV1 {
        return wlr_ext_output_image_capture_source_manager_v1_create(server, version) orelse error.OutOfMemory;
    }
};

pub const ExtForeignToplevelImageCaptureSourceManagerV1 = extern struct {
    pub const Request = extern struct {
        toplevel_handle: *wlr.ExtForeignToplevelHandleV1,
        client: *wl.Client,

        const wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request_accept = abi.bind(fn (
            request: *Request,
            source: *ExtImageCaptureSourceV1,
        ) callconv(.c) bool, c.wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request_accept);
        pub const accept = wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request_accept;
    };

    global: *wl.Global,

    events: extern struct {
        destroy: wl.Signal(void),
        new_request: wl.Signal(*Request),
    },

    const wlr_ext_foreign_toplevel_image_capture_source_manager_v1_create = abi.bind(fn (
        server: *wl.Server,
        version: u32,
    ) callconv(.c) ?*ExtForeignToplevelImageCaptureSourceManagerV1, c.wlr_ext_foreign_toplevel_image_capture_source_manager_v1_create);
    pub fn create(server: *wl.Server, version: u32) !*ExtForeignToplevelImageCaptureSourceManagerV1 {
        return wlr_ext_foreign_toplevel_image_capture_source_manager_v1_create(
            server,
            version,
        ) orelse error.OutOfMemory;
    }
};

comptime {
    abi.assertFields(ExtImageCaptureSourceV1, c.wlr_ext_image_capture_source_v1);
    @import("signal.zig").assertSameLayout(ExtImageCaptureSourceV1, c.wlr_ext_image_capture_source_v1);
    abi.assertFields(ExtImageCaptureSourceV1.Interface, c.wlr_ext_image_capture_source_v1_interface);
    @import("signal.zig").assertSameLayout(ExtImageCaptureSourceV1.Interface, c.wlr_ext_image_capture_source_v1_interface);
    abi.assertFields(ExtImageCaptureSourceV1.event.Frame, c.wlr_ext_image_capture_source_v1_frame_event);
    @import("signal.zig").assertSameLayout(ExtImageCaptureSourceV1.event.Frame, c.wlr_ext_image_capture_source_v1_frame_event);
    abi.assertFields(ExtImageCaptureSourceV1.Cursor, c.wlr_ext_image_capture_source_v1_cursor);
    @import("signal.zig").assertSameLayout(ExtImageCaptureSourceV1.Cursor, c.wlr_ext_image_capture_source_v1_cursor);
    abi.assertFields(ExtOutputImageCaptureSourceManagerV1, c.wlr_ext_output_image_capture_source_manager_v1);
    abi.assertFields(ExtForeignToplevelImageCaptureSourceManagerV1, c.wlr_ext_foreign_toplevel_image_capture_source_manager_v1);
    abi.assertFields(ExtForeignToplevelImageCaptureSourceManagerV1.Request, c.wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request);
}
