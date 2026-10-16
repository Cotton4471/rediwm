const std = @import("std");
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("protocol.zig");
const stats = @import("stats.zig");
const scene_data = @import("../scene_data.zig");
const chrome = @import("../chrome.zig");
const ui = @import("ui");
const virtual_input_mod = @import("../input/virtual.zig");
const VirtualInput = virtual_input_mod.VirtualInput;
const Client = @import("server.zig").Client;
const actions = @import("../config_runtime/actions.zig");
const events = @import("events.zig");
const taskbar_items = @import("config").taskbar_items;
const handlers_queries = @import("handlers_queries.zig");
const handlers_panels = @import("handlers_panels.zig");
const handlers_widgets = @import("handlers_widgets.zig");
const handlers_data = @import("handlers_data.zig");
pub const getNightLight = handlers_queries.getNightLight;
pub const getIdleState = handlers_queries.getIdleState;
pub const getCaptureState = handlers_queries.getCaptureState;
pub const getWindowRules = handlers_queries.getWindowRules;
pub const matchWindowRules = handlers_queries.matchWindowRules;
pub const walkSceneTree = handlers_queries.walkSceneTree;
pub const ClipRect = handlers_panels.ClipRect;
pub const PanelRoot = handlers_panels.PanelRoot;
pub const PanelRegistryEntry = handlers_panels.PanelRegistryEntry;
pub const resolveStartMenu = handlers_panels.resolveStartMenu;
pub const resolveControlCenter = handlers_panels.resolveControlCenter;
pub const controlCenterState = handlers_panels.controlCenterState;
pub const resolvePowerMenu = handlers_panels.resolvePowerMenu;
pub const resolveDock = handlers_panels.resolveDock;
pub const panel_registry = handlers_panels.panel_registry;
pub const walkWidgetTree = handlers_widgets.walkWidgetTree;
pub const computeTargetPoint = handlers_widgets.computeTargetPoint;
pub const findWidgetInNodes = handlers_widgets.findWidgetInNodes;
pub const ResolveWidgetOutcome = handlers_widgets.ResolveWidgetOutcome;
pub const buildTaskbarWidgetTree = handlers_widgets.buildTaskbarWidgetTree;
pub const buildWindowWidgetTree = handlers_widgets.buildWindowWidgetTree;
pub const appendTabWidget = handlers_widgets.appendTabWidget;
pub const findVirtualWidgetNode = handlers_widgets.findVirtualWidgetNode;
pub const findWidgetNode = handlers_widgets.findWidgetNode;
pub const resolveWidget = handlers_widgets.resolveWidget;
pub const cloneRequestId = handlers_data.cloneRequestId;
pub const freeRequestId = handlers_data.freeRequestId;
pub const getBackendName = handlers_data.getBackendName;
pub const getRendererName = handlers_data.getRendererName;
pub const startupStats = handlers_data.startupStats;
pub const makeAudioStateData = handlers_data.makeAudioStateData;
pub const makeWindowData = handlers_data.makeWindowData;
pub const makeOutputData = handlers_data.makeOutputData;
pub const makeCameraData = handlers_data.makeCameraData;
pub const makeShellStateData = handlers_data.makeShellStateData;
pub const findToplevelById = handlers_data.findToplevelById;
pub const findFocusedToplevel = handlers_data.findFocusedToplevel;
pub const findOutputByName = handlers_data.findOutputByName;

pub fn automationEnabled(server: *const Server) bool {
    const ipc = server.ipc orelse return false;
    return ipc.automation;
}

