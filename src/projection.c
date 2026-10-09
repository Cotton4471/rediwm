// Presentation-only geometry. Source xdg/subsurface nodes are never rewritten.
// wlroots 0.20 ABI, pinned by build.zig.zon (as in glass.c).
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "projection.h"
#include "scene_graph.h"
#include "scene_damage.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/util/addon.h>
#include <wlr/util/log.h>

// Two halves, joined by the typed graph of scene_graph.h. resolve() walks the
// source tree and writes `item`s and group origins, in paint order, into the
// lists below; it touches no view node. present() reads only that graph (and the
// content the source still owns: buffers, wait points, opaque regions), rounds,
// and applies the result to the view tree. The graph is the one place geometry
// is computed; present() may not derive any of its own.
struct rediwm_projection {
  struct wlr_scene_tree *source, *view;
  struct wlr_scene *scene;
  // Every adapter, in creation order; `paint` holds the groups resolve() last
  // reached, bottom to top.
  struct wl_list leaves, groups, paint;
  struct wl_listener new_surface;
  struct wl_list surfaces;
};
// Source top-level subtrees are contiguous in paint order. Moving their
// presentation tree updates wlroots visibility once for the whole window,
// instead of once for every titlebar, border, client and shadow leaf.
struct group {
  struct wl_list link;
  // In projection->paint, or alone, when the last resolve() did not reach it.
  struct wl_list paint;
  // The leaves resolve() last reached under this group, bottom to top.
  struct wl_list items;
  // The group's origin in layout space, unrounded; resolved from the source.
  double x, y;
  bool enabled;
  struct rediwm_projection *projection;
  struct wlr_scene_node *source;
  struct wlr_scene_tree *view;
  struct wl_listener destroy;
  struct wlr_addon source_lookup, view_lookup;
  bool seen;
};
// Everything present() last applied to a view node: the rounded rectangle, the
// content and what the view's buffer reported about itself. Nothing else writes
// to non-glass views, so an unchanged state skips a dozen setter calls and an
// opaque-region rebuild per leaf on every sync (every frame after a commit).
struct view_state {
  int x, y, width, height;
  bool enabled, opaque;
  // Hash of the source's opaque region as mirrored onto the view.
  uint64_t opaque_hash;
  struct rediwm_content content;
};
static bool view_state_equal(const struct view_state *a,
                             const struct view_state *b) {
  return a->x == b->x && a->y == b->y && a->width == b->width &&
         a->height == b->height && a->enabled == b->enabled &&
         a->opaque == b->opaque && a->opaque_hash == b->opaque_hash &&
         rediwm_content_equal(&a->content, &b->content);
}
// A list link that is always valid to remove: alone, or in a live list.
static void detach(struct wl_list *link) {
  wl_list_remove(link);
  wl_list_init(link);
}
struct leaf {
  struct wl_list link;
  // In its group's `items` when the last resolve() reached it, else alone.
  struct wl_list paint;
  struct rediwm_projection *projection;
  struct wlr_scene_node *source, *view;
  struct wl_listener destroy, commit;
  struct wlr_addon lookup, source_lookup;
  struct wlr_scene_surface *surface;
  bool dirty, seen;
  // Commits can outpace presentation. Keep their union, including empty damage
  // on a rotated buffer; buffer identity is not evidence of changed pixels.
  pixman_region32_t damage;
  bool full_damage;
  // A compositor-owned buffer reported its own damage since the last sync;
  // without a report a replaced buffer damages its whole view.
  bool owned_damage;
  int damage_width, damage_height;
  // The graph's view of this leaf, rewritten by every resolve(). `item.clip`
  // points at `clip` when the leaf is under a clipped tree.
  struct rediwm_item item;
  struct rediwm_clip clip;
  // Glass's raster is published after resolve; its target still supplies the
  // geometry. Kept separately so an unchanged/held blur survives the next sync.
  struct rediwm_item effect_item;
  struct rediwm_clip effect_clip;
  struct wlr_buffer *last_buffer;
  // The client buffer whose view lock we told wlroots to ignore, if any.
  struct wlr_client_buffer *marked;
  struct view_state applied;
  bool has_applied;
};
// Everything the compositor says about how a source tree is presented, in one
// addon. Resolve meets every tree of every window on every frame, and each
// property that had an addon of its own cost a lookup there. The properties:
//  * zoom: a window's scale about its origin, composing with the camera;
//  * scale: a relative presentation scale (Xwayland's 1/N), composing with both;
//  * clip: the rounded shape that clips everything under the tree. Resolve
//    evaluates it after this tree's own zoom and scale, so it follows its window
//    and an inner scale never changes it. A clipped tree inside another replaces
//    the outer shape for its own leaves; nothing intersects them;
//  * unclipped: ends the inherited clip for the subtree. A popup's scene tree is a
//    child of its parent surface's, so it sits under the window's clipped tree in
//    the source graph while belonging to no window shape. The subtree's own clip,
//    if it sets one, still applies.
struct tree_props {
  struct wlr_addon addon;
  bool has_zoom, has_scale, has_clip, unclipped;
  double zoom, scale;
  struct rediwm_clip_spec clip;
  // The clip as the last resolve() saw it in layout space, to tell a changed
  // shape (to be damaged) from a moved window (whose views damage themselves).
  struct rediwm_clip applied;
  bool has_applied;
};
static void destroy_tree_props(struct wlr_addon *addon) {
  struct tree_props *props = wl_container_of(addon, props, addon);
  wlr_addon_finish(addon);
  free(props);
}
static const struct wlr_addon_interface tree_props_impl = {
    .name = "rediwm tree presentation", .destroy = destroy_tree_props};
