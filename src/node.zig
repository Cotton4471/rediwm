//! The compositor's own scene nodes (node.h): what wlr.Scene* was as a data model.
//! Method names are wlr_scene's, so a call site changes its type and little else.
//!
//! A client's surfaces are still wlr_scene trees (stage 7b replaces that): they live
//! under the scene's hidden host and an own `Foreign` node places them.
const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const pixman = @import("pixman");
const wlr = @import("wlroots");

pub const Node = extern struct {
    pub const Type = enum(c_int) { tree, rect, buffer, foreign };

    type: Type,
    parent: ?*Tree,
    link: wl.list.Link,
    enabled: bool,
    x: c_int,
    y: c_int,
    data: ?*anyopaque,
    events: extern struct {
        destroy: wl.Signal(void),
    },
    addons: wlr.AddonSet,
    scene: *Scene,

    extern fn rediwm_node_destroy(node: *Node) void;
    pub const destroy = rediwm_node_destroy;
    extern fn rediwm_node_set_enabled(node: *Node, enabled: bool) void;
    pub const setEnabled = rediwm_node_set_enabled;
    extern fn rediwm_node_set_position(node: *Node, x: c_int, y: c_int) void;
    pub const setPosition = rediwm_node_set_position;
    extern fn rediwm_node_raise_to_top(node: *Node) void;
    pub const raiseToTop = rediwm_node_raise_to_top;
    extern fn rediwm_node_lower_to_bottom(node: *Node) void;
    pub const lowerToBottom = rediwm_node_lower_to_bottom;
    extern fn rediwm_node_place_above(node: *Node, sibling: *Node) void;
    pub const placeAbove = rediwm_node_place_above;
    extern fn rediwm_node_place_below(node: *Node, sibling: *Node) void;
    pub const placeBelow = rediwm_node_place_below;
    extern fn rediwm_node_reparent(node: *Node, parent: *Tree) void;
    pub const reparent = rediwm_node_reparent;
    extern fn rediwm_node_coords(node: *Node, lx: *c_int, ly: *c_int) bool;
    pub const coords = rediwm_node_coords;
    extern fn rediwm_node_visible(node: *const Node) bool;
    /// Whether the node and every ancestor are enabled.
    pub const visible = rediwm_node_visible;

    extern fn rediwm_node_for_each_buffer(
        node: *Node,
        iterator: *const fn (buffer: *Buffer, sx: c_int, sy: c_int, data: ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
    ) void;
    /// The own buffers of the subtree, positions relative to this node.
    pub inline fn forEachBuffer(
        node: *Node,
        comptime T: type,
        comptime iterator: fn (buffer: *Buffer, sx: c_int, sy: c_int, data: T) void,
        data: T,
    ) void {
        rediwm_node_for_each_buffer(
            node,
            struct {
                fn wrapper(b: *Buffer, sx: c_int, sy: c_int, d: ?*anyopaque) callconv(.c) void {
                    iterator(b, sx, sy, @ptrCast(@alignCast(d)));
                }
            }.wrapper,
            data,
        );
    }

    extern fn rediwm_node_for_each_wlr_buffer(
        node: *Node,
        iterator: *const fn (buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, data: ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
    ) void;
    /// The wlr_scene buffers of the clients' surfaces under this node, positions
    /// relative to it.
    pub inline fn forEachSurfaceBuffer(
        node: *Node,
        comptime T: type,
        comptime iterator: fn (buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, data: T) void,
        data: T,
    ) void {
        rediwm_node_for_each_wlr_buffer(
            node,
            struct {
                fn wrapper(b: *wlr.SceneBuffer, sx: c_int, sy: c_int, d: ?*anyopaque) callconv(.c) void {
                    iterator(b, sx, sy, @ptrCast(@alignCast(d)));
                }
            }.wrapper,
            data,
        );
    }

    /// The foreign node this is, if it is one.
    pub fn foreign(node: *Node) ?*Foreign {
        return if (node.type == .foreign) @fieldParentPtr("node", node) else null;
    }
    pub fn tree(node: *Node) ?*Tree {
        return if (node.type == .tree) @fieldParentPtr("node", node) else null;
    }
};

pub const Tree = extern struct {
    node: Node,
    children: wl.list.Head(Node, .link),

    extern fn rediwm_tree_create(parent: *Tree) ?*Tree;
    pub fn createSceneTree(parent: *Tree) !*Tree {
        return rediwm_tree_create(parent) orelse error.OutOfMemory;
    }

    extern fn rediwm_rect_create(parent: *Tree, width: c_int, height: c_int, color: *const [4]f32) ?*Rect;
    pub fn createSceneRect(parent: *Tree, width: c_int, height: c_int, color: *const [4]f32) !*Rect {
        return rediwm_rect_create(parent, width, height, color) orelse error.OutOfMemory;
    }

    extern fn rediwm_buffer_create(parent: *Tree, buffer: ?*wlr.Buffer) ?*Buffer;
    pub fn createSceneBuffer(parent: *Tree, buffer: ?*wlr.Buffer) !*Buffer {
        return rediwm_buffer_create(parent, buffer) orelse error.OutOfMemory;
    }

    extern fn rediwm_foreign_create(parent: *Tree, wlr_node: *wlr.SceneNode) ?*Foreign;
    extern fn rediwm_tree_host(tree: *const Tree) *wlr.SceneTree;
    /// The hidden wlr_scene tree that holds the clients' surface trees.
    pub const host = rediwm_tree_host;

    /// A hosted subtree's root keeps its foreign node in its `data`, so a hit inside
    /// it finds its way back to the own tree.
    fn adopt(parent: *Tree, tree: *wlr.SceneTree) !*Foreign {
        const foreign = rediwm_foreign_create(parent, &tree.node) orelse {
            tree.node.destroy();
            return error.OutOfMemory;
        };
        tree.node.data = foreign;
        return foreign;
    }

    pub fn createSceneXdgSurface(parent: *Tree, xdg_surface: *wlr.XdgSurface) !*Foreign {
        return adopt(parent, try rediwm_tree_host(parent).createSceneXdgSurface(xdg_surface));
    }

    pub fn createSceneSubsurfaceTree(parent: *Tree, surface: *wlr.Surface) !*Foreign {
        return adopt(parent, try rediwm_tree_host(parent).createSceneSubsurfaceTree(surface));
    }

    pub fn createSceneDragIcon(parent: *Tree, drag_icon: *wlr.Drag.Icon) !*Foreign {
        return adopt(parent, try rediwm_tree_host(parent).createSceneDragIcon(drag_icon));
    }

    /// The layer surface's wlr_scene tree is hosted like any client's; the foreign
    /// node places it, and the wlr tree's own position is the layer shell's.
    pub fn createSceneLayerSurfaceV1(parent: *Tree, layer_surface: *wlr.LayerSurfaceV1) !struct { scene: *wlr.SceneLayerSurfaceV1, foreign: *Foreign } {
        const scene = try rediwm_tree_host(parent).createSceneLayerSurfaceV1(layer_surface);
        return .{ .scene = scene, .foreign = try adopt(parent, scene.tree) };
    }

    pub fn fromNode(node: *Node) *Tree {
        return @fieldParentPtr("node", node);
    }
};

pub const Rect = extern struct {
    node: Node,
    width: c_int,
    height: c_int,
    color: [4]f32,
    carrier: *wlr.SceneRect,

    extern fn rediwm_rect_set_color(rect: *Rect, color: *const [4]f32) void;
    pub const setColor = rediwm_rect_set_color;
    extern fn rediwm_rect_set_size(rect: *Rect, width: c_int, height: c_int) void;
    pub const setSize = rediwm_rect_set_size;

    pub fn fromNode(node: *Node) *Rect {
        return @fieldParentPtr("node", node);
    }
};

pub const Buffer = extern struct {
    node: Node,
    /// The hidden wlr_scene buffer that carries the pixels (see node.h).
    carrier: *wlr.SceneBuffer,
    point_accepts_input: ?*const fn (buffer: *Buffer, sx: *f64, sy: *f64) callconv(.c) bool,
    opacity: f32,
    filter_mode: wlr.RenderPass.ScaleFilterMode,
    src_box: wlr.FBox,
    dst_width: c_int,
    dst_height: c_int,
    transform: wl.Output.Transform,
    opaque_region: pixman.Region32,
    buffer_width: c_int,
    buffer_height: c_int,

    extern fn rediwm_buffer_set_buffer(buffer: *Buffer, wlr_buffer: ?*wlr.Buffer) void;
    pub const setBuffer = rediwm_buffer_set_buffer;
    extern fn rediwm_buffer_get_buffer(buffer: *const Buffer) ?*wlr.Buffer;
    /// The buffer the carrier holds; null once the renderer released it after upload.
    pub const getBuffer = rediwm_buffer_get_buffer;
    extern fn rediwm_buffer_set_buffer_with_damage(buffer: *Buffer, wlr_buffer: ?*wlr.Buffer, damage: *const pixman.Region32) void;
    pub const setBufferWithDamage = rediwm_buffer_set_buffer_with_damage;
    extern fn rediwm_buffer_set_dest_size(buffer: *Buffer, width: c_int, height: c_int) void;
    pub const setDestSize = rediwm_buffer_set_dest_size;
    extern fn rediwm_buffer_set_source_box(buffer: *Buffer, box: ?*const wlr.FBox) void;
    pub const setSourceBox = rediwm_buffer_set_source_box;
    extern fn rediwm_buffer_set_opacity(buffer: *Buffer, opacity: f32) void;
    pub const setOpacity = rediwm_buffer_set_opacity;
    extern fn rediwm_buffer_set_filter_mode(buffer: *Buffer, mode: wlr.RenderPass.ScaleFilterMode) void;
    pub const setFilterMode = rediwm_buffer_set_filter_mode;
    extern fn rediwm_buffer_set_transform(buffer: *Buffer, transform: wl.Output.Transform) void;
    pub const setTransform = rediwm_buffer_set_transform;
    extern fn rediwm_buffer_set_opaque_region(buffer: *Buffer, region: ?*const pixman.Region32) void;
    pub const setOpaqueRegion = rediwm_buffer_set_opaque_region;

    pub fn fromNode(node: *Node) *Buffer {
        return @fieldParentPtr("node", node);
    }
};

/// A wlr_scene subtree hosted under an own tree.
pub const Foreign = extern struct {
    node: Node,
    /// Null once wlroots has destroyed the subtree (this node goes with it).
    wlr: ?*wlr.SceneNode,
    wlr_destroy: wl.Listener(void),

    pub fn tree(foreign: *Foreign) *wlr.SceneTree {
        return wlr.SceneTree.fromNode(foreign.wlr.?);
    }

    /// The foreign node whose subtree holds this wlr node (a root's `data`).
    pub fn of(wlr_node: *wlr.SceneNode) ?*Foreign {
        var current: *wlr.SceneNode = wlr_node;
        while (true) {
            if (current.data) |data| return @ptrCast(@alignCast(data));
            current = if (current.parent) |parent| &parent.node else return null;
        }
    }

    /// Clips the hosted surface tree, as wlr_scene_subsurface_tree_set_clip.
    pub fn subsurfaceTreeSetClip(foreign: *Foreign, clip: ?*const wlr.Box) void {
        wlr.SceneNode.subsurfaceTreeSetClip(foreign.wlr.?, clip);
    }

    pub fn fromNode(node: *Node) *Foreign {
        return @fieldParentPtr("node", node);
    }
};

/// The own scene: its root tree's children are the layers, bottom to top.
pub const Scene = extern struct {
    tree: Tree,
    host: *wlr.SceneTree,
    changed: ?*const fn (data: ?*anyopaque) callconv(.c) void,
    changed_data: ?*anyopaque,

    extern fn rediwm_scene_create(host: *wlr.SceneTree, changed: ?*const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) ?*Scene;
    /// `host` is a hidden, disabled wlr_scene tree for the carriers and the
    /// clients' subtrees.
    pub fn create(host: *wlr.SceneTree) !*Scene {
        return rediwm_scene_create(host, null, null) orelse error.OutOfMemory;
    }
    extern fn rediwm_scene_destroy(scene: ?*Scene) void;
    pub const destroy = rediwm_scene_destroy;
};

/// Where a node inside a client's subtree is in the scene's root, and whether the
/// own nodes above it are enabled: the hosting node's place plus the wlr_scene offsets
/// down to it.
pub fn wlrCoords(wlr_node: *wlr.SceneNode, lx: *c_int, ly: *c_int) bool {
    var x: c_int = 0;
    var y: c_int = 0;
    var current: *wlr.SceneNode = wlr_node;
    while (true) {
        x += current.x;
        y += current.y;
        if (current.data != null) break;
        current = if (current.parent) |parent| &parent.node else {
            lx.* = x;
            ly.* = y;
            return false;
        };
    }
    const foreign: *Foreign = @ptrCast(@alignCast(current.data.?));
    var ox: c_int = 0;
    var oy: c_int = 0;
    const enabled = foreign.node.coords(&ox, &oy);
    lx.* = ox + x;
    ly.* = oy + y;
    return enabled;
}

/// A scene for unit tests: a wlroots scene with the own scene's hidden host in it.
pub const TestScene = struct {
    wlr_scene: *wlr.Scene,
    nodes: *Scene,

    pub fn create() !TestScene {
        const wlr_scene = try wlr.Scene.create();
        errdefer wlr_scene.tree.node.destroy();
        const host = try wlr_scene.tree.createSceneTree();
        host.node.setEnabled(false);
        return .{ .wlr_scene = wlr_scene, .nodes = try Scene.create(host) };
    }

    pub fn destroy(fixture: TestScene) void {
        fixture.nodes.destroy();
        fixture.wlr_scene.tree.node.destroy();
    }
};
