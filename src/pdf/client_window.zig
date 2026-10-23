//! Globals and window events: the registry, outputs and scale, the seat, xdg surface and toplevel, and decorations.

const std = @import("std");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const a = std.heap.c_allocator;
const main_mod = @import("main.zig");
const Client = main_mod.Client;
const CSD_TITLEBAR_H = main_mod.CSD_TITLEBAR_H;
const OutputInfo = main_mod.OutputInfo;
const dataDeviceEvent = main_mod.dataDeviceEvent;
const pointerEvent = Client.pointerEvent;
const keyboardEvent = Client.keyboardEvent;

pub fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Client) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.span(g.interface);
            self.cursor_shape.bind(registry, g.name, iface, g.version);
            if (std.mem.eql(u8, iface, "wl_compositor")) {
                self.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 5)) catch null;
            } else if (std.mem.eql(u8, iface, "wl_shm")) {
                self.shm = registry.bind(g.name, wl.Shm, 1) catch null;
            } else if (std.mem.eql(u8, iface, "wl_output")) {
                if (registry.bind(g.name, wl.Output, @min(g.version, 4)) catch null) |proxy| {
                    const info = a.create(OutputInfo) catch {
                        proxy.destroy();
                        return;
                    };
                    info.* = .{ .client = self, .proxy = proxy, .name = g.name };
                    self.outputs.append(a, info) catch {
                        proxy.destroy();
                        a.destroy(info);
                        return;
                    };
                    proxy.setListener(*OutputInfo, outputEvent, info);
                }
            } else if (std.mem.eql(u8, iface, "zxdg_output_manager_v1")) {
                self.output_manager = registry.bind(g.name, zxdg.OutputManagerV1, @min(g.version, 3)) catch null;
            } else if (std.mem.eql(u8, iface, "wl_seat") and self.seat == null) {
                self.seat = registry.bind(g.name, wl.Seat, @min(g.version, 7)) catch null;
                if (self.seat) |seat| seat.setListener(*Client, seatEvent, self);
            } else if (std.mem.eql(u8, iface, "xdg_activation_v1")) {
                self.activation = registry.bind(g.name, xdg.ActivationV1, 1) catch null;
            } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                self.wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 2)) catch null;
                if (self.wm_base) |wm| wm.setListener(*Client, wmBaseEvent, self);
            } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
                self.decoration_manager = registry.bind(g.name, zxdg.DecorationManagerV1, 1) catch null;
            } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
                self.data_manager = registry.bind(g.name, wl.DataDeviceManager, @min(g.version, 3)) catch null;
            }
        },
        .global_remove => |ev| {
            for (self.outputs.items, 0..) |info, i| {
                if (info.name == ev.name) {
                    _ = self.outputs.swapRemove(i);
                    self.removeEnteredOutput(info);
                    if (info.logical) |logical| logical.destroy();
                    info.proxy.destroy();
                    a.destroy(info);
                    self.recomputeScale();
                    break;
                }
            }
        },
    }
}

pub fn outputEvent(proxy: *wl.Output, event: wl.Output.Event, info: *OutputInfo) void {
    switch (event) {
        .scale => |ev| {
            info.scale = ev.factor;
            info.client.recomputeScale();
        },
        else => {},
    }
    _ = proxy;
}

pub fn logicalOutputEvent(_: *zxdg.OutputV1, event: zxdg.OutputV1.Event, info: *OutputInfo) void {
    switch (event) {
        .logical_size => |ev| {
            info.logical_width = ev.width;
            info.logical_height = ev.height;
        },
        else => {},
    }
}

pub fn surfaceEvent(_: *wl.Surface, event: wl.Surface.Event, self: *Client) void {
    switch (event) {
        .enter => |ev| {
            for (self.outputs.items) |info| {
                if (info.proxy == ev.output) {
                    self.entered_outputs.append(a, info) catch return;
                    self.recomputeScale();
                    break;
                }
            }
        },
        .leave => |ev| {
            for (self.entered_outputs.items, 0..) |info, i| {
                if (info.proxy == ev.output) {
                    _ = self.entered_outputs.swapRemove(i);
                    self.recomputeScale();
                    break;
                }
            }
        },
    }
}

