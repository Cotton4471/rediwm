// Synthetic surface commits into the real projection and wlroots scene damage
// path. No renderer, GPU, socket or host desktop is needed.
#include "projection.c"
#include <assert.h>
#include <stdio.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_buffer.h>

static struct wlr_scene_node *effect_node;
bool rediwm_glass_is_effect_node(struct wlr_scene_node *node) {
  return node == effect_node;
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
static bool damaged(struct wlr_scene_output *out, int x, int y) {
  return pixman_region32_contains_point(&out->damage_ring.current, x, y, NULL);
}
static void clear_damage(struct wlr_scene_output *out) {
  pixman_region32_clear(&out->damage_ring.current);
  pixman_region32_clear(&out->private.pending_commit_damage);
}
static void assert_position(struct rediwm_projection *p,
                            struct wlr_scene_node *source, int x, int y) {
  struct wlr_scene_node *view = rediwm_projection_node(p, source);
  assert(view && rediwm_projection_source(view) == source);
  int actual_x = 0, actual_y = 0;
  assert(wlr_scene_node_coords(view, &actual_x, &actual_y));
  assert(actual_x == x && actual_y == y);
}
static bool visible_at(struct wlr_scene_node *node, int x, int y) {
  return pixman_region32_contains_point(&node->private.visible, x, y, NULL);
}
// Runs while a leaf's view node is being destroyed, after its group's view has
// already finished and freed the group, and before the leaf's own teardown. A
// leaf that still listed itself in that group would point into freed memory
// here; no allocator reliably shows that (glibc does not poison small chunks on
// free), so check the links themselves. Lookup, not a pointer: the leaf may
// already be gone, which is why the caller counts the checks that ran.
struct probe {
  struct wlr_addon addon;
  struct wlr_scene_node *view;
  int *checks;
};
static void probe_destroy(struct wlr_addon *addon) {
  struct probe *probe = wl_container_of(addon, probe, addon);
  struct leaf *l = lookup(probe->view);
  if (l) {
    assert(l->paint.next == &l->paint && l->paint.prev == &l->paint);
    ++*probe->checks;
  }
  wlr_addon_finish(addon);
  free(probe);
}
static const struct wlr_addon_interface probe_impl = {.name = "test probe", .destroy = probe_destroy};
static void probe_leaf(struct leaf *l, int *checks) {
  struct probe *probe = calloc(1, sizeof(*probe));
  assert(probe);
  probe->view = l->view;
  probe->checks = checks;
  wlr_addon_init(&probe->addon, &l->view->addons, probe, &probe_impl);
}
static size_t items_of(struct group *g, struct leaf **out, size_t max) {
  size_t n = 0;
  struct leaf *l;
  wl_list_for_each(l, &g->items, paint) {
    assert(n < max);
    out[n++] = l;
  }
  return n;
}
// Presented views are the graph's edges rounded in layout space and nothing
// else: every group at the rounded origin, every leaf at its snapped rectangle
// relative to it, and nothing but this pass's leaves in the lists.
static void assert_presented(struct rediwm_projection *p) {
  struct group *g;
  wl_list_for_each(g, &p->paint, paint) {
    assert(g->seen && g->view->node.x == lround(g->x) &&
           g->view->node.y == lround(g->y) && g->view->node.enabled == g->enabled);
    struct leaf *l;
    wl_list_for_each(l, &g->items, paint) {
      assert(l->seen && l->view->parent == g->view);
      if (l->item.kind == REDIWM_ITEM_EFFECT)
        continue; // glass owns its view
      struct rediwm_snap s = rediwm_edges_snap(l->item.edges);
      assert(l->view->x == s.x - g->view->node.x && l->view->y == s.y - g->view->node.y);
      assert(l->view->enabled == (l->item.enabled && s.width > 0 && s.height > 0));
      if (l->item.kind != REDIWM_ITEM_RECT) {
        struct wlr_scene_buffer *v = wlr_scene_buffer_from_node(l->view);
        assert(v->dst_width == (s.width > 0 ? s.width : 1) &&
               v->dst_height == (s.height > 0 ? s.height : 1));
      }
    }
  }
}
// The typed graph: complete and in paint order before anything is presented,
// unrounded, and the only source of the view tree's geometry.
struct graph_probe {
  struct wlr_scene_node *transport;
  struct rediwm_item expected;
  int count;
};
static bool probe_item(const struct rediwm_item *item, struct wlr_scene_node *transport, void *data) {
  struct graph_probe *probe = data;
  if (transport != probe->transport) return true;
  probe->count++;
  assert(item->edges.x1 == probe->expected.edges.x1 && item->edges.y1 == probe->expected.edges.y1);
  assert(item->edges.x2 == probe->expected.edges.x2 && item->edges.y2 == probe->expected.edges.y2);
  assert(item->kind == probe->expected.kind && rediwm_content_equal(&item->content, &probe->expected.content));
  return true;
}
static void test_graph(struct wlr_scene *scene) {
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  struct wlr_scene_tree *frame = wlr_scene_tree_create(source);
  struct wlr_scene_tree *nested = wlr_scene_tree_create(frame);
  struct wlr_scene_tree *other = wlr_scene_tree_create(source);
  float color[4] = {.2, .3, .1, 1};
  struct wlr_scene_rect *border = wlr_scene_rect_create(frame, 17, 9, color);
  struct wlr_buffer *buffer = buffer_create(), *glass_buffer = buffer_create();
  struct wlr_scene_buffer *client = wlr_scene_buffer_create(nested, buffer);
  struct wlr_scene_buffer *glass = wlr_scene_buffer_create(frame, glass_buffer);
  struct wlr_scene_rect *overlay = wlr_scene_rect_create(other, 20, 20, color);
  assert(frame && nested && other && border && client && glass && overlay);
  wlr_scene_node_set_position(&frame->node, 37, 29);
  wlr_scene_node_set_position(&nested->node, -12, 5);
  wlr_scene_node_set_position(&client->node, 4, 3);
  wlr_scene_node_set_position(&border->node, -2, -3);
  wlr_scene_node_set_position(&other->node, 90, 60);
  effect_node = &glass->node;
  wlr_scene_buffer_set_dest_size(client, 100, 60);
  wlr_scene_buffer_set_dest_size(glass, 50, 20);
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));

  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_presented(p);
  struct group *g = get_group(p, &frame->node), *h = get_group(p, &other->node);
  struct leaf *border_leaf = get_leaf(p, &border->node), *client_leaf = get_leaf(p, &client->node),
              *glass_leaf = get_leaf(p, &glass->node), *overlay_leaf = get_leaf(p, &overlay->node);
  struct leaf *order[8];
  assert(p->paint.next == &g->paint && g->paint.next == &h->paint && h->paint.next == &p->paint);

  // Kinds. A leaf is a surface only once wlroots has bound it to a wl_surface.
  assert(border_leaf->item.kind == REDIWM_ITEM_RECT);
  assert(client_leaf->item.kind == REDIWM_ITEM_BUFFER);
  assert(glass_leaf->item.kind == REDIWM_ITEM_EFFECT);
  struct wlr_surface surface = {0};
  struct wlr_scene_surface scene_surface = {.surface = &surface};
  client_leaf->surface = &scene_surface;
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(client_leaf->item.kind == REDIWM_ITEM_SURFACE);
  client_leaf->surface = NULL; // The synthetic surface has no lifecycle listeners.
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(client_leaf->item.kind == REDIWM_ITEM_BUFFER);

  // Paint order, bottom to top, flattened per window.
  assert(items_of(g, order, 8) == 3 && order[0] == client_leaf && order[1] == border_leaf &&
         order[2] == glass_leaf);
  assert(items_of(h, order, 8) == 1 && order[0] == overlay_leaf);

  // Resolving alone moves no view: they keep what the last present gave them.
  int before_x = client_leaf->view->x, before_y = client_leaf->view->y;
  int before_w = wlr_scene_buffer_from_node(client_leaf->view)->dst_width;
  int group_x = g->view->node.x;
  struct view_state applied = client_leaf->applied;
  const double z = .85, cx = 6.5, cy = -2.5, ox = -17, oy = 31;
  resolve(p, z, cx, cy, ox, oy, NULL);
  assert(client_leaf->view->x == before_x && client_leaf->view->y == before_y);
  assert(wlr_scene_buffer_from_node(client_leaf->view)->dst_width == before_w);
  assert(g->view->node.x == group_x && view_state_equal(&client_leaf->applied, &applied));

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
  // stale view geometry must never become a second source of truth.
  struct graph_probe probe = {.transport = client_leaf->view, .expected = client_leaf->item};
  assert(rediwm_projection_for_each_item(p, false, probe_item, &probe) && probe.count == 1);
  probe.count = 0;
  assert(rediwm_projection_for_each_item(p, true, probe_item, &probe) && probe.count == 1);
  assert(fabs(client_leaf->item.scale - z * w) < 1e-12);
  assert(client_leaf->item.width == 100 && client_leaf->item.height == 60);
  assert(fabs(g->x - (z * 37 + tx)) < 1e-9 && fabs(g->y - (z * 29 + ty)) < 1e-9);
  // Edges, not origin and size: a size is the difference of two rounded edges.
  const struct rediwm_snap s = rediwm_edges_snap(e);
  assert(s.width == lround(e.x2) - lround(e.x1) && s.x == lround(e.x1));
  // Scaled content is filtered bilinearly whatever the client asked for.
  wlr_scene_buffer_set_filter_mode(client, WLR_SCALE_FILTER_NEAREST);
  resolve(p, z, cx, cy, ox, oy, NULL);
  assert(client_leaf->item.content.filter_mode == WLR_SCALE_FILTER_BILINEAR);
  resolve(p, 1, 0, 0, 0, 0, NULL);
  assert(rediwm_projection_set_tree_zoom(&frame->node, 1.0));
  resolve(p, 1, 0, 0, 0, 0, NULL);
  assert(client_leaf->item.content.filter_mode == WLR_SCALE_FILTER_NEAREST);
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));
  wlr_scene_buffer_set_filter_mode(client, WLR_SCALE_FILTER_BILINEAR);

  // Presenting applies exactly that graph, and only that graph.
  present(p);
  assert_presented(p);
  assert(g->view->node.x == lround(g->x));
  assert(glass_leaf->view->x == 0 && !glass_leaf->has_applied); // Left to glass.
  const double zooms[] = {.25, .5, .85, 1, 1.25};
  for (size_t i = 0; i < sizeof(zooms) / sizeof(zooms[0]); ++i)
    for (int x = -9; x <= 9; x += 3) {
      wlr_scene_node_set_position(&frame->node, x * 7, -x * 5);
      rediwm_projection_sync_fixed(p, zooms[i], x * .5, -x * .25, ox, oy, other);
      assert_presented(p);
      assert(h->x == other->node.x && h->y == other->node.y); // Fixed: no camera.
    }
  wlr_scene_node_set_position(&frame->node, 37, 29);

  // Order follows the source: raising a node reorders its list, a reparent
  // moves the leaf between lists, and a disabled branch is still resolved.
  wlr_scene_node_raise_to_top(&border->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(items_of(g, order, 8) == 3 && order[0] == client_leaf && order[1] == glass_leaf &&
         order[2] == border_leaf);
  assert(border_leaf->view->link.prev == &glass_leaf->view->link);
  wlr_scene_node_reparent(&client->node, other);
  wlr_scene_node_set_enabled(&other->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(items_of(g, order, 8) == 2 && order[0] == glass_leaf && order[1] == border_leaf);
  assert(items_of(h, order, 8) == 2 && order[0] == overlay_leaf && order[1] == client_leaf);
  assert(!h->enabled && !client_leaf->item.enabled && !overlay_leaf->item.enabled);
  assert(border_leaf->item.enabled && !h->view->node.enabled);
  assert_presented(p);
  wlr_scene_node_set_enabled(&other->node, true);

  // A subtree the pass no longer reaches leaves the graph and is hidden.
  wlr_scene_node_reparent(&other->node, &scene->tree);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(wl_list_length(&p->paint) == 1 && wl_list_empty(&h->items));
  assert(!h->seen && !h->view->node.enabled && !client_leaf->seen && !client_leaf->view->enabled);
  assert(client_leaf->paint.next == &client_leaf->paint && !client_leaf->has_applied);
  wlr_scene_node_reparent(&other->node, source);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(wl_list_length(&p->paint) == 2 && wl_list_length(&h->items) == 2);
  assert_presented(p);

  // Destruction with the lists linked: a leaf leaves its list with its source,
  // a group takes the leaves it still lists with it, and neither order of
  // teardown touches freed list heads.
  wlr_scene_node_destroy(&overlay->node);
  assert(wl_list_length(&h->items) == 1 && wl_list_length(&p->leaves) == 3);
  wlr_scene_node_destroy(&other->node);
  assert(wl_list_length(&p->paint) == 1 && wl_list_length(&p->groups) == 1);
  assert(wl_list_length(&g->items) == 2);
  effect_node = NULL;
  int checks = 0;
  struct leaf *listed;
  wl_list_for_each(listed, &g->items, paint) probe_leaf(listed, &checks);
  wlr_scene_node_destroy(&view->node); // View first: the group's addons finish first.
  assert(checks == 2); // Both leaves were checked after the group was freed.
  assert(wl_list_empty(&p->groups) && wl_list_empty(&p->leaves) && wl_list_empty(&p->paint));
  rediwm_projection_destroy(p);
  wlr_scene_node_destroy(&source->node);
  wlr_buffer_drop(buffer);
  wlr_buffer_drop(glass_buffer);
}
// Stage 4: the clip shape. Pure geometry first, with no scene at all.
static bool near(double a, double b) { return fabs(a - b) < 1e-9; }
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
  assert(rediwm_clip_opaque(&(struct rediwm_clip){rediwm_xform_rect(identity, 0, 0, 8, 8), {4, 4, 4, 4}, 0, {0}}, one) == 0);
  assert(rediwm_clip_opaque(&(struct rediwm_clip){rediwm_xform_rect(identity, 5, 7, 120, 80), {40, 40, 40, 40}, 0, {0}}, one) == 1);
  assert(one[0].x == 5 + 42 && one[0].y == 7 && one[0].width == 120 - 84 && one[0].height == 80);
}
static void test_clip_projection(struct wlr_scene *scene) {
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  struct wlr_scene_tree *frame = wlr_scene_tree_create(source);
  struct wlr_scene_tree *nested = wlr_scene_tree_create(frame);
  struct wlr_scene_tree *other = wlr_scene_tree_create(source);
  float color[4] = {.2, .3, .1, 1};
  struct wlr_scene_rect *border = wlr_scene_rect_create(frame, 17, 9, color);
  struct wlr_buffer *buffer = buffer_create(), *glass_buffer = buffer_create(), *title_buffer = buffer_create();
  struct wlr_scene_buffer *client = wlr_scene_buffer_create(nested, buffer);
  struct wlr_scene_buffer *title = wlr_scene_buffer_create(frame, title_buffer);
  struct wlr_scene_buffer *glass = wlr_scene_buffer_create(frame, glass_buffer);
  struct wlr_scene_rect *overlay = wlr_scene_rect_create(other, 20, 20, color);
  assert(frame && nested && other && border && client && title && glass && overlay);
  wlr_scene_node_set_position(&frame->node, 37, 29);
  wlr_scene_node_set_position(&nested->node, 2, 12);
  wlr_scene_buffer_set_dest_size(client, 100, 60);
  wlr_scene_buffer_set_dest_size(title, 100, 12);
  wlr_scene_buffer_set_dest_size(glass, 100, 12);
  effect_node = &glass->node;
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));
  assert(rediwm_projection_set_tree_scale(&nested->node, .5));

  // Nothing is clipped until a tree asks.
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *border_leaf = get_leaf(p, &border->node), *client_leaf = get_leaf(p, &client->node),
              *title_leaf = get_leaf(p, &title->node), *glass_leaf = get_leaf(p, &glass->node),
              *overlay_leaf = get_leaf(p, &overlay->node);
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
  resolve(p, .5, 12, -8, 3, 4, NULL);
  const struct rediwm_xform moved = rediwm_xform_scale_about(rediwm_xform_camera(.5, 12, -8, 3, 4), .85, 37, 29);
  const struct rediwm_clip want_moved = rediwm_clip_resolve(moved, 37, 29, &spec);
  assert(near(client_leaf->item.clip->edges.x1, want_moved.edges.x1) &&
         near(client_leaf->item.clip->edges.y2, want_moved.edges.y2) &&
         near(client_leaf->item.clip->radii[0], 10 * .85 * .5));
  resolve(p, 1, 0, 0, 0, 0, NULL);

  // The graph consumer sees the pointer too, and a glass effect takes the shape
  // of the titlebar it sits under, in storage of its own.
  // Glass works on the projected nodes, as the compositor calls it.
  rediwm_projection_effect_updated(wlr_scene_buffer_from_node(glass_leaf->view),
                                   wlr_scene_buffer_from_node(title_leaf->view));
  assert(glass_leaf->effect_item.clip == &glass_leaf->effect_clip);
  assert(glass_leaf->effect_item.clip != title_leaf->item.clip);
  assert(near(glass_leaf->effect_item.clip->edges.x1, want.edges.x1) &&
         near(glass_leaf->effect_item.clip->radii[1], 10 * .85));

  // A popup lives under its parent's tree but is no part of the window's shape;
  // its siblings, such as subsurfaces, still are. The barrier can be lifted.
  struct wlr_scene_tree *subsurface = wlr_scene_tree_create(nested);
  struct wlr_scene_tree *popup = wlr_scene_tree_create(nested);
  struct wlr_buffer *popup_buffer = buffer_create(), *sub_buffer = buffer_create();
  struct wlr_scene_buffer *popup_content = wlr_scene_buffer_create(popup, popup_buffer);
  struct wlr_scene_buffer *sub_content = wlr_scene_buffer_create(subsurface, sub_buffer);
  assert(popup_content && sub_content);
  wlr_scene_node_set_position(&popup->node, 90, 70); // Hanging outside the 120x80 frame.
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true));
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true)); // Idempotent.
  resolve(p, 1, 0, 0, 0, 0, NULL);
  struct leaf *popup_leaf = get_leaf(p, &popup_content->node), *sub_leaf = get_leaf(p, &sub_content->node);
  assert(!popup_leaf->item.clip && sub_leaf->item.clip && client_leaf->item.clip);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false));
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false)); // Nothing to lift is fine.
  resolve(p, 1, 0, 0, 0, 0, NULL);
  assert(popup_leaf->item.clip);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true));
  // A barrier does not hide a clip the subtree sets for itself.
  struct rediwm_clip_spec own = {.width = 50, .height = 40, .radii = {3, 3, 3, 3}};
  assert(rediwm_projection_set_tree_clip(&popup->node, &own));
  resolve(p, 1, 0, 0, 0, 0, NULL);
  assert(popup_leaf->item.clip && near(popup_leaf->item.clip->edges.x2 - popup_leaf->item.clip->edges.x1, .85 * .5 * 50));
  assert(rediwm_projection_set_tree_clip(&popup->node, NULL));
  resolve(p, 1, 0, 0, 0, 0, NULL);
  assert(!popup_leaf->item.clip);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false));

  // An inner clipped tree shapes its own leaves only.
  struct rediwm_clip_spec inner_spec = {.width = 30, .height = 20, .radii = {4, 4, 4, 4}};
  assert(rediwm_projection_set_tree_clip(&nested->node, &inner_spec));
  resolve(p, 1, 0, 0, 0, 0, NULL);
  assert(near(client_leaf->item.clip->edges.x2 - client_leaf->item.clip->edges.x1, .85 * .5 * 30));
  assert(near(title_leaf->item.clip->edges.x2 - title_leaf->item.clip->edges.x1, .85 * 120));
  assert(rediwm_projection_set_tree_clip(&nested->node, NULL));

  // A bad shape is refused and leaves the old one in force; NULL removes it.
  const struct rediwm_clip_spec bad[] = {
      {.width = 0, .height = 80}, {.width = 120, .height = -1}, {.width = 120, .height = 80, .border = -1},
      {.width = 120, .height = 80, .radii = {1, -1, 1, 1}}, {.width = 120, .height = 80, .radii = {NAN, 1, 1, 1}},
      {.width = 120, .height = 80, .border = INFINITY}};
  for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) assert(!rediwm_projection_set_tree_clip(&frame->node, &bad[i]));
  resolve(p, 1, 0, 0, 0, 0, NULL);
  assert(near(client_leaf->item.clip->edges.x2, want.edges.x2));
  spec.width = 200;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  resolve(p, 1, 0, 0, 0, 0, NULL);
  assert(near(client_leaf->item.clip->edges.x2, 37 + .85 * 200));
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL));
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL)); // Removing nothing is fine.
  resolve(p, 1, 0, 0, 0, 0, NULL);
  assert(!client_leaf->item.clip && !border_leaf->item.clip);

  // Presenting a clipped graph changes nothing about the view tree yet: the
  // shape reaches no pixel until the output pass draws it.
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_presented(p);
  // Destroying the clipped tree frees its addon with it.
  effect_node = NULL;
  wlr_scene_node_destroy(&frame->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  wlr_scene_node_destroy(&view->node);
  rediwm_projection_destroy(p);
  wlr_scene_node_destroy(&source->node);
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
static bool layout_damaged(struct wlr_scene_output *out, double x, double y) {
  return damaged(out, (int)(x * out->output->scale), (int)(y * out->output->scale));
}
static void test_clip_output(struct wlr_scene *scene, struct wlr_scene_output *out) {
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  struct wlr_scene_tree *under_tree = wlr_scene_tree_create(source);
  struct wlr_scene_tree *frame = wlr_scene_tree_create(source);
  struct wlr_buffer *under_buffer = buffer_create(), *client_buffer = buffer_create();
  struct wlr_scene_buffer *under = wlr_scene_buffer_create(under_tree, under_buffer);
  struct wlr_scene_buffer *client = wlr_scene_buffer_create(frame, client_buffer);
  assert(under_tree && frame && under && client);
  wlr_scene_node_set_position(&under_tree->node, 300, 200);
  wlr_scene_node_set_position(&frame->node, 300, 200);
  wlr_scene_buffer_set_dest_size(under, 120, 80);
  wlr_scene_buffer_set_dest_size(client, 120, 80);
  struct rediwm_clip_spec spec = {.width = 120, .height = 80, .radii = {10, 10, 10, 10}, .border = 1,
      .border_color = {.1f, .1f, .1f, .1f}};
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *client_leaf = get_leaf(p, &client->node), *under_leaf = get_leaf(p, &under->node);

  // Points inside the window reach it; the corner pixel, which the arc cuts away,
  // goes to the window below, and so does the one just outside the box.
  double nx, ny;
  struct wlr_scene_node *hit = wlr_scene_node_at(&view->node, 360, 240, &nx, &ny);
  assert(hit == client_leaf->view);
  hit = wlr_scene_node_at(&view->node, 300.5, 200.5, &nx, &ny);
  assert(hit == under_leaf->view);
  hit = wlr_scene_node_at(&view->node, 419.5, 279.5, &nx, &ny); // bottom-right corner
  assert(hit == under_leaf->view);
  hit = wlr_scene_node_at(&view->node, 310.5, 200.5, &nx, &ny); // on the straight edge
  assert(hit == client_leaf->view);
  // Without a shape the corner is the window's again.
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(wlr_scene_node_at(&view->node, 300.5, 200.5, &nx, &ny) == client_leaf->view);
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
  assert(pixman_region32_not_empty(&out->private.pending_commit_damage));
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
  wlr_scene_node_set_position(&frame->node, 310, 200);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 370, 240)); // the views of the window moved
  wlr_scene_node_set_position(&frame->node, 300, 200);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  // A hidden window damages nothing for a shape change.
  wlr_scene_node_set_enabled(&frame->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  clear_damage(out);
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  spec.border_color[1] = .7f;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  wlr_scene_node_destroy(&view->node);
  rediwm_projection_destroy(p);
  wlr_scene_node_destroy(&source->node);
  wlr_buffer_drop(under_buffer);
  wlr_buffer_drop(client_buffer);
}
// Stage 4d: a shadow's view has no buffer, so wlroots damages nothing for it and the
// projection damages the footprint itself: when it appears, moves, changes, is
// hidden with its window, or goes away, and never when nothing changed.
static void test_shadow_output(struct wlr_scene *scene, struct wlr_scene_output *out) {
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  struct wlr_scene_tree *frame = wlr_scene_tree_create(source);
  struct wlr_scene_tree *shadow_tree = wlr_scene_tree_create(frame);
  struct wlr_scene_buffer *footprint = wlr_scene_buffer_create(shadow_tree, NULL);
  assert(frame && shadow_tree && footprint);
  wlr_scene_node_set_position(&frame->node, 100, 100);
  wlr_scene_node_set_position(&footprint->node, -16, -8);
  wlr_scene_buffer_set_dest_size(footprint, 152, 112);
  struct rediwm_shadow_spec spec = {.width = 120, .height = 80, .radii = {10, 10, 10, 10},
      .offset_y = 8, .softness = 16, .color = {0, 0, 0, .4f}};
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *l = get_leaf(p, &footprint->node);
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
  wlr_scene_node_set_position(&frame->node, 140, 100);
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
  wlr_scene_node_set_enabled(&frame->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 130, 140));
  clear_damage(out);
  wlr_scene_node_set_enabled(&frame->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 130, 140));
  clear_damage(out);
  wlr_scene_node_destroy(&footprint->node);
  assert(layout_damaged(out, 130, 140));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);

  wlr_scene_node_destroy(&view->node);
  rediwm_projection_destroy(p);
  wlr_scene_node_destroy(&source->node);
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
static void test_damage_events(struct wlr_scene *scene) {
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  uint64_t cursor = rediwm_projection_damage_cursor(p), other = cursor;
  struct wlr_scene_tree *window = wlr_scene_tree_create(source);
  struct wlr_buffer *buffer = buffer_create(); // 200x120
  struct wlr_scene_buffer *a = wlr_scene_buffer_create(window, buffer);
  struct wlr_scene_buffer *b = wlr_scene_buffer_create(window, buffer);
  wlr_scene_node_set_position(&window->node, 40, 30);
  wlr_scene_buffer_set_dest_size(a, 100, 60); // half size: one buffer px = 0.5
  wlr_scene_node_set_position(&b->node, 0, 100);
  wlr_scene_buffer_set_dest_size(b, 20, 20);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *la = get_leaf(p, &a->node), *lb = get_leaf(p, &b->node);
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
  wlr_scene_node_set_position(&b->node, 10, 100);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 2);
  assert(event_is(&seen.last[0], lb->item.id, 40, 130, 20, 20));
  assert(event_is(&seen.last[1], lb->item.id, 50, 130, 20, 20));
  wlr_scene_node_set_enabled(&b->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], lb->item.id, 50, 130, 20, 20));
  wlr_scene_node_set_enabled(&b->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], lb->item.id, 50, 130, 20, 20));
  // A changed opacity is a restyle of the whole box.
  wlr_scene_buffer_set_opacity(a, .5f);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 2 && event_is(&seen.last[1], la->item.id, 40, 30, 100, 60));
  // A destroyed leaf reports its last box at once.
  const uint64_t gone = lb->item.id;
  wlr_scene_node_destroy(&b->node);
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], gone, 50, 130, 20, 20));

  // A second consumer read nothing yet and sees everything since its cursor.
  bool complete = false;
  seen = events_since(p, &other, &complete);
  assert(complete && seen.count == 11);
  // One that falls behind the ring is told so.
  uint64_t stale = rediwm_projection_damage_cursor(p);
  for (int i = 0; i < 2100; i++) {
    wlr_scene_node_set_position(&window->node, 40 + i % 2, 30);
    rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  }
  events_since(p, &stale, &complete);
  assert(!complete);
  assert(events_since(p, &stale, &complete).count == 0 && complete);

  pixman_region32_fini(&damage);
  wlr_scene_node_destroy(&view->node);
  rediwm_projection_destroy(p);
  wlr_scene_node_destroy(&source->node);
  wlr_buffer_drop(buffer);
}
// A client surface's opaque region has to reach its view, or nothing below the
// window is ever culled. The buffers here reveal no format, like a
// wlr_client_buffer, so only the node's own region can say they are opaque.
static void test_opaque(struct wlr_scene *scene) {
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  struct wlr_buffer *below_buffer = buffer_create(), *client_buffer = buffer_create();
  struct wlr_scene_buffer *below = wlr_scene_buffer_create(source, below_buffer);
  struct wlr_scene_buffer *client = wlr_scene_buffer_create(source, client_buffer);
  assert(below && client);
  wlr_scene_node_set_position(&below->node, 20, 10);
  wlr_scene_node_set_position(&client->node, 20, 10);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct wlr_scene_node *below_view = rediwm_projection_node(p, &below->node);
  assert(below_view && visible_at(below_view, 100, 60));

  pixman_region32_t region;
  pixman_region32_init_rect(&region, 0, 0, 200, 120);
  wlr_scene_buffer_set_opaque_region(client, &region);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!visible_at(below_view, 100, 60) && !visible_at(below_view, 21, 11));

  // Only the client's own region occludes, and a changed region is applied
  // although the view's geometry did not change.
  pixman_region32_clear(&region);
  pixman_region32_union_rect(&region, &region, 50, 30, 100, 60);
  wlr_scene_buffer_set_opaque_region(client, &region);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!visible_at(below_view, 100, 60) && !visible_at(below_view, 70, 40));
  assert(visible_at(below_view, 30, 20) && visible_at(below_view, 215, 125));
  pixman_region32_clear(&region);
  wlr_scene_buffer_set_opaque_region(client, &region);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(visible_at(below_view, 100, 60));

  // Scaled with the view and pulled one pixel in: the middle is culled, the
  // edge pixels, which the filter may blend with what is outside, are drawn.
  pixman_region32_union_rect(&region, &region, 0, 0, 200, 120);
  wlr_scene_buffer_set_opaque_region(client, &region);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(!visible_at(below_view, 60, 35));
  assert(visible_at(below_view, 10, 5) && visible_at(below_view, 109, 64));

  // A translucent node hides nothing, whatever its region says.
  wlr_scene_buffer_set_opacity(client, .5f);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(visible_at(below_view, 100, 60));
  wlr_scene_buffer_set_opacity(client, 1.f);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!visible_at(below_view, 100, 60));

  pixman_region32_fini(&region);
  rediwm_projection_destroy(p);
  wlr_buffer_drop(below_buffer);
  wlr_buffer_drop(client_buffer);
}
static void test_groups(struct wlr_scene *scene, struct wlr_scene_output *out) {
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  struct wlr_scene_tree *frame = wlr_scene_tree_create(source);
  struct wlr_scene_tree *nested = wlr_scene_tree_create(frame);
  struct wlr_scene_tree *other = wlr_scene_tree_create(source);
  float color[4] = {.2, .3, .1, 1};
  struct wlr_scene_rect *border = wlr_scene_rect_create(frame, 17, 9, color);
  struct wlr_buffer *buffer = buffer_create();
  struct wlr_scene_buffer *client = wlr_scene_buffer_create(nested, buffer);
  struct wlr_scene_rect *overlay = wlr_scene_rect_create(other, 20, 20, color);
  assert(frame && nested && other && border && client && overlay);
  wlr_scene_node_set_position(&frame->node, 37, 29);
  wlr_scene_node_set_position(&nested->node, -12, 5);
  wlr_scene_node_set_position(&client->node, 4, 3);
  wlr_scene_node_set_position(&border->node, -2, -3);
  wlr_scene_node_set_position(&other->node, 90, 60);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct group *g = get_group(p, &frame->node);
  struct group *h = get_group(p, &other->node);
  struct leaf *l = get_leaf(p, &client->node);
  assert(l->view->parent == g->view);
  assert(get_leaf(p, &border->node)->view->parent == g->view);
  assert(wl_list_length(&view->children) == 2);
  assert_position(p, &client->node, 29, 37);
  assert_position(p, &border->node, 35, 26);
  int local_x = l->view->x, local_y = l->view->y;
  clear_damage(out);
  wlr_scene_node_set_position(&frame->node, 83, 71);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  // Ordinary movement changes one group origin; child setters are no-ops.
  assert(l->view->x == local_x && l->view->y == local_y);
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
  assert(wlr_scene_buffer_from_node(l->view)->dst_width == 200);
  rediwm_projection_sync(p, .5, 10, 20, 0, 0);
  assert_position(p, &client->node, 33, 30);

  // Endpoint rounding must remain global, including half-pixels crossing
  // zero. Integer rounding of a local offset is not equivalent here.
  const double zooms[] = {.5, .85, 1, 1.25};
  for (size_t i = 0; i < sizeof(zooms) / sizeof(zooms[0]); ++i) {
    double z = zooms[i], cx = 6.5, cy = -2.5, ox = -17, oy = 31;
    double tx = ox * (1 - z) - z * cx, ty = oy * (1 - z) - z * cy;
    for (int x = -13; x <= 13; ++x) {
      wlr_scene_node_set_position(&frame->node, x, -x);
      rediwm_projection_sync(p, z, cx, cy, ox, oy);
      assert_position(p, &client->node, lround(z * (x - 8) + tx),
                       lround(z * (-x + 8) + ty));
      assert_position(p, &border->node, lround(z * (x - 2) + tx),
                       lround(z * (-x - 3) + ty));
      struct wlr_scene_buffer *v = wlr_scene_buffer_from_node(l->view);
      assert(v->dst_width == lround(z * (x - 8 + 200) + tx) -
                             lround(z * (x - 8) + tx));
    }
  }
  // Window zoom multiplies the camera scale while preserving its world origin.
  // Nested geometry keeps the same per-leaf projected scale.
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));
  wlr_scene_node_set_position(&frame->node, -17, 23);
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert_position(p, &client->node, lround(.5 * -17 - 1.5 + (.85 * .5) * -8),
                   lround(.5 * 23 + 3.5 + (.85 * .5) * 8));
  assert(rediwm_projection_node_zoom(l->view) == (.85 * .5));

  // A relative tree scale composes with camera and window zoom, preserving origin.
  assert(rediwm_projection_set_tree_scale(&nested->node, .5));
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert(fabs(rediwm_projection_node_zoom(l->view) - ((.85 * .5) * .5)) < .0001);
  assert_position(p, &client->node, lround(.5 * -17 - 1.5 + (.85 * .5) * -12 + (.85 * .5) * .5 * 4),
                   lround(.5 * 23 + 3.5 + (.85 * .5) * 5 + (.85 * .5) * .5 * 3));
  assert(rediwm_projection_set_tree_scale(&nested->node, 1.0));
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert(fabs(rediwm_projection_node_zoom(l->view) - (.85 * .5)) < .0001);
  assert(rediwm_projection_set_tree_zoom(&frame->node, 1.0));

  // Reorder a whole window and a leaf within it, retaining source paint order.
  wlr_scene_node_raise_to_top(&frame->node);
  wlr_scene_node_raise_to_top(&nested->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(g->view->node.link.prev == &h->view->node.link);
  assert(l->view->link.prev == &get_leaf(p, &border->node)->view->link);
  // Input lookup and surface routing remain attached to the leaf when a
  // subsurface changes source root, rather than retaining a stale group.
  wlr_scene_node_reparent(&client->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(l->view->parent == h->view);
  assert_position(p, &client->node, 94, 63);
  double input_x = 40, input_y = 24;
  assert(accepts(wlr_scene_buffer_from_node(l->view), &input_x, &input_y));
  assert(input_x == 40 && input_y == 24);
  wlr_scene_node_set_enabled(&other->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  int x = 0, y = 0;
  assert(!wlr_scene_node_coords(l->view, &x, &y));
  wlr_scene_node_set_enabled(&other->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_position(p, &client->node, 94, 63);

  // A former source root can become nested, leave the projected tree, and
  // return. Its unused group must hide while its leaves change group, and
  // neither its former position nor window zoom may leak into other leaves.
  wlr_scene_node_reparent(&frame->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!g->view->node.enabled);
  assert(get_leaf(p, &border->node)->view->parent == h->view);
  assert_position(p, &border->node, 71, 80);
  assert_position(p, &client->node, 94, 63);
  wlr_scene_node_reparent(&frame->node, &scene->tree);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!wlr_scene_node_coords(get_leaf(p, &border->node)->view, &x, &y));
  wlr_scene_node_reparent(&frame->node, source);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(g->view->node.enabled);
  assert(get_leaf(p, &border->node)->view->parent == g->view);
  assert_position(p, &border->node, -19, 20);

  // Destruction can precede synchronization after reparenting. The old view
  // group still owns this leaf, but the surviving source must be recreatable.
  struct wlr_scene_tree *temporary = wlr_scene_tree_create(source);
  struct wlr_scene_rect *survivor = wlr_scene_rect_create(temporary, 12, 12, color);
  assert(temporary && survivor);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  wlr_scene_node_reparent(&survivor->node, other);
  wlr_scene_node_destroy(&temporary->node);
  assert(!rediwm_projection_node(p, &survivor->node));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_position(p, &survivor->node, 90, 60);
  wlr_scene_node_destroy(&survivor->node);

  // A direct leaf can itself be a former group root. After it becomes nested,
  // destroying the source runs both leaf and group cleanup on the same node.
  struct wlr_scene_rect *direct = wlr_scene_rect_create(source, 12, 12, color);
  assert(direct);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  wlr_scene_node_reparent(&direct->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(get_leaf(p, &direct->node)->view->parent == h->view);
  wlr_scene_node_destroy(&direct->node);
  assert(wl_list_length(&p->groups) == 2 && wl_list_length(&p->leaves) == 3);

  // Source-first teardown destroys its group without dangling leaf listeners;
  // view-first teardown removes every adapter before the source is destroyed.
  wlr_scene_node_destroy(&frame->node);
  assert(wl_list_length(&p->groups) == 1 && wl_list_length(&p->leaves) == 2);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  wlr_scene_node_destroy(&view->node);
  assert(wl_list_empty(&p->groups) && wl_list_empty(&p->leaves));
  rediwm_projection_destroy(p);
  wlr_scene_node_destroy(&source->node);
  wlr_buffer_drop(buffer);
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
  struct wlr_scene *scene = wlr_scene_create();
  assert(scene);
  struct wlr_scene_output *out = wlr_scene_output_create(scene, output);
  assert(out);
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  struct wlr_buffer *a = buffer_create(), *b = buffer_create();
  struct wlr_scene_buffer *node = wlr_scene_buffer_create(source, a);
  assert(node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 100, 60)); // First presentation is fully damaged.
  clear_damage(out);

  struct leaf *l = get_leaf(p, &node->node);
  struct wlr_surface surface = {.current = {.buffer_width = 200, .buffer_height = 120}};
  pixman_region32_init(&surface.buffer_damage);
  struct wlr_scene_surface scene_surface = {.surface = &surface};
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
  wlr_scene_buffer_set_buffer(node, b);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  wlr_scene_buffer_set_buffer(node, a);
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
  wlr_scene_buffer_set_source_box(node, &(struct wlr_fbox){20, 20, 100, 60});
  wlr_scene_buffer_set_dest_size(node, 100, 60);
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
  wlr_scene_node_set_position(&node->node, 200, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 20, 20) && damaged(out, 170, 20));
  clear_damage(out);
  wlr_scene_node_set_enabled(&node->node, false);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  wlr_scene_node_set_enabled(&node->node, true);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 170, 20));
  wlr_scene_node_set_position(&node->node, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);

  // Unmap/remap must repaint even when the remapping commit has empty damage.
  wlr_scene_buffer_set_buffer(node, NULL);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  wlr_scene_buffer_set_buffer(node, a);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 25, 15));

  l->surface = NULL; // Synthetic surface has no lifecycle listeners to route.
  pixman_region32_fini(&surface.buffer_damage);
  rediwm_projection_destroy(p);
  test_groups(scene, out);
  test_graph(scene);
  test_clip_geometry();
  test_clip_opaque();
  test_clip_projection(scene);
  test_clip_output(scene, out);
  test_shadow_output(scene, out);
  test_damage_events(scene);
  test_opaque(scene);
  wlr_scene_node_destroy(&scene->tree.node);
  wlr_buffer_drop(a);
  wlr_buffer_drop(b);
  wlr_backend_destroy(backend);
  wl_display_destroy(display);
  puts("PASS: projection damage, grouping, geometry, graph, opaque regions and lifecycle");
  return 0;
}
