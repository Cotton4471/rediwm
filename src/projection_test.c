// Synthetic surface commits into the real projection and wlroots scene damage
// path. No renderer, GPU, socket or host desktop is needed.
#include "projection.c"
#include "node.h"
#include <assert.h>
#include <stdio.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_output_layout.h>


// One own scene and a world layer, per test.
struct rig {
  struct rediwm_scene *own, *parking; // `parking` holds what the pass no longer reaches
  struct rediwm_tree *world;
};
static struct rig rig_create(struct rediwm_scene_outputs *scene) {
  (void)scene;
  struct rig rig = {0};
  rig.own = rediwm_scene_create(NULL, NULL);
  rig.parking = rediwm_scene_create(NULL, NULL);
  assert(rig.own && rig.parking);
  rig.world = rediwm_tree_create(&rig.own->tree);
  assert(rig.world);
  return rig;
}
static void rig_destroy(struct rig *rig) {
  rediwm_scene_destroy(rig->own);
  rediwm_scene_destroy(rig->parking);
}
static struct leaf *leaf_of(struct rediwm_projection *p, struct rediwm_node *node) {
  struct leaf *l = node->leaf;
  return l && l->projection == p ? l : NULL;
}

static struct rediwm_node *pick(struct rediwm_projection *p, double x, double y, double *nx, double *ny) {
  struct rediwm_hit hit;
  if (!rediwm_projection_node_at(p, x, y, &hit)) return NULL;
  if (nx) *nx = hit.x;
  if (ny) *ny = hit.y;
  return hit.own;
}

