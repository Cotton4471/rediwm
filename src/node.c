// Own scene nodes: see node.h.
#define WLR_USE_UNSTABLE
#include "node.h"
#include <stdlib.h>
#include <string.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_scene.h>

// A change to `node`'s own state; `structural` when the tree's shape changed (nodes made,
// moved, stacked or destroyed), which the owner treats as a change of everything.
static void report(struct rediwm_node *node, bool structural) {
  struct rediwm_scene *scene = node->scene;
  if (scene && scene->changed) scene->changed(scene->changed_data, node, structural);
}
static void changed(struct rediwm_node *node) { report(node, false); }
static void structure(struct rediwm_node *node) { report(node, true); }
// The root and the layers under it are what groups hang from: a change to one of them
// touches every group below.
static bool is_layer(const struct rediwm_node *node) {
  return !node->parent || !node->parent->node.parent;
}

static void buffer_damaged(struct rediwm_buffer *b, const pixman_region32_t *damage) {
  struct rediwm_scene *scene = b->node.scene;
  if (scene && scene->buffer_damaged) scene->buffer_damaged(scene->changed_data, b, damage);
}

static void node_init(struct rediwm_node *node, enum rediwm_node_type type, struct rediwm_tree *parent) {
  node->type = type;
  node->parent = parent;
  node->enabled = true;
  node->x = node->y = 0;
  node->data = NULL;
  node->props = node->group = NULL;
  wl_signal_init(&node->events.destroy);
  wlr_addon_set_init(&node->addons);
  wl_list_init(&node->link);
  if (parent) {
    node->scene = parent->node.scene;
    wl_list_insert(parent->children.prev, &node->link);
  } else {
    node->scene = NULL;
  }
}

struct rediwm_scene *rediwm_scene_create(struct wlr_scene_tree *host,
                                         void (*notify)(void *, struct rediwm_node *, bool),
                                         void *data) {
  struct rediwm_scene *scene = calloc(1, sizeof(*scene));
  if (!scene) return NULL;
  scene->host = host;
  node_init(&scene->tree.node, REDIWM_NODE_TREE, NULL);
  wl_list_init(&scene->tree.children);
  scene->tree.node.scene = scene;
  scene->changed = notify;
  scene->changed_data = data;
  return scene;
}

void rediwm_scene_destroy(struct rediwm_scene *scene) {
  if (!scene) return;
  // Nothing may call back into an owner that is already going away.
  scene->changed = NULL;
  rediwm_node_destroy(&scene->tree.node);
}

struct rediwm_tree *rediwm_tree_create(struct rediwm_tree *parent) {
  struct rediwm_tree *tree = calloc(1, sizeof(*tree));
  if (!tree) return NULL;
  node_init(&tree->node, REDIWM_NODE_TREE, parent);
  wl_list_init(&tree->children);
  structure(&tree->node);
  return tree;
}

struct rediwm_rect *rediwm_rect_create(struct rediwm_tree *parent, int width, int height,
                                       const float color[4]) {
  struct rediwm_rect *rect = calloc(1, sizeof(*rect));
  if (!rect) return NULL;
  rect->carrier = wlr_scene_rect_create(parent->node.scene->host, width, height, color);
  if (!rect->carrier) {
    free(rect);
    return NULL;
  }
  node_init(&rect->node, REDIWM_NODE_RECT, parent);
  rect->width = width;
  rect->height = height;
  memcpy(rect->color, color, sizeof(rect->color));
  structure(&rect->node);
  return rect;
}

struct rediwm_buffer *rediwm_buffer_create(struct rediwm_tree *parent, struct wlr_buffer *buffer) {
  struct rediwm_buffer *b = calloc(1, sizeof(*b));
  if (!b) return NULL;
  b->carrier = wlr_scene_buffer_create(parent->node.scene->host, NULL);
  if (!b->carrier) {
    free(b);
    return NULL;
  }
  node_init(&b->node, REDIWM_NODE_BUFFER, parent);
  b->opacity = 1;
  b->filter_mode = WLR_SCALE_FILTER_BILINEAR;
  b->transform = WL_OUTPUT_TRANSFORM_NORMAL;
  pixman_region32_init(&b->opaque_region);
  if (buffer) rediwm_buffer_set_buffer(b, buffer);
  structure(&b->node);
  return b;
}

static void foreign_wlr_destroyed(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_foreign *f = wl_container_of(listener, f, wlr_destroy);
  wl_list_remove(&f->wlr_destroy.link);
  f->wlr = NULL;
  rediwm_node_destroy(&f->node);
}

