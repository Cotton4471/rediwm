const std = @import("std");
const wlr = @import("wlroots");
pub const Projection = opaque {
    extern fn rediwm_projection_create(source: *wlr.SceneTree, scene: *wlr.Scene) ?*Projection;
    pub const create = rediwm_projection_create;
    extern fn rediwm_projection_watch(projection: *Projection, compositor: *wlr.Compositor) void;
    pub const watch = rediwm_projection_watch;
    extern fn rediwm_projection_destroy(projection: ?*Projection) void;
    pub const destroy = rediwm_projection_destroy;
    extern fn rediwm_projection_sync(projection: ?*Projection, zoom: f64, cx: f64, cy: f64, ox: f64, oy: f64) void;
    pub const sync = rediwm_projection_sync;
    extern fn rediwm_projection_sync_fixed(projection: ?*Projection, zoom: f64, cx: f64, cy: f64, ox: f64, oy: f64, fixed: ?*wlr.SceneTree) void;
    pub const syncFixed = rediwm_projection_sync_fixed;
    extern fn rediwm_projection_damage_buffer(projection: *Projection, source: *wlr.SceneNode, damage: ?*const @import("pixman").Region32) void;
    /// Buffer-local damage for the buffer just set on a compositor-owned
    /// source node; null damages all of it.
    pub const damageBuffer = rediwm_projection_damage_buffer;
    extern fn rediwm_projection_present_owned(projection: *Projection, source: *wlr.SceneBuffer, renderer: *wlr.Renderer, buffer: *wlr.Buffer, damage: ?*const @import("pixman").Region32) bool;
    /// Sets `buffer` on a compositor-owned source node, updating the texture
    /// in place with `damage` when the renderer allows; null replaces all.
    /// The caller may drop `buffer` afterwards. True when updated in place.
    pub const presentOwned = rediwm_projection_present_owned;
    extern fn rediwm_projection_node_at(projection: *Projection, lx: f64, ly: f64, nx: ?*f64, ny: ?*f64) ?*wlr.SceneNode;
    /// The topmost node at a layout point (a source node for the world), and
    /// the point in the node's own coordinates.
    pub const nodeAt = rediwm_projection_node_at;
    extern fn rediwm_projection_send_frame_done(projection: *Projection, output: *wlr.SceneOutput, now: *std.posix.timespec) void;
    /// Frame callbacks of the world's client surfaces for one output, beside
    /// `wlr.SceneOutput.sendFrameDone`, which reaches the layout trees only.
    pub const sendFrameDone = rediwm_projection_send_frame_done;
};
extern fn rediwm_projection_set_tree_zoom(node: *wlr.SceneNode, scale: f64) bool;
pub const setTreeZoom = rediwm_projection_set_tree_zoom;
extern fn rediwm_projection_set_tree_scale(node: *wlr.SceneNode, factor: f64) bool;
pub const setTreeScale = rediwm_projection_set_tree_scale;

/// One rounded-rectangle shape for every leaf under a tree (see scene_graph.h):
/// source units, anchored at the tree's origin. `border_color` is premultiplied,
/// with the window's opacity applied.
pub const ClipSpec = extern struct {
    width: c_int,
    height: c_int,
    /// Top-left, top-right, bottom-right, bottom-left.
    radii: [4]f64,
    border: f64,
    border_color: [4]f32,
};
extern fn rediwm_projection_set_tree_clip(node: *wlr.SceneNode, spec: ?*const ClipSpec) bool;
/// A null spec removes the clip. False for a size that is not positive or a
/// radius, border or colour that is negative or not finite.
pub fn setTreeClip(node: *wlr.SceneNode, spec: ?ClipSpec) bool {
    if (spec) |value| return rediwm_projection_set_tree_clip(node, &value);
    return rediwm_projection_set_tree_clip(node, null);
}
/// The analytic drop shadow of a window's shape (see scene_graph.h): every leaf
/// under the tree draws it in the owned pass. `width`, `height` and `radii` are
/// the shape it is kept out of, in source units at the tree's origin; `color` is
/// premultiplied.
pub const ShadowSpec = extern struct {
    width: c_int,
    height: c_int,
    radii: [4]f64,
    offset_x: f64,
    offset_y: f64,
    softness: f64,
    color: [4]f32,
};
extern fn rediwm_projection_set_tree_shadow(node: *wlr.SceneNode, spec: ?*const ShadowSpec) bool;
/// A null spec removes the shadow. False for a size that is not positive or a
/// radius or softness that is negative or not finite.
pub fn setTreeShadow(node: *wlr.SceneNode, spec: ?ShadowSpec) bool {
    if (spec) |value| return rediwm_projection_set_tree_shadow(node, &value);
    return rediwm_projection_set_tree_shadow(node, null);
}
/// Ends the clip inherited from an ancestor for this subtree: an xdg popup or a
/// window's shadow hangs under the window's tree but is no part of its shape.
extern fn rediwm_projection_set_tree_unclipped(node: *wlr.SceneNode, unclipped: bool) bool;
pub const setTreeUnclipped = rediwm_projection_set_tree_unclipped;
/// Shows the subtree but lets the pick pass through it to what is below: a
/// window sliding off the workspace it has left.
extern fn rediwm_projection_set_tree_inert(node: *wlr.SceneNode, inert: bool) bool;
pub const setTreeInert = rediwm_projection_set_tree_inert;
