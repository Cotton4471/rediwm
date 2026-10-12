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
// lists below. present() reads only that graph (and the content the source still
// owns: buffers and their damage), rounds, and turns what changed into damage
// events and screen damage. The graph is the one place geometry is computed;
// present() may not derive any of its own. The output pass, hit testing and the
// surface feedback all read the graph too: there is no second tree of the world.
// Damage events: which leaf changed which layout-space box, for consumers that
// must tell what lies below a point in paint order from what lies above it
// (backdrop effects, stage 5 of docs/plans/scene-graph.md). A ring: each consumer
// keeps its own cursor, and one that falls behind by more than the ring holds is
// told so and must treat everything as changed.
enum { DAMAGE_EVENTS = 4096 };
struct rediwm_projection {
  struct wlr_scene_tree *source;
  struct wlr_scene *scene;
  // Every adapter, in creation order; `paint` holds the groups resolve() last
  // reached, bottom to top.
  struct wl_list leaves, groups, paint;
  // The surface leaves whose outputs the output pass reports (stage 6), and what
  // each output (by scene output index) looked like at the last report.
  struct wl_list feedback;
  struct {
    float scale;
    enum wl_output_transform transform;
    enum wl_output_subpixel subpixel;
    bool known;
  } shown_output[64];
  // The outputs whose scale, transform or subpixel order changed since: a surface
  // on them is told again even where nothing else changed, as wlroots does, for
  // its preferred scale.
  uint64_t forced;
  struct wl_listener new_surface;
  struct wl_list surfaces;
  uint64_t next_leaf_id;
  // Layout-space damage the sync in progress collects, applied to every output
  // when it ends (stage 6b).
  pixman_region32_t pending;
  struct rediwm_damage_event events[DAMAGE_EVENTS];
  uint64_t next_event; // sequence number of the next event; 0 is never used
};
// Source top-level subtrees are contiguous in paint order: each is a group, and
// a window going away damages everything its leaves showed at once.
struct group {
  struct wl_list link;
  // In projection->paint, or alone, when the last resolve() did not reach it.
  struct wl_list paint;
  // The leaves resolve() last reached under this group, bottom to top.
  struct wl_list items;
  bool enabled;
  struct rediwm_projection *projection;
  struct wlr_scene_node *source;
  struct wl_listener destroy;
  struct wlr_addon source_lookup;
  bool seen;
};
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
  struct wlr_scene_node *source;
  struct wl_listener destroy, commit;
  struct wlr_addon source_lookup;
  struct wlr_scene_surface *surface;
  struct feedback *feedback;
  bool dirty, seen;
  // Under an inert tree at the last resolve(): drawn, never picked.
  bool inert;
  // Commits can outpace presentation. Keep their union, including empty damage
  // on a rotated buffer; buffer identity is not evidence of changed pixels.
  pixman_region32_t damage;
  bool full_damage;
  // A compositor-owned buffer reported its own damage since the last sync;
  // without a report a replaced buffer damages its whole box.
  bool owned_damage;
  int damage_width, damage_height;
  // The graph's view of this leaf, rewritten by every resolve(). `item.clip`
  // points at `clip` when the leaf is under a clipped tree.
  struct rediwm_item item;
  struct rediwm_clip clip;
  // `item.shadow` points at `shadow` when the leaf is under a shadow tree. A
  // shadow has no buffer to damage: present() damages the footprint it last drew
  // (`shadow_drawn`) and the new one.
  struct rediwm_shadow shadow;
  // The box present() last showed the leaf in, for its damage events.
  struct rediwm_snap shown;
  struct rediwm_content shown_content;
  bool has_shown;
  // What of the leaf nothing above hid when the output pass last built, over the
  // whole layout: damage that changes only what the leaf shows is cut to it, as
  // wlroots cut it to a node's visible region. Not known until the first build.
  pixman_region32_t visible;
  bool has_visible;
  // Position in paint order at the last sync, to tell a restack.
  uint32_t rank;
  bool ranked;
  struct rediwm_shadow shadow_drawn_as;
  struct rediwm_snap shadow_drawn;
  float shadow_drawn_opacity;
  bool has_shadow_drawn;
  struct wlr_buffer *last_buffer;
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
//    if it sets one, still applies;
//  * shadow: every leaf under the tree is the analytic shadow of this shape
//    (REDIWM_ITEM_SHADOW), resolved like the clip;
//  * inert: the subtree is shown but takes no input: the pick passes through it
//    to what is below (a window sliding off a workspace it has left).
struct tree_props {
  struct wlr_addon addon;
  bool has_zoom, has_scale, has_clip, unclipped, has_shadow, inert;
  double zoom, scale;
  struct rediwm_clip_spec clip;
  struct rediwm_shadow_spec shadow;
  // The clip as the last resolve() saw it in layout space, to tell a changed
  // shape (to be damaged) from a moved window (whose leaves damage themselves).
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
bool rediwm_projection_set_tree_shadow(struct wlr_scene_node *node,
                                       const struct rediwm_shadow_spec *spec) {
  if (!spec) {
    struct tree_props *props = tree_props_find(node);
    if (props) props->has_shadow = false;
    return true;
  }
  if (spec->width <= 0 || spec->height <= 0 || !finite_at_least_zero(spec->softness) ||
      !isfinite(spec->offset_x) || !isfinite(spec->offset_y))
    return false;
  for (int i = 0; i < 4; i++)
    if (!finite_at_least_zero(spec->radii[i]) || !isfinite(spec->color[i])) return false;
  struct tree_props *props = tree_props_get(node);
  if (!props) return false;
  props->shadow = *spec;
  props->has_shadow = true;
  return true;
}
bool rediwm_projection_set_tree_unclipped(struct wlr_scene_node *node, bool unclipped) {
  struct tree_props *props = unclipped ? tree_props_get(node) : tree_props_find(node);
  if (unclipped && !props) return false;
  if (props) props->unclipped = unclipped;
  return true;
}
bool rediwm_projection_set_tree_inert(struct wlr_scene_node *node, bool inert) {
  struct tree_props *props = inert ? tree_props_get(node) : tree_props_find(node);
  if (inert && !props) return false;
  if (props) props->inert = inert;
  return true;
}
static const struct wlr_addon_interface source_lookup_impl, group_source_impl;
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
static void forget_shown(struct leaf *l);
static void damage_shadow(struct leaf *l, bool show, struct rediwm_snap at);
static void apply_damage(struct rediwm_projection *p);
static void destroy_group(struct group *g) {
  // What the window's leaves showed is damaged at once, as a node going away was
  // for wlroots: a frame built before the next sync (a capture) must see it. The
  // leaves are destroyed with their nodes, after this group, and only ever touch
  // the projection.
  struct leaf *l, *next;
  wl_list_for_each_safe(l, next, &g->items, paint) {
    forget_shown(l);
    damage_shadow(l, false, (struct rediwm_snap){0});
    detach(&l->paint);
  }
  apply_damage(g->projection);
  wl_list_remove(&g->paint);
  wl_list_remove(&g->destroy.link);
  wl_list_remove(&g->link);
  wlr_addon_finish(&g->source_lookup);
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
static const struct wlr_addon_interface group_source_impl = {
    .name = "rediwm projection group source", .destroy = group_source_addon_destroy};
static struct group *get_group(struct rediwm_projection *p,
                               struct wlr_scene_node *source) {
  struct wlr_addon *addon = wlr_addon_find(&source->addons, p, &group_source_impl);
  struct group *g;
  if (addon)
    return wl_container_of(addon, g, source_lookup);
  g = calloc(1, sizeof(*g));
  if (!g)
    return NULL;
  g->source = source;
  g->projection = p;
  wl_list_init(&g->paint);
  wl_list_init(&g->items);
  wl_list_insert(&p->groups, &g->link);
  wlr_addon_init(&g->source_lookup, &source->addons, p, &group_source_impl);
  g->destroy.notify = group_source_destroy;
  wl_signal_add(&source->events.destroy, &g->destroy);
  return g;
}
// ---- Surface feedback (stage 6 of docs/plans/scene-graph.md) ---------------------
// wlr_scene tells a surface where it is shown by emitting its scene buffer's own
// signals, from the node's visible region. The world's source tree is disabled, so
// wlroots sees nothing there; the output pass, which draws the graph, knows what
// is shown.
// For every client surface it reports, per output it builds, how many pixels are
// visible (not hidden by what is above), and this keeps the last report of each
// output. From the sums it applies wlroots' own rule (scene.c,
// update_node_update_outputs): an output is active when it shows more than a tenth
// of what is visible on all of them, and the primary one is the one showing most
// (the last, on a tie). It then emits the signals wlr_scene would have: the
// source buffer is where wlr_scene_surface listens.
enum { FEEDBACK_OUTPUTS = 64 };
struct feedback {
  struct wl_list link;
  struct leaf *leaf;
  // Visible pixels as the last build of each output (scene output index) saw them.
  uint32_t area[FEEDBACK_OUTPUTS];
  uint64_t active;
  struct wlr_scene_output *primary;
};
static void free_feedback(struct leaf *l) {
  if (!l->feedback) return;
  wl_list_remove(&l->feedback->link);
  free(l->feedback);
  l->feedback = NULL;
}
static void emit(struct rediwm_projection *p, uint64_t leaf, int x, int y, int width, int height) {
  if (width <= 0 || height <= 0) return;
  if (!p->next_event) p->next_event = 1;
  p->events[p->next_event % DAMAGE_EVENTS] =
      (struct rediwm_damage_event){.leaf = leaf, .box = {x, y, width, height}};
  p->next_event++;
}
static void emit_snap(struct leaf *l, struct rediwm_snap s) {
  emit(l->projection, l->item.id, s.x, s.y, s.width, s.height);
}
bool rediwm_projection_damage_events(struct rediwm_projection *p, uint64_t *cursor,
                                     rediwm_damage_event_iterator fn, void *data) {
  const uint64_t end = p->next_event ? p->next_event : 1;
  const uint64_t oldest = end > DAMAGE_EVENTS ? end - DAMAGE_EVENTS : 1;
  bool complete = *cursor >= oldest;
  for (uint64_t seq = complete ? *cursor : oldest; seq < end; seq++)
    fn(&p->events[seq % DAMAGE_EVENTS], data);
  *cursor = end;
  return complete;
}
uint64_t rediwm_projection_damage_cursor(struct rediwm_projection *p) {
  return p->next_event ? p->next_event : 1;
}
// Layout-space damage for the screen, applied when the sync ends. `visible_only`
// cuts it to what the leaf showed at the last build: a change of what the leaf
// itself shows is invisible where something opaque lay over it, and anything that
// stops covering it damages that region itself.
static void damage_box(struct leaf *l, struct rediwm_snap s, bool visible_only) {
  if (s.width <= 0 || s.height <= 0) return;
  pixman_region32_t *pending = &l->projection->pending;
  if (visible_only && l->has_visible) {
    pixman_region32_t region;
    pixman_region32_init_rect(&region, s.x, s.y, s.width, s.height);
    pixman_region32_intersect(&region, &region, &l->visible);
    pixman_region32_union(pending, pending, &region);
    pixman_region32_fini(&region);
  } else {
    pixman_region32_union_rect(pending, pending, s.x, s.y, s.width, s.height);
  }
}
static void damage_shadow(struct leaf *l, bool show, struct rediwm_snap at);
static void forget_shown(struct leaf *l) {
  if (l->has_shown) {
    emit_snap(l, l->shown);
    damage_box(l, l->shown, true);
  }
  l->has_shown = false;
}
static void destroy_leaf(struct leaf *l) {
  forget_shown(l);
  damage_shadow(l, false, (struct rediwm_snap){0});
  // A node going away damaged the screen at once, and a frame built before the
  // next sync (a capture) must see it.
  apply_damage(l->projection);
  free_feedback(l);
  wl_list_remove(&l->commit.link);
  wl_list_remove(&l->destroy.link);
  wl_list_remove(&l->link);
  wl_list_remove(&l->paint);
  wlr_addon_finish(&l->source_lookup);
  pixman_region32_fini(&l->damage);
  pixman_region32_fini(&l->visible);
  free(l);
}
static void source_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct leaf *l = wl_container_of(listener, l, destroy);
  schedule(l->projection);
  destroy_leaf(l);
}
static void source_addon_destroy(struct wlr_addon *addon) {
  struct leaf *l = wl_container_of(addon, l, source_lookup);
  destroy_leaf(l);
}
static const struct wlr_addon_interface source_lookup_impl = {
    .name = "rediwm projection source", .destroy = source_addon_destroy};
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
  l->item.id = ++p->next_leaf_id;
  l->dirty = true;
  l->full_damage = true;
  pixman_region32_init(&l->damage);
  pixman_region32_init(&l->visible);
  wl_list_init(&l->commit.link);
  wl_list_init(&l->paint);
  wl_list_insert(&p->leaves, &l->link);
  wlr_addon_init(&l->source_lookup, &source->addons, p, &source_lookup_impl);
  l->destroy.notify = source_destroy;
  wl_signal_add(&source->events.destroy, &l->destroy);
  if (source->type == WLR_SCENE_NODE_BUFFER) {
    struct wlr_scene_buffer *buffer = wlr_scene_buffer_from_node(source);
    l->surface = wlr_scene_surface_try_from_buffer(buffer);
    if (l->surface) {
      l->damage_width = l->surface->surface->current.buffer_width;
      l->damage_height = l->surface->surface->current.buffer_height;
      l->feedback = calloc(1, sizeof(*l->feedback));
      if (l->feedback) {
        l->feedback->leaf = l;
        wl_list_insert(&p->feedback, &l->feedback->link);
      }
      l->commit.notify = committed;
      wl_signal_add(&l->surface->surface->events.commit, &l->commit);
    }
  }
  return l;
}
#include "glass.h"
// A glass effect covers its target exactly: the box is the target's (same
// parent), and it is shown only with it. The pass draws the blur (stage 5c).
static void effect_geometry(struct wlr_scene_node *node, int *x, int *y, int *width,
                            int *height, bool *enabled) {
  struct rediwm_glass_info info;
  if (!rediwm_glass_effect_info(node, &info)) return;
  struct wlr_scene_buffer *t = info.target;
  *x += t->node.x - node->x;
  *y += t->node.y - node->y;
  *enabled = *enabled && t->node.enabled;
  *width = t->dst_width ? t->dst_width : t->private.buffer_width;
  *height = t->dst_height ? t->dst_height : t->private.buffer_height;
}

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
  pixman_region32_union(&p->pending, &p->pending, &region);
  pixman_region32_fini(&region);
}
// resolve(): source tree -> graph. Writes items, group origins, `seen` flags and
// the paint-order lists; creates adapters for nodes it meets the first time, but
// moves and shows nothing.
static void resolve_node(struct rediwm_projection *p, struct group *g,
                         struct wlr_scene_node *node, double x, double y,
                         bool enabled, bool inert, struct rediwm_xform t,
                         const struct rediwm_clip *clip,
                         const struct rediwm_shadow *shadow) {
  x += node->x;
  y += node->y;
  enabled = enabled && node->enabled;
  if (node->type == WLR_SCENE_NODE_TREE) {
    struct rediwm_clip here;
    struct rediwm_shadow cast;
    struct tree_props *props = tree_props_find(node);
    if (props) {
      // Window zoom composes with the camera, around the frame origin.
      if (props->has_zoom) t = rediwm_xform_scale_about(t, props->zoom, x, y);
      if (props->has_scale) t = rediwm_xform_scale_about(t, props->scale, x, y);
      if (props->unclipped) clip = NULL;
      if (props->inert) inert = true;
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
      if (props->has_shadow) {
        cast = rediwm_shadow_resolve(t, x, y, &props->shadow);
        shadow = &cast;
      }
    }
    struct wlr_scene_node *child;
    wl_list_for_each(child, &wlr_scene_tree_from_node(node)->children, link)
        resolve_node(p, g, child, x, y, enabled, inert, t, clip, shadow);
    return;
  }
  struct leaf *l = get_leaf(p, node);
  if (!l) {
    wlr_log(WLR_ERROR, "zoom: cannot allocate presentation node");
    return;
  }
  l->seen = true;
  if (l->inert != inert) l->inert = inert;
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
    if (item->kind == REDIWM_ITEM_EFFECT) {
      int ex = 0, ey = 0;
      effect_geometry(node, &ex, &ey, &item->width, &item->height, &item->enabled);
      x += ex;
      y += ey;
    } else if (!item->width || !item->height) {
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
  if (shadow && node->type == WLR_SCENE_NODE_BUFFER) {
    item->kind = REDIWM_ITEM_SHADOW;
    l->shadow = *shadow;
    item->shadow = &l->shadow;
  } else if (item->shadow) {
    item->shadow = NULL;
  }
  item->edges = rediwm_xform_rect(t, x, y, item->width, item->height);
}

// What a shadow draws changed, or it appeared or went: damage the footprint it
// last drew and the one it draws now, in layout space.
static void damage_shadow(struct leaf *l, bool show, struct rediwm_snap at) {
  const float opacity = l->item.content.opacity;
  if (show == l->has_shadow_drawn &&
      (!show || (at.x == l->shadow_drawn.x && at.y == l->shadow_drawn.y &&
                 at.width == l->shadow_drawn.width && at.height == l->shadow_drawn.height &&
                 opacity == l->shadow_drawn_opacity &&
                 rediwm_shadow_equal(&l->shadow, &l->shadow_drawn_as))))
    return;
  pixman_region32_t region;
  pixman_region32_init(&region);
  if (l->has_shadow_drawn)
    pixman_region32_union_rect(&region, &region, l->shadow_drawn.x, l->shadow_drawn.y,
                               l->shadow_drawn.width, l->shadow_drawn.height);
  if (show) pixman_region32_union_rect(&region, &region, at.x, at.y, at.width, at.height);
  if (pixman_region32_not_empty(&region)) {
    pixman_region32_union(&l->projection->pending, &l->projection->pending, &region);
    const pixman_box32_t *b = pixman_region32_extents(&region);
    emit(l->projection, l->item.id, b->x1, b->y1, b->x2 - b->x1, b->y2 - b->y1);
  }
  pixman_region32_fini(&region);
  l->has_shadow_drawn = show;
  l->shadow_drawn = at;
  l->shadow_drawn_as = l->shadow;
  l->shadow_drawn_opacity = opacity;
}

// The layout box a buffer-local box covers: through the source box onto the item's
// edges, one pixel wider for filtering, never beyond the leaf (damage outside its
// source box shows nowhere).
static struct rediwm_snap map_damage(const struct rediwm_item *item, const pixman_box32_t *b,
                                     const struct wlr_fbox *src, struct rediwm_snap snap) {
  const struct rediwm_edges *e = &item->edges;
  const double sx = (e->x2 - e->x1) / src->width, sy = (e->y2 - e->y1) / src->height;
  const int x1 = (int)floor(e->x1 + (b->x1 - src->x) * sx) - 1;
  const int y1 = (int)floor(e->y1 + (b->y1 - src->y) * sy) - 1;
  const int x2 = (int)ceil(e->x1 + (b->x2 - src->x) * sx) + 1;
  const int y2 = (int)ceil(e->y1 + (b->y2 - src->y) * sy) + 1;
  const int cx1 = x1 > snap.x ? x1 : snap.x, cy1 = y1 > snap.y ? y1 : snap.y;
  const int cx2 = x2 < snap.x + snap.width ? x2 : snap.x + snap.width;
  const int cy2 = y2 < snap.y + snap.height ? y2 : snap.y + snap.height;
  return (struct rediwm_snap){cx1, cy1, cx2 - cx1, cy2 - cy1};
}
// What a commit's or a replaced buffer's damage changed: the event covers the
// bounding box of the buffer-local damage, the screen only the pieces of it (up to
// a few). The whole box without damage, or under a transform (conservative, like
// glass.c was).
static void damage_event_for_buffer(struct leaf *l, const pixman_region32_t *damage,
                                    int buffer_width, int buffer_height,
                                    struct rediwm_snap snap) {
  const struct rediwm_item *item = &l->item;
  if (!damage || item->content.transform != WL_OUTPUT_TRANSFORM_NORMAL ||
      buffer_width <= 0 || buffer_height <= 0) {
    emit_snap(l, snap);
    damage_box(l, snap, true);
    return;
  }
  if (!pixman_region32_not_empty((pixman_region32_t *)damage)) return;
  struct wlr_fbox src = item->content.src_box;
  if (wlr_fbox_empty(&src)) src = (struct wlr_fbox){0, 0, buffer_width, buffer_height};
  const struct rediwm_snap whole =
      map_damage(item, pixman_region32_extents((pixman_region32_t *)damage), &src, snap);
  emit(l->projection, item->id, whole.x, whole.y, whole.width, whole.height);
  int count = 0;
  const pixman_box32_t *rects = pixman_region32_rectangles((pixman_region32_t *)damage, &count);
  if (count > 16) {
    damage_box(l, whole, true);
    return;
  }
  for (int i = 0; i < count; i++) {
    const struct rediwm_snap piece = map_damage(item, &rects[i], &src, snap);
    damage_box(l, piece, true);
  }
}
// present(): graph -> damage. Reads items, never the source's geometry; rounds
// and tells the screen and the damage events what changed.
static void present_leaf(struct leaf *l) {
  struct rediwm_item *item = &l->item;
  // Round in layout coordinates first. Rounding a scaled local offset would
  // change pixels at fractional zoom and when crossing negative origins.
  const struct rediwm_snap snap = rediwm_edges_snap(item->edges);
  const bool enabled = item->enabled && snap.width > 0 && snap.height > 0;
  // Damage events: a moved, resized, shown, hidden or restyled leaf changes its
  // old and its new box; otherwise only what a new buffer or commit damaged.
  // Only a leaf that puts pixels on screen has them: an input-only node (a
  // resize grab) moving with its window must not read as a change below glass,
  // and the pass draws effects itself (shadows report in damage_shadow).
  bool paints = enabled;
  if (item->kind == REDIWM_ITEM_RECT) {
    paints = paints && item->content.color[3] > 0;
  } else if (item->kind == REDIWM_ITEM_EFFECT || item->kind == REDIWM_ITEM_SHADOW) {
    paints = false;
  } else {
    // What the output pass draws from: the buffer, or the texture left when GLES2
    // uploaded it and let the buffer go, or a single-pixel colour.
    const struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(l->source);
    paints = paints && item->content.opacity > 0 &&
             (sb->buffer || sb->private.texture || sb->private.is_single_pixel_buffer ||
              (l->surface && l->surface->surface->buffer));
  }
  const bool restyled = !l->has_shown || !paints || snap.x != l->shown.x ||
                        snap.y != l->shown.y || snap.width != l->shown.width ||
                        snap.height != l->shown.height ||
                        !rediwm_content_equal(&item->content, &l->shown_content);
  if (restyled) {
    forget_shown(l);
    if (paints) {
      emit_snap(l, snap);
      damage_box(l, snap, false);
      l->shown = snap;
      l->shown_content = item->content;
      l->has_shown = true;
    }
  }
  if (item->kind != REDIWM_ITEM_RECT && item->kind != REDIWM_ITEM_EFFECT) {
    struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(l->source);
    struct wlr_buffer *backing = b->buffer;
    // wlroots may cache a single-pixel buffer as a color and release the
    // source node's buffer reference. The mapped surface still owns it.
    if (!backing && l->surface && l->surface->surface->buffer)
      backing = &l->surface->surface->buffer->base;
    if (l->dirty || l->last_buffer != backing) {
      const pixman_region32_t *damage =
          backing && (l->surface || l->owned_damage) && l->dirty && !l->full_damage
              ? &l->damage : NULL;
      if (!restyled && l->has_shown)
        damage_event_for_buffer(l, damage,
                                l->surface ? l->damage_width : backing ? backing->width : 0,
                                l->surface ? l->damage_height : backing ? backing->height : 0, snap);
      l->last_buffer = backing;
    }
  }
  if (item->kind == REDIWM_ITEM_SHADOW || l->has_shadow_drawn)
    damage_shadow(l, item->kind == REDIWM_ITEM_SHADOW && enabled &&
                         item->content.opacity > 0 && item->shadow->color[3] > 0,
                  snap);
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
// lock is marked ignorable (like wlr_scene's own surface lock): the output pass
// reads the buffer from the node and is told the damage at the next sync.
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
static uint32_t region_area(const pixman_region32_t *region) {
  int count = 0;
  const pixman_box32_t *box = pixman_region32_rectangles((pixman_region32_t *)region, &count);
  uint32_t area = 0;
  for (int i = 0; i < count; i++)
    area += (uint32_t)(box[i].x2 - box[i].x1) * (uint32_t)(box[i].y2 - box[i].y1);
  return area;
}
static struct leaf *transport_leaf(struct rediwm_projection *p, struct wlr_scene_node *node) {
  struct wlr_addon *addon = wlr_addon_find(&node->addons, p, &source_lookup_impl);
  struct leaf *l;
  return addon ? wl_container_of(addon, l, source_lookup) : NULL;
}
static struct leaf *feedback_leaf(struct rediwm_projection *p, struct wlr_scene_node *node) {
  struct leaf *l = transport_leaf(p, node);
  return l && l->feedback ? l : NULL;
}
// What of an item nothing above hides, as the output pass last saw it (layout space).
void rediwm_projection_note_visible(struct rediwm_projection *p, struct wlr_scene_node *node,
                                    const pixman_region32_t *visible) {
  struct leaf *l = transport_leaf(p, node);
  if (!l) return;
  pixman_region32_copy(&l->visible, visible);
  l->has_visible = true;
}
void rediwm_projection_feedback_begin(struct rediwm_projection *p) {
  // Whatever this build does not reach (off every output, hidden, gone) shows
  // nothing: damage that only changes what such a leaf shows is dropped.
  struct leaf *leaf;
  wl_list_for_each(leaf, &p->leaves, link) {
    pixman_region32_clear(&leaf->visible);
    leaf->has_visible = true;
  }
  struct feedback *f;
  wl_list_for_each(f, &p->feedback, link) memset(f->area, 0, sizeof(f->area));
  struct wlr_scene_output *out;
  wl_list_for_each(out, &p->scene->outputs, link) {
    const unsigned i = out->private.index % FEEDBACK_OUTPUTS;
    if (p->shown_output[i].known &&
        (p->shown_output[i].scale != out->output->scale ||
         p->shown_output[i].transform != out->output->transform ||
         p->shown_output[i].subpixel != out->output->subpixel))
      p->forced |= 1ull << i;
    p->shown_output[i].scale = out->output->scale;
    p->shown_output[i].transform = out->output->transform;
    p->shown_output[i].subpixel = out->output->subpixel;
    p->shown_output[i].known = true;
  }
}
// `visible` is what of the surface nothing above it hides, over the whole layout.
void rediwm_projection_feedback_note(struct rediwm_projection *p, struct wlr_scene_node *node,
                                     const pixman_region32_t *visible) {
  struct leaf *l = feedback_leaf(p, node);
  if (!l || !pixman_region32_not_empty((pixman_region32_t *)visible)) return;
  struct wlr_scene_output *out;
  wl_list_for_each(out, &p->scene->outputs, link) {
    if (!out->output->enabled) continue;
    struct wlr_box box = {.x = out->x, .y = out->y};
    wlr_output_effective_resolution(out->output, &box.width, &box.height);
    pixman_region32_t shown;
    pixman_region32_init(&shown);
    pixman_region32_intersect_rect(&shown, (pixman_region32_t *)visible, box.x, box.y, box.width,
                                   box.height);
    l->feedback->area[out->private.index % FEEDBACK_OUTPUTS] = region_area(&shown);
    pixman_region32_fini(&shown);
  }
}
// The outputs and primary output of one surface from the last report of every
// output, and the signals of what changed.
static void update_feedback(struct leaf *l) {
  struct feedback *f = l->feedback;
  struct wlr_scene *scene = l->projection->scene;
  struct wlr_scene_output *out;
  uint64_t total = 0;
  wl_list_for_each(out, &scene->outputs, link)
      if (out->output->enabled) total += f->area[out->private.index % FEEDBACK_OUTPUTS];
  uint32_t largest = 0;
  uint64_t active = 0;
  size_t count = 0;
  struct wlr_scene_output *primary = NULL;
  wl_list_for_each(out, &scene->outputs, link) {
    if (!out->output->enabled) continue;
    const uint32_t overlap = f->area[out->private.index % FEEDBACK_OUTPUTS];
    // Ten percent of what is visible or less, and the output is ignored.
    if (overlap > 0.1 * total) {
      if (overlap >= largest) {
        largest = overlap;
        primary = out;
      }
      active |= 1ull << (out->private.index % FEEDBACK_OUTPUTS);
      count++;
    }
  }
  struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(l->source);
  const uint64_t before = f->active;
  struct wlr_scene_output *before_primary = f->primary;
  f->active = active;
  f->primary = primary;
  wl_list_for_each(out, &scene->outputs, link) {
    const uint64_t mask = 1ull << (out->private.index % FEEDBACK_OUTPUTS);
    if ((active & mask) && !(before & mask))
      wl_signal_emit_mutable(&b->events.output_enter, out);
    else if (!(active & mask) && (before & mask))
      wl_signal_emit_mutable(&b->events.output_leave, out);
  }
  if (before == active && before_primary == primary && !(active & l->projection->forced)) return;
  struct wlr_scene_output *outputs[FEEDBACK_OUTPUTS];
  struct wlr_scene_outputs_update_event event = {.active = outputs, .size = count};
  size_t i = 0;
  wl_list_for_each(out, &scene->outputs, link)
      if (active & (1ull << (out->private.index % FEEDBACK_OUTPUTS))) outputs[i++] = out;
  wl_signal_emit_mutable(&b->events.outputs_update, &event);
}
void rediwm_projection_feedback_end(struct rediwm_projection *p) {
  struct feedback *f, *next;
  wl_list_for_each_safe(f, next, &p->feedback, link) update_feedback(f->leaf);
  p->forced = 0;
}
// wlr_scene_output_send_frame_done for the world: the surfaces shown on any
// output (the surface itself picks the output that paces it).
void rediwm_projection_send_frame_done(struct rediwm_projection *p, struct wlr_scene_output *out,
                                       struct timespec *now) {
  struct feedback *f, *next;
  wl_list_for_each_safe(f, next, &p->feedback, link) {
    if (!f->active || !f->leaf->seen || !f->leaf->item.enabled) continue;
    struct wlr_scene_frame_done_event event = {.output = out, .when = *now};
    wl_signal_emit_mutable(&wlr_scene_buffer_from_node(f->leaf->source)->events.frame_done, &event);
  }
}
struct rediwm_projection *
rediwm_projection_create(struct wlr_scene_tree *source, struct wlr_scene *scene) {
  struct rediwm_projection *p = calloc(1, sizeof(*p));
  if (!p)
    return NULL;
  p->source = source;
  p->scene = scene;
  wl_list_init(&p->leaves);
  wl_list_init(&p->groups);
  wl_list_init(&p->paint);
  wl_list_init(&p->surfaces);
  wl_list_init(&p->feedback);
  wl_list_init(&p->new_surface.link);
  pixman_region32_init(&p->pending);
  // wlroots ignores a disabled tree: it computes no outputs, frame callbacks or
  // damage for the source nodes; the graph does all three.
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
    g->enabled = node->enabled;
    wl_list_insert(p->paint.prev, &g->paint);
    resolve_node(p, g, node, 0, 0, true, false, t, NULL, NULL);
  }
}
static void damage_restacked(struct rediwm_projection *p);
// Graph -> damage, then forget what the graph no longer reaches.
static void present(struct rediwm_projection *p) {
  struct group *g;
  wl_list_for_each(g, &p->paint, paint) {
    struct leaf *l, *next;
    wl_list_for_each_safe(l, next, &g->items, paint) present_leaf(l);
  }
  struct leaf *l;
  wl_list_for_each(l, &p->leaves, link) if (!l->seen) {
    forget_shown(l);
    damage_shadow(l, false, (struct rediwm_snap){0});
    l->ranked = false;
  }
  damage_restacked(p);
}
// A leaf that is above what it was below, or the reverse, changes every pixel of
// the two where they overlap, and nothing else tells the screen: wlroots damaged a
// node it restacked. The leaves still there are checked in paint order against
// the order of the last sync; when it differs, the ones that must have moved (all
// but a longest run that kept its order) are damaged whole. Any pair that swapped
// has at least one of them outside that run, and the overlap lies in its box.
static void damage_restacked(struct rediwm_projection *p) {
  size_t n = 0;
  bool ordered = true, have = false;
  uint32_t last = 0;
  struct group *g;
  struct leaf *l;
  wl_list_for_each(g, &p->paint, paint) wl_list_for_each(l, &g->items, paint) {
    if (!l->ranked) continue;
    if (have && l->rank < last) ordered = false;
    last = l->rank;
    have = true;
    n++;
  }
  if (!ordered) {
    struct leaf **leaves = malloc(n * sizeof(*leaves));
    size_t *tails = malloc(n * sizeof(*tails));
    long *before = malloc(n * sizeof(*before));
    bool *kept = calloc(n, sizeof(*kept));
    if (leaves && tails && before && kept) {
      size_t count = 0, length = 0;
      wl_list_for_each(g, &p->paint, paint) wl_list_for_each(l, &g->items, paint)
          if (l->ranked) leaves[count++] = l;
      // Longest strictly increasing run of the old ranks.
      for (size_t i = 0; i < count; i++) {
        size_t lo = 0, hi = length;
        while (lo < hi) {
          const size_t mid = (lo + hi) / 2;
          if (leaves[tails[mid]]->rank < leaves[i]->rank) lo = mid + 1;
          else hi = mid;
        }
        before[i] = lo > 0 ? (long)tails[lo - 1] : -1;
        tails[lo] = i;
        if (lo == length) length++;
      }
      for (long i = length ? (long)tails[length - 1] : -1; i >= 0; i = before[i]) kept[i] = true;
      for (size_t i = 0; i < count; i++) {
        struct leaf *moved = leaves[i];
        if (kept[i]) continue;
        // A shadow shows no box of its own (`shown`), but it lies over or under
        // what was restacked all the same.
        if (moved->has_shown) damage_box(moved, moved->shown, false);
        if (moved->has_shadow_drawn) damage_box(moved, moved->shadow_drawn, false);
      }
    } else {
      // Out of memory: treat the whole layout as changed.
      pixman_region32_union_rect(&p->pending, &p->pending, INT32_MIN / 2, INT32_MIN / 2, INT32_MAX, INT32_MAX);
    }
    free(leaves);
    free(tails);
    free(before);
    free(kept);
  }
  uint32_t rank = 0;
  wl_list_for_each(g, &p->paint, paint) wl_list_for_each(l, &g->items, paint) {
    l->rank = rank++;
    l->ranked = true;
  }
}
static void apply_damage(struct rediwm_projection *p) {
  if (pixman_region32_not_empty(&p->pending)) rediwm_scene_damage_layout(p->scene, &p->pending);
  pixman_region32_clear(&p->pending);
}
void rediwm_projection_sync_fixed(struct rediwm_projection *p, double z, double cx,
                            double cy, double ox, double oy,
                            struct wlr_scene_tree *fixed) {
  if (!p)
    return;
  resolve(p, z, cx, cy, ox, oy, fixed);
  present(p);
  apply_damage(p);
}
void rediwm_projection_sync(struct rediwm_projection *p, double z, double cx,
                            double cy, double ox, double oy) {
  rediwm_projection_sync_fixed(p, z, cx, cy, ox, oy, NULL);
}
// Shell/layer/lock nodes have identity layout transforms. Resolve them into the
// same item type at the output boundary.
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
    if (item.kind == REDIWM_ITEM_EFFECT) {
      effect_geometry(node, &x, &y, &item.width, &item.height, &item.enabled);
    } else if (!item.width || !item.height) {
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
static bool visit_items(struct rediwm_projection *p, struct wlr_scene_node *node,
                       int x, int y, bool reverse, rediwm_item_iterator iterator, void *data) {
  if (!node->enabled && node != &p->source->node) return true;
  if (node == &p->source->node) {
    for (struct wl_list *link = reverse ? p->paint.prev : p->paint.next;
         link != &p->paint; link = reverse ? link->prev : link->next) {
      struct group *g = wl_container_of(link, g, paint);
      if (!g->enabled) continue;
      for (struct wl_list *leaf_link = reverse ? g->items.prev : g->items.next;
           leaf_link != &g->items; leaf_link = reverse ? leaf_link->prev : leaf_link->next) {
        struct leaf *l = wl_container_of(leaf_link, l, paint);
        if (l->item.enabled && !iterator(&l->item, l->source, data)) return false;
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
// A node's opaque region (in its own units) as it lands on screen, never larger
// than the real one.
//
// wlroots knows a client surface is opaque from its raw buffer's format (an XRGB
// buffer covers the whole surface) or from the client's own opaque region, and
// keeps that in the node's opaque region; the node's buffer is a wlr_client_buffer,
// which reveals no pixel format, so its own flag is false for every client. A node
// shown 1:1 uses the region as is. Otherwise each rectangle is scaled with the
// node and pulled one pixel inward, so rounding and the filter's reach beyond an
// opaque edge can never mark a translucent pixel opaque.
void rediwm_mirror_opaque(pixman_region32_t *out, const pixman_region32_t *source, int source_width,
        int source_height, int width, int height) {
    int count = 0;
    const pixman_box32_t *box = pixman_region32_rectangles((pixman_region32_t *)source, &count);
    const bool exact = width == source_width && height == source_height;
    for (int i = 0; i < count; i++) {
        if (exact) {
            pixman_region32_union_rect(out, out, box[i].x1, box[i].y1, box[i].x2 - box[i].x1, box[i].y2 - box[i].y1);
        } else if (source_width > 0 && source_height > 0) {
            const double sx = (double)width / source_width;
            const double sy = (double)height / source_height;
            const int x1 = (int)ceil(box[i].x1 * sx) + 1;
            const int y1 = (int)ceil(box[i].y1 * sy) + 1;
            const int x2 = (int)floor(box[i].x2 * sx) - 1;
            const int y2 = (int)floor(box[i].y2 * sy) - 1;
            if (x2 > x1 && y2 > y1) pixman_region32_union_rect(out, out, x1, y1, x2 - x1, y2 - y1);
        }
    }
    pixman_region32_intersect_rect(out, out, 0, 0, width, height);
}
// ---- Hit testing (stage 6 of docs/plans/scene-graph.md) --------------------------
// What wlr_scene_node_at gave on the world's view tree, from the graph: the items
// from the top of the paint order down, each tested at the pixels it covers once
// rounded, then against the window's shape and the source buffer's own input
// region. The layout trees are still wlroots' to pick (D1).
static struct wlr_scene_node *pick_world(struct rediwm_projection *p, double lx, double ly,
                                         double *nx, double *ny) {
  const double px = floor(lx), py = floor(ly);
  for (struct wl_list *gl = p->paint.prev; gl != &p->paint; gl = gl->prev) {
    struct group *g = wl_container_of(gl, g, paint);
    if (!g->enabled) continue;
    for (struct wl_list *ll = g->items.prev; ll != &g->items; ll = ll->prev) {
      struct leaf *l = wl_container_of(ll, l, paint);
      const struct rediwm_item *item = &l->item;
      // An effect takes no input, and a leaf with no pixels once rounded is not shown.
      if (!item->enabled || item->kind == REDIWM_ITEM_EFFECT || l->inert) continue;
      const struct rediwm_snap s = rediwm_edges_snap(item->edges);
      if (s.width <= 0 || s.height <= 0 || px < s.x || px >= s.x + s.width || py < s.y ||
          py >= s.y + s.height)
        continue;
      double x = lx - s.x, y = ly - s.y;
      if (l->source->type == WLR_SCENE_NODE_BUFFER) {
        x *= (double)item->width / s.width;
        y *= (double)item->height / s.height;
        // A window's rounded corners are transparent: a point the shape cuts away
        // goes to what is below. The point is in source units; the shape is in
        // layout space.
        if (item->clip && item->width > 0 && item->height > 0) {
          const struct rediwm_edges *e = &item->edges;
          const double cx = e->x1 + x * (e->x2 - e->x1) / item->width;
          const double cy = e->y1 + y * (e->y2 - e->y1) / item->height;
          if (rediwm_clip_distance(item->clip, cx, cy) > 0) continue;
        }
        struct wlr_scene_buffer *source = wlr_scene_buffer_from_node(l->source);
        if (source->point_accepts_input && !source->point_accepts_input(source, &x, &y)) continue;
      }
      *nx = x;
      *ny = y;
      return l->source;
    }
  }
  return NULL;
}
static struct wlr_scene_node *pick_layout(struct wlr_scene_node *node, double lx, double ly,
                                          double *nx, double *ny) {
  return wlr_scene_node_at(node, lx, ly, nx, ny);
}
// The topmost node at a layout point and the point in its own coordinates, or NULL.
// A hit in the world is the source node.
struct wlr_scene_node *rediwm_projection_node_at(struct rediwm_projection *p, double lx, double ly,
                                                 double *nx, double *ny) {
  struct wlr_scene_node *hit = NULL;
  double x = 0, y = 0;
  struct wl_list *children = &p->scene->tree.children;
  for (struct wl_list *link = children->prev; link != children && !hit; link = link->prev) {
    struct wlr_scene_node *child = wl_container_of(link, child, link);
    if (child == &p->source->node) hit = pick_world(p, lx, ly, &x, &y);
    else hit = pick_layout(child, lx, ly, &x, &y);
  }
  if (hit) {
    if (nx) *nx = x;
    if (ny) *ny = y;
  }
  return hit;
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
  pixman_region32_fini(&p->pending);
  struct watched_surface *watch, *next;
  wl_list_for_each_safe(watch, next, &p->surfaces, link)
      watched_destroy(&watch->destroy, NULL);
  free(p);
}
