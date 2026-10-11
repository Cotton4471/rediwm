// What the owned output pass needs to know about a glass effect (stage 5 of
// docs/plans/scene-graph.md). glass.c only registers effects; the pass blurs.
#pragma once
#include <stdbool.h>
#include <stdint.h>
struct wlr_scene_node;
struct wlr_scene_buffer;
struct rediwm_glass_info {
  // The surface the effect backs: drawn over it, same parent, same box.
  struct wlr_scene_buffer *target;
  float sigma;      // Gaussian sigma, logical px, before any zoom
  float saturation; // 1 leaves colours unchanged
  float opacity;
  float radius;     // logical px; a window's effect takes the window's shape instead
  // Unique for the effect's life (a node address can be reused).
  uint64_t serial;
  // Keep the last blur while the effect moves (a dragged opaque titlebar, camera motion).
  bool held;
};
// False when `node` is not a glass effect node.
bool rediwm_glass_effect_info(struct wlr_scene_node *node, struct rediwm_glass_info *out);
bool rediwm_glass_is_effect_node(struct wlr_scene_node *node);