pub fn handleRequest(
    server: *Server,
    request_id: ?protocol.RequestId,
    request: protocol.Request,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    if (server.locker != null) return .{ .err = "SessionLocked" };
    if (client) |c_ptr| {
        if (c_ptr.sandbox) |sb| {
            const groups = server.config.sandboxAllowGroups(sb.app_id, sb.engine);
            if (!groups.contains(.ipc)) {
                return .{ .err = "PermissionDenied: sandboxed caller lacks ipc allowance" };
            }
            if (protocol.commands.requiresAutomation(request) and !groups.contains(.automation)) {
                return .{ .err = "PermissionDenied: sandboxed caller lacks automation allowance" };
            }
        }
    }
    if (protocol.commands.requiresAutomation(request) and !automationEnabled(server))
        return .{ .err = "AutomationDisabled: set [ipc] automation = true and restart rediwm" };
    if (server.polkit_dialog != null) switch (request) {
        .get_shell_state, .get_state, .get_input_state, .get_widget_tree, .outputs, .windows, .version, .capabilities, .event_stream, .event_stream_filtered => {},
        .action => |act| switch (act) {
            .wait_for_frame => {},
            else => return .{ .err = "AuthenticationActive" },
        },
        else => return .{ .err = "AuthenticationActive" },
    };
    switch (request) {
        .get_services => return @import("settings.zig").services(server, allocator),
        .get_sounds => return .{ .ok = .{ .sounds = try @import("../audio/sounds.zig").inspect(server, allocator) } },
        .get_wallpaper => return @import("settings.zig").wallpaper(server, allocator),
        .theme_list => {
            const packs = try @import("config").theme_pack.list(allocator, server.io, server.environ, server.config.path);
            var result: protocol.ResponsePayload = .{ .theme_packs = .{ .active = server.config.theme_base, .packs = &.{} } };
            const T = @typeInfo(@TypeOf(result.theme_packs.packs)).pointer.child;
            const rows = try allocator.alloc(T, packs.len);
            for (packs, rows) |p, *row| row.* = .{ .id = p.id, .name = p.name, .version = p.version, .user_installed = p.user_installed };
            result.theme_packs.packs = rows;
            return .{ .ok = result };
        },
        .get_theme => return @import("settings.zig").getTheme(server, allocator),
        .get_processes => return @import("processes.zig").start(server, request_id, client),
        .get_keyboard_layouts => return .{ .ok = .{ .keyboard_layouts = try @import("../input/layouts.zig").inspect(server, allocator) } },
        .version => {
            return .{ .ok = .{ .version = "0.1.0" } };
        },
        .capabilities => {
            const caps = &protocol.commands.capabilities;
            return .{ .ok = .{ .capabilities = caps } };
        },
        .describe_ipc => {
            const commands = &protocol.commands.descriptions;

            var unavailable = std.ArrayList([]const u8).empty;
            if (server.audio == null) try unavailable.append(allocator, "audio unavailable");
            if (server.virtual_input == null) try unavailable.append(allocator, "virtual input unavailable");
            if (server.screenshot_mgr == null) try unavailable.append(allocator, "screenshot manager unavailable");
            if (server.idle == null) try unavailable.append(allocator, "idle manager unavailable");
            if (!automationEnabled(server)) try unavailable.append(allocator, "automation disabled: synthetic input, screenshots, pixel reads and buffer dumps need [ipc] automation = true");

            return .{ .ok = .{ .describe_ipc = .{
                .protocol_version = "1",
                .build_version = "0.1.0",
                .backend = getBackendName(server.backend),
                .renderer = getRendererName(server.renderer),
                .commands = commands,
                .unavailable_reasons = try unavailable.toOwnedSlice(allocator),
            } } };
        },
        .windows => {
            var list = std.ArrayList(protocol.WindowData).empty;
            var it = server.world.toplevels.iterator(.forward);
            while (it.next()) |toplevel| {
                const win = makeWindowData(server, toplevel);
                try list.append(allocator, win);
            }
            const wins = try list.toOwnedSlice(allocator);
            return .{ .ok = .{ .windows = wins } };
        },
        .outputs => {
            var list = std.ArrayList(protocol.OutputData).empty;
            var it = server.outputs.iterator(.forward);
            while (it.next()) |output| {
                const out = makeOutputData(server, output);
                try list.append(allocator, out);
            }
            const outs = try list.toOwnedSlice(allocator);
            return .{ .ok = .{ .outputs = outs } };
        },
        .focused_window => {
            if (findFocusedToplevel(server)) |toplevel| {
                return .{ .ok = .{ .focused_window = makeWindowData(server, toplevel) } };
            } else {
                return .{ .ok = .{ .focused_window = null } };
            }
        },
        .workspaces => {
            return .{ .ok = .{ .workspaces = try server.world.workspaces.data(server, allocator) } };
        },
        .event_stream => {
            return .{ .ok = .handled };
        },
        .event_stream_filtered => {
            return .{ .ok = .handled };
        },
        .get_state => {
            var wins = std.ArrayList(protocol.WindowData).empty;
            var win_it = server.world.toplevels.iterator(.forward);
            while (win_it.next()) |toplevel| {
                try wins.append(allocator, makeWindowData(server, toplevel));
            }

            var outs = std.ArrayList(protocol.OutputData).empty;
            var out_it = server.outputs.iterator(.forward);
            while (out_it.next()) |output| {
                try outs.append(allocator, makeOutputData(server, output));
            }

            const focused_id: ?u64 = if (findFocusedToplevel(server)) |t| t.id else null;

            return .{ .ok = .{ .state = .{
                .seq = if (server.ipc) |ipc| ipc.seq else 0,
                .session_id = if (server.ipc) |ipc| ipc.session_id else "",
                .windows = try wins.toOwnedSlice(allocator),
                .outputs = try outs.toOwnedSlice(allocator),
                .camera = makeCameraData(server),
                .focused_window_id = focused_id,
                .shell = makeShellStateData(server),
                .workspaces = try server.world.workspaces.data(server, allocator),
            } } };
        },
        .get_window_debug => |p| {
            const toplevel = findToplevelById(server, p.id) orelse {
                const msg = try std.fmt.allocPrint(allocator, "UnknownWindow: {d}", .{p.id});
                return .{ .err = msg };
            };
            const surface = toplevel.surface() orelse return .{ .err = "WindowNotVisible" };
            var src_box: wlr.FBox = undefined;
            surface.getBufferSourceBox(&src_box);

            const geometry_box = toplevel.clientGeometry();
            const decorated = toplevel.hasServerDecorations();
            const radius: f32 = toplevel.cornerRadius();
            const footer = chrome.frame_border;

            const client_box: protocol.RectData = .{
                .x = toplevel.x + if (decorated) chrome.frame_border else 0,
                .y = toplevel.y + toplevel.titlebarHeight(),
                .width = geometry_box.width,
                .height = geometry_box.height,
            };
            const chrome_box: protocol.RectData = .{
                .x = toplevel.x,
                .y = toplevel.y,
                .width = toplevel.chrome_width,
                .height = toplevel.chrome_height,
            };

            var out_names = std.ArrayList([]const u8).empty;
            var out_it = server.outputs.iterator(.forward);
            while (out_it.next()) |out| {
                var obox: wlr.Box = undefined;
                server.output_layout.getBox(out.wlr_output, &obox);
                if (obox.x < toplevel.x + toplevel.chrome_width and
                    obox.x + obox.width > toplevel.x and
                    obox.y < toplevel.y + toplevel.chrome_height and
                    obox.y + obox.height > toplevel.y)
                {
                    try out_names.append(allocator, std.mem.span(out.wlr_output.name));
                }
            }

            return .{
                .ok = .{
                    .window_debug = .{
                        .id = toplevel.id,
                        .title = toplevel.titleOrNull(),
                        .app_id = toplevel.appIdOrNull(),
                        .pid = toplevel.clientPid(),
                        .client_box = client_box,
                        .chrome_box = chrome_box,
                        .titlebar_height = toplevel.titlebarHeight(),
                        .footer_height = if (decorated) footer else 0,
                        .frame_border = if (decorated) chrome.frame_border else 0,
                        .frame_radius = if (decorated) radius else 0,
                        .decoration_mode = if (decorated) "server" else "client",
                        .minimized = toplevel.minimized,
                        .maximized = toplevel.isMaximized(),
                        .fullscreen = toplevel.isFullscreen(),
                        .is_resizing = toplevel.isResizing(),
                        .zoom_percent = if (server.world.workspaces.active) 100 else @import("../camera.zig").zoom_levels[toplevel.zoom_index],
                        .effective_zoom = toplevel.zoom(),
                        .zoom_boosted = toplevel.zoom_boost.to != 0,
                        .source_box = .{ .x = src_box.x, .y = src_box.y, .width = src_box.width, .height = src_box.height },
                        // Surface width/height are logical (after scale/viewport).
                        // Report actual submitted pixels for density diagnostics.
                        .buffer_width = surface.current.buffer_width,
                        .buffer_height = surface.current.buffer_height,
                        .buffer_scale = @floatFromInt(surface.current.scale),
                        .buffer_transform = @tagName(surface.current.transform),
                        .configure_serial = toplevel.scheduledSerial(),
                        .ack_serial = toplevel.ackSerial(),
                        .outputs = try out_names.toOwnedSlice(allocator),
                        // Kept for the wire format: frames have had no skirt to
                        // sample since the window shapes (stage 4e).
                        .skirt_fill = null,
                        .edge_sample = "none",
                    },
                },
            };
        },
        .get_shell_state => |p| {
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            const now = @import("ui").anim.nowMs();
            var start_menu_data: ?protocol.PanelStateData = null;
            if (target_out.start_menu) |sm| {
                start_menu_data = .{
                    .state = @tagName(sm.state),
                    .progress = sm.slide.value(now),
                    .is_settled = (sm.state == .open and sm.slide.settled(now)),
                    .box = .{ .x = sm.panel_box.x, .y = sm.panel_box.y, .width = sm.panel_box.width, .height = sm.panel_box.height },
                    .search_text = if (sm.model.query.items.len > 0) sm.model.query.items else null,
                    .category = @tagName(sm.model.category),
                    .selected_index = @intCast(sm.model.selected_index),
                    .result_count = sm.model.results.len,
                };
            }
            var cc_data: ?protocol.PanelStateData = null;
            if (server.input.open_control_center) |cc| {
                cc_data = controlCenterState(cc, now);
            }
            var pm_data: ?protocol.PanelStateData = null;
            if (target_out.power_menu) |pm| {
                pm_data = .{
                    .state = @tagName(pm.state),
                    .progress = pm.slide.value(now),
                    .is_settled = (pm.state == .open and pm.slide.settled(now)),
                    .box = .{ .x = pm.panel_box.x, .y = pm.panel_box.y, .width = pm.panel_box.width, .height = pm.panel_box.height },
                };
            }

            var taskbars = std.ArrayList(protocol.TaskbarData).empty;
            var it_out = server.outputs.iterator(.forward);
            while (it_out.next()) |out| {
                if (out.taskbar) |tb| {
                    var chips = std.ArrayList(protocol.TaskbarChipData).empty;
                    const focused_tl = findFocusedToplevel(server);
                    for (tb.chips.items) |chip| {
                        try chips.append(allocator, .{
                            .window_id = chip.toplevel.id,
                            .title = chip.toplevel.title(),
                            .box = .{
                                .x = tb.box.x + @as(i32, @intFromFloat(@round(chip.renderX(now)))),
                                .y = tb.box.y + @divTrunc(tb.box.height - 42, 2),
                                .width = @as(i32, @intFromFloat(chip.width)),
                                .height = 42,
                            },
                            .is_active = (focused_tl == chip.toplevel),
                            .is_urgent = chip.toplevel.needs_attention,
                        });
                    }
                    var right_items = std.ArrayList(protocol.TaskbarItemData).empty;
                    const items = server.config.compositor.taskbar_items;
                    for (items.order) |item| {
                        // Keep the existing status-item IPC contract.
                        if (item == .start or item == .windows or item == .tray) continue;
                        const box = tb.itemBox(item);
                        try right_items.append(allocator, .{
                            .name = @tagName(item),
                            .visible = items.resolved(item, tb.network_presence),
                            .box = if (box) |b| .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height } else null,
                        });
                    }
                    var app_tray = std.ArrayList(protocol.TaskbarItemData).empty;
                    if (server.tray) |tray| {
                        for (0..tb.appTrayCount()) |i| {
                            const item = tray.visibleItem(i) orelse continue;
                            const b = tb.appTrayBox(i);
                            try app_tray.append(allocator, .{ .name = item.service, .visible = true, .box = .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height } });
                        }
                    }
                    const menu_box = if (server.tray) |tray| (if (tray.menu_node != null) tray.menu_box else null) else null;
                    try taskbars.append(allocator, .{
                        .output = std.mem.span(out.wlr_output.name),
                        .box = .{ .x = tb.box.x, .y = tb.box.y, .width = tb.box.width, .height = tb.box.height },
                        .start_button_box = .{
                            .x = tb.startButtonBox().x,
                            .y = tb.startButtonBox().y,
                            .width = tb.startButtonBox().width,
                            .height = tb.startButtonBox().height,
                        },
                        .right_items = try right_items.toOwnedSlice(allocator),
                        .app_tray = try app_tray.toOwnedSlice(allocator),
                        .tray_menu = if (menu_box) |b| .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height } else null,
                        .chips = try chips.toOwnedSlice(allocator),
                    });
                }
            }

            return .{ .ok = .{ .shell_state = .{
                .start_menu = start_menu_data,
                .control_center = cc_data,
                .power_menu = pm_data,
                .polkit_dialog = makeShellStateData(server).polkit_dialog,
                .taskbars = try taskbars.toOwnedSlice(allocator),
            } } };
        },
        .get_text_input => return .{ .ok = .{ .text_input = if (server.text_input) |relay| try relay.inspect(allocator) else .{} } },
        .get_input_state => {
            var mods = protocol.ModifiersData{};
            var kbd_it = server.input.keyboards.iterator(.forward);
            while (kbd_it.next()) |kbd| {
                const m = kbd.device.toKeyboard().getModifiers();
                if (m.ctrl) mods.ctrl = true;
                if (m.alt) mods.alt = true;
                if (m.shift) mods.shift = true;
                if (m.logo) mods.super = true;
                if (m.caps) mods.caps_lock = true;
            }

            var held_b = std.ArrayList(u32).empty;
            var held_k = std.ArrayList(u32).empty;
            if (client) |c| {
                var b_it = c.held_buttons.keyIterator();
                while (b_it.next()) |b| try held_b.append(allocator, b.*);
                var k_it = c.held_keys.keyIterator();
                while (k_it.next()) |k| try held_k.append(allocator, k.*);
            }

            var pointer_focused_id: ?u64 = null;
            if (server.input.seat.pointer_state.focused_surface) |psurf| {
                if (Toplevel.fromSurface(server, psurf)) |tl| pointer_focused_id = tl.id;
            }

            const keyboard_focused_id = if (findFocusedToplevel(server)) |tl| tl.id else null;

            return .{ .ok = .{ .input_state = .{
                .pointer_x = server.input.cursor.x,
                .pointer_y = server.input.cursor.y,
                .pointer_focused_window_id = pointer_focused_id,
                .keyboard_focused_window_id = keyboard_focused_id,
                .modifiers = mods,
                .held_buttons = try held_b.toOwnedSlice(allocator),
                .held_keys = try held_k.toOwnedSlice(allocator),
                .cursor_mode = @tagName(server.input.cursor_mode),
                .cursor_source = @tagName(server.input.cursor_source),
                .cursor_name = if (server.input.cursor_name) |name| std.mem.span(name) else null,
                .grabbed_window_id = if (server.input.grabbed_toplevel) |tl| tl.id else null,
                .resize_edges = if (server.input.cursor_mode == .resize and server.input.resize_session != null)
                    std.mem.span(server.input.resize_session.?.edges.cursorName())
                else
                    null,
                .has_active_sequence = server.virtual_input != null and server.virtual_input.?.active_sequence != null,
            } } };
        },
        .hit_test => |p| {
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            var obox: wlr.Box = undefined;
            server.output_layout.getBox(target_out.wlr_output, &obox);
            const lx: f64 = @floatFromInt(obox.x + p.x);
            const ly: f64 = @floatFromInt(obox.y + p.y);

            const hit = scene_data.hitTest(server, lx, ly);
            var result = protocol.HitTestResult{
                .target_type = "none",
                .local_x = 0,
                .local_y = 0,
                .layout_x = lx,
                .layout_y = ly,
                .output = std.mem.span(target_out.wlr_output.name),
            };

            switch (hit) {
                .mini_map => |map| {
                    result.target_type = "mini_map";
                    result.local_x = lx - @as(f64, @floatFromInt(map.box.x));
                    result.local_y = ly - @as(f64, @floatFromInt(map.box.y));
                },
                .none => {},
                .input_popup => |popup_hit| {
                    result.target_type = "input_popup";
                    result.local_x = popup_hit.sx;
                    result.local_y = popup_hit.sy;
                },
                .layer => |l| {
                    result.target_type = "layer";
                    result.local_x = l.sx;
                    result.local_y = l.sy;
                },
                .desktop => |d| {
                    result.target_type = "desktop";
                    result.local_x = d.x;
                    result.local_y = d.y;
                },
                .chrome => |c| {
                    result.target_type = "chrome";
                    result.window_id = c.toplevel.id;
                    result.local_x = c.sx;
                    result.local_y = c.sy;
                    result.widget = if (c.toplevel.hovered_control) |ctrl| @tagName(ctrl) else "titlebar";
                },
                .surface => |s| {
                    result.target_type = "window";
                    result.window_id = s.toplevel.id;
                    result.local_x = s.sx;
                    result.local_y = s.sy;
                },
                .dock => |d| {
                    result.target_type = "dock";
                    result.local_x = d.sx;
                    result.local_y = d.sy;
                },
                .taskbar => |tb| {
                    result.target_type = "taskbar";
                    result.local_x = tb.sx;
                    result.local_y = tb.sy;
                    const target = tb.bar.hitTest(tb.sx, tb.sy);
                    result.widget = if (tb.bar.appTrayAt(tb.sx, tb.sy) != null) "app_tray" else @tagName(target);
                },
                .wifi_popup => |popup| {
                    result.target_type = "wifi_popup";
                    result.widget = popup.popup.widgetAt(popup.sx, popup.sy);
                    result.local_x = popup.sx;
                    result.local_y = popup.sy;
                },
                .battery_popup => |popup| {
                    result.target_type = "battery_popup";
                    result.local_x = popup.sx;
                    result.local_y = popup.sy;
                },
                .calendar => |cal| {
                    result.target_type = "calendar";
                    result.local_x = cal.sx;
                    result.local_y = cal.sy;
                },
                .control_center => |cc| {
                    result.target_type = "control_center";
                    result.local_x = cc.sx;
                    result.local_y = cc.sy;
                },
                .start_menu => |sm| {
                    result.target_type = "start_menu";
                    result.local_x = sm.sx;
                    result.local_y = sm.sy;
                },
                .power_menu => |pm| {
                    result.target_type = "power_menu";
                    result.local_x = pm.sx;
                    result.local_y = pm.sy;
                },
                .xwayland_unmanaged => |u| {
                    result.target_type = "xwayland_unmanaged";
                    result.local_x = u.sx;
                    result.local_y = u.sy;
                },
                .toast => |t| {
                    result.target_type = "toast";
                    result.local_x = t.sx;
                    result.local_y = t.sy;
                },
            }

            return .{ .ok = .{ .hit_test = result } };
        },
        .get_scene_tree => |p| {
            var nodes = std.ArrayList(protocol.SceneNodeData).empty;
            var total: usize = 0;
            const max_depth = p.max_depth orelse 16;
            try walkSceneTree(&server.nodes.tree.node, &nodes, allocator, 0, max_depth, &total);
            return .{ .ok = .{ .scene_tree = .{
                .nodes = try nodes.toOwnedSlice(allocator),
                .total_nodes = total,
            } } };
        },
        .get_layer_surfaces => {
            var list = std.ArrayList(protocol.LayerSurfaceData).empty;
            var it = server.layer_surfaces.iterator(.forward);
            while (it.next()) |ls| {
                const out_name = if (ls.layer.output) |o| std.mem.span(o.name) else "none";
                try list.append(allocator, .{
                    .namespace = std.mem.span(ls.layer.namespace),
                    .output = out_name,
                    .layer = @tagName(ls.layer.current.layer),
                    .exclusive_zone = ls.layer.current.exclusive_zone,
                    .keyboard_interactive = ls.layer.current.keyboard_interactive != .none,
                    .mapped = ls.layer.surface.mapped,
                    .box = .{
                        .x = ls.tree.node.x,
                        .y = ls.tree.node.y,
                        .width = ls.layer.surface.current.width,
                        .height = ls.layer.surface.current.height,
                    },
                });
            }
            return .{ .ok = .{ .layer_surfaces = .{
                .surfaces = try list.toOwnedSlice(allocator),
            } } };
        },
        .get_widget_tree => |p| {
            const def_out = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            for (panel_registry) |entry| {
                if (std.mem.eql(u8, entry.name, p.panel)) {
                    const resolved = entry.resolve(def_out) orelse return .{ .err = "PanelNotOpen" };
                    var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                    try walkWidgetTree(resolved.root, &widgets, allocator, p.panel, null, resolved.box.x, resolved.box.y, null);
                    return .{ .ok = .{ .widget_tree = .{
                        .panel = p.panel,
                        .widgets = try widgets.toOwnedSlice(allocator),
                    } } };
                }
            }
            if (std.mem.eql(u8, p.panel, "taskbar")) {
                const tb = def_out.taskbar orelse return .{ .err = "PanelNotOpen" };
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                try buildTaskbarWidgetTree(server, tb, &widgets, allocator);
                return .{ .ok = .{ .widget_tree = .{
                    .panel = p.panel,
                    .widgets = try widgets.toOwnedSlice(allocator),
                } } };
            }
            if (std.mem.eql(u8, p.panel, "window") or std.mem.startsWith(u8, p.panel, "window/")) {
                var target_tl: ?*Toplevel = null;
                if (std.mem.startsWith(u8, p.panel, "window/")) {
                    const rest = p.panel["window/".len..];
                    const slash_pos = std.mem.indexOfScalar(u8, rest, '/');
                    const num_str = if (slash_pos) |idx| rest[0..idx] else rest;
                    if (std.fmt.parseInt(u64, num_str, 10)) |id| {
                        target_tl = findToplevelById(server, id);
                    } else |_| return .{ .err = "InvalidRequest: bad window id" };
                } else {
                    target_tl = findFocusedToplevel(server) orelse server.world.toplevels.first();
                }
                const toplevel = target_tl orelse return .{ .err = "NotFound" };
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                try buildWindowWidgetTree(server, toplevel, &widgets, allocator);
                return .{ .ok = .{ .widget_tree = .{
                    .panel = p.panel,
                    .widgets = try widgets.toOwnedSlice(allocator),
                } } };
            }
            return .{ .err = "InvalidPanel: expected start_menu, control_center, power_menu, dock, taskbar, or window" };
        },
        .list_panels => {
            const def_out = server.getDefaultOutput();
            var panels = std.ArrayList(protocol.PanelData).empty;
            for (panel_registry) |entry| {
                var is_open = false;
                var box: ?protocol.RectData = null;
                if (def_out) |out| {
                    if (entry.resolve(out)) |res| {
                        is_open = true;
                        box = .{
                            .x = res.box.x,
                            .y = res.box.y,
                            .width = res.box.width,
                            .height = res.box.height,
                        };
                    }
                }
                try panels.append(allocator, .{
                    .name = entry.name,
                    .open = is_open,
                    .box = box,
                });
            }
            if (def_out) |out| {
                if (out.taskbar) |tb| {
                    try panels.append(allocator, .{
                        .name = "taskbar",
                        .open = true,
                        .box = .{
                            .x = tb.box.x,
                            .y = tb.box.y,
                            .width = tb.box.width,
                            .height = tb.box.height,
                        },
                    });
                }
            }
            return .{ .ok = .{ .list_panels = .{
                .panels = try panels.toOwnedSlice(allocator),
            } } };
        },
        .get_config_status => {
            return .{ .ok = .{ .config_status = .{
                .config_path = if (server.config.path.len > 0) server.config.path else null,
                .generation = server.config_generation,
                .theme_path = server.theme_path,
                .keybinds_count = server.config.keybinds.len,
                .last_reload_result = if (server.config_reload_error != null) "failed" else "ok",
                .last_reload_error = server.config_reload_error,
            } } };
        },
        .get_runtime_info => {
            return .{ .ok = .{ .runtime_info = .{
                .compositor = "rediwm",
                .version = "0.1.0",
                .wlroots_version = "0.20",
                .backend = getBackendName(server.backend),
                .renderer = getRendererName(server.renderer),
                .outputs_count = server.outputs.length(),
                .audio_available = server.audio != null,
                .session_id = if (server.ipc) |ipc| ipc.session_id else "",
                .xwayland_enabled = server.xwayland != null,
                .xwayland_display = if (server.xwayland) |xw| xw.displayName() else null,
                .xwayland_native_scaling = if (server.xwayland) |xw| xw.native_scaling else false,
                .xwayland_scale = server.xwaylandScale(),
                .xwayland_scale_pending = server.xwaylandScalePending(),
                .current_desktop = @import("../child_env.zig").desktop_name,
                .nested = @import("../session/activation.zig").isNested(
                    @import("../session/activation.zig").viewFromEnviron(server.environ),
                ),
            } } };
        },
        .get_idle_state => {
            return getIdleState(server, allocator);
        },
        .get_capture_state => {
            return getCaptureState(server, allocator);
        },
        .get_window_rules => |p| {
            return getWindowRules(server, p.id, allocator);
        },
        .match_window_rules => |p| {
            return matchWindowRules(server, p, allocator);
        },
        .get_night_light => {
            return getNightLight(server, allocator);
        },
        .get_notifications => {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            return .{ .ok = .{ .notifications = try notif_mgr.getNotificationsResult(allocator) } };
        },
        .action => |act| {
            return handleAction(server, request_id, act, allocator, client);
        },
    }
}