struct rediwm_foreign *rediwm_foreign_create(struct rediwm_tree *parent, struct wlr_scene_node *wlr) {
  struct rediwm_foreign *f = calloc(1, sizeof(*f));
  if (!f) return NULL;
  node_init(&f->node, REDIWM_NODE_FOREIGN, parent);
  f->wlr = wlr;
  f->wlr_destroy.notify = foreign_wlr_destroyed;
  wl_signal_add(&wlr->events.destroy, &f->wlr_destroy);
  structure(&f->node);
  return f;
}

struct wlr_scene_tree *rediwm_tree_host(const struct rediwm_tree *tree) {
  return tree->node.scene->host;
}

void rediwm_node_destroy(struct rediwm_node *node) {
  if (!node) return;
  wl_signal_emit_mutable(&node->events.destroy, NULL);
  if (node->type == REDIWM_NODE_TREE) {
    struct rediwm_tree *tree = (struct rediwm_tree *)node;
    struct rediwm_node *child, *tmp;
    wl_list_for_each_safe(child, tmp, &tree->children, link) rediwm_node_destroy(child);
  } else if (node->type == REDIWM_NODE_FOREIGN) {
    struct rediwm_foreign *f = (struct rediwm_foreign *)node;
    if (f->wlr) {
      wl_list_remove(&f->wlr_destroy.link);
      struct wlr_scene_node *wlr = f->wlr;
      f->wlr = NULL;
      wlr_scene_node_destroy(wlr);
    }
  } else if (node->type == REDIWM_NODE_RECT) {
    wlr_scene_node_destroy(&((struct rediwm_rect *)node)->carrier->node);
  } else if (node->type == REDIWM_NODE_BUFFER) {
    struct rediwm_buffer *b = (struct rediwm_buffer *)node;
    wlr_scene_node_destroy(&b->carrier->node);
    pixman_region32_fini(&b->opaque_region);
  }
  // Report before the node and its scene are gone; a root has no parent to tell.
  const bool shown = node->parent != NULL;
  struct rediwm_scene *scene = node->scene;
  wlr_addon_set_finish(&node->addons);
  wl_list_remove(&node->link);
  free(node);
  if (shown && scene && scene->changed) scene->changed(scene->changed_data, NULL, true);
}

void rediwm_node_touch(struct rediwm_node *node) { report(node, is_layer(node)); }

void rediwm_node_set_enabled(struct rediwm_node *node, bool enabled) {
  if (node->enabled == enabled) return;
  node->enabled = enabled;
  report(node, is_layer(node));
}

void rediwm_node_set_position(struct rediwm_node *node, int x, int y) {
  if (node->x == x && node->y == y) return;
  node->x = x;
  node->y = y;
  report(node, is_layer(node));
}

// Moves the node to follow `after` (a link of its parent's list, or the list head).
static void move_after(struct rediwm_node *node, struct wl_list *after) {
  wl_list_remove(&node->link);
  wl_list_insert(after, &node->link);
  structure(node);
}

void rediwm_node_raise_to_top(struct rediwm_node *node) {
  if (!node->parent || node->link.next == &node->parent->children) return;
  move_after(node, node->parent->children.prev);
}

void rediwm_node_lower_to_bottom(struct rediwm_node *node) {
  if (!node->parent || node->link.prev == &node->parent->children) return;
  move_after(node, &node->parent->children);
}

void rediwm_node_place_above(struct rediwm_node *node, struct rediwm_node *sibling) {
  if (node == sibling || !node->parent || node->parent != sibling->parent ||
      node->link.prev == &sibling->link)
    return;
  move_after(node, &sibling->link);
}

void rediwm_node_place_below(struct rediwm_node *node, struct rediwm_node *sibling) {
  if (node == sibling || !node->parent || node->parent != sibling->parent ||
      node->link.next == &sibling->link)
    return;
  move_after(node, sibling->link.prev);
}

static bool is_ancestor(const struct rediwm_node *ancestor, const struct rediwm_node *node) {
  for (const struct rediwm_tree *t = node->parent; t; t = t->node.parent)
    if (&t->node == ancestor) return true;
  return false;
}

void rediwm_node_reparent(struct rediwm_node *node, struct rediwm_tree *parent) {
  if (!node->parent || node->parent == parent) return;
  if (&parent->node == node || is_ancestor(node, &parent->node)) return;
  wl_list_remove(&node->link);
  node->parent = parent;
  wl_list_insert(parent->children.prev, &node->link);
  // A different scene keeps its own owner informed from now on.
  struct rediwm_scene *from = node->scene;
  node->scene = parent->node.scene;
  if (from && from != node->scene && from->changed) from->changed(from->changed_data, NULL, true);
  structure(node);
}

