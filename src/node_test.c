// Own scene nodes: tree structure, the change hook, stacking, picking and teardown.
// No wlroots backend or renderer is needed.
#define WLR_USE_UNSTABLE
#include "node.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_buffer.h>

static int changes;
static void on_change(void *data, struct rediwm_node *node, bool structural) {
  (void)data;
  (void)node;
  (void)structural;
  changes++;
}

static void buffer_destroy(struct wlr_buffer *buffer) { free(buffer); }
static const struct wlr_buffer_impl buffer_impl = {.destroy = buffer_destroy};
static struct wlr_buffer *buffer_create(int width, int height) {
  struct wlr_buffer *buffer = calloc(1, sizeof(*buffer));
  assert(buffer);
  wlr_buffer_init(buffer, &buffer_impl, width, height);
  return buffer;
}

static struct rediwm_node *nth(struct rediwm_tree *tree, int n) {
  struct rediwm_node *node;
  wl_list_for_each(node, &tree->children, link) if (n-- == 0) return node;
  return NULL;
}

static int destroyed;
static void on_destroy(struct wl_listener *l, void *data) {
  (void)l;
  (void)data;
  destroyed++;
}

static bool accepts_left_half(struct rediwm_buffer *b, double *x, double *y) {
  (void)y;
  int width, height;
  rediwm_buffer_size(b, &width, &height);
  return *x < width / 2.0;
}

static void collect(struct rediwm_buffer *b, int sx, int sy, void *data) {
  int *out = data;
  out[0]++;
  out[1] = sx;
  out[2] = sy;
  (void)b;
}