static struct tree_props *tree_props_find(struct wlr_scene_node *node) {
  struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &tree_props_impl);
  struct tree_props *props;
  return addon ? (props = wl_container_of(addon, props, addon)) : NULL;
}
static struct tree_props *tree_props_get(struct wlr_scene_node *node) {
  struct tree_props *props = tree_props_find(node);
  if (props) return props;
  props = calloc(1, sizeof(*props));
  if (!props) return NULL;
  wlr_addon_init(&props->addon, &node->addons, NULL, &tree_props_impl);
  return props;
}
bool rediwm_projection_set_tree_zoom(struct wlr_scene_node *node, double scale) {
  struct tree_props *props = tree_props_get(node);
  if (!props) return false;
  props->zoom = scale;
  props->has_zoom = true;
  return true;
}
bool rediwm_projection_set_tree_scale(struct wlr_scene_node *node, double factor) {
  if (factor <= 0) return false;
  struct tree_props *props = tree_props_get(node);
  if (!props) return false;
  props->scale = factor;
  props->has_scale = true;
  return true;
}
static bool finite_at_least_zero(double value) { return isfinite(value) && value >= 0; }
bool rediwm_projection_set_tree_clip(struct wlr_scene_node *node,
                                     const struct rediwm_clip_spec *spec) {
  if (!spec) {
    struct tree_props *props = tree_props_find(node);
    if (props) props->has_clip = false;
    return true;
  }
  if (spec->width <= 0 || spec->height <= 0 || !finite_at_least_zero(spec->border)) return false;
  for (int i = 0; i < 4; i++)
    if (!finite_at_least_zero(spec->radii[i]) || !isfinite(spec->border_color[i])) return false;
  struct tree_props *props = tree_props_get(node);
  if (!props) return false;
  props->clip = *spec;
  props->has_clip = true;
  return true;
}
bool rediwm_projection_set_tree_unclipped(struct wlr_scene_node *node, bool unclipped) {
  struct tree_props *props = unclipped ? tree_props_get(node) : tree_props_find(node);
  if (unclipped && !props) return false;
  if (props) props->unclipped = unclipped;
  return true;
}
static const struct wlr_addon_interface lookup_impl, source_lookup_impl;
static const struct wlr_addon_interface group_source_impl, group_view_impl;
struct watched_surface {
  struct rediwm_projection *projection;
  struct wl_list link;
  struct wl_listener commit, destroy;
};
static void schedule(struct rediwm_projection *p) {
  struct wlr_scene_output *out;
  wl_list_for_each(out, &p->scene->outputs, link)
      wlr_output_schedule_frame(out->output);
}
static void finish_group(struct group *g) {
  // Leaves outlive their group by a moment (its view node frees them after its
  // addons finish), and each still points into this list head.
  struct leaf *l, *next;
  wl_list_for_each_safe(l, next, &g->items, paint) detach(&l->paint);
  wl_list_remove(&g->paint);
  wl_list_remove(&g->destroy.link);
  wl_list_remove(&g->link);
  wlr_addon_finish(&g->source_lookup);
  wlr_addon_finish(&g->view_lookup);
}
static void destroy_group(struct group *g) {
  finish_group(g);
  // Destroying the view also releases any remaining leaf adapters. This is
  // safe if the source tree is destroyed before its children or vice versa.
  wlr_scene_node_destroy(&g->view->node);
  free(g);
}
static void group_source_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct group *g = wl_container_of(listener, g, destroy);
  schedule(g->projection);
  destroy_group(g);
}
static void group_source_addon_destroy(struct wlr_addon *addon) {
  struct group *g = wl_container_of(addon, g, source_lookup);
  destroy_group(g);
}
static void group_view_destroy(struct wlr_addon *addon) {
  struct group *g = wl_container_of(addon, g, view_lookup);
  finish_group(g);
  free(g);
}
static const struct wlr_addon_interface group_source_impl = {
    .name = "rediwm projection group source", .destroy = group_source_addon_destroy};
static const struct wlr_addon_interface group_view_impl = {
    .name = "rediwm projection group", .destroy = group_view_destroy};
