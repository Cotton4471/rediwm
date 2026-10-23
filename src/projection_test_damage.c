// Output damage tests: clips and shadows on screen, damage events, dim and opaque
// regions.
// Included by projection_test.c, in its one unit with the projection.

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
