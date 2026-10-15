// Owned output assembly, wlroots 0.20 ABI. Geometry is resolved by projection;
// scene nodes below are resource/feedback transports, never world geometry.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "scene_output.h"
#include "scene_view.h"
#include "scene_pass.h"
#include "scene_graph.h"
#include "projection.h"
#include "glass.h"
#include "node.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#ifdef REDIWM_DAMAGE_AUDIT
#include <drm_fourcc.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#endif
#include <wlr/render/drm_syncobj.h>
#include <wlr/render/swapchain.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_damage_ring.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/util/log.h>
#include <wlr/util/region.h>
#include <wlr/util/transform.h>

// Stage 5c: a glass effect's blur, kept per effect and output between frames
// (D1, D3 of docs/plans/scene-graph-stage5.md) and re-taken only when something
// below the effect changed in the region it reads.
struct effect_cache {
    struct wl_list link;
    uint64_t serial;               // rediwm_glass_info.serial
    struct rediwm_backdrop *backdrop;
    struct wlr_box region;         // device pixels the blur covers
    float sigma;                   // device pixels
    bool valid, seen;
    // A hold moved the blur without re-taking it: re-take it once released.
    bool carried;
};
struct output_state {
    struct wl_list link;
    struct rediwm_output_renderer *renderer;
    struct wlr_output *output;
    struct wl_listener destroy;
    uint64_t cursor;               // into the projection's damage events
    bool started;
    // Software cursors drawn last frame (device pixels), whose damage now is old.
    struct wlr_box cursors[4];
    int ncursors;
    struct wl_list caches;
    // rediwm_scene_output_set_veil: black over the frame (0 to 1), and whether it
    // changed since the last frame was built, so that change re-blurs no glass.
    float veil;
    bool veil_changed;
};
struct entry {
    struct rediwm_item item;
    struct wlr_scene_node *transport;
    struct wlr_box box; // snap of item edges in layout space
    pixman_region32_t visible, opaque;
    bool sampled;
    // Effects only: what glass registered, the box the blur reads (layout, the
    // target's grown by three sigma), the surface drawn over it, and whether
    // this frame takes a new blur.
    struct rediwm_glass_info glass;
    struct wlr_box padded;
    float sigma; // layout pixels
    struct wlr_scene_node *front;
    struct effect_cache *cache;
    bool reblur;
};
static bool render_entry(struct rediwm_output_renderer *r, struct entry *e, struct wlr_scene_output *out,
    struct wlr_render_pass *pass, const struct output_view *v, pixman_region32_t *damage, bool backdrop);