static struct group *get_group(struct rediwm_projection *p,
                               struct wlr_scene_node *source) {
  struct wlr_addon *addon = wlr_addon_find(&source->addons, p, &group_source_impl);
  struct group *g;
  if (addon)
    return wl_container_of(addon, g, source_lookup);
  g = calloc(1, sizeof(*g));
  if (!g)
    return NULL;
  g->view = wlr_scene_tree_create(p->view);
  if (!g->view) {
    free(g);
    return NULL;
  }
  g->source = source;
  g->projection = p;
  wl_list_init(&g->paint);
  wl_list_init(&g->items);
  wl_list_insert(&p->groups, &g->link);
  wlr_addon_init(&g->source_lookup, &source->addons, p, &group_source_impl);
  wlr_addon_init(&g->view_lookup, &g->view->node.addons, NULL, &group_view_impl);
  g->destroy.notify = group_source_destroy;
  wl_signal_add(&source->events.destroy, &g->destroy);
  return g;
}
static struct leaf *lookup(struct wlr_scene_node *node) {
  struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &lookup_impl);
  if (!addon)
    return NULL;
  struct leaf *l = wl_container_of(addon, l, lookup);
  return l;
}
struct wlr_scene_node *rediwm_projection_source(struct wlr_scene_node *node) {
  struct leaf *l = lookup(node);
  return l ? l->source : node;
}
double rediwm_projection_node_zoom(struct wlr_scene_node *node) {
  struct leaf *l = lookup(node);
  return l ? l->item.scale : 1;
}
struct wlr_scene_node *rediwm_projection_node(struct rediwm_projection *p,
                                              struct wlr_scene_node *source) {
  if (!p)
    return source;
  struct wlr_addon *addon =
      wlr_addon_find(&source->addons, p, &source_lookup_impl);
  if (!addon)
    return NULL;
  struct leaf *l = wl_container_of(addon, l, source_lookup);
  return l->view;
}
static void move_listener(struct wl_listener *listener,
                          struct wl_signal *signal) {
  wl_list_remove(&listener->link);
  wl_signal_add(signal, listener);
}
// Keep wlroots' own surface lifecycle implementation, but drive it exclusively
// from displayed buffers. Source buffers stay under a disabled tree in the same
// scene, so the handlers retain the correct scene/output/color-manager context.
static void route_surface(struct leaf *l, struct wlr_scene_buffer *buffer) {
  if (!l->surface)
    return;
  move_listener(&l->surface->private.outputs_update,
                &buffer->events.outputs_update);
  move_listener(&l->surface->private.output_sample,
                &buffer->events.output_sample);
  move_listener(&l->surface->private.frame_done, &buffer->events.frame_done);
}
// wlr_client_buffer_apply_damage updates a shm client's texture in place only
// when no lock but the surface's is outstanding; otherwise every commit
// allocates a new texture and uploads the whole buffer. wlr_scene marks its
// own surface-node lock as ignorable for that reason. The view holds a second
// lock and needs the same mark, which is safe for the same reason: the view is
// synchronized from the source before every output frame. Single-pixel
// buffers are excluded because wlroots draws them from a cached colour.
static void unmark_view_buffer(struct leaf *l) {
  if (!l->marked)
    return;
  struct wlr_scene_buffer *v = wlr_scene_buffer_from_node(l->view);
  if (v->buffer == &l->marked->base && l->marked->private.n_ignore_locks > 0)
    l->marked->private.n_ignore_locks--;
  l->marked = NULL;
}
static void mark_view_buffer(struct leaf *l, struct wlr_buffer *backing) {
  struct wlr_client_buffer *client =
      backing ? wlr_client_buffer_get(backing) : NULL;
  if (!client || !l->surface || l->surface->surface->buffer != client)
    return;
  if (client->source &&
      wlr_single_pixel_buffer_v1_try_from_buffer(client->source))
    return;
  client->private.n_ignore_locks++;
  l->marked = client;
}
static void destroy_leaf(struct leaf *l) {
  unmark_view_buffer(l);
  route_surface(l, l->surface ? l->surface->buffer : NULL);
  wl_list_remove(&l->commit.link);
  wl_list_remove(&l->destroy.link);
  wl_list_remove(&l->link);
  wl_list_remove(&l->paint);
  wlr_addon_finish(&l->source_lookup);
  wlr_addon_finish(&l->lookup);
  wlr_scene_node_destroy(l->view);
  pixman_region32_fini(&l->damage);
  free(l);
}
static void source_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct leaf *l = wl_container_of(listener, l, destroy);
  schedule(l->projection);
  destroy_leaf(l);
}
static void view_destroy(struct wlr_addon *addon) {
  // The adapter is explicitly destroyed before its presentation tree.
  struct leaf *l = wl_container_of(addon, l, lookup);
  // Addons finish before wlroots unlocks the view's buffer.
  unmark_view_buffer(l);
  route_surface(l, l->surface ? l->surface->buffer : NULL);
  wl_list_remove(&l->commit.link);
  wl_list_remove(&l->destroy.link);
  wl_list_remove(&l->link);
  wl_list_remove(&l->paint);
  wlr_addon_finish(&l->source_lookup);
  wlr_addon_finish(addon);
  pixman_region32_fini(&l->damage);
  free(l);
}
static void source_addon_destroy(struct wlr_addon *addon) {
  struct leaf *l = wl_container_of(addon, l, source_lookup);
  destroy_leaf(l);
}
static const struct wlr_addon_interface source_lookup_impl = {
    .name = "rediwm projection source", .destroy = source_addon_destroy};
static const struct wlr_addon_interface lookup_impl = {
    .name = "rediwm projection", .destroy = view_destroy};
