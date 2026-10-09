#pragma once
struct wlr_scene;
struct pixman_region32;
// Damages a layout-space region on every output it touches, for changes that
// move no view node (a clip's border colour).
void rediwm_scene_damage_layout(struct wlr_scene *, const struct pixman_region32 *);
