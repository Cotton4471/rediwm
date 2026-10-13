// The typed form of what the compositor shows (stage 2 of
// docs/plans/scene-graph.md). A source tree is resolved into items held in paint
// order: a kind, float edges in layout space, the composed scale and the content
// to draw. A presenter consumes the items and is the only code that rounds.
//
// Pure: no wlroots calls and no state, so it is tested alone and the stage 3
// output pass can use it as it is. Every expression here is the one projection.c
// evaluated inline before the split; keep operands and order, since a rounding
// that moves by one pixel at a half-pixel edge is a visible change.
#pragma once
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <wayland-server-protocol.h>
#include <wlr/render/color.h>
#include <wlr/render/pass.h>
#include <wlr/util/box.h>

// Source space to layout space: p -> scale * p + (tx, ty). Uniform scale only;
// a window zoom, an Xwayland 1/N scale and the camera all compose into one.
struct rediwm_xform {
  double scale, tx, ty;
};
// The camera at zoom `z`, panned to (cx, cy) over a layout whose origin is
// (ox, oy): the scene is scaled about the layout origin, then shifted.
static inline struct rediwm_xform rediwm_xform_camera(double z, double cx, double cy,
                                                      double ox, double oy) {
  return (struct rediwm_xform){z, ox * (1 - z) - z * cx, oy * (1 - z) - z * cy};
}
// `t` followed by a relative scale `factor` about the source point (x, y), so
// that point stays where it was.
static inline struct rediwm_xform rediwm_xform_scale_about(struct rediwm_xform t,
                                                           double factor, double x,
                                                           double y) {
  const double scale = t.scale * factor;
  return (struct rediwm_xform){scale, t.tx + (t.scale - scale) * x,
                               t.ty + (t.scale - scale) * y};
}
static inline void rediwm_xform_point(struct rediwm_xform t, double x, double y,
                                      double *out_x, double *out_y) {
  *out_x = t.scale * x + t.tx;
  *out_y = t.scale * y + t.ty;
}

// A rectangle as its four edges, not origin and size. Each edge is transformed
// on its own and rounded on its own, so neighbours that share an edge in source
// space share the same pixel column in the output, at any scale, and a size is
// never rounded separately from a position.
struct rediwm_edges {
  double x1, y1, x2, y2;
};
static inline struct rediwm_edges rediwm_xform_rect(struct rediwm_xform t, double x,
                                                    double y, int width, int height) {
  return (struct rediwm_edges){t.scale * x + t.tx, t.scale * y + t.ty,
                               t.scale * (x + width) + t.tx,
                               t.scale * (y + height) + t.ty};
}
// The device-pixel rectangle those edges cover. Rounding happens here, in
// layout coordinates, before anything is made relative to a parent: rounding a
// scaled local offset would move pixels at fractional zoom and across negative
// origins.
struct rediwm_snap {
  int x, y, width, height;
};
static inline struct rediwm_snap rediwm_edges_snap(struct rediwm_edges e) {
  const int x = lround(e.x1), y = lround(e.y1);
  return (struct rediwm_snap){x, y, (int)lround(e.x2) - x, (int)lround(e.y2) - y};
}

