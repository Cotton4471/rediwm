// The compositor's own scene nodes (stage 7 of docs/plans/scene-graph-stage7.md).
//
// What wlr_scene gave the compositor as a data model: a tree of nodes with a
// position, an enabled flag and an owner pointer, whose leaves are buffers or
// rectangles. It does no drawing, damage or picking here; the projection resolves
// the tree into items and the output pass draws them. Every mutator that can change
// what the tree shows reports it through the scene's `changed` hook, which asks for
// a frame; the projection then finds what moved by comparing items, as it does for
// the world today.
//
// Field names follow wlr_scene on purpose: the projection and the pass read the
// same members under the same names, and the Zig wrapper keeps wlr_scene's method
// names, so a call site changes by type, not by shape.
//
// Single-threaded, like the rest of the compositor.
#pragma once
#include <pixman.h>
#include <stdbool.h>
#include <stdint.h>
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>
#include <wlr/render/pass.h>
#include <wlr/util/addon.h>
#include <wlr/util/box.h>

struct wlr_buffer;
struct wlr_scene_buffer;
struct wlr_scene_rect;
struct wlr_scene_tree;
struct rediwm_scene;
struct rediwm_tree;

enum rediwm_node_type {
  REDIWM_NODE_TREE,
  REDIWM_NODE_RECT,
  REDIWM_NODE_BUFFER,
};

struct rediwm_node {
  enum rediwm_node_type type;
  struct rediwm_tree *parent; // NULL for a scene's root
  struct wl_list link;        // in parent->children, bottom to top
  bool enabled;
  int x, y; // relative to the parent
  void *data;
  struct {
    struct wl_signal destroy;
  } events;
  struct wlr_addon_set addons;
  // The projection's per-node state, found without a walk of `addons` on every sync:
  // a tree's presentation properties and the group a top-level node is.
  void *props, *group;
  struct rediwm_scene *scene;
};

struct rediwm_tree {
  struct rediwm_node node;
  struct wl_list children; // rediwm_node.link, bottom to top
};

struct rediwm_rect {
  struct rediwm_node node;
  int width, height;
  float color[4]; // premultiplied, as wlr_scene_rect
  // The hidden wlr_scene rect the output pass reads the colour from, kept in step.
  struct wlr_scene_rect *carrier;
};

struct rediwm_buffer;
struct rediwm_surface;
typedef bool (*rediwm_buffer_point_accepts_input)(struct rediwm_buffer *, double *x, double *y);

// Geometry and content state live here; the pixels themselves (the locked buffer,
// its texture, wait points, single-pixel colour) are carried by a hidden wlr_scene
// buffer the output pass already knows how to read. Every setter keeps the two in
// step. Stage 7c replaces the carrier with the pass's own texture cache.
struct rediwm_buffer {
  struct rediwm_node node;
  struct wlr_scene_buffer *carrier;
  rediwm_buffer_point_accepts_input point_accepts_input; // may be NULL
  float opacity;
  enum wlr_scale_filter_mode filter_mode;
  struct wlr_fbox src_box;
  int dst_width, dst_height;
  enum wl_output_transform transform;
  pixman_region32_t opaque_region;
  // The size of the buffer as last set, kept for when the renderer releases it.
  int buffer_width, buffer_height;
  // The client surface this node shows, or NULL (node_surface.h).
  struct rediwm_surface *surface;
};

struct rediwm_scene {
  struct rediwm_tree tree;
  // A hidden, disabled wlr_scene tree that hosts every buffer's carrier, so wlroots
  // computes nothing for them.
  struct wlr_scene_tree *host;
  // Something the tree shows may have changed: the owner schedules a frame.
  // `node` is the one that changed (NULL when it is gone); `structural` when nodes
  // were made, moved, stacked or destroyed, or a layer changed.
  void (*changed)(void *data, struct rediwm_node *node, bool structural);
  // A buffer node was given a buffer (set_buffer, set_buffer_with_damage): the
  // buffer-local `damage` of what differs, or NULL for all of it. The projection turns
  // this into screen damage, as wlroots did for the nodes it tracked.
  void (*buffer_damaged)(void *data, struct rediwm_buffer *, const pixman_region32_t *damage);
  void *changed_data;
};

static inline struct rediwm_tree *rediwm_tree_from_node(struct rediwm_node *node) {
  return node->type == REDIWM_NODE_TREE ? (struct rediwm_tree *)node : NULL;
}
static inline struct rediwm_rect *rediwm_rect_from_node(struct rediwm_node *node) {
  return node->type == REDIWM_NODE_RECT ? (struct rediwm_rect *)node : NULL;
}
static inline struct rediwm_buffer *rediwm_buffer_from_node(struct rediwm_node *node) {
  return node->type == REDIWM_NODE_BUFFER ? (struct rediwm_buffer *)node : NULL;
}

