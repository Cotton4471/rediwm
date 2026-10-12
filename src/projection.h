#pragma once
#include <stdbool.h>
#include <stdint.h>
struct wlr_scene_node;
struct wlr_scene_tree;
struct wlr_scene;
struct wlr_scene_buffer;
struct wlr_surface_state;
struct rediwm_projection;
struct rediwm_item;
struct rediwm_clip_spec;
// Synchronous traversal of the whole displayed graph (bottom-to-top unless
// reverse is true). World geometry comes from resolved items; `transport` is the
// scene node that owns the item's buffer, texture and wait points: the source
// node for the world, the node itself for the layout trees. Callbacks must not
// mutate the scene; pointers are borrowed for this call.
typedef bool (*rediwm_item_iterator)(const struct rediwm_item *,
                                    struct wlr_scene_node *transport, void *);
bool rediwm_projection_for_each_item(struct rediwm_projection *, bool reverse, rediwm_item_iterator, void *);
// Whether a commit changed how buffer pixels map onto the surface, so damage
// from before it cannot be combined with damage after it.
bool rediwm_surface_state_remapped(const struct wlr_surface_state *);
// `source` is the world's tree, disabled so that wlroots ignores it; the
// projection resolves it into the graph the output pass draws.
struct rediwm_projection *rediwm_projection_create(struct wlr_scene_tree *source,
                                                   struct wlr_scene *);
void rediwm_projection_destroy(struct rediwm_projection *);
void rediwm_projection_sync(struct rediwm_projection *, double, double, double,
                            double, double);
// A leaf's pixels changed in `box` (layout space) during a sync. `leaf` is the
// item's `id`; a leaf that is gone or hidden reports its last box.
struct rediwm_damage_event {
  uint64_t leaf;
  struct { int x, y, width, height; } box;
};
typedef void (*rediwm_damage_event_iterator)(const struct rediwm_damage_event *, void *);
// Calls `fn` for every event since `*cursor` and moves the cursor past them. A
// consumer starts from rediwm_projection_damage_cursor(). Returns false when
// events were lost (the cursor fell behind the ring): treat everything as changed.
bool rediwm_projection_damage_events(struct rediwm_projection *, uint64_t *cursor,
                                     rediwm_damage_event_iterator, void *);
uint64_t rediwm_projection_damage_cursor(struct rediwm_projection *);
// Optional root subtree presented in layout coordinates, independent of the camera.
void rediwm_projection_sync_fixed(struct rediwm_projection *, double, double, double,
                                  double, double, struct wlr_scene_tree *);
// The topmost node at a layout point, with the point in the node's own coordinates
// (source units for a client surface), or NULL. Hits in the world are source nodes.
struct wlr_scene_node *rediwm_projection_node_at(struct rediwm_projection *, double lx, double ly,
                                                 double *nx, double *ny);
// Window scale relative to its parent camera, around the frame origin.
bool rediwm_projection_set_tree_zoom(struct wlr_scene_node *, double);
// Relative presentation scale. Composes with parent camera and window zoom.
bool rediwm_projection_set_tree_scale(struct wlr_scene_node *, double);
// One rounded-rectangle shape for every leaf under the tree, in the tree's own
// units and anchored at its origin; NULL removes it. Returns false for a size
// that is not positive or a radius or border that is negative or not finite.
bool rediwm_projection_set_tree_clip(struct wlr_scene_node *, const struct rediwm_clip_spec *);
// Every leaf under the tree draws the analytic shadow of this shape (see
// rediwm_shadow_spec in scene_graph.h); its node supplies only the footprint,
// opacity and input. NULL removes it. False for a size that is not positive, or a
// radius or softness that is negative or not finite.
struct rediwm_shadow_spec;
bool rediwm_projection_set_tree_shadow(struct wlr_scene_node *, const struct rediwm_shadow_spec *);
// Ends the clip inherited from an ancestor for this subtree (an xdg popup lives
// under its parent's tree but is no part of the window's shape).
bool rediwm_projection_set_tree_unclipped(struct wlr_scene_node *, bool);
// Buffer-local damage for the next buffer set on a compositor-owned source
// buffer node; NULL damages all of it. Surface leaves track their own.
struct pixman_region32;
void rediwm_projection_damage_buffer(struct rediwm_projection *,
                                     struct wlr_scene_node *,
                                     const struct pixman_region32 *);
// Presents `buffer` on a compositor-owned source buffer node, updating its
// texture in place with `damage` (buffer-local) when the renderer can. The
// caller may release `buffer` afterwards. NULL damage replaces everything.
// Returns whether the texture was updated in place.
struct wlr_scene_buffer;
struct wlr_renderer;
struct wlr_buffer;
bool rediwm_projection_present_owned(struct rediwm_projection *,
                                     struct wlr_scene_buffer *,
                                     struct wlr_renderer *,
                                     struct wlr_buffer *,
                                     const struct pixman_region32 *);
// A node's opaque region (in the node's own units, `source_width` by `source_height`)
// as it lands on a box of `width` by `height` device pixels: never larger than the
// real one, one pixel inward where the node is scaled.
void rediwm_mirror_opaque(struct pixman_region32 *out, const struct pixman_region32 *source,
                          int source_width, int source_height, int width, int height);
// Surface feedback (stage 6): each time the output pass builds, it reports how
// much of every client surface nothing above hides, over the whole layout.
// `begin` clears the last report, `note` reports one surface (a node of the
// graph's items; anything but a client surface of the world is ignored) and
// `end` works out and sends what changed: outputs entered and left, the primary
// output.
// What of an item nothing above hides, in layout space, as the pass saw it.
struct wlr_scene_output;
void rediwm_projection_note_visible(struct rediwm_projection *, struct wlr_scene_node *,
                                    const struct pixman_region32 *visible);
void rediwm_projection_feedback_begin(struct rediwm_projection *);
void rediwm_projection_feedback_note(struct rediwm_projection *, struct wlr_scene_node *,
                                     const struct pixman_region32 *visible);
void rediwm_projection_feedback_end(struct rediwm_projection *);
// Frame callbacks of the world's surfaces, beside wlr_scene_output_send_frame_done.
struct timespec;
void rediwm_projection_send_frame_done(struct rediwm_projection *, struct wlr_scene_output *,
                                       struct timespec *now);