bool rediwm_node_coords(struct rediwm_node *node, int *lx, int *ly) {
  int x = 0, y = 0;
  bool enabled = true;
  for (struct rediwm_node *n = node; n; n = n->parent ? &n->parent->node : NULL) {
    x += n->x;
    y += n->y;
    enabled = enabled && n->enabled;
  }
  if (lx) *lx = x;
  if (ly) *ly = y;
  return enabled;
}

bool rediwm_node_visible(const struct rediwm_node *node) {
  for (; node; node = node->parent ? &node->parent->node : NULL)
    if (!node->enabled) return false;
  return true;
}

void rediwm_rect_set_size(struct rediwm_rect *rect, int width, int height) {
  if (rect->width == width && rect->height == height) return;
  rect->width = width;
  rect->height = height;
  wlr_scene_rect_set_size(rect->carrier, width, height);
  changed(&rect->node);
}

void rediwm_rect_set_color(struct rediwm_rect *rect, const float color[4]) {
  if (!memcmp(rect->color, color, sizeof(rect->color))) return;
  memcpy(rect->color, color, sizeof(rect->color));
  wlr_scene_rect_set_color(rect->carrier, color);
  changed(&rect->node);
}

void rediwm_buffer_set_buffer(struct rediwm_buffer *b, struct wlr_buffer *buffer) {
  // A buffer set again is new content even if the pointer matches: a compositor-owned
  // buffer is redrawn in place, and the projection is told its damage separately.
  wlr_scene_buffer_set_buffer(b->carrier, buffer);
  b->buffer_width = buffer ? buffer->width : 0;
  b->buffer_height = buffer ? buffer->height : 0;
  buffer_damaged(b, NULL);
  changed(&b->node);
}

void rediwm_buffer_set_buffer_with_damage(struct rediwm_buffer *b, struct wlr_buffer *buffer,
                                         const pixman_region32_t *damage) {
  wlr_scene_buffer_set_buffer_with_damage(b->carrier, buffer, damage);
  b->buffer_width = buffer ? buffer->width : 0;
  b->buffer_height = buffer ? buffer->height : 0;
  buffer_damaged(b, damage);
  changed(&b->node);
}

struct wlr_buffer *rediwm_buffer_get_buffer(const struct rediwm_buffer *b) {
  return b->carrier->buffer;
}

void rediwm_buffer_set_dest_size(struct rediwm_buffer *b, int width, int height) {
  if (b->dst_width == width && b->dst_height == height) return;
  b->dst_width = width;
  b->dst_height = height;
  wlr_scene_buffer_set_dest_size(b->carrier, width, height);
  changed(&b->node);
}

void rediwm_buffer_set_source_box(struct rediwm_buffer *b, const struct wlr_fbox *box) {
  const struct wlr_fbox none = {0};
  const struct wlr_fbox *next = box ? box : &none;
  if (!memcmp(&b->src_box, next, sizeof(*next))) return;
  b->src_box = *next;
  wlr_scene_buffer_set_source_box(b->carrier, box);
  changed(&b->node);
}

void rediwm_buffer_set_opacity(struct rediwm_buffer *b, float opacity) {
  if (b->opacity == opacity) return;
  b->opacity = opacity;
  wlr_scene_buffer_set_opacity(b->carrier, opacity);
  changed(&b->node);
}

void rediwm_buffer_set_filter_mode(struct rediwm_buffer *b, enum wlr_scale_filter_mode mode) {
  if (b->filter_mode == mode) return;
  b->filter_mode = mode;
  wlr_scene_buffer_set_filter_mode(b->carrier, mode);
  changed(&b->node);
}

void rediwm_buffer_set_transform(struct rediwm_buffer *b, enum wl_output_transform transform) {
  if (b->transform == transform) return;
  b->transform = transform;
  wlr_scene_buffer_set_transform(b->carrier, transform);
  changed(&b->node);
}

void rediwm_buffer_set_opaque_region(struct rediwm_buffer *b, const pixman_region32_t *region) {
  if (!region) {
    if (!pixman_region32_not_empty(&b->opaque_region)) return;
    pixman_region32_clear(&b->opaque_region);
  } else {
    if (pixman_region32_equal((pixman_region32_t *)region, &b->opaque_region)) return;
    pixman_region32_copy(&b->opaque_region, region);
  }
  wlr_scene_buffer_set_opaque_region(b->carrier, &b->opaque_region);
  changed(&b->node);
}