// A scene is its root tree. `host` is where carriers live (the caller disables it); `changed` may be NULL.
struct rediwm_scene *rediwm_scene_create(struct wlr_scene_tree *host,
                                         void (*changed)(void *, struct rediwm_node *, bool),
                                         void *data);
void rediwm_scene_destroy(struct rediwm_scene *);

// Children are created enabled, at (0, 0), on top of their siblings. NULL on
// allocation failure.
struct rediwm_tree *rediwm_tree_create(struct rediwm_tree *parent);
struct rediwm_rect *rediwm_rect_create(struct rediwm_tree *parent, int width, int height,
                                       const float color[4]);
struct rediwm_buffer *rediwm_buffer_create(struct rediwm_tree *parent, struct wlr_buffer *);
// Where the scene's carriers are made.
struct wlr_scene_tree *rediwm_tree_host(const struct rediwm_tree *);

// Destroys the node and everything under it; each node emits events.destroy first.
void rediwm_node_destroy(struct rediwm_node *);
// Reports a change the node's setters cannot see: asks for a frame.
void rediwm_node_touch(struct rediwm_node *);
void rediwm_node_set_enabled(struct rediwm_node *, bool enabled);
void rediwm_node_set_position(struct rediwm_node *, int x, int y);
// Restacking: all of these are no-ops where the node already sits.
void rediwm_node_raise_to_top(struct rediwm_node *);
void rediwm_node_lower_to_bottom(struct rediwm_node *);
void rediwm_node_place_above(struct rediwm_node *, struct rediwm_node *sibling);
void rediwm_node_place_below(struct rediwm_node *, struct rediwm_node *sibling);
// Moves the node to the top of `parent`, which must not be inside the node.
void rediwm_node_reparent(struct rediwm_node *, struct rediwm_tree *parent);
// The node's origin in the scene's root, and whether it and every ancestor are
// enabled, as wlr_scene_node_coords.
bool rediwm_node_coords(struct rediwm_node *, int *lx, int *ly);
// Whether the node and every ancestor are enabled.
bool rediwm_node_visible(const struct rediwm_node *);

void rediwm_rect_set_size(struct rediwm_rect *, int width, int height);
void rediwm_rect_set_color(struct rediwm_rect *, const float color[4]);

// Takes a lock on `buffer` (NULL clears), as wlr_scene_buffer_set_buffer. Nothing is
// damaged here: the caller of a compositor-owned buffer reports its damage to the
// projection.
void rediwm_buffer_set_buffer(struct rediwm_buffer *, struct wlr_buffer *);
// As wlr_scene_buffer_set_buffer_with_damage: `damage` is buffer-local.
void rediwm_buffer_set_buffer_with_damage(struct rediwm_buffer *, struct wlr_buffer *,
                                          const pixman_region32_t *damage);
// As wlr_scene_buffer_set_buffer_with_options: damage plus an acquire point to wait for.
struct wlr_scene_buffer_set_buffer_options;
void rediwm_buffer_set_buffer_with_options(struct rediwm_buffer *, struct wlr_buffer *,
                                           const struct wlr_scene_buffer_set_buffer_options *);
// The buffer the carrier holds; NULL once the renderer released it after upload.
struct wlr_buffer *rediwm_buffer_get_buffer(const struct rediwm_buffer *);
void rediwm_buffer_set_dest_size(struct rediwm_buffer *, int width, int height);
void rediwm_buffer_set_source_box(struct rediwm_buffer *, const struct wlr_fbox *);
void rediwm_buffer_set_opacity(struct rediwm_buffer *, float opacity);
void rediwm_buffer_set_filter_mode(struct rediwm_buffer *, enum wlr_scale_filter_mode);
void rediwm_buffer_set_transform(struct rediwm_buffer *, enum wl_output_transform);
// A copy of the region, in buffer-local units; NULL clears it.
void rediwm_buffer_set_opaque_region(struct rediwm_buffer *, const pixman_region32_t *);
// The size the buffer node is shown at when nothing sets one: the destination, else
// the buffer's own size with the transform applied.
void rediwm_buffer_size(const struct rediwm_buffer *, int *width, int *height);

// The topmost enabled node of the subtree at (x, y) in the subtree's own
// coordinates, with the point in the node's, as wlr_scene_node_at. Buffers answer
// through `point_accepts_input`.
struct rediwm_node *rediwm_node_at(struct rediwm_node *, double x, double y, double *nx, double *ny);
typedef void (*rediwm_buffer_iterator)(struct rediwm_buffer *, int sx, int sy, void *data);
// Every buffer of the subtree, bottom to top, with its position relative to the
// node passed in (as wlr_scene_node_for_each_buffer; disabled nodes are skipped).
void rediwm_node_for_each_buffer(struct rediwm_node *, rediwm_buffer_iterator, void *data);
