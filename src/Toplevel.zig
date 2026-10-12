const std = @import("std");
const xscale = @import("xwayland_scale.zig");
const glass = @import("glass.zig");
const explicit_sync = @import("explicit_sync.zig");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");
const col = @import("color.zig");

const Decoration = @import("Decoration.zig");
const Input = @import("Input.zig");
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const ControlCenter = @import("control_center/panel.zig").ControlCenter;
const chrome = @import("chrome.zig");
const geometry = @import("geometry.zig");
const icon_service = @import("icon_service.zig");
const resize = @import("resize.zig");
const tiling = @import("snap.zig");
const scene_data = @import("scene_data.zig");
const projection = @import("projection.zig");
const theme = @import("ui").theme;
const events = @import("ipc/events.zig");
const stats = @import("ipc/stats.zig");
const protocol = @import("ipc/protocol.zig");
const xdg = @import("xdg.zig");
const xwayland_surface = @import("xwayland_surface.zig");
const gpa = @import("main.zig").gpa;
const window_rules = @import("config").window_rules;
const loader = @import("config").loader;
const actions = @import("config_runtime/actions.zig");
const anim = @import("ui").anim;
const window_sizes = @import("window_sizes.zig");
const placeholder_match = @import("placeholder_match.zig");
const applications = @import("start_menu/applications.zig");

const Toplevel = @This();

const log = std.log.scoped(.toplevel);

pub const Placeholder = struct {
    desktop_id: [:0]const u8,
    name: [:0]const u8,
    app_id: [:0]const u8,
    startup_wm_class: ?[:0]const u8 = null,
    icon: ?[:0]const u8 = null,
    token: ?[:0]const u8 = null,
    pid: ?i32 = null,
    client_width: i32,
    client_height: i32,
    body_rect: *wlr.SceneRect,
    delay_timer: ?*wl.EventSource = null,
    timeout_timer: ?*wl.EventSource = null,
    child_source: ?*wl.EventSource = null,
    child_pidfd: i32 = -1,
    launch_time_ms: i64,
    matched: bool = false,
    cancelled: bool = false,

    pub fn setPid(self: *Placeholder, toplevel: *Toplevel, pid: i32) void {
        self.pid = pid;
        if (pid <= 0 or self.child_source != null) return;
        const rc = std.os.linux.pidfd_open(pid, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) return;
        self.child_pidfd = @intCast(rc);
        self.child_source = toplevel.server.wl_server.getEventLoop().addFd(*Toplevel, self.child_pidfd, .{ .readable = true }, handleChildExit, toplevel) catch {
            _ = std.os.linux.close(self.child_pidfd);
            self.child_pidfd = -1;
            return;
        };
    }

    pub fn deinit(self: *Placeholder) void {
        if (self.delay_timer) |t| {
            t.remove();
            self.delay_timer = null;
        }
        if (self.timeout_timer) |t| {
            t.remove();
            self.timeout_timer = null;
        }
        if (self.child_source) |source| source.remove();
        if (self.child_pidfd >= 0) _ = std.os.linux.close(self.child_pidfd);
        gpa.free(self.desktop_id);
        gpa.free(self.name);
        gpa.free(self.app_id);
        if (self.startup_wm_class) |wmc| gpa.free(wmc);
        if (self.icon) |ico| gpa.free(ico);
        if (self.token) |tok| gpa.free(tok);
    }

    pub fn cancel(self: *Placeholder, toplevel: *Toplevel) void {
        if (self.cancelled or self.matched) return;
        self.cancelled = true;
        if (self.pid) |p| {
            if (p > 0) {
                _ = std.posix.kill(p, std.posix.SIG.TERM) catch {};
            }
        }
        if (toplevel.server.ipc) |ipc| {
            events.onLaunchTimeout(ipc, self.desktop_id, self.pid);
        }
        toplevel.destroyNow();
    }
};

/// Protocol-specific window backend. Shared chrome, taskbar, world geometry,
/// and IPC talk to this tagged union rather than an xdg pointer.
pub const Backend = union(enum) {
    xdg: xdg,
    xwayland: xwayland_surface,
    placeholder: Placeholder,
    shell: Shell,
};

/// A window whose content the compositor draws itself (the settings window).
/// It has no wl_surface: keyboard focus is "first in the stack with no seat
/// focus", and pointer input reaches the content through its own scene data.
pub const Shell = struct {
    /// Cleared before the window is destroyed; the content owns this window.
    control_center: ?*ControlCenter,
    client_width: i32,
    client_height: i32,
};

pub const settings_title: [:0]const u8 = "RediWM Settings";
pub const settings_app_id: [:0]const u8 = "rediwm-settings";

/// Token returned by `requestSize`. xdg waits on a configure serial; X11
/// waits on a surface commit. Never invent an xdg serial for X11.
pub const ConfigureWait = union(enum) {
    none,
    xdg_serial: u32,
    x11_commit,
};

server: *Server,
link: wl.list.Link = undefined,
backend: Backend,
// The frame tree owns compositor-drawn chrome and the client surface tree.
// Keeping it separate lets the client remain entirely undecorated.
frame_tree: *wlr.SceneTree,
shadow_tree: *wlr.SceneTree,
// The analytic shadow's leaf: no buffer, only footprint, opacity and input.
shadow_node: *wlr.SceneBuffer,
resize_grab: *wlr.SceneBuffer,
glass_effect: ?*glass.Effect = null,
titlebar_buffer: *wlr.SceneBuffer,
// Body under the border ring beside and below the client (left, right, bottom).
frame_fills: [3]*wlr.SceneRect,
// The outline of a window that draws its own decorations.
border_rects: [4]*wlr.SceneRect,
content_tree: *wlr.SceneTree,
scene_tree: *wlr.SceneTree,
decoration: ?*Decoration = null,
kde_decoration: ?*@import("KdeDecoration.zig") = null,
frame_data: scene_data.SceneData = undefined,
chrome_data: scene_data.SceneData = undefined,

id: u64 = 0,
workspace_id: u8 = 0,
workspace_order: u64 = 0,
workspace_generation: u64 = 0,
canvas_state: ?@import("workspaces.zig").CanvasWindow = null,
// Hidden tabs stay mapped; this is independent of client minimization.
tab_group: u64 = 0,
tab_identity: []const u8 = "",
tab_pending_group: u64 = 0,
tab_hidden: bool = false,
tab_restore: ?RestoreGeometry = null,
tab_notice: @import("window_tabs.zig").Notice = .none,
tab_first: usize = 0,
tab_hover: u64 = 0,

/// Digest of the last window record sent to IPC subscribers; most commits
/// only change pixels, and `events.onWindowChanged` skips those.
ipc_window_digest: ?u64 = null,

/// Published while mapped, xdg-shell-backed only (docs/screen-sharing.md
/// stage 3 leaves Xwayland windows unlisted until their unmanaged
/// menus/tooltips have a tested ownership rule). Created in `handleMapped`,
/// kept in sync in `handleIdentityChanged`, destroyed in `handleUnmapped`.
foreign_handle: ?*wlr.ExtForeignToplevelHandleV1 = null,
/// wlr-foreign-toplevel-management handle for docks and window switchers,
/// every backend but placeholders, while mapped.
wlr_foreign: ?*@import("foreign_toplevel.zig").Handle = null,

/// Top-left of the authoritative frame in world coordinates. Panning and
/// desktop zoom leave these unchanged; window zoom repositions the frame to
/// preserve its pointer anchor. Client dimensions remain unscaled.
x: i32 = 0,
y: i32 = 0,
render_scale: f32 = 1,
chrome_width: i32 = 0,
chrome_height: i32 = 0,
/// Compositor activation is immediate; client protocol acknowledgements lag.
activated: bool = false,
zoom_index: usize = 0,
zoom_scale: f64 = 1.0,
/// Presentation-only focus boost. Neither saved geometry nor zoom_index changes.
zoom_boost: anim.Anim = .{},
zoom_boost_value: f64 = 0,
zoom_anim: @import("ui").anim.Anim = .{ .from = 1, .to = 1 },
zoom_anchor: geometry.Vec2 = .{ .x = 0, .y = 0 },
zoom_local: geometry.Vec2 = .{ .x = 0, .y = 0 },
peek_mix: @import("ui").anim.Anim = .{ .property = .opacity },
peek_level: @import("ui").anim.Anim = .{ .from = 1, .to = 1, .property = .opacity },
map_motion: anim.Anim = .{ .from = 1, .to = 1 },
map_opacity: anim.Anim = .{ .from = 1, .to = 1, .property = .opacity },
move_x: anim.Anim = .{},
move_y: anim.Anim = .{},
/// Temporary displacement of the frame in world units (`input/drag_dodge.zig`).
/// Presentation only: `x`/`y`, the canvas bounds, IPC and saved layouts never
/// see it, and it is never folded into `move_x`/`move_y`.
dodge_x: anim.Anim = .{},
dodge_y: anim.Anim = .{},
/// Workspace switch (`workspaces.zig`): an offset in world units and a fade,
/// presentation only like `dodge_*`. A window whose workspace was hidden keeps
/// its frame shown, inert, until they settle (`switch_leaving`).
switch_x: anim.Anim = .{},
switch_y: anim.Anim = .{},
switch_fade: anim.Anim = .{ .from = 1, .to = 1, .property = .opacity },
switch_leaving: bool = false,
size_w: anim.Anim = .{},
size_h: anim.Anim = .{},
/// The size request `size_w`/`size_h` ease toward. Once the client has answered
/// it, a settled animation gives way to the size the client took (one that
/// cannot fit is never clipped to a frame it refused).
size_wait: ConfigureWait = .none,
// Last clip handed to `wlr_scene_subsurface_tree_set_clip`, so an unchanged
// clip is not re-applied. `applySizeClip` runs from `syncChrome`, i.e. on
// every client commit, and wlroots walks the whole subsurface tree on each
// call; once a window's size has settled that call is pure per-commit waste.
last_clip: ?wlr.Box = null,
last_clip_valid: bool = false,
close_snapshot: ?*wlr.SceneTree = null,
closing: bool = false,
in_closing_list: bool = false,
backend_gone: bool = false,
closing_link: wl.list.Link = undefined,
hovered: bool = false,
hovered_control: ?chrome.ControlKind = null,
hover_anim: anim.Anim = .{},
// Window-button hover chip: slot coordinate (chrome.controlSlot) and opacity.
chip_pos: anim.Anim = .{},
chip_alpha: anim.Anim = .{ .property = .opacity },
last_painted_hover: f32 = 0,
/// The window opacity the border colour of the shape was last given, so a
/// hover or focus repaint keeps the ring as faded as the body.
shape_opacity: f32 = 1,
// Inputs that produced the buffers currently attached to the scene nodes.
// syncChrome / syncShadow skip a re-raster when these still match.
last_titlebar: ?chrome.TitlebarMemo = null,
cached_titlebar: ?*chrome.ChromeBuffer = null,
last_shadow: ?chrome.ShadowMemo = null,
// xdg-shell has no minimized state of its own; this is purely a
// compositor-side hint that hides the frame while the client stays mapped.
minimized: bool = false,
needs_attention: bool = false,
maximized: bool = false,
fullscreen: bool = false,
in_world: bool = false,
placed: bool = false,
placeholder_source: ?*Toplevel = null,
rules_resolved: bool = false,
resolved_before_app_id: bool = false,
open_rules: window_rules.OpenRules = .{},
live_rules: window_rules.LiveRules = .{},
matched_rules: std.StaticBitSet(window_rules.max_rules) = std.StaticBitSet(window_rules.max_rules).initEmpty(),
maximize_restore: ?RestoreGeometry = null,
fullscreen_restore: ?RestoreGeometry = null,
maximize_target: ?RestoreGeometry = null,
fullscreen_target: ?RestoreGeometry = null,
// Automatic rectangles are independent of manual half/quarter tiles.
// Explicit floating placement opts a member out; overflow can retry later.
auto_target: ?RestoreGeometry = null,
auto_restore: ?RestoreGeometry = null,
auto_float: bool = false,
auto_float_override: ?bool = null,
auto_seen: ?@import("auto_tiling.zig").State = null,
auto_reinsert: ?@import("auto_layout.zig").Placement = null,
/// The window that had focus on this one's workspace when it joined it: a new
/// tile splits that window's tile. Cleared once the window is in the tree.
auto_anchor: ?u64 = null,
tab_resume_group: u64 = 0,
tab_resume_restore: ?RestoreGeometry = null,
// Manual half/quarter tile and the floating geometry to return to.
tile: ?tiling.Tile = null,
tile_target: ?RestoreGeometry = null,
tile_restore: ?RestoreGeometry = null,
pending_restore: ?RestoreGeometry = null,
forced_geometry_timer: ?*wl.EventSource = null,
reconnect_output: [128]u8 = undefined,
reconnect_output_len: usize = 0,
reconnect_expected_x: i32 = 0,
reconnect_expected_y: i32 = 0,
reconnect_offset_x: i32 = 0,
reconnect_offset_y: i32 = 0,
reconnect_maximized: bool = false,
reconnect_fullscreen: bool = false,
reconnect_tile: ?tiling.Tile = null,

pub const RestoreGeometry = @import("undo.zig").Geometry;

const ChromeNodes = struct {
    frame_tree: *wlr.SceneTree,
    shadow_tree: *wlr.SceneTree,
    shadow_node: *wlr.SceneBuffer,
    resize_grab: *wlr.SceneBuffer,
    glass_effect: ?*glass.Effect,
    titlebar_buffer: *wlr.SceneBuffer,
    frame_fills: [3]*wlr.SceneRect,
    border_rects: [4]*wlr.SceneRect,
    content_tree: *wlr.SceneTree,
};

fn createChromeNodes(server: *Server) !ChromeNodes {
    const frame_tree = try server.world.tree.createSceneTree();
    errdefer frame_tree.node.destroy();
    // Hidden until handleMapped. An X11 window gets titled, configured and
    // chrome-synced long before it maps, and some never map at all; a visible
    // frame would be a clickable ghost for a window not in world.toplevels.
    frame_tree.node.setEnabled(false);
    if (!@import("projection.zig").setTreeZoom(&frame_tree.node, 1)) return error.OutOfMemory;

    // Input only: no buffer, so never drawn. Gives the edges their reach past
    // the frame without depending on the shadow (`shadow_size = 0`). It sits in
    // a tree of its own so that the window's shape, which cuts the corners off
    // everything else under the frame, does not cut its reach: that must accept
    // points the shape declines.
    const reach_tree = try frame_tree.createSceneTree();
    _ = @import("projection.zig").setTreeUnclipped(&reach_tree.node, true);
    const resize_grab = try reach_tree.createSceneBuffer(null);
    resize_grab.point_accepts_input = chromeAcceptsInput;

    const shadow_tree = try frame_tree.createSceneTree();
    // The shadow is outside the shape by definition.
    _ = @import("projection.zig").setTreeUnclipped(&shadow_tree.node, true);
    const shadow_node = try shadow_tree.createSceneBuffer(null);
    shadow_node.point_accepts_input = chromeAcceptsInput;

    const titlebar_buffer = try frame_tree.createSceneBuffer(null);
    const glass_effect = glass.Engine.attach(server.glass_engine, titlebar_buffer, &shadow_tree.node, .titlebar);
    titlebar_buffer.setFilterMode(.bilinear);

    // The titlebar backs the ring at the top with its fill. Carry that same
    // chrome under the ring beside and below the client.
    var frame_fills: [3]*wlr.SceneRect = undefined;
    for (&frame_fills) |*rect| {
        rect.* = try col.createRect(frame_tree, 1, 1, chrome.fillColor());
    }
    const border_color = chrome.borderColor(0);
    var border_rects: [4]*wlr.SceneRect = undefined;
    for (&border_rects) |*rect| {
        rect.* = try col.createRect(frame_tree, 1, 1, border_color);
    }

    const content_tree = try frame_tree.createSceneTree();
    return .{
        .frame_tree = frame_tree,
        .shadow_tree = shadow_tree,
        .shadow_node = shadow_node,
        .resize_grab = resize_grab,
        .glass_effect = glass_effect,
        .titlebar_buffer = titlebar_buffer,
        .frame_fills = frame_fills,
        .border_rects = border_rects,
        .content_tree = content_tree,
    };
}

fn finishCreate(toplevel: *Toplevel, nodes: ChromeNodes, scene_tree: *wlr.SceneTree) void {
    toplevel.frame_tree = nodes.frame_tree;
    toplevel.shadow_tree = nodes.shadow_tree;
    toplevel.shadow_node = nodes.shadow_node;
    toplevel.resize_grab = nodes.resize_grab;
    toplevel.glass_effect = nodes.glass_effect;
    toplevel.titlebar_buffer = nodes.titlebar_buffer;
    toplevel.frame_fills = nodes.frame_fills;
    toplevel.border_rects = nodes.border_rects;
    toplevel.content_tree = nodes.content_tree;
    toplevel.scene_tree = scene_tree;
    toplevel.attachSceneData();
    nodes.titlebar_buffer.point_accepts_input = chromeAcceptsInput;
}

pub fn create(server: *Server, xdg_toplevel: *wlr.XdgToplevel) !void {
    const xdg_surface = xdg_toplevel.base;

    const toplevel = try gpa.create(Toplevel);
    errdefer gpa.destroy(toplevel);

    const nodes = try createChromeNodes(server);
    errdefer nodes.frame_tree.node.destroy();
    const scene_tree = try nodes.content_tree.createSceneXdgSurface(xdg_surface);

    toplevel.* = .{
        .server = server,
        .id = server.next_toplevel_id,
        .backend = .{ .xdg = .{
            .window = toplevel,
            .xdg_toplevel = xdg_toplevel,
        } },
        .frame_tree = nodes.frame_tree,
        .shadow_tree = nodes.shadow_tree,
        .shadow_node = nodes.shadow_node,
        .resize_grab = nodes.resize_grab,
        .glass_effect = nodes.glass_effect,
        .titlebar_buffer = nodes.titlebar_buffer,
        .frame_fills = nodes.frame_fills,
        .border_rects = nodes.border_rects,
        .content_tree = nodes.content_tree,
        .scene_tree = scene_tree,
    };
    server.next_toplevel_id += 1;
    finishCreate(toplevel, nodes, scene_tree);
    scene_data.setXdgSceneTree(xdg_surface, scene_tree);
    server.shell.kde_decorations.attach(toplevel);
    switch (toplevel.backend) {
        .xdg => |*adapter| adapter.listen(),
        .xwayland, .placeholder, .shell => {},
    }
}

pub fn createXwayland(server: *Server, xsurface: *wlr.XwaylandSurface) !void {
    const toplevel = try gpa.create(Toplevel);
    errdefer gpa.destroy(toplevel);

    const nodes = try createChromeNodes(server);
    errdefer nodes.frame_tree.node.destroy();
    const scale_n = server.xwaylandScale();
    if (scale_n > 1) {
        _ = @import("projection.zig").setTreeScale(&nodes.content_tree.node, 1.0 / scale_n);
    }
    const scene_tree = try nodes.content_tree.createSceneTree();

    toplevel.* = .{
        .server = server,
        .id = server.next_toplevel_id,
        .backend = .{ .xwayland = .{
            .window = toplevel,
            .xsurface = xsurface,
        } },
        .maximized = xsurface.maximized_horz and xsurface.maximized_vert,
        .fullscreen = xsurface.fullscreen,
        .frame_tree = nodes.frame_tree,
        .shadow_tree = nodes.shadow_tree,
        .shadow_node = nodes.shadow_node,
        .resize_grab = nodes.resize_grab,
        .glass_effect = nodes.glass_effect,
        .titlebar_buffer = nodes.titlebar_buffer,
        .frame_fills = nodes.frame_fills,
        .border_rects = nodes.border_rects,
        .content_tree = nodes.content_tree,
        .scene_tree = scene_tree,
    };
    server.next_toplevel_id += 1;
    finishCreate(toplevel, nodes, scene_tree);
    xsurface.data = toplevel;
    switch (toplevel.backend) {
        .xdg, .placeholder, .shell => {},
        .xwayland => |*adapter| adapter.listen(),
    }
}

fn handleDelayTimeout(toplevel: *Toplevel) c_int {
    if (toplevel.backend != .placeholder) return 0;
    const ph = &toplevel.backend.placeholder;
    if (ph.delay_timer) |t| {
        t.remove();
        ph.delay_timer = null;
    }
    if (!ph.matched and !ph.cancelled and toplevel.in_world) {
        toplevel.frame_tree.node.setEnabled(@import("window_tabs.zig").visible(toplevel));
        toplevel.server.scheduleFrames();
    }
    return 0;
}

fn handleLaunchTimeout(toplevel: *Toplevel) c_int {
    if (toplevel.backend != .placeholder) return 0;
    const ph = &toplevel.backend.placeholder;
    if (ph.timeout_timer) |t| {
        t.remove();
        ph.timeout_timer = null;
    }
    if (!ph.matched and !ph.cancelled) {
        if (toplevel.server.ipc) |ipc| {
            events.onLaunchTimeout(ipc, ph.desktop_id, ph.pid);
        }
        toplevel.destroyNow();
    }
    return 0;
}