bool rediwm_surface_state_remapped(const struct wlr_surface_state *state) {
  // wl_surface before v5 sets OFFSET on every attach, even attach(buffer, 0, 0),
  // so only a nonzero delta is a real change. GTK3, Xwayland and other v4
  // clients would otherwise fully damage the surface on every frame.
  return (state->committed & (WLR_SURFACE_STATE_TRANSFORM |
                              WLR_SURFACE_STATE_SCALE |
                              WLR_SURFACE_STATE_VIEWPORT)) ||
         ((state->committed & WLR_SURFACE_STATE_OFFSET) &&
          (state->dx || state->dy));
}
static void committed(struct wl_listener *listener, void *data) {
  (void)data;
  struct leaf *l = wl_container_of(listener, l, commit);
  struct wlr_surface *surface = l->surface->surface;
  const struct wlr_surface_state *state = &surface->current;
  // Regions from different buffer mappings cannot safely be combined. A full
  // repaint also covers a mapping changed and restored between presentations.
  if (state->buffer_width != l->damage_width ||
      state->buffer_height != l->damage_height ||
      rediwm_surface_state_remapped(state))
    l->full_damage = true;
  l->damage_width = state->buffer_width;
  l->damage_height = state->buffer_height;
  if (!l->full_damage &&
      !pixman_region32_union(&l->damage, &l->damage, &surface->buffer_damage))
    l->full_damage = true;
  l->dirty = true;
  schedule(l->projection);
}
static bool accepts(struct wlr_scene_buffer *buffer, double *x, double *y) {
  struct leaf *l = lookup(&buffer->node);
  if (!l || buffer->dst_width <= 0 || buffer->dst_height <= 0)
    return false;
  *x *= (double)l->item.width / buffer->dst_width;
  *y *= (double)l->item.height / buffer->dst_height;
  // A window's rounded corners are transparent: a point the shape cuts away goes
  // to whatever is below, which wlroots finds by asking the next node. The point
  // is now in source units; the shape is in layout space.
  if (l->item.clip && l->item.width > 0 && l->item.height > 0) {
    const struct rediwm_edges *e = &l->item.edges;
    const double px = e->x1 + *x * (e->x2 - e->x1) / l->item.width;
    const double py = e->y1 + *y * (e->y2 - e->y1) / l->item.height;
    if (rediwm_clip_distance(l->item.clip, px, py) > 0)
      return false;
  }
  struct wlr_scene_buffer *source = wlr_scene_buffer_from_node(l->source);
  return !source->point_accepts_input ||
         source->point_accepts_input(source, x, y);
}
static struct leaf *get_leaf(struct rediwm_projection *p,
                             struct wlr_scene_node *source) {
  struct wlr_addon *addon =
      wlr_addon_find(&source->addons, p, &source_lookup_impl);
  struct leaf *l;
  if (addon)
    return wl_container_of(addon, l, source_lookup);
  l = calloc(1, sizeof(*l));
  if (!l)
    return NULL;
  l->source = source;
  l->projection = p;
  l->dirty = true;
  l->full_damage = true;
  pixman_region32_init(&l->damage);
  wl_list_init(&l->commit.link);
  wl_list_init(&l->paint);
  if (source->type == WLR_SCENE_NODE_RECT) {
    struct wlr_scene_rect *rect = wlr_scene_rect_from_node(source);
    struct wlr_scene_rect *view =
        wlr_scene_rect_create(p->view, 0, 0, rect->color);
    if (view)
      l->view = &view->node;
  } else {
    struct wlr_scene_buffer *view = wlr_scene_buffer_create(p->view, NULL);
    if (view)
      l->view = &view->node;
  }
  if (!l->view) {
    pixman_region32_fini(&l->damage);
    free(l);
    return NULL;
  }
  wl_list_insert(&p->leaves, &l->link);
  wlr_addon_init(&l->source_lookup, &source->addons, p, &source_lookup_impl);
  wlr_addon_init(&l->lookup, &l->view->addons, NULL, &lookup_impl);
  l->destroy.notify = source_destroy;
  wl_signal_add(&source->events.destroy, &l->destroy);
  if (source->type == WLR_SCENE_NODE_BUFFER) {
    struct wlr_scene_buffer *buffer = wlr_scene_buffer_from_node(source);
    struct wlr_scene_buffer *view = wlr_scene_buffer_from_node(l->view);
    view->point_accepts_input = accepts;
    l->surface = wlr_scene_surface_try_from_buffer(buffer);
    if (l->surface) {
      l->damage_width = l->surface->surface->current.buffer_width;
      l->damage_height = l->surface->surface->current.buffer_height;
      route_surface(l, view);
      l->commit.notify = committed;
      wl_signal_add(&l->surface->surface->events.commit, &l->commit);
    }
  }
  return l;
}
// The source's opaque region mapped onto its view, never larger than the real
// one, returning a hash of the source region for the view-state cache.
//
// wlroots knows a client surface is opaque from its raw buffer's format (an
// XRGB buffer covers the whole surface) or from the client's own opaque
// region, and keeps that in the node's opaque region. The view's buffer is a
// wlr_client_buffer, which reveals no pixel format, so its own flag is false
// for every client: without this no window occluded anything below it, every
// damaged frame redrew the wallpaper and the windows underneath, and a
// fullscreen client could never be the only thing left to scan out.
//
// A 1:1 view uses the region as is. Otherwise each rectangle is scaled with
// the view and pulled one pixel inward, so rounding and the filter's reach
// beyond an opaque edge can never mark a translucent pixel opaque.
static uint64_t mirror_opaque(pixman_region32_t *out, const pixman_region32_t *source,
                              int source_width, int source_height, int width,
                              int height) {
  uint64_t hash = UINT64_C(14695981039346656037);
  int count = 0;
  const pixman_box32_t *box =
      pixman_region32_rectangles((pixman_region32_t *)source, &count);
  const bool exact = width == source_width && height == source_height;
  for (int i = 0; i < count; i++) {
    const int edges[4] = {box[i].x1, box[i].y1, box[i].x2, box[i].y2};
    for (int j = 0; j < 4; j++)
      hash = (hash ^ (uint64_t)(uint32_t)edges[j]) * UINT64_C(1099511628211);
    if (exact) {
      pixman_region32_union_rect(out, out, box[i].x1, box[i].y1,
                                 box[i].x2 - box[i].x1, box[i].y2 - box[i].y1);
    } else if (source_width > 0 && source_height > 0) {
      const double sx = (double)width / source_width;
      const double sy = (double)height / source_height;
      const int x1 = (int)ceil(box[i].x1 * sx) + 1;
      const int y1 = (int)ceil(box[i].y1 * sy) + 1;
      const int x2 = (int)floor(box[i].x2 * sx) - 1;
      const int y2 = (int)floor(box[i].y2 * sy) - 1;
      if (x2 > x1 && y2 > y1)
        pixman_region32_union_rect(out, out, x1, y1, x2 - x1, y2 - y1);
    }
  }
  pixman_region32_intersect_rect(out, out, 0, 0, width, height);
  return hash;
}
// Glass writes its own projected buffers after this synchronization pass.
extern bool rediwm_glass_is_effect_node(struct wlr_scene_node *node);