struct rediwm_output_renderer {
    struct rediwm_scene_renderer *pass;
    struct wl_array entries; // reusable scratch; no retained resource references
    struct wl_list outputs;  // output_state
    struct rediwm_projection *projection; // of the frame being built
    bool has_backdrops;
};
struct rediwm_output_renderer *rediwm_output_renderer_create(struct wlr_renderer *renderer) {
    struct rediwm_output_renderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->pass = rediwm_scene_renderer_create(renderer);
    if (!r->pass) { free(r); return NULL; }
    wl_array_init(&r->entries);
    wl_list_init(&r->outputs);
    return r;
}
bool rediwm_output_renderer_enable_shapes(struct rediwm_output_renderer *r) {
    return rediwm_scene_renderer_enable_shapes(r->pass);
}
bool rediwm_output_renderer_enable_backdrops(struct rediwm_output_renderer *r) {
    r->has_backdrops = rediwm_scene_renderer_enable_backdrops(r->pass);
    return r->has_backdrops;
}
static void cache_destroy(struct rediwm_output_renderer *r, struct effect_cache *c) {
    rediwm_scene_renderer_destroy_backdrop(r->pass, c->backdrop);
    wl_list_remove(&c->link);
    free(c);
}
static void output_state_destroy(struct output_state *os) {
    struct effect_cache *c, *next;
    wl_list_for_each_safe(c, next, &os->caches, link) cache_destroy(os->renderer, c);
    wl_list_remove(&os->destroy.link);
    wl_list_remove(&os->link);
    free(os);
}
static void output_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct output_state *os = wl_container_of(listener, os, destroy);
    output_state_destroy(os);
}
static struct output_state *output_state_find(struct rediwm_output_renderer *r, struct wlr_output *output) {
    struct output_state *os;
    wl_list_for_each(os, &r->outputs, link) if (os->output == output) return os;
    return NULL;
}
static struct output_state *output_state_get(struct rediwm_output_renderer *r, struct wlr_output *output) {
    struct output_state *os = output_state_find(r, output);
    if (os) return os;
    os = calloc(1, sizeof(*os));
    if (!os) return NULL;
    os->renderer = r;
    os->output = output;
    wl_list_init(&os->caches);
    os->destroy.notify = output_destroyed;
    wl_signal_add(&output->events.destroy, &os->destroy);
    wl_list_insert(&r->outputs, &os->link);
    return os;
}
void rediwm_output_renderer_destroy(struct rediwm_output_renderer *r) {
    if (!r) return;
    struct output_state *os, *next;
    wl_list_for_each_safe(os, next, &r->outputs, link) output_state_destroy(os);
    rediwm_scene_renderer_destroy(r->pass);
    wl_array_release(&r->entries);
    free(r);
}
struct wlr_render_pass *rediwm_output_begin_pass(struct rediwm_output_renderer *r,
        struct wlr_buffer *buffer, const struct wlr_buffer_pass_options *options) {
    return rediwm_scene_pass_begin(r->pass, buffer, options);
}
void rediwm_scene_output_damage_whole(struct wlr_scene_output *out) {
    wlr_damage_ring_add_whole(&out->damage_ring);
    pixman_region32_union_rect(&out->private.pending_commit_damage,
        &out->private.pending_commit_damage, 0, 0, out->output->width, out->output->height);
    wlr_output_schedule_frame(out->output);
}
bool rediwm_scene_output_set_veil(struct rediwm_output_renderer *r, struct wlr_scene_output *out, float alpha) {
    alpha = alpha < 0 ? 0 : alpha > 1 ? 1 : alpha;
    struct output_state *os = alpha > 0 ? output_state_get(r, out->output) : output_state_find(r, out->output);
    if (!os) return alpha == 0;
    if (os->veil == alpha) return true;
    os->veil = alpha;
    os->veil_changed = true;
    rediwm_scene_output_damage_whole(out);
    return true;
}
// Stage 3 parity deliberately retains the legacy layout snap, then snaps
// output-scaled edges. Removing that first snap is a geometry change, not a
// renderer switch. No view node position/size is consulted here.
static struct wlr_box device_box(struct wlr_box box, const struct output_view *v) {
    box.x -= v->logical.x;
    box.y -= v->logical.y;
    int x2 = round((box.x + box.width) * v->scale);
    int y2 = round((box.y + box.height) * v->scale);
    box.x = round(box.x * v->scale);
    box.y = round(box.y * v->scale);
    box.width = x2 - box.x;
    box.height = y2 - box.y;
    wlr_box_transform(&box, &box, wlr_output_transform_invert(v->transform),
        v->trans_width, v->trans_height);
    return box;
}
static void device_region(pixman_region32_t *region, const struct output_view *v, bool expand) {
    output_view_region(region, v, expand);
}
// Which device corner each logical corner (tl, tr, br, bl) lands on, found by
// moving a one-pixel box in each corner of a small frame through the same
// transform device_box applies, so the two cannot disagree.
static void device_radii(float out[4], const float in[4], enum wl_output_transform transform) {
    enum { W = 3, H = 5 };
    const struct wlr_box corners[4] = {{0, 0, 1, 1}, {W - 1, 0, 1, 1}, {W - 1, H - 1, 1, 1}, {0, H - 1, 1, 1}};
    const int w = (transform & 1) ? H : W, h = (transform & 1) ? W : H;
    for (int i = 0; i < 4; i++) {
        struct wlr_box b;
        wlr_box_transform(&b, &corners[i], wlr_output_transform_invert(transform), W, H);
        out[b.x < w / 2 ? (b.y < h / 2 ? 0 : 3) : (b.y < h / 2 ? 1 : 2)] = in[i];
    }
}
// The pass's shape for a clip: the clip's box snapped in layout space like any
// item's, then taken to device pixels by the same function as the pieces that
// tile it, so the shape and the quads agree on every pixel column. A ring is
// whole device pixels, never thinner than one.
static void shape_for(struct rediwm_pass_shape *s, const struct rediwm_clip *c, const struct output_view *v) {
    const struct rediwm_snap f = rediwm_edges_snap(c->edges);
    s->box = device_box((struct wlr_box){f.x, f.y, f.width, f.height}, v);
    float radii[4];
    for (int i = 0; i < 4; i++) radii[i] = (float)(c->radii[i] * v->scale);
    device_radii(s->radii, radii, v->transform);
    s->border = c->border > 0 ? fmaxf(1.f, roundf((float)(c->border * v->scale))) : 0.f;
    for (int i = 0; i < 4; i++) s->border_color[i] = c->border_color[i];
    s->glow_radius = s->glow_depth = 0;
    memset(s->glow_center, 0, sizeof(s->glow_center));
    memset(s->glow_color, 0, sizeof(s->glow_color));
    if (c->glow_radius > 0 && c->glow_color[3] > 0) {
        // The highlight's point goes through the same transform as the box, as a
        // one-pixel box (the loss is under a layout pixel, far inside its radius).
        const struct wlr_box at = device_box((struct wlr_box){(int)floor(c->glow_x), (int)floor(c->glow_y), 1, 1}, v);
        s->glow_center[0] = at.x + at.width * .5f - s->box.x;
        s->glow_center[1] = at.y + at.height * .5f - s->box.y;
        s->glow_radius = (float)(c->glow_radius * v->scale);
        s->glow_depth = (float)(c->glow_depth * v->scale);
        for (int i = 0; i < 4; i++) s->glow_color[i] = c->glow_color[i];
    }
}
// What of a clipped item may be drawn without the shape and without blending: the
// model's opaque cover, minus a margin around the edge where the ring is drawn.
// Layout space, like the item's own opaque region.
static void clip_cover(pixman_region32_t *out, const struct rediwm_clip *c, double scale) {
    pixman_region32_init(out);
    struct rediwm_snap parts[3];
    const int n = rediwm_clip_opaque(c, parts);
    for (int i = 0; i < n; i++)
        pixman_region32_union_rect(out, out, parts[i].x, parts[i].y, parts[i].width, parts[i].height);
    if (c->border > 0) {
        const struct rediwm_snap f = rediwm_edges_snap(c->edges);
        const int ring = (int)ceil(fmax(c->border, 1.0 / scale)) + 1;
        if (f.width > 2 * ring && f.height > 2 * ring)
            pixman_region32_intersect_rect(out, out, f.x + ring, f.y + ring, f.width - 2 * ring, f.height - 2 * ring);
        else
            pixman_region32_clear(out);
    }
}
struct collector {
    struct rediwm_output_renderer *renderer;
    const struct output_view *view;
    // The logical boxes of the other enabled outputs.
    struct wlr_box other[15];
    int others;
    pixman_region32_t covered;
    // A window's items are contiguous and share one clip, so its cover is built
    // once for the run rather than for each of its six or so items.
    struct rediwm_clip cover_of;
    pixman_region32_t cover;
    bool has_cover;
    // What the effects visited so far read (layout): items there are kept even
    // where surfaces above hide them, for the blurs only (stage 5f).
    pixman_region32_t reads;
};
static bool same_clip(const struct rediwm_clip *a, const struct rediwm_clip *b) {
    if (a->edges.x1 != b->edges.x1 || a->edges.y1 != b->edges.y1 || a->edges.x2 != b->edges.x2 ||
        a->edges.y2 != b->edges.y2 || a->border != b->border) return false;
    for (int i = 0; i < 4; i++) if (a->radii[i] != b->radii[i]) return false;
    return true;
}
static bool collect(const struct rediwm_item *item, struct wlr_scene_node *transport, void *data) {
    struct collector *collector = data;
    struct rediwm_output_renderer *r = collector->renderer;
    if (!item->enabled) { return true; }
    struct rediwm_snap s = rediwm_edges_snap(item->edges);
    if (s.width <= 0 || s.height <= 0) { return true; }
    struct wlr_box box = {s.x, s.y, s.width, s.height}, intersection;
    const bool here = wlr_box_intersection(&intersection, &box, &collector->view->logical);
    // An item on another output only is not drawn for this one, but it still hides
    // what is below it there, which the surface feedback below counts (stage 6).
    bool elsewhere = false;
    for (int i = 0; i < collector->others && !elsewhere; i++) {
        struct wlr_box other;
        elsewhere = wlr_box_intersection(&other, &box, &collector->other[i]);
    }
    if (!here && !elsewhere) { return true; }
    // Visit top-to-bottom so fully occluded items never enter the render list
    // and never allocate/copy content. The graph, not the view's visible region,
    // supplies the bounds and paint order.
    pixman_region32_t visible;
    pixman_region32_init_rect(&visible, box.x, box.y, box.width, box.height);
    pixman_region32_subtract(&visible, &visible, &collector->covered);
    // What a client surface shows of itself on every output is what it is told:
    // this counts for an item that draws nothing as well (opacity 0), as it does
    // for wlroots.
    if (item->kind == REDIWM_ITEM_SURFACE)
        rediwm_projection_feedback_note(r->projection, transport, &visible);
    if (item->kind != REDIWM_ITEM_EFFECT)
        rediwm_projection_note_visible(r->projection, transport, &visible);
    if (here)
        pixman_region32_intersect_rect(&visible, &visible, intersection.x, intersection.y,
            intersection.width, intersection.height);
    struct rediwm_glass_info glass = {0};
    bool skip = false;
    if (item->kind == REDIWM_ITEM_RECT) {
        skip = item->content.color[3] == 0;
    } else if (item->kind == REDIWM_ITEM_EFFECT) {
        // Glass is drawn here (stage 5c); without the blur program there is none,
        // and the surface's own tint shows, as glass.c's fallback did.
        skip = !here || !r->has_backdrops || item->content.opacity == 0 ||
            !rediwm_glass_effect_info(transport, &glass) || glass.opacity <= 0;
    } else if (item->kind == REDIWM_ITEM_SHADOW) {
        // No buffer: the pixels are the shadow's, and never opaque.
        skip = item->content.opacity == 0 || item->shadow->color[3] == 0;
    } else {
        struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(transport);
        skip = item->content.opacity == 0 ||
            (!b->buffer && !b->private.texture && !b->private.is_single_pixel_buffer);
    }
    if (skip) { pixman_region32_fini(&visible); return true; }
    if (here && !pixman_region32_not_empty(&visible) &&
        pixman_region32_contains_rectangle(&collector->reads, &(pixman_box32_t){intersection.x, intersection.y,
            intersection.x + intersection.width, intersection.y + intersection.height}) == PIXMAN_REGION_OUT) {
        pixman_region32_fini(&visible);
        return true;
    }
    struct entry *e = wl_array_add(&r->entries, sizeof(*e));
    if (!e) { pixman_region32_fini(&visible); return false; }
    *e = (struct entry){.item = *item, .transport = transport,
        .box = box, .visible = visible};
    pixman_region32_init(&e->opaque);
    if (item->kind == REDIWM_ITEM_EFFECT) {
        // The blur reads three sigma around the surface, below the effect in
        // paint order, including what opaque surfaces above hide on screen: items
        // there stay in the list for it (`reads`), not for the screen.
        e->glass = glass;
        e->sigma = glass.sigma * item->scale;
        const int pad = (int)ceil(3 * e->sigma);
        e->padded = (struct wlr_box){box.x - pad, box.y - pad, box.width + 2 * pad, box.height + 2 * pad};
        pixman_region32_union_rect(&collector->reads, &collector->reads,
            e->padded.x, e->padded.y, e->padded.width, e->padded.height);
        e->front = &glass.target->carrier->node;
        return true;
    }
    bool full = item->kind == REDIWM_ITEM_RECT && item->content.color[3] == 1;
    if (item->kind != REDIWM_ITEM_RECT && item->kind != REDIWM_ITEM_SHADOW) {
        struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(transport);
        // Match the surface adapter's opacity policy. A cached raster whose
        // buffer was released must not suddenly hide previously visible peers.
        if (b->buffer && item->content.opacity == 1) {
            full = b->private.buffer_is_opaque;
            if (!full) {
                rediwm_mirror_opaque(&e->opaque, &b->opaque_region, item->width, item->height, s.width, s.height);
                pixman_region32_translate(&e->opaque, s.x, s.y);
            }
        }
    }
    if (full) pixman_region32_union_rect(&e->opaque, &e->opaque, s.x, s.y, s.width, s.height);
    if (item->clip) {
        // The corners are transparent and the ring is drawn by the shape: only
        // the interior may hide what is below or skip blending.
        if (!collector->has_cover || !same_clip(&collector->cover_of, item->clip)) {
            if (collector->has_cover) pixman_region32_fini(&collector->cover);
            clip_cover(&collector->cover, item->clip, collector->view->scale);
            collector->cover_of = *item->clip;
            collector->has_cover = true;
        }
        pixman_region32_intersect(&e->opaque, &e->opaque, &collector->cover);
    }
    pixman_region32_union(&collector->covered, &collector->covered, &e->opaque);
    if (!here) {
        // Only what it hides, for the feedback of what is below.
        pixman_region32_fini(&e->visible);
        pixman_region32_fini(&e->opaque);
        r->entries.size -= sizeof(*e);
    }
    return true;
}
static void clear_entries(struct rediwm_output_renderer *r) {
    struct entry *e;
    wl_array_for_each(e, &r->entries) {
        pixman_region32_fini(&e->visible);
        pixman_region32_fini(&e->opaque);
    }
    r->entries.size = 0;
}
// The node's own texture cache, as wlr_scene keeps it. Buffer replacement and
// scene destruction already clear it in wlroots. Do not keep an extra buffer
// lock: shm clients must still update in place.
static void texture_renderer_destroy(struct wl_listener *listener, void *data) {
    (void)data;
    struct wlr_scene_buffer *b = wl_container_of(listener, b, private.renderer_destroy);
    wl_list_remove(&b->private.renderer_destroy.link);
    wl_list_init(&b->private.renderer_destroy.link);
    wlr_texture_destroy(b->private.texture);
    b->private.texture = NULL;
}
static struct wlr_texture *buffer_texture(struct wlr_scene_buffer *b, struct wlr_renderer *renderer) {
    if (!b->buffer || b->private.texture) return b->private.texture;
    struct wlr_client_buffer *client = wlr_client_buffer_get(b->buffer);
    if (client) return client->texture;
    struct wlr_texture *texture = wlr_texture_from_buffer(renderer, b->buffer);
    if (!texture) return NULL;
    if (b->private.own_buffer) {
        b->private.own_buffer = false;
        wlr_buffer_unlock(b->buffer);
    }
    b->private.texture = texture;
    wl_list_remove(&b->private.renderer_destroy.link);
    b->private.renderer_destroy.notify = texture_renderer_destroy;
    wl_signal_add(&renderer->events.destroy, &b->private.renderer_destroy);
    return texture;
}
static void sample(struct entry *e, struct wlr_scene_output *out, bool scanout) {
    if (e->item.kind == REDIWM_ITEM_RECT) return;
    struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(e->transport);
    struct wlr_scene_output_sample_event event = {
        .output = out, .direct_scanout = scanout,
        .release_timeline = scanout ? out->private.out_timeline : out->private.in_timeline,
        .release_point = scanout ? out->private.out_point : out->private.in_point,
    };
    wl_signal_emit_mutable(&b->events.output_sample, &event);
}
static bool try_scanout(struct entry *e, struct wlr_scene_output *out,
        struct wlr_output_state *state, const struct output_view *v) {
    if (e->item.clip || e->item.kind != REDIWM_ITEM_SURFACE || !out->scene->private.direct_scanout ||
        (state->committed & (WLR_OUTPUT_STATE_MODE | WLR_OUTPUT_STATE_ENABLED | WLR_OUTPUT_STATE_RENDER_FORMAT)) ||
        !wlr_output_is_direct_scanout_allowed(out->output)) return false;
    struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(e->transport);
    const struct rediwm_content *c = &e->item.content;
    // Scanout shows the client's buffer as it is: a dimmed window needs the pass.
    if (!b->buffer || c->transform != v->transform || c->opacity != 1 ||
        c->dim_brightness > 0 || c->dim_saturation > 0) return false;
    const struct wlr_output_image_description *desc = state->committed & WLR_OUTPUT_STATE_IMAGE_DESCRIPTION ?
        state->image_description : out->output->image_description;
    if (desc) {
        if (c->transfer_function != desc->transfer_function || c->primaries != desc->primaries) return false;
    } else if (!((c->transfer_function == 0 && c->primaries == 0) ||
        (c->transfer_function == WLR_COLOR_TRANSFER_FUNCTION_GAMMA22 &&
         c->primaries == WLR_COLOR_NAMED_PRIMARIES_SRGB))) return false;
    if (!((c->color_encoding == WLR_COLOR_ENCODING_NONE && c->color_range == WLR_COLOR_RANGE_NONE) ||
        (c->color_encoding == WLR_COLOR_ENCODING_IDENTITY && c->color_range == WLR_COLOR_RANGE_FULL))) return false;
    struct wlr_box dst = device_box(e->box, v);
    // Keep the guaranteed fullscreen case. Partial coverage never bypasses
    // the black/background draw, even if it was the only visible entry.
    if (dst.x != 0 || dst.y != 0 || dst.width != v->width || dst.height != v->height) return false;
    if (pixman_region32_contains_rectangle(&e->opaque, &(pixman_box32_t){
        v->logical.x, v->logical.y, v->logical.x + v->logical.width,
        v->logical.y + v->logical.height}) != PIXMAN_REGION_IN) return false;
    struct wlr_output_state pending;
    wlr_output_state_init(&pending);
    if (!wlr_output_state_copy(&pending, state)) { wlr_output_state_finish(&pending); return false; }
    struct wlr_buffer *buffer = b->buffer;
    struct wlr_client_buffer *client = wlr_client_buffer_get(buffer);
    if (client && client->source && client->source->n_locks > 0) buffer = client->source;
    wlr_output_state_set_buffer(&pending, buffer);
    pending.buffer_src_box = c->src_box;
    pending.buffer_dst_box = dst;
    if (b->private.wait_timeline)
        wlr_output_state_set_wait_timeline(&pending, b->private.wait_timeline, b->private.wait_point);
    if (out->private.out_timeline)
        wlr_output_state_set_signal_timeline(&pending, out->private.out_timeline, ++out->private.out_point);
    bool ok = wlr_output_test_state(out->output, &pending) && wlr_output_state_copy(state, &pending);
    wlr_output_state_finish(&pending);
    if (ok) sample(e, out, true);
    return ok;
}
// Most entries lie outside a small repaint, and the region arithmetic below
// (scale, expand, transform) is what costs at fractional scale. Reject from the
// device box first. A clip is a subregion of the entry's box rounded outward by
// wlr_region_scale and then expanded by one pixel, so two pixels of margin
// around the rounded box can never reject an entry that would have drawn.
static bool misses_damage(const struct wlr_box *dst, pixman_region32_t *damage) {
    const pixman_box32_t *extents = pixman_region32_extents(damage);
    return dst->x - 2 >= extents->x2 || dst->x + dst->width + 2 <= extents->x1 ||
        dst->y - 2 >= extents->y2 || dst->y + dst->height + 2 <= extents->y1;
}
// ---- Effects: which blurs this frame re-takes (D1) ---------------------------------
uint64_t rediwm_scene_output_reblurs; // read and reset by the performance stats
struct attribution {
    const struct output_view *view;
    struct entry *entries;
    size_t len;
    struct wl_array events;          // struct seen_event
    pixman_region32_t explained;     // device pixels events account for
};
struct seen_event { uint64_t leaf; struct wlr_box box; }; // device pixels
static void note_event(const struct rediwm_damage_event *ev, void *data) {
    struct attribution *a = data;
    struct wlr_box box = device_box((struct wlr_box){ev->box.x, ev->box.y, ev->box.width, ev->box.height}, a->view);
    // wlroots widens a scaled buffer's damage for filtering; so does this.
    box = (struct wlr_box){box.x - 2, box.y - 2, box.width + 4, box.height + 4};
    struct seen_event *se = wl_array_add(&a->events, sizeof(*se));
    if (se) *se = (struct seen_event){ev->leaf, box};
    pixman_region32_union_rect(&a->explained, &a->explained, box.x, box.y, box.width, box.height);
}
// Paint position of a leaf in this frame (0 = top), or -1 when it is not drawn.
static long position_of(const struct attribution *a, uint64_t leaf) {
    if (!leaf) return -1;
    for (size_t i = 0; i < a->len; i++) if (a->entries[i].item.id == leaf) return (long)i;
    return -1;
}
static bool boxes_meet(const struct wlr_box *a, const struct wlr_box *b) {
    struct wlr_box out;
    return wlr_box_intersection(&out, a, b);
}
static struct effect_cache *cache_for(struct output_state *os, uint64_t serial) {
    struct effect_cache *c;
    wl_list_for_each(c, &os->caches, link) if (c->serial == serial) return c;
    c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->serial = serial;
    wl_list_insert(&os->caches, &c->link);
    return c;
}
// Decides, bottom to top, which effects re-blur: a blur is kept unless something
// painted below the effect, or something no event explains, changed in the region
// it reads, or the region or sigma changed (a held effect keeps it while moving).
// A re-blur changes the effect's own pixels (`changed`). Returns false on
// allocation failure.
static bool decide_effects(struct rediwm_output_renderer *r, struct output_state *os,
        struct wlr_scene_output *out, const struct output_view *v, pixman_region32_t *changed) {
    struct entry *entries = r->entries.data;
    const size_t len = r->entries.size / sizeof(*entries);
    struct attribution a = {.view = v, .entries = entries, .len = len};
    wl_array_init(&a.events);
    pixman_region32_init(&a.explained);
    bool complete = os->started && rediwm_projection_damage_events(r->projection, &os->cursor, note_event, &a);
    if (!os->started) {
        os->cursor = rediwm_projection_damage_cursor(r->projection);
        os->started = true;
    }
    // A software cursor is drawn over everything, so its damage (where it was and
    // where it is) never changes what a blur reads.
    struct wlr_output_cursor *cursor;
    int ncursors = 0;
    struct wlr_box cursors[4];
    wl_list_for_each(cursor, &out->output->cursors, link) {
        if (ncursors == 4 || !cursor->enabled || !cursor->visible || cursor == out->output->hardware_cursor) continue;
        cursors[ncursors++] = (struct wlr_box){(int)floor(cursor->x) - cursor->hotspot_x - 4,
            (int)floor(cursor->y) - cursor->hotspot_y - 4, (int)cursor->width + 8, (int)cursor->height + 8};
    }
    for (int i = 0; i < os->ncursors; i++)
        pixman_region32_union_rect(&a.explained, &a.explained, os->cursors[i].x, os->cursors[i].y,
            os->cursors[i].width, os->cursors[i].height);
    for (int i = 0; i < ncursors; i++) {
        pixman_region32_union_rect(&a.explained, &a.explained, cursors[i].x, cursors[i].y,
            cursors[i].width, cursors[i].height);
        os->cursors[i] = cursors[i];
    }
    os->ncursors = ncursors;
    // The veil is drawn over every effect, so repainting the output for it changes
    // nothing a blur reads. While it changes, damage no event explains goes
    // unnoticed too; a resize or failed frame still re-blurs on its own.
    if (os->veil_changed)
        pixman_region32_union_rect(&a.explained, &a.explained, 0, 0, v->width, v->height);
    pixman_region32_t unexplained;
    pixman_region32_init(&unexplained);
    pixman_region32_subtract(&unexplained, &out->private.pending_commit_damage, &a.explained);
    struct effect_cache *c;
    wl_list_for_each(c, &os->caches, link) c->seen = false;
    bool ok = true;
    for (size_t i = len; i > 0; i--) {
        struct entry *e = &entries[i - 1];
        if (e->item.kind != REDIWM_ITEM_EFFECT) continue;
        e->cache = cache_for(os, e->glass.serial);
        if (!e->cache) { ok = false; continue; }
        c = e->cache;
        c->seen = true;
        const struct wlr_box region = device_box(e->padded, v);
        const float sigma = e->sigma * v->scale;
        const bool same_size = c->valid && c->sigma == sigma && c->region.width == region.width &&
            c->region.height == region.height;
        bool reblur = !same_size || !complete || (c->carried && !e->glass.held);
        if (!reblur && (c->region.x != region.x || c->region.y != region.y)) {
            // A held effect carries its last blur along; otherwise a move re-blurs.
            if (e->glass.held) {
                c->region = region;
                c->carried = true;
            } else {
                reblur = true;
            }
        }
        if (!reblur && !e->glass.held) {
            const long here = (long)(i - 1);
            struct seen_event *se;
            wl_array_for_each(se, &a.events) {
                if (!boxes_meet(&se->box, &region)) continue;
                const long at = position_of(&a, se->leaf);
                if (at < 0 || at > here) { reblur = true; break; }
            }
            if (!reblur && pixman_region32_contains_rectangle(&unexplained,
                    &(pixman_box32_t){region.x, region.y, region.x + region.width, region.y + region.height}) != PIXMAN_REGION_OUT)
                reblur = true;
            // An effect below that re-blurs changes what this one reads.
            for (size_t j = len; !reblur && j > i; j--) {
                const struct entry *below = &entries[j - 1];
                if (below->item.kind == REDIWM_ITEM_EFFECT && below->reblur) {
                    const struct wlr_box bb = device_box(below->box, v);
                    if (boxes_meet(&bb, &region)) reblur = true;
                }
            }
        }
        e->reblur = reblur;
        if (reblur) {
            const struct wlr_box own = device_box(e->box, v);
            pixman_region32_union_rect(changed, changed, own.x, own.y, own.width, own.height);
        }
    }
    pixman_region32_fini(&unexplained);
    pixman_region32_fini(&a.explained);
    wl_array_release(&a.events);
    return ok;
}
static void render_effect(struct entry *e, struct wlr_render_pass *pass, const struct output_view *v,
        struct rediwm_output_renderer *r, struct wlr_scene_output *out, const pixman_region32_t *clip,
        bool backdrop) {
    struct effect_cache *c = e->cache;
    if (!c) return;
    struct wlr_renderer *renderer = out->output->renderer;
    if (e->reblur && !backdrop && !pixman_region32_not_empty((pixman_region32_t *)clip)) {
        // Hidden here (kept only for another effect's blur): re-take it when shown.
        c->valid = false;
        return;
    }
    if (e->reblur && !backdrop) {
        // Draw what lies below the effect, bottom up, into a quarter-size image of
        // the region the blur reads, and blur that (stage 5f): no full-size copy.
        c->region = device_box(e->padded, v);
        c->sigma = e->sigma * v->scale;
        // A quarter of the logical size, as glass.c blurred: the same pixels at any
        // scale (a quarter of the device size cost 2.25 times more at 1.5).
        rediwm_scene_pass_begin_backdrop(pass, c->region, 4 * (float)v->scale);
        struct entry *entries = r->entries.data;
        const size_t len = r->entries.size / sizeof(*entries);
        const size_t here = (size_t)(e - entries);
        // Cull within the blur's region as the screen is culled: walking down from
        // the effect, an item that opaque items below the effect hide entirely is
        // not drawn (a fullscreen client under the taskbar hides everything else).
        pixman_region32_t region, hidden;
        pixman_region32_init_rect(&region, c->region.x, c->region.y, c->region.width, c->region.height);
        pixman_region32_init(&hidden);
        bool draw[len];
        for (size_t j = here + 1; j < len; j++) {
            struct entry *below = &entries[j];
            const struct wlr_box b = device_box(below->box, v);
            draw[j] = pixman_region32_contains_rectangle(&region, &(pixman_box32_t){b.x, b.y, b.x + b.width,
                b.y + b.height}) != PIXMAN_REGION_OUT &&
                pixman_region32_contains_rectangle(&hidden, &(pixman_box32_t){b.x, b.y, b.x + b.width,
                b.y + b.height}) != PIXMAN_REGION_IN;
            if (draw[j] && pixman_region32_not_empty(&below->opaque)) {
                pixman_region32_t opaque;
                pixman_region32_init(&opaque);
                pixman_region32_copy(&opaque, &below->opaque);
                device_region(&opaque, v, false);
                pixman_region32_union(&hidden, &hidden, &opaque);
                pixman_region32_fini(&opaque);
            }
        }
        for (size_t j = len; j > here + 1; j--)
            if (draw[j - 1]) render_entry(r, &entries[j - 1], out, pass, v, &region, true);
        pixman_region32_fini(&hidden);
        pixman_region32_fini(&region);
        rediwm_scene_pass_end_backdrop(pass, &c->backdrop, c->sigma);
        c->valid = true;
        c->carried = false;
        rediwm_scene_output_reblurs++;
    }
    if (!c->valid || !c->backdrop || !pixman_region32_not_empty((pixman_region32_t *)clip)) return;
    const struct wlr_box dst = device_box(e->box, v);
    struct rediwm_pass_shape shape = {.box = dst};
    if (e->item.clip) {
        shape_for(&shape, e->item.clip, v);
    } else {
        const float radius = e->glass.radius * e->item.scale * v->scale;
        for (int i = 0; i < 4; i++) shape.radii[i] = radius;
    }
    shape.border = 0;
    struct rediwm_pass_backdrop o = {.backdrop = c->backdrop, .saturation = e->glass.saturation,
        .opacity = e->glass.opacity * e->item.content.opacity, .clip = clip};
    // The surface over the effect: its alpha is made up to the coverage.
    struct entry *entries = r->entries.data;
    const size_t len = r->entries.size / sizeof(*entries);
    for (size_t i = 0; i < len; i++) {
        struct entry *f = &entries[i];
        if (f->transport != e->front || f->item.kind == REDIWM_ITEM_RECT) continue;
        struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(f->transport);
        if (b->private.is_single_pixel_buffer || b->transform != WL_OUTPUT_TRANSFORM_NORMAL) break;
        o.front = buffer_texture(b, renderer);
        o.front_box = device_box(f->box, v);
        o.front_opacity = f->item.content.opacity;
        break;
    }
    // The effect shows what is behind its window: it is dimmed with the window.
    const struct rediwm_content *content = &e->item.content;
    const bool graded = content->dim_brightness > 0 || content->dim_saturation > 0;
    if (graded) rediwm_scene_pass_set_dim(pass, content->dim_brightness, content->dim_saturation);
    rediwm_scene_pass_add_backdrop(pass, &shape, dst, &o);
    if (graded) rediwm_scene_pass_set_dim(pass, 0, 0);
}
// `backdrop`: drawing into an effect's quarter-size image (stage 5f), where an
// item counts with its whole box, not what is visible of it on screen, and
// `damage` is the region the blur reads.
static bool render_entry(struct rediwm_output_renderer *r, struct entry *e, struct wlr_scene_output *out,
        struct wlr_render_pass *pass, const struct output_view *v, pixman_region32_t *damage, bool backdrop) {
    struct wlr_box dst = device_box(e->box, v);
    if (misses_damage(&dst, damage)) return true;
    pixman_region32_t clip, blend, core;
    pixman_region32_init(&clip);
    pixman_region32_init(&blend);
    pixman_region32_init(&core);
    bool graded = false;
    if (backdrop) pixman_region32_init_rect(&clip, dst.x, dst.y, dst.width, dst.height);
    else {
        pixman_region32_copy(&clip, &e->visible);
        device_region(&clip, v, true);
    }
    pixman_region32_intersect(&clip, &clip, damage);
    bool ok = true;
    if (e->item.kind == REDIWM_ITEM_EFFECT) {
        // A re-blur takes its blur even where the effect itself is hidden.
        render_effect(e, pass, v, r, out, &clip, backdrop);
        goto done;
    }
    if (!pixman_region32_not_empty(&clip)) goto done;
    // A clipped item is drawn in two parts: `core` (its interior, which the model
    // proves fully covered and opaque) as before, without the shape, and the rest
    // (corners, ring, anything translucent) through the shape.
    struct rediwm_pass_shape shape;
    const bool shaped = e->item.clip != NULL;
    if (shaped) {
        shape_for(&shape, e->item.clip, v);
        pixman_region32_copy(&core, &e->opaque);
        device_region(&core, v, false);
        // One rectangle, deeper than the corner arcs and the ring. The model's cover
        // is a cross of up to three, which leaves about twelve scissored draws per
        // window for what a rim of a few shaded pixels costs far less than: draws
        // dominated the output build in a drag.
        float depth = fmaxf(fmaxf(shape.radii[0], shape.radii[1]), fmaxf(shape.radii[2], shape.radii[3]));
        const int inset = (int)ceilf(fmaxf(depth, shape.border + shape.glow_depth)) + REDIWM_CLIP_OPAQUE_MARGIN;
        if (shape.box.width > 2 * inset && shape.box.height > 2 * inset)
            pixman_region32_intersect_rect(&core, &core, shape.box.x + inset, shape.box.y + inset,
                shape.box.width - 2 * inset, shape.box.height - 2 * inset);
        else
            pixman_region32_clear(&core);
        pixman_region32_intersect(&core, &core, &clip);
        pixman_region32_subtract(&clip, &clip, &core);
    }
    const struct rediwm_content *c = &e->item.content;
    // A window that is not the focus is drawn dimmed, whole: the pass grades each
    // draw (the interior, the rim and the ring alike) until it is reset below.
    graded = c->dim_brightness > 0 || c->dim_saturation > 0;
    if (graded) rediwm_scene_pass_set_dim(pass, c->dim_brightness, c->dim_saturation);
    if (e->item.kind == REDIWM_ITEM_SHADOW) {
        // The offset is taken to device pixels as the difference of two snapped
        // boxes, so an output transform turns it with them.
        const struct rediwm_shadow *sh = e->item.shadow;
        struct rediwm_clip moved = sh->shape;
        moved.edges.x1 += sh->offset_x;
        moved.edges.x2 += sh->offset_x;
        moved.edges.y1 += sh->offset_y;
        moved.edges.y2 += sh->offset_y;
        struct rediwm_pass_shape at;
        shape_for(&shape, &sh->shape, v);
        shape_for(&at, &moved, v);
        struct rediwm_pass_shadow shadow = {
            .offset_x = (float)(at.box.x - shape.box.x), .offset_y = (float)(at.box.y - shape.box.y),
            .softness = (float)(sh->softness * v->scale), .hide_inside = true, .clip = &clip};
        for (int i = 0; i < 4; i++) shadow.color[i] = sh->color[i] * c->opacity;
        rediwm_scene_pass_add_shadow(pass, &shape, &shadow);
    } else if (e->item.kind == REDIWM_ITEM_RECT) {
        struct wlr_render_rect_options rect = {.box = dst,
            .color = {c->color[0], c->color[1], c->color[2], c->color[3]}};
        if (pixman_region32_not_empty(&core)) {
            rect.clip = &core;
            wlr_render_pass_add_rect(pass, &rect);
        }
        rect.clip = &clip;
        if (!shaped) wlr_render_pass_add_rect(pass, &rect);
        else if (pixman_region32_not_empty(&clip)) rediwm_scene_pass_add_rect_shaped(pass, &rect, &shape);
    } else {
        struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(e->transport);
        if (b->private.is_single_pixel_buffer) {
            const uint32_t *color = b->private.single_pixel_buffer_color;
            // Match wlroots' single-pixel path during parity, including its
            // treatment of opacity (only alpha is multiplied there).
            struct wlr_render_rect_options rect = {.box = dst,
                .color = {(float)color[0] / (float)UINT32_MAX, (float)color[1] / (float)UINT32_MAX,
                    (float)color[2] / (float)UINT32_MAX, (float)color[3] / (float)UINT32_MAX * c->opacity}};
            if (pixman_region32_not_empty(&core)) {
                rect.clip = &core;
                wlr_render_pass_add_rect(pass, &rect);
            }
            rect.clip = &clip;
            if (!shaped) wlr_render_pass_add_rect(pass, &rect);
            else if (pixman_region32_not_empty(&clip)) rediwm_scene_pass_add_rect_shaped(pass, &rect, &shape);
        } else {
            struct wlr_texture *texture = buffer_texture(b, out->output->renderer);
            if (!texture) { ok = false; goto done; }
            struct wlr_render_texture_options t = {
                .texture = texture, .dst_box = dst, .src_box = c->src_box,
                .transform = wlr_output_transform_compose(wlr_output_transform_invert(c->transform), v->transform),
                .alpha = &c->opacity, .filter_mode = c->filter_mode,
                .wait_timeline = b->private.wait_timeline, .wait_point = b->private.wait_point,
            };
            if (pixman_region32_not_empty(&core)) {
                t.clip = &core;
                t.blend_mode = WLR_RENDER_BLEND_MODE_NONE;
                wlr_render_pass_add_texture(pass, &t);
            }
            t.clip = &clip;
            if (shaped) {
                t.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED;
                if (pixman_region32_not_empty(&clip)) rediwm_scene_pass_add_texture_shaped(pass, &t, &shape);
            } else {
                pixman_region32_copy(&blend, &e->opaque);
                device_region(&blend, v, false);
                pixman_region32_subtract(&blend, &clip, &blend);
                t.blend_mode = pixman_region32_not_empty(&blend) ? WLR_RENDER_BLEND_MODE_PREMULTIPLIED : WLR_RENDER_BLEND_MODE_NONE;
                wlr_render_pass_add_texture(pass, &t);
            }
        }
        e->sampled = true;
    }
done:
    // What is drawn next (the next item, the software cursor) is not this item's.
    if (graded) rediwm_scene_pass_set_dim(pass, 0, 0);
    pixman_region32_fini(&clip);
    pixman_region32_fini(&blend);
    pixman_region32_fini(&core);
    return ok;
}
#ifdef REDIWM_DAMAGE_AUDIT
// Debug audit of the damage (`zig build -Ddamage-audit=true`, TESTING.md): after a
// frame is drawn into the swapchain buffer with only the damage it was given, the
// same entries are drawn whole into a private buffer and the two are compared. A
// difference is a region the damage should have covered; it is logged with the
// entries over it. Reads two frames back every time: slow, and off by default.
static struct { struct wlr_output *output; struct wlr_buffer *buffer; } audit_slots[8];
static bool audit_read(struct wlr_renderer *renderer, struct wlr_buffer *buffer, uint8_t *pixels) {
    struct wlr_texture *texture = wlr_texture_from_buffer(renderer, buffer);
    if (!texture) return false;
    bool ok = wlr_texture_read_pixels(texture, &(struct wlr_texture_read_pixels_options){
        .data = pixels, .format = DRM_FORMAT_ARGB8888, .stride = (uint32_t)buffer->width * 4});
    wlr_texture_destroy(texture);
    return ok;
}
static void audit_damage(struct rediwm_output_renderer *r, struct wlr_scene_output *out,
        struct wlr_buffer *real, struct entry *entries, size_t len, const struct output_view *v,
        const pixman_region32_t *damage, float veil) {
    struct wlr_output *output = out->output;
    int slot = -1;
    for (int i = 0; i < 8; i++) {
        if (audit_slots[i].output == output) { slot = i; break; }
        if (slot < 0 && !audit_slots[i].output) slot = i;
    }
    if (slot < 0) return;
    if (audit_slots[slot].output != output || (audit_slots[slot].buffer &&
            (audit_slots[slot].buffer->width != real->width || audit_slots[slot].buffer->height != real->height))) {
        if (audit_slots[slot].buffer) wlr_buffer_drop(audit_slots[slot].buffer);
        audit_slots[slot].buffer = NULL;
        audit_slots[slot].output = output;
    }
    if (!audit_slots[slot].buffer)
        audit_slots[slot].buffer = wlr_allocator_create_buffer(output->allocator, real->width, real->height,
            &output->swapchain->format);
    struct wlr_buffer *copy = audit_slots[slot].buffer;
    if (!copy) return;
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r->pass, copy, &(struct wlr_buffer_pass_options){0});
    if (!pass) return;
    pixman_region32_t whole;
    pixman_region32_init_rect(&whole, 0, 0, real->width, real->height);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, real->width, real->height}, .color = {0, 0, 0, 1}, .clip = &whole});
    // Blurs are kept as the real pass left them: this audits damage, not glass.
    for (size_t i = 0; i < len; i++) entries[i].reblur = false;
    for (size_t i = len; i > 0; i--) render_entry(r, &entries[i - 1], out, pass, v, &whole, false);
    if (veil > 0) wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, real->width, real->height}, .color = {0, 0, 0, veil}, .clip = &whole});
    wlr_output_add_software_cursors_to_render_pass(output, pass, &whole);
    bool submitted = wlr_render_pass_submit(pass);
    pixman_region32_fini(&whole);
    if (!submitted) return;
    const size_t bytes = (size_t)real->width * real->height * 4;
    uint8_t *a = malloc(bytes), *b = malloc(bytes);
    if (a && b && audit_read(output->renderer, real, a) && audit_read(output->renderer, copy, b)) {
        // GLES2 at a fractional scale can differ by a level or two with render history.
        const int tolerance = floor(v->scale) != v->scale ? 3 : 1;
        long differing = 0, inside = 0;
        int x1 = real->width, y1 = real->height, x2 = 0, y2 = 0, worst = 0;
        for (int y = 0; y < real->height; y++) {
            for (int x = 0; x < real->width; x++) {
                const size_t o = ((size_t)y * real->width + x) * 4;
                int d = 0;
                for (int c = 0; c < 4; c++) { int e = abs((int)a[o + c] - (int)b[o + c]); if (e > d) d = e; }
                if (d <= tolerance) continue;
                differing++;
                if (pixman_region32_contains_point((pixman_region32_t *)damage, x, y, NULL)) inside++;
                if (d > worst) worst = d;
                if (x < x1) x1 = x;
                if (y < y1) y1 = y;
                if (x + 1 > x2) x2 = x + 1;
                if (y + 1 > y2) y2 = y + 1;
            }
        }
        if (differing) {
            const pixman_box32_t *ex = pixman_region32_extents((pixman_region32_t *)damage);
            wlr_log(WLR_ERROR, "damage audit %s: %ld pixels differ (worst %d, %ld inside the damage) in %d,%d-%d,%d; "
                "damage %d,%d-%d,%d", output->name, differing, worst, inside, x1, y1, x2, y2,
                ex->x1, ex->y1, ex->x2, ex->y2);
            const struct wlr_box mine = {x1, y1, x2 - x1, y2 - y1};
            for (size_t i = 0; i < len; i++) {
                struct wlr_box hit;
                if (!wlr_box_intersection(&hit, &entries[i].box, &mine)) continue;
                wlr_log(WLR_ERROR, "damage audit:   entry %zu id %llu kind %d opacity %.3f box %d,%d %dx%d clip %d", i,
                    (unsigned long long)entries[i].item.id, (int)entries[i].item.kind,
                    entries[i].item.content.opacity, entries[i].box.x, entries[i].box.y, entries[i].box.width,
                    entries[i].box.height, entries[i].item.clip != NULL);
            }
        }
    }
    free(a);
    free(b);
}
#endif
bool rediwm_scene_output_build_state(struct rediwm_output_renderer *r,
        struct rediwm_projection *projection, struct wlr_scene_output *out, struct wlr_output_state *state) {
    if ((state->committed & WLR_OUTPUT_STATE_ENABLED) && !state->enabled) return true;
    struct wlr_output *output = out->output;
    // These scene services are not installed by RediWM. KMS colour state is
    // applied later by Output.commitFrameState, for either presenter.
    if (out->scene->gamma_control_manager_v1 || out->private.combined_color_transform) return false;
    struct output_view v = {.width = output->width, .height = output->height,
        .scale = state->committed & WLR_OUTPUT_STATE_SCALE ? state->scale : output->scale,
        .transform = state->committed & WLR_OUTPUT_STATE_TRANSFORM ? state->transform : output->transform,
        .logical = {.x = out->x, .y = out->y}};
    if (state->committed & WLR_OUTPUT_STATE_MODE) {
        v.width = state->mode_type == WLR_OUTPUT_STATE_MODE_FIXED ? state->mode->width : state->custom_mode.width;
        v.height = state->mode_type == WLR_OUTPUT_STATE_MODE_FIXED ? state->mode->height : state->custom_mode.height;
    }
    v.trans_width = v.width;
    v.trans_height = v.height;
    wlr_output_transform_coords(v.transform, &v.trans_width, &v.trans_height);
    v.logical.width = v.trans_width / v.scale;
    v.logical.height = v.trans_height / v.scale;
    if (v.scale != output->scale || v.transform != output->transform ||
        v.width != output->width || v.height != output->height)
        rediwm_scene_output_damage_whole(out);
    r->projection = projection;
    rediwm_projection_feedback_begin(projection);
    struct collector collector = {.renderer = r, .view = &v};
    struct wlr_scene_output *other;
    wl_list_for_each(other, &out->scene->outputs, link) {
        if (other == out || !other->output->enabled || collector.others == 15) continue;
        struct wlr_box *box = &collector.other[collector.others++];
        *box = (struct wlr_box){.x = other->x, .y = other->y};
        wlr_output_effective_resolution(other->output, &box->width, &box->height);
    }
    pixman_region32_init(&collector.covered);
    pixman_region32_init(&collector.reads);
    bool collected = rediwm_projection_for_each_item(projection, true, collect, &collector);
    if (collector.has_cover) pixman_region32_fini(&collector.cover);
    pixman_region32_fini(&collector.reads);
    if (!collected) {
        pixman_region32_fini(&collector.covered);
        clear_entries(r);
        return false;
    }
    rediwm_projection_feedback_end(projection);
    struct entry *entries = r->entries.data;
    size_t len = r->entries.size / sizeof(*entries);
    // Effects decide before the damage is handed on: a re-blur changes the
    // effect's pixels (reported and kept in the ring for the other buffers) and
    // repaints the whole region it reads (this buffer only).
    pixman_region32_t changed;
    pixman_region32_init(&changed);
    struct output_state *os = r->has_backdrops ? output_state_get(r, output) : NULL;
    struct output_state *veiled = output_state_find(r, output);
    const float veil = veiled ? veiled->veil : 0;
    if (os && !decide_effects(r, os, out, &v, &changed)) {
        pixman_region32_fini(&changed);
        pixman_region32_fini(&collector.covered);
        clear_entries(r);
        return false;
    }
    if (pixman_region32_not_empty(&changed)) {
        pixman_region32_intersect_rect(&changed, &changed, 0, 0, v.width, v.height);
        wlr_damage_ring_add(&out->damage_ring, &changed);
        pixman_region32_union(&out->private.pending_commit_damage,
            &out->private.pending_commit_damage, &changed);
    }
    pixman_region32_fini(&changed);
    wlr_output_state_set_damage(state, &out->private.pending_commit_damage);
    bool scanout = len == 1 && veil == 0 && try_scanout(&entries[0], out, state, &v);
    if (out->private.prev_scanout != scanout) {
        out->private.prev_scanout = scanout;
        wlr_log(WLR_DEBUG, "Direct scan-out %s", scanout ? "enabled" : "disabled");
    }
    bool ok = scanout;
    struct wlr_buffer *buffer = NULL;
    if (scanout) goto done;
    if (!wlr_output_configure_primary_swapchain(output, state, &output->swapchain)) goto done;
    buffer = wlr_swapchain_acquire(output->swapchain);
    if (!buffer) goto done;
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r->pass, buffer,
        &(struct wlr_buffer_pass_options){.signal_timeline = out->private.in_timeline,
            .signal_point = ++out->private.in_point});
    if (!pass) goto done;
    pixman_region32_t damage, background;
    pixman_region32_init(&damage);
    pixman_region32_init(&background);
    wlr_damage_ring_rotate_buffer(&out->damage_ring, buffer, &damage);
    pixman_region32_intersect_rect(&damage, &damage, 0, 0, v.width, v.height);
    device_region(&collector.covered, &v, false);
    pixman_region32_subtract(&background, &damage, &collector.covered);
    if (floor(v.scale) != v.scale) {
        wlr_region_expand(&background, &background, 1);
        pixman_region32_intersect(&background, &background, &damage);
    }
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, buffer->width, buffer->height}, .color = {0, 0, 0, 1}, .clip = &background});
    ok = true;
    for (size_t i = len; i > 0; i--)
        if (!render_entry(r, &entries[i - 1], out, pass, &v, &damage, false)) ok = false;
    if (veil > 0) wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, buffer->width, buffer->height}, .color = {0, 0, 0, veil}, .clip = &damage});
    wlr_output_add_software_cursors_to_render_pass(output, pass, &damage);
    bool submitted = wlr_render_pass_submit(pass);
    // Successful reads still need release points when another item failed to
    // import. No sample event is sent for a failed GPU submission.
    if (submitted) for (size_t i = 0; i < len; i++) if (entries[i].sampled) sample(&entries[i], out, false);
#ifdef REDIWM_DAMAGE_AUDIT
    if (submitted && ok) audit_damage(r, out, buffer, entries, len, &v, &damage, veil);
#endif
    ok = ok && submitted;
    pixman_region32_fini(&background);
    pixman_region32_fini(&damage);
    if (ok) {
        wlr_output_state_set_buffer(state, buffer);
        if (out->private.in_timeline) {
            wlr_output_state_set_wait_timeline(state, out->private.in_timeline, out->private.in_point);
            wlr_output_state_set_signal_timeline(state, out->private.out_timeline, ++out->private.out_point);
        }
    }
done:
    if (buffer) wlr_buffer_unlock(buffer);
    if (!ok) rediwm_scene_output_damage_whole(out);
    pixman_region32_fini(&collector.covered);
    if (ok && veiled) veiled->veil_changed = false;
    if (os) {
        // Outside the pass: drop the blurs of effects this output no longer shows;
        // after a failed frame, trust none of them.
        struct effect_cache *c, *next;
        wl_list_for_each_safe(c, next, &os->caches, link) {
            if (!ok) c->valid = false;
            if (!c->seen) cache_destroy(r, c);
        }
    }
    clear_entries(r);
    return ok;
}