// Observe the same pidfd exit without reaping: services owns the child status.
fn handleChildExit(_: c_int, _: wl.EventMask, toplevel: *Toplevel) c_int {
    if (toplevel.backend != .placeholder) return 0;
    const ph = &toplevel.backend.placeholder;
    if (ph.child_source) |source| source.remove();
    ph.child_source = null;
    if (ph.child_pidfd >= 0) _ = std.os.linux.close(ph.child_pidfd);
    ph.child_pidfd = -1;
    if (!ph.matched and !ph.cancelled) {
        if (toplevel.server.ipc) |ipc| events.onLaunchTimeout(ipc, ph.desktop_id, ph.pid);
        toplevel.destroyNow();
    }
    return 0;
}

pub fn createPlaceholder(
    server: *Server,
    entry: *const applications.AppEntry,
    token_str: ?[]const u8,
) !*Toplevel {
    const toplevel = try gpa.create(Toplevel);
    errdefer gpa.destroy(toplevel);

    const nodes = try createChromeNodes(server);
    errdefer nodes.frame_tree.node.destroy();
    const scene_tree = try nodes.content_tree.createSceneTree();

    var init_w: i32 = 640;
    var init_h: i32 = 480;
    if (window_sizes.load(server.io, server.environ, entry.id)) |saved| {
        init_w = saved.width;
        init_h = saved.height;
    }

    const synth_id: window_rules.WindowIdentity = .{
        .app_id = if (entry.startup_wm_class) |wmc| wmc else entry.id,
        .title = entry.name,
        .backend = .xdg,
        .dialog = false,
    };
    const resolved = window_rules.resolve(server.config.window_rules, synth_id);
    const open_rules = window_rules.OpenRules.fromResolved(resolved);
    const live_rules = window_rules.LiveRules.fromResolved(resolved);
    if (open_rules.width) |rw| init_w = @intCast(rw);
    if (open_rules.height) |rh| init_h = @intCast(rh);

    const body_color = col.Straight.fromRgba(theme.global.window_bg).premultiply();
    const body_rect = try col.createRect(nodes.content_tree, init_w, init_h, body_color);

    const desktop_id = try gpa.dupeZ(u8, entry.id);
    errdefer gpa.free(desktop_id);
    const name = try gpa.dupeZ(u8, entry.name);
    errdefer gpa.free(name);
    const app_id = try gpa.dupeZ(u8, if (entry.startup_wm_class) |wmc| wmc else entry.id);
    errdefer gpa.free(app_id);
    const startup_wm_class = if (entry.startup_wm_class) |wmc| try gpa.dupeZ(u8, wmc) else null;
    errdefer if (startup_wm_class) |wmc| gpa.free(wmc);
    const icon = if (entry.icon) |ico| try gpa.dupeZ(u8, ico) else null;
    errdefer if (icon) |ico| gpa.free(ico);
    const token = if (token_str) |tok| try gpa.dupeZ(u8, tok) else null;
    errdefer if (token) |tok| gpa.free(tok);

    toplevel.* = .{
        .server = server,
        .id = server.next_toplevel_id,
        .backend = .{ .placeholder = .{
            .desktop_id = desktop_id,
            .name = name,
            .app_id = app_id,
            .startup_wm_class = startup_wm_class,
            .icon = icon,
            .token = token,
            .pid = null,
            .client_width = init_w,
            .client_height = init_h,
            .body_rect = body_rect,
            .launch_time_ms = nowMs(),
        } },
        .open_rules = open_rules,
        .live_rules = live_rules,
        .matched_rules = resolved.matched_rules,
        .rules_resolved = true,
        .frame_tree = nodes.frame_tree,
        .shadow_tree = nodes.shadow_tree,
        .shadow_node = nodes.shadow_node,
        .resize_grab = nodes.resize_grab,
        .glass_effect = nodes.glass_effect,
        .titlebar_buffer = nodes.titlebar_buffer,
        .frame_fills = nodes.frame_fills,
        .border_rects = nodes.border_rects,
        .content_tree = nodes.content_tree,
        .scene_tree = scene_tree,
    };
    server.next_toplevel_id += 1;
    finishCreate(toplevel, nodes, scene_tree);

    const target_out = toplevel.resolveTargetOutput() orelse server.getDefaultOutput();
    if (open_rules.fullscreen orelse false) {
        toplevel.fullscreen = true;
        if (target_out) |out| {
            var box: wlr.Box = undefined;
            server.output_layout.getBox(out.wlr_output, &box);
            toplevel.backend.placeholder.client_width = box.width;
            toplevel.backend.placeholder.client_height = box.height;
            toplevel.setupInitialRestoreGeometry(out);
            toplevel.fullscreen_target = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
            toplevel.setPosition(box.x, box.y);
            toplevel.placed = true;
        }
    } else if (open_rules.maximized orelse false) {
        toplevel.maximized = true;
        if (target_out) |out| {
            const usable = out.usableBox();
            const footer = chrome.frame_border;
            const mw = usable.width - 2 * chrome.frame_border;
            const mh = usable.height - toplevel.titlebarHeight() - footer;
            toplevel.backend.placeholder.client_width = @max(1, mw);
            toplevel.backend.placeholder.client_height = @max(1, mh);
            toplevel.setupInitialRestoreGeometry(out);
            toplevel.maximize_target = .{ .x = usable.x, .y = usable.y, .width = @max(1, mw), .height = @max(1, mh) };
            toplevel.setPosition(usable.x, usable.y);
            toplevel.placed = true;
        }
    } else if (target_out) |out| {
        const footer = chrome.frame_border;
        const natural_w = init_w + 2 * chrome.frame_border;
        const natural_h = init_h + toplevel.titlebarHeight() + footer;
        const geom = pickInitialPlacement(server, out, open_rules, null, natural_w, natural_h);
        toplevel.setPosition(geom.x, geom.y);
        toplevel.placed = true;
    }

    try toplevel.syncChrome(true, nowMs());

    server.world.toplevels.prepend(toplevel);
    toplevel.in_world = true;
    toplevel.server.world.workspaces.mapped(toplevel);
    if (server.layout_autosave) |autosave| autosave.finishMapped(toplevel);
    server.world.focus(toplevel);
    server.refreshTaskbars();

    if (server.ipc) |ipc| {
        events.onWindowOpened(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }

    const delay_ms = server.config.compositor.placeholder_delay_ms;
    if (delay_ms > 0) {
        toplevel.frame_tree.node.setEnabled(false);
        toplevel.backend.placeholder.delay_timer = server.wl_server.getEventLoop().addTimer(
            *Toplevel,
            handleDelayTimeout,
            toplevel,
        ) catch null;
        if (toplevel.backend.placeholder.delay_timer) |t| {
            _ = t.timerUpdate(@intCast(delay_ms)) catch {};
        }
    } else {
        toplevel.frame_tree.node.setEnabled(@import("window_tabs.zig").visible(toplevel));
    }

    toplevel.backend.placeholder.timeout_timer = server.wl_server.getEventLoop().addTimer(
        *Toplevel,
        handleLaunchTimeout,
        toplevel,
    ) catch null;
    if (toplevel.backend.placeholder.timeout_timer) |t| {
        _ = t.timerUpdate(10_000) catch {};
    }

    return toplevel;
}

/// A compositor-drawn window of `width`×`height` content, unmapped: the
/// caller fills `scene_tree` with the content, then calls `mapShell`.
pub fn createShell(server: *Server, cc: *ControlCenter, width: i32, height: i32) !*Toplevel {
    const toplevel = try gpa.create(Toplevel);
    errdefer gpa.destroy(toplevel);

    const nodes = try createChromeNodes(server);
    errdefer nodes.frame_tree.node.destroy();
    const scene_tree = try nodes.content_tree.createSceneTree();

    toplevel.* = .{
        .server = server,
        .id = server.next_toplevel_id,
        .backend = .{ .shell = .{
            .control_center = cc,
            .client_width = width,
            .client_height = height,
        } },
        .frame_tree = nodes.frame_tree,
        .shadow_tree = nodes.shadow_tree,
        .shadow_node = nodes.shadow_node,
        .resize_grab = nodes.resize_grab,
        .glass_effect = nodes.glass_effect,
        .titlebar_buffer = nodes.titlebar_buffer,
        .frame_fills = nodes.frame_fills,
        .border_rects = nodes.border_rects,
        .content_tree = nodes.content_tree,
        .scene_tree = scene_tree,
    };
    server.next_toplevel_id += 1;
    finishCreate(toplevel, nodes, scene_tree);
    return toplevel;
}

/// Maps a `createShell` window like a client's first map: rules, placement
/// (centred on the target output unless a rule places it), focus, taskbar,
/// foreign-toplevel handle and the open animation.
pub fn mapShell(toplevel: *Toplevel) void {
    toplevel.resolveInitialRules();
    if (toplevel.open_rules.center == null) toplevel.open_rules.center = true;
    if (toplevel.open_rules.width) |w| toplevel.backend.shell.client_width = @max(ControlCenter.min_width, @as(i32, @intCast(w)));
    if (toplevel.open_rules.height) |h| toplevel.backend.shell.client_height = @max(ControlCenter.min_height, @as(i32, @intCast(h)));
    if (toplevel.backend.shell.control_center) |cc| cc.resize(toplevel.backend.shell.client_width, toplevel.backend.shell.client_height);
    toplevel.handleMapped();
}

pub fn findMatchingPlaceholder(toplevel: *Toplevel) ?*Toplevel {
    var it = toplevel.server.world.toplevels.iterator(.forward);
    while (it.next()) |candidate| {
        if (candidate.backend != .placeholder) continue;
        const ph = &candidate.backend.placeholder;
        if (ph.matched or ph.cancelled) continue;

        if (toplevel.clientPid()) |cpid| {
            if (ph.pid) |ppid| {
                if (placeholder_match.matchesPidChain(cpid, ppid)) return candidate;
            }
        }

        const app_id = toplevel.appId();
        if (app_id.len > 0) {
            if (placeholder_match.matchesAppId(app_id, ph.startup_wm_class, ph.desktop_id)) {
                return candidate;
            }
        }
    }
    return null;
}

pub fn attachXwaylandScene(toplevel: *Toplevel, client_surface: *wlr.Surface) !void {
    const new_tree = try toplevel.content_tree.createSceneSubsurfaceTree(client_surface);
    toplevel.scene_tree.node.destroy();
    toplevel.scene_tree = new_tree;
}

pub fn detachXwaylandScene(toplevel: *Toplevel) void {
    const placeholder = toplevel.content_tree.createSceneTree() catch return;
    toplevel.scene_tree.node.destroy();
    toplevel.scene_tree = placeholder;
}

pub fn replaceDestroyedXwaylandScene(toplevel: *Toplevel) void {
    // The previous node is in its destroy signal and must not be touched.
    toplevel.scene_tree = toplevel.content_tree.createSceneTree() catch return;
}

/// Window that owns `surface`, walking xdg popup parents and subsurface roots.
pub fn fromSurface(server: *Server, candidate: *wlr.Surface) ?*Toplevel {
    var current: *wlr.Surface = candidate;
    var guard: usize = 0;
    while (guard < 32) : (guard += 1) {
        var it = server.world.toplevels.iterator(.forward);
        while (it.next()) |toplevel| {
            if (toplevel.surface()) |owned| {
                if (owned == current) return toplevel;
            }
        }
        if (wlr.XdgSurface.tryFromWlrSurface(current)) |xdg_surface| {
            if (xdg_surface.role == .popup) {
                if (xdg_surface.role_data.popup) |popup| {
                    if (popup.parent) |parent| {
                        current = parent;
                        continue;
                    }
                }
            }
        }
        if (wlr.XwaylandSurface.tryFromWlrSurface(current)) |xs| {
            var xit = server.world.toplevels.iterator(.forward);
            while (xit.next()) |toplevel| {
                switch (toplevel.backend) {
                    .xwayland => |*adapter| if (adapter.xsurface == xs) return toplevel,
                    .xdg, .placeholder, .shell => {},
                }
            }
            if (xs.parent) |parent| {
                if (parent.surface) |ps| {
                    current = ps;
                    continue;
                }
            }
        }
        const root = current.getRootSurface();
        if (root != current) {
            current = root;
            continue;
        }
        return null;
    }
    return null;
}

pub fn surface(toplevel: *const Toplevel) ?*wlr.Surface {
    if (toplevel.backend_gone) return null;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.surface,
        .xwayland => |*adapter| adapter.xsurface.surface,
        .placeholder, .shell => null,
    };
}

pub fn title(toplevel: *const Toplevel) []const u8 {
    return titleOrNull(toplevel) orelse "";
}

pub fn titleOrNull(toplevel: *const Toplevel) ?[]const u8 {
    const ptr = titlePtr(toplevel) orelse return null;
    return std.mem.span(ptr);
}

pub fn titlePtr(toplevel: *const Toplevel) ?[*:0]const u8 {
    if (toplevel.backend_gone) return null;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.title,
        .xwayland => |*adapter| adapter.xsurface.title,
        .placeholder => |*ph| ph.name.ptr,
        .shell => settings_title.ptr,
    };
}

pub fn appId(toplevel: *const Toplevel) []const u8 {
    return appIdOrNull(toplevel) orelse "";
}

pub fn appIdOrNull(toplevel: *const Toplevel) ?[]const u8 {
    return std.mem.span(toplevel.appIdPtr() orelse return null);
}

pub fn appIdPtr(toplevel: *const Toplevel) ?[*:0]const u8 {
    if (toplevel.backend_gone) return null;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.app_id,
        .xwayland => |*adapter| adapter.xsurface.class orelse adapter.xsurface.instance,
        .placeholder => |*ph| ph.app_id.ptr,
        .shell => settings_app_id.ptr,
    };
}

pub fn surfaceScale(toplevel: *const Toplevel) f64 {
    return switch (toplevel.backend) {
        .xwayland => toplevel.server.xwaylandScale(),
        else => 1,
    };
}

pub fn clientSurfaceGeometry(toplevel: *const Toplevel) wlr.Box {
    if (toplevel.backend_gone) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.geometry,
        .xwayland => |*adapter| blk: {
            if (adapter.xsurface.surface) |s| {
                if (s.current.width > 0 and s.current.height > 0) {
                    break :blk .{ .x = 0, .y = 0, .width = s.current.width, .height = s.current.height };
                }
            }
            break :blk .{
                .x = 0,
                .y = 0,
                .width = @intCast(adapter.xsurface.width),
                .height = @intCast(adapter.xsurface.height),
            };
        },
        .placeholder => |*ph| .{
            .x = 0,
            .y = 0,
            .width = ph.client_width,
            .height = ph.client_height,
        },
        .shell => |*sw| .{
            .x = 0,
            .y = 0,
            .width = sw.client_width,
            .height = sw.client_height,
        },
    };
}

pub fn clientGeometry(toplevel: *const Toplevel) wlr.Box {
    var geom = toplevel.clientSurfaceGeometry();
    const n = toplevel.surfaceScale();
    if (n > 1) {
        if (geom.width > 0) geom.width = xscale.worldLength(geom.width, n);
        if (geom.height > 0) geom.height = xscale.worldLength(geom.height, n);
    }
    return geom;
}

pub fn clientPid(toplevel: *const Toplevel) ?i32 {
    return switch (toplevel.backend) {
        .xdg => {
            const owned = surface(toplevel) orelse return null;
            return owned.resource.getClient().getCredentials().pid;
        },
        .xwayland => |*adapter| adapter.xsurface.pid,
        .placeholder => |*ph| ph.pid,
        .shell => null,
    };
}

pub fn waylandClient(toplevel: *const Toplevel) ?*wl.Client {
    return switch (toplevel.backend) {
        .xdg => {
            const owned = surface(toplevel) orelse return null;
            return owned.resource.getClient();
        },
        .xwayland, .placeholder, .shell => null,
    };
}

pub fn sandboxInfo(toplevel: *const Toplevel) ?protocol.WindowSandboxData {
    const client = toplevel.waylandClient() orelse return null;
    const sc_mgr = toplevel.server.security_context orelse return null;
    const state = sc_mgr.lookupClient(client) orelse return null;
    return .{
        .engine = if (state.sandbox_engine) |s| std.mem.span(s) else null,
        .app_id = if (state.app_id) |s| std.mem.span(s) else null,
        .instance_id = if (state.instance_id) |s| std.mem.span(s) else null,
    };
}

/// Urgency requests never raise, restore or move a window. Focus acknowledges
/// attention; repeat requests with the same effective state are silent.
pub fn setUrgent(toplevel: *Toplevel, urgent: bool) void {
    if (!toplevel.in_world or toplevel.closing or toplevel.backend_gone) return;
    const focused = if (toplevel.server.input.seat.keyboard_state.focused_surface) |surface_ptr|
        fromSurface(toplevel.server, surface_ptr) == toplevel
    else
        false;
    const wanted = urgent and !focused;
    if (toplevel.backend == .xwayland) toplevel.backend.xwayland.setDemandsAttention(wanted);
    if (toplevel.needs_attention == wanted) return;
    toplevel.needs_attention = wanted;
    toplevel.server.refreshTaskbars();
    if (toplevel.server.ipc) |ipc| events.onWindowUrgencyChanged(ipc, toplevel.id, wanted);
}

pub fn isMapped(toplevel: *const Toplevel) bool {
    if (toplevel.closing or toplevel.backend_gone) return false;
    if (toplevel.backend == .shell) return true;
    const owned = surface(toplevel) orelse return false;
    return owned.mapped;
}

pub fn isMaximized(toplevel: *const Toplevel) bool {
    if (toplevel.backend_gone) return toplevel.maximized;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.current.maximized,
        .xwayland, .placeholder, .shell => toplevel.maximized,
    };
}

pub fn isFullscreen(toplevel: *const Toplevel) bool {
    if (toplevel.backend_gone) return toplevel.fullscreen;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.current.fullscreen,
        .xwayland, .placeholder, .shell => toplevel.fullscreen,
    };
}

pub fn isInitialized(toplevel: *const Toplevel) bool {
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.initialized,
        // Not just `xsurface.surface != null`: that flips true as soon as the
        // X11 window is associated with a wl_surface, but scene_tree isn't a
        // tracked subsurface tree (wlr_scene_subsurface_tree_create) until
        // attachXwaylandScene actually runs — and a scene_destroy in between
        // (replaceDestroyedXwaylandScene) can drop back to an untracked plain
        // tree while the surface stays associated. `scene_attached` is the
        // precise, current state of scene_tree itself.
        .xwayland => |*adapter| adapter.scene_attached,
        .placeholder, .shell => true,
    };
}

pub fn parentWindow(toplevel: *Toplevel) ?*Toplevel {
    switch (toplevel.backend) {
        .xdg => |*adapter| {
            const parent_xdg = adapter.xdg_toplevel.parent orelse return null;
            var it = toplevel.server.world.toplevels.iterator(.forward);
            while (it.next()) |other| {
                switch (other.backend) {
                    .xdg => |*other_adapter| {
                        if (other_adapter.xdg_toplevel == parent_xdg) return other;
                    },
                    .xwayland, .placeholder, .shell => {},
                }
            }
            return null;
        },
        .xwayland => |*adapter| {
            const parent_xs = adapter.xsurface.parent orelse return null;
            var it = toplevel.server.world.toplevels.iterator(.forward);
            while (it.next()) |other| {
                switch (other.backend) {
                    .xwayland => |*other_adapter| {
                        if (other_adapter.xsurface == parent_xs) return other;
                    },
                    .xdg, .placeholder, .shell => {},
                }
            }
            return null;
        },
        .placeholder, .shell => return null,
    }
}

pub fn sizeConstraints(toplevel: *const Toplevel) resize.SizeConstraints {
    switch (toplevel.backend) {
        .xdg => |*adapter| {
            const current = &adapter.xdg_toplevel.current;
            const pending = &adapter.xdg_toplevel.pending;
            return .{
                .min_width = if (pending.min_width > 0) pending.min_width else current.min_width,
                .max_width = if (pending.max_width > 0) pending.max_width else current.max_width,
                .min_height = if (pending.min_height > 0) pending.min_height else current.min_height,
                .max_height = if (pending.max_height > 0) pending.max_height else current.max_height,
                .control_min_width = 100,
            };
        },
        .xwayland => |*adapter| {
            const hints: ?*const xwayland_surface.SizeHints = if (adapter.xsurface.size_hints) |ptr|
                @ptrCast(@alignCast(ptr))
            else
                null;
            var c = xwayland_surface.sizeConstraintsOf(hints);
            const n = toplevel.surfaceScale();
            if (n > 1) {
                if (c.min_width > 0) c.min_width = xscale.worldLength(c.min_width, n);
                if (c.min_height > 0) c.min_height = xscale.worldLength(c.min_height, n);
                if (c.max_width > 0) c.max_width = xscale.worldFloor(c.max_width, n);
                if (c.max_height > 0) c.max_height = xscale.worldFloor(c.max_height, n);
            }
            return c;
        },
        .placeholder => return .{
            .min_width = 100,
            .max_width = 0,
            .min_height = 100,
            .max_height = 0,
            .control_min_width = 100,
        },
        .shell => |sw| return .{
            .min_width = if (sw.control_center) |cc| cc.minimumWidth() else ControlCenter.min_width,
            .max_width = 0,
            .min_height = if (sw.control_center) |cc| cc.minimumHeight() else ControlCenter.min_height,
            .max_height = 0,
            .control_min_width = 100,
        },
    }
}

