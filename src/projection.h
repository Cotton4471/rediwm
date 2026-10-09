#pragma once
#include <stdbool.h>
struct wlr_scene_node;
struct wlr_scene_tree;
struct wlr_scene;
struct wlr_scene_buffer;
struct wlr_surface_state;
struct rediwm_projection;
struct rediwm_item;
struct rediwm_clip_spec;
// Synchronous traversal of the whole displayed graph (bottom-to-top unless
// reverse is true). World
// geometry comes from resolved items, never the view tree. `transport` owns
// buffer resources and surface feedback until the legacy adapter is removed.
// Callbacks must not mutate the scene; pointers are borrowed for this call.
typedef bool (*rediwm_item_iterator)(const struct rediwm_item *,
                                    struct wlr_scene_node *transport, void *);
bool rediwm_projection_for_each_item(struct rediwm_projection *, bool reverse, rediwm_item_iterator, void *);
// Glass publishes its current raster against the resolved target geometry.
void rediwm_projection_effect_updated(struct wlr_scene_buffer *, struct wlr_scene_buffer *);
// Whether a commit changed how buffer pixels map onto the surface, so damage
// from before it cannot be combined with damage after it.
bool rediwm_surface_state_remapped(const struct wlr_surface_state *);
struct rediwm_projection *rediwm_projection_create(struct wlr_scene_tree *,
                                                   struct wlr_scene_tree *,
                                                   struct wlr_scene *);
void rediwm_projection_destroy(struct rediwm_projection *);
void rediwm_projection_sync(struct rediwm_projection *, double, double, double,
                            double, double);
// Optional root subtree presented in layout coordinates, independent of the camera.
void rediwm_projection_sync_fixed(struct rediwm_projection *, double, double, double,
                                  double, double, struct wlr_scene_tree *);
struct wlr_scene_node *rediwm_projection_source(struct wlr_scene_node *);
// Window scale relative to its parent camera, around the frame origin.
bool rediwm_projection_set_tree_zoom(struct wlr_scene_node *, double);
// Relative presentation scale. Composes with parent camera and window zoom.
bool rediwm_projection_set_tree_scale(struct wlr_scene_node *, double);
double rediwm_projection_node_zoom(struct wlr_scene_node *);
// One rounded-rectangle shape for every leaf under the tree, in the tree's own
// units and anchored at its origin; NULL removes it. Returns false for a size
// that is not positive or a radius or border that is negative or not finite.
bool rediwm_projection_set_tree_clip(struct wlr_scene_node *, const struct rediwm_clip_spec *);
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
struct wlr_scene_node *rediwm_projection_node(struct rediwm_projection *,
                                              struct wlr_scene_node *);
