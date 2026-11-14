//! Typed wlroots header adapter. API shapes adapted from zig-wlroots;
//! see LICENSE.zig-wlroots for its MIT license.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const posix = @import("std").posix;

const pixman = @import("pixman");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const Compositor = extern struct {
    global: *wl.Global,
    renderer: ?*wlr.Renderer,

    events: extern struct {
        new_surface: wl.Signal(*wlr.Surface),
        destroy: wl.Signal(*wlr.Compositor),
    },

    const wlr_compositor_create = abi.bind(fn (server: *wl.Server, version: u32, renderer: ?*wlr.Renderer) callconv(.c) ?*Compositor, c.wlr_compositor_create);
    pub fn create(server: *wl.Server, version: u32, renderer: ?*wlr.Renderer) !*Compositor {
        return wlr_compositor_create(server, version, renderer) orelse error.OutOfMemory;
    }

    const wlr_compositor_set_renderer = abi.bind(fn (compositor: *Compositor, renderer: ?*wlr.Renderer) callconv(.c) void, c.wlr_compositor_set_renderer);
    pub const setRenderer = wlr_compositor_set_renderer;
};

pub const Surface = extern struct {
    pub const State = extern struct {
        pub const Fields = packed struct(u32) {
            buffer: bool = false,
            surface_damage: bool = false,
            buffer_damage: bool = false,
            opaque_region: bool = false,
            input_region: bool = false,
            transform: bool = false,
            scale: bool = false,
            frame_callback_list: bool = false,
            viewport: bool = false,
            offset: bool = false,
            _: u22 = 0,
        };

        committed: Fields,
        seq: u32,

        buffer: ?*wlr.Buffer,
        dx: i32,
        dy: i32,
        surface_damage: pixman.Region32,
        buffer_damage: pixman.Region32,
        @"opaque": pixman.Region32,
        input: pixman.Region32,
        transform: wl.Output.Transform,
        scale: i32,
        frame_callback_list: wl.list.Head(wl.Callback, null),

        width: c_int,
        height: c_int,
        buffer_width: c_int,
        buffer_height: c_int,

        subsurfaces_below: wl.list.Head(wlr.Subsurface.ParentState, .link),
        subsurfaces_above: wl.list.Head(wlr.Subsurface.ParentState, .link),

        viewport: extern struct {
            has_src: bool,
            has_dst: bool,
            src: wlr.FBox,
            dst_width: c_int,
            dst_height: c_int,
        },

        cached_state_locks: usize,
        cached_state_link: wl.list.Link,

        synced: wl.Array,

        const wlr_surface_state_has_buffer = abi.bind(fn (state: *State) callconv(.c) bool, c.wlr_surface_state_has_buffer);
        pub const hasBuffer = wlr_surface_state_has_buffer;
    };

    pub const Role = extern struct {
        name: [*:0]const u8,
        no_object: bool = false,
        client_commit: ?*const fn (surface: *Surface) callconv(.c) void = null,
        commit: ?*const fn (surface: *Surface) callconv(.c) void = null,
        map: ?*const fn (surface: *Surface) callconv(.c) void = null,
        unmap: ?*const fn (surface: *Surface) callconv(.c) void = null,
        destroy: ?*const fn (surface: *Surface) callconv(.c) void = null,
    };

    pub const Output = extern struct {
        surface: *wlr.Surface,
        output: *wlr.Output,

        // Surface.current_outputs
        link: wl.list.Link,
    };

    pub const Synced = extern struct {
        pub const Impl = extern struct {
            state_size: usize,
            init_state: ?*const fn (state: *anyopaque) callconv(.c) void,
            finish_state: ?*const fn (state: *anyopaque) callconv(.c) void,
            move_state: ?*const fn (dst: *anyopaque, src: *anyopaque) callconv(.c) void,
            commit: ?*const fn (synced: *Synced) callconv(.c) void = null,
        };

        surface: *Surface,
        impl: *const Impl,
        /// wlr.Surface.synced
        link: wl.list.Link,
        index: usize,

        const wlr_surface_synced_init = abi.bind(fn (
            synced: *Synced,
            surface: *Surface,
            impl: *const Impl,
            pending: *anyopaque,
            current: *anyopaque,
        ) callconv(.c) bool, c.wlr_surface_synced_init);
        pub inline fn init(
            synced: *Synced,
            surface: *Surface,
            impl: *const Impl,
            pending: *anyopaque,
            current: *anyopaque,
        ) error{OutOfMemory}!void {
            if (!wlr_surface_synced_init(synced, surface, impl, pending, current)) {
                return error.OutOfMemory;
            }
        }

        const wlr_surface_synced_finish = abi.bind(fn (synced: *Synced) callconv(.c) void, c.wlr_surface_synced_finish);
        pub const deinit = wlr_surface_synced_finish;

        const wlr_surface_synced_get_state = abi.bind(fn (synced: *Synced, state: *const Surface.State) callconv(.c) *anyopaque, c.wlr_surface_synced_get_state);
        pub const getState = wlr_surface_synced_get_state;
    };

    resource: *wl.Surface,
    compositor: *wlr.Compositor,

    buffer: ?*wlr.ClientBuffer,

    buffer_damage: pixman.Region32,
    opaque_region: pixman.Region32,
    input_region: pixman.Region32,

    current: State,
    pending: State,

    cached: wl.list.Head(Surface.State, .cached_state_link),

    mapped: bool,

    role: ?*const Role,
    role_resource: ?*wl.Resource,

    events: extern struct {
        client_commit: wl.Signal(void),
        commit: wl.Signal(*wlr.Surface),
        map: wl.Signal(void),
        unmap: wl.Signal(void),
        new_subsurface: wl.Signal(*wlr.Subsurface),
        destroy: wl.Signal(*wlr.Surface),
    },

    current_outputs: wl.list.Head(Surface.Output, .link),

    addons: wlr.AddonSet,
    data: ?*anyopaque,

    const wlr_surface_set_role = abi.bind(fn (
        surface: *Surface,
        role: *const Role,
        error_resource: ?*wl.Resource,
        error_code: u32,
    ) callconv(.c) bool, c.wlr_surface_set_role);
    pub const setRole = wlr_surface_set_role;

    const wlr_surface_set_role_object = abi.bind(fn (surface: *Surface, role_resource: *wl.Resource) callconv(.c) void, c.wlr_surface_set_role_object);
    pub const setRoleObject = wlr_surface_set_role_object;

    const wlr_surface_map = abi.bind(fn (surface: *Surface) callconv(.c) void, c.wlr_surface_map);
    pub const map = wlr_surface_map;

    const wlr_surface_unmap = abi.bind(fn (surface: *Surface) callconv(.c) void, c.wlr_surface_unmap);
    pub const unmap = wlr_surface_unmap;

    const wlr_surface_has_buffer = abi.bind(fn (surface: *Surface) callconv(.c) bool, c.wlr_surface_has_buffer);
    pub const hasBuffer = wlr_surface_has_buffer;

    const wlr_surface_get_texture = abi.bind(fn (surface: *Surface) callconv(.c) ?*wlr.Texture, c.wlr_surface_get_texture);
    pub const getTexture = wlr_surface_get_texture;

    const wlr_surface_get_root_surface = abi.bind(fn (surface: *Surface) callconv(.c) *Surface, c.wlr_surface_get_root_surface);
    pub const getRootSurface = wlr_surface_get_root_surface;

    const wlr_surface_point_accepts_input = abi.bind(fn (surface: *Surface, sx: f64, sy: f64) callconv(.c) bool, c.wlr_surface_point_accepts_input);
    pub const pointAcceptsInput = wlr_surface_point_accepts_input;

    const wlr_surface_surface_at = abi.bind(fn (surface: *Surface, sx: f64, sy: f64, sub_x: *f64, sub_y: *f64) callconv(.c) ?*Surface, c.wlr_surface_surface_at);
    pub const surfaceAt = wlr_surface_surface_at;

    const wlr_surface_send_enter = abi.bind(fn (surface: *Surface, output: *wlr.Output) callconv(.c) void, c.wlr_surface_send_enter);
    pub const sendEnter = wlr_surface_send_enter;

    const wlr_surface_send_leave = abi.bind(fn (surface: *Surface, output: *wlr.Output) callconv(.c) void, c.wlr_surface_send_leave);
    pub const sendLeave = wlr_surface_send_leave;

    const wlr_surface_send_frame_done = abi.bind(fn (surface: *Surface, when: *const posix.timespec) callconv(.c) void, c.wlr_surface_send_frame_done);
    pub const sendFrameDone = wlr_surface_send_frame_done;

    const wlr_surface_get_extents = abi.bind(fn (surface: *Surface, box: *wlr.Box) callconv(.c) void, c.wlr_surface_get_extents);
    pub const getExtents = wlr_surface_get_extents;

    const wlr_surface_from_resource = abi.bind(fn (resource: *wl.Surface) callconv(.c) *Surface, c.wlr_surface_from_resource);
    pub const fromWlSurface = wlr_surface_from_resource;

    const wlr_surface_for_each_surface = abi.bind(fn (
        surface: *Surface,
        iterator: *const fn (surface: *Surface, sx: c_int, sy: c_int, data: ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
    ) callconv(.c) void, c.wlr_surface_for_each_surface);
    pub inline fn forEachSurface(
        surface: *Surface,
        comptime T: type,
        comptime iterator: fn (surface: *Surface, sx: c_int, sy: c_int, data: T) void,
        data: T,
    ) void {
        wlr_surface_for_each_surface(
            surface,
            struct {
                fn wrapper(s: *Surface, sx: c_int, sy: c_int, d: ?*anyopaque) callconv(.c) void {
                    iterator(s, sx, sy, @ptrCast(@alignCast(d)));
                }
            }.wrapper,
            data,
        );
    }

    const wlr_surface_get_effective_damage = abi.bind(fn (surface: *Surface, damage: *pixman.Region32) callconv(.c) void, c.wlr_surface_get_effective_damage);
    pub const getEffectiveDamage = wlr_surface_get_effective_damage;

    const wlr_surface_get_buffer_source_box = abi.bind(fn (surface: *Surface, box: *wlr.FBox) callconv(.c) void, c.wlr_surface_get_buffer_source_box);
    pub const getBufferSourceBox = wlr_surface_get_buffer_source_box;

    const wlr_surface_accepts_touch = abi.bind(fn (surface: *Surface, seat: *wlr.Seat) callconv(.c) bool, c.wlr_surface_accepts_touch);
    pub const acceptsTouch = wlr_surface_accepts_touch;

    const wlr_surface_accepts_tablet_v2 = abi.bind(fn (surface: *Surface, tablet: *wlr.TabletV2Tablet) callconv(.c) bool, c.wlr_surface_accepts_tablet_v2);
    pub const acceptsTabletV2 = wlr_surface_accepts_tablet_v2;

    const wlr_surface_lock_pending = abi.bind(fn (surface: *Surface) callconv(.c) u32, c.wlr_surface_lock_pending);
    pub const lockPending = wlr_surface_lock_pending;

    const wlr_surface_unlock_cached = abi.bind(fn (surface: *Surface, seq: u32) callconv(.c) void, c.wlr_surface_unlock_cached);
    pub const unlockCached = wlr_surface_unlock_cached;

    const wlr_surface_set_preferred_buffer_scale = abi.bind(fn (surface: *Surface, scale: i32) callconv(.c) void, c.wlr_surface_set_preferred_buffer_scale);
    pub const setPreferredBufferScale = wlr_surface_set_preferred_buffer_scale;

    const wlr_surface_set_preferred_buffer_transform = abi.bind(fn (surface: *Surface, transform: wl.Output.Transform) callconv(.c) void, c.wlr_surface_set_preferred_buffer_transform);
    pub const setPreferredBufferTransform = wlr_surface_set_preferred_buffer_transform;
};

comptime {
    @setEvalBranchQuota(10000);
    abi.assertFields(Compositor, c.wlr_compositor);
    abi.assertFields(Surface, c.wlr_surface);
    abi.assertLayout(Surface.State, c.wlr_surface_state);
    abi.assertLayout(Surface.Role, c.wlr_surface_role);
    abi.assertFields(Surface.Output, c.wlr_surface_output);
    abi.assertLayout(Surface.Synced, c.wlr_surface_synced);
    abi.assertLayout(Surface.Synced.Impl, c.wlr_surface_synced_impl);
}
