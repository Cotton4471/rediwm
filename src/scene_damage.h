#pragma once
struct rediwm_scene_outputs;
struct pixman_region32;
// Damages a layout-space region on every output it touches, for changes that
// move no view node (a clip's border colour).
void rediwm_scene_damage_layout(struct rediwm_scene_outputs *, const struct pixman_region32 *);
