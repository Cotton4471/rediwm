// How a layout-space region maps onto one output's buffer. Shared by the owned
// output pass and by damage that has no view node to carry it.
#pragma once
#include <math.h>
#include <stdbool.h>
#include <pixman.h>
#include <wayland-server-protocol.h>
#include <wlr/util/box.h>
#include <wlr/util/region.h>
#include <wlr/util/transform.h>

struct output_view {
    struct wlr_box logical;
    int width, height, trans_width, trans_height;
    float scale;
    enum wl_output_transform transform;
};
static inline void output_view_region(pixman_region32_t *region, const struct output_view *v, bool expand) {
    pixman_region32_translate(region, -v->logical.x, -v->logical.y);
    wlr_region_scale(region, region, v->scale);
    if (expand && floor(v->scale) != v->scale) wlr_region_expand(region, region, 1);
    wlr_region_transform(region, region, wlr_output_transform_invert(v->transform),
        v->trans_width, v->trans_height);
}