/// Keep X11's input stacking in step with the displayed scene. Xwayland
/// resolves pointer events against its own root window stack even when our
/// scene hit test already selected the right surface.
pub fn raise(toplevel: *Toplevel) void {
    toplevel.frame_tree.node.raiseToTop();
    toplevel.syncXwaylandStack();
}

fn syncXwaylandStack(toplevel: *Toplevel) void {
    if (toplevel.backend != .xwayland or toplevel.backend_gone) return;
    if (!@import("workspaces.zig").visible(toplevel)) {
        toplevel.backend.xwayland.xsurface.restack(null, .below);
        return;
    }
    // Use the nearest managed X11 sibling above us. This also covers an
    // initially unfocused window placed below a focused Wayland window.
    if (toplevel.frame_tree.node.parent) |parent| {
        var found_self = false;
        var it = parent.children.iterator(.forward);
        while (it.next()) |node| {
            if (node == &toplevel.frame_tree.node) {
                found_self = true;
                continue;
            }
            if (!found_self) continue;
            const data = scene_data.SceneData.fromNode(node) orelse continue;
            if (data.role != .toplevel) continue;
            const other = data.role.toplevel;
            if (!other.in_world or other.minimized or !@import("workspaces.zig").visible(other) or other.backend_gone or other.backend != .xwayland) continue;
            toplevel.backend.xwayland.xsurface.restack(other.backend.xwayland.xsurface, .below);
            return;
        }
    }
    toplevel.backend.xwayland.xsurface.restack(null, .above);
}

pub fn setActivated(toplevel: *Toplevel, activated: bool) void {
    const changed = toplevel.activated != activated;
    toplevel.activated = activated;
    if (toplevel.wlr_foreign) |handle| handle.setActivated(activated);
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setActivated(activated),
        .xwayland => |*adapter| {
            if (activated) {
                switch (adapter.xsurface.icccmInputModel()) {
                    .none => {},
                    .passive => adapter.xsurface.activate(true),
                    .local, .global => xwayland_surface.offerFocus(adapter.xsurface),
                }
            } else {
                adapter.xsurface.activate(false);
            }
        },
        .placeholder => {},
        .shell => |*sw| if (sw.control_center) |cc| cc.setActivated(activated),
    }
    if (changed and toplevel.in_world) toplevel.syncChrome(false, nowMs()) catch |err| {
        log.warn("activation: could not repaint title: {}", .{err});
    };
}

/// Publishes state, title, output and parent changes to wlr foreign-toplevel
/// clients; unchanged values send nothing.
pub fn syncForeign(toplevel: *Toplevel) void {
    @import("auto_tiling.zig").observe(toplevel);
    if (toplevel.wlr_foreign) |handle| handle.sync();
}

pub fn sendClose(toplevel: *Toplevel) void {
    switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.sendClose(),
        .xwayland => |*adapter| adapter.xsurface.close(),
        .placeholder => |*ph| ph.cancel(toplevel),
        .shell => |*sw| if (sw.control_center) |cc| cc.close(),
    }
}

/// Bypass the client's close handler, including an unresponsive application.
pub fn forceClose(toplevel: *Toplevel) void {
    switch (toplevel.backend) {
        .xdg => {
            const client = toplevel.waylandClient() orelse return;
            const pid = client.getCredentials().pid;
            if (pid > 1 and pid != std.os.linux.getpid()) std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            client.destroy();
        },
        .xwayland => |*adapter| if (toplevel.server.xwayland) |xwayland| xwayland.forceClose(adapter.xsurface.window_id),
        .placeholder => |*ph| {
            if (ph.pid) |pid| {
                if (pid > 1 and pid != std.os.linux.getpid()) std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            }
            ph.cancel(toplevel);
        },
        .shell => toplevel.sendClose(),
    }
}

pub fn setResizing(toplevel: *Toplevel, resizing: bool) void {
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setResizing(resizing),
        .xwayland, .placeholder, .shell => {},
    }
}

pub fn requestSize(toplevel: *Toplevel, width: i32, height: i32) ConfigureWait {
    return switch (toplevel.backend) {
        .xdg => |*adapter| .{ .xdg_serial = adapter.xdg_toplevel.setSize(width, height) },
        .xwayland => |*adapter| blk: {
            const n = toplevel.surfaceScale();
            adapter.configure(
                xscale.surfacePosition((toplevel.x + toplevel.borderWidth()), n),
                xscale.surfacePosition((toplevel.y + toplevel.titlebarHeight()), n),
                xscale.surfaceLength(width, n),
                xscale.surfaceLength(height, n),
            );
            break :blk .x11_commit;
        },
        .placeholder => |*ph| {
            ph.client_width = width;
            ph.client_height = height;
            toplevel.syncChrome(true, nowMs()) catch {};
            return .none;
        },
        .shell => |*sw| {
            sw.client_width = @max(if (sw.control_center) |cc| cc.minimumWidth() else 1, width);
            sw.client_height = @max(if (sw.control_center) |cc| cc.minimumHeight() else 1, height);
            if (sw.control_center) |cc| cc.resize(sw.client_width, sw.client_height);
            toplevel.positionDuringResize();
            // Shell windows have no client commit to update their shadow.
            toplevel.syncChrome(true, nowMs()) catch {};
            return .none;
        },
    };
}

pub fn configureCompleted(toplevel: *const Toplevel, wait: ConfigureWait) bool {
    return switch (wait) {
        .none => true,
        .x11_commit => false,
        .xdg_serial => |serial| switch (toplevel.backend) {
            .xdg => |*adapter| adapter.xdg_toplevel.base.current.configure_serial >= serial,
            .xwayland, .placeholder, .shell => false,
        },
    };
}

pub fn scheduledSerial(toplevel: *const Toplevel) u32 {
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.scheduled_serial,
        .xwayland, .placeholder, .shell => 0,
    };
}

pub fn ackSerial(toplevel: *const Toplevel) u32 {
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.current.configure_serial,
        .xwayland, .placeholder, .shell => 0,
    };
}

pub fn backendName(toplevel: *const Toplevel) []const u8 {
    return switch (toplevel.backend) {
        .xdg => "xdg",
        .xwayland => "xwayland",
        .placeholder => "placeholder",
        .shell => "shell",
    };
}

pub fn x11Class(toplevel: *const Toplevel) ?[]const u8 {
    return switch (toplevel.backend) {
        .xdg, .placeholder, .shell => null,
        .xwayland => |*adapter| if (adapter.xsurface.class) |c| std.mem.span(c) else null,
    };
}

pub fn x11Instance(toplevel: *const Toplevel) ?[]const u8 {
    return switch (toplevel.backend) {
        .xdg, .placeholder, .shell => null,
        .xwayland => |*adapter| if (adapter.xsurface.instance) |c| std.mem.span(c) else null,
    };
}

/// Resolve the mapped owner live, for both native and X11 transient windows.
pub fn owner(toplevel: *Toplevel) ?*Toplevel {
    return toplevel.parentWindow();
}

pub fn cornerRadius(toplevel: *const Toplevel) f32 {
    return if (toplevel.isMaximized() or toplevel.isFullscreen()) 0 else chrome.frameRadius() * toplevel.chromeDensity();
}

pub fn ownsSurface(toplevel: *const Toplevel, candidate: *wlr.Surface) bool {
    const owned = surface(toplevel) orelse return false;
    if (owned == candidate) return true;
    return candidate.getRootSurface() == owned;
}

fn attachSceneData(toplevel: *Toplevel) void {
    toplevel.frame_data = .{ .role = .{ .toplevel = toplevel } };
    toplevel.chrome_data = .{ .role = .{ .chrome = toplevel } };
    scene_data.SceneData.attach(&toplevel.frame_data, &toplevel.frame_tree.node);
    scene_data.SceneData.attach(&toplevel.chrome_data, &toplevel.shadow_tree.node);
    scene_data.SceneData.attach(&toplevel.chrome_data, &toplevel.shadow_node.node);
    scene_data.SceneData.attach(&toplevel.chrome_data, &toplevel.resize_grab.node);
    scene_data.SceneData.attach(&toplevel.chrome_data, &toplevel.titlebar_buffer.node);
    for (toplevel.frame_fills) |rect| {
        scene_data.SceneData.attach(&toplevel.chrome_data, &rect.node);
    }
    for (toplevel.border_rects) |rect| {
        scene_data.SceneData.attach(&toplevel.chrome_data, &rect.node);
    }
}

pub fn setPosition(toplevel: *Toplevel, x: i32, y: i32) void {
    toplevel.move_x.cancel(@floatFromInt(x));
    toplevel.move_y.cancel(@floatFromInt(y));
    commitPosition(toplevel, x, y, true);
}

/// Move a normal window to the selected output while preserving its offset
/// from the old usable area where possible. Maximized and fullscreen windows
/// are refit directly because their geometry is owned by the target output.
pub fn moveToOutput(toplevel: *Toplevel, output: *Output) bool {
    if (!toplevel.in_world or !output.isAvailable()) return false;
    if (toplevel.server.world.workspaces.active) {
        toplevel.server.world.workspaces.moveTo(toplevel, output.workspace_id);
        return true;
    }
    if (toplevel.isMaximized()) {
        toplevel.setMaximizedOn(output);
        return true;
    }
    if (toplevel.isFullscreen()) {
        toplevel.setFullscreenOn(output);
        return true;
    }
    if (toplevel.tile) |tile| {
        toplevel.setTiledOn(output, tile);
        return true;
    }

    const source = toplevel.currentOutput() orelse output;
    return toplevel.moveFromUsableToOutput(source.usableBox(), output);
}

pub fn moveFromUsableToOutput(toplevel: *Toplevel, source_box: wlr.Box, output: *Output) bool {
    if (!toplevel.in_world or !output.isAvailable()) return false;
    toplevel.finishMoveAnimation();
    const target = output.usableBox();
    if (target.width <= 0 or target.height <= 0) return false;
    const layout_position = toplevel.server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
    const offset_x = @as(i32, @intFromFloat(@round(layout_position.x))) - source_box.x;
    const offset_y = @as(i32, @intFromFloat(@round(layout_position.y))) - source_box.y;
    const frame_w: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.zoom()));
    const frame_h: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.zoom()));
    const max_x = @max(target.x, target.x + target.width - @max(frame_w, 1));
    const max_y = @max(target.y, target.y + target.height - @max(frame_h, 1));
    const target_layout_x = std.math.clamp(target.x + offset_x, target.x, max_x);
    const target_layout_y = std.math.clamp(target.y + offset_y, target.y, max_y);
    const world_position = toplevel.server.world.toWorld(@floatFromInt(target_layout_x), @floatFromInt(target_layout_y));
    toplevel.setPosition(
        @intFromFloat(@round(world_position.x)),
        @intFromFloat(@round(world_position.y)),
    );
    return true;
}

pub fn rememberOutputDisconnect(toplevel: *Toplevel, output_name: []const u8, source_box: wlr.Box) void {
    if (output_name.len == 0 or output_name.len > toplevel.reconnect_output.len) {
        toplevel.reconnect_output_len = 0;
        return;
    }
    const layout_position = toplevel.server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
    std.mem.copyForwards(u8, toplevel.reconnect_output[0..output_name.len], output_name);
    toplevel.reconnect_output_len = output_name.len;
    toplevel.reconnect_expected_x = toplevel.x;
    toplevel.reconnect_expected_y = toplevel.y;
    toplevel.reconnect_offset_x = @as(i32, @intFromFloat(@round(layout_position.x))) - source_box.x;
    toplevel.reconnect_offset_y = @as(i32, @intFromFloat(@round(layout_position.y))) - source_box.y;
    toplevel.reconnect_maximized = toplevel.isMaximized();
    toplevel.reconnect_fullscreen = toplevel.isFullscreen();
    toplevel.reconnect_tile = toplevel.tile;
}

pub fn markOutputDisconnectPosition(toplevel: *Toplevel) void {
    toplevel.reconnect_expected_x = toplevel.x;
    toplevel.reconnect_expected_y = toplevel.y;
}

fn clearOutputDisconnect(toplevel: *Toplevel) void {
    toplevel.reconnect_output_len = 0;
    toplevel.reconnect_maximized = false;
    toplevel.reconnect_fullscreen = false;
    toplevel.reconnect_tile = null;
}

pub fn restoreOutputDisconnect(toplevel: *Toplevel, output: *Output) bool {
    if (toplevel.reconnect_output_len == 0 or
        !std.mem.eql(u8, toplevel.reconnect_output[0..toplevel.reconnect_output_len], std.mem.span(output.wlr_output.name))) return false;
    if (toplevel.x != toplevel.reconnect_expected_x or toplevel.y != toplevel.reconnect_expected_y) {
        clearOutputDisconnect(toplevel);
        return false;
    }
    if (!toplevel.in_world or !output.isAvailable()) return false;
    if (toplevel.reconnect_maximized) {
        toplevel.setMaximizedOn(output);
    } else if (toplevel.reconnect_fullscreen) {
        toplevel.setFullscreenOn(output);
    } else if (toplevel.reconnect_tile) |tile| {
        toplevel.setTiledOn(output, tile);
    } else {
        const target = output.usableBox();
        if (target.width <= 0 or target.height <= 0) return false;
        const frame_w: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.zoom()));
        const frame_h: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.zoom()));
        const max_x = @max(target.x, target.x + target.width - @max(frame_w, 1));
        const max_y = @max(target.y, target.y + target.height - @max(frame_h, 1));
        const target_layout_x = std.math.clamp(target.x + toplevel.reconnect_offset_x, target.x, max_x);
        const target_layout_y = std.math.clamp(target.y + toplevel.reconnect_offset_y, target.y, max_y);
        const world_position = toplevel.server.world.toWorld(@floatFromInt(target_layout_x), @floatFromInt(target_layout_y));
        toplevel.setPosition(@intFromFloat(@round(world_position.x)), @intFromFloat(@round(world_position.y)));
    }
    clearOutputDisconnect(toplevel);
    return true;
}

/// Programmatic moves (maximize/restore, IPC, forced geometry). Direct
/// pointer drags keep using `setPosition` so the frame stays 1:1 with the
/// cursor.
pub fn setPositionAnimated(toplevel: *Toplevel, x: i32, y: i32) void {
    if (!toplevel.in_world or (toplevel.server.input.cursor_mode == .move and toplevel.server.input.grabbed_toplevel == toplevel) or toplevel.isResizing()) {
        toplevel.setPosition(x, y);
        return;
    }
    const now_ms = nowMs();
    const from_x = visualX(toplevel, now_ms);
    const from_y = visualY(toplevel, now_ms);
    if (!toplevel.move_x.active()) {
        toplevel.move_x = .{ .from = @floatFromInt(from_x), .to = @floatFromInt(from_x) };
    }
    if (!toplevel.move_y.active()) {
        toplevel.move_y = .{ .from = @floatFromInt(from_y), .to = @floatFromInt(from_y) };
    }
    const curve = anim.curveFor(.window_move);
    toplevel.move_x.retargetTo(now_ms, @floatFromInt(x), curve);
    toplevel.move_y.retargetTo(now_ms, @floatFromInt(y), curve);
    commitPosition(toplevel, x, y, false);
    toplevel.applyVisualTransform(now_ms);
    if (toplevel.move_x.settled(now_ms) and toplevel.move_y.settled(now_ms)) {
        toplevel.move_x.cancel(@floatFromInt(x));
        toplevel.move_y.cancel(@floatFromInt(y));
        toplevel.applyVisualTransform(now_ms);
    } else {
        toplevel.server.scheduleFrames();
    }
}

fn commitPosition(toplevel: *Toplevel, x: i32, y: i32, update_scene: bool) void {
    const moved = toplevel.x != x or toplevel.y != y;
    toplevel.x = x;
    toplevel.y = y;
    if (update_scene) toplevel.applyVisualTransform(nowMs());
    if (moved) toplevel.server.scheduleFrames();
    toplevel.server.world.ensureToplevelInBounds(toplevel);
    if (moved) {
        if (!toplevel.isResizing() and !toplevel.backend_gone) {
            switch (toplevel.backend) {
                .xwayland => |*adapter| {
                    const geom = toplevel.clientSurfaceGeometry();
                    if (geom.width > 0 and geom.height > 0) {
                        const n = toplevel.surfaceScale();
                        adapter.configure(
                            xscale.surfacePosition((x + toplevel.borderWidth()), n),
                            xscale.surfacePosition((y + toplevel.titlebarHeight()), n),
                            if (toplevel.auto_target != null and !toplevel.maximized and !toplevel.fullscreen) xscale.surfaceLength(toplevel.auto_target.?.width, n) else geom.width,
                            if (toplevel.auto_target != null and !toplevel.maximized and !toplevel.fullscreen) xscale.surfaceLength(toplevel.auto_target.?.height, n) else geom.height,
                        );
                    }
                },
                .xdg, .placeholder, .shell => {},
            }
        }
        toplevel.syncForeign();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowMoved(ipc, toplevel.id, x, y);
        }
        if (toplevel.server.idle) |im| {
            im.recheckInhibitors();
        }
    }
}

pub fn logicalWidth(toplevel: *const Toplevel) i32 {
    if (toplevel.size_w.settle_ms > 0) return @intFromFloat(@round(toplevel.size_w.to));
    return toplevel.chrome_width;
}

pub fn logicalHeight(toplevel: *const Toplevel) i32 {
    if (toplevel.size_h.settle_ms > 0) return @intFromFloat(@round(toplevel.size_h.to));
    return toplevel.chrome_height;
}

fn visualX(toplevel: *const Toplevel, now_ms: i64) i32 {
    if (toplevel.move_x.active()) return @intFromFloat(@round(toplevel.move_x.value(now_ms)));
    return toplevel.x;
}

fn visualY(toplevel: *const Toplevel, now_ms: i64) i32 {
    if (toplevel.move_y.active()) return @intFromFloat(@round(toplevel.move_y.value(now_ms)));
    return toplevel.y;
}

pub fn finishMoveAnimation(toplevel: *Toplevel) void {
    if (!toplevel.move_x.active() and !toplevel.move_y.active()) return;
    const now_ms = nowMs();
    toplevel.setPosition(visualX(toplevel, now_ms), visualY(toplevel, now_ms));
}

pub fn finishSizeAnimation(toplevel: *Toplevel) void {
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) return;
    const geom = toplevel.clientGeometry();
    const size = chromeSizeForClient(toplevel, geom.width, geom.height);
    toplevel.size_w.cancel(@floatFromInt(size.w));
    toplevel.size_h.cancel(@floatFromInt(size.h));
    applySizeClip(toplevel);
}

pub fn requestSizeAnimated(toplevel: *Toplevel, width: i32, height: i32) ConfigureWait {
    const wait = toplevel.requestSize(width, height);
    toplevel.animateChromeSize(width, height, wait);
    return wait;
}

/// Eases the frame toward a client size already requested (`wait`), clipping
/// the client to it while the client catches up.
fn animateChromeSize(toplevel: *Toplevel, width: i32, height: i32, wait: ConfigureWait) void {
    if (!toplevel.in_world or toplevel.isResizing()) return;
    toplevel.size_wait = wait;
    const now_ms = nowMs();
    const target = chromeSizeForClient(toplevel, width, height);
    if (target.w <= 0 or target.h <= 0) return;
    if (!toplevel.size_w.active() and toplevel.size_w.settle_ms == 0) {
        const cur_w: f32 = @floatFromInt(if (toplevel.chrome_width > 0) toplevel.chrome_width else target.w);
        toplevel.size_w = .{ .from = cur_w, .to = cur_w };
    }
    if (!toplevel.size_h.active() and toplevel.size_h.settle_ms == 0) {
        const cur_h: f32 = @floatFromInt(if (toplevel.chrome_height > 0) toplevel.chrome_height else target.h);
        toplevel.size_h = .{ .from = cur_h, .to = cur_h };
    }
    const curve = anim.curveFor(.window_resize);
    toplevel.size_w.retargetTo(now_ms, @floatFromInt(target.w), curve);
    toplevel.size_h.retargetTo(now_ms, @floatFromInt(target.h), curve);
    if (toplevel.size_w.settled(now_ms) and toplevel.size_h.settled(now_ms)) {
        toplevel.size_w.cancel(@floatFromInt(target.w));
        toplevel.size_h.cancel(@floatFromInt(target.h));
    } else {
        toplevel.server.scheduleFrames();
    }
}

fn chromeSizeForClient(toplevel: *const Toplevel, client_w: i32, client_h: i32) struct { w: i32, h: i32 } {
    if (!toplevel.hasServerDecorations()) return .{ .w = client_w, .h = client_h };
    const footer = chrome.frame_border;
    return .{
        .w = client_w + 2 * chrome.frame_border,
        .h = client_h + toplevel.titlebarHeight() + footer,
    };
}