// Stage 4 of docs/plans/scene-graph.md: one rounded-rectangle shape clips every
// leaf of a tree (titlebar, client, subsurfaces). `rediwm_clip_spec` is what the
// compositor sets on the tree, in source units and anchored at the tree's origin;
// `rediwm_clip` is the same shape in layout space as resolve hands it on. A
// presenter snaps `edges` like any item's, so the shape and the quads that tile
// it agree on pixel columns, and evaluates the distance in device pixels.
struct rediwm_clip_spec {
  int width, height;
  // Top-left, top-right, bottom-right, bottom-left.
  double radii[4];
  double border;
  // Premultiplied, with the window's opacity already applied: the ring is
  // composited over the body, so a translucent border tints what is under it.
  float border_color[4];
  // A highlight on the frame's edge near a point: `glow_color` (premultiplied,
  // opacity applied) fades out with the distance from (glow_x, glow_y), in the
  // tree's own units, to `glow_radius`, and reaches `glow_depth` inward past the
  // ring. A radius of 0 draws none.
  double glow_x, glow_y, glow_radius, glow_depth;
  float glow_color[4];
};
struct rediwm_clip {
  struct rediwm_edges edges;
  double radii[4];
  double border;
  float border_color[4];
  // In layout space, like the edges.
  double glow_x, glow_y, glow_radius, glow_depth;
  float glow_color[4];
};
// Radii are capped at half the short side before scaling, as the CPU chrome
// does, so a small window never asks for an impossible arc.
static inline struct rediwm_clip rediwm_clip_resolve(struct rediwm_xform t, double x,
                                                     double y,
                                                     const struct rediwm_clip_spec *spec) {
  const double cap = 0.5 * (spec->width < spec->height ? spec->width : spec->height);
  struct rediwm_clip clip = {
      .edges = rediwm_xform_rect(t, x, y, spec->width, spec->height),
      .border = spec->border * t.scale};
  for (int i = 0; i < 4; i++)
    clip.radii[i] = (spec->radii[i] < cap ? spec->radii[i] : cap) * t.scale;
  for (int i = 0; i < 4; i++) clip.border_color[i] = spec->border_color[i];
  if (spec->glow_radius > 0) {
    clip.glow_x = clip.edges.x1 + spec->glow_x * t.scale;
    clip.glow_y = clip.edges.y1 + spec->glow_y * t.scale;
    clip.glow_radius = spec->glow_radius * t.scale;
    clip.glow_depth = spec->glow_depth * t.scale;
    for (int i = 0; i < 4; i++) clip.glow_color[i] = spec->glow_color[i];
  }
  return clip;
}
// Signed distance, negative inside, from (px, py) to the rounded rectangle
// (x, y, w, h). The radius is picked by quadrant: the stage 1 shader's formula,
// which `ui/sdf.zig` computes for one radius.
static inline double rediwm_sd_rounded_box(double px, double py, double x, double y,
                                           double w, double h, const double radii[4]) {
  const double qx = px - (x + w / 2), qy = py - (y + h / 2);
  const double r = qx < 0 ? (qy < 0 ? radii[0] : radii[3]) : (qy < 0 ? radii[1] : radii[2]);
  const double dx = fabs(qx) - (w / 2 - r), dy = fabs(qy) - (h / 2 - r);
  const double ox = dx > 0 ? dx : 0, oy = dy > 0 ? dy : 0;
  const double inner = dx > dy ? dx : dy;
  return sqrt(ox * ox + oy * oy) + (inner < 0 ? inner : 0) - r;
}
// Pixel coverage at signed distance `d` from an edge: a one-pixel ramp centred on it.
static inline double rediwm_coverage(double d) {
  return d >= .5 ? 0 : d <= -.5 ? 1 : .5 - d;
}
static inline double rediwm_clip_distance(const struct rediwm_clip *clip, double px,
                                          double py) {
  return rediwm_sd_rounded_box(px, py, clip->edges.x1, clip->edges.y1,
                               clip->edges.x2 - clip->edges.x1,
                               clip->edges.y2 - clip->edges.y1, clip->radii);
}
// A conservative cover of the pixels the shape fully covers, on the grid of the
// space the clip is in: its snapped rectangle minus a square at each corner two
// pixels deeper than the radius. The anti-aliased arc lies inside the radius
// square; the margin keeps it, and the outward rounding of a region converted to
// device pixels at any output scale of 1 or more, out of the claim. Culling and
// blend decisions may only trust what is returned. Up to three rectangles: a
// strip between the top corners, the full-width middle, a strip between the
// bottom corners. When the corners leave no room for a middle (a pill, or a
// small window with large radii) it is the one full-height column between the
// left and right corners instead. Returns how many, 0 when nothing is safe.
enum { REDIWM_CLIP_OPAQUE_MARGIN = 2 };
static inline int rediwm_clip_opaque(const struct rediwm_clip *clip,
                                     struct rediwm_snap out[3]) {
  const struct rediwm_snap f = rediwm_edges_snap(clip->edges);
  if (f.width <= 0 || f.height <= 0) return 0;
  int inset[4];
  for (int i = 0; i < 4; i++)
    inset[i] = clip->radii[i] > 0 ? (int)ceil(clip->radii[i]) + REDIWM_CLIP_OPAQUE_MARGIN : 0;
  const int top = inset[0] > inset[1] ? inset[0] : inset[1];
  const int bottom = inset[2] > inset[3] ? inset[2] : inset[3];
  if (top + bottom > f.height) {
    const int left = inset[0] > inset[3] ? inset[0] : inset[3];
    const int right = inset[1] > inset[2] ? inset[1] : inset[2];
    if (f.width - left - right <= 0) return 0;
    out[0] = (struct rediwm_snap){f.x + left, f.y, f.width - left - right, f.height};
    return 1;
  }
  int n = 0;
  if (top > 0 && f.width - inset[0] - inset[1] > 0)
    out[n++] = (struct rediwm_snap){f.x + inset[0], f.y, f.width - inset[0] - inset[1], top};
  if (f.height - top - bottom > 0)
    out[n++] = (struct rediwm_snap){f.x, f.y + top, f.width, f.height - top - bottom};
  if (bottom > 0 && f.width - inset[3] - inset[2] > 0)
    out[n++] = (struct rediwm_snap){f.x + inset[3], f.y + f.height - bottom,
                                    f.width - inset[3] - inset[2], bottom};
  return n;
}

