#pragma once
#include <stdbool.h>
struct wlr_renderer;
struct wlr_scene_output;
struct wlr_output_state;
struct rediwm_projection;
struct rediwm_output_renderer;
struct wlr_render_pass;
struct wlr_buffer;
struct wlr_buffer_pass_options;
struct rediwm_output_renderer *rediwm_output_renderer_create(struct wlr_renderer *);
void rediwm_output_renderer_destroy(struct rediwm_output_renderer *);
// Node-subset capture uses the same drawing backend with its own swapchain
// and ReadFence; it must not inherit output culling or screen geometry.
struct wlr_render_pass *rediwm_output_begin_pass(struct rediwm_output_renderer *,
    struct wlr_buffer *, const struct wlr_buffer_pass_options *);
// Builds but never commits. The scene adapter continues to own surface
// enter/leave, pacing and the damage notifications during stages 3–5.
bool rediwm_scene_output_build_state(struct rediwm_output_renderer *,
    struct rediwm_projection *, struct wlr_scene_output *, struct wlr_output_state *);
void rediwm_scene_output_damage_whole(struct wlr_scene_output *);