fn ignoreCloseInput(_: *wlr.SceneBuffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

pub fn applyVisualTransform(toplevel: *Toplevel, now_ms: i64) void {
    const zoom_scale = toplevel.worldScale();
    if (toplevel.in_world and !toplevel.closing) {
        toplevel.frame_tree.node.setEnabled(toplevel.switch_leaving or (@import("window_tabs.zig").visible(toplevel) and toplevel.cameraFocusOpacity() > 0));
    }
    // Open keeps tree zoom at the logical window zoom so scene picking and
    // client-local coordinates stay 1:1 with the mapped frame (existing
    // tests and the "input keys off the logical map" rule). Close may scale
    // because the frame no longer accepts input.
    const factor: f64 = if (toplevel.closing)
        anim.windowMapScale(toplevel.map_motion.value(now_ms))
    else
        1.0;
    _ = @import("projection.zig").setTreeZoom(&toplevel.frame_tree.node, zoom_scale * factor);
    toplevel.frame_tree.node.setPosition(
        visualX(toplevel, now_ms) + animOffset(toplevel.dodge_x, now_ms) + animOffset(toplevel.switch_x, now_ms),
        visualY(toplevel, now_ms) + animOffset(toplevel.dodge_y, now_ms) + animOffset(toplevel.switch_y, now_ms),
    );
}

fn animOffset(a: anim.Anim, now_ms: i64) i32 {
    if (!a.active()) return 0;
    return @intFromFloat(@round(a.value(now_ms)));
}

/// Slides the frame `dx`/`dy` world units from where it is, or back with 0/0.
/// The offset is presentation only, so the window's real position, size and
/// input state are untouched; every path that ends the reason for it must call
/// this with zeros (or `clearDodge`).
pub fn setDodge(toplevel: *Toplevel, dx: f32, dy: f32) void {
    if (!toplevel.in_world) return;
    const now_ms = nowMs();
    const curve = anim.curveFor(.window_move);
    if (!toplevel.dodge_x.active()) toplevel.dodge_x = .{};
    if (!toplevel.dodge_y.active()) toplevel.dodge_y = .{};
    toplevel.dodge_x.retargetTo(now_ms, dx, curve);
    toplevel.dodge_y.retargetTo(now_ms, dy, curve);
    toplevel.applyVisualTransform(now_ms);
    toplevel.server.scheduleFrames();
}

/// Drops any displacement at once, for a window that stops being shown.
pub fn clearDodge(toplevel: *Toplevel) void {
    if (!toplevel.dodge_x.active() and !toplevel.dodge_y.active()) return;
    toplevel.dodge_x.cancel(0);
    toplevel.dodge_y.cancel(0);
    if (toplevel.in_world) toplevel.applyVisualTransform(nowMs());
}

pub fn tickDodge(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.dodge_x.active() and !toplevel.dodge_y.active()) return false;
    _ = toplevel.dodge_x.sampleChanged(now_ms, anim.quantum_px);
    _ = toplevel.dodge_y.sampleChanged(now_ms, anim.quantum_px);
    if (toplevel.dodge_x.settled(now_ms) and toplevel.dodge_y.settled(now_ms)) {
        // Back at rest: forget the animation so the window is not ticked forever.
        if (toplevel.dodge_x.to == 0 and toplevel.dodge_y.to == 0) {
            toplevel.dodge_x.cancel(0);
            toplevel.dodge_y.cancel(0);
        }
        return false;
    }
    return true;
}

/// Brings the window in with its workspace: from (`from_x`, `from_y`) world
/// units away, faded out with `fade`, or from where it is when it was leaving.
pub fn switchIn(toplevel: *Toplevel, from_x: f32, from_y: f32, fade: bool) void {
    if (!toplevel.switch_leaving) {
        toplevel.switch_x = .{ .from = from_x, .to = from_x };
        toplevel.switch_y = .{ .from = from_y, .to = from_y };
        const start: f32 = if (fade) 0 else 1;
        toplevel.switch_fade = .{ .from = start, .to = start, .property = .opacity };
    }
    toplevel.setSwitchLeaving(false);
    toplevel.retargetSwitch(0, 0, 1);
}

/// Takes the window out with the workspace it is on, which is already hidden:
/// it stays shown, inert, until it reaches (`to_x`, `to_y`) or has faded.
pub fn switchOut(toplevel: *Toplevel, to_x: f32, to_y: f32, fade: bool) void {
    toplevel.setSwitchLeaving(true);
    toplevel.retargetSwitch(to_x, to_y, if (fade) 0 else 1);
}

fn retargetSwitch(toplevel: *Toplevel, x: f32, y: f32, opacity: f32) void {
    const now_ms = nowMs();
    const curve = anim.curveFor(.camera_desktop);
    toplevel.switch_x.retargetTo(now_ms, x, curve);
    toplevel.switch_y.retargetTo(now_ms, y, curve);
    toplevel.switch_fade.retargetTo(now_ms, opacity, curve);
    if (!toplevel.tickSwitch(now_ms)) return;
    toplevel.applyVisualTransform(now_ms);
    toplevel.applyOpacity(now_ms);
    toplevel.server.scheduleFrames();
}

fn setSwitchLeaving(toplevel: *Toplevel, leaving: bool) void {
    if (toplevel.switch_leaving == leaving) return;
    toplevel.switch_leaving = leaving;
    _ = projection.setTreeInert(&toplevel.frame_tree.node, leaving);
}

/// Ends a workspace switch at once; a window that was leaving is hidden.
pub fn finishSwitch(toplevel: *Toplevel) void {
    if (!toplevel.switch_x.active() and !toplevel.switch_y.active() and !toplevel.switch_fade.active() and !toplevel.switch_leaving) return;
    toplevel.switch_x.cancel(0);
    toplevel.switch_y.cancel(0);
    toplevel.switch_fade.cancel(1);
    toplevel.setSwitchLeaving(false);
    if (!toplevel.in_world) return;
    const now_ms = nowMs();
    toplevel.applyVisualTransform(now_ms);
    toplevel.applyOpacity(now_ms);
}

pub fn tickSwitch(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.switch_x.active() and !toplevel.switch_y.active() and !toplevel.switch_fade.active() and !toplevel.switch_leaving) return false;
    _ = toplevel.switch_x.sampleChanged(now_ms, anim.quantum_px);
    _ = toplevel.switch_y.sampleChanged(now_ms, anim.quantum_px);
    _ = toplevel.switch_fade.sampleChanged(now_ms, anim.quantum_alpha);
    if (toplevel.switch_x.settled(now_ms) and toplevel.switch_y.settled(now_ms) and toplevel.switch_fade.settled(now_ms)) {
        toplevel.finishSwitch();
        return false;
    }
    return true;
}

pub fn tickMove(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.move_x.active() and !toplevel.move_y.active()) return false;
    _ = toplevel.move_x.sampleChanged(now_ms, anim.quantum_px);
    _ = toplevel.move_y.sampleChanged(now_ms, anim.quantum_px);
    if (toplevel.move_x.settled(now_ms) and toplevel.move_y.settled(now_ms)) {
        toplevel.move_x.cancel(@floatFromInt(toplevel.x));
        toplevel.move_y.cancel(@floatFromInt(toplevel.y));
        return false;
    }
    return true;
}

pub fn tickSize(toplevel: *Toplevel, now_ms: i64) bool {
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) return false;
    const moving = !toplevel.size_w.settled(now_ms) or !toplevel.size_h.settled(now_ms);
    const quantum = anim.rasterPixelQuantum(toplevel.render_scale);
    const w_changed = toplevel.size_w.sampleChanged(now_ms, quantum);
    const h_changed = toplevel.size_h.sampleChanged(now_ms, quantum);
    // At rest the frame may give way to the size the client took.
    if (w_changed or h_changed or !moving) {
        toplevel.syncChrome(true, now_ms) catch |err| {
            log.err("tickSize: could not update window decoration: {}", .{err});
        };
    }
    return moving;
}

pub fn tickMap(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.map_motion.active() and !toplevel.map_opacity.active()) return false;
    _ = toplevel.map_motion.sampleChanged(now_ms, 0.001);
    _ = toplevel.map_opacity.sampleChanged(now_ms, anim.quantum_alpha);
    if (toplevel.map_motion.settled(now_ms) and toplevel.map_opacity.settled(now_ms)) {
        if (toplevel.closing) return false;
        toplevel.map_motion.cancel(1);
        toplevel.map_opacity.cancel(1);
        return false;
    }
    return true;
}

pub fn closingFinished(toplevel: *const Toplevel, now_ms: i64) bool {
    return toplevel.closing and toplevel.map_motion.settled(now_ms) and toplevel.map_opacity.settled(now_ms);
}

/// Ends a finished close animation. Only a destroyed backend frees the
/// window: one that merely unmapped (a withdrawn X11 window, an app hiding to
/// its tray) still has listeners on its surface and may map again.
pub fn finishClose(toplevel: *Toplevel) void {
    if (toplevel.backend_gone) return toplevel.destroyNow();
    if (toplevel.close_snapshot) |snap| {
        snap.node.destroy();
        toplevel.close_snapshot = null;
    }
    if (toplevel.in_closing_list) {
        toplevel.closing_link.remove();
        toplevel.in_closing_list = false;
    }
    toplevel.closing = false;
    toplevel.clearChromeCache();
    toplevel.frame_tree.node.setEnabled(false);
    toplevel.scene_tree.node.setEnabled(true);
}

/// Idempotent: re-applying the clip a window already has is a no-op, so the
/// per-commit call from `syncChrome` costs nothing once the size settles.
fn setSizeClip(toplevel: *Toplevel, clip: ?wlr.Box) void {
    if (toplevel.backend == .placeholder or toplevel.backend == .shell) return;
    if (toplevel.last_clip_valid) {
        const same = if (clip) |box|
            if (toplevel.last_clip) |prev| std.meta.eql(prev, box) else false
        else
            toplevel.last_clip == null;
        if (same) return;
    }
    toplevel.last_clip = clip;
    toplevel.last_clip_valid = true;
    if (clip) |box| {
        var copy = box;
        wlr.SceneNode.subsurfaceTreeSetClip(&toplevel.scene_tree.node, &copy);
    } else {
        wlr.SceneNode.subsurfaceTreeSetClip(&toplevel.scene_tree.node, null);
    }
}

fn applySizeClip(toplevel: *Toplevel) void {
    if (toplevel.backend_gone or toplevel.closing) return;
    if (toplevel.backend == .placeholder or toplevel.backend == .shell) return;
    // An Xwayland surface can fire property changes (e.g. WM_CLASS, routed
    // here through handleIdentityChanged -> syncChrome) before its X11
    // window is associated with a wl_surface and attachXwaylandScene has run.
    // scene_tree is then still the bare placeholder tree from createXwayland,
    // with none of the subsurface-tree bookkeeping wlr_scene_subsurface_tree_set_clip
    // requires — calling it anyway aborts the whole compositor.
    if (!toplevel.isInitialized()) return;
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) {
        toplevel.setSizeClip(null);
        return;
    }
    const decorated = toplevel.hasServerDecorations();
    const cw = if (decorated) @max(toplevel.chrome_width - 2 * chrome.frame_border, 0) else toplevel.chrome_width;
    const ch = if (decorated)
        @max(toplevel.chrome_height - toplevel.titlebarHeight() - chrome.frame_border, 0)
    else
        toplevel.chrome_height;
    const n = toplevel.surfaceScale();
    toplevel.setSizeClip(.{ .x = 0, .y = 0, .width = xscale.surfaceLength(cw, n), .height = xscale.surfaceLength(ch, n) });
}

fn beginOpenAnimation(toplevel: *Toplevel) void {
    const now_ms = nowMs();
    if (toplevel.isMaximized() or toplevel.isFullscreen()) {
        toplevel.map_motion.cancel(1);
        toplevel.map_opacity.cancel(1);
        toplevel.applyVisualTransform(now_ms);
        toplevel.applyOpacity(now_ms);
        return;
    }
    toplevel.map_motion.cancel(0);
    toplevel.map_opacity.cancel(0);
    toplevel.map_motion.retargetTo(now_ms, 1, anim.curveFor(.window_open));
    toplevel.map_opacity.retargetTo(now_ms, 1, anim.curveFor(.window_open));
    toplevel.applyVisualTransform(now_ms);
    toplevel.applyOpacity(now_ms);
    if (!toplevel.map_motion.settled(now_ms) or !toplevel.map_opacity.settled(now_ms)) {
        toplevel.server.scheduleFrames();
    }
}

fn beginCloseAnimation(toplevel: *Toplevel) bool {
    if (!anim.enabled() or anim.speed() <= 0) return false;
    if (!snapshotClient(toplevel)) return false;
    const now_ms = nowMs();
    toplevel.map_motion.retargetTo(now_ms, 0, anim.curveFor(.window_close));
    toplevel.map_opacity.retargetTo(now_ms, 0, anim.curveFor(.window_close));
    if (toplevel.map_motion.settled(now_ms) and toplevel.map_opacity.settled(now_ms)) {
        if (toplevel.close_snapshot) |snap| {
            snap.node.destroy();
            toplevel.close_snapshot = null;
        }
        toplevel.scene_tree.node.setEnabled(true);
        return false;
    }
    toplevel.closing = true;
    toplevel.server.world.closing.append(toplevel);
    toplevel.in_closing_list = true;
    toplevel.applyVisualTransform(now_ms);
    toplevel.applyOpacity(now_ms);
    toplevel.server.scheduleFrames();
    return true;
}

const CloseSnapshot = struct {
    tree: *wlr.SceneTree,
    count: u32 = 0,
    ok: bool = true,
};

fn copyCloseBuffer(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, ctx: *CloseSnapshot) void {
    const src = buffer.buffer orelse return;
    const dest = ctx.tree.createSceneBuffer(src) catch {
        ctx.ok = false;
        return;
    };
    dest.node.setPosition(sx, sy);
    dest.point_accepts_input = ignoreCloseInput;
    if (buffer.dst_width > 0 and buffer.dst_height > 0) {
        dest.setDestSize(buffer.dst_width, buffer.dst_height);
    }
    if (buffer.src_box.width > 0 and buffer.src_box.height > 0) {
        dest.setSourceBox(&buffer.src_box);
    }
    dest.setTransform(buffer.transform);
    dest.setOpacity(buffer.opacity);
    dest.setFilterMode(buffer.filter_mode);
    ctx.count += 1;
}

fn snapshotClient(toplevel: *Toplevel) bool {
    const snap = toplevel.content_tree.createSceneTree() catch return false;
    var ctx: CloseSnapshot = .{ .tree = snap };
    toplevel.scene_tree.node.forEachBuffer(*CloseSnapshot, copyCloseBuffer, &ctx);
    if (!ctx.ok or ctx.count == 0) {
        snap.node.destroy();
        return false;
    }
    toplevel.scene_tree.node.setEnabled(false);
    toplevel.close_snapshot = snap;
    return true;
}

fn cancelClose(toplevel: *Toplevel) void {
    if (toplevel.close_snapshot) |snap| {
        snap.node.destroy();
        toplevel.close_snapshot = null;
    }
    if (toplevel.in_closing_list) {
        toplevel.closing_link.remove();
        toplevel.in_closing_list = false;
    }
    toplevel.closing = false;
    toplevel.map_motion.cancel(1);
    toplevel.map_opacity.cancel(1);
    toplevel.scene_tree.node.setEnabled(true);
}

/// Only committed negotiation may change the frame, so the client and
/// compositor switch decorations with the same surface update. A fullscreen
/// window never draws our titlebar/border/footer regardless of the
/// negotiated mode — same as every other compositor, the whole point of
/// fullscreen is an edge-to-edge client surface with no window-manager
/// chrome eating into it.
pub fn hasServerDecorations(toplevel: *const Toplevel) bool {
    if (toplevel.backend_gone) return false;
    if (toplevel.isFullscreen()) return false;
    return switch (toplevel.backend) {
        .xdg => blk: {
            // KDE defines using both protocols as undefined; prefer XDG
            // and its configure/ack synchronization when available.
            if (toplevel.decoration) |decoration| {
                break :blk decoration.decoration.current.mode == .server_side;
            }
            break :blk if (toplevel.kde_decoration) |decoration| decoration.current == .server else false;
        },
        .xwayland => |*adapter| adapter.serverDecorations(),
        .placeholder, .shell => true,
    };
}

pub fn chromeDensity(toplevel: *const Toplevel) f32 {
    return switch (toplevel.backend) {
        .xwayland => 0.75,
        else => 1,
    };
}

pub fn titlebarHeight(toplevel: *const Toplevel) i32 {
    return if (toplevel.hasServerDecorations()) (chrome.Metrics{ .density = toplevel.chromeDensity() }).titlebarHeight() else 0;
}

pub fn borderWidth(toplevel: *const Toplevel) i32 {
    return if (toplevel.hasServerDecorations()) chrome.frame_border else 0;
}

fn hasWorkspaceFocusBorder(toplevel: *const Toplevel) bool {
    return toplevel.server.world.workspaces.active and toplevel.activated and !toplevel.isFullscreen();
}

fn borderColor(toplevel: *const Toplevel) col.Premul {
    return chrome.windowBorderColor(toplevel.last_painted_hover, toplevel.hasWorkspaceFocusBorder());
}

pub fn footerHeight(toplevel: *const Toplevel) i32 {
    if (!toplevel.hasServerDecorations()) return 0;
    return chrome.frame_border;
}

pub fn frameLocal(toplevel: *const Toplevel, lx: f64, ly: f64) geometry.Vec2 {
    const point = toplevel.server.world.toWorld(lx, ly);
    const local = geometry.toLocal(point.x, point.y, toplevel.x, toplevel.y);
    return .{ .x = local.x / toplevel.worldScale(), .y = local.y / toplevel.worldScale() };
}

pub fn frameWorld(toplevel: *const Toplevel, x: f64, y: f64) geometry.Vec2 {
    return .{
        .x = @as(f64, @floatFromInt(toplevel.x)) + x * toplevel.worldScale(),
        .y = @as(f64, @floatFromInt(toplevel.y)) + y * toplevel.worldScale(),
    };
}

/// On-screen logical scale, combining window and camera zoom (before output DPI).
pub fn zoom(toplevel: *const Toplevel) f64 {
    return toplevel.worldScale() * toplevel.server.world.camera.zoom();
}

/// Client units to presented world units, including the temporary focus boost.
/// The saved frame position, client size and zoom_index remain unchanged.
pub fn worldScale(toplevel: *const Toplevel) f64 {
    if (toplevel.server.world.workspaces.active) return 1;
    return @import("camera.zig").boostedScale(toplevel.zoom_scale, toplevel.server.world.camera.zoom(), toplevel.zoom_boost_value);
}

pub fn setZoomBoost(toplevel: *Toplevel, enabled: bool) void {
    const target: f32 = if (enabled and toplevel.layout() == .floating and !toplevel.isFullscreen()) 1 else 0;
    if (toplevel.zoom_boost.to == target) return;
    const now = nowMs();
    toplevel.zoom_boost.retargetTo(now, target, anim.curveFor(.window_zoom));
    _ = toplevel.tickZoomBoost(now);
    toplevel.server.scheduleFrames();
}

pub fn tickZoomBoost(toplevel: *Toplevel, now: i64) bool {
    const live = toplevel.zoom_boost.active();
    const settled = toplevel.zoom_boost.settled(now);
    toplevel.zoom_boost_value = if (settled) toplevel.zoom_boost.to else toplevel.zoom_boost.value(now);
    if (settled) {
        toplevel.zoom_boost.cancel(@floatCast(toplevel.zoom_boost_value));
        if (live) {
            toplevel.syncForeign();
            toplevel.server.input.processCursorMotion(0);
        }
    }
    return !settled;
}

fn clearZoomBoost(toplevel: *Toplevel) void {
    toplevel.zoom_boost.cancel(0);
    toplevel.zoom_boost_value = 0;
}

/// Explicit window zoom takes over from the temporary boost without a jump.
fn takeZoomBoost(toplevel: *Toplevel) void {
    if (toplevel.zoom_boost_value == 0 and toplevel.zoom_boost.to == 0) return;
    toplevel.zoom_scale = toplevel.worldScale();
    toplevel.zoom_anim.cancel(@floatCast(toplevel.zoom_scale));
    toplevel.clearZoomBoost();
}

fn cameraFocusOpacity(toplevel: *const Toplevel) f32 {
    if (toplevel.server.world.workspaces.active) return 1;
    if (toplevel.server.config.compositor.focus_zoom != .camera or toplevel.layout() != .floating or toplevel.isFullscreen()) return 1;
    // Windows passed by the camera fade away, and stop accepting input once
    // invisible. Reversing the zoom reveals the same retained scene again.
    return @floatCast(std.math.clamp((1.05 - toplevel.zoom()) / 0.05, 0, 1));
}

