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

enum rediwm_item_kind {
  REDIWM_ITEM_RECT,    // a solid colour
  REDIWM_ITEM_SURFACE, // the buffer of a client wl_surface
  REDIWM_ITEM_BUFFER,  // a compositor-owned raster: chrome, text, panels, shadows
  REDIWM_ITEM_EFFECT,  // a backdrop effect; its pixels belong to glass
};
// What a leaf draws, apart from where. `color` is premultiplied.
struct rediwm_content {
  float opacity;
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
  return a->opacity == b->opacity && a->color[0] == b->color[0] &&
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
  // Every node from the leaf to the root of its group is enabled. Whether the
  // item has any pixels once rounded is the presenter's to add.
  bool enabled;
  // Size in source units, before `scale`.
  int width, height;
  // The composed scale of the leaf's transform; also the blur and filter scale.
  double scale;
  struct rediwm_edges edges;
  struct rediwm_content content;
};