int main(void) {
  struct rediwm_scene *scene = rediwm_scene_create(on_change, NULL);
  assert(scene && scene->tree.node.enabled && !scene->tree.node.parent);

  // Creation reports, a no-op mutation does not.
  struct rediwm_tree *a = rediwm_tree_create(&scene->tree);
  struct rediwm_tree *b = rediwm_tree_create(&scene->tree);
  assert(a && b && changes == 2);
  assert(nth(&scene->tree, 0) == &a->node && nth(&scene->tree, 1) == &b->node);
  changes = 0;
  rediwm_node_set_position(&a->node, 0, 0);
  rediwm_node_set_enabled(&a->node, true);
  assert(changes == 0);
  rediwm_node_set_position(&a->node, 10, 20);
  rediwm_node_set_enabled(&a->node, false);
  rediwm_node_set_enabled(&a->node, true);
  assert(changes == 3);

  // Coordinates sum the ancestors, and a disabled one hides the subtree.
  struct rediwm_tree *inner = rediwm_tree_create(a);
  rediwm_node_set_position(&inner->node, 5, 7);
  int lx, ly;
  assert(rediwm_node_coords(&inner->node, &lx, &ly) && lx == 15 && ly == 27);
  rediwm_node_set_enabled(&a->node, false);
  assert(!rediwm_node_coords(&inner->node, &lx, &ly) && lx == 15 && ly == 27);
  assert(!rediwm_node_visible(&inner->node));
  rediwm_node_set_enabled(&a->node, true);
  assert(rediwm_node_visible(&inner->node));

  // Stacking.
  changes = 0;
  rediwm_node_raise_to_top(&b->node);
  assert(changes == 0); // already on top
  rediwm_node_raise_to_top(&a->node);
  assert(nth(&scene->tree, 1) == &a->node && changes == 1);
  rediwm_node_place_below(&a->node, &b->node);
  assert(nth(&scene->tree, 0) == &a->node);
  rediwm_node_place_above(&a->node, &b->node);
  assert(nth(&scene->tree, 1) == &a->node);
  rediwm_node_lower_to_bottom(&a->node);
  assert(nth(&scene->tree, 0) == &a->node);
  rediwm_node_place_above(&a->node, &inner->node); // not a sibling: ignored
  assert(nth(&scene->tree, 0) == &a->node);

  // Reparenting goes to the top of the new parent and refuses a cycle.
  rediwm_node_reparent(&inner->node, b);
  assert(inner->node.parent == b && nth(b, 0) == &inner->node);
  rediwm_node_reparent(&b->node, inner);
  assert(b->node.parent == &scene->tree);
  rediwm_node_reparent(&b->node, b);
  assert(b->node.parent == &scene->tree);

  // Rect and buffer state.
  const float red[4] = {1, 0, 0, 1};
  struct rediwm_rect *rect = rediwm_rect_create(&scene->tree, 30, 20, red);
  changes = 0;
  rediwm_rect_set_size(rect, 30, 20);
  rediwm_rect_set_color(rect, red);
  assert(changes == 0);
  rediwm_rect_set_size(rect, 31, 20);
  assert(changes == 1 && rect->width == 31);

  struct wlr_buffer *raw = buffer_create(200, 100);
  struct rediwm_buffer *buf = rediwm_buffer_create(&scene->tree, raw);
  wlr_buffer_drop(raw); // the node keeps its own lock
  assert(rediwm_buffer_get_buffer(buf) == raw && buf->buffer_width == 200 && buf->buffer_height == 100);
  int w, h;
  rediwm_buffer_size(buf, &w, &h);
  assert(w == 200 && h == 100);
  rediwm_buffer_set_transform(buf, WL_OUTPUT_TRANSFORM_90);
  rediwm_buffer_size(buf, &w, &h);
  assert(w == 100 && h == 200);
  rediwm_buffer_set_transform(buf, WL_OUTPUT_TRANSFORM_NORMAL);
  rediwm_buffer_set_dest_size(buf, 40, 40);
  rediwm_buffer_size(buf, &w, &h);
  assert(w == 40 && h == 40);
  changes = 0;
  rediwm_buffer_set_dest_size(buf, 40, 40);
  rediwm_buffer_set_opacity(buf, 1);
  rediwm_buffer_set_filter_mode(buf, WLR_SCALE_FILTER_BILINEAR);
  rediwm_buffer_set_source_box(buf, NULL);
  rediwm_buffer_set_opaque_region(buf, NULL);
  assert(changes == 0);
  rediwm_buffer_set_opacity(buf, 0.5f);
  rediwm_buffer_set_filter_mode(buf, WLR_SCALE_FILTER_NEAREST);
  assert(changes == 2);
  pixman_region32_t opaque;
  pixman_region32_init_rect(&opaque, 0, 0, 10, 10);
  rediwm_buffer_set_opaque_region(buf, &opaque);
  rediwm_buffer_set_opaque_region(buf, &opaque);
  assert(changes == 3 && pixman_region32_not_empty(&buf->opaque_region));
  pixman_region32_fini(&opaque);

  // Picking: topmost first, in the node's own coordinates, honouring input rules.
  rediwm_node_set_position(&rect->node, 100, 100);
  rediwm_node_set_position(&buf->node, 100, 100);
  buf->point_accepts_input = accepts_left_half;
  double nx = -1, ny = -1;
  assert(rediwm_node_at(&scene->tree.node, 110, 105, &nx, &ny) == &buf->node && nx == 10 && ny == 5);
  assert(rediwm_node_at(&scene->tree.node, 130, 105, &nx, &ny) == &rect->node && nx == 30 && ny == 5);
  assert(!rediwm_node_at(&scene->tree.node, 99, 100, &nx, &ny));
  rediwm_node_set_enabled(&buf->node, false);
  assert(rediwm_node_at(&scene->tree.node, 110, 105, &nx, &ny) == &rect->node);
  rediwm_node_set_enabled(&buf->node, true);

  int seen[3] = {0};
  rediwm_node_for_each_buffer(&scene->tree.node, collect, seen);
  assert(seen[0] == 1 && seen[1] == 100 && seen[2] == 100);

  // Teardown: children go with the tree, each reports, addons are finished, and the
  // buffer lock is released (the buffer is freed with its last lock).
  struct wl_listener listener = {.notify = on_destroy};
  wl_signal_add(&b->node.events.destroy, &listener);
  struct wl_listener inner_listener = {.notify = on_destroy};
  wl_signal_add(&inner->node.events.destroy, &inner_listener);
  changes = 0;
  rediwm_node_destroy(&b->node);
  assert(destroyed == 2 && changes >= 1);
  assert(nth(&scene->tree, 0) == &a->node);
  rediwm_node_destroy(&buf->node);

  rediwm_scene_destroy(scene);
  puts("node tests passed");
  return 0;
}