pub fn finishZoomAnimation(toplevel: *Toplevel) void {
    if (!toplevel.zoom_anim.active()) return;
    const target_scale = @as(f64, @floatFromInt(@import("camera.zig").zoom_levels[toplevel.zoom_index])) / 100;
    toplevel.zoom_scale = target_scale;
    toplevel.zoom_anim = .{ .from = @floatCast(target_scale), .to = @floatCast(target_scale) };
    const target_ws = target_scale;
    const target_x = toplevel.zoom_anchor.x - toplevel.zoom_local.x * target_ws;
    const target_y = toplevel.zoom_anchor.y - toplevel.zoom_local.y * target_ws;
    toplevel.setPosition(@intFromFloat(@round(target_x)), @intFromFloat(@round(target_y)));
    toplevel.syncChrome(false, nowMs()) catch {};
}

pub fn tickZoom(toplevel: *Toplevel, now_ms: i64) bool {
    if (!toplevel.zoom_anim.active()) return false;
    _ = toplevel.zoom_anim.sampleChanged(now_ms, 0.001);
    const settled = toplevel.zoom_anim.settled(now_ms);
    const target_scale = @as(f64, @floatFromInt(@import("camera.zig").zoom_levels[toplevel.zoom_index])) / 100;
    const current_scale: f64 = if (settled)
        target_scale
    else
        @as(f64, toplevel.zoom_anim.value(now_ms));

    toplevel.zoom_scale = current_scale;

    const current_ws = current_scale;
    const nx = toplevel.zoom_anchor.x - toplevel.zoom_local.x * current_ws;
    const ny = toplevel.zoom_anchor.y - toplevel.zoom_local.y * current_ws;

    if (settled) {
        toplevel.zoom_anim = .{ .from = @floatCast(target_scale), .to = @floatCast(target_scale) };
        toplevel.setPosition(@intFromFloat(@round(nx)), @intFromFloat(@round(ny)));
        toplevel.syncChrome(false, now_ms) catch {};
        toplevel.server.input.processCursorMotion(0);
        return false;
    } else {
        const round_x: i32 = @intFromFloat(@round(nx));
        const round_y: i32 = @intFromFloat(@round(ny));
        const moved = toplevel.x != round_x or toplevel.y != round_y;
        toplevel.x = round_x;
        toplevel.y = round_y;
        if (moved) toplevel.server.world.ensureToplevelInBounds(toplevel);
        return true;
    }
}

pub fn setZoom(toplevel: *Toplevel, index: usize, lx: f64, ly: f64) void {
    if (toplevel.server.world.workspaces.active) return;
    toplevel.takeZoomBoost();
    const next = @min(index, @import("camera.zig").zoom_levels.len - 1);
    if (next == toplevel.zoom_index and toplevel.zoom_scale == @as(f64, @floatFromInt(@import("camera.zig").zoom_levels[next])) / 100) return;

    // Record for undo before modifying state.
    {
        const geom = toplevel.clientGeometry();
        const now_ms = @import("Server.zig").undoNowMs();
        toplevel.server.undo.record(.{
            .kind = .window_zoom,
            .press_seq = toplevel.server.undo.press_seq,
            .at_ms = now_ms,
            .window = .{ .id = toplevel.id, .x = toplevel.x, .y = toplevel.y, .width = geom.width, .height = geom.height, .zoom_index = toplevel.zoom_index },
        }, now_ms);
    }
    const local = toplevel.frameLocal(lx, ly);
    const anchor = toplevel.server.world.toWorld(lx, ly);
    const scale = @as(f64, @floatFromInt(@import("camera.zig").zoom_levels[next])) / 100;
    if (!@import("projection.zig").setTreeZoom(&toplevel.frame_tree.node, scale)) {
        log.err("cannot allocate window zoom", .{});
        return;
    }
    toplevel.zoom_index = next;
    toplevel.zoom_scale = scale;
    toplevel.zoom_anim = .{ .from = @floatCast(scale), .to = @floatCast(scale) };
    // Keep the point under the pointer fixed, without resizing the client.
    toplevel.setPosition(@intFromFloat(@round(anchor.x - local.x * toplevel.worldScale())), @intFromFloat(@round(anchor.y - local.y * toplevel.worldScale())));
    toplevel.server.world.syncPresentation();
    toplevel.server.scheduleFrames();
    toplevel.server.input.processCursorMotion(0);
}

pub fn setZoomAnimated(toplevel: *Toplevel, index: usize, lx: f64, ly: f64) void {
    if (toplevel.server.world.workspaces.active) return;
    toplevel.takeZoomBoost();
    const next = @min(index, @import("camera.zig").zoom_levels.len - 1);
    const target_scale = @as(f64, @floatFromInt(@import("camera.zig").zoom_levels[next])) / 100;

    if (next == toplevel.zoom_index and toplevel.zoom_scale == target_scale and !toplevel.zoom_anim.active()) return;

    // Record for undo before modifying state.
    {
        const geom = toplevel.clientGeometry();
        const undo_ms = @import("Server.zig").undoNowMs();
        toplevel.server.undo.record(.{
            .kind = .window_zoom,
            .press_seq = toplevel.server.undo.press_seq,
            .at_ms = undo_ms,
            .window = .{ .id = toplevel.id, .x = toplevel.x, .y = toplevel.y, .width = geom.width, .height = geom.height, .zoom_index = toplevel.zoom_index },
        }, undo_ms);
    }

    toplevel.finishMoveAnimation();

    const local = toplevel.frameLocal(lx, ly);
    const anchor = toplevel.server.world.toWorld(lx, ly);

    _ = @import("projection.zig").setTreeZoom(&toplevel.frame_tree.node, toplevel.zoom_scale);

    toplevel.zoom_index = next;
    toplevel.zoom_anchor = .{ .x = anchor.x, .y = anchor.y };
    toplevel.zoom_local = .{ .x = local.x, .y = local.y };

    if (!toplevel.zoom_anim.active()) {
        toplevel.zoom_anim.from = @floatCast(toplevel.zoom_scale);
        toplevel.zoom_anim.to = @floatCast(toplevel.zoom_scale);
    }

    const now_ms = nowMs();
    toplevel.zoom_anim.retargetTo(now_ms, @floatCast(target_scale), anim.curveFor(.window_zoom));

    toplevel.server.scheduleFrames();
    toplevel.server.input.processCursorMotion(0);
}

// Shell windows have no surface commit, so apply the fixed-edge position as
// soon as their size changes too.
fn positionDuringResize(toplevel: *Toplevel) void {
    const session = toplevel.server.input.resize_session orelse return;
    if (session.toplevel != toplevel) return;
    const geom = toplevel.clientGeometry();
    if (geom.width > 0 and geom.height > 0) {
        const pos = resize.computeFramePosition(session.snapshot, geom.width, geom.height);
        const initial_x = session.snapshot.initial_frame_x;
        const initial_y = session.snapshot.initial_frame_y;
        // The fixed opposite edge is in displayed world coordinates.
        const dx: f64 = @floatFromInt(pos.x - initial_x);
        const dy: f64 = @floatFromInt(pos.y - initial_y);
        toplevel.setPosition(
            initial_x + @as(i32, @intFromFloat(@round(dx * toplevel.worldScale()))),
            initial_y + @as(i32, @intFromFloat(@round(dy * toplevel.worldScale()))),
        );
    }
}

pub fn handleSurfaceCommit(toplevel: *Toplevel) void {
    if (toplevel.server.config.compositor.allow_tearing) {
        if (toplevel.currentOutput()) |output| output.queueTearing();
    }
    toplevel.server.switcher.committed(toplevel);
    if (toplevel.kde_decoration) |decoration| decoration.commit();
    if (toplevel.decoration) |decoration| decoration.applyMode();

    if (toplevel.size_wait == .x11_commit or toplevel.configureCompleted(toplevel.size_wait)) toplevel.size_wait = .none;
    if (toplevel.server.input.resize_session) |*session| {
        if (session.toplevel == toplevel) {
            if (session.outstanding_configure == .x11_commit) {
                session.outstanding_configure = .none;
            } else if (session.outstanding_configure != .none) {
                if (toplevel.configureCompleted(session.outstanding_configure)) {
                    session.outstanding_configure = .none;
                }
            }

            toplevel.positionDuringResize();

            // A queued pre-release commit must not discard the fixed-edge
            // snapshot before the client acknowledges the final resize size.
            if (session.settling and session.outstanding_configure == .none) {
                const gen = session.generation;
                toplevel.server.input.finishSettlement(gen);
            }
        }
    }

    toplevel.syncChrome(true, nowMs()) catch |err| {
        log.err("handleCommit: could not update window decoration: {}", .{err});
    };
    if (toplevel.in_world) if (toplevel.server.layout_autosave) |autosave| {
        autosave.mapped(toplevel);
        autosave.finishMapped(toplevel);
    };
    @import("auto_tiling.zig").observe(toplevel);
    toplevel.server.window_tabs.reconcile(toplevel);
    if (toplevel.tab_hidden) {
        if (@import("window_tabs.zig").active(toplevel.server, toplevel.tab_group)) |active_tab| active_tab.syncChrome(false, nowMs()) catch {};
    }
    if (toplevel.isMapped()) {
        toplevel.syncForeign();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowChanged(ipc, toplevel);
            ipc.wait_mgr.checkAll();
        }
    }
}

pub fn handleMapped(toplevel: *Toplevel) void {
    toplevel.server.holdTaskbars();
    defer toplevel.server.releaseTaskbars();
    if (toplevel.closing) toplevel.cancelClose();
    toplevel.minimized = false;
    toplevel.needs_attention = false;
    toplevel.syncChrome(true, nowMs()) catch |err| {
        log.err("handleMap: could not update window decoration: {}", .{err});
    };

    toplevel.resolveInitialRules();
    if (toplevel.open_rules.focus orelse true) toplevel.server.window_tabs.focusMember(toplevel);
    if (toplevel.backend != .placeholder and toplevel.backend != .shell) toplevel.server.launch_feedback.windowMapped(toplevel);

    if (toplevel.open_rules.depth) |d| {
        toplevel.setZoomOrigin(d);
    }

    const maybe_ph = toplevel.placeholder_source orelse toplevel.findMatchingPlaceholder();
    var inherited_placeholder: ?*Toplevel = null;
    var ph_token: ?[]const u8 = null;
    var ph_pid: ?i32 = null;
    var ph_desktop_id: []const u8 = "";
    var ph_had_focus = false;

    if (maybe_ph) |ph_top| {
        if (ph_top.in_world and ph_top.backend == .placeholder and !ph_top.backend.placeholder.cancelled) {
            inherited_placeholder = ph_top;
            toplevel.workspace_id = ph_top.workspace_id;
            toplevel.workspace_order = ph_top.workspace_order;
            toplevel.workspace_generation = ph_top.workspace_generation;
            toplevel.canvas_state = ph_top.canvas_state;
            toplevel.auto_float = ph_top.auto_float;
            toplevel.auto_restore = ph_top.auto_restore;
            toplevel.auto_reinsert = ph_top.auto_reinsert;
            toplevel.auto_anchor = ph_top.auto_anchor;
            const ph = &ph_top.backend.placeholder;
            ph.matched = true;
            ph_token = ph.token;
            ph_pid = ph.pid;
            ph_desktop_id = ph.desktop_id;
            ph_had_focus = (toplevel.server.world.toplevels.first() == ph_top);

            const is_dialog = toplevel.parentWindow() != null;
            const client_geom = toplevel.clientGeometry();
            const is_far_smaller = (client_geom.width > 0 and client_geom.width < @divTrunc(ph.client_width, 2) and
                client_geom.height > 0 and client_geom.height < @divTrunc(ph.client_height, 2));

            if (!is_dialog and !is_far_smaller) {
                if (!toplevel.placed) {
                    toplevel.setPosition(ph_top.x, ph_top.y);
                    toplevel.placed = true;
                }
                if (ph_top.isMaximized()) {
                    toplevel.maximized = true;
                }
            }
        }
    }

    const target_out = toplevel.resolveTargetOutput();

    // Initial client requests already configure the protocol state, but must
    // also apply the corresponding geometry when the window maps. In
    // particular, don't cascade a maximized window like a floating one.
    if (toplevel.open_rules.fullscreen orelse toplevel.isFullscreen()) {
        if (target_out) |out| toplevel.setFullscreenOn(out);
        toplevel.placed = true;
    } else if (toplevel.open_rules.maximized orelse toplevel.isMaximized()) {
        if (target_out) |out| toplevel.setMaximizedOn(out);
        toplevel.placed = true;
    } else if (!toplevel.placed) {
        if (target_out) |output| {
            const frame_w = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.zoom())));
            const frame_h = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.zoom())));
            const geom = pickInitialPlacement(toplevel.server, output, toplevel.open_rules, toplevel.parentWindow(), frame_w, frame_h);
            toplevel.setPosition(geom.x, geom.y);
            toplevel.placed = true;
        }
    }

    toplevel.server.world.workspaces.mapped(toplevel);
    const want_focus = (if (inherited_placeholder != null) ph_had_focus else (toplevel.open_rules.focus orelse true)) and @import("workspaces.zig").visible(toplevel);
    if (want_focus) {
        toplevel.needs_attention = false;
        toplevel.server.world.toplevels.prepend(toplevel);
        toplevel.in_world = true;
        toplevel.server.world.workspaces.mapped(toplevel);
        const undo_applying = toplevel.server.undo.applying;
        if (inherited_placeholder != null and toplevel.server.world.workspaces.active) toplevel.server.undo.applying = true;
        defer toplevel.server.undo.applying = undo_applying;
        toplevel.server.world.focus(toplevel);
    } else {
        toplevel.needs_attention = true;
        if (toplevel.server.world.toplevels.first()) |current_focused| {
            current_focused.link.insert(&toplevel.link);
            toplevel.frame_tree.node.placeBelow(&current_focused.frame_tree.node);
            toplevel.syncXwaylandStack();
        } else {
            toplevel.server.world.toplevels.prepend(toplevel);
        }
        toplevel.in_world = true;
        toplevel.server.world.workspaces.mapped(toplevel);
        toplevel.setActivated(false);
        @import("config_runtime/apply.zig").applyWindowOpacity(toplevel.server);
        toplevel.server.refreshTaskbars();
    }
    if (toplevel.backend == .xdg) {
        if (toplevel.server.capture_mgr) |cm| {
            toplevel.foreign_handle = wlr.ExtForeignToplevelHandleV1.create(cm.toplevel_list, &.{
                .title = toplevel.backend.xdg.xdg_toplevel.title,
                .app_id = toplevel.backend.xdg.xdg_toplevel.app_id,
            }) catch |err| blk: {
                log.warn("handleMapped: could not publish foreign-toplevel handle: {}", .{err});
                break :blk null;
            };
        }
    }

    if (toplevel.backend != .placeholder and toplevel.wlr_foreign == null) {
        if (toplevel.server.foreign_toplevels) |manager| {
            toplevel.wlr_foreign = @import("foreign_toplevel.zig").Handle.create(manager, toplevel) catch |err| blk: {
                log.warn("handleMapped: could not publish wlr foreign-toplevel handle: {}", .{err});
                break :blk null;
            };
        }
    }

    if (inherited_placeholder) |ph_top| {
        @import("layout_undo.zig").replaced(toplevel.server, ph_top.id, toplevel.id);
        if (toplevel.server.ipc) |ipc| {
            events.onLaunchMatched(ipc, ph_desktop_id, toplevel.id, ph_pid);
        }
        ph_top.destroyNow();
    }

    if (toplevel.server.ipc) |ipc| {
        events.onWindowOpened(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
    if (toplevel.server.idle) |im| {
        im.recheckInhibitors();
    }

    if (inherited_placeholder != null) {
        const now_ms = nowMs();
        toplevel.map_motion.cancel(1);
        toplevel.map_opacity.cancel(0);
        toplevel.map_opacity.retargetTo(now_ms, 1, anim.Curve{
            .duration = .{ .ms = 80, .ease = .out_cubic },
        });
        toplevel.applyVisualTransform(now_ms);
        toplevel.applyOpacity(now_ms);
        toplevel.server.scheduleFrames();
    } else {
        toplevel.beginOpenAnimation();
    }
    toplevel.server.window_tabs.mapped(toplevel);
    toplevel.server.window_tabs.mappedToken(toplevel);
    if (toplevel.server.layout_autosave) |autosave| autosave.finishMapped(toplevel);
    toplevel.syncChrome(false, nowMs()) catch {};
    toplevel.frame_tree.node.setEnabled(@import("window_tabs.zig").visible(toplevel));
    // A newly focused app must not open behind the camera's current depth.
    if (want_focus and toplevel.server.config.compositor.focus_zoom == .camera) {
        if (target_out) |output| toplevel.server.world.navigateTo(toplevel, output);
    }
}

pub fn handleUnmapped(toplevel: *Toplevel) void {
    if (toplevel.closing) return;
    toplevel.finishZoomAnimation();
    toplevel.finishMoveAnimation();
    toplevel.server.switcher.cancel();
    if (!toplevel.in_world) return;
    const undo_applying = toplevel.server.undo.applying;
    toplevel.server.undo.applying = true;
    defer toplevel.server.undo.applying = undo_applying;
    const was_focused = toplevel.server.world.toplevels.first() == toplevel;
    const was_tab = toplevel.tab_group != 0;
    @import("auto_tiling.zig").unmapped(toplevel);
    @import("window_tabs.zig").rememberUnmap(toplevel);
    toplevel.server.window_tabs.remove(toplevel, false);
    toplevel.auto_target = null;
    toplevel.in_world = false;
    toplevel.needs_attention = false;
    toplevel.detachInput();
    toplevel.finishSwitch();
    const keep_scene = if (was_tab or !@import("workspaces.zig").visible(toplevel)) false else toplevel.beginCloseAnimation();
    if (!keep_scene) {
        toplevel.clearChromeCache();
        toplevel.frame_tree.node.setEnabled(false);
    }
    if (toplevel.backend == .xdg) {
        toplevel.rules_resolved = false;
        toplevel.placed = false;
    }
    if (toplevel.backend != .placeholder) {
        const id = toplevel.appId();
        if (id.len > 0) {
            const geom = toplevel.clientGeometry();
            if (geom.width > 0 and geom.height > 0) {
                window_sizes.save(toplevel.server.io, toplevel.server.environ, id, @intCast(geom.width), @intCast(geom.height));
            }
        }
    }
    // Retire the foreign-toplevel handle so an unmapped (but not yet
    // destroyed) window stops being offered as a new capture target. This
    // deliberately does *not* also call `Manager.stopForWindow` here: full
    // close always calls this before `content_tree.node.destroy()`
    // (`Toplevel.destroy`), and `WindowCaptureSource`'s own listener on
    // that destroy event already ends any live session on it gracefully
    // (a real `stopped` event, not a hard disconnect — see
    // window_source.zig and `run_window_destroy_case`). Calling
    // `stopForWindow` here too would win that race every time and replace
    // the graceful stop with a hard one (minimize already gets its own
    // explicit `stopForWindow` call in `minimize()`, since that hides the
    // frame without destroying anything). The gap this leaves — a window
    // that unmaps without ever being destroyed and without going through
    // `minimize()` either — is a known, narrow limitation, not a
    // content-isolation bug like the one that motivated
    // `WindowCaptureSource` in the first place.
    if (toplevel.foreign_handle) |handle| {
        handle.destroy();
        toplevel.foreign_handle = null;
    }
    if (toplevel.wlr_foreign) |handle| {
        handle.destroy();
        toplevel.wlr_foreign = null;
    }
    toplevel.link.remove();
    toplevel.server.world.workspaces.tiler.schedule(toplevel.server);
    toplevel.server.refreshTaskbars();
    // A dismissed transient dialog returns focus to the window it was
    // opened from, rather than leaving the seat with no keyboard focus at
    // all (or focus on whatever the scene tree now happens to expose).
    if (was_focused) {
        if (toplevel.owner()) |owner_toplevel| {
            if (owner_toplevel.in_world) toplevel.server.world.focus(owner_toplevel);
        }
    }
    if (was_focused and toplevel.server.world.workspaces.active) @import("workspaces.zig").focusFallback(toplevel.server, toplevel.workspace_id);
    if (toplevel.server.ipc) |ipc| {
        events.onWindowClosed(ipc, toplevel.id);
        ipc.wait_mgr.checkAll();
    }
    if (toplevel.server.idle) |im| {
        im.recheckInhibitors();
    }
}

pub fn destroy(toplevel: *Toplevel) void {
    if (toplevel.in_world) toplevel.handleUnmapped();
    if (!toplevel.backend_gone) {
        if (toplevel.forced_geometry_timer) |timer| {
            timer.remove();
            toplevel.forced_geometry_timer = null;
        }
        switch (toplevel.backend) {
            .xwayland => |*adapter| adapter.xsurface.data = null,
            .xdg, .placeholder, .shell => {},
        }
        toplevel.detachInput();
        if (toplevel.decoration) |decoration| {
            decoration.toplevel = null;
            toplevel.decoration = null;
        }
        if (toplevel.kde_decoration) |decoration| {
            decoration.toplevel = null;
            toplevel.kde_decoration = null;
        }
        toplevel.backend_gone = true;
    }
    if (toplevel.tryDeferDestroy()) return;
    toplevel.destroyNow();
}

fn tryDeferDestroy(toplevel: *Toplevel) bool {
    if (toplevel.server.shutting_down) return false;
    if (!toplevel.closing) return false;
    if (toplevel.close_snapshot == null) return false;
    const now_ms = nowMs();
    if (toplevel.map_motion.settled(now_ms) and toplevel.map_opacity.settled(now_ms)) return false;
    return true;
}

pub fn destroyNow(toplevel: *Toplevel) void {
    // A client window is freed only after its backend is destroyed: until then
    // its listeners are still attached and would run on freed memory.
    std.debug.assert(toplevel.backend_gone or toplevel.backend == .placeholder or toplevel.backend == .shell);
    if (toplevel.in_world) {
        toplevel.in_world = false;
        toplevel.link.remove();
        toplevel.server.world.workspaces.tiler.schedule(toplevel.server);
        toplevel.server.refreshTaskbars();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowClosed(ipc, toplevel.id);
            ipc.wait_mgr.checkAll();
        }
    }
    if (toplevel.in_closing_list) {
        toplevel.closing_link.remove();
        toplevel.in_closing_list = false;
    }
    toplevel.closing = false;
    toplevel.close_snapshot = null;
    if (!toplevel.backend_gone) {
        if (toplevel.forced_geometry_timer) |timer| {
            timer.remove();
            toplevel.forced_geometry_timer = null;
        }
        switch (toplevel.backend) {
            .xwayland => |*adapter| adapter.xsurface.data = null,
            .xdg => {},
            .placeholder => |*ph| {
                var it = toplevel.server.world.toplevels.iterator(.forward);
                while (it.next()) |top| {
                    if (top.placeholder_source == toplevel) top.placeholder_source = null;
                }
                ph.deinit();
            },
            .shell => |*sw| std.debug.assert(sw.control_center == null),
        }
        toplevel.detachInput();
        if (toplevel.decoration) |decoration| {
            decoration.toplevel = null;
            toplevel.decoration = null;
        }
        if (toplevel.kde_decoration) |decoration| {
            decoration.toplevel = null;
            toplevel.kde_decoration = null;
        }
        toplevel.backend_gone = true;
    }
    toplevel.clearChromeCache();
    toplevel.frame_tree.node.destroy();
    toplevel.releaseIcon();
    gpa.destroy(toplevel);
}