// A clip's size, radii, border or colour changed: its views did not move, so
// nothing else tells wlroots that the corner arcs and the ring need repainting.
// The zone is the frame's rim, as wide as the largest radius plus the border and
// a margin; where the frame is thinner than twice that it is the whole box.
static bool clip_same_shape(const struct rediwm_clip *a, const struct rediwm_clip *b) {
  if (a->edges.x2 - a->edges.x1 != b->edges.x2 - b->edges.x1 ||
      a->edges.y2 - a->edges.y1 != b->edges.y2 - b->edges.y1 || a->border != b->border)
    return false;
  for (int i = 0; i < 4; i++)
    if (a->radii[i] != b->radii[i] || a->border_color[i] != b->border_color[i]) return false;
  return true;
}
static void clip_rim(pixman_region32_t *out, const struct rediwm_clip *c) {
  const struct rediwm_snap f = rediwm_edges_snap(c->edges);
  if (f.width <= 0 || f.height <= 0) return;
  double radius = 0;
  for (int i = 0; i < 4; i++)
    if (c->radii[i] > radius) radius = c->radii[i];
  const int inset = (int)ceil(radius) + (int)ceil(c->border) + 2;
  pixman_region32_t rim;
  pixman_region32_init_rect(&rim, f.x, f.y, f.width, f.height);
  if (f.width > 2 * inset && f.height > 2 * inset) {
    pixman_region32_t inner;
    pixman_region32_init_rect(&inner, f.x + inset, f.y + inset, f.width - 2 * inset,
                              f.height - 2 * inset);
    pixman_region32_subtract(&rim, &rim, &inner);
    pixman_region32_fini(&inner);
  }
  pixman_region32_union(out, out, &rim);
  pixman_region32_fini(&rim);
}
static void damage_clip_change(struct rediwm_projection *p, const struct rediwm_clip *before,
                               const struct rediwm_clip *after) {
  pixman_region32_t region;
  pixman_region32_init(&region);
  if (before) clip_rim(&region, before);
  if (after) clip_rim(&region, after);
  if (pixman_region32_not_empty(&region)) rediwm_scene_damage_layout(p->scene, &region);
  pixman_region32_fini(&region);
}
// resolve(): source tree -> graph. Writes items, group origins, `seen` flags and
// the paint-order lists; creates adapters for nodes it meets the first time, but
// moves, sizes and shows nothing in the view tree.
static void resolve_node(struct rediwm_projection *p, struct group *g,
                         struct wlr_scene_node *node, double x, double y,
                         bool enabled, struct rediwm_xform t,
                         const struct rediwm_clip *clip) {
  x += node->x;
  y += node->y;
  enabled = enabled && node->enabled;
  if (node->type == WLR_SCENE_NODE_TREE) {
    struct rediwm_clip here;
    struct tree_props *props = tree_props_find(node);
    if (props) {
      // Window zoom composes with the camera, around the frame origin.
      if (props->has_zoom) t = rediwm_xform_scale_about(t, props->zoom, x, y);
      if (props->has_scale) t = rediwm_xform_scale_about(t, props->scale, x, y);
      if (props->unclipped) clip = NULL;
      if (props->has_clip) {
        here = rediwm_clip_resolve(t, x, y, &props->clip);
        clip = &here;
        // A hidden window damages nothing; showing it will.
        if (enabled && (!props->has_applied || !clip_same_shape(&props->applied, &here)))
          damage_clip_change(p, props->has_applied ? &props->applied : NULL, &here);
        props->applied = here;
        props->has_applied = true;
      } else if (props->has_applied) {
        if (enabled) damage_clip_change(p, &props->applied, NULL);
        props->has_applied = false;
      }
    }
    struct wlr_scene_node *child;
    wl_list_for_each(child, &wlr_scene_tree_from_node(node)->children, link)
        resolve_node(p, g, child, x, y, enabled, t, clip);
    return;
  }
  struct leaf *l = get_leaf(p, node);
  if (!l) {
    wlr_log(WLR_ERROR, "zoom: cannot allocate presentation node");
    return;
  }
  l->seen = true;
  // Flattened leaves within each group retain the source's paint order.
  wl_list_insert(g->items.prev, &l->paint);
  struct rediwm_item *item = &l->item;
  item->enabled = enabled;
  item->scale = t.scale;
  item->content = (struct rediwm_content){0};
  // Only write what changes: rewriting a NULL over a NULL on every leaf of every
  // window dirties the line for nothing (measured at about 1 ns per leaf).
  if (clip) {
    l->clip = *clip;
    item->clip = &l->clip;
  } else if (item->clip) {
    item->clip = NULL;
  }
  if (node->type == WLR_SCENE_NODE_RECT) {
    struct wlr_scene_rect *r = wlr_scene_rect_from_node(node);
    item->kind = REDIWM_ITEM_RECT;
    item->width = r->width;
    item->height = r->height;
    memcpy(item->content.color, r->color, sizeof(item->content.color));
  } else {
    struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(node);
    item->kind = rediwm_glass_is_effect_node(node) ? REDIWM_ITEM_EFFECT
                 : l->surface                      ? REDIWM_ITEM_SURFACE
                                                   : REDIWM_ITEM_BUFFER;
    item->width = b->dst_width;
    item->height = b->dst_height;
    if (!item->width || !item->height) {
      item->width = b->private.buffer_width;
      item->height = b->private.buffer_height;
      if (b->transform & 1) {
        int tmp = item->width;
        item->width = item->height;
        item->height = tmp;
      }
    }
    struct rediwm_content *content = &item->content;
    content->src_box = b->src_box;
    content->transform = b->transform;
    content->opacity = b->opacity;
    content->filter_mode = rediwm_filter_at_scale(t.scale, b->filter_mode);
    content->transfer_function = b->transfer_function;
    content->primaries = b->primaries;
    content->color_encoding = b->color_encoding;
    content->color_range = b->color_range;
  }
  item->edges = rediwm_xform_rect(t, x, y, item->width, item->height);
}