pub fn handleAction(
    server: *Server,
    request_id: ?protocol.RequestId,
    action: protocol.Action,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    switch (action) {
        .set_service_mode => |p| {
            const systemd = server.getSystemd() catch return .{ .err = "ServicesUnavailable" };
            systemd.setMode(p.service, p.mode) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .{ .service_mode = .{ .service = p.service, .mode = p.mode } } };
        },
        .play_sound => |p| return @import("../audio/sounds.zig").play(server, allocator, p.event) catch |err| .{ .err = @errorName(err) },
        .theme_apply => |p| {
            @import("../config_runtime/theme_pack.zig").apply(server, p.id) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .theme_install => |p| {
            @import("../config_runtime/theme_job.zig").start(server, if (p.replace) &.{ "install", p.path, "--replace" } else &.{ "install", p.path }, client, request_id) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .async_pending };
        },
        .set_wallpaper => |p| {
            @import("settings.zig").setWallpaper(server, p.path, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_accent_color => |p| {
            @import("settings.zig").setAccent(server, p.color, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_night_light => |p| {
            @import("settings.zig").setNightLight(server, p.enabled, p.temperature, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .open_appearance => {
            server.openAppearance();
            return .{ .ok = .handled };
        },
        .focus_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse {
                const msg = try std.fmt.allocPrint(allocator, "UnknownWindow: {d}", .{p.id});
                return .{ .err = msg };
            };
            if (toplevel.minimized) {
                toplevel.restore();
            } else {
                server.world.focus(toplevel);
            }
            if (server.getDefaultOutput()) |output| {
                server.world.revealIfOffscreen(toplevel, output);
            }
            return .{ .ok = .handled };
        },
        .close_window => |p| {
            const target: *Toplevel = if (p.id) |id|
                findToplevelById(server, id) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownWindow: {d}", .{id});
                    return .{ .err = msg };
                }
            else
                findFocusedToplevel(server) orelse return .{ .err = "NoFocusedWindow" };

            target.sendClose();
            return .{ .ok = .handled };
        },
        .move_window_to => |p| {
            const toplevel = findToplevelById(server, p.id) orelse {
                const msg = try std.fmt.allocPrint(allocator, "UnknownWindow: {d}", .{p.id});
                return .{ .err = msg };
            };
            if (toplevel.isResizing() or ((server.input.cursor_mode == .move or server.input.tiling_grab != null) and server.input.grabbed_toplevel == toplevel)) return .{ .err = "Busy" };

            if (p.output) |name| {
                const target_output = findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                };
                if (!target_output.isAvailable()) return .{ .err = "OutputUnavailable" };
                var transaction: ?@import("../layout_undo.zig").Transaction = if (server.world.workspaces.active)
                    @import("../layout_undo.zig").Transaction.begin(server, &.{ toplevel.workspace_id, target_output.workspace_id })
                else
                    null;
                defer if (transaction) |*change| change.finish();
                const old_x = toplevel.x;
                const old_y = toplevel.y;
                if (!toplevel.moveToOutput(target_output)) return .{ .err = "WindowUnavailable" };
                const dx = toplevel.x - old_x;
                const dy = toplevel.y - old_y;
                // Keep transient dialogs attached to their owner when the
                // owner is moved between monitors. Their own maximize or
                // fullscreen state remains authoritative if they have one.
                var it = server.world.toplevels.iterator(.forward);
                while (it.next()) |child| {
                    if (child == toplevel or child.owner() != toplevel or !child.in_world or child.isMaximized() or child.isFullscreen()) continue;
                    child.setPosition(child.x + dx, child.y + dy);
                }
            } else {
                var transaction: ?@import("../layout_undo.zig").Transaction = if (server.world.workspaces.active)
                    @import("../layout_undo.zig").Transaction.begin(server, &.{toplevel.workspace_id})
                else
                    null;
                defer if (transaction) |*change| change.finish();
                const floating = toplevel.auto_restore;
                @import("../auto_tiling.zig").setFloating(toplevel, true);
                toplevel.setPosition(p.x, p.y);
                if (floating) |saved| {
                    // This explicit placement is final; a delayed restore must
                    // not move it back after a subsequent interactive drag.
                    toplevel.pending_restore = null;
                    toplevel.finishSizeAnimation();
                    _ = toplevel.requestSize(saved.width, saved.height);
                }
            }
            toplevel.syncChrome(false, Toplevel.nowMs()) catch {};
            return .{ .ok = .handled };
        },
        .spawn => |p| {
            if (p.argv.len == 0) return .{ .err = "InvalidRequest: empty argv" };

            var env_map = try server.environ.createMap(allocator);
            defer env_map.deinit();
            try server.applyChildEnv(&env_map);

            const child = std.process.spawn(server.io, .{
                .argv = p.argv,
                .environ_map = &env_map,
            }) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "SpawnFailed: {s}", .{@errorName(err)});
                return .{ .err = msg };
            };
            if (child.id) |pid| {
                @import("../session/app_scope.zig").place(server, pid, std.fs.path.basename(p.argv[0]));
                if (server.services) |s| s.trackChild(pid) catch {};
            }

            return .{ .ok = .handled };
        },
        .move_cursor => |p| {
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            var box: wlr.Box = undefined;
            server.output_layout.getBox(target_out.wlr_output, &box);

            if (p.x < 0 or p.y < 0 or p.x >= box.width or p.y >= box.height) {
                return .{ .err = "InvalidCoordinates: out of bounds" };
            }

            const lx: f64 = @floatFromInt(box.x + p.x);
            const ly: f64 = @floatFromInt(box.y + p.y);
            server.input.warpCursor(lx, ly, VirtualInput.nowMs());
            return .{ .ok = .handled };
        },
        .move_cursor_relative => |p| {
            const new_x = server.input.cursor.x + @as(f64, @floatFromInt(p.dx));
            const new_y = server.input.cursor.y + @as(f64, @floatFromInt(p.dy));
            server.input.warpCursor(new_x, new_y, VirtualInput.nowMs());
            return .{ .ok = .handled };
        },
        .pointer_button => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            if (client) |c| {
                if (p.pressed) {
                    try c.held_buttons.put(p.button, {});
                } else {
                    _ = c.held_buttons.remove(p.button);
                }
            }
            vi.pointer.sendButton(VirtualInput.nowMs(), p.button, if (p.pressed) .pressed else .released);
            return .{ .ok = .handled };
        },
        .click => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            var steps = std.ArrayList(virtual_input_mod.Step).empty;
            try steps.append(vi.allocator, .{ .pointer_button = .{ .button = p.button, .state = .pressed } });
            try steps.append(vi.allocator, .{ .pointer_button = .{ .button = p.button, .state = .released } });

            const seq = try vi.allocator.create(virtual_input_mod.Sequence);
            const duped_rid = if (request_id) |rid| try cloneRequestId(rid, vi.allocator) else null;
            seq.* = .{
                .client_id = if (client) |c| c.id else null,
                .request_id = duped_rid,
                .steps = steps,
                .on_complete = @import("server.zig").onSequenceComplete,
            };

            vi.startSequence(seq) catch |err| {
                seq.steps.deinit(vi.allocator);
                if (seq.request_id) |rid| freeRequestId(rid, vi.allocator);
                vi.allocator.destroy(seq);
                if (err == error.Busy) return .{ .err = "Busy" };
                return err;
            };

            return .{ .ok = .async_pending };
        },
        .scroll => |p| {
            const now = VirtualInput.nowMs();
            if (p.dy != 0) {
                server.input.processAxis(now, .vertical_scroll, p.dy, 0, .continuous);
            }
            if (p.dx != 0) {
                server.input.processAxis(now, .horizontal_scroll, p.dx, 0, .continuous);
            }
            server.input.seat.pointerNotifyFrame();
            return .{ .ok = .handled };
        },
        .pinch => |p| {
            const now = VirtualInput.nowMs();
            switch (p.phase) {
                .begin => server.input.handlePinchBegin(now, p.fingers),
                .update => server.input.handlePinchUpdate(now, p.dx, p.dy, p.scale, p.rotation),
                .end => server.input.handlePinchEnd(now, p.cancelled),
            }
            return .{ .ok = .handled };
        },
        .swipe => |p| {
            const now = VirtualInput.nowMs();
            switch (p.phase) {
                .begin => server.input.handleSwipeBegin(now, p.fingers),
                .update => server.input.handleSwipeUpdate(now, p.dx, p.dy),
                .end => server.input.handleSwipeEnd(now, p.cancelled),
            }
            return .{ .ok = .handled };
        },
        .key => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            if (client) |c| {
                if (p.pressed) {
                    try c.held_keys.put(p.keycode, {});
                } else {
                    _ = c.held_keys.remove(p.keycode);
                }
            }
            vi.keyboard.sendKey(VirtualInput.nowMs(), p.keycode, if (p.pressed) .pressed else .released);
            return .{ .ok = .handled };
        },
        .key_press => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            const info = vi.keyboard.lookupKeyName(p.key) orelse {
                const msg = try std.fmt.allocPrint(allocator, "UnknownKey: {s}", .{p.key});
                return .{ .err = msg };
            };

            var steps = std.ArrayList(virtual_input_mod.Step).empty;
            if (info.shift) {
                try steps.append(vi.allocator, .{ .shift_modifier = .{ .active = true } });
            }
            try steps.append(vi.allocator, .{ .key = .{ .keycode = info.evdev_keycode, .state = .pressed } });
            try steps.append(vi.allocator, .{ .key = .{ .keycode = info.evdev_keycode, .state = .released } });
            if (info.shift) {
                try steps.append(vi.allocator, .{ .shift_modifier = .{ .active = false } });
            }

            const seq = try vi.allocator.create(virtual_input_mod.Sequence);
            const duped_rid = if (request_id) |rid| try cloneRequestId(rid, vi.allocator) else null;
            seq.* = .{
                .client_id = if (client) |c| c.id else null,
                .request_id = duped_rid,
                .steps = steps,
                .on_complete = @import("server.zig").onSequenceComplete,
            };

            vi.startSequence(seq) catch |err| {
                seq.steps.deinit(vi.allocator);
                if (seq.request_id) |rid| freeRequestId(rid, vi.allocator);
                vi.allocator.destroy(seq);
                if (err == error.Busy) return .{ .err = "Busy" };
                return err;
            };

            return .{ .ok = .async_pending };
        },
        .type_text => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            if (!std.unicode.utf8ValidateSlice(p.text)) return .{ .err = "InvalidRequest: invalid UTF-8" };

            for (p.text) |byte| {
                if (vi.keyboard.lookupChar(byte) == null) {
                    const msg = try std.fmt.allocPrint(allocator, "UnsupportedCharacter: '{c}'", .{byte});
                    return .{ .err = msg };
                }
            }

            var steps = std.ArrayList(virtual_input_mod.Step).empty;
            for (p.text) |byte| {
                const info = vi.keyboard.lookupChar(byte).?;
                if (info.shift) {
                    try steps.append(vi.allocator, .{ .shift_modifier = .{ .active = true } });
                }
                try steps.append(vi.allocator, .{ .key = .{ .keycode = info.evdev_keycode, .state = .pressed } });
                try steps.append(vi.allocator, .{ .key = .{ .keycode = info.evdev_keycode, .state = .released } });
                if (info.shift) {
                    try steps.append(vi.allocator, .{ .shift_modifier = .{ .active = false } });
                }
            }

            const seq = try vi.allocator.create(virtual_input_mod.Sequence);
            const duped_rid = if (request_id) |rid| try cloneRequestId(rid, vi.allocator) else null;
            seq.* = .{
                .client_id = if (client) |c| c.id else null,
                .request_id = duped_rid,
                .steps = steps,
                .on_complete = @import("server.zig").onSequenceComplete,
            };

            vi.startSequence(seq) catch |err| {
                seq.steps.deinit(vi.allocator);
                if (seq.request_id) |rid| freeRequestId(rid, vi.allocator);
                vi.allocator.destroy(seq);
                if (err == error.Busy) return .{ .err = "Busy" };
                return err;
            };

            return .{ .ok = .async_pending };
        },
        .drag => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            var box: wlr.Box = undefined;
            server.output_layout.getBox(target_out.wlr_output, &box);

            if (p.from_x < 0 or p.from_y < 0 or p.from_x >= box.width or p.from_y >= box.height or
                p.to_x < 0 or p.to_y < 0 or p.to_x >= box.width or p.to_y >= box.height)
            {
                return .{ .err = "InvalidCoordinates: out of bounds" };
            }

            const start_x: f64 = @floatFromInt(box.x + p.from_x);
            const start_y: f64 = @floatFromInt(box.y + p.from_y);
            const end_x: f64 = @floatFromInt(box.x + p.to_x);
            const end_y: f64 = @floatFromInt(box.y + p.to_y);

            var steps = std.ArrayList(virtual_input_mod.Step).empty;
            try steps.append(vi.allocator, .{ .move_cursor = .{ .x = start_x, .y = start_y } });
            try steps.append(vi.allocator, .{ .pointer_button = .{ .button = p.button, .state = .pressed } });

            const num_steps: usize = 10;
            var i: usize = 1;
            while (i <= num_steps) : (i += 1) {
                const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(num_steps));
                const cur_x = start_x + (end_x - start_x) * t;
                const cur_y = start_y + (end_y - start_y) * t;
                try steps.append(vi.allocator, .{ .move_cursor = .{ .x = cur_x, .y = cur_y } });
            }

            try steps.append(vi.allocator, .{ .pointer_button = .{ .button = p.button, .state = .released } });

            const seq = try vi.allocator.create(virtual_input_mod.Sequence);
            const duped_rid = if (request_id) |rid| try cloneRequestId(rid, vi.allocator) else null;
            seq.* = .{
                .client_id = if (client) |c| c.id else null,
                .request_id = duped_rid,
                .steps = steps,
                .on_complete = @import("server.zig").onSequenceComplete,
            };

            vi.startSequence(seq) catch |err| {
                seq.steps.deinit(vi.allocator);
                if (seq.request_id) |rid| freeRequestId(rid, vi.allocator);
                vi.allocator.destroy(seq);
                if (err == error.Busy) return .{ .err = "Busy" };
                return err;
            };

            return .{ .ok = .async_pending };
        },
        .screenshot => |p| {
            const sm = server.screenshot_mgr orelse return .{ .err = "Unsupported" };
            return sm.queueRequest(p, if (client) |c| c.id else null, request_id);
        },
        .stop_all_capture => {
            const cm = server.capture_mgr orelse return .{ .err = "Unsupported" };
            cm.stopAll();
            return .{ .ok = .handled };
        },
        .get_camera => {
            const cam = makeCameraData(server);
            return .{ .ok = .{ .camera = .{ .x = cam.x, .y = cam.y, .max_x = cam.max_x, .max_y = cam.max_y, .zoom_percent = cam.zoom_percent } } };
        },
        .set_camera => |p| {
            if (!server.input.canZoom() or server.input.cursor_mode == .pan) return .{ .err = "Busy" };
            server.world.springPan(@floatFromInt(p.x), @floatFromInt(p.y), .camera_pan);
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .set_zoom => |p| {
            if (!server.input.canZoom()) return .{ .err = "Busy" };
            for (@import("../camera.zig").zoom_levels, 0..) |percent, index| {
                if (@min(percent, 100) == p.percent) {
                    server.world.setZoom(index, server.input.cursor.x, server.input.cursor.y);
                    return .{ .ok = .handled };
                }
            }
            return .{ .err = "InvalidRequest" };
        },
        .reset_camera => {
            if (!server.input.canZoom() or server.input.cursor_mode == .pan) return .{ .err = "Busy" };
            server.world.resetCamera();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .set_master_volume => |p| {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.setMasterVolume(p.volume);
            return .{ .ok = .handled };
        },
        .toggle_mute => {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.toggleMasterMute();
            return .{ .ok = .handled };
        },
        .set_app_volume => |p| {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.setSinkInputVolume(p.index, p.volume);
            return .{ .ok = .handled };
        },
        .set_app_mute => |p| {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.setSinkInputMute(p.index, p.muted);
            return .{ .ok = .handled };
        },
        .get_audio_state => {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            return .{ .ok = .{ .audio_state = try makeAudioStateData(mgr, allocator) } };
        },
        .get_panel_stats => {
            const panel_s = @import("../panel_present.zig").snapshot();
            return .{ .ok = .{ .panel_stats = .{
                .paints = panel_s.paints,
                .allocated_bytes = panel_s.allocated_bytes,
                .reused_bytes = panel_s.reused_bytes,
                .paint_ns = panel_s.paint_ns,
            } } };
        },
        .get_animations => {
            return .{ .ok = .{ .animations = try @import("animations.zig").snapshot(server, allocator) } };
        },
        .reset_panel_stats => {
            @import("../panel_present.zig").reset();
            return .{ .ok = .handled };
        },
        .set_anim_time => |p| {
            @import("ui").anim.setNowMs(p.ms);
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .open_start_menu => {
            const output = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            // Handles the already-open and mid-close cases itself, including
            // the keyboard routing and taskbar state a bare `reopen` misses.
            output.openStartMenu();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .open_control_center => {
            const output = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            output.toggleControlCenter();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .open_power_menu => {
            const output = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            output.openPowerMenu();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },

        // Phase 1 waits
        .wait_for => |p| {
            const c = client orelse return .{ .err = "ClientRequired" };
            const ipc = server.ipc orelse return .{ .err = "IpcNotRunning" };
            return ipc.wait_mgr.registerCondition(c.id, request_id, p.condition, p.timeout_ms);
        },
        .wait_for_frame => |p| {
            const c = client orelse return .{ .err = "ClientRequired" };
            const ipc = server.ipc orelse return .{ .err = "IpcNotRunning" };
            return ipc.wait_mgr.registerFrame(c.id, request_id, p.output, p.timeout_ms);
        },

        // Phase 3 captures/stats
        .dump_buffer => |p| {
            var target_buf: ?*wlr.Buffer = null;
            var scale: f32 = 1;

            const target = std.meta.stringToEnum(DumpTarget, p.target) orelse return .{ .err = "UnknownTarget" };
            switch (target) {
                .titlebar => {
                    const win_id = p.window_id orelse return .{ .err = "InvalidRequest: titlebar requires window_id" };
                    const toplevel = findToplevelById(server, win_id) orelse return .{ .err = "UnknownWindow" };
                    if (!toplevel.hasServerDecorations()) return .{ .err = "WindowHasNoServerDecorations" };
                    scale = toplevel.render_scale;
                    target_buf = toplevel.titlebar_buffer.getBuffer();
                },
                // Each tag names the Output field holding that panel.
                .control_center => {
                    const cc = server.input.open_control_center orelse return .{ .err = comptime DumpTarget.control_center.missingError() };
                    scale = cc.painted_scale;
                    target_buf = cc.buffer_node.getBuffer();
                },
                inline .taskbar, .start_menu, .power_menu => |tag| {
                    const out = if (p.output) |name| findOutputByName(server, name) else server.getDefaultOutput();
                    const target_out = out orelse return .{ .err = "NoOutput" };
                    scale = target_out.wlr_output.scale;
                    const panel = @field(target_out, @tagName(tag)) orelse return .{ .err = comptime tag.missingError() };
                    target_buf = panel.buffer_node.getBuffer();
                },
            }

            const buf = target_buf orelse return .{ .err = "BufferNotAttached" };
            var data_ptr: *anyopaque = undefined;
            var format: u32 = 0;
            // A panel presented through its texture (`presentOwned`) is a client
            // buffer with no CPU mapping on GLES2; its raster is packed ARGB8888.
            var stride: usize = @as(usize, @intCast(buf.width)) * @sizeOf(u32);
            if (buf.beginDataPtrAccess(0, &data_ptr, &format, &stride)) buf.endDataPtrAccess();

            return .{ .ok = .{ .dump_buffer = .{
                .target = p.target,
                .width = @intCast(buf.width),
                .height = @intCast(buf.height),
                .stride = @intCast(stride),
                .format = "argb8888",
                .scale = scale,
                .premultiplied = true,
                .data = null,
            } } };
        },
        .sample_pixels => |p| {
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse return .{ .err = "UnknownOutput" }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            const scene_output = server.scene_outputs.get(target_out.wlr_output) orelse return .{ .err = "NoSceneOutput" };
            var state = wlr.Output.State.init();
            defer state.finish();
            if (!server.buildOutputState(scene_output, &state)) return .{ .err = "CaptureFailed: scene render failed" };
            const buffer = state.buffer orelse return .{ .err = "CaptureFailed: missing frame buffer" };
            const texture = wlr.Texture.fromBuffer(server.renderer, buffer) orelse return .{ .err = "CaptureFailed: texture creation failed" };
            defer texture.destroy();

            const format = texture.preferredReadFormat();
            const count = p.width * p.height;
            const pixels = try allocator.alloc(u32, count);
            const ok = texture.readPixels(&.{
                .data = @ptrCast(pixels.ptr),
                .format = format,
                .stride = @intCast(p.width * @sizeOf(u32)),
                .dst_x = 0,
                .dst_y = 0,
                .src_box = .{ .x = p.x, .y = p.y, .width = @intCast(p.width), .height = @intCast(p.height) },
            });
            if (!ok) return .{ .err = "ReadPixelsFailed" };
            // The reply is packed 0xAARRGGBB whatever the renderer prefers to read
            // (GLES2 reads ABGR8888, bytes R, G, B, A).
            for (pixels) |*pixel| pixel.* = packedArgb(format, pixel.*) orelse return .{ .err = "ReadPixelsFailed: unsupported read format" };

            return .{ .ok = .{ .sample_pixels = .{
                .output = std.mem.span(target_out.wlr_output.name),
                .x = p.x,
                .y = p.y,
                .width = p.width,
                .height = p.height,
                .pixels = pixels,
                .gpu_readback = true,
            } } };
        },
        .get_performance_stats => {
            server.ensureGpuTimer();
            if (server.gpu_timer) |timer| timer.collect();
            const panel_s = @import("../panel_present.zig").snapshot();
            const timing = stats.global_stats.timing();
            return .{ .ok = .{ .performance_stats = .{
                .frame_work = stats.global_stats.frameWork(server.gpu_timer != null),
                .screenshot_selection = stats.global_stats.screenshot_selection,
                .output_commits = stats.global_stats.output_commits,
                .output_failed_commits = stats.global_stats.output_failed_commits,
                .fps = timing.fps,
                .frame_time_ms = timing.frame_time_ms,
                .missed_frames = timing.missed_frames,
                .refresh_hz = timing.refresh_hz,
                .titlebar_paints = stats.global_stats.titlebar_paints,
                .footer_paints = stats.global_stats.footer_paints,
                .edge_samples_attempted = stats.global_stats.edge_samples_attempted,
                .edge_samples_succeeded = stats.global_stats.edge_samples_succeeded,
                .edge_samples_skipped = stats.global_stats.edge_samples_skipped,
                .edge_sample_ns = stats.global_stats.edge_sample_ns,
                .panel_paints = panel_s.paints,
                .panel_allocated_bytes = panel_s.allocated_bytes,
                .panel_reused_bytes = panel_s.reused_bytes,
                .icon_cache_hits = stats.global_stats.icon_cache_hits,
                .icon_cache_misses = stats.global_stats.icon_cache_misses,
                .icon_decode_ns = stats.global_stats.icon_decode_ns,
                .icon_decode_count = stats.global_stats.icon_decode_count,
                .icon_decoded_bytes = stats.global_stats.icon_decoded_bytes,
                .icon_queue_depth_max = stats.global_stats.icon_queue_depth_max,
                .taskbar_paints = stats.global_stats.taskbar_paints,
                .taskbar_paint_ns = stats.global_stats.taskbar_paint_ns,
                .taskbar_raster_pixels = stats.global_stats.taskbar_raster_pixels,
                .taskbar_clock_frame_requests = stats.global_stats.taskbar_clock_frame_requests,
                .taskbar_clock_paints = stats.global_stats.taskbar_clock_paints,
                .taskbar_start_paints = stats.global_stats.taskbar_start_paints,
                .taskbar_chip_paints = stats.global_stats.taskbar_chip_paints,
                .taskbar_tray_paints = stats.global_stats.taskbar_tray_paints,
                .taskbar_hover_paints = stats.global_stats.taskbar_hover_paints,
                .taskbar_press_paints = stats.global_stats.taskbar_press_paints,
                .taskbar_audio_paints = stats.global_stats.taskbar_audio_paints,
                .recent_errors_count = stats.global_stats.errors_count,
                .anim_frames_scheduled = stats.global_stats.anim_frames_scheduled,
                .anim_wasted_wakeups = stats.global_stats.anim_wasted_wakeups,
                .anim_longest_ms = stats.global_stats.anim_longest_ms,
                .anim_speed = @import("ui").anim.speed(),
                .anim_enabled = @import("ui").anim.enabled(),
                .anim_reduced_motion = @import("ui").anim.reducedMotion(),
                .startup = startupStats(),
                .desktop = stats.global_stats.desktop,
                .output_skipped_commits = stats.global_stats.output_skipped_commits,
                .glass_reblurs = @import("../scene_output.zig").reblurs.*,
            } } };
        },
        .reset_performance_stats => {
            server.ensureGpuTimer();
            stats.global_stats.reset();
            @import("../panel_present.zig").reset();
            @import("../scene_output.zig").reblurs.* = 0;
            return .{ .ok = .handled };
        },

        // Phase 4 targeted actions
        .set_desktop_mode => |p| {
            @import("../config_runtime/workspace_controls.zig").mode(server, p.mode, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_window_gap => |p| {
            @import("../config_runtime/workspace_controls.zig").gap(server, p.gap, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_floating_apps => |p| {
            @import("../config_runtime/workspace_controls.zig").floatingApps(server, p.apps, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_workspace_layout => |p| {
            if (!server.world.workspaces.active) return .{ .err = "WorkspaceModeRequired" };
            @import("../config_runtime/workspace_controls.zig").automatic(server, p.workspace, p.automatic);
            return .{ .ok = .handled };
        },
        .switch_workspace => |p| {
            if (!server.world.workspaces.active) return .{ .err = "WorkspaceModeRequired" };
            server.world.workspaces.switchTo(server, p.workspace);
            return .{ .ok = .handled };
        },
        .move_to_workspace => |p| {
            if (!server.world.workspaces.active) return .{ .err = "WorkspaceModeRequired" };
            const top = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            server.world.workspaces.moveTo(top, p.workspace);
            return .{ .ok = .handled };
        },
        .tiling_action => |p| {
            if (!server.world.workspaces.active) return .{ .err = "WorkspaceModeRequired" };
            const top = if (p.id) |id| findToplevelById(server, id) orelse return .{ .err = "UnknownWindow" } else findFocusedToplevel(server);
            if (top) |target| if (!target.in_world or !@import("../workspaces.zig").visible(target)) return .{ .err = "WindowNotVisible" };
            @import("../auto_tiling.zig").execute(server, top, p.action);
            return .{ .ok = .handled };
        },
        .maximize_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            toplevel.setMaximized(true);
            return .{ .ok = .handled };
        },
        .minimize_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            toplevel.minimize();
            return .{ .ok = .handled };
        },
        .restore_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            if (toplevel.minimized) {
                toplevel.restore();
            } else if (toplevel.maximized) {
                toplevel.setMaximized(false);
            } else if (toplevel.fullscreen) {
                toplevel.setFullscreen(false);
            }
            return .{ .ok = .handled };
        },
        .fullscreen_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            _ = p.output;
            toplevel.toggleFullscreen();
            return .{ .ok = .handled };
        },
        .stop_xwayland => {
            const xwayland = server.xwayland orelse return .{ .err = "XwaylandNotRunning" };
            xwayland.stop();
            return .{ .ok = .handled };
        },
        .set_window_size => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            if (p.width <= 0 or p.height <= 0) return .{ .err = "InvalidCoordinates" };
            if (server.input.tiling_grab != null) server.input.finishTilingGrab(false);
            var transaction: ?@import("../layout_undo.zig").Transaction = if (server.world.workspaces.active)
                @import("../layout_undo.zig").Transaction.begin(server, &.{toplevel.workspace_id})
            else
                null;
            defer if (transaction) |*change| change.finish();
            if (transaction) |*change| change.resized = .{ .id = toplevel.id, .width = p.width, .height = p.height };
            if (toplevel.auto_target != null) toplevel.leaveLayout();
            _ = toplevel.requestSizeAnimated(p.width, p.height);
            return .{ .ok = .handled };
        },
        .set_window_zoom => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            for (@import("../camera.zig").zoom_levels, 0..) |pct, idx| {
                if (pct == p.percent) {
                    toplevel.setZoom(idx, server.input.cursor.x, server.input.cursor.y);
                    return .{ .ok = .handled };
                }
            }
            return .{ .err = "InvalidRequest: unsupported zoom percent" };
        },
        .close_panel => |p| {
            const out = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            const panel = std.meta.stringToEnum(enum { start_menu, control_center, power_menu }, p.panel) orelse
                return .{ .err = "UnknownPanel" };
            switch (panel) {
                .start_menu => out.closeStartMenu(),
                .control_center => out.closeControlCenter(),
                .power_menu => out.closePowerMenu(),
            }
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .restart_shell => {
            @import("../config_runtime/actions.zig").executeAction(server, .restart_shell);
            return .{ .ok = .handled };
        },
        .switch_layout => |target| {
            @import("../input/layouts.zig").switchLayout(server, target) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .reload_config => {
            @import("../config_runtime/watcher.zig").reloadConfig(server);
            return .{ .ok = .handled };
        },
        .launch_app => |p| {
            const launch_mod = @import("../start_menu/launch.zig");
            const snap = server.start_menu_catalog.retainSnapshot();
            defer snap.release();
            for (snap.entries) |*entry| {
                if (std.mem.eql(u8, entry.id, p.desktop_id)) {
                    try launch_mod.launchUris(allocator, server, entry, p.uris);
                    return .{ .ok = .handled };
                }
            }
            return .{ .err = "UnknownDesktopId" };
        },
        .get_idle_state => {
            return getIdleState(server, allocator);
        },
        .set_output_config => |p| {
            const output = findOutputByName(server, p.output) orelse return .{ .err = "UnknownOutput" };
            output.applyAndPersist(p) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_idle_config => |p| {
            if (server.idle) |im| {
                if (p.enabled) |e| im.config.enabled = e;
                if (p.blank_after_seconds) |b| im.config.blank_after_seconds = b;
                if (p.suspend_after_seconds) |s| im.config.suspend_after_seconds = s;
                im.recheckInhibitors();
                im.armNextTimeout();
                return .{ .ok = .handled };
            }
            return .{ .err = "IdleManagerNotAvailable" };
        },
        .advance_idle_time => |p| {
            if (server.idle) |im| {
                const current = im.clock.nowMs();
                const target = current + (@as(i64, p.seconds) * 1000);
                im.clock.mock_now_ms = target;
                im.tickTimer();
                return .{ .ok = .handled };
            }
            return .{ .err = "IdleManagerNotAvailable" };
        },
        .get_night_light => {
            return getNightLight(server, allocator);
        },
        .set_night_light_clock => |p| {
            server.night_light.setClockOverride(p.unix_seconds);
            return .{ .ok = .handled };
        },
        .dismiss_notification => |p| {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            const reason = p.reason orelse 2;
            notif_mgr.closeNotification(p.id, reason);
            return .{ .ok = .handled };
        },
        .invoke_notification_action => |p| {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            notif_mgr.invokeAction(p.id, p.action_key);
            return .{ .ok = .handled };
        },
        .set_dnd => |p| {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            notif_mgr.dnd = p.enabled;
            return .{ .ok = .handled };
        },
        .clear_notifications => {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            notif_mgr.clearNotifications("all");
            return .{ .ok = .handled };
        },
        .undo => {
            @import("../config_runtime/actions.zig").executeAction(server, .undo);
            return .{ .ok = .handled };
        },
        .click_widget => |p| {
            const outcome = try resolveWidget(server, p.path, allocator);
            const target = switch (outcome) {
                .ok => |node| node,
                .panel_not_open => return .{ .err = "PanelNotOpen" },
                .not_found => return .{ .err = "NotFound" },
                .not_visible => return .{ .err = "NotVisible" },
                .disabled => return .{ .err = "Disabled" },
            };

            const gbox = target.global_box orelse return .{ .err = "NotFound" };
            const pt = computeTargetPoint(gbox, p.at);

            server.input.warpCursor(@floatFromInt(pt.x), @floatFromInt(pt.y), VirtualInput.nowMs());

            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            const btn = p.button orelse 0x110;
            const now = VirtualInput.nowMs();
            vi.pointer.sendButton(now, btn, .pressed);
            vi.pointer.sendButton(now, btn, .released);

            if (server.ipc) |ipc| {
                var node_arena = std.heap.ArenaAllocator.init(allocator);
                defer node_arena.deinit();
                if (findWidgetNode(server, p.path, node_arena.allocator()) catch null) |updated_node| {
                    const slash_idx = std.mem.indexOfScalar(u8, p.path, '/');
                    const panel_name = if (slash_idx) |idx| p.path[0..idx] else "panel";
                    events.onWidgetChanged(ipc, panel_name, updated_node);
                }
            }

            return .{ .ok = .{ .click_widget = .{
                .point = pt,
                .x = pt.x,
                .y = pt.y,
            } } };
        },
        .hover_widget => |p| {
            const outcome = try resolveWidget(server, p.path, allocator);
            const target = switch (outcome) {
                .ok => |node| node,
                .panel_not_open => return .{ .err = "PanelNotOpen" },
                .not_found => return .{ .err = "NotFound" },
                .not_visible => return .{ .err = "NotVisible" },
                .disabled => return .{ .err = "Disabled" },
            };

            const gbox = target.global_box orelse return .{ .err = "NotFound" };
            const pt = computeTargetPoint(gbox, p.at);

            server.input.warpCursor(@floatFromInt(pt.x), @floatFromInt(pt.y), VirtualInput.nowMs());

            return .{ .ok = .{ .hover_widget = .{
                .point = pt,
                .x = pt.x,
                .y = pt.y,
            } } };
        },
    }
}

/// One pixel read in a little-endian 32-bit DRM `format`, as 0xAARRGGBB.
pub fn packedArgb(format: u32, pixel: u32) ?u32 {
    const argb8888: u32 = 0x34325241;
    const xrgb8888: u32 = 0x34325258;
    const abgr8888: u32 = 0x34324241;
    const xbgr8888: u32 = 0x34324258;
    const swapped = (pixel & 0xff00ff00) | ((pixel & 0xff) << 16) | ((pixel >> 16) & 0xff);
    return switch (format) {
        argb8888 => pixel,
        xrgb8888 => pixel | 0xff000000,
        abgr8888 => swapped,
        xbgr8888 => swapped | 0xff000000,
        else => null,
    };
}

test "sampled pixels are reported as 0xAARRGGBB from every 8-bit read format" {
    try std.testing.expectEqual(@as(?u32, 0x80112233), packedArgb(0x34325241, 0x80112233));
    try std.testing.expectEqual(@as(?u32, 0xff112233), packedArgb(0x34325258, 0x00112233));
    try std.testing.expectEqual(@as(?u32, 0x80112233), packedArgb(0x34324241, 0x80332211));
    try std.testing.expectEqual(@as(?u32, 0xff112233), packedArgb(0x34324258, 0x00332211));
    try std.testing.expectEqual(@as(?u32, null), packedArgb(0, 0));
}

/// `dump_buffer` targets; the panel tags double as `Output` field names.
pub const DumpTarget = enum {
    titlebar,
    taskbar,
    start_menu,
    control_center,
    power_menu,

    fn missingError(comptime target: DumpTarget) []const u8 {
        return switch (target) {
            .taskbar => "NoTaskbar",
            .start_menu => "StartMenuNotOpen",
            .control_center => "ControlCenterNotOpen",
            .power_menu => "PowerMenuNotOpen",
            .titlebar => @compileError("window targets have no panel"),
        };
    }
};

test {
    _ = @import("handlers_tests.zig");
}