// A point is the frame's only if it falls inside the window's shape. The
// coordinates are frame-local.
fn insideFrame(toplevel: *Toplevel, px: f32, py: f32) bool {
    if (!toplevel.hasServerDecorations()) return false;
    const width = toplevel.chrome_width;
    const height = toplevel.chrome_height;
    if (width <= 0 or height <= 0) return false;

    const radius: f32 = toplevel.cornerRadius();
    return chrome.coverage(chrome.sdRoundedBox(
        px,
        py,
        0,
        0,
        @floatFromInt(width),
        @floatFromInt(height),
        radius,
    )) != 0;
}

pub fn isResizing(toplevel: *Toplevel) bool {
    const session = toplevel.server.input.resize_session orelse return false;
    return session.toplevel == toplevel;
}

pub fn isGeometrySettled(toplevel: *Toplevel, now_ms: i64) bool {
    if (toplevel.isResizing()) return false;
    return toplevel.move_x.settled(now_ms) and toplevel.move_y.settled(now_ms) and
        toplevel.size_w.settled(now_ms) and toplevel.size_h.settled(now_ms) and
        toplevel.switch_x.settled(now_ms) and toplevel.switch_y.settled(now_ms);
}

pub fn chromeAcceptsInput(buffer: *wlr.SceneBuffer, sx: *f64, sy: *f64) callconv(.c) bool {
    const data = scene_data.SceneData.fromNode(&buffer.node) orelse return false;
    if (data.role == .chrome and data.role.chrome.closing) return false;
    const toplevel = switch (data.role) {
        .chrome => |t| t,
        else => return false,
    };
    var ox: i32 = 0;
    var oy: i32 = 0;
    _ = buffer.node.coords(&ox, &oy);
    var fx: i32 = 0;
    var fy: i32 = 0;
    _ = toplevel.frame_tree.node.coords(&fx, &fy);
    const local = geometry.toLocal(@as(f64, @floatFromInt(ox)) + sx.*, @as(f64, @floatFromInt(oy)) + sy.*, fx, fy);
    const has_control = toplevel.controlAt(local.x, local.y) != null or toplevel.tabAt(local.x, local.y) != .none;
    if (resize.detectResizeEdges(local.x, local.y, toplevel.chrome_width, toplevel.chrome_height, toplevel.titlebarHeight(), chrome.frame_border, chrome.frame_border, has_control) != null) {
        return true;
    }

    const px = @as(f32, @floatCast(local.x)) + 0.5;
    const py = @as(f32, @floatCast(local.y)) + 0.5;
    if (!toplevel.insideFrame(px, py)) return false;

    return local.y < @as(f64, @floatFromInt(toplevel.titlebarHeight()));
}

/// Repaint theme-dependent chrome. `rebuild_shadow` is true here: a theme edit can change the shadow's
/// color/size, so already-open windows must pick it up immediately, same as
/// border/titlebar colors already do.
pub fn refreshTheme(toplevel: *Toplevel) void {
    defer @import("auto_tiling.zig").observe(toplevel);
    const height_changed = if (toplevel.last_titlebar) |memo| memo.chrome_height != theme.global.chrome_height else false;
    switch (toplevel.backend) {
        .placeholder => |*ph| col.setRect(ph.body_rect, col.Straight.fromRgba(theme.global.window_bg).premultiply()),
        .shell => |*sw| if (sw.control_center) |cc| cc.requestRepaint(),
        else => {},
    }
    syncChrome(toplevel, true, nowMs()) catch |err| {
        log.warn("refreshTheme: could not rebuild chrome: {}", .{err});
    };
    // A changed titlebar height must keep tiled frames inside their tile.
    if (height_changed and toplevel.in_world) {
        if (toplevel.tile) |tile| {
            if (toplevel.currentOutput()) |out| toplevel.setTiledOn(out, tile);
        }
    }
}

/// Keeps `IconService`'s refcount in sync with whatever icon this titlebar
/// last displayed (`toplevel.last_titlebar.?.icon`), so a future eviction
/// pass can tell a live titlebar's icon apart from an unreferenced one.
/// No-op when the icon didn't change (the common case: most `syncChrome`
/// calls are unrelated commits/hover changes on an already-resolved icon).
fn updateHeldIcon(toplevel: *Toplevel, new_icon: ?icon_service.Entry) void {
    const old_id: ?u64 = if (toplevel.last_titlebar) |prev| (if (prev.icon) |e| e.id else null) else null;
    const new_id: ?u64 = if (new_icon) |e| e.id else null;
    if (old_id == new_id) return;
    if (old_id) |id| toplevel.server.iconRelease(id);
    if (new_id) |id| toplevel.server.iconAcquire(id);
}

/// Releases whatever icon handle this titlebar currently holds, if any.
/// Called before dropping `last_titlebar` outside of the normal
/// `updateHeldIcon` path (window destroyed, decorations turned off).
fn releaseIcon(toplevel: *Toplevel) void {
    if (toplevel.last_titlebar) |prev| {
        if (prev.icon) |e| toplevel.server.iconRelease(e.id);
    }
}

/// Density of the sharpest output touched by the displayed frame. Keep the
/// previous density while offscreen to avoid repainting invisible windows.
pub fn syncOutputScale(toplevel: *Toplevel) void {
    const origin = toplevel.server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
    const width = @as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.zoom();
    const height = @as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.zoom();
    var scale: f32 = 0;
    var it = toplevel.server.outputs.iterator(.forward);
    while (it.next()) |out| {
        if (!out.isLogicallyEnabled()) continue;
        const b = out.cached_box;
        if (origin.x < @as(f64, @floatFromInt(b.x)) + @as(f64, @floatFromInt(b.width)) and
            origin.y < @as(f64, @floatFromInt(b.y)) + @as(f64, @floatFromInt(b.height)) and
            origin.x + width > @as(f64, @floatFromInt(b.x)) and
            origin.y + height > @as(f64, @floatFromInt(b.y)))
        {
            scale = @max(scale, out.wlr_output.scale);
        }
    }
    if (scale == 0 or scale == toplevel.render_scale) return;
    toplevel.render_scale = scale;
    toplevel.syncChrome(true, nowMs()) catch |err| {
        log.warn("output scale: could not rebuild chrome: {}", .{err});
    };
}

fn clearChromeCache(toplevel: *Toplevel) void {
    if (toplevel.cached_titlebar) |buffer| buffer.base.drop();
    toplevel.cached_titlebar = null;
}

/// `rebuild_shadow` is false on a pure hover repaint, which cannot change the
/// shadow; geometry and theme changes pass true.
pub fn syncChrome(toplevel: *Toplevel, rebuild_shadow: bool, now_ms: i64) !void {
    defer toplevel.server.scheduleFrames();
    const geometry_box = toplevel.clientGeometry();
    if (geometry_box.width <= 0 or geometry_box.height <= 0) return;

    const decorated = toplevel.hasServerDecorations();
    toplevel.titlebar_buffer.node.setEnabled(decorated);
    for (toplevel.frame_fills) |rect| rect.node.setEnabled(decorated);
    // A decorated window's border is the shape's ring; the rects only outline
    // windows that draw their own decorations.
    for (toplevel.border_rects) |rect| rect.node.setEnabled(!decorated and toplevel.hasWorkspaceFocusBorder());
    if (!decorated) {
        toplevel.releaseIcon();
        toplevel.clearChromeCache();
        toplevel.last_titlebar = null;
        toplevel.shadow_tree.node.setEnabled(false);
        toplevel.resize_grab.node.setEnabled(false);
        toplevel.content_tree.node.setPosition(0, 0);
        const animated = visualChromeSize(toplevel, now_ms, geometry_box.width, geometry_box.height);
        toplevel.chrome_width = animated.w;
        toplevel.chrome_height = animated.h;
        applySizeClip(toplevel);
        toplevel.hovered = false;
        toplevel.hovered_control = null;
        toplevel.hover_anim.cancel(0);
        toplevel.resetChip();
        toplevel.last_painted_hover = 0;
        toplevel.syncBorders(animated.w, animated.h);
        toplevel.applyShape();
        return;
    }

    const radius: f32 = toplevel.cornerRadius();
    const natural_w = geometry_box.width + 2 * chrome.frame_border;
    const natural_h = geometry_box.height + toplevel.titlebarHeight() + chrome.frame_border;
    const animated = visualChromeSize(toplevel, now_ms, natural_w, natural_h);
    const width = animated.w;
    const height = animated.h;
    const window_title = toplevel.title();
    const app_id = toplevel.appId();
    const icon_lookup = toplevel.server.iconLookup(app_id, geometry.devicePixels((chrome.Metrics{ .density = toplevel.chromeDensity() }).iconSize(), toplevel.render_scale));
    const icon: ?icon_service.Entry = switch (icon_lookup) {
        .ready => |e| e,
        .pending, .missing => null,
    };
    toplevel.updateHeldIcon(icon);
    const hover = toplevel.hover_anim.value(now_ms);
    const chip_alpha = toplevel.chip_alpha.value(now_ms);
    var tab_storage: [@import("window_tabs.zig").max_tabs]@import("chrome_tabs.zig").Tab = undefined;
    const state: chrome.ChromeState = .{
        .tabs = toplevel.tabStrip(&tab_storage),
        .active = toplevel.activated,
        .workspace_focus = toplevel.hasWorkspaceFocusBorder(),
        .maximized = toplevel.isMaximized(),
        .density = toplevel.chromeDensity(),
        .title = window_title,
        .scale = toplevel.render_scale,
        .hover = hover,
        // An invisible chip has no position: keeps the raster memo stable.
        .chip_pos = if (chip_alpha > 0) toplevel.chip_pos.value(now_ms) else 0,
        .chip_alpha = chip_alpha,
        .icon = icon,
    };
    toplevel.last_painted_hover = hover;
    toplevel.chrome_width = width;
    toplevel.chrome_height = height;

    const title_memo = chrome.TitlebarMemo.capture(width, height, toplevel.titlePtr(), state);
    const skip_titlebar = if (toplevel.last_titlebar) |prev| prev.eql(title_memo) or toplevel.stretchesTitlebar(prev, title_memo, now_ms) else false;
    if (!skip_titlebar) {
        const titlebar = if (toplevel.cached_titlebar != null and toplevel.last_titlebar != null and toplevel.last_titlebar.?.reusableFor(title_memo))
            try chrome.ChromeBuffer.createUpdated(toplevel.cached_titlebar.?, state, toplevel.last_titlebar.?.title_ptr != title_memo.title_ptr)
        else
            try chrome.ChromeBuffer.create(width, state);
        toplevel.titlebar_buffer.setBuffer(&titlebar.base);
        if (toplevel.cached_titlebar) |previous| previous.base.drop();
        toplevel.cached_titlebar = titlebar;
        stats.recordTitlebarPaint();
        toplevel.last_titlebar = title_memo;
    }

    toplevel.titlebar_buffer.setDestSize(width, toplevel.titlebarHeight());
    glass.Effect.configure(toplevel.glass_effect, radius, 1);

    toplevel.syncBorders(width, height);
    toplevel.applyShape();
    toplevel.syncResizeGrab(width, height);
    if (rebuild_shadow) try toplevel.syncShadow(width, height, radius);

    // wlr_scene_xdg_surface_create origin is the geometry top-left.
    toplevel.content_tree.node.setPosition(chrome.frame_border, toplevel.titlebarHeight());
    switch (toplevel.backend) {
        .placeholder => |*ph| ph.body_rect.setSize(geometry_box.width, geometry_box.height),
        else => {},
    }
    applySizeClip(toplevel);
}

/// How far an easing frame stretches its titlebar raster before rastering anew.
const titlebar_stretch: f32 = 0.12;

/// Whether a frame easing to a new size keeps its titlebar raster, stretched,
/// instead of rastering it for every frame (`ChromeBuffer.create` costs
/// milliseconds, and a reflow eases several frames at once): only the size
/// changed, the width by at most `titlebar_stretch`. The band does not depend
/// on the height, and the settled size always rasters exactly.
fn stretchesTitlebar(toplevel: *const Toplevel, raster: chrome.TitlebarMemo, next: chrome.TitlebarMemo, now_ms: i64) bool {
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) return false;
    if (toplevel.size_w.settled(now_ms) and toplevel.size_h.settled(now_ms)) return false;
    var resized = raster;
    resized.width = next.width;
    resized.height = next.height;
    if (!resized.eql(next)) return false;
    const ratio = @as(f32, @floatFromInt(next.width)) / @as(f32, @floatFromInt(@max(raster.width, 1)));
    return @abs(ratio - 1) <= titlebar_stretch;
}

fn visualChromeSize(toplevel: *Toplevel, now_ms: i64, natural_w: i32, natural_h: i32) struct { w: i32, h: i32 } {
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) {
        return .{ .w = natural_w, .h = natural_h };
    }
    const w: i32 = @intFromFloat(@round(toplevel.size_w.value(now_ms)));
    const h: i32 = @intFromFloat(@round(toplevel.size_h.value(now_ms)));
    if (toplevel.size_w.settled(now_ms) and toplevel.size_h.settled(now_ms) and
        ((w == natural_w and h == natural_h) or toplevel.size_wait == .none))
    {
        toplevel.size_w.cancel(@floatFromInt(natural_w));
        toplevel.size_h.cancel(@floatFromInt(natural_h));
        return .{ .w = natural_w, .h = natural_h };
    }
    return .{ .w = @max(w, 1), .h = @max(h, 1) };
}

// The output pass draws the shadow from the window's shape; the node, without a
// buffer, carries only its footprint, the window's opacity and input. Called
// where geometry or theme may have changed, never on a hover repaint.
fn syncShadow(toplevel: *Toplevel, width: i32, height: i32, radius: f32) !void {
    const t = theme.global;
    const disabled = !chrome.shapes or toplevel.isMaximized() or t.shadow[3] <= 0 or t.shadow_size <= 0;
    const memo = chrome.ShadowMemo.capture(width, height, radius, toplevel.render_scale, disabled);

    if (disabled) {
        toplevel.shadow_tree.node.setEnabled(false);
        toplevel.last_shadow = memo;
        return;
    }

    toplevel.shadow_tree.node.setEnabled(true);
    // Every client commit lands here; an unchanged memo means nothing to redo.
    if (toplevel.last_shadow) |prev| {
        if (prev.eql(memo)) return;
    }

    const margin: i32 = @intFromFloat(@ceil(t.shadow_size));
    const offset_y: i32 = @intFromFloat(t.shadow_offset_y);
    toplevel.shadow_node.node.setPosition(-margin, -margin + offset_y);
    toplevel.shadow_node.setDestSize(width + 2 * margin, height + 2 * margin);
    const r: f64 = radius;
    if (!projection.setTreeShadow(&toplevel.shadow_tree.node, .{
        .width = width,
        .height = height,
        .radii = .{ r, r, r, r },
        .offset_x = 0,
        .offset_y = @floatFromInt(offset_y),
        .softness = t.shadow_size,
        .color = col.Straight.fromRgba(t.shadow).premultiply().rgba,
    })) log.warn("could not set the window shadow ({d}x{d})", .{ width, height });
    toplevel.last_shadow = memo;
}

// Unchanged position and size are no-ops in wlroots, so this runs on every
// sync. Off while maximized, like the shadow: `startResize` refuses then.
fn syncResizeGrab(toplevel: *Toplevel, width: i32, height: i32) void {
    const reach: i32 = @intFromFloat(@ceil(resize.reach_outside));
    toplevel.resize_grab.node.setEnabled(!toplevel.isMaximized());
    toplevel.resize_grab.node.setPosition(-reach, -reach);
    toplevel.resize_grab.setDestSize(width + 2 * reach, height + 2 * reach);
}

/// The shape that clips the whole window, titlebar, client and subsurfaces, in
/// the output pass (see `chrome.shapes`). Windows that draw their own
/// decorations, and fullscreen ones, have none; a maximized one has a square one,
/// for its border. Nothing changes if the shape is the one already set.
fn applyShape(toplevel: *Toplevel) void {
    if (!chrome.shapes) return;
    const node = &toplevel.frame_tree.node;
    if (!toplevel.hasServerDecorations() or toplevel.chrome_width <= 0 or toplevel.chrome_height <= 0) {
        _ = projection.setTreeClip(node, null);
        return;
    }
    const radius: f64 = toplevel.cornerRadius();
    const ring = toplevel.borderColor().scale(toplevel.shape_opacity);
    if (!projection.setTreeClip(node, .{
        .width = toplevel.chrome_width,
        .height = toplevel.chrome_height,
        .radii = .{ radius, radius, radius, radius },
        .border = @floatFromInt(chrome.frame_border),
        .border_color = ring.rgba,
    })) {
        log.warn("could not set the window shape ({d}x{d})", .{ toplevel.chrome_width, toplevel.chrome_height });
    }
}

fn syncBorders(toplevel: *Toplevel, width: i32, height: i32) void {
    if (!toplevel.hasServerDecorations()) {
        // Outline CSD frames outside their content. Client geometry and input
        // coordinates stay unchanged, and the content remains above the stroke.
        const color = toplevel.borderColor();
        for (toplevel.border_rects) |rect| col.setRect(rect, color);
        const edge = chrome.frame_border;
        toplevel.border_rects[0].node.setPosition(-edge, -edge);
        toplevel.border_rects[0].setSize(width + 2 * edge, edge);
        toplevel.border_rects[1].node.setPosition(-edge, 0);
        toplevel.border_rects[1].setSize(edge, height);
        toplevel.border_rects[2].node.setPosition(width, 0);
        toplevel.border_rects[2].setSize(edge, height);
        toplevel.border_rects[3].node.setPosition(-edge, height);
        toplevel.border_rects[3].setSize(width + 2 * edge, edge);
        return;
    }
    // Only back the gap the titlebar leaves: overlapping it would apply the
    // translucent chrome twice at the joins. The ring over the fills, the
    // titlebar and the client's edge is the shape's.
    const body_top = toplevel.titlebarHeight();
    const edge = chrome.frame_border;
    const body_height = @max(0, height - body_top - edge);
    for (toplevel.frame_fills) |rect| col.setRect(rect, chrome.fillColor());
    toplevel.frame_fills[0].node.setPosition(0, body_top);
    toplevel.frame_fills[0].setSize(edge, body_height);
    toplevel.frame_fills[1].node.setPosition(width - edge, body_top);
    toplevel.frame_fills[1].setSize(edge, body_height);
    toplevel.frame_fills[2].node.setPosition(0, height - edge);
    toplevel.frame_fills[2].setSize(width, edge);
}