pub fn removeEnteredOutput(self: *Client, info: *OutputInfo) void {
    for (self.entered_outputs.items, 0..) |entered, i| {
        if (entered == info) {
            _ = self.entered_outputs.swapRemove(i);
            break;
        }
    }
}

pub fn recomputeScale(self: *Client) void {
    var max_scale: i32 = 1;
    for (self.entered_outputs.items) |info| {
        if (info.scale > max_scale) max_scale = info.scale;
    }
    if (self.scale != max_scale) {
        self.scale = max_scale;
        self.app.scale = max_scale;
        self.app.dirty = true;
    }
}

pub fn wmBaseEvent(wm: *xdg.WmBase, event: xdg.WmBase.Event, _: *Client) void {
    switch (event) {
        .ping => |ev| wm.pong(ev.serial),
    }
}

pub fn seatEvent(_: *wl.Seat, event: wl.Seat.Event, self: *Client) void {
    switch (event) {
        .capabilities => |ev| {
            if (ev.capabilities.pointer and self.pointer == null) {
                self.pointer = self.seat.?.getPointer() catch null;
                if (self.pointer) |p| p.setListener(*Client, pointerEvent, self);
            }
            if (!ev.capabilities.pointer) {
                if (self.pointer) |p| p.release();
                self.pointer = null;
            }
            if (ev.capabilities.keyboard and self.keyboard == null) {
                self.keyboard = self.seat.?.getKeyboard() catch null;
                if (self.keyboard) |k| k.setListener(*Client, keyboardEvent, self);
            }
            if (!ev.capabilities.keyboard) {
                if (self.keyboard) |k| k.release();
                self.keyboard = null;
            }
            if (self.data_manager) |mgr| {
                if (self.data_device == null) {
                    self.data_device = mgr.getDataDevice(self.seat.?) catch null;
                    if (self.data_device) |device| device.setListener(*Client, dataDeviceEvent, self);
                }
            }
        },
        else => {},
    }
}

pub fn xdgSurfaceEvent(xdg_surf: *xdg.Surface, event: xdg.Surface.Event, self: *Client) void {
    switch (event) {
        .configure => |ev| {
            xdg_surf.ackConfigure(ev.serial);
            self.configured = true;
            self.app.dirty = true;
        },
    }
}

pub fn wantsCsd(self: *const Client) bool {
    return self.decoration_mode != .server_side;
}

pub fn titlebarHeight(self: *const Client) i32 {
    return if (self.wantsCsd()) CSD_TITLEBAR_H else 0;
}

pub fn decorationEvent(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, self: *Client) void {
    switch (event) {
        .configure => |ev| {
            self.decoration_mode = switch (ev.mode) {
                .server_side => .server_side,
                .client_side => .client_side,
                else => .client_side,
            };
            self.app.dirty = true;
        },
    }
}

pub fn xdgToplevelEvent(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Client) void {
    switch (event) {
        .configure => |ev| {
            const tbh = self.titlebarHeight();
            if (ev.width > 0 and ev.height > 0) {
                self.app.resize(ev.width, @max(1, ev.height - tbh));
            } else if (!self.configured) {
                var width: i32 = 1000;
                var height: i32 = 700;
                if (self.outputs.items.len > 0) {
                    const output = self.outputs.items[0];
                    if (output.logical_width > 0) width = std.math.clamp(output.logical_width - 160, 480, 1200);
                    if (output.logical_height > 0) height = std.math.clamp(output.logical_height - 180, 360, 800);
                }
                self.app.resize(width, height);
            }
            self.xdg_toplevel.setMinSize(480, 320 + tbh);
            self.app.dirty = true;
        },
        .close => {
            self.app.requestClose();
        },
        .configure_bounds, .wm_capabilities => {},
    }
}
