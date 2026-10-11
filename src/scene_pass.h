// GLES2 drawing for the owned scene output pass. The caller owns output policy
// (damage, culling, feedback, swapchain and commit). Using the wlroots pass
// interface also lets software cursors use the same pass.
#pragma once
#include <stdbool.h>
#include <wlr/render/pass.h>
#include <wlr/util/box.h>

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

// Stage 4b of docs/plans/scene-graph.md: rounded-rectangle shapes. One shape
// clips every piece of a window (titlebar, client, border, shadow), and each
// piece is a draw that names the shape, so they agree on the arc to the last bit
// and there is no per-piece corner approximation. Plain add_rect/add_texture
// calls are unchanged and never touch these programs.
//
// All numbers are device pixels of the destination buffer, in the same space as
// `box` of the draws (y down, row 0 first). The caller snaps the box (see
// rediwm_edges_snap in scene_graph.h) and scales the radii and border; nothing
// is rounded here, so a fractional radius or border is drawn as given.
struct rediwm_pass_shape {
  struct wlr_box box;
  // Top-left, top-right, bottom-right, bottom-left. A radius larger than half
  // the short side is capped to it.
  float radii[4];
  // Width of the ring just inside the edge. The same fragment that draws the body
  // composites the ring over it, then applies the shape's coverage, so a
  // translucent border tints the fill beneath it, as the legacy border rects do,
  // and an opaque one equals splitting the pixel between body and ring exactly.
  // 0 draws no ring.
  float border;
  float border_color[4]; // premultiplied
};
struct rediwm_pass_shadow {
  float offset_x, offset_y; // how far the shadow is shifted from the shape
  // Full strength inside the moved shape, falling to nothing this far outside it
  // with a smoothstep, as the CPU chrome's shadow does; below 0.25 it is 0.25.
  float softness;
  float color[4];           // premultiplied, at full strength under the shape's edge
  // Keep the shadow out of the shape, so a translucent window does not show it.
  bool hide_inside;
  const pixman_region32_t *clip; // damage, as for any draw; NULL for everything
};

// Builds the shaped programs, which cost the driver about 430 KiB and are
// therefore not made with the renderer. Call it once, outside a pass, before the
// first shaped draw; later calls return the first result. False when they did not
// build: shaped draws then fail the pass at submit, plain drawing is unaffected.
bool rediwm_scene_renderer_enable_shapes(struct rediwm_scene_renderer *);

// These take a pass from rediwm_scene_pass_begin only (a wlroots pass is a
// programming error). `box` of the options is the piece to draw; the shape is
// what clips it, so a piece is usually a part of the shape's box.
//
// Edges are anti-aliased by multiplying the piece's premultiplied colour by the
// shape's pixel coverage, so the blend mode must be PREMULTIPLIED wherever the
// shape's edge crosses the piece. NONE is only right inside the part of the shape
// that is fully covered (see rediwm_clip_opaque in scene_graph.h).
void rediwm_scene_pass_add_rect_shaped(struct wlr_render_pass *,
    const struct wlr_render_rect_options *, const struct rediwm_pass_shape *);
void rediwm_scene_pass_add_texture_shaped(struct wlr_render_pass *,
    const struct wlr_render_texture_options *, const struct rediwm_pass_shape *);
// The shape's shadow. The quad reaches the softness and the offset past the box.
void rediwm_scene_pass_add_shadow(struct wlr_render_pass *, const struct rediwm_pass_shape *,
    const struct rediwm_pass_shadow *);

// Stage 5b of docs/plans/scene-graph.md: backdrop effects (glass). An effect
// blurs what the pass has drawn so far under a region and composites it through
// its shape, under the surface it backs. The blur is kept between frames in a
// `rediwm_backdrop`, owned by the caller, so an effect is re-blurred only when
// what lies below it changed (stage 5, D1); compositing a kept blur is cheap.
struct rediwm_backdrop;
// Builds the blur program (about 140 KiB), outside a pass. Requires
// rediwm_scene_renderer_enable_shapes, whose program composites. Later calls
// return the first result; without it, backdrop calls fail the pass.
bool rediwm_scene_renderer_enable_backdrops(struct rediwm_scene_renderer *);
// Frees a backdrop's GL resources; outside a pass. NULL is a no-op.
void rediwm_scene_renderer_destroy_backdrop(struct rediwm_scene_renderer *, struct rediwm_backdrop *);
// Copies `region` (device pixels of this pass's buffer; the part outside the
// buffer replicates its edge) as drawn so far and blurs it at quarter size with
// a Gaussian of `sigma` device pixels into `*backdrop`, creating it if NULL. Not
// limited by any clip: the caller must have drawn everything below the effect
// in the whole region first (with buffer age, that means damaging all of it).
void rediwm_scene_pass_capture_backdrop(struct wlr_render_pass *, struct rediwm_backdrop **,
    struct wlr_box region, float sigma);
struct rediwm_pass_backdrop {
  const struct rediwm_backdrop *backdrop;
  float saturation; // 1 leaves colours as they are
  float opacity;    // the effect's, times the shape's coverage
  // The surface drawn over the effect, whose alpha the effect makes up to the
  // coverage (its alpha a: the effect draws (coverage - a) / (1 - a)), so the pair
  // is exactly as opaque as the shape and a curved edge is not covered twice.
  // NULL when nothing is drawn over it.
  struct wlr_texture *front;
  struct wlr_box front_box; // where `front` is drawn, whole texture, untransformed
  float front_opacity;
  const pixman_region32_t *clip;
};
// Composites `backdrop` through `shape` over `box` (device pixels).
void rediwm_scene_pass_add_backdrop(struct wlr_render_pass *, const struct rediwm_pass_shape *,
    struct wlr_box box, const struct rediwm_pass_backdrop *);