pub fn detachInput(toplevel: *Toplevel) void {
    toplevel.server.input.detachToplevel(toplevel);
    toplevel.clearDodge();
    toplevel.clearZoomBoost();
    toplevel.peek_mix = .{};
    toplevel.peek_level = .{ .from = 1, .to = 1 };
    toplevel.hovered = false;
    toplevel.hovered_control = null;
    toplevel.hover_anim.cancel(0);
    toplevel.resetChip();
    toplevel.last_painted_hover = 0;
}

/// Blend the temporary taskbar preview over the configured window opacity.
pub fn effectiveOpacity(toplevel: *Toplevel, now_ms: i64) f32 {
    const focused = @import("config_runtime/actions.zig").focusedToplevel(toplevel.server);
    const inactive = std.math.clamp(toplevel.server.config.compositor.inactive_opacity, 0, 1);
    const normal = (toplevel.live_rules.opacity orelse 1) * (if (toplevel == focused) @as(f32, 1) else inactive);
    const mix = toplevel.peek_mix.value(now_ms);
    return (normal * (1 - mix) + toplevel.peek_level.value(now_ms) * mix) * toplevel.cameraFocusOpacity();
}

pub fn applyOpacity(toplevel: *Toplevel, now_ms: i64) void {
    var opacity = std.math.clamp(toplevel.effectiveOpacity(now_ms) * toplevel.map_opacity.value(now_ms) * toplevel.switch_fade.value(now_ms), 0, 1);
    toplevel.frame_tree.node.forEachBuffer(*f32, struct {
        fn iter(buffer: *wlr.SceneBuffer, _: c_int, _: c_int, value: *f32) void {
            buffer.setOpacity(value.*);
        }
    }.iter, &opacity);
    const color = toplevel.borderColor().scale(opacity);
    for (toplevel.border_rects) |rect| col.setRect(rect, color);
    for (toplevel.frame_fills) |rect| col.setRect(rect, chrome.fillColor().scale(opacity));
    toplevel.shape_opacity = opacity;
    toplevel.applyShape();
    glass.Effect.configure(toplevel.glass_effect, toplevel.cornerRadius(), opacity);
    switch (toplevel.backend) {
        .placeholder => |*ph| col.setRect(ph.body_rect, col.Straight.fromRgba(theme.global.window_bg).premultiply().scale(opacity)),
        else => {},
    }
}

pub fn applyHover(toplevel: *Toplevel, hovered: bool, control: ?chrome.ControlKind) void {
    if (!hovered and toplevel.tab_hover != 0) {
        toplevel.tab_hover = 0;
        toplevel.syncChrome(false, nowMs()) catch {};
    }
    const hover_changed = toplevel.hovered != hovered;
    const control_changed = toplevel.hovered_control != control;
    if (!hover_changed and !control_changed) return;

    toplevel.hovered = hovered;
    toplevel.hovered_control = control;
    if (hover_changed) {
        toplevel.hover_anim.retargetTo(nowMs(), if (hovered) 1 else 0, anim.curveFor(.titlebar_hover));
        toplevel.server.scheduleFrames();
    }
    if (control_changed) {
        toplevel.retargetChip(control);
        toplevel.server.scheduleFrames();
    }
    if (control_changed or !hover_changed) {
        toplevel.syncChrome(false, nowMs()) catch |err| {
            log.err("applyHover: could not update window decoration: {}", .{err});
        };
    }
}

/// The chip fades in where the pointer lands, then glides to whichever button
/// the pointer visits next; leaving every button only fades it, in place.
fn retargetChip(toplevel: *Toplevel, control: ?chrome.ControlKind) void {
    const now_ms = nowMs();
    const kind = control orelse {
        toplevel.chip_alpha.retargetTo(now_ms, 0, anim.curveFor(.titlebar_chip_fade));
        return;
    };
    const slot = chrome.controlSlot(kind);
    if (toplevel.chip_alpha.value(now_ms) <= 0.01) {
        toplevel.chip_pos.cancel(slot);
    } else {
        toplevel.chip_pos.retargetTo(now_ms, slot, anim.curveFor(.titlebar_chip));
    }
    toplevel.chip_alpha.retargetTo(now_ms, 1, anim.curveFor(.titlebar_chip_fade));
}

fn resetChip(toplevel: *Toplevel) void {
    toplevel.chip_pos.cancel(0);
    toplevel.chip_alpha.cancel(0);
}

pub fn tickHover(toplevel: *Toplevel, now_ms: i64) bool {
    // Every sampler must run each frame (they track their own last value).
    const border = toplevel.hover_anim.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    const glide = toplevel.chip_pos.sampleChanged(now_ms, anim.rasterPixelQuantum(toplevel.render_scale) / chip_slot_px);
    const fade = toplevel.chip_alpha.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    if (border or glide or fade) {
        toplevel.syncChrome(false, now_ms) catch |err| {
            log.err("tickHover: could not update window decoration: {}", .{err});
        };
    }
    return !toplevel.hover_anim.settled(now_ms) or !toplevel.chip_pos.settled(now_ms) or !toplevel.chip_alpha.settled(now_ms);
}

// Roughly one button pitch in logical px: converts the glide's pixel quantum
// into slot units.
const chip_slot_px: f32 = 32;

pub fn nowMs() i64 {
    return @import("ui").anim.nowMs();
}

pub fn controlAt(toplevel: *Toplevel, sx: f64, sy: f64) ?chrome.ControlKind {
    if (!toplevel.hasServerDecorations() or sy >= @as(f64, @floatFromInt(toplevel.titlebarHeight()))) return null;
    inline for (.{ chrome.ControlKind.close, .maximize, .minimize }) |kind| {
        if (chrome.controlRectScaled(toplevel.chrome_width, kind, toplevel.chromeDensity()).contains(sx, sy)) return kind;
    }
    return null;
}

pub fn handleChromeClick(toplevel: *Toplevel, sx: f64, sy: f64, button: u32) void {
    if (!toplevel.hasServerDecorations() or sy >= @as(f64, @floatFromInt(toplevel.titlebarHeight()))) return;

    const hit = toplevel.tabAt(sx, sy);
    if (hit != .none) {
        if (button != Input.btn_left) return;
        switch (hit) {
            .tab => |id| if (toplevel.server.findToplevelById(id)) |target| toplevel.server.world.focus(target),
            .close => |id| if (toplevel.server.findToplevelById(id)) |target| {
                toplevel.server.world.focus(target);
                target.sendClose();
            },
            .plus => toplevel.server.window_tabs.launch(toplevel),
            .previous => toplevel.stepTab(false),
            .next => toplevel.stepTab(true),
            .none => {},
        }
        return;
    }
    if (toplevel.controlAt(sx, sy)) |kind| switch (kind) {
        .close => @import("window_tabs.zig").closeGroup(toplevel),
        .maximize => toplevel.toggleMaximize(),
        .minimize => toplevel.minimize(),
    } else if (button == Input.btn_left) {
        toplevel.beginMove();
    }
}

// xdg-shell has no minimized state of its own, so minimizing is purely a
// compositor-side hint: hide the frame and drop keyboard focus while the
// client stays mapped. Taskbar.pointerPress restores it on the next chip
// click (see Taskbar.zig).
pub fn minimize(toplevel: *Toplevel) void {
    if (toplevel.tab_hidden) {
        if (@import("window_tabs.zig").active(toplevel.server, toplevel.tab_group)) |active_tab| active_tab.minimize();
        return;
    }
    // X11 clients can ask for this while withdrawn; the stack reorder below
    // needs the window to be in it.
    if (toplevel.minimized or !toplevel.in_world) return;
    toplevel.minimized = true;
    toplevel.detachInput();
    toplevel.finishSwitch();
    toplevel.frame_tree.node.setEnabled(false);

    const server = toplevel.server;
    if (server.input.seat.keyboard_state.focused_surface) |focused| {
        if (fromSurface(server, focused) == toplevel) server.input.seat.keyboardNotifyClearFocus();
    }
    toplevel.setActivated(false);
    switch (toplevel.backend) {
        .xwayland => |*adapter| {
            adapter.xsurface.setMinimized(true);
            adapter.xsurface.restack(null, .below);
        },
        .xdg, .placeholder, .shell => {},
    }

    // Move to the back of the stack so the taskbar's active-window mark and
    // the F1 cycle both skip past minimized windows.
    toplevel.link.remove();
    server.world.toplevels.append(toplevel);

    server.refreshTaskbars();
    toplevel.syncForeign();
    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
    if (toplevel.server.idle) |im| {
        im.recheckInhibitors();
    }

    if (toplevel.tab_group != 0) @import("window_tabs.zig").refreshVisibility(server);
    if (server.world.workspaces.active) @import("workspaces.zig").focusFallback(server, toplevel.workspace_id);
    // Must run last: content_tree stays alive and rendering-ready while
    // minimized (only the frame is hidden), so a window-capture source
    // over it wouldn't otherwise notice — unlike a real close, nothing
    // here destroys the scene node to trigger WindowCaptureSource's
    // graceful stop. The failure contract's "minimize: End the selected
    // source's session" row needs this explicit hard-disconnect fallback
    // instead — and since the capturing client can be this same toplevel's
    // own client (self-capture), disconnecting it can free `toplevel`
    // itself; nothing above this point may run afterward.
    if (server.capture_mgr) |cm| {
        cm.stopForWindow(toplevel.id, @import("capture/manager.zig").failure_window_closed);
    }
}

pub fn restore(toplevel: *Toplevel) void {
    toplevel.server.window_tabs.select(toplevel);
    defer if (toplevel.tab_group != 0) @import("window_tabs.zig").refreshVisibility(toplevel.server);
    if (!toplevel.minimized or !toplevel.in_world) return;
    toplevel.minimized = false;
    toplevel.frame_tree.node.setEnabled(@import("window_tabs.zig").visible(toplevel));
    switch (toplevel.backend) {
        .xwayland => |*adapter| adapter.xsurface.setMinimized(false),
        .xdg, .placeholder, .shell => {},
    }
    toplevel.server.world.focus(toplevel);
    toplevel.syncForeign();
    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
    if (toplevel.server.idle) |im| {
        im.recheckInhibitors();
    }
}

pub fn rememberGeometry(toplevel: *const Toplevel) RestoreGeometry {
    const client = toplevel.clientGeometry();
    return .{
        .x = toplevel.x,
        .y = toplevel.y,
        .width = client.width,
        .height = client.height,
    };
}

/// Immediate floating placement, with no deferred restore that can undo a drag.
pub fn restoreGeometryNow(toplevel: *Toplevel, saved: RestoreGeometry) void {
    toplevel.pending_restore = null;
    toplevel.finishSizeAnimation();
    var x = saved.x;
    var y = saved.y;
    if (@import("workspaces.zig").outputFor(toplevel)) |output| {
        // A restore may have been captured before transfer or hot-unplug.
        // Keep its titlebar on the workspace's current output.
        const usable = output.usableBox();
        const width = saved.width +| (2 * toplevel.borderWidth());
        const height = saved.height +| toplevel.titlebarHeight() +| toplevel.footerHeight();
        x = std.math.clamp(x, usable.x, usable.x + @max(0, usable.width - width));
        y = std.math.clamp(y, usable.y, usable.y + @max(0, usable.height - height));
    }
    toplevel.setPosition(x, y);
    _ = toplevel.requestSize(saved.width, saved.height);
}

pub fn restoreGeometry(toplevel: *Toplevel, saved: RestoreGeometry) void {
    toplevel.pending_restore = saved;
    _ = toplevel.requestSizeAnimated(saved.width, saved.height);
    toplevel.setPositionAnimated(saved.x, saved.y);
    toplevel.scheduleForcedGeometry();
}

pub fn forcedGeometry(toplevel: *const Toplevel) ?RestoreGeometry {
    return toplevel.fullscreen_target orelse toplevel.maximize_target orelse toplevel.tile_target orelse toplevel.auto_target orelse toplevel.pending_restore;
}

fn applyForcedGeometry(toplevel: *Toplevel) c_int {
    const forced = toplevel.forcedGeometry() orelse return 0;
    if (toplevel.auto_target != null and !toplevel.maximized and !toplevel.fullscreen) {
        // Automatic frames must not inherit a size-animation endpoint computed
        // with the old maximized/fullscreen decorations before the xdg ack.
        toplevel.finishSizeAnimation();
        _ = toplevel.requestSize(forced.width, forced.height);
        toplevel.setPosition(forced.x, forced.y);
    } else {
        _ = toplevel.requestSizeAnimated(forced.width, forced.height);
        toplevel.setPositionAnimated(forced.x, forced.y);
    }
    toplevel.pending_restore = null;
    return 0;
}

fn scheduleForcedGeometry(toplevel: *Toplevel) void {
    if (toplevel.forced_geometry_timer == null) {
        toplevel.forced_geometry_timer = toplevel.server.wl_server.getEventLoop().addTimer(
            *Toplevel,
            applyForcedGeometry,
            toplevel,
        ) catch return;
    }
    toplevel.forced_geometry_timer.?.timerUpdate(25) catch {};
}

// Maximizing fits the window into its output's usable area (the full output
// minus the taskbar's exclusive strip), so it sits above the bar rather than
// under it. The compositor owns the position as well as the requested client
// size, so it also owns and restores both values on un-maximize.
pub fn toggleMaximize(toplevel: *Toplevel) void {
    toplevel.setMaximized(!toplevel.maximized);
}

pub fn currentIdentity(toplevel: *Toplevel) window_rules.WindowIdentity {
    return switch (toplevel.backend) {
        .xdg => |*adapter| .{
            .tag = @import("extra_protocols.zig").tag(toplevel.surface(), false) orelse "",
            .app_id = if (adapter.xdg_toplevel.app_id) |s| std.mem.span(s) else "",
            .title = if (adapter.xdg_toplevel.title) |s| std.mem.span(s) else "",
            .backend = .xdg,
            .dialog = toplevel.parentWindow() != null or adapter.xdg_toplevel.parent != null,
        },
        .xwayland => |*adapter| .{
            .app_id = "",
            .title = if (adapter.xsurface.title) |s| std.mem.span(s) else "",
            .x11_class = if (adapter.xsurface.class) |s| std.mem.span(s) else "",
            .x11_instance = if (adapter.xsurface.instance) |s| std.mem.span(s) else "",
            .backend = .xwayland,
            .dialog = toplevel.parentWindow() != null or adapter.xsurface.parent != null,
        },
        .shell => .{
            .app_id = settings_app_id,
            .title = settings_title,
            .backend = .xdg,
            .dialog = false,
        },
        .placeholder => |*ph| .{
            .app_id = ph.app_id,
            .title = ph.name,
            .backend = .xdg,
            .dialog = false,
        },
    };
}

pub fn resolveTargetOutput(toplevel: *const Toplevel) ?*Output {
    if (toplevel.open_rules.getOutput()) |name| {
        if (toplevel.server.findOutputByName(name)) |out| {
            return out;
        }
    }
    return toplevel.server.getDefaultOutput();
}

/// The output the window's center currently sits over, falling back to its
/// resolved target output (e.g. before it has ever been placed in the
/// layout). Used to decide which output's taskbar a fullscreen window
/// should suppress.
pub fn currentOutput(toplevel: *const Toplevel) ?*Output {
    if (@import("workspaces.zig").outputFor(toplevel)) |output| return output;
    const center = toplevel.frameWorld(@floatFromInt(@divTrunc(toplevel.chrome_width, 2)), @floatFromInt(@divTrunc(toplevel.chrome_height, 2)));
    const layout_center = toplevel.server.world.toLayout(center.x, center.y);
    return Output.atLayout(toplevel.server, layout_center.x, layout_center.y) orelse toplevel.resolveTargetOutput();
}

pub fn resolveInitialRules(toplevel: *Toplevel) void {
    if (toplevel.rules_resolved) return;
    toplevel.rules_resolved = true;
    const id = toplevel.currentIdentity();
    if (id.app_id.len == 0 and toplevel.backend == .xdg) {
        toplevel.resolved_before_app_id = true;
    }
    const resolved = window_rules.resolve(toplevel.server.config.window_rules, id);
    toplevel.open_rules = window_rules.OpenRules.fromResolved(resolved);
    toplevel.live_rules = window_rules.LiveRules.fromResolved(resolved);
    toplevel.matched_rules = resolved.matched_rules;
}

pub fn pickInitialPlacement(
    server: *Server,
    output: *Output,
    open_rules: window_rules.OpenRules,
    parent: ?*Toplevel,
    w: i32,
    h: i32,
) RestoreGeometry {
    const usable = output.usableBox();
    var rx: i32 = undefined;
    var ry: i32 = undefined;

    if (open_rules.center orelse false) {
        const lx = usable.x + @divTrunc(usable.width - w, 2);
        const ly = usable.y + @divTrunc(usable.height - h, 2);
        const pt = server.world.toWorld(@floatFromInt(lx), @floatFromInt(ly));
        rx = @intFromFloat(@round(pt.x));
        ry = @intFromFloat(@round(pt.y));
    } else if (open_rules.x != null or open_rules.y != null) {
        const lx = usable.x + (open_rules.x orelse 0);
        const ly = usable.y + (open_rules.y orelse 0);
        const pt = server.world.toWorld(@floatFromInt(lx), @floatFromInt(ly));
        rx = @intFromFloat(@round(pt.x));
        ry = @intFromFloat(@round(pt.y));
    } else if (parent) |p| {
        rx = p.x + 30;
        ry = p.y + 30;
    } else {
        const cascade = @mod(@as(i32, @intCast(server.world.toplevels.length())) * 30, 240);
        const pt = server.world.toWorld(@floatFromInt(usable.x + 50 + cascade), @floatFromInt(usable.y + 50 + cascade));
        rx = @intFromFloat(@round(pt.x));
        ry = @intFromFloat(@round(pt.y));
    }

    return .{ .x = rx, .y = ry, .width = w, .height = h };
}

pub fn setupInitialRestoreGeometry(toplevel: *Toplevel, output: *Output) void {
    const rw: i32 = @intCast(toplevel.open_rules.width orelse 640);
    const rh: i32 = @intCast(toplevel.open_rules.height orelse 480);
    const geom = pickInitialPlacement(toplevel.server, output, toplevel.open_rules, toplevel.parentWindow(), rw, rh);
    if (toplevel.maximize_restore == null) toplevel.maximize_restore = geom;
    if (toplevel.fullscreen_restore == null) toplevel.fullscreen_restore = geom;
}

pub fn configureInitialXdgState(toplevel: *Toplevel) void {
    const adapter = switch (toplevel.backend) {
        .xdg => |*a| a,
        .xwayland, .placeholder, .shell => return,
    };

    const maybe_ph = toplevel.placeholder_source orelse toplevel.findMatchingPlaceholder();
    if (maybe_ph) |ph_top| {
        toplevel.placeholder_source = ph_top;
        ph_top.backend.placeholder.matched = true;
        const is_dialog = toplevel.parentWindow() != null or adapter.xdg_toplevel.parent != null;
        if (!is_dialog) {
            const ph = &ph_top.backend.placeholder;
            if (ph_top.isMaximized()) {
                _ = adapter.xdg_toplevel.setMaximized(true);
                toplevel.maximized = true;
                _ = adapter.xdg_toplevel.setSize(ph.client_width, ph.client_height);
                toplevel.maximize_target = ph_top.maximize_target;
                toplevel.maximize_restore = ph_top.maximize_restore;
                toplevel.placed = true;
                return;
            } else if (ph_top.isFullscreen()) {
                _ = adapter.xdg_toplevel.setFullscreen(true);
                toplevel.fullscreen = true;
                _ = adapter.xdg_toplevel.setSize(ph.client_width, ph.client_height);
                toplevel.fullscreen_target = ph_top.fullscreen_target;
                toplevel.fullscreen_restore = ph_top.fullscreen_restore;
                toplevel.placed = true;
                return;
            } else {
                _ = adapter.xdg_toplevel.setSize(ph.client_width, ph.client_height);
                toplevel.setPosition(ph_top.x, ph_top.y);
                toplevel.placed = true;
                return;
            }
        }
    }

    const target_out = toplevel.resolveTargetOutput();
    const rule_fs = toplevel.open_rules.fullscreen;
    const rule_max = toplevel.open_rules.maximized;

    const want_fs = if (rule_fs) |v| v else adapter.xdg_toplevel.requested.fullscreen;
    const want_max = if (want_fs) false else (if (rule_max) |v| v else adapter.xdg_toplevel.requested.maximized);

    if (want_fs) {
        _ = adapter.xdg_toplevel.setFullscreen(true);
        toplevel.fullscreen = true;
        if (target_out) |out| {
            var box: wlr.Box = undefined;
            toplevel.server.output_layout.getBox(out.wlr_output, &box);
            _ = adapter.xdg_toplevel.setSize(box.width, box.height);
            toplevel.setupInitialRestoreGeometry(out);
            toplevel.fullscreen_target = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        }
    } else if (want_max) {
        _ = adapter.xdg_toplevel.setMaximized(true);
        toplevel.maximized = true;
        if (target_out) |out| {
            const usable = out.usableBox();
            const footer = if (toplevel.hasServerDecorations()) chrome.frame_border else 0;
            const mw = usable.width - 2 * toplevel.borderWidth();
            const mh = usable.height - toplevel.titlebarHeight() - footer;
            _ = adapter.xdg_toplevel.setSize(@max(1, mw), @max(1, mh));
            toplevel.setupInitialRestoreGeometry(out);
            toplevel.maximize_target = .{ .x = usable.x, .y = usable.y, .width = @max(1, mw), .height = @max(1, mh) };
        }
    } else {
        if (rule_max != null and !rule_max.?) {
            _ = adapter.xdg_toplevel.setMaximized(false);
        }
        if (rule_fs != null and !rule_fs.?) {
            _ = adapter.xdg_toplevel.setFullscreen(false);
        }
        const w: i32 = @intCast(toplevel.open_rules.width orelse 0);
        const h: i32 = @intCast(toplevel.open_rules.height orelse 0);
        _ = adapter.xdg_toplevel.setSize(w, h);
    }
}