// Stage 4d: the analytic drop shadow of a window's shape, set on the tree that
// holds the shadow's transport leaf. `width`, `height` and `radii` are the shape
// the shadow is kept out of (the window's, at the tree's origin, in source
// units); the shadow is that shape moved by the offset, at full strength inside
// it and falling to nothing `softness` units outside with the smoothstep of the
// CPU chrome (`chrome.shadowCoverage`). Colour premultiplied.
struct rediwm_shadow_spec {
  int width, height;
  double radii[4];
  double offset_x, offset_y, softness;
  float color[4];
};
struct rediwm_shadow {
  struct rediwm_clip shape; // in layout space; no border
  double offset_x, offset_y, softness;
  float color[4];
};
static inline struct rediwm_shadow rediwm_shadow_resolve(struct rediwm_xform t, double x,
                                                         double y,
                                                         const struct rediwm_shadow_spec *spec) {
  struct rediwm_clip_spec shape = {.width = spec->width, .height = spec->height};
  for (int i = 0; i < 4; i++) shape.radii[i] = spec->radii[i];
  struct rediwm_shadow shadow = {.shape = rediwm_clip_resolve(t, x, y, &shape),
                                 .offset_x = spec->offset_x * t.scale,
                                 .offset_y = spec->offset_y * t.scale,
                                 .softness = spec->softness * t.scale};
  for (int i = 0; i < 4; i++) shadow.color[i] = spec->color[i];
  return shadow;
}
static inline bool rediwm_shadow_equal(const struct rediwm_shadow *a,
                                       const struct rediwm_shadow *b) {
  if (a->shape.edges.x1 != b->shape.edges.x1 || a->shape.edges.y1 != b->shape.edges.y1 ||
      a->shape.edges.x2 != b->shape.edges.x2 || a->shape.edges.y2 != b->shape.edges.y2 ||
      a->offset_x != b->offset_x || a->offset_y != b->offset_y || a->softness != b->softness)
    return false;
  for (int i = 0; i < 4; i++)
    if (a->shape.radii[i] != b->shape.radii[i] || a->color[i] != b->color[i]) return false;
  return true;
}

enum rediwm_item_kind {
  REDIWM_ITEM_RECT,    // a solid colour
  REDIWM_ITEM_SURFACE, // the buffer of a client wl_surface
  REDIWM_ITEM_BUFFER,  // a compositor-owned raster: chrome, text, panels, shadows
  REDIWM_ITEM_EFFECT,  // a backdrop effect; its pixels belong to glass
  // The analytic shadow of `item.shadow`; the leaf transports input, opacity and
  // the footprint (its edges), never pixels.
  REDIWM_ITEM_SHADOW,
};
// What a leaf draws, apart from where. `color` is premultiplied.
struct rediwm_content {
  float opacity;
  // How much of the brightness and of the colour the window the leaf belongs to
  // has lost (a fraction, set on its tree: `rediwm_projection_set_tree_dim`). 0
  // draws the leaf as it is, so a zeroed content is the plain one.
  float dim_brightness, dim_saturation;
  float color[4];
  struct wlr_fbox src_box;
  enum wl_output_transform transform;
  enum wlr_scale_filter_mode filter_mode;
  enum wlr_color_transfer_function transfer_function;
  enum wlr_color_named_primaries primaries;
  enum wlr_color_encoding color_encoding;
  enum wlr_color_range color_range;
};
// Field by field: this is compiled by zig cc, where memcmp() == 0 lowers to
// compiler-rt's bytewise bcmp, which cost more than the work it skipped.
static inline bool rediwm_content_equal(const struct rediwm_content *a,
                                        const struct rediwm_content *b) {
  return a->opacity == b->opacity && a->dim_brightness == b->dim_brightness &&
         a->dim_saturation == b->dim_saturation && a->color[0] == b->color[0] &&
         a->color[1] == b->color[1] && a->color[2] == b->color[2] &&
         a->color[3] == b->color[3] && a->src_box.x == b->src_box.x &&
         a->src_box.y == b->src_box.y && a->src_box.width == b->src_box.width &&
         a->src_box.height == b->src_box.height && a->transform == b->transform &&
         a->filter_mode == b->filter_mode &&
         a->transfer_function == b->transfer_function &&
         a->primaries == b->primaries && a->color_encoding == b->color_encoding &&
         a->color_range == b->color_range;
}
// Content scaled by anything but 1:1 is always filtered bilinearly: a nearest
// filter chosen for pixel-exact content would shimmer under zoom.
static inline enum wlr_scale_filter_mode
rediwm_filter_at_scale(double scale, enum wlr_scale_filter_mode requested) {
  return scale == 1 ? requested : WLR_SCALE_FILTER_BILINEAR;
}

// One leaf of the resolved graph.
struct rediwm_item {
  enum rediwm_item_kind kind;
  // Stable for the leaf's life, never 0 for a projected leaf; 0 for the items of
  // nodes outside the projection. Damage events name leaves by it.
  uint64_t id;
  // Every node from the leaf to the root of its group is enabled. Whether the
  // item has any pixels once rounded is the presenter's to add.
  bool enabled;
  // Size in source units, before `scale`.
  int width, height;
  // The composed scale of the leaf's transform; also the blur and filter scale.
  double scale;
  struct rediwm_edges edges;
  struct rediwm_content content;
  // The shape clipping this item with the rest of its tree, or NULL. Owned by the
  // leaf the item belongs to: valid for the callback, until the next resolve.
  const struct rediwm_clip *clip;
  // Set exactly for REDIWM_ITEM_SHADOW, with the same lifetime as `clip`.
  const struct rediwm_shadow *shadow;
};
