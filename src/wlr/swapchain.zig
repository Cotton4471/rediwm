// Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");

const wlr = @import("wlr.zig");

const wayland = @import("wayland");
const wl = wayland.server.wl;

pub const Swapchain = extern struct {
    pub const Slot = extern struct {
        buffer: ?*wlr.Buffer,
        /// Waiting for release
        acquired: bool,

        WLR_PRIVATE: @FieldType(c.wlr_swapchain_slot, "WLR_PRIVATE"),
    };

    /// `null` if destroyed
    allocator: ?*wlr.Allocator,

    width: c_int,
    height: c_int,
    format: wlr.DrmFormat,

    slots: [4]Slot,

    WLR_PRIVATE: @FieldType(c.wlr_swapchain, "WLR_PRIVATE"),

    const wlr_swapchain_create = abi.bind(fn (alloc: *wlr.Allocator, width: c_int, height: c_int, format: *const wlr.DrmFormat) callconv(.c) ?*Swapchain, c.wlr_swapchain_create);
    pub fn create(alloc: *wlr.Allocator, width: c_int, height: c_int, format: *const wlr.DrmFormat) !*Swapchain {
        return wlr_swapchain_create(alloc, width, height, format) orelse error.SwapchainCreateFailed;
    }

    const wlr_swapchain_destroy = abi.bind(fn (swapchain: *Swapchain) callconv(.c) void, c.wlr_swapchain_destroy);
    pub const destroy = wlr_swapchain_destroy;

    /// Acquire a buffer from the swap chain.
    ///
    /// The returned buffer is locked. When the caller is done with it, they must
    /// unlock it by calling `wlr.Buffer.unlock`.
    const wlr_swapchain_acquire = abi.bind(fn (swapchain: *Swapchain) callconv(.c) ?*wlr.Buffer, c.wlr_swapchain_acquire);
    pub fn acquire(swapchain: *Swapchain) !*wlr.Buffer {
        return wlr_swapchain_acquire(swapchain) orelse error.SwapchainAquireBufferFailed;
    }

    /// Returns `true` if this buffer has been created by this swapchain, and false otherwise
    const wlr_swapchain_has_buffer = abi.bind(fn (swapchain: *Swapchain, buffer: *wlr.Buffer) callconv(.c) bool, c.wlr_swapchain_has_buffer);
    pub const hasBuffer = wlr_swapchain_has_buffer;
};

comptime {
    abi.assertLayout(Swapchain, c.wlr_swapchain);
    abi.assertLayout(Swapchain.Slot, c.wlr_swapchain_slot);
}