pub fn setZoomOrigin(toplevel: *Toplevel, index: usize) void {
    const next = @min(index, @import("camera.zig").zoom_levels.len - 1);
    const scale = @as(f64, @floatFromInt(@import("camera.zig").zoom_levels[next])) / 100;
    if (!@import("projection.zig").setTreeZoom(&toplevel.frame_tree.node, scale)) {
        log.err("cannot allocate window zoom", .{});
        return;
    }
    toplevel.zoom_index = next;
    toplevel.zoom_scale = scale;
    toplevel.zoom_anim = .{ .from = @floatCast(scale), .to = @floatCast(scale) };
}

pub fn setMaximizedOn(toplevel: *Toplevel, output: *Output) void {
    toplevel.clearZoomBoost();
    toplevel.finishZoomAnimation();
    toplevel.maximized = true;
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setMaximized(true),
        .xwayland => |*adapter| adapter.xsurface.setMaximized(true, true),
        .placeholder, .shell => {},
    }

    const usable = output.usableBox();
    if (usable.width <= 0 or usable.height <= 0) return;

    const footer = if (toplevel.hasServerDecorations()) chrome.frame_border else 0;
    const scale = toplevel.zoom();
    const width = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(usable.width)) / scale))) - 2 * toplevel.borderWidth();
    const height = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(usable.height)) / scale))) - toplevel.titlebarHeight() - footer;
    if (width <= 0 or height <= 0) return;

    const point = toplevel.server.world.toWorld(@floatFromInt(usable.x), @floatFromInt(usable.y));
    const wx: i32 = @intFromFloat(@round(point.x));
    const wy: i32 = @intFromFloat(@round(point.y));
    if (toplevel.maximize_restore == null) {
        if (!toplevel.placed and !toplevel.in_world) {
            toplevel.setupInitialRestoreGeometry(output);
        } else {
            toplevel.maximize_restore = toplevel.floatingGeometry();
        }
    }
    toplevel.dropTile();
    toplevel.maximize_target = .{ .x = wx, .y = wy, .width = width, .height = height };
    _ = toplevel.requestSizeAnimated(width, height);
    toplevel.setPositionAnimated(wx, wy);
    toplevel.scheduleForcedGeometry();

    toplevel.syncForeign();

    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
}

pub fn setFullscreenOn(toplevel: *Toplevel, output: *Output) void {
    toplevel.clearZoomBoost();
    toplevel.finishZoomAnimation();
    toplevel.fullscreen = true;
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setFullscreen(true),
        .xwayland => |*adapter| adapter.xsurface.setFullscreen(true),
        .placeholder, .shell => {},
    }

    var box: wlr.Box = undefined;
    toplevel.server.output_layout.getBox(output.wlr_output, &box);
    if (box.width <= 0 or box.height <= 0) return;

    const scale = toplevel.zoom();
    const width = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(box.width)) / scale)));
    const height = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(box.height)) / scale)));
    if (width <= 0 or height <= 0) return;
    const point = toplevel.server.world.toWorld(@floatFromInt(box.x), @floatFromInt(box.y));
    const wx: i32 = @intFromFloat(@round(point.x));
    const wy: i32 = @intFromFloat(@round(point.y));
    if (toplevel.fullscreen_restore == null) {
        if (!toplevel.placed and !toplevel.in_world) {
            toplevel.setupInitialRestoreGeometry(output);
        } else {
            toplevel.fullscreen_restore = toplevel.rememberGeometry();
        }
    }
    toplevel.fullscreen_target = .{ .x = wx, .y = wy, .width = width, .height = height };
    _ = toplevel.requestSizeAnimated(width, height);
    toplevel.setPositionAnimated(wx, wy);
    toplevel.scheduleForcedGeometry();

    toplevel.syncForeign();

    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
    toplevel.server.refreshTaskbars();
}

pub fn setMaximized(toplevel: *Toplevel, maximizing: bool) void {
    if (!maximizing) {
        toplevel.maximized = false;
        switch (toplevel.backend) {
            .xdg => |*adapter| _ = adapter.xdg_toplevel.setMaximized(false),
            .xwayland => |*adapter| adapter.xsurface.setMaximized(false, false),
            .placeholder, .shell => {},
        }
        toplevel.maximize_target = null;
        if (toplevel.maximize_restore) |saved| {
            toplevel.maximize_restore = null;
            toplevel.restoreGeometry(saved);
        }
        toplevel.syncForeign();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowChanged(ipc, toplevel);
            ipc.wait_mgr.checkAll();
        }
        return;
    }

    const geometry_box = toplevel.clientGeometry();
    const center = toplevel.frameWorld(@floatFromInt(toplevel.borderWidth() + @divTrunc(geometry_box.width, 2)), @floatFromInt(toplevel.titlebarHeight() + @divTrunc(geometry_box.height, 2)));
    const layout_center = toplevel.server.world.toLayout(center.x, center.y);
    const output = Output.atLayout(toplevel.server, layout_center.x, layout_center.y) orelse toplevel.resolveTargetOutput() orelse return;
    toplevel.setMaximizedOn(output);
}

/// Where the compositor has put the window: undo records this and keyboard
/// tiling steps from it. `maximized`, not isMaximized(): an xdg client acks
/// maximize a commit later.
pub fn layout(toplevel: *const Toplevel) tiling.Layout {
    if (toplevel.maximized) return .maximized;
    if (toplevel.tile) |tile| return .{ .tiled = tile };
    if (toplevel.auto_target != null) return .automatic;
    return .floating;
}

/// The geometry to return to when leaving maximize or a tile.
fn floatingGeometry(toplevel: *const Toplevel) RestoreGeometry {
    return toplevel.tile_restore orelse toplevel.auto_restore orelse toplevel.rememberGeometry();
}

pub fn setTiled(toplevel: *Toplevel, tile: tiling.Tile) void {
    const output = toplevel.currentOutput() orelse return;
    toplevel.setTiledOn(output, tile);
}

/// Fit the frame to `tile` of the output's usable area. A maximized window
/// hands its restore geometry to the tile.
pub fn setTiledOn(toplevel: *Toplevel, output: *Output, tile: tiling.Tile) void {
    toplevel.clearZoomBoost();
    if (!toplevel.in_world or toplevel.isFullscreen()) return;
    toplevel.finishZoomAnimation();
    const usable = output.usableBox();
    if (usable.width <= 0 or usable.height <= 0) return;

    const rect = tiling.tileRect(usable, tile, toplevel.server.config.compositor.windowGap());
    // cornerRadius() still reads maximized until an xdg client acks leaving it.
    const footer = if (toplevel.hasServerDecorations()) chrome.frame_border else 0;
    const scale = toplevel.zoom();
    const width = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(rect.width)) / scale))) - 2 * toplevel.borderWidth();
    const height = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(rect.height)) / scale))) - toplevel.titlebarHeight() - footer;
    if (width <= 0 or height <= 0) return;

    const point = toplevel.server.world.toWorld(@floatFromInt(rect.x), @floatFromInt(rect.y));
    const wx: i32 = @intFromFloat(@round(point.x));
    const wy: i32 = @intFromFloat(@round(point.y));
    if (toplevel.maximized or toplevel.isMaximized()) {
        toplevel.tile_restore = toplevel.maximize_restore orelse toplevel.tile_restore;
        toplevel.clearMaximized();
    } else if (toplevel.tile_restore == null) {
        toplevel.tile_restore = toplevel.rememberGeometry();
    }
    @import("auto_tiling.zig").setFloating(toplevel, true);
    toplevel.tile = tile;
    toplevel.tile_target = .{ .x = wx, .y = wy, .width = width, .height = height };
    toplevel.sendTiled(tiling.tiledEdges(tile));
    _ = toplevel.requestSizeAnimated(width, height);
    toplevel.setPositionAnimated(wx, wy);
    toplevel.scheduleForcedGeometry();
    toplevel.notifyLayoutChanged();
}

/// Arbitrary automatic frame rectangle. Only changed targets configure a client;
/// replies to an earlier configure never trigger another layout pass.
/// `animate` glides the frame to the tile like other compositor-owned geometry;
/// a window still opening takes its first tile at once.
pub fn setAutoTile(toplevel: *Toplevel, rect: wlr.Box, animate: bool) void {
    if (!toplevel.in_world or toplevel.fullscreen or toplevel.maximized) return;
    const footer = if (toplevel.hasServerDecorations()) chrome.frame_border else 0;
    const target: RestoreGeometry = .{
        .x = rect.x,
        .y = rect.y,
        .width = @max(1, rect.width - 2 * toplevel.borderWidth()),
        .height = @max(1, rect.height - toplevel.titlebarHeight() - footer),
    };
    // An unchanged tile keeps a glide in flight (an earlier reflow, a restore).
    if (toplevel.auto_target) |previous| if (std.meta.eql(previous, target)) return;
    const was_tiled = toplevel.auto_target != null;
    const glide = animate and (was_tiled or !toplevel.map_motion.active());
    if (!glide) toplevel.finishSizeAnimation();
    if (toplevel.auto_restore == null) toplevel.auto_restore = toplevel.rememberGeometry();
    toplevel.auto_target = target;
    toplevel.pending_restore = null;
    toplevel.clearZoomBoost();
    if (!was_tiled) toplevel.sendTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    const moved = toplevel.x != target.x or toplevel.y != target.y;
    // X11 sends position and size together: commitPosition uses auto_target,
    // never the old client buffer size, and already configures a moved window.
    if (glide) toplevel.setPositionAnimated(target.x, target.y) else toplevel.setPosition(target.x, target.y);
    const wait: ConfigureWait = if (toplevel.backend != .xwayland or !moved) toplevel.requestSize(target.width, target.height) else .x11_commit;
    if (glide) toplevel.animateChromeSize(target.width, target.height, wait);
    toplevel.notifyLayoutChanged();
}

pub fn clearAutoTile(toplevel: *Toplevel, restore_floating: bool) void {
    if (toplevel.auto_target == null) return;
    const saved = toplevel.auto_restore;
    toplevel.auto_target = null;
    toplevel.auto_restore = null;
    if (toplevel.tile == null) toplevel.sendTiled(.{});
    if (restore_floating and !toplevel.fullscreen and !toplevel.maximized) {
        if (saved) |geom| {
            var floating = geom;
            const constraints = toplevel.sizeConstraints();
            floating.width = @max(floating.width, @max(1, constraints.min_width));
            floating.height = @max(floating.height, @max(1, constraints.min_height));
            if (constraints.max_width > 0) floating.width = @min(floating.width, constraints.max_width);
            if (constraints.max_height > 0) floating.height = @min(floating.height, constraints.max_height);
            toplevel.restoreGeometryNow(floating);
        }
    }
    toplevel.notifyLayoutChanged();
}

/// Return a tiled window to its floating geometry.
pub fn untile(toplevel: *Toplevel) void {
    if (toplevel.auto_target != null) {
        const saved = toplevel.auto_restore;
        @import("auto_tiling.zig").setFloating(toplevel, true);
        if (saved) |geom| toplevel.restoreGeometry(geom);
        return;
    }
    if (toplevel.tile == null) return;
    const saved = toplevel.tile_restore;
    toplevel.dropTile();
    if (saved) |geom| toplevel.restoreGeometry(geom);
    toplevel.notifyLayoutChanged();
}

/// Leave maximize or a tile without moving; the caller places the window
/// (a drag carrying it off, an interactive resize, undo).
pub fn leaveLayout(toplevel: *Toplevel) void {
    @import("auto_tiling.zig").setFloating(toplevel, true);
    if (!toplevel.maximized and !toplevel.isMaximized() and toplevel.tile == null) return;
    toplevel.clearMaximized();
    toplevel.dropTile();
    toplevel.notifyLayoutChanged();
}

/// Keyboard tiling and undo: go to `target` from wherever the window is.
pub fn applyLayout(toplevel: *Toplevel, target: tiling.Layout) void {
    if (toplevel.isFullscreen() or toplevel.layout().eql(target)) return;
    switch (target) {
        .floating => if (toplevel.maximized) toplevel.setMaximized(false) else toplevel.untile(),
        .maximized => toplevel.setMaximized(true),
        .tiled => |tile| toplevel.setTiled(tile),
        .automatic => {
            toplevel.clearMaximized();
            toplevel.dropTile();
            @import("auto_tiling.zig").setFloating(toplevel, false);
        },
    }
}

/// Drop a dragged window into `target` on `output`. `floating` is its
/// geometry from before the drag, so leaving the snap returns it there.
pub fn snapTo(toplevel: *Toplevel, output: *Output, target: tiling.Target, floating: ?RestoreGeometry) void {
    if (toplevel.layout() == .floating) {
        if (floating) |geom| toplevel.tile_restore = geom;
    }
    switch (target) {
        .maximize => toplevel.setMaximizedOn(output),
        .tile => |tile| toplevel.setTiledOn(output, tile),
    }
}

fn clearMaximized(toplevel: *Toplevel) void {
    if (!toplevel.maximized and !toplevel.isMaximized()) return;
    toplevel.maximized = false;
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setMaximized(false),
        .xwayland => |*adapter| adapter.xsurface.setMaximized(false, false),
        .placeholder, .shell => {},
    }
    toplevel.maximize_target = null;
    toplevel.maximize_restore = null;
}

/// Forget the tile (and any restore hint) without moving the window.
fn dropTile(toplevel: *Toplevel) void {
    const was_tiled = toplevel.tile != null;
    toplevel.tile = null;
    toplevel.tile_target = null;
    toplevel.tile_restore = null;
    if (was_tiled) toplevel.sendTiled(.{});
}

pub fn sendTiled(toplevel: *Toplevel, edges: wlr.Edges) void {
    if (toplevel.backend_gone) return;
    switch (toplevel.backend) {
        // wlroots asserts an xdg_wm_base of version 2 or later (Shell.zig).
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setTiled(edges),
        .xwayland, .placeholder, .shell => {},
    }
}

fn notifyLayoutChanged(toplevel: *Toplevel) void {
    toplevel.syncForeign();
    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
}

pub fn setFullscreen(toplevel: *Toplevel, fullscreen: bool) void {
    if (toplevel.fullscreen != fullscreen) {
        toplevel.toggleFullscreen();
    }
}

pub fn toggleFullscreen(toplevel: *Toplevel) void {
    // Use compositor intent: a second toggle may precede the client ack.
    const next = !toplevel.fullscreen;
    if (!next) {
        toplevel.fullscreen = false;
        switch (toplevel.backend) {
            .xdg => |*adapter| _ = adapter.xdg_toplevel.setFullscreen(false),
            .xwayland => |*adapter| adapter.xsurface.setFullscreen(false),
            .placeholder, .shell => {},
        }
        toplevel.fullscreen_target = null;
        if (toplevel.fullscreen_restore) |saved| {
            toplevel.fullscreen_restore = null;
            toplevel.restoreGeometry(saved);
        }
        toplevel.syncForeign();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowChanged(ipc, toplevel);
            ipc.wait_mgr.checkAll();
        }
        toplevel.server.refreshTaskbars();
        return;
    }

    const center = toplevel.frameWorld(@floatFromInt(@divTrunc(toplevel.chrome_width, 2)), @floatFromInt(@divTrunc(toplevel.chrome_height, 2)));
    const layout_center = toplevel.server.world.toLayout(center.x, center.y);
    const output = Output.atLayout(toplevel.server, layout_center.x, layout_center.y) orelse toplevel.resolveTargetOutput() orelse return;
    toplevel.setFullscreenOn(output);
}

pub fn beginMove(toplevel: *Toplevel) void {
    toplevel.server.input.startMove(toplevel);
}

pub fn handleIdentityChanged(toplevel: *Toplevel) void {
    const prev_rules = toplevel.live_rules;
    const new_id = toplevel.currentIdentity();

    if (toplevel.rules_resolved) {
        if (toplevel.resolved_before_app_id and new_id.app_id.len > 0) {
            const hyp = window_rules.resolve(toplevel.server.config.window_rules, new_id);
            const hyp_open = window_rules.OpenRules.fromResolved(hyp);
            if (!hyp_open.eql(toplevel.open_rules)) {
                log.debug("window '{s}' ({s}) identity changed after open-time rules resolved; open-time rules would have differed", .{ toplevel.appId(), toplevel.title() });
            }
        }
        const resolved = window_rules.resolve(toplevel.server.config.window_rules, new_id);
        toplevel.live_rules = window_rules.LiveRules.fromResolved(resolved);
        toplevel.matched_rules = resolved.matched_rules;
    }

    if (toplevel.live_rules.opacity != prev_rules.opacity) {
        @import("config_runtime/apply.zig").applyWindowOpacity(toplevel.server);
    }
    if (toplevel.live_rules.decorations != prev_rules.decorations) {
        if (toplevel.decoration) |d| d.applyMode();
        if (toplevel.kde_decoration) |d| d.applyMode(false);
        toplevel.syncChrome(true, nowMs()) catch {};
    }

    if (toplevel.in_world) if (toplevel.server.layout_autosave) |autosave| {
        autosave.mapped(toplevel);
        autosave.finishMapped(toplevel);
    };
    @import("auto_tiling.zig").observe(toplevel);
    toplevel.server.window_tabs.reconcile(toplevel);
    if (toplevel.tab_hidden) {
        if (@import("window_tabs.zig").active(toplevel.server, toplevel.tab_group)) |active_tab| active_tab.syncChrome(false, nowMs()) catch {};
    }
    toplevel.syncChrome(true, nowMs()) catch |err| {
        log.err("handleIdentityChanged: could not update window title: {}", .{err});
    };
    if (toplevel.foreign_handle) |handle| {
        if (toplevel.backend == .xdg) {
            handle.updateState(&.{
                .title = toplevel.backend.xdg.xdg_toplevel.title,
                .app_id = toplevel.backend.xdg.xdg_toplevel.app_id,
            });
        }
    }
    toplevel.server.refreshTaskbars();
    toplevel.syncForeign();
    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
}

pub fn tabStrip(toplevel: *Toplevel, storage: *[@import("window_tabs.zig").max_tabs]@import("chrome_tabs.zig").Tab) @import("chrome_tabs.zig").Strip {
    var members_storage: [@import("window_tabs.zig").max_tabs]*Toplevel = undefined;
    const members = @import("window_tabs.zig").members(toplevel, &members_storage);
    var selected: usize = 0;
    for (members, 0..) |member, i| {
        storage[i] = .{ .id = member.id, .title = member.title(), .active = member == toplevel, .attention = member.needs_attention };
        if (member == toplevel) selected = i;
    }
    var strip: @import("chrome_tabs.zig").Strip = .{ .tabs = storage[0..members.len], .first = toplevel.tab_first, .hover = toplevel.tab_hover, .notice = toplevel.tab_notice };
    const geom = @import("chrome_tabs.zig").geometry(toplevel.chrome_width, toplevel.chromeDensity(), strip);
    if (selected < strip.first) strip.first = selected;
    if (selected >= strip.first + geom.count) strip.first = selected + 1 -| geom.count;
    toplevel.tab_first = strip.first;
    return strip;
}

pub fn tabAt(toplevel: *Toplevel, x: f64, y: f64) @import("chrome_tabs.zig").Hit {
    if (!toplevel.hasServerDecorations() or toplevel.tab_group == 0) return .none;
    var storage: [@import("window_tabs.zig").max_tabs]@import("chrome_tabs.zig").Tab = undefined;
    return @import("chrome_tabs.zig").hit(toplevel.chrome_width, toplevel.chromeDensity(), toplevel.tabStrip(&storage), x, y);
}

pub fn hoverTab(toplevel: *Toplevel, x: f64, y: f64) void {
    const next = @import("chrome_tabs.zig").key(toplevel.tabAt(x, y));
    if (next == toplevel.tab_hover) return;
    toplevel.tab_hover = next;
    toplevel.syncChrome(false, nowMs()) catch {};
}

pub fn stepTab(toplevel: *Toplevel, forward: bool) void {
    var storage: [@import("window_tabs.zig").max_tabs]*Toplevel = undefined;
    const members = @import("window_tabs.zig").members(toplevel, &storage);
    if (members.len < 2) return;
    for (members, 0..) |member, i| {
        if (member != toplevel) continue;
        const next = if (forward) (i + 1) % members.len else (i + members.len - 1) % members.len;
        toplevel.server.world.focus(members[next]);
        return;
    }
}
