// Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");

const wlr = @import("wlr.zig");

const posix = @import("std").posix;
const wl = @import("wayland").server.wl;
const pixman = @import("pixman");

pub const ShmAttributes = extern struct {
    fd: c_int,
    format: u32,
    width: c_int,
    height: c_int,
    stride: c_int,
    offset: posix.off_t,
};

pub const BufferCap = enum(c_int) {
    data_ptr = c.WLR_BUFFER_CAP_DATA_PTR,
    dmabuf = c.WLR_BUFFER_CAP_DMABUF,
    shm = c.WLR_BUFFER_CAP_SHM,
};

pub const Buffer = extern struct {
    pub const data_ptr_access_flag = struct {
        pub const read = c.WLR_BUFFER_DATA_PTR_ACCESS_READ;
        pub const write = c.WLR_BUFFER_DATA_PTR_ACCESS_WRITE;
    };

    pub const Impl = extern struct {
        destroy: *const fn (buffer: *Buffer) callconv(.c) void,
        get_dmabuf: ?*const fn (buffer: *Buffer, attribs: *wlr.DmabufAttributes) callconv(.c) bool,
        get_shm: ?*const fn (buffer: *Buffer, attribs: *wlr.ShmAttributes) callconv(.c) bool,
        begin_data_ptr_access: ?*const fn (buffer: *Buffer, flags: u32, data: **anyopaque, format: *u32, stride: *usize) callconv(.c) bool,
        end_data_ptr_access: ?*const fn (buffer: *Buffer) callconv(.c) void,
    };

    pub const ResourceInterface = extern struct {
        name: [*:0]const u8,
        is_instance: *const fn (resource: *wl.Resource) callconv(.c) bool,
        from_resource: *const fn (resource: *wl.Resource) callconv(.c) ?*Buffer,
    };

    impl: *const Impl,

    width: c_int,
    height: c_int,

    dropped: bool,
    n_locks: usize,

    accessing_data_ptr: bool,

    events: extern struct {
        destroy: wl.Signal(void),
        release: wl.Signal(void),
    },

    addons: wlr.AddonSet,

    const wlr_buffer_init = abi.bind(fn (buffer: *Buffer, impl: *const Buffer.Impl, width: c_int, height: c_int) callconv(.c) void, c.wlr_buffer_init);
    pub const init = wlr_buffer_init;

    const wlr_buffer_finish = abi.bind(fn (buffer: *Buffer) callconv(.c) void, c.wlr_buffer_finish);
    pub const finish = wlr_buffer_finish;

    const wlr_buffer_drop = abi.bind(fn (buffer: *Buffer) callconv(.c) void, c.wlr_buffer_drop);
    pub const drop = wlr_buffer_drop;

    const wlr_buffer_lock = abi.bind(fn (buffer: *Buffer) callconv(.c) *Buffer, c.wlr_buffer_lock);
    pub const lock = wlr_buffer_lock;

    const wlr_buffer_unlock = abi.bind(fn (buffer: *Buffer) callconv(.c) void, c.wlr_buffer_unlock);
    pub const unlock = wlr_buffer_unlock;

    const wlr_buffer_get_dmabuf = abi.bind(fn (buffer: *Buffer, attribs: *wlr.DmabufAttributes) callconv(.c) bool, c.wlr_buffer_get_dmabuf);
    pub const getDmabuf = wlr_buffer_get_dmabuf;

    const wlr_buffer_get_shm = abi.bind(fn (buffer: *Buffer, attribs: *wlr.ShmAttributes) callconv(.c) bool, c.wlr_buffer_get_shm);
    pub const getShm = wlr_buffer_get_shm;

    const wlr_buffer_register_resource_interface = abi.bind(fn (iface: *const ResourceInterface) callconv(.c) void, c.wlr_buffer_register_resource_interface);
    pub const registerResourceInterface = wlr_buffer_register_resource_interface;

    const wlr_buffer_try_from_resource = abi.bind(fn (resource: *wl.Buffer) callconv(.c) ?*Buffer, c.wlr_buffer_try_from_resource);
    pub const tryFromWlBuffer = wlr_buffer_try_from_resource;

    const wlr_buffer_is_opaque = abi.bind(fn (buffer: *Buffer) callconv(.c) bool, c.wlr_buffer_is_opaque);
    pub const isOpaque = wlr_buffer_is_opaque;

    const wlr_buffer_begin_data_ptr_access = abi.bind(fn (buffer: *Buffer, flags: u32, data: **anyopaque, format: *u32, stride: *usize) callconv(.c) bool, c.wlr_buffer_begin_data_ptr_access);
    pub const beginDataPtrAccess = wlr_buffer_begin_data_ptr_access;

    const wlr_buffer_end_data_ptr_access = abi.bind(fn (buffer: *Buffer) callconv(.c) void, c.wlr_buffer_end_data_ptr_access);
    pub const endDataPtrAccess = wlr_buffer_end_data_ptr_access;
};

pub const ClientBuffer = extern struct {
    base: Buffer,

    texture: ?*wlr.Texture,
    source: ?*wlr.Buffer,

    WLR_PRIVATE: @FieldType(c.wlr_client_buffer, "WLR_PRIVATE"),

    const wlr_client_buffer_get = abi.bind(fn (buffer: *wlr.Buffer) callconv(.c) ?*ClientBuffer, c.wlr_client_buffer_get);
    pub const get = wlr_client_buffer_get;
};

comptime {
    abi.assertLayout(ShmAttributes, c.wlr_shm_attributes);
    abi.assertLayout(Buffer, c.wlr_buffer);
    abi.assertLayout(Buffer.Impl, c.wlr_buffer_impl);
    abi.assertLayout(Buffer.ResourceInterface, c.wlr_buffer_resource_interface);
    abi.assertLayout(ClientBuffer, c.wlr_client_buffer);
}
