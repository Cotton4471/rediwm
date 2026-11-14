// Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");

const std = @import("std");

pub const Importance = enum(c_int) {
    silent = c.WLR_SILENT,
    err = c.WLR_ERROR,
    info = c.WLR_INFO,
    debug = c.WLR_DEBUG,
    last = c.WLR_LOG_IMPORTANCE_LAST,
};

const wlr_log_init = abi.bind(fn (
    verbosity: Importance,
    callback: ?*const fn (importance: Importance, fmt: [*:0]const u8, args: *std.lang.VaList) callconv(.c) void,
) callconv(.c) void, c.wlr_log_init);
pub const init = wlr_log_init;

const wlr_log_get_verbosity = abi.bind(fn () callconv(.c) Importance, c.wlr_log_get_verbosity);
pub const getVerbosity = wlr_log_get_verbosity;
