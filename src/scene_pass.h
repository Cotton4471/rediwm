// Radius-zero GLES2 drawing for the owned scene output pass. The caller owns
// output policy (damage, culling, feedback, swapchain and commit). Using the
// wlroots pass interface also lets software cursors use the same pass.
#pragma once
#include <wlr/render/pass.h>

struct rediwm_scene_renderer;
// The renderer must be GLES2 and outlive this object and all its passes.
struct rediwm_scene_renderer *rediwm_scene_renderer_create(struct wlr_renderer *);
void rediwm_scene_renderer_destroy(struct rediwm_scene_renderer *);
// Exactly one pass at a time. Submit even after a draw fails: submit reports
// the failure and restores the GL/EGL state. Destination and texture lifetimes
// follow wlr_renderer_begin_buffer_pass. No timers or output colour transforms
// are supported; non-NULL requests fail instead of silently ignoring them.
struct wlr_render_pass *rediwm_scene_pass_begin(struct rediwm_scene_renderer *,
    struct wlr_buffer *, const struct wlr_buffer_pass_options *);