void rediwm_buffer_size(const struct rediwm_buffer *b, int *width, int *height) {
  int w = b->dst_width, h = b->dst_height;
  if (!w || !h) {
    w = b->buffer_width;
    h = b->buffer_height;
    if (b->transform & 1) {
      const int tmp = w;
      w = h;
      h = tmp;
    }
  }
  if (width) *width = w;
  if (height) *height = h;
}

struct rediwm_node *rediwm_node_at(struct rediwm_node *node, double x, double y, double *nx, double *ny) {
  if (!node->enabled) return NULL;
  x -= node->x;
  y -= node->y;
  switch (node->type) {
  case REDIWM_NODE_TREE: {
    struct rediwm_tree *tree = (struct rediwm_tree *)node;
    for (struct wl_list *link = tree->children.prev; link != &tree->children; link = link->prev) {
      struct rediwm_node *child = wl_container_of(link, child, link);
      struct rediwm_node *hit = rediwm_node_at(child, x, y, nx, ny);
      if (hit) return hit;
    }
    return NULL;
  }
  case REDIWM_NODE_RECT: {
    struct rediwm_rect *rect = (struct rediwm_rect *)node;
    if (x < 0 || y < 0 || x >= rect->width || y >= rect->height) return NULL;
    break;
  }
  case REDIWM_NODE_BUFFER: {
    struct rediwm_buffer *b = (struct rediwm_buffer *)node;
    int width, height;
    rediwm_buffer_size(b, &width, &height);
    if (x < 0 || y < 0 || x >= width || y >= height) return NULL;
    if (b->point_accepts_input && !b->point_accepts_input(b, &x, &y)) return NULL;
    break;
  }
  case REDIWM_NODE_FOREIGN:
    return NULL;
  }
  if (nx) *nx = x;
  if (ny) *ny = y;
  return node;
}

static void for_each_buffer(struct rediwm_node *node, int x, int y, rediwm_buffer_iterator fn, void *data) {
  if (!node->enabled) return;
  x += node->x;
  y += node->y;
  if (node->type == REDIWM_NODE_TREE) {
    struct rediwm_node *child;
    wl_list_for_each(child, &((struct rediwm_tree *)node)->children, link)
        for_each_buffer(child, x, y, fn, data);
  } else if (node->type == REDIWM_NODE_BUFFER) {
    fn((struct rediwm_buffer *)node, x, y, data);
  }
}

void rediwm_node_for_each_buffer(struct rediwm_node *node, rediwm_buffer_iterator fn, void *data) {
  // Relative to the node passed in, as wlr_scene_node_for_each_buffer.
  if (!node->enabled) return;
  if (node->type == REDIWM_NODE_TREE) {
    struct rediwm_node *child;
    wl_list_for_each(child, &((struct rediwm_tree *)node)->children, link)
        for_each_buffer(child, 0, 0, fn, data);
  } else if (node->type == REDIWM_NODE_BUFFER) {
    fn((struct rediwm_buffer *)node, 0, 0, data);
  }
}

struct wlr_iteration {
  rediwm_wlr_buffer_iterator fn;
  void *data;
  int x, y;
};
static void wlr_buffer_shifted(struct wlr_scene_buffer *b, int sx, int sy, void *data) {
  struct wlr_iteration *it = data;
  it->fn(b, it->x + sx, it->y + sy, it->data);
}
static void for_each_wlr_buffer(struct rediwm_node *node, int x, int y, rediwm_wlr_buffer_iterator fn, void *data) {
  if (!node->enabled) return;
  x += node->x;
  y += node->y;
  if (node->type == REDIWM_NODE_TREE) {
    struct rediwm_node *child;
    wl_list_for_each(child, &((struct rediwm_tree *)node)->children, link)
        for_each_wlr_buffer(child, x, y, fn, data);
  } else if (node->type == REDIWM_NODE_FOREIGN) {
    struct rediwm_foreign *f = (struct rediwm_foreign *)node;
    struct wlr_iteration it = {.fn = fn, .data = data, .x = x, .y = y};
    if (f->wlr) wlr_scene_node_for_each_buffer(f->wlr, wlr_buffer_shifted, &it);
  }
}

void rediwm_node_for_each_wlr_buffer(struct rediwm_node *node, rediwm_wlr_buffer_iterator fn, void *data) {
  if (!node->enabled) return;
  if (node->type == REDIWM_NODE_TREE) {
    struct rediwm_node *child;
    wl_list_for_each(child, &((struct rediwm_tree *)node)->children, link)
        for_each_wlr_buffer(child, 0, 0, fn, data);
  } else if (node->type == REDIWM_NODE_FOREIGN) {
    for_each_wlr_buffer(node, -node->x, -node->y, fn, data);
  }
}