// present(): graph -> view tree. Reads items and group origins, never the
// source's geometry; rounds, orders and applies, and tells wlroots about the
// buffers and damage that changed.
static void present_leaf(struct group *g, struct leaf *l,
                         struct wlr_scene_node **previous) {
  struct rediwm_item *item = &l->item;
  if (l->view->parent != g->view)
    wlr_scene_node_reparent(l->view, g->view);
  // Reorder only when necessary, avoiding damage from no-op syncs.
  if (*previous) {
    if (l->view->link.prev != &(*previous)->link)
      wlr_scene_node_place_above(l->view, *previous);
  } else if (l->view->link.prev != &g->view->children) {
    wlr_scene_node_lower_to_bottom(l->view);
  }
  *previous = l->view;
  // Round in layout coordinates first. Rounding a scaled local offset would
  // change pixels at fractional zoom and when crossing negative origins.
  const struct rediwm_snap snap = rediwm_edges_snap(item->edges);
  struct view_state next = {0};
  next.x = snap.x - g->view->node.x;
  next.y = snap.y - g->view->node.y;
  next.width = snap.width;
  next.height = snap.height;
  next.enabled = item->enabled && snap.width > 0 && snap.height > 0;
  next.content = item->content;
  if (item->kind == REDIWM_ITEM_RECT) {
    if (!l->has_applied || !view_state_equal(&next, &l->applied)) {
      struct wlr_scene_rect *v = wlr_scene_rect_from_node(l->view);
      wlr_scene_node_set_position(l->view, next.x, next.y);
      wlr_scene_node_set_enabled(l->view, next.enabled);
      wlr_scene_rect_set_size(v, snap.width > 0 ? snap.width : 0,
                              snap.height > 0 ? snap.height : 0);
      wlr_scene_rect_set_color(v, item->content.color);
      l->applied = next;
      l->has_applied = true;
    }
  } else if (item->kind != REDIWM_ITEM_EFFECT) {
    struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(l->source);
    struct wlr_scene_buffer *v = wlr_scene_buffer_from_node(l->view);
    struct wlr_buffer *backing = b->buffer;
    // wlroots may cache a single-pixel buffer as a color and release the
    // source node's buffer reference. The mapped surface still owns it.
    if (!backing && l->surface && l->surface->surface->buffer)
      backing = &l->surface->surface->buffer->base;
    if (l->dirty || l->last_buffer != backing) {
      struct wlr_scene_buffer_set_buffer_options options = {
          .damage = backing && (l->surface || l->owned_damage) &&
                            l->dirty && !l->full_damage
                        ? &l->damage : NULL,
          .wait_timeline = b->private.wait_timeline,
          .wait_point = b->private.wait_point,
      };
      unmark_view_buffer(l);
      wlr_scene_buffer_set_buffer_with_options(v, backing, &options);
      mark_view_buffer(l, backing);
      l->last_buffer = backing;
    }
    // Read after the buffer update above, which can change it.
    next.opaque = v->private.buffer_is_opaque;
    pixman_region32_t mirrored;
    pixman_region32_init(&mirrored);
    if (!next.opaque && snap.width > 0 && snap.height > 0)
      next.opaque_hash = mirror_opaque(&mirrored, &b->opaque_region, item->width,
                                       item->height, snap.width, snap.height);
    if (!l->has_applied || !view_state_equal(&next, &l->applied)) {
      const struct rediwm_content *content = &item->content;
      wlr_scene_node_set_position(l->view, next.x, next.y);
      wlr_scene_node_set_enabled(l->view, next.enabled);
      wlr_scene_buffer_set_source_box(v, &content->src_box);
      wlr_scene_buffer_set_dest_size(v, snap.width > 0 ? snap.width : 1,
                                     snap.height > 0 ? snap.height : 1);
      wlr_scene_buffer_set_transform(v, content->transform);
      wlr_scene_buffer_set_opacity(v, content->opacity);
      wlr_scene_buffer_set_filter_mode(v, content->filter_mode);
      wlr_scene_buffer_set_transfer_function(v, content->transfer_function);
      wlr_scene_buffer_set_primaries(v, content->primaries);
      wlr_scene_buffer_set_color_encoding(v, content->color_encoding);
      wlr_scene_buffer_set_color_range(v, content->color_range);
      // Mirror intrinsic opacity into the explicit region too. wlroots updates
      // buffer_is_opaque on buffer replacement without recomputing visibility
      // when the size is unchanged. Changing this region invalidates occlusion,
      // so an opaque -> translucent single-pixel buffer reveals the nodes below.
      // A client's own region (see mirror_opaque) is used when the view's
      // buffer does not know it is opaque.
      if (next.opaque && snap.width > 0 && snap.height > 0)
        pixman_region32_union_rect(&mirrored, &mirrored, 0, 0, snap.width,
                                   snap.height);
      wlr_scene_buffer_set_opaque_region(v, &mirrored);
      l->applied = next;
      l->has_applied = true;
    }
    pixman_region32_fini(&mirrored);
  }
  l->dirty = false;
  l->full_damage = false;
  l->owned_damage = false;
  pixman_region32_clear(&l->damage);
}
// Not in 0.20's public headers, but exported; see
// rediwm_projection_present_owned.
struct wlr_client_buffer *wlr_client_buffer_create(struct wlr_buffer *buffer,
                                                   struct wlr_renderer *renderer);
bool wlr_client_buffer_apply_damage(struct wlr_client_buffer *client_buffer,
                                    struct wlr_buffer *next,
                                    const pixman_region32_t *damage);
