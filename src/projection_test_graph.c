// Graph tests: clean syncs, geometry, clips and their projection.
// Included by projection_test.c, in its one unit with the projection.

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
  struct group *g = projection_get_group(p, &frame->node), *h = projection_get_group(p, &other->node);
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
  projection_resolve(p, z, cx, cy, ox, oy, NULL, true);
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
  projection_resolve(p, z, cx, cy, ox, oy, NULL, true);
  assert(client_leaf->item.content.filter_mode == WLR_SCALE_FILTER_BILINEAR);
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(rediwm_projection_set_tree_zoom(&frame->node, 1.0));
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(client_leaf->item.content.filter_mode == WLR_SCALE_FILTER_NEAREST);
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));
  rediwm_buffer_set_filter_mode(client, WLR_SCALE_FILTER_BILINEAR);

  // Presenting shows exactly that graph, and only that graph.
  projection_present(p, true);
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
// A polygon outline: the distance, the part of the box that is surely inside, and
// the cover built from it. A 100x60 frame with its top-left corner cut and a 10 px
// step in the top edge from x = 60.
static void test_polygon_geometry(void) {
  const struct rediwm_xform id = {1, 0, 0};
  struct rediwm_clip_spec spec = {.width = 100, .height = 60, .poly_count = 7, .border = 1};
  const double v[7][2] = {{0, 20}, {20, 0}, {60, 0}, {70, 10}, {100, 10}, {100, 60}, {0, 60}};
  memcpy(spec.poly, v, sizeof(v));
  struct rediwm_clip clip = rediwm_clip_resolve(id, 10, 5, &spec);
  assert(clip.poly_count == 7 && near(clip.poly[1][0], 30) && near(clip.poly[1][1], 5));
  // The distance: inside is negative, a straight edge is exact, the cut is outside.
  assert(rediwm_clip_distance(&clip, 60, 35) < 0);
  assert(near(rediwm_clip_distance(&clip, 40, 5), 0));        // On the top edge.
  assert(near(rediwm_clip_distance(&clip, 40, 2), 3));        // 3 above it.
  assert(near(rediwm_clip_distance(&clip, 90, 15), 0));       // On the step.
  assert(near(rediwm_clip_distance(&clip, 90, 12), 3));       // Above the lower edge.
  assert(near(rediwm_clip_distance(&clip, 10, 65), 0));       // On the bottom edge.
  assert(near(rediwm_clip_distance(&clip, 11, 6), 18 * sqrt(.5))); // Beside the cut.
  assert(rediwm_clip_distance(&clip, 10, 5) > 0);             // The cut-away corner.
  // Either winding.
  struct rediwm_clip_spec rev = spec;
  for (int i = 0; i < 7; i++) memcpy(rev.poly[i], v[6 - i], sizeof(v[0]));
  const struct rediwm_clip back = rediwm_clip_resolve(id, 10, 5, &rev);
  for (double px = 8; px < 112; px += 7.3)
    for (double py = 3; py < 68; py += 6.1)
      assert(near(rediwm_clip_distance(&clip, px, py), rediwm_clip_distance(&back, px, py)));
  // What is surely inside leaves out the cut and the step, nothing more than needed.
  assert(clip.inset >= 10 && clip.inset <= 21);
  struct rediwm_snap cover[3];
  const int n = rediwm_clip_opaque(&clip, cover);
  assert(n == 1);
  for (int y = cover[0].y; y < cover[0].y + cover[0].height; y++)
    for (int x = cover[0].x; x < cover[0].x + cover[0].width; x++)
      assert(rediwm_clip_distance(&clip, x + .5, y + .5) < -.5);
  // The rounded rectangle is unchanged: no polygon, inset = the largest radius.
  const struct rediwm_clip_spec round = {.width = 100, .height = 60, .radii = {4, 9, 6, 2}};
  const struct rediwm_clip rc = rediwm_clip_resolve(id, 0, 0, &round);
  assert(rc.poly_count == 0 && near(rc.inset, 9));
  // Same outline wherever it sits; a different point is a different outline.
  const struct rediwm_clip moved = rediwm_clip_resolve(id, 50, 80, &spec);
  assert(rediwm_clip_outline_equal(&clip, &moved));
  spec.poly[3][0] = 66;
  const struct rediwm_clip edited = rediwm_clip_resolve(id, 10, 5, &spec);
  assert(!rediwm_clip_outline_equal(&clip, &edited));
  // A triangle has a rectangle in it only well inside, and claims just that.
  const struct rediwm_clip_spec thin = {.width = 40, .height = 40, .poly_count = 3, .poly = {{0, 0}, {40, 20}, {0, 40}}};
  const struct rediwm_clip tc = rediwm_clip_resolve(id, 0, 0, &thin);
  assert(rediwm_clip_opaque(&tc, cover) == 1);
  for (int y = cover[0].y; y < cover[0].y + cover[0].height; y++)
    for (int x = cover[0].x; x < cover[0].x + cover[0].width; x++)
      assert(rediwm_clip_distance(&tc, x + .5, y + .5) < -.5);
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
  assert(rediwm_clip_opaque(&(struct rediwm_clip){.edges = rediwm_xform_rect(identity, 0, 0, 8, 8), .radii = {4, 4, 4, 4}}, one) == 0);
  assert(rediwm_clip_opaque(&(struct rediwm_clip){.edges = rediwm_xform_rect(identity, 5, 7, 120, 80), .radii = {40, 40, 40, 40}}, one) == 1);
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
  projection_resolve(p, .5, 12, -8, 3, 4, NULL, true);
  const struct rediwm_xform moved = rediwm_xform_scale_about(rediwm_xform_camera(.5, 12, -8, 3, 4), .85, 37, 29);
  const struct rediwm_clip want_moved = rediwm_clip_resolve(moved, 37, 29, &spec);
  assert(near(client_leaf->item.clip->edges.x1, want_moved.edges.x1) &&
         near(client_leaf->item.clip->edges.y2, want_moved.edges.y2) &&
         near(client_leaf->item.clip->radii[0], 10 * .85 * .5));
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);

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
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
  struct leaf *popup_leaf = leaf_of(p, &popup_content->node), *sub_leaf = leaf_of(p, &sub_content->node);
  assert(!popup_leaf->item.clip && sub_leaf->item.clip && client_leaf->item.clip);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false));
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false)); // Nothing to lift is fine.
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(popup_leaf->item.clip);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true));
  // A barrier does not hide a clip the subtree sets for itself.
  struct rediwm_clip_spec own = {.width = 50, .height = 40, .radii = {3, 3, 3, 3}};
  assert(rediwm_projection_set_tree_clip(&popup->node, &own));
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(popup_leaf->item.clip && near(popup_leaf->item.clip->edges.x2 - popup_leaf->item.clip->edges.x1, .85 * .5 * 50));
  assert(rediwm_projection_set_tree_clip(&popup->node, NULL));
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(!popup_leaf->item.clip);
  assert(rediwm_projection_set_tree_unclipped(&popup->node, false));

  // An inner clipped tree shapes its own leaves only.
  struct rediwm_clip_spec inner_spec = {.width = 30, .height = 20, .radii = {4, 4, 4, 4}};
  assert(rediwm_projection_set_tree_clip(&nested->node, &inner_spec));
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(near(client_leaf->item.clip->edges.x2 - client_leaf->item.clip->edges.x1, .85 * .5 * 30));
  assert(near(title_leaf->item.clip->edges.x2 - title_leaf->item.clip->edges.x1, .85 * 120));
  assert(rediwm_projection_set_tree_clip(&nested->node, NULL));

  // A bad shape is refused and leaves the old one in force; NULL removes it.
  const struct rediwm_clip_spec bad[] = {
      {.width = 0, .height = 80}, {.width = 120, .height = -1}, {.width = 120, .height = 80, .border = -1},
      {.width = 120, .height = 80, .radii = {1, -1, 1, 1}}, {.width = 120, .height = 80, .radii = {NAN, 1, 1, 1}},
      {.width = 120, .height = 80, .border = INFINITY}};
  for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) assert(!rediwm_projection_set_tree_clip(&frame->node, &bad[i]));
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(near(client_leaf->item.clip->edges.x2, want.edges.x2));
  spec.width = 200;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
  assert(near(client_leaf->item.clip->edges.x2, 37 + .85 * 200));
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL));
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL)); // Removing nothing is fine.
  projection_resolve(p, 1, 0, 0, 0, 0, NULL, true);
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