static struct rediwm_node *effect_node;
bool rediwm_glass_is_effect_node(struct rediwm_node *node) {
  return node == effect_node;
}
// glass.c is not linked here: the stub effect keeps its own box.
bool rediwm_glass_effect_info(struct rediwm_node *node, struct rediwm_glass_info *out) {
  (void)node;
  (void)out;
  return false;
}
static void buffer_destroy(struct wlr_buffer *buffer) { free(buffer); }
static const struct wlr_buffer_impl buffer_impl = {.destroy = buffer_destroy};
static struct wlr_buffer *buffer_create(void) {
  struct wlr_buffer *buffer = calloc(1, sizeof(*buffer));
  assert(buffer);
  wlr_buffer_init(buffer, &buffer_impl, 200, 120);
  return buffer;
}
static void commit_damage(struct leaf *l, int x, int y, int width, int height) {
  struct wlr_surface *surface = l->surface->surface;
  pixman_region32_clear(&surface->buffer_damage);
  assert(pixman_region32_union_rect(&surface->buffer_damage,
      &surface->buffer_damage, x, y, width, height));
  committed(&l->commit, NULL);
}
static bool damaged(struct rediwm_scene_output *out, int x, int y) {
  return pixman_region32_contains_point(&out->damage_ring.current, x, y, NULL);
}
static void clear_damage(struct rediwm_scene_output *out) {
  pixman_region32_clear(&out->damage_ring.current);
  pixman_region32_clear(&out->pending_commit_damage);
}
// Where the graph puts a leaf once rounded in layout space.
static void assert_position(struct rediwm_projection *p,
                            struct rediwm_node *source, int x, int y) {
  struct leaf *l = leaf_of(p, source);
  assert(l);
  const struct rediwm_snap s = rediwm_edges_snap(l->item.edges);
  assert(s.x == x && s.y == y);
}
// Runs when a window's source tree is destroyed, after the projection dropped its
// group and before the leaves are destroyed with their nodes. A leaf that still
// listed itself in that group would point into freed memory here; no allocator
// reliably shows that (glibc does not poison small chunks on free), so check
// the links themselves.
struct probe {
  struct wl_listener listener;
  struct leaf *leaves[8];
  size_t count;
  int *checks;
};
static void probe_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct probe *probe = wl_container_of(listener, probe, listener);
  for (size_t i = 0; i < probe->count; i++) {
    assert(probe->leaves[i]->paint.next == &probe->leaves[i]->paint &&
           probe->leaves[i]->paint.prev == &probe->leaves[i]->paint);
    ++*probe->checks;
  }
  wl_list_remove(&listener->link);
  free(probe);
}
static void probe_group(struct group *g, int *checks) {
  struct probe *probe = calloc(1, sizeof(*probe));
  assert(probe);
  struct leaf *l;
  wl_list_for_each(l, &g->items, paint) {
    assert(probe->count < 8);
    probe->leaves[probe->count++] = l;
  }
  probe->checks = checks;
  probe->listener.notify = probe_destroy;
  wl_signal_add(&g->source->events.destroy, &probe->listener);
}
static bool near(double a, double b) { return fabs(a - b) < 1e-9; }
static size_t items_of(struct group *g, struct leaf **out, size_t max) {
  size_t n = 0;
  struct leaf *l;
  wl_list_for_each(l, &g->items, paint) {
    assert(n < max);
    out[n++] = l;
  }
  return n;
}
// What a sync leaves: every group and leaf in the lists was reached by this pass,
// and nothing else is listed.
static void assert_presented(struct rediwm_projection *p) {
  struct group *g;
  wl_list_for_each(g, &p->paint, paint) {
    assert(g->seen);
    struct leaf *l;
    wl_list_for_each(l, &g->items, paint) assert(l->seen);
  }
}
// The typed graph: complete and in paint order before anything is presented,
// unrounded, and the only source of geometry.
struct graph_probe {
  struct rediwm_node *transport;
  struct rediwm_item expected;
  int count;
};
static bool probe_item(const struct rediwm_item *item, struct rediwm_node *transport, void *data) {
  struct graph_probe *probe = data;
  if (transport != probe->transport) return true;
  probe->count++;
  assert(item->edges.x1 == probe->expected.edges.x1 && item->edges.y1 == probe->expected.edges.y1);
  assert(item->edges.x2 == probe->expected.edges.x2 && item->edges.y2 == probe->expected.edges.y2);
  assert(item->kind == probe->expected.kind && rediwm_content_equal(&item->content, &probe->expected.content));
  return true;
}
// A sync with nothing changed resolves nothing; every kind of change brings it back.
static void test_clean_sync(struct rediwm_scene_outputs *scene) {
  struct rig rig = rig_create(scene);
  struct rediwm_projection *p = rediwm_projection_create(rig.own, rig.world, scene);
  struct wlr_buffer *buffer = buffer_create();
  struct rediwm_tree *frame = rediwm_tree_create(rig.world);
  struct rediwm_buffer *node = rediwm_buffer_create(frame, buffer);
  rediwm_buffer_set_dest_size(node, 40, 30);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *l = leaf_of(p, &node->node);
  assert(l && l->item.edges.x2 - l->item.edges.x1 == 40);
  // Poke the graph: a clean sync leaves it alone.
  l->item.edges.x2 = 12345;
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(l->item.edges.x2 == 12345);
  // The scene changed.
  rediwm_node_set_position(&frame->node, 5, 5);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(l->item.edges.x2 == 45);
  // The camera moved.
  l->item.edges.x2 = 12345;
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(l->item.edges.x2 == 12345);
  rediwm_projection_sync(p, 2, 0, 0, 0, 0);
  assert(l->item.edges.x2 == 90);
  // A tree property changed.
  l->item.edges.x2 = 12345;
  assert(rediwm_projection_set_tree_scale(&frame->node, .5));
  rediwm_projection_sync(p, 2, 0, 0, 0, 0);
  assert(l->item.edges.x2 == 50);
  // A surface commit, or an owned buffer's damage.
  l->item.edges.x2 = 12345;
  rediwm_projection_damage_buffer(p, &node->node, NULL);
  rediwm_projection_sync(p, 2, 0, 0, 0, 0);
  assert(l->item.edges.x2 == 50);
  // Only the group that changed is walked again; a change to the tree's shape walks all.
  const float color[4] = {1, 0, 0, 1};
  struct rediwm_tree *other = rediwm_tree_create(rig.world);
  struct rediwm_rect *rect = rediwm_rect_create(other, 10, 10, color);
  rediwm_projection_sync(p, 2, 0, 0, 0, 0);
  struct leaf *rl = leaf_of(p, &rect->node);
  assert(rl && rl->item.edges.x2 - rl->item.edges.x1 == 20);
  rl->item.edges.x2 = 777;
  l->item.edges.x2 = 12345;
  rediwm_node_set_position(&frame->node, 7, 7);
  rediwm_projection_sync(p, 2, 0, 0, 0, 0);
  assert(l->item.edges.x2 != 12345 && rl->item.edges.x2 == 777);
  rediwm_node_set_position(&rect->node, 1, 1);
  rediwm_projection_sync(p, 2, 0, 0, 0, 0);
  assert(rl->item.edges.x2 != 777);
  rl->item.edges.x2 = 777;
  rediwm_node_raise_to_top(&frame->node);
  rediwm_projection_sync(p, 2, 0, 0, 0, 0);
  assert(rl->item.edges.x2 != 777);
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
}
static void test_graph(struct rediwm_scene_outputs *scene) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct rediwm_tree *frame = rediwm_tree_create(source);
  struct rediwm_tree *nested = rediwm_tree_create(frame);
  struct rediwm_tree *other = rediwm_tree_create(source);
  float color[4] = {.2, .3, .1, 1};
  struct rediwm_rect *border = rediwm_rect_create(frame, 17, 9, color);
  struct wlr_buffer *buffer = buffer_create(), *glass_buffer = buffer_create();
  struct rediwm_buffer *client = rediwm_buffer_create(nested, buffer);
  struct rediwm_buffer *glass = rediwm_buffer_create(frame, glass_buffer);
  struct rediwm_rect *overlay = rediwm_rect_create(other, 20, 20, color);
  assert(frame && nested && other && border && client && glass && overlay);
  rediwm_node_set_position(&frame->node, 37, 29);
  rediwm_node_set_position(&nested->node, -12, 5);
  rediwm_node_set_position(&client->node, 4, 3);
  rediwm_node_set_position(&border->node, -2, -3);
  rediwm_node_set_position(&other->node, 90, 60);
  effect_node = &glass->node;
  rediwm_buffer_set_dest_size(client, 100, 60);
  rediwm_buffer_set_dest_size(glass, 50, 20);
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));

  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_presented(p);
  struct group *g = get_group(p, &frame->node), *h = get_group(p, &other->node);
  struct leaf *border_leaf = leaf_of(p, &border->node), *client_leaf = leaf_of(p, &client->node),
              *glass_leaf = leaf_of(p, &glass->node), *overlay_leaf = leaf_of(p, &overlay->node);
  struct leaf *order[8];
  assert(p->paint.next == &g->paint && g->paint.next == &h->paint && h->paint.next == &p->paint);

  // Kinds. A leaf is a surface only once wlroots has bound it to a wl_surface.
  assert(border_leaf->item.kind == REDIWM_ITEM_RECT);
  assert(client_leaf->item.kind == REDIWM_ITEM_BUFFER);
  assert(glass_leaf->item.kind == REDIWM_ITEM_EFFECT);
  struct wlr_surface surface = {0};
  struct rediwm_surface scene_surface = {.surface = &surface};
  client_leaf->surface = &scene_surface;
  mark_all(p); // the test changed a leaf behind the scene's back
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(client_leaf->item.kind == REDIWM_ITEM_SURFACE);
  client_leaf->surface = NULL; // The synthetic surface has no lifecycle listeners.
  mark_all(p);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(client_leaf->item.kind == REDIWM_ITEM_BUFFER);

  // Paint order, bottom to top, flattened per window.
  assert(items_of(g, order, 8) == 3 && order[0] == client_leaf && order[1] == border_leaf &&
         order[2] == glass_leaf);
  assert(items_of(h, order, 8) == 1 && order[0] == overlay_leaf);

  // Resolving alone shows nothing: what the last present showed is kept.
  const struct rediwm_snap shown_before = client_leaf->shown;
  const double z = .85, cx = 6.5, cy = -2.5, ox = -17, oy = 31;
  resolve(p, z, cx, cy, ox, oy, NULL, true);
  assert(client_leaf->has_shown && client_leaf->shown.x == shown_before.x &&
         client_leaf->shown.y == shown_before.y && client_leaf->shown.width == shown_before.width);

  // The graph holds the exact, unrounded edges: the camera, then the window's
  // zoom about its origin (37, 29), applied to the client at (29, 37) sized
  // 100x60 in source units.
  const double tx = ox * (1 - z) - z * cx, ty = oy * (1 - z) - z * cy, w = .85;
  const double frame_x = z * 37 + tx, frame_y = z * 29 + ty;
  const struct rediwm_edges e = client_leaf->item.edges;
  assert(fabs(e.x1 - (frame_x + z * w * (29 - 37))) < 1e-9);
  assert(fabs(e.y1 - (frame_y + z * w * (37 - 29))) < 1e-9);
  assert(fabs(e.x2 - e.x1 - z * w * 100) < 1e-9 && fabs(e.y2 - e.y1 - z * w * 60) < 1e-9);
  assert(e.x1 != floor(e.x1) && e.y1 != floor(e.y1)); // Fractional until presented.
  // The output consumer sees the newly resolved graph even before present:
  // what was last shown must never become a second source of truth.
  struct graph_probe probe = {.transport = client_leaf->source, .expected = client_leaf->item};
  assert(rediwm_projection_for_each_item(p, false, probe_item, &probe) && probe.count == 1);
  probe.count = 0;
  assert(rediwm_projection_for_each_item(p, true, probe_item, &probe) && probe.count == 1);
  assert(fabs(client_leaf->item.scale - z * w) < 1e-12);
  assert(client_leaf->item.width == 100 && client_leaf->item.height == 60);
  // Edges, not origin and size: a size is the difference of two rounded edges.
  const struct rediwm_snap s = rediwm_edges_snap(e);
  assert(s.width == lround(e.x2) - lround(e.x1) && s.x == lround(e.x1));
  // Scaled content is filtered bilinearly whatever the client asked for.
  rediwm_buffer_set_filter_mode(client, WLR_SCALE_FILTER_NEAREST);
  resolve(p, z, cx, cy, ox, oy, NULL, true);
  assert(client_leaf->item.content.filter_mode == WLR_SCALE_FILTER_BILINEAR);
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(rediwm_projection_set_tree_zoom(&frame->node, 1.0));
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(client_leaf->item.content.filter_mode == WLR_SCALE_FILTER_NEAREST);
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));
  rediwm_buffer_set_filter_mode(client, WLR_SCALE_FILTER_BILINEAR);

  // Presenting shows exactly that graph, and only that graph.
  present(p, true);
  assert_presented(p);
  {
    const struct rediwm_snap now = rediwm_edges_snap(client_leaf->item.edges);
    assert(client_leaf->shown.x == now.x && client_leaf->shown.y == now.y &&
           client_leaf->shown.width == now.width && client_leaf->shown.height == now.height);
  }
  const double zooms[] = {.25, .5, .85, 1, 1.25};
  for (size_t i = 0; i < sizeof(zooms) / sizeof(zooms[0]); ++i)
    for (int x = -9; x <= 9; x += 3) {
      rediwm_node_set_position(&frame->node, x * 7, -x * 5);
      rediwm_projection_sync_fixed(p, zooms[i], x * .5, -x * .25, ox, oy, other);
      assert_presented(p);
      // Fixed: no camera.
      assert(near(overlay_leaf->item.edges.x1, other->node.x) && near(overlay_leaf->item.edges.y1, other->node.y));
    }
  rediwm_node_set_position(&frame->node, 37, 29);

  // Order follows the source: raising a node reorders its list, a reparent
  // moves the leaf between lists, and a disabled branch is still resolved.
  rediwm_node_raise_to_top(&border->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(items_of(g, order, 8) == 3 && order[0] == client_leaf && order[1] == glass_leaf &&
         order[2] == border_leaf);
  rediwm_node_reparent(&client->node, other);
  rediwm_node_set_enabled(&other->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(items_of(g, order, 8) == 2 && order[0] == glass_leaf && order[1] == border_leaf);
  assert(items_of(h, order, 8) == 2 && order[0] == overlay_leaf && order[1] == client_leaf);
  assert(!h->enabled && !client_leaf->item.enabled && !overlay_leaf->item.enabled);
  assert(border_leaf->item.enabled);
  assert_presented(p);
  rediwm_node_set_enabled(&other->node, true);

  // A subtree the pass no longer reaches leaves the graph and is hidden.
  rediwm_node_reparent(&other->node, &rig.parking->tree);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(wl_list_length(&p->paint) == 1 && wl_list_empty(&h->items));
  assert(!h->seen && !client_leaf->seen && !client_leaf->has_shown);
  assert(client_leaf->paint.next == &client_leaf->paint);
  rediwm_node_reparent(&other->node, source);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(wl_list_length(&p->paint) == 2 && wl_list_length(&h->items) == 2);
  assert_presented(p);

  // Destruction with the lists linked: a leaf leaves its list with its source,
  // a group takes the leaves it still lists with it, and neither order of
  // teardown touches freed list heads.
  rediwm_node_destroy(&overlay->node);
  assert(wl_list_length(&h->items) == 1 && wl_list_length(&p->leaves) == 3);
  rediwm_node_destroy(&other->node);
  assert(wl_list_length(&p->paint) == 1 && wl_list_length(&p->groups) == 1);
  assert(wl_list_length(&g->items) == 2);
  effect_node = NULL;
  int checks = 0;
  probe_group(g, &checks);
  rediwm_node_destroy(&frame->node); // The group goes first, then its leaves.
  assert(checks == 2); // Both leaves were checked after the group was freed.
  assert(wl_list_empty(&p->groups) && wl_list_empty(&p->leaves) && wl_list_empty(&p->paint));
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
  wlr_buffer_drop(glass_buffer);
}
// Stage 4: the clip shape. Pure geometry first, with no scene at all.
static void test_clip_geometry(void) {
  // Resolve composes the camera and the window's zoom into the transform, takes
  // the rectangle's edges from it, scales radius and border, and caps a radius
  // at half the short side first.
  const struct rediwm_xform camera = rediwm_xform_camera(.85, 6.5, -2.5, -17, 31);
  const struct rediwm_xform t = rediwm_xform_scale_about(camera, .75, 37, 29);
  const struct rediwm_clip_spec spec = {.width = 120, .height = 80, .radii = {10, 10, 6, 60}, .border = 1};
  const struct rediwm_clip clip = rediwm_clip_resolve(t, 37, 29, &spec);
  const struct rediwm_edges expected = rediwm_xform_rect(t, 37, 29, 120, 80);
  assert(clip.edges.x1 == expected.x1 && clip.edges.y1 == expected.y1 &&
         clip.edges.x2 == expected.x2 && clip.edges.y2 == expected.y2);
  assert(near(clip.radii[0], 10 * t.scale) && near(clip.radii[2], 6 * t.scale));
  assert(near(clip.radii[3], 40 * t.scale)); // 60 capped to half of the 80 side.
  assert(near(clip.border, t.scale));

  // The distance, in a 100x60 box at (20, 10) with radius 10.
  const double all[4] = {10, 10, 10, 10};
  const double arc = 10 * (1 - sqrt(.5));
  assert(near(rediwm_sd_rounded_box(70, 40, 20, 10, 100, 60, all), -20 - 10));
  assert(near(rediwm_sd_rounded_box(70, 10, 20, 10, 100, 60, all), 0)); // On the top edge.
  assert(near(rediwm_sd_rounded_box(20, 40, 20, 10, 100, 60, all), 0)); // On the left edge.
  assert(near(rediwm_sd_rounded_box(20 + arc, 10 + arc, 20, 10, 100, 60, all), 0)); // On the arc.
  assert(near(rediwm_sd_rounded_box(20, 10, 20, 10, 100, 60, all), 10 * (sqrt(2) - 1)));
  assert(rediwm_sd_rounded_box(20 + arc + 1, 10 + arc + 1, 20, 10, 100, 60, all) < 0);
  // Each corner has its own radius: the sharp one reaches the bounding corner,
  // the large one stays away from it, and the others are untouched.
  const double mixed[4] = {0, 20, 5, 10};
  assert(near(rediwm_sd_rounded_box(20, 10, 20, 10, 100, 60, mixed), 0));
  assert(near(rediwm_sd_rounded_box(120, 10, 20, 10, 100, 60, mixed), 20 * (sqrt(2) - 1)));
  assert(near(rediwm_sd_rounded_box(120, 70, 20, 10, 100, 60, mixed), 5 * (sqrt(2) - 1)));
  assert(near(rediwm_sd_rounded_box(20, 70, 20, 10, 100, 60, mixed), 10 * (sqrt(2) - 1)));
  // Symmetric: the same radii mirrored give the mirrored distance.
  const double mirrored[4] = {20, 0, 10, 5};
  for (double px = 18; px <= 122; px += 6.5)
    for (double py = 8; py <= 72; py += 5.5)
      assert(near(rediwm_sd_rounded_box(px, py, 20, 10, 100, 60, mixed),
                  rediwm_sd_rounded_box(140 - px, py, 20, 10, 100, 60, mirrored)));
  // Coverage is the one-pixel ramp the CPU chrome and the shader both use.
  assert(rediwm_coverage(-.5) == 1 && rediwm_coverage(-3) == 1 && rediwm_coverage(.5) == 0 &&
         rediwm_coverage(9) == 0 && near(rediwm_coverage(0), .5) && near(rediwm_coverage(.25), .25));
}
// Every pixel the opaque cover claims must be fully covered by the shape, and it
// may leave out only the corner squares. Checked in the clip's own pixel grid,
// for fractional origins and for clips authored at fractional scales.
static void test_clip_opaque(void) {
  const int sizes[][2] = {{40, 40}, {120, 80}, {121, 79}, {300, 200}, {17, 60}, {8, 8}};
  const double radii[][4] = {{10, 10, 10, 10}, {0, 0, 0, 0}, {10, 4, 0, 20}, {30, 30, 6, 6},
                             {50, 50, 50, 50}, {0, 0, 12, 12}, {3, 3, 3, 3}};
  const double scales[] = {1, 1.25, 1.5, 2};
  for (size_t si = 0; si < sizeof(sizes) / sizeof(sizes[0]); ++si)
    for (size_t ri = 0; ri < sizeof(radii) / sizeof(radii[0]); ++ri)
      for (size_t k = 0; k < sizeof(scales) / sizeof(scales[0]); ++k) {
        const struct rediwm_clip_spec spec = {
            .width = sizes[si][0], .height = sizes[si][1],
            .radii = {radii[ri][0], radii[ri][1], radii[ri][2], radii[ri][3]}};
        // Authored at the output's scale, at a fractional origin: the space the
        // pass evaluates the shape in.
        const struct rediwm_xform t = {scales[k], 13.3, 7.8};
        const struct rediwm_clip clip = rediwm_clip_resolve(t, 5.1, 3.7, &spec);
        const struct rediwm_snap f = rediwm_edges_snap(clip.edges);
        struct rediwm_snap rects[3];
        const int n = rediwm_clip_opaque(&clip, rects);
        assert(n >= 0 && n <= 3);
        long claimed = 0;
        for (int i = 0; i < n; i++) {
          assert(rects[i].width > 0 && rects[i].height > 0);
          assert(rects[i].x >= f.x && rects[i].y >= f.y &&
                 rects[i].x + rects[i].width <= f.x + f.width &&
                 rects[i].y + rects[i].height <= f.y + f.height);
          for (int y = rects[i].y; y < rects[i].y + rects[i].height; y++)
            for (int x = rects[i].x; x < rects[i].x + rects[i].width; x++) {
              assert(rediwm_coverage(rediwm_sd_rounded_box(x + .5, y + .5, f.x, f.y, f.width,
                                                           f.height, clip.radii)) == 1);
              claimed++;
            }
        }
        // Rectangles never overlap: a pixel claimed twice would be counted twice
        // by a consumer that sums areas.
        for (int i = 0; i < n; i++)
          for (int j = i + 1; j < n; j++)
            assert(rects[i].x + rects[i].width <= rects[j].x || rects[j].x + rects[j].width <= rects[i].x ||
                   rects[i].y + rects[i].height <= rects[j].y || rects[j].y + rects[j].height <= rects[i].y);
        long covered = 0;
        for (int y = f.y; y < f.y + f.height; y++)
          for (int x = f.x; x < f.x + f.width; x++)
            covered += rediwm_coverage(rediwm_sd_rounded_box(x + .5, y + .5, f.x, f.y, f.width,
                                                             f.height, clip.radii)) == 1;
        int inset[4];
        for (int i = 0; i < 4; i++)
          inset[i] = clip.radii[i] > 0 ? (int)ceil(clip.radii[i]) + REDIWM_CLIP_OPAQUE_MARGIN : 0;
        const int top = inset[0] > inset[1] ? inset[0] : inset[1];
        const int bottom = inset[2] > inset[3] ? inset[2] : inset[3];
        // What it leaves out of the fully covered pixels is bounded by the corner
        // squares and the strips beside them, or by the two corner columns when
        // there is no room for a middle band; a window too small for its corners
        // may claim nothing at all.
        const int left = inset[0] > inset[3] ? inset[0] : inset[3];
        const int right = inset[1] > inset[2] ? inset[1] : inset[2];
        const long bound = top + bottom > f.height
                               ? (long)(left + right) * f.height
                               : (long)(inset[0] + inset[1]) * top + (long)(inset[2] + inset[3]) * bottom;
        assert(covered - claimed <= bound);
        if (n == 0) assert(top + bottom > f.height ? f.width - left - right <= 0
                                                    : f.width - inset[0] - inset[1] <= 0 && f.height == top + bottom);
        if (radii[ri][0] + radii[ri][1] + radii[ri][2] + radii[ri][3] == 0) {
          assert(n == 1 && rects[0].x == f.x && rects[0].y == f.y && rects[0].width == f.width &&
                 rects[0].height == f.height); // Square corners lose nothing.
        }
      }
  // A window too small for its corners claims nothing rather than guessing, and a
  // pill keeps the full-height column between its two semicircles.
  struct rediwm_snap one[3];
  const struct rediwm_xform identity = {1, 0, 0};
  assert(rediwm_clip_opaque(&(struct rediwm_clip){rediwm_xform_rect(identity, 0, 0, 8, 8), {4, 4, 4, 4}, 0, {0}, 0, 0, 0, 0, {0}}, one) == 0);
  assert(rediwm_clip_opaque(&(struct rediwm_clip){rediwm_xform_rect(identity, 5, 7, 120, 80), {40, 40, 40, 40}, 0, {0}, 0, 0, 0, 0, {0}}, one) == 1);
  assert(one[0].x == 5 + 42 && one[0].y == 7 && one[0].width == 120 - 84 && one[0].height == 80);
}
static void test_clip_projection(struct rediwm_scene_outputs *scene) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct rediwm_tree *frame = rediwm_tree_create(source);
  struct rediwm_tree *nested = rediwm_tree_create(frame);
  struct rediwm_tree *other = rediwm_tree_create(source);
  float color[4] = {.2, .3, .1, 1};
  struct rediwm_rect *border = rediwm_rect_create(frame, 17, 9, color);
  struct wlr_buffer *buffer = buffer_create(), *glass_buffer = buffer_create(), *title_buffer = buffer_create();
  struct rediwm_buffer *client = rediwm_buffer_create(nested, buffer);
  struct rediwm_buffer *title = rediwm_buffer_create(frame, title_buffer);
  struct rediwm_buffer *glass = rediwm_buffer_create(frame, glass_buffer);
  struct rediwm_rect *overlay = rediwm_rect_create(other, 20, 20, color);
  assert(frame && nested && other && border && client && title && glass && overlay);
  rediwm_node_set_position(&frame->node, 37, 29);
  rediwm_node_set_position(&nested->node, 2, 12);
  rediwm_buffer_set_dest_size(client, 100, 60);
  rediwm_buffer_set_dest_size(title, 100, 12);
  rediwm_buffer_set_dest_size(glass, 100, 12);
  effect_node = &glass->node;
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));
  assert(rediwm_projection_set_tree_scale(&nested->node, .5));

  // Nothing is clipped until a tree asks.
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *border_leaf = leaf_of(p, &border->node), *client_leaf = leaf_of(p, &client->node),
              *title_leaf = leaf_of(p, &title->node), *glass_leaf = leaf_of(p, &glass->node),
              *overlay_leaf = leaf_of(p, &overlay->node);
  assert(!border_leaf->item.clip && !client_leaf->item.clip && !overlay_leaf->item.clip);

  // Every leaf under the tree carries the one shape: the frame's rectangle after
  // the window zoom about its origin, not changed by the inner tree's own scale.
  struct rediwm_clip_spec spec = {.width = 120, .height = 80, .radii = {10, 10, 6, 6}, .border = 1};
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  const struct rediwm_xform zoomed = rediwm_xform_scale_about((struct rediwm_xform){1, 0, 0}, .85, 37, 29);
  const struct rediwm_clip want = rediwm_clip_resolve(zoomed, 37, 29, &spec);
  struct leaf *clipped[] = {border_leaf, client_leaf, title_leaf, glass_leaf};
  for (size_t i = 0; i < sizeof(clipped) / sizeof(clipped[0]); ++i) {
    const struct rediwm_clip *c = clipped[i]->item.clip;
    assert(c == &clipped[i]->clip);
    assert(near(c->edges.x1, want.edges.x1) && near(c->edges.y1, want.edges.y1) &&
           near(c->edges.x2, want.edges.x2) && near(c->edges.y2, want.edges.y2));
    assert(near(c->radii[0], 10 * .85) && near(c->radii[3], 6 * .85) && near(c->border, .85));
  }
  assert(near(want.edges.x1, 37) && near(want.edges.x2, 37 + .85 * 120)); // The origin stays put.
  assert(!overlay_leaf->item.clip); // A sibling window is not clipped.
  // It follows the camera with the window.
  resolve(p, .5, 12, -8, 3, 4, NULL, true);
  const struct rediwm_xform moved = rediwm_xform_scale_about(rediwm_xform_camera(.5, 12, -8, 3, 4), .85, 37, 29);
  const struct rediwm_clip want_moved = rediwm_clip_resolve(moved, 37, 29, &spec);
  assert(near(client_leaf->item.clip->edges.x1, want_moved.edges.x1) &&
         near(client_leaf->item.clip->edges.y2, want_moved.edges.y2) &&
         near(client_leaf->item.clip->radii[0], 10 * .85 * .5));
  resolve(p, 1, 0, 0, 0, 0, NULL, true);

  // A popup lives under its parent's tree but is no part of the window's shape;
  // its siblings, such as subsurfaces, still are. The barrier can be lifted.
  struct rediwm_tree *subsurface = rediwm_tree_create(nested);
  struct rediwm_tree *popup = rediwm_tree_create(nested);
  struct wlr_buffer *popup_buffer = buffer_create(), *sub_buffer = buffer_create();
  struct rediwm_buffer *popup_content = rediwm_buffer_create(popup, popup_buffer);
  struct rediwm_buffer *sub_content = rediwm_buffer_create(subsurface, sub_buffer);
  assert(popup_content && sub_content);
  rediwm_node_set_position(&popup->node, 90, 70); // Hanging outside the 120x80 frame.
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true));
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true)); // Idempotent.
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  struct leaf *popup_leaf = leaf_of(p, &popup_content->node), *sub_leaf = leaf_of(p, &sub_content->node);
  assert(!popup_leaf->item.clip && sub_leaf->item.clip && client_leaf->item.clip);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false));
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false)); // Nothing to lift is fine.
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(popup_leaf->item.clip);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true));
  // A barrier does not hide a clip the subtree sets for itself.
  struct rediwm_clip_spec own = {.width = 50, .height = 40, .radii = {3, 3, 3, 3}};
  assert(rediwm_projection_set_tree_clip(&popup->node, &own));
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(popup_leaf->item.clip && near(popup_leaf->item.clip->edges.x2 - popup_leaf->item.clip->edges.x1, .85 * .5 * 50));
  assert(rediwm_projection_set_tree_clip(&popup->node, NULL));
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(!popup_leaf->item.clip);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false));

  // An inner clipped tree shapes its own leaves only.
  struct rediwm_clip_spec inner_spec = {.width = 30, .height = 20, .radii = {4, 4, 4, 4}};
  assert(rediwm_projection_set_tree_clip(&nested->node, &inner_spec));
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(near(client_leaf->item.clip->edges.x2 - client_leaf->item.clip->edges.x1, .85 * .5 * 30));
  assert(near(title_leaf->item.clip->edges.x2 - title_leaf->item.clip->edges.x1, .85 * 120));
  assert(rediwm_projection_set_tree_clip(&nested->node, NULL));

  // A bad shape is refused and leaves the old one in force; NULL removes it.
  const struct rediwm_clip_spec bad[] = {
      {.width = 0, .height = 80}, {.width = 120, .height = -1}, {.width = 120, .height = 80, .border = -1},
      {.width = 120, .height = 80, .radii = {1, -1, 1, 1}}, {.width = 120, .height = 80, .radii = {NAN, 1, 1, 1}},
      {.width = 120, .height = 80, .border = INFINITY}};
  for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) assert(!rediwm_projection_set_tree_clip(&frame->node, &bad[i]));
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(near(client_leaf->item.clip->edges.x2, want.edges.x2));
  spec.width = 200;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(near(client_leaf->item.clip->edges.x2, 37 + .85 * 200));
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL));
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL)); // Removing nothing is fine.
  resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(!client_leaf->item.clip && !border_leaf->item.clip);

  // Presenting a clipped graph changes nothing about the view tree yet: the
  // shape reaches no pixel until the output pass draws it.
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_presented(p);
  // Destroying the clipped tree frees its addon with it.
  effect_node = NULL;
  rediwm_node_destroy(&frame->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
  wlr_buffer_drop(glass_buffer);
  wlr_buffer_drop(title_buffer);
  wlr_buffer_drop(popup_buffer);
  wlr_buffer_drop(sub_buffer);
}
// What a changed shape does to the output, and to the pointer. The views of a
// window do not move when its border colour changes, so the rim is damaged by the
// projection itself; and a point the shape cuts away goes to what is below.
// Damage is in output pixels and the points below are in layout coordinates, at
// whatever scale an earlier test left the output.
static bool layout_damaged(struct rediwm_scene_output *out, double x, double y) {
  return damaged(out, (int)(x * out->output->scale), (int)(y * out->output->scale));
}
static void test_clip_output(struct rediwm_scene_outputs *scene, struct rediwm_scene_output *out) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct rediwm_tree *under_tree = rediwm_tree_create(source);
  struct rediwm_tree *frame = rediwm_tree_create(source);
  struct wlr_buffer *under_buffer = buffer_create(), *client_buffer = buffer_create();
  struct rediwm_buffer *under = rediwm_buffer_create(under_tree, under_buffer);
  struct rediwm_buffer *client = rediwm_buffer_create(frame, client_buffer);
  assert(under_tree && frame && under && client);
  rediwm_node_set_position(&under_tree->node, 300, 200);
  rediwm_node_set_position(&frame->node, 300, 200);
  rediwm_buffer_set_dest_size(under, 120, 80);
  rediwm_buffer_set_dest_size(client, 120, 80);
  struct rediwm_clip_spec spec = {.width = 120, .height = 80, .radii = {10, 10, 10, 10}, .border = 1,
      .border_color = {.1f, .1f, .1f, .1f}};
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *client_leaf = leaf_of(p, &client->node), *under_leaf = leaf_of(p, &under->node);

  // Points inside the window reach it; the corner pixel, which the arc cuts away,
  // goes to the window below, and so does the one just outside the box.
  double nx, ny;
  struct rediwm_node *hit = pick(p, 360, 240, &nx, &ny);
  assert(hit == client_leaf->own);
  hit = pick(p, 300.5, 200.5, &nx, &ny);
  assert(hit == under_leaf->own);
  hit = pick(p, 419.5, 279.5, &nx, &ny); // bottom-right corner
  assert(hit == under_leaf->own);
  hit = pick(p, 310.5, 200.5, &nx, &ny); // on the straight edge
  assert(hit == client_leaf->own);
  // An inert window is still drawn, but the pointer reaches what is below it.
  assert(rediwm_projection_set_tree_inert(&frame->node, true));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(client_leaf->item.enabled && pick(p, 360, 240, &nx, &ny) == under_leaf->own);
  assert(rediwm_projection_set_tree_inert(&frame->node, false));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(pick(p, 360, 240, &nx, &ny) == client_leaf->own);
  // Without a shape the corner is the window's again.
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(pick(p, 300.5, 200.5, &nx, &ny) == client_leaf->own);
  clear_damage(out);

  // A shape appearing, a different border colour, and the shape going away each
  // damage the rim and only the rim. Nothing else moved.
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 301, 201) && layout_damaged(out, 419, 279) && layout_damaged(out, 360, 202));
  assert(!layout_damaged(out, 360, 240));
  clear_damage(out);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0); // Nothing changed.
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  spec.border_color[0] = .3f;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 301, 201) && layout_damaged(out, 419, 279) && layout_damaged(out, 300, 240));
  assert(!layout_damaged(out, 360, 240) && !layout_damaged(out, 100, 100));
  assert(pixman_region32_not_empty(&out->pending_commit_damage));
  clear_damage(out);
  // Setting the same shape again damages nothing.
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  // The shape going away damages the rim, not the interior.
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 301, 201) && layout_damaged(out, 419, 279) && !layout_damaged(out, 360, 240));
  // Moving a window moves its views, which damage themselves; the shape follows
  // without a second, rim-only report of its own.
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  clear_damage(out);
  rediwm_node_set_position(&frame->node, 310, 200);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 370, 240)); // the views of the window moved
  rediwm_node_set_position(&frame->node, 300, 200);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  // A hidden window damages nothing for a shape change.
  rediwm_node_set_enabled(&frame->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  clear_damage(out);
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  spec.border_color[1] = .7f;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(under_buffer);
  wlr_buffer_drop(client_buffer);
}
// Stage 4d: a shadow's view has no buffer, so wlroots damages nothing for it and the
// projection damages the footprint itself: when it appears, moves, changes, is
// hidden with its window, or goes away, and never when nothing changed.
static void test_shadow_output(struct rediwm_scene_outputs *scene, struct rediwm_scene_output *out) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct rediwm_tree *frame = rediwm_tree_create(source);
  struct rediwm_tree *shadow_tree = rediwm_tree_create(frame);
  struct rediwm_buffer *footprint = rediwm_buffer_create(shadow_tree, NULL);
  assert(frame && shadow_tree && footprint);
  rediwm_node_set_position(&frame->node, 100, 100);
  rediwm_node_set_position(&footprint->node, -16, -8);
  rediwm_buffer_set_dest_size(footprint, 152, 112);
  struct rediwm_shadow_spec spec = {.width = 120, .height = 80, .radii = {10, 10, 10, 10},
      .offset_y = 8, .softness = 16, .color = {0, 0, 0, .4f}};
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *l = leaf_of(p, &footprint->node);
  assert(l->item.kind == REDIWM_ITEM_BUFFER && !l->item.shadow);
  clear_damage(out);

  assert(rediwm_projection_set_tree_shadow(&shadow_tree->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(l->item.kind == REDIWM_ITEM_SHADOW && l->item.shadow);
  assert(near(l->item.shadow->shape.edges.x1, 100) && near(l->item.shadow->shape.edges.y2, 180));
  assert(near(l->item.shadow->offset_y, 8) && near(l->item.shadow->softness, 16));
  assert(layout_damaged(out, 85, 93) && layout_damaged(out, 235, 203) && layout_damaged(out, 160, 140));
  assert(!layout_damaged(out, 80, 140) && !layout_damaged(out, 160, 90));
  clear_damage(out);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0); // Nothing changed.
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  // A moved window damages where its shadow was and where it is.
  rediwm_node_set_position(&frame->node, 140, 100);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 85, 140) && layout_damaged(out, 270, 140));
  clear_damage(out);
  // A different colour damages it in place.
  spec.color[3] = .5f;
  assert(rediwm_projection_set_tree_shadow(&shadow_tree->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 130, 140) && !layout_damaged(out, 100, 140));
  clear_damage(out);
  // Hidden with its window, shown again, and destroyed.
  rediwm_node_set_enabled(&frame->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 130, 140));
  clear_damage(out);
  rediwm_node_set_enabled(&frame->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 130, 140));
  clear_damage(out);
  rediwm_node_destroy(&footprint->node);
  assert(layout_damaged(out, 130, 140));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);

  rediwm_projection_destroy(p);
  rig_destroy(&rig);
}
// Stage 5a: damage events name the leaf and the layout box its pixels changed in,
// for consumers that must tell what lies below a backdrop effect from what lies
// above it. Each consumer reads through its own cursor.
struct events_seen { int count; struct rediwm_damage_event last[16]; };
static void collect_event(const struct rediwm_damage_event *e, void *data) {
  struct events_seen *seen = data;
  if (seen->count < 16) seen->last[seen->count] = *e;
  seen->count++;
}
static struct events_seen events_since(struct rediwm_projection *p, uint64_t *cursor, bool *complete) {
  struct events_seen seen = {0};
  bool ok = rediwm_projection_damage_events(p, cursor, collect_event, &seen);
  if (complete) *complete = ok;
  return seen;
}
static bool event_is(const struct rediwm_damage_event *e, uint64_t leaf, int x, int y, int w, int h) {
  return e->leaf == leaf && e->box.x == x && e->box.y == y && e->box.width == w && e->box.height == h;
}
static void test_damage_events(struct rediwm_scene_outputs *scene) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  uint64_t cursor = rediwm_projection_damage_cursor(p), other = cursor;
  struct rediwm_tree *window = rediwm_tree_create(source);
  struct wlr_buffer *buffer = buffer_create(); // 200x120
  struct rediwm_buffer *a = rediwm_buffer_create(window, buffer);
  struct rediwm_buffer *b = rediwm_buffer_create(window, buffer);
  rediwm_node_set_position(&window->node, 40, 30);
  rediwm_buffer_set_dest_size(a, 100, 60); // half size: one buffer px = 0.5
  rediwm_node_set_position(&b->node, 0, 100);
  rediwm_buffer_set_dest_size(b, 20, 20);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *la = leaf_of(p, &a->node), *lb = leaf_of(p, &b->node);
  assert(la->item.id && lb->item.id && la->item.id != lb->item.id);

  // Appearing: each leaf's whole box.
  struct events_seen seen = events_since(p, &cursor, NULL);
  assert(seen.count == 2);
  assert(event_is(&seen.last[0], la->item.id, 40, 30, 100, 60));
  assert(event_is(&seen.last[1], lb->item.id, 40, 130, 20, 20));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0); // Nothing changed.
  assert(events_since(p, &cursor, NULL).count == 0);

  // Reported buffer damage maps through the scale, a pixel wider for filtering.
  pixman_region32_t damage;
  pixman_region32_init_rect(&damage, 20, 40, 10, 10);
  rediwm_projection_damage_buffer(p, &a->node, &damage);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], la->item.id, 49, 49, 7, 7));
  // Unreported damage is the whole box.
  rediwm_projection_damage_buffer(p, &a->node, NULL);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], la->item.id, 40, 30, 100, 60));

  // A move changes the old and the new box; a hidden leaf its last one.
  rediwm_node_set_position(&b->node, 10, 100);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 2);
  assert(event_is(&seen.last[0], lb->item.id, 40, 130, 20, 20));
  assert(event_is(&seen.last[1], lb->item.id, 50, 130, 20, 20));
  rediwm_node_set_enabled(&b->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], lb->item.id, 50, 130, 20, 20));
  rediwm_node_set_enabled(&b->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], lb->item.id, 50, 130, 20, 20));
  // A changed opacity is a restyle of the whole box.
  rediwm_buffer_set_opacity(a, .5f);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 2 && event_is(&seen.last[1], la->item.id, 40, 30, 100, 60));
  // A destroyed leaf reports its last box at once.
  const uint64_t gone = lb->item.id;
  rediwm_node_destroy(&b->node);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], gone, 50, 130, 20, 20));

  // A leaf that draws nothing (an input-only node such as a resize grab) has no
  // events, however it moves: glass would otherwise take it for a change below.
  struct rediwm_buffer *grab = rediwm_buffer_create(window, NULL);
  rediwm_buffer_set_dest_size(grab, 300, 300);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_node_set_position(&grab->node, 5, 5);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_node_destroy(&grab->node);
  assert(events_since(p, &cursor, NULL).count == 0);

  // A second consumer read nothing yet and sees everything since its cursor.
  bool complete = false;
  seen = events_since(p, &other, &complete);
  assert(complete && seen.count == 11);
  // One that falls behind the ring is told so.
  uint64_t stale = rediwm_projection_damage_cursor(p);
  for (int i = 0; i < 2100; i++) {
    rediwm_node_set_position(&window->node, 40 + i % 2, 30);
    rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  }
  events_since(p, &stale, &complete);
  assert(!complete);
  assert(events_since(p, &stale, &complete).count == 0 && complete);

  pixman_region32_fini(&damage);
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
}
// A window's dim is a field of what its leaves show: inherited down the tree like
// its shape, ended where a popup hangs under it, and a change of it restyles (so
// damages) every leaf under the tree and no other.
static void test_dim(struct rediwm_scene_outputs *scene) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  uint64_t cursor = rediwm_projection_damage_cursor(p);
  struct rediwm_tree *window = rediwm_tree_create(source);
  struct rediwm_tree *content = rediwm_tree_create(window);
  struct rediwm_tree *popup = rediwm_tree_create(content);
  struct rediwm_tree *sibling = rediwm_tree_create(source);
  float color[4] = {.2, .3, .1, 1};
  struct wlr_buffer *buffer = buffer_create();
  struct rediwm_rect *ring = rediwm_rect_create(window, 10, 10, color);
  struct rediwm_buffer *client = rediwm_buffer_create(content, buffer);
  struct rediwm_buffer *menu = rediwm_buffer_create(popup, buffer);
  struct rediwm_buffer *other = rediwm_buffer_create(sibling, buffer);
  assert(ring && client && menu && other);
  rediwm_node_set_position(&window->node, 40, 30);
  rediwm_node_set_position(&client->node, 0, 10);
  rediwm_buffer_set_dest_size(client, 100, 60);
  rediwm_node_set_position(&popup->node, 50, 20);
  rediwm_buffer_set_dest_size(menu, 30, 30);
  rediwm_node_set_position(&sibling->node, 300, 200);
  rediwm_buffer_set_dest_size(other, 20, 20);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *lring = leaf_of(p, &ring->node), *lclient = leaf_of(p, &client->node),
              *lmenu = leaf_of(p, &menu->node), *lother = leaf_of(p, &other->node);
  assert(events_since(p, &cursor, NULL).count == 4); // Appearing.

  // Nothing is dimmed until a tree asks, and taking nothing away makes no addon.
  assert(rediwm_projection_set_tree_dim(&sibling->node, 0, 0));
  assert(!lring->item.content.dim_brightness && !lclient->item.content.dim_saturation);

  // Every leaf of the window, not the popup under it and not another window.
  assert(rediwm_projection_set_tree_dim(&window->node, .08f, .1f));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(lring->item.content.dim_brightness == .08f && lring->item.content.dim_saturation == .1f);
  assert(lclient->item.content.dim_brightness == .08f && lclient->item.content.dim_saturation == .1f);
  assert(!lmenu->item.content.dim_brightness && !lmenu->item.content.dim_saturation);
  assert(!lother->item.content.dim_brightness && !lother->item.content.dim_saturation);
  // The change restyles those two leaves (each reports its box as it was and as it
  // is) and no other.
  struct events_seen seen = events_since(p, &cursor, NULL);
  assert(seen.count == 4 && event_is(&seen.last[1], lclient->item.id, 40, 40, 100, 60) &&
         event_is(&seen.last[3], lring->item.id, 40, 30, 10, 10));
  for (int i = 0; i < 4; i++) assert(seen.last[i].leaf == lclient->item.id || seen.last[i].leaf == lring->item.id);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(events_since(p, &cursor, NULL).count == 0); // Unchanged is no damage.
  assert(rediwm_projection_set_tree_dim(&window->node, .1f, .1f));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(events_since(p, &cursor, NULL).count == 4);

  // A fraction outside 0 to 1 is refused and the old dim stays.
  assert(!rediwm_projection_set_tree_dim(&window->node, -.1f, 0));
  assert(!rediwm_projection_set_tree_dim(&window->node, 0, 1.5f));
  assert(!rediwm_projection_set_tree_dim(&window->node, NAN, 0));
  assert(!rediwm_projection_set_tree_dim(&window->node, 0, INFINITY));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(lclient->item.content.dim_brightness == .1f && events_since(p, &cursor, NULL).count == 0);

  // The barrier does not hide a dim the subtree sets for itself, and lifting it
  // gives the popup the window's.
  assert(rediwm_projection_set_tree_dim(&popup->node, .5f, 0));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(lmenu->item.content.dim_brightness == .5f && lmenu->item.content.dim_saturation == 0);
  assert(rediwm_projection_set_tree_dim(&popup->node, 0, 0));
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(lmenu->item.content.dim_brightness == .1f);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!lmenu->item.content.dim_brightness);

  // Taking nothing away undoes it, and restyles the leaves back.
  events_since(p, &cursor, NULL);
  assert(rediwm_projection_set_tree_dim(&window->node, 0, 0));
  assert(rediwm_projection_set_tree_dim(&window->node, 0, 0)); // Again is fine.
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!lring->item.content.dim_brightness && !lclient->item.content.dim_saturation);
  assert(events_since(p, &cursor, NULL).count == 4);

  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
}
// The output pass hides what a client's opaque region covers, from the region as
// the surface node keeps it. The buffers of a client reveal no format, like a
// wlr_client_buffer, so only the node's own region can say they are opaque: it
// has to land on screen exactly, or one pixel inside where it is scaled.
static void test_opaque(void) {
  pixman_region32_t source, out;
  pixman_region32_init_rect(&source, 50, 30, 100, 60);
  pixman_region32_init(&out);
  // Shown 1:1, a region is used as is, clipped to the box.
  rediwm_mirror_opaque(&out, &source, 200, 120, 200, 120);
  assert(pixman_region32_n_rects(&out) == 1);
  assert(pixman_region32_contains_point(&out, 50, 30, NULL) && pixman_region32_contains_point(&out, 149, 89, NULL));
  assert(!pixman_region32_contains_point(&out, 49, 30, NULL) && !pixman_region32_contains_point(&out, 150, 89, NULL));
  pixman_region32_clear(&out);
  pixman_region32_clear(&source);
  pixman_region32_union_rect(&source, &source, 0, 0, 300, 300);
  rediwm_mirror_opaque(&out, &source, 200, 120, 200, 120);
  assert(pixman_region32_contains_point(&out, 199, 119, NULL) && !pixman_region32_contains_point(&out, 200, 0, NULL));
  // Nothing says nothing.
  pixman_region32_clear(&out);
  pixman_region32_clear(&source);
  rediwm_mirror_opaque(&out, &source, 200, 120, 200, 120);
  assert(!pixman_region32_not_empty(&out));

  // Scaled with the node and pulled one pixel in: the middle is opaque, the edge
  // pixels, which the filter may blend with what is outside, are not.
  pixman_region32_union_rect(&source, &source, 0, 0, 200, 120);
  rediwm_mirror_opaque(&out, &source, 200, 120, 100, 60);
  assert(pixman_region32_contains_point(&out, 40, 25, NULL));
  assert(!pixman_region32_contains_point(&out, 0, 0, NULL) && !pixman_region32_contains_point(&out, 99, 59, NULL));
  assert(pixman_region32_contains_point(&out, 1, 1, NULL) && pixman_region32_contains_point(&out, 98, 58, NULL));
  // A rectangle thinner than the inset vanishes.
  pixman_region32_clear(&out);
  pixman_region32_clear(&source);
  pixman_region32_union_rect(&source, &source, 10, 10, 2, 2);
  rediwm_mirror_opaque(&out, &source, 200, 120, 100, 60);
  assert(!pixman_region32_not_empty(&out));
  // A node with no size shows no region.
  pixman_region32_union_rect(&source, &source, 0, 0, 50, 50);
  rediwm_mirror_opaque(&out, &source, 0, 0, 100, 60);
  assert(!pixman_region32_not_empty(&out));
  pixman_region32_fini(&source);
  pixman_region32_fini(&out);
}
static bool in_group(struct group *g, struct leaf *l) {
  struct leaf *listed;
  wl_list_for_each(listed, &g->items, paint) if (listed == l) return true;
  return false;
}
static int snap_width(struct leaf *l) { return rediwm_edges_snap(l->item.edges).width; }
static void test_groups(struct rediwm_scene_outputs *scene, struct rediwm_scene_output *out) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct rediwm_tree *frame = rediwm_tree_create(source);
  struct rediwm_tree *nested = rediwm_tree_create(frame);
  struct rediwm_tree *other = rediwm_tree_create(source);
  float color[4] = {.2, .3, .1, 1};
  struct rediwm_rect *border = rediwm_rect_create(frame, 17, 9, color);
  struct wlr_buffer *buffer = buffer_create();
  struct rediwm_buffer *client = rediwm_buffer_create(nested, buffer);
  struct rediwm_rect *overlay = rediwm_rect_create(other, 20, 20, color);
  assert(frame && nested && other && border && client && overlay);
  rediwm_node_set_position(&frame->node, 37, 29);
  rediwm_node_set_position(&nested->node, -12, 5);
  rediwm_node_set_position(&client->node, 4, 3);
  rediwm_node_set_position(&border->node, -2, -3);
  rediwm_node_set_position(&other->node, 90, 60);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct group *g = get_group(p, &frame->node);
  struct group *h = get_group(p, &other->node);
  struct leaf *l = leaf_of(p, &client->node);
  struct leaf *border_leaf = leaf_of(p, &border->node);
  assert(in_group(g, l) && in_group(g, border_leaf) && in_group(h, leaf_of(p, &overlay->node)));
  assert(wl_list_length(&p->paint) == 2);
  assert_position(p, &client->node, 29, 37);
  assert_position(p, &border->node, 35, 26);
  clear_damage(out);
  rediwm_node_set_position(&frame->node, 83, 71);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  // Ordinary movement moves every leaf of the group.
  assert_position(p, &client->node, 75, 79);
  assert_position(p, &border->node, 81, 68);
  assert(damaged(out, 50, 60) && damaged(out, 200, 150));
  clear_damage(out);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  // A fixed desktop ignores the camera while neighboring windows still pan.
  rediwm_projection_sync_fixed(p, .5, 10, 20, 0, 0, frame);
  assert_position(p, &client->node, 75, 79);
  assert_position(p, &overlay->node, 40, 20);
  assert(snap_width(l) == 200);
  rediwm_projection_sync(p, .5, 10, 20, 0, 0);
  assert_position(p, &client->node, 33, 30);

  // Endpoint rounding must remain global, including half-pixels crossing
  // zero. Integer rounding of a local offset is not equivalent here.
  const double zooms[] = {.5, .85, 1, 1.25};
  for (size_t i = 0; i < sizeof(zooms) / sizeof(zooms[0]); ++i) {
    double z = zooms[i], cx = 6.5, cy = -2.5, ox = -17, oy = 31;
    double tx = ox * (1 - z) - z * cx, ty = oy * (1 - z) - z * cy;
    for (int x = -13; x <= 13; ++x) {
      rediwm_node_set_position(&frame->node, x, -x);
      rediwm_projection_sync(p, z, cx, cy, ox, oy);
      assert_position(p, &client->node, lround(z * (x - 8) + tx),
                       lround(z * (-x + 8) + ty));
      assert_position(p, &border->node, lround(z * (x - 2) + tx),
                       lround(z * (-x - 3) + ty));
      assert(snap_width(l) == lround(z * (x - 8 + 200) + tx) -
                              lround(z * (x - 8) + tx));
    }
  }
  // Window zoom multiplies the camera scale while preserving its world origin.
  // Nested geometry keeps the same per-leaf projected scale.
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));
  rediwm_node_set_position(&frame->node, -17, 23);
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert_position(p, &client->node, lround(.5 * -17 - 1.5 + (.85 * .5) * -8),
                   lround(.5 * 23 + 3.5 + (.85 * .5) * 8));
  assert(l->item.scale == (.85 * .5));

  // A relative tree scale composes with camera and window zoom, preserving origin.
  assert(rediwm_projection_set_tree_scale(&nested->node, .5));
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert(fabs(l->item.scale - ((.85 * .5) * .5)) < .0001);
  assert_position(p, &client->node, lround(.5 * -17 - 1.5 + (.85 * .5) * -12 + (.85 * .5) * .5 * 4),
                   lround(.5 * 23 + 3.5 + (.85 * .5) * 5 + (.85 * .5) * .5 * 3));
  assert(rediwm_projection_set_tree_scale(&nested->node, 1.0));
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert(fabs(l->item.scale - (.85 * .5)) < .0001);
  assert(rediwm_projection_set_tree_zoom(&frame->node, 1.0));

  // Reorder a whole window and a leaf within it, retaining source paint order.
  rediwm_node_raise_to_top(&frame->node);
  rediwm_node_raise_to_top(&nested->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *order[8];
  assert(p->paint.next == &h->paint && h->paint.next == &g->paint && g->paint.next == &p->paint);
  assert(items_of(g, order, 8) == 2 && order[0] == border_leaf && order[1] == l);
  // The source node and its input stay attached to the leaf when a subsurface
  // changes source root, rather than retaining a stale group.
  rediwm_node_reparent(&client->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(in_group(h, l) && !in_group(g, l));
  assert_position(p, &client->node, 94, 63);
  double input_x, input_y;
  assert(pick(p, 94 + 40, 63 + 24, &input_x, &input_y) == &client->node);
  assert(input_x == 40 && input_y == 24);
  rediwm_node_set_enabled(&other->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!l->item.enabled && !pick(p, 94 + 40, 63 + 24, &input_x, &input_y));
  rediwm_node_set_enabled(&other->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_position(p, &client->node, 94, 63);

  // A former source root can become nested, leave the projected tree, and
  // return. Its unused group is not reached while its leaves change group, and
  // neither its former position nor window zoom may leak into other leaves.
  rediwm_node_reparent(&frame->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!g->seen);
  assert(in_group(h, border_leaf));
  assert_position(p, &border->node, 71, 80);
  assert_position(p, &client->node, 94, 63);
  rediwm_node_reparent(&frame->node, &rig.parking->tree);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!border_leaf->seen);
  rediwm_node_reparent(&frame->node, source);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(g->seen);
  assert(in_group(g, border_leaf));
  assert_position(p, &border->node, -19, 20);

  // A leaf moved out of a window's tree before the tree is destroyed keeps its
  // leaf: the surviving source node needs nothing recreated.
  struct rediwm_tree *temporary = rediwm_tree_create(source);
  struct rediwm_rect *survivor = rediwm_rect_create(temporary, 12, 12, color);
  assert(temporary && survivor);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_node_reparent(&survivor->node, other);
  rediwm_node_destroy(&temporary->node);
  assert(leaf_of(p, &survivor->node));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_position(p, &survivor->node, 90, 60);
  rediwm_node_destroy(&survivor->node);

  // A direct leaf can itself be a former group root. After it becomes nested,
  // destroying the source runs both leaf and group cleanup on the same node.
  struct rediwm_rect *direct = rediwm_rect_create(source, 12, 12, color);
  assert(direct);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_node_reparent(&direct->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(in_group(h, leaf_of(p, &direct->node)));
  rediwm_node_destroy(&direct->node);
  assert(wl_list_length(&p->groups) == 2 && wl_list_length(&p->leaves) == 3);

  // Source-first teardown destroys its group without dangling leaf listeners.
  rediwm_node_destroy(&frame->node);
  assert(wl_list_length(&p->groups) == 1 && wl_list_length(&p->leaves) == 2);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_node_destroy(&other->node);
  assert(wl_list_empty(&p->groups) && wl_list_empty(&p->leaves));
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
}
// Stage 6b: the screen's damage comes from the graph. A restack damages what
// changed order, a change of what a leaf itself shows is cut to what was visible
// of it at the last build, and a window going away is damaged at once.
static void test_graph_damage(struct rediwm_scene_outputs *scene, struct rediwm_scene_output *out) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct wlr_buffer *buffer = buffer_create(); // 200x120
  struct rediwm_tree *frame_a = rediwm_tree_create(source);
  struct rediwm_tree *frame_b = rediwm_tree_create(source);
  struct rediwm_buffer *a = rediwm_buffer_create(frame_a, buffer);
  struct rediwm_buffer *b = rediwm_buffer_create(frame_b, buffer);
  rediwm_node_set_position(&frame_a->node, 20, 20);
  rediwm_node_set_position(&frame_b->node, 60, 40);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  clear_damage(out);

  // Raising the window below changes the pixels where the two overlap, and says
  // nothing about the rest of the screen.
  rediwm_node_raise_to_top(&frame_a->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 100, 60) && layout_damaged(out, 210, 130));
  assert(!layout_damaged(out, 350, 300) && !layout_damaged(out, 5, 5));
  clear_damage(out);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0); // Same order: nothing.
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  // What changes only what a leaf shows is cut to what of it was visible at the
  // last build: the right part of `a` was hidden, so its change is not damaged.
  struct leaf *la = leaf_of(p, &a->node), *lb = leaf_of(p, &b->node);
  pixman_region32_t visible;
  pixman_region32_init_rect(&visible, 20, 20, 50, 120);
  rediwm_projection_note_visible(p, &a->node, &visible);
  rediwm_projection_damage_buffer(p, &a->node, NULL);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 30, 60) && !layout_damaged(out, 150, 60));
  clear_damage(out);
  // Nothing visible, nothing to damage; a leaf the pass never saw is damaged whole.
  pixman_region32_clear(&visible);
  rediwm_projection_note_visible(p, &a->node, &visible);
  rediwm_projection_damage_buffer(p, &a->node, NULL);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  assert(!lb->has_visible);
  rediwm_projection_damage_buffer(p, &b->node, NULL);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 70, 50) && layout_damaged(out, 250, 150));
  clear_damage(out);
  // A leaf that is moved damages where it was only where it was visible, and
  // where it is whatever the last build saw.
  pixman_region32_init_rect(&visible, 60, 40, 40, 120);
  rediwm_projection_note_visible(p, &b->node, &visible);
  rediwm_node_set_position(&frame_b->node, 200, 150);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 70, 60) && !layout_damaged(out, 150, 60)); // old box, cut
  assert(layout_damaged(out, 250, 200)); // new box, whole
  clear_damage(out);
  (void)la;

  // A window going away damages what it showed without waiting for a sync: a
  // capture can build a frame before the next one.
  rediwm_projection_note_visible(p, &a->node, &(pixman_region32_t){.extents = {20, 20, 220, 140}, .data = NULL});
  rediwm_node_destroy(&frame_a->node);
  assert(layout_damaged(out, 30, 30) && layout_damaged(out, 210, 130));
  pixman_region32_fini(&visible);
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
}
// Stage 6a: what the output pass reports of a surface becomes the signals wlroots
// would have sent. Two outputs side by side, a node over the seam.
static int outputs_updates, frame_dones, update_size;
static struct rediwm_scene_output *update_active[4];
static void on_outputs_update(struct wl_listener *listener, void *data) {
  (void)listener;
  const struct rediwm_outputs_update_event *event = data;
  outputs_updates++;
  update_size = (int)event->size;
  for (size_t i = 0; i < event->size && i < 4; i++) update_active[i] = event->active[i];
}
static void on_frame_done(struct wl_listener *listener, void *data) {
  (void)listener;
  (void)data;
  frame_dones++;
}
static void report(struct rediwm_projection *p, struct rediwm_node *node, int x, int y, int w, int h) {
  pixman_region32_t visible;
  pixman_region32_init(&visible);
  if (w > 0) pixman_region32_union_rect(&visible, &visible, x, y, w, h);
  rediwm_projection_feedback_begin(p);
  rediwm_projection_feedback_note(p, node, &visible);
  rediwm_projection_feedback_end(p);
  pixman_region32_fini(&visible);
}
static void test_feedback(struct rediwm_scene_outputs *scene, struct wlr_backend *backend, struct rediwm_scene_output *left,
                          struct wlr_output *left_output) {
  struct wlr_output *right_output = wlr_headless_add_output(backend, 320, 240);
  assert(right_output);
  struct wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, true);
  assert(wlr_output_commit_state(right_output, &state));
  wlr_output_state_finish(&state);
  struct rediwm_scene_output *right = rediwm_scene_output_create(scene, right_output, NULL);
  assert(right);
  int seam = 0, unused = 0;
  wlr_output_effective_resolution(left_output, &seam, &unused);
  right->x = seam;

  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct wlr_buffer *buffer = buffer_create();
  struct rediwm_buffer *node = rediwm_buffer_create(source, buffer);
  rediwm_node_set_position(&node->node, seam - 26, 50);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *l = leaf_of(p, &node->node);
  l->feedback = calloc(1, sizeof(*l->feedback));
  assert(l->feedback);
  l->feedback->leaf = l;
  wl_list_insert(&p->feedback, &l->feedback->link);
  struct wl_listener updated = {.notify = on_outputs_update}, done = {.notify = on_frame_done};
  wl_signal_add(&node->events.outputs_update, &updated);
  wl_signal_add(&node->events.frame_done, &done);
  struct timespec now = {0};

  // Over the seam: both outputs show more than a tenth, the one with most is primary.
  report(p, &node->node, seam - 26, 50, 200, 100); // 26 columns left, 174 right
  assert(outputs_updates == 1 && update_size == 2 && l->feedback->primary == right);
  assert(l->feedback->active == (1ull << left->index | 1ull << right->index));
  report(p, &node->node, seam - 26, 50, 200, 100);
  assert(outputs_updates == 1); // Unchanged: no signal.
  // A sliver on the other side is ignored (10 % rule): 2 of 28 columns.
  report(p, &node->node, seam - 26, 50, 28, 100);
  assert(outputs_updates == 2 && update_size == 1 && update_active[0] == left && l->feedback->primary == left);
  // Frames are sent for what is shown, and for no output it is not.
  rediwm_projection_send_frame_done(p, left, &now);
  assert(frame_dones == 1);
  // A hidden leaf hears none, whatever it was told last.
  rediwm_node_set_enabled(&node->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_projection_send_frame_done(p, left, &now);
  assert(frame_dones == 1);
  rediwm_node_set_enabled(&node->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  report(p, &node->node, 0, 0, 0, 0); // hidden
  assert(outputs_updates == 3 && update_size == 0 && !l->feedback->active && !l->feedback->primary);
  rediwm_projection_send_frame_done(p, left, &now);
  assert(frame_dones == 1); // nothing shown, nothing sent
  // An active output whose scale changed hears again, whatever else is the same.
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 4 && update_size == 1);
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 4);
  wlr_output_state_init(&state);
  wlr_output_state_set_scale(&state, 1.25f);
  assert(wlr_output_commit_state(left_output, &state));
  wlr_output_state_finish(&state);
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 5);
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 5);
  wlr_output_state_init(&state);
  wlr_output_state_set_scale(&state, 1.f);
  assert(wlr_output_commit_state(left_output, &state));
  wlr_output_state_finish(&state);

  wl_list_remove(&updated.link);
  wl_list_remove(&done.link);
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
  rediwm_scene_output_destroy(right);
  wlr_output_destroy(right_output);
}
int main(void) {
  struct wl_display *display = wl_display_create();
  assert(display);
  struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(display));
  assert(backend);
  struct wlr_output *output = wlr_headless_add_output(backend, 640, 480);
  assert(output);
  struct wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, true);
  assert(wlr_output_commit_state(output, &state));
  wlr_output_state_finish(&state);
  struct wlr_output_layout *layout = wlr_output_layout_create(display);
  assert(layout);
  struct rediwm_scene_outputs *scene = rediwm_scene_outputs_create(layout);
  assert(scene);
  struct rediwm_scene_output *out = rediwm_scene_output_create(scene, output, NULL);
  assert(out);
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct wlr_buffer *a = buffer_create(), *b = buffer_create();
  struct rediwm_buffer *node = rediwm_buffer_create(source, a);
  assert(node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 100, 60)); // First presentation is fully damaged.
  clear_damage(out);

  struct leaf *l = leaf_of(p, &node->node);
  struct wlr_surface surface = {.current = {.buffer_width = 200, .buffer_height = 120}};
  pixman_region32_init(&surface.buffer_damage);
  struct rediwm_surface scene_surface = {.surface = &surface};
  l->surface = &scene_surface;
  l->damage_width = 200;
  l->damage_height = 120;

  // Both commits must survive until presentation, despite the final empty
  // commit. No buffer pointer change is needed for pixels to change.
  commit_damage(l, 10, 10, 4, 4);
  commit_damage(l, 170, 90, 4, 4);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 11, 11) && damaged(out, 171, 91));
  assert(!damaged(out, 100, 60));
  clear_damage(out);

  // Rotation with empty damage is not a repaint; rotation with partial damage
  // must retain only that region. The source tree itself is disabled.
  rediwm_buffer_set_buffer(node, b);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  rediwm_buffer_set_buffer(node, a);
  commit_damage(l, 20, 20, 4, 4);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 21, 21) && !damaged(out, 100, 60));
  clear_damage(out);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  // Mapping invalidations remain sticky through later commits, even if a
  // buffer resize or viewport change is reverted before presentation.
  const uint32_t mappings[] = {WLR_SURFACE_STATE_VIEWPORT,
      WLR_SURFACE_STATE_SCALE, WLR_SURFACE_STATE_TRANSFORM};
  for (size_t i = 0; i < sizeof(mappings) / sizeof(mappings[0]); ++i) {
    surface.current.committed = mappings[i];
    commit_damage(l, 0, 0, 0, 0);
    surface.current.committed = 0;
    commit_damage(l, 0, 0, 0, 0);
    rediwm_projection_sync(p, 1, 0, 0, 0, 0);
    assert(damaged(out, 100, 60));
    clear_damage(out);
  }
  surface.current.buffer_width = 240;
  commit_damage(l, 0, 0, 0, 0);
  surface.current.buffer_width = 200;
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 100, 60));
  clear_damage(out);

  // Cropping and fractional zoom use wlroots' buffer-to-output damage mapping,
  // including filtering expansion, rather than treating buffer pixels as scene
  // coordinates.
  rediwm_buffer_set_source_box(node, &(struct wlr_fbox){20, 20, 100, 60});
  rediwm_buffer_set_dest_size(node, 100, 60);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  commit_damage(l, 40, 40, 4, 4);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 10, 10) && !damaged(out, 30, 20));
  clear_damage(out);
  commit_damage(l, 0, 0, 4, 4); // Fully outside the viewport.
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  wlr_output_state_init(&state);
  wlr_output_state_set_scale(&state, 1.5f);
  assert(wlr_output_commit_state(output, &state));
  wlr_output_state_finish(&state);
  clear_damage(out);
  commit_damage(l, 40, 40, 4, 4);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 15, 15) && !damaged(out, 45, 30));
  clear_damage(out);

  // Geometry changes still damage both the old and new location, independently
  // of client buffer damage. Re-enabling a hidden node must repaint it too.
  rediwm_node_set_position(&node->node, 200, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 20, 20) && damaged(out, 170, 20));
  clear_damage(out);
  rediwm_node_set_enabled(&node->node, false);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  rediwm_node_set_enabled(&node->node, true);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 170, 20));
  rediwm_node_set_position(&node->node, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);

  // Unmap/remap must repaint even when the remapping commit has empty damage.
  rediwm_buffer_set_buffer(node, NULL);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  rediwm_buffer_set_buffer(node, a);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 25, 15));

  l->surface = NULL; // Synthetic surface has no lifecycle listeners to route.
  pixman_region32_fini(&surface.buffer_damage);
  rediwm_projection_destroy(p);
  test_groups(scene, out);
  test_graph(scene);
  test_clean_sync(scene);
  test_clip_geometry();
  test_clip_opaque();
  test_clip_projection(scene);
  test_clip_output(scene, out);
  test_shadow_output(scene, out);
  test_damage_events(scene);
  test_dim(scene);
  test_graph_damage(scene, out);
  test_feedback(scene, backend, out, output);
  test_opaque();
  rediwm_scene_outputs_destroy(scene);
  wlr_output_layout_destroy(layout);
  wlr_buffer_drop(a);
  wlr_buffer_drop(b);
  wlr_backend_destroy(backend);
  wl_display_destroy(display);
  puts("PASS: projection damage, feedback, grouping, geometry, graph, opaque regions and lifecycle");
  return 0;
}