// A plain buffer replaced on a scene node gets a new texture and a full
// upload. Wrapping it in a client buffer instead lets the next frame's
// damage update that texture in place, as for shm clients. The source node's
// lock is marked ignorable (like wlr_scene's own surface lock): the view is
// synchronized from the source before every frame and told the damage.
bool rediwm_projection_present_owned(struct rediwm_projection *p,
                                     struct wlr_scene_buffer *source,
                                     struct wlr_renderer *renderer,
                                     struct wlr_buffer *buffer,
                                     const pixman_region32_t *damage) {
  struct wlr_client_buffer *current =
      source->buffer ? wlr_client_buffer_get(source->buffer) : NULL;
  bool same_size = current && current->base.width == buffer->width &&
                   current->base.height == buffer->height;
  if (same_size) {
    // A full repaint still fits the existing texture.
    pixman_region32_t whole;
    pixman_region32_init_rect(&whole, 0, 0, buffer->width, buffer->height);
    bool updated = wlr_client_buffer_apply_damage(current, buffer,
                                                  damage ? damage : &whole);
    pixman_region32_fini(&whole);
    if (updated) {
      rediwm_projection_damage_buffer(p, &source->node, damage);
      return true;
    }
  }
  struct wlr_client_buffer *next = wlr_client_buffer_create(buffer, renderer);
  if (!next) {
    // Without a texture wrapper, fall back to the plain buffer.
    if (current)
      current->private.n_ignore_locks--;
    wlr_scene_buffer_set_buffer(source, buffer);
    rediwm_projection_damage_buffer(p, &source->node, NULL);
    return false;
  }
  if (current)
    current->private.n_ignore_locks--;
  wlr_scene_buffer_set_buffer(source, &next->base);
  next->private.n_ignore_locks++;
  // The node's lock keeps it alive; drop the one creation handed us.
  wlr_buffer_unlock(&next->base);
  // Renderers without in-place updates (pixman) land here every frame. The
  // replacement differs from its predecessor only where `damage` says, so a
  // same-sized replacement keeps precise output damage.
  rediwm_projection_damage_buffer(p, &source->node, same_size ? damage : NULL);
  return false;
}
void rediwm_projection_damage_buffer(struct rediwm_projection *p,
                                     struct wlr_scene_node *source,
                                     const pixman_region32_t *damage) {
  struct wlr_addon *addon =
      wlr_addon_find(&source->addons, p, &source_lookup_impl);
  // A leaf's first projection applies its whole buffer anyway.
  if (!addon)
    return;
  struct leaf *l = wl_container_of(addon, l, source_lookup);
  if (l->surface)
    return;
  if (!damage ||
      !pixman_region32_union(&l->damage, &l->damage, damage))
    l->full_damage = true;
  l->owned_damage = true;
  l->dirty = true;
  schedule(p);
}
struct rediwm_projection *
rediwm_projection_create(struct wlr_scene_tree *source,
                         struct wlr_scene_tree *view, struct wlr_scene *scene) {
  struct rediwm_projection *p = calloc(1, sizeof(*p));
  if (!p)
    return NULL;
  p->source = source;
  p->view = view;
  p->scene = scene;
  wl_list_init(&p->leaves);
  wl_list_init(&p->groups);
  wl_list_init(&p->paint);
  wl_list_init(&p->surfaces);
  wl_list_init(&p->new_surface.link);
  wlr_scene_node_set_enabled(&source->node, false);
  return p;
}
// Source tree -> graph. Every adapter is detached from the paint lists first, so
// the lists hold exactly what this pass reaches, in source paint order.
static void resolve(struct rediwm_projection *p, double z, double cx, double cy,
                    double ox, double oy, struct wlr_scene_tree *fixed) {
  struct leaf *l;
  wl_list_for_each(l, &p->leaves, link) {
    l->seen = false;
    detach(&l->paint);
  }
  struct group *g;
  wl_list_for_each(g, &p->groups, link) {
    g->seen = false;
    detach(&g->paint);
  }
  const struct rediwm_xform camera = rediwm_xform_camera(z, cx, cy, ox, oy);
  const struct rediwm_xform identity = {1, 0, 0};
  struct wlr_scene_node *node;
  wl_list_for_each(node, &p->source->children, link) {
    g = get_group(p, node);
    if (!g) {
      wlr_log(WLR_ERROR, "zoom: cannot allocate presentation group");
      continue;
    }
    // The fixed subtree is laid out as is; everything else follows the camera.
    const struct rediwm_xform t = fixed && node == &fixed->node ? identity : camera;
    g->seen = true;
    rediwm_xform_point(t, node->x, node->y, &g->x, &g->y);
    g->enabled = node->enabled;
    wl_list_insert(p->paint.prev, &g->paint);
    resolve_node(p, g, node, 0, 0, true, t, NULL);
  }
}
// Graph -> view tree, then hide what the graph no longer reaches.
static void present(struct rediwm_projection *p) {
  struct wlr_scene_node *previous_group = NULL;
  struct group *g, *next_group;
  wl_list_for_each_safe(g, next_group, &p->paint, paint) {
    wlr_scene_node_set_position(&g->view->node, lround(g->x), lround(g->y));
    wlr_scene_node_set_enabled(&g->view->node, g->enabled);
    if (previous_group) {
      if (g->view->node.link.prev != &previous_group->link)
        wlr_scene_node_place_above(&g->view->node, previous_group);
    } else if (g->view->node.link.prev != &p->view->children) {
      wlr_scene_node_lower_to_bottom(&g->view->node);
    }
    previous_group = &g->view->node;
    struct wlr_scene_node *previous = NULL;
    struct leaf *l, *next;
    wl_list_for_each_safe(l, next, &g->items, paint) present_leaf(g, l, &previous);
  }
  struct leaf *l;
  wl_list_for_each(l, &p->leaves, link) if (!l->seen) {
    wlr_scene_node_set_enabled(l->view, false);
    // The cached state no longer describes the view; reapply on return.
    l->has_applied = false;
  }
  wl_list_for_each(g, &p->groups, link) if (!g->seen)
      wlr_scene_node_set_enabled(&g->view->node, false);
}
void rediwm_projection_sync_fixed(struct rediwm_projection *p, double z, double cx,
                            double cy, double ox, double oy,
                            struct wlr_scene_tree *fixed) {
  if (!p)
    return;
  resolve(p, z, cx, cy, ox, oy, fixed);
  present(p);
}
void rediwm_projection_sync(struct rediwm_projection *p, double z, double cx,
                            double cy, double ox, double oy) {
  rediwm_projection_sync_fixed(p, z, cx, cy, ox, oy, NULL);
}
// Shell/layer/lock nodes have identity layout transforms. Resolve them into the
// same item type at the output boundary; they have no projected view tree.
static struct rediwm_item layout_item(struct wlr_scene_node *node, int x, int y) {
  struct rediwm_item item = {.enabled = node->enabled, .scale = 1};
  if (node->type == WLR_SCENE_NODE_RECT) {
    struct wlr_scene_rect *r = wlr_scene_rect_from_node(node);
    item.kind = REDIWM_ITEM_RECT;
    item.width = r->width;
    item.height = r->height;
    memcpy(item.content.color, r->color, sizeof(item.content.color));
  } else {
    struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(node);
    item.kind = rediwm_glass_is_effect_node(node) ? REDIWM_ITEM_EFFECT :
        wlr_scene_surface_try_from_buffer(b) ? REDIWM_ITEM_SURFACE : REDIWM_ITEM_BUFFER;
    item.width = b->dst_width;
    item.height = b->dst_height;
    if (!item.width || !item.height) {
      item.width = b->private.buffer_width;
      item.height = b->private.buffer_height;
      if (b->transform & 1) { int tmp = item.width; item.width = item.height; item.height = tmp; }
    }
    item.content = (struct rediwm_content){
        .opacity = b->opacity, .src_box = b->src_box, .transform = b->transform,
        .filter_mode = b->filter_mode, .transfer_function = b->transfer_function,
        .primaries = b->primaries, .color_encoding = b->color_encoding, .color_range = b->color_range,
    };
  }
  item.edges = rediwm_xform_rect((struct rediwm_xform){1, 0, 0}, x, y, item.width, item.height);
  return item;
}
void rediwm_projection_effect_updated(struct wlr_scene_buffer *effect, struct wlr_scene_buffer *target) {
  struct leaf *l = lookup(&effect->node), *t = lookup(&target->node);
  if (!l || !t) return;
  const struct rediwm_snap snap = rediwm_edges_snap(t->item.edges);
  l->effect_item = layout_item(&effect->node, snap.x, snap.y);
  // The blur takes the shape of the titlebar it sits under.
  if (t->item.clip) {
    l->effect_clip = *t->item.clip;
    l->effect_item.clip = &l->effect_clip;
  }
}
static bool visit_items(struct rediwm_projection *p, struct wlr_scene_node *node,
                       int x, int y, bool reverse, rediwm_item_iterator iterator, void *data) {
  if (!node->enabled) return true;
  if (node == &p->view->node) {
    for (struct wl_list *link = reverse ? p->paint.prev : p->paint.next;
         link != &p->paint; link = reverse ? link->prev : link->next) {
      struct group *g = wl_container_of(link, g, paint);
      if (!g->enabled || !g->view->node.enabled) continue;
      for (struct wl_list *leaf_link = reverse ? g->items.prev : g->items.next;
           leaf_link != &g->items; leaf_link = reverse ? leaf_link->prev : leaf_link->next) {
        struct leaf *l = wl_container_of(leaf_link, l, paint);
        const struct rediwm_item *item = l->item.kind == REDIWM_ITEM_EFFECT ? &l->effect_item : &l->item;
        if (item->enabled && l->item.enabled && !iterator(item, l->view, data)) return false;
      }
    }
    return true;
  }
  x += node->x;
  y += node->y;
  if (node->type == WLR_SCENE_NODE_TREE) {
    struct wl_list *children = &wlr_scene_tree_from_node(node)->children;
    for (struct wl_list *link = reverse ? children->prev : children->next;
         link != children; link = reverse ? link->prev : link->next) {
      struct wlr_scene_node *child = wl_container_of(link, child, link);
      if (!visit_items(p, child, x, y, reverse, iterator, data)) return false;
    }
    return true;
  }
  struct rediwm_item item = layout_item(node, x, y);
  return iterator(&item, node, data);
}
bool rediwm_projection_for_each_item(struct rediwm_projection *p, bool reverse, rediwm_item_iterator iterator, void *data) {
  return visit_items(p, &p->scene->tree.node, 0, 0, reverse, iterator, data);
}
static void watched_commit(struct wl_listener *listener, void *data) {
  (void)data;
  struct watched_surface *watch = wl_container_of(listener, watch, commit);
  // Covers the first commit of new/desynchronized subsurfaces and popups,
  // before they have presentation leaves of their own.
  schedule(watch->projection);
}
static void watched_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct watched_surface *watch = wl_container_of(listener, watch, destroy);
  wl_list_remove(&watch->commit.link);
  wl_list_remove(&watch->destroy.link);
  wl_list_remove(&watch->link);
  free(watch);
}
static void new_surface(struct wl_listener *listener, void *data) {
  struct rediwm_projection *p = wl_container_of(listener, p, new_surface);
  struct wlr_surface *surface = data;
  struct watched_surface *watch = calloc(1, sizeof(*watch));
  if (!watch) {
    wlr_log(WLR_ERROR, "zoom: cannot watch new surface");
    return;
  }
  watch->projection = p;
  watch->commit.notify = watched_commit;
  watch->destroy.notify = watched_destroy;
  wl_signal_add(&surface->events.commit, &watch->commit);
  wl_signal_add(&surface->events.destroy, &watch->destroy);
  wl_list_insert(&p->surfaces, &watch->link);
}
void rediwm_projection_watch(struct rediwm_projection *p,
                             struct wlr_compositor *compositor) {
  p->new_surface.notify = new_surface;
  wl_signal_add(&compositor->events.new_surface, &p->new_surface);
}
void rediwm_projection_destroy(struct rediwm_projection *p) {
  if (!p)
    return;
  struct leaf *l, *tmp;
  wl_list_for_each_safe(l, tmp, &p->leaves, link) destroy_leaf(l);
  struct group *g, *next_group;
  wl_list_for_each_safe(g, next_group, &p->groups, link) destroy_group(g);
  wl_list_remove(&p->new_surface.link);
  struct watched_surface *watch, *next;
  wl_list_for_each_safe(watch, next, &p->surfaces, link)
      watched_destroy(&watch->destroy, NULL);
  free(p);
}
