// Stage 4b shape gates 1-4: clip accuracy, seams, border partition and
// premultiplied edges, with the shared shape helpers.
// Included by scene_pass_test.c, in its one unit with scene_pass.c.

// ---- Stage 4b: rounded shapes (docs/plans/scene-graph-stage4.md) ----------------------
// The stage 1 spike's gates, on the production pass. Windows are made the way the
// compositor will make them: a clip spec in source units, resolved through a
// transform and snapped, so these also test that the pieces tile on the grid.
enum { GW = 640, GH = 480 };
static const float BG[4] = {224 / 255.f, 225 / 255.f, 232 / 255.f, 1};
static const float BODY[4] = {16 / 255.f, 18 / 255.f, 21 / 255.f, 1};
static const float SCALES[] = {1.f, 1.25f, 1.5f, 2.f};
static const float ZOOMS[] = {1.f, .85f, .70f, .55f, .25f};
#define COUNT(a) (sizeof(a) / sizeof(*(a)))

static void check(bool ok, const char *what, ...) {
    if (ok) return;
    char text[256];
    va_list args;
    va_start(args, what);
    vsnprintf(text, sizeof(text), what, args);
    va_end(args);
    fprintf(stderr, "FAIL: %s\n", text);
    exit(1);
}
struct image { int w, h; uint8_t *p; };
static uint8_t *at(const struct image *img, int x, int y) { return img->p + 4 * (y * img->w + x); }
static int diff(int a, int b) { return abs(a - b); }
static void read_image(struct rediwm_scene_renderer *r, struct wlr_buffer *b, struct image *img) {
    struct gl_state state;
    assert(scene_pass_enter(r, &state));
    img->w = b->width;
    img->h = b->height;
    img->p = realloc(img->p, 4 * (size_t)img->w * img->h);
    glBindFramebuffer(GL_FRAMEBUFFER, wlr_gles2_renderer_get_buffer_fbo(r->renderer, b));
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, img->w, img->h, GL_RGBA, GL_UNSIGNED_BYTE, img->p);
    assert(glGetError() == GL_NO_ERROR);
    scene_pass_leave(r, &state);
}
static struct wlr_buffer *target_sized(struct wlr_allocator *allocator, int w, int h) {
    uint64_t modifier = DRM_FORMAT_MOD_INVALID;
    struct wlr_drm_format format = {
        .format = DRM_FORMAT_ARGB8888, .len = 1, .capacity = 1, .modifiers = &modifier,
    };
    struct wlr_buffer *b = wlr_allocator_create_buffer(allocator, w, h, &format);
    assert(b);
    return b;
}
// A pass whose buffer starts as one opaque colour.
static struct wlr_render_pass *begin_fill(struct rediwm_scene_renderer *r, struct wlr_buffer *b,
        const float color[4], const pixman_region32_t *clip) {
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, b, NULL);
    check(pass != NULL, "cannot begin an owned pass");
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, b->width, b->height}, .color = {color[0], color[1], color[2], color[3]},
        .blend_mode = WLR_RENDER_BLEND_MODE_NONE, .clip = clip,
    });
    return pass;
}
static void finish(struct wlr_render_pass *pass) { check(wlr_render_pass_submit(pass), "an owned pass failed"); }
static void piece(struct wlr_render_pass *pass, const struct rediwm_pass_shape *shape,
        struct wlr_box box, const float color[4], const pixman_region32_t *clip) {
    rediwm_scene_pass_add_rect_shaped(pass, &(struct wlr_render_rect_options){
        .box = box, .color = {color[0], color[1], color[2], color[3]}, .clip = clip,
    }, shape);
}

// A window 200x140 (source units) at (30, 24), plus a titlebar of 36 and a footer
// of 10, placed in a layout offset by 8 device pixels.
struct window {
    struct rediwm_pass_shape shape;
    struct rediwm_clip clip;
    struct wlr_box title, client, footer;
};
static struct wlr_box box_of(struct rediwm_snap s) { return (struct wlr_box){s.x, s.y, s.width, s.height}; }
static struct window make_window(float scale, float zoom, float radius, double border) {
    const struct rediwm_xform xf = {(double)scale * zoom, 8, 8};
    const struct rediwm_clip_spec spec = {.width = 200, .height = 140, .radii = {radius, radius, radius, radius}, .border = border};
    struct window w = {.clip = rediwm_clip_resolve(xf, 30, 24, &spec)};
    w.shape.box = box_of(rediwm_edges_snap(w.clip.edges));
    for (int i = 0; i < 4; i++) w.shape.radii[i] = w.clip.radii[i];
    // A ring is whole device pixels, never thinner than one.
    w.shape.border = w.clip.border > 0 ? fmaxf(1.f, roundf(w.clip.border)) : 0;
    w.title = box_of(rediwm_edges_snap(rediwm_xform_rect(xf, 30, 24, 200, 36)));
    w.client = box_of(rediwm_edges_snap(rediwm_xform_rect(xf, 30, 24 + 36, 200, 140 - 36 - 10)));
    w.footer = box_of(rediwm_edges_snap(rediwm_xform_rect(xf, 30, 24 + 140 - 10, 200, 10)));
    return w;
}

// ---- Gate 1: the clip against a supersampled reference ---------------------------------
static bool inside_rrect(double px, double py, const struct rediwm_pass_shape *s) {
    double x = px - s->box.x, y = py - s->box.y;
    if (x < 0 || y < 0 || x > s->box.width || y > s->box.height) return false;
    double r = (x < s->box.width / 2.) ? (y < s->box.height / 2. ? s->radii[0] : s->radii[3])
                                       : (y < s->box.height / 2. ? s->radii[1] : s->radii[2]);
    double cx = x < s->box.width / 2. ? r : s->box.width - r, cy = y < s->box.height / 2. ? r : s->box.height - r;
    if (!((x < r || x > s->box.width - r) && (y < r || y > s->box.height - r))) return true;
    return hypot(x - cx, y - cy) <= r;
}
static double reference_coverage(const struct rediwm_pass_shape *s, int x, int y) {
    const int n = 8;
    int hits = 0;
    for (int j = 0; j < n; j++) for (int i = 0; i < n; i++) hits += inside_rrect(x + (i + .5) / n, y + (j + .5) / n, s);
    return (double)hits / (n * n);
}
static void gate_clip_accuracy(struct rediwm_scene_renderer *r, struct wlr_buffer *buf, struct image *img) {
    int worst = 0, fringe = 0;
    const uint8_t bg[3] = {224, 225, 232}, body[3] = {16, 18, 21};
    for (size_t si = 0; si < COUNT(SCALES); si++) for (size_t zi = 0; zi < COUNT(ZOOMS); zi++) {
        struct window w = make_window(SCALES[si], ZOOMS[zi], 10, 0);
        struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
        piece(pass, &w.shape, w.shape.box, BODY, NULL);
        finish(pass);
        read_image(r, buf, img);
        for (int y = w.shape.box.y - 2; y < w.shape.box.y + w.shape.box.height + 2; y++)
        for (int x = w.shape.box.x - 2; x < w.shape.box.x + w.shape.box.width + 2; x++) {
            double c = reference_coverage(&w.shape, x, y);
            for (int ch = 0; ch < 3; ch++) {
                int got = at(img, x, y)[ch];
                int want = (int)lround(bg[ch] * (1 - c) + body[ch] * c);
                if (diff(got, want) > worst) worst = diff(got, want);
                // No fringe: never outside the range of the two colours.
                int lo = body[ch] < bg[ch] ? body[ch] : bg[ch], hi = body[ch] < bg[ch] ? bg[ch] : body[ch];
                if (got < lo - 1 || got > hi + 1) fringe++;
            }
        }
    }
    check(fringe == 0, "clip: %d channel values fall outside the bg/body range (fringe)", fringe);
    // A one-pixel linear ramp on the distance is not area coverage: on a curved
    // 45-degree edge it is off by up to about .08 of the contrast, here 18 of 208
    // levels at scale 1.25, zoom .70 (an 8.75 px radius), pixel (2,2) of each
    // corner. The spike, without the 1.25 scale, measured 12. glass.c uses the
    // same ramp, and a straight edge or a pixel off the diagonal is exact.
    check(worst <= 20, "clip: differs from supersampled coverage by %d levels", worst);
    printf("PASS: rounded clip within %d levels of area coverage, no fringe, %zu scales x %zu zoom steps\n",
        worst, COUNT(SCALES), COUNT(ZOOMS));
}

// ---- Gate 2: pieces of one window share the clip with no seam --------------------------
static void gate_no_seams(struct rediwm_scene_renderer *r, struct wlr_buffer *buf, struct image *img) {
    const float red[4] = {1, 0, 0, 1}, green[4] = {0, 1, 0, 1}, blue[4] = {0, 0, 1, 1};
    for (size_t si = 0; si < COUNT(SCALES); si++) for (size_t zi = 0; zi < COUNT(ZOOMS); zi++) {
        struct window w = make_window(SCALES[si], ZOOMS[zi], 10, 0);
        struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
        piece(pass, &w.shape, w.title, red, NULL);
        piece(pass, &w.shape, w.client, green, NULL);
        piece(pass, &w.shape, w.footer, blue, NULL);
        finish(pass);
        read_image(r, buf, img);
        const struct wlr_box *b = &w.shape.box;
        const int margin = (int)ceilf(w.shape.radii[0]) + 2;
        for (int y = 0; y < b->height; y++) for (int x = margin; x < b->width - margin; x++) {
            const float *want = b->y + y < w.client.y ? red : b->y + y < w.footer.y ? green : blue;
            uint8_t *px = at(img, b->x + x, b->y + y);
            for (int ch = 0; ch < 3; ch++)
                check(diff(px[ch], (int)lround(want[ch] * 255)) <= 1,
                    "seam at scale %.2f zoom %.2f, row %d col %d channel %d = %d",
                    SCALES[si], ZOOMS[zi], y, x, ch, px[ch]);
        }
        // The pieces really tile the shape's box, with no gap and no overlap.
        check(w.title.y == b->y && w.title.y + w.title.height == w.client.y &&
              w.client.y + w.client.height == w.footer.y && w.footer.y + w.footer.height == b->y + b->height,
              "pieces do not tile the window at scale %.2f zoom %.2f", SCALES[si], ZOOMS[zi]);
    }
    puts("PASS: titlebar, client and footer meet without a seam at every scale and zoom");
}

// ---- Gate 3: border and body partition the shape's coverage ----------------------------
static void gate_border_partition(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
        struct image *img, struct image *ref) {
    int worst = 0;
    for (size_t si = 0; si < COUNT(SCALES); si++) for (size_t zi = 0; zi < COUNT(ZOOMS); zi++) {
        struct window w = make_window(SCALES[si], ZOOMS[zi], 10, 1);
        struct rediwm_pass_shape ringed = w.shape, plain = w.shape;
        plain.border = 0;
        memcpy(ringed.border_color, BODY, sizeof(BODY));
        // Ring and body in one colour, in three pieces, must equal one plain body,
        // whatever the split between them, or coverage leaks.
        struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
        piece(pass, &plain, plain.box, BODY, NULL);
        finish(pass);
        read_image(r, buf, ref);
        pass = begin_fill(r, buf, BG, NULL);
        piece(pass, &ringed, w.title, BODY, NULL);
        piece(pass, &ringed, w.client, BODY, NULL);
        piece(pass, &ringed, w.footer, BODY, NULL);
        finish(pass);
        read_image(r, buf, img);
        for (int i = 0; i < img->w * img->h * 4; i++) if (diff(img->p[i], ref->p[i]) > worst) worst = diff(img->p[i], ref->p[i]);
        // And the ring really is the ring: its own colour on the outer row of a
        // straight edge, the body colour just inside it.
        const float red[4] = {1, 0, 0, 1};
        memcpy(ringed.border_color, red, sizeof(red));
        pass = begin_fill(r, buf, BG, NULL);
        piece(pass, &ringed, ringed.box, BODY, NULL);
        finish(pass);
        read_image(r, buf, img);
        int cx = ringed.box.x + ringed.box.width / 2, bw = (int)ringed.border;
        check(at(img, cx, ringed.box.y)[0] >= 254 && at(img, cx, ringed.box.y)[1] <= 1,
            "outer row is not the border colour at scale %.2f zoom %.2f", SCALES[si], ZOOMS[zi]);
        check(diff(at(img, cx, ringed.box.y + bw)[0], 16) <= 1,
            "row inside the border is not the body at scale %.2f zoom %.2f", SCALES[si], ZOOMS[zi]);
        check(at(img, ringed.box.x, ringed.box.y + ringed.box.height / 2)[0] >= 254,
            "left edge is not the border colour at scale %.2f zoom %.2f", SCALES[si], ZOOMS[zi]);
        // A translucent ring (the default theme's is 9% white) is composited over the
        // body, not in place of it: ring + body * (1 - alpha), per channel.
        const float faint[4] = {.09f, .09f, .09f, .09f};
        memcpy(ringed.border_color, faint, sizeof(faint));
        pass = begin_fill(r, buf, BG, NULL);
        piece(pass, &ringed, ringed.box, BODY, NULL);
        finish(pass);
        read_image(r, buf, img);
        for (int ch = 0; ch < 3; ch++)
            check(diff(at(img, cx, ringed.box.y)[ch], (int)lround(255 * (.09 + BODY[ch] * .91))) <= 1,
                "translucent ring is not over the body at scale %.2f zoom %.2f: channel %d is %d",
                SCALES[si], ZOOMS[zi], ch, at(img, cx, ringed.box.y)[ch]);
    }
    check(worst <= 2, "border + body differ from one shape by %d levels", worst);
    printf("PASS: border ring and body, in one pass, add up to exactly the shape's coverage (max diff %d)\n", worst);
}

// ---- Gate 4: premultiplied texture edges and opaque (XRGB) textures ---------------------
static void gate_premultiplied(struct rediwm_scene_renderer *r, struct wlr_buffer *buf, struct image *img) {
    struct rediwm_pass_shape s = {.box = {40, 40, 80, 80}, .radii = {20, 20, 20, 20}};
    // 50% red, premultiplied: (128, 0, 0, 128) is a half-intensity red at half alpha.
    uint32_t half[16], junk = 0x000AC81E, white = 0xffffffff, solid_px[1] = {junk};
    for (int i = 0; i < 16; i++) half[i] = 0x80800000;
    struct wlr_texture *t_half = wlr_texture_from_pixels(r->renderer, DRM_FORMAT_ARGB8888, 16, 4, 4, half);
    struct wlr_texture *t_xrgb = wlr_texture_from_pixels(r->renderer, DRM_FORMAT_XRGB8888, 4, 1, 1, solid_px);
    struct wlr_texture *t_white = wlr_texture_from_pixels(r->renderer, DRM_FORMAT_XRGB8888, 4, 1, 1, &white);
    check(t_half && t_xrgb && t_white, "cannot create the test textures");
    struct { struct wlr_texture *t; float alpha; const char *name; } cases[] = {
        {t_half, 1, "half-transparent"}, {t_xrgb, 1, "xrgb"}, {t_white, .5f, "opacity"},
    };
    for (size_t i = 0; i < COUNT(cases); i++) {
        const bool on_black = cases[i].t == t_white;
        float base[4] = {BG[0], BG[1], BG[2], 1};
        if (on_black) memset(base, 0, sizeof(float) * 3);
        struct wlr_render_pass *pass = begin_fill(r, buf, base, NULL);
        float alpha = cases[i].alpha;
        rediwm_scene_pass_add_texture_shaped(pass, &(struct wlr_render_texture_options){
            .texture = cases[i].t, .dst_box = s.box, .alpha = &alpha}, &s);
        finish(pass);
        read_image(r, buf, img);
        uint8_t *in = at(img, 80, 80);
        const int want[3][3] = {{240, 112, 116}, {10, 200, 30}, {128, 128, 128}};
        for (int ch = 0; ch < 3; ch++)
            check(diff(in[ch], want[i][ch]) <= 2, "%s texel gave (%d,%d,%d) inside the shape",
                cases[i].name, in[0], in[1], in[2]);
        // At the edge the colour is the premultiplied source times coverage over the backdrop:
        // never darker or brighter than the two ends, and within the clip's accuracy of area coverage.
        double src_a = i == 0 ? .50196 : i == 2 ? .5 : 1;
        for (int y = s.box.y - 1; y < s.box.y + s.box.height + 1; y++)
        for (int x = s.box.x - 1; x < s.box.x + s.box.width + 1; x++) {
            double c = reference_coverage(&s, x, y);
            for (int ch = 0; ch < 3; ch++) {
                double bgv = base[ch] * 255;
                double want_v = want[i][ch] - (1 - src_a) * bgv;  // the premultiplied source, 0..255
                double expect = want_v * c + bgv * (1 - src_a * c);
                check(diff(at(img, x, y)[ch], (int)lround(expect)) <= 14,
                    "%s edge pixel (%d,%d) channel %d is %d, area coverage predicts %.0f",
                    cases[i].name, x, y, ch, at(img, x, y)[ch], expect);
            }
        }
    }
    wlr_texture_destroy(t_half);
    wlr_texture_destroy(t_xrgb);
    wlr_texture_destroy(t_white);
    puts("PASS: premultiplied edges, opacity and XRGB textures blend correctly through the clip");
}

// ---- Gate 5: a polygon outline (windows with cut corners and stepped edges) --------------
// A frame 200x120 whose top-left and bottom-right corners are cut, whose top edge
// steps down 10 px from x = 120 to its end, and whose top-right tip is slanted: the
// outline of a themed window. Device pixels from the shape box's corner.
static void polygon_shape(struct rediwm_pass_shape *s, bool reversed) {
    static const float v[][2] = {{0, 24}, {24, 0}, {118, 0}, {128, 10}, {176, 10}, {200, 34}, {200, 96}, {176, 120}, {0, 120}};
    const int n = (int)COUNT(v);
    *s = (struct rediwm_pass_shape){.box = {40, 40, 200, 120}, .poly_count = n};
    for (int i = 0; i < n; i++) {
        const int j = reversed ? n - 1 - i : i;
        s->poly[i][0] = v[j][0];
        s->poly[i][1] = v[j][1];
    }
}
static bool inside_polygon(double px, double py, const struct rediwm_pass_shape *s) {
    double v[REDIWM_POLY_MAX][2];
    for (int i = 0; i < s->poly_count; i++) { v[i][0] = s->poly[i][0]; v[i][1] = s->poly[i][1]; }
    return rediwm_sd_polygon(px - s->box.x, py - s->box.y, v, s->poly_count) < 0;
}
static void gate_polygon(struct rediwm_scene_renderer *r, struct wlr_buffer *buf, struct image *img,
        struct image *ref) {
    _Static_assert(REDIWM_PASS_POLY_MAX == REDIWM_POLY_MAX, "the pass and the graph size the outline alike");
    struct rediwm_pass_shape s;
    polygon_shape(&s, false);
    // The polygon programs are built on request: before it a polygon draw fails the
    // pass (the caller must not make one), and the next pass is unharmed.
    struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
    piece(pass, &s, s.box, BODY, NULL);
    check(!wlr_render_pass_submit(pass), "polygon: a draw without its programs did not fail the pass");
    check(rediwm_scene_renderer_enable_polygons(r), "polygon: the programs did not build");
    check(rediwm_scene_renderer_enable_polygons(r), "polygon: a second request lost the programs");
    pass = begin_fill(r, buf, BG, NULL);
    piece(pass, &s, s.box, BODY, NULL);
    finish(pass);
    read_image(r, buf, img);
    // The coverage of the outline, against sixty-four samples a pixel. The ramp is on
    // the distance, which on a diagonal is not area coverage: allow what the arc gets.
    int worst = 0, fringe = 0;
    const uint8_t bg[3] = {224, 225, 232}, body[3] = {16, 18, 21};
    for (int y = s.box.y - 2; y < s.box.y + s.box.height + 2; y++)
    for (int x = s.box.x - 2; x < s.box.x + s.box.width + 2; x++) {
        int hits = 0;
        for (int j = 0; j < 8; j++) for (int i = 0; i < 8; i++) hits += inside_polygon(x + (i + .5) / 8, y + (j + .5) / 8, &s);
        const double c = hits / 64.;
        for (int ch = 0; ch < 3; ch++) {
            const int got = at(img, x, y)[ch], want = (int)lround(bg[ch] * (1 - c) + body[ch] * c);
            if (diff(got, want) > worst) worst = diff(got, want);
            const int lo = body[ch] < bg[ch] ? body[ch] : bg[ch], hi = body[ch] < bg[ch] ? bg[ch] : body[ch];
            if (got < lo - 1 || got > hi + 1) fringe++;
        }
    }
    check(fringe == 0, "polygon: %d channel values fall outside the bg/body range", fringe);
    check(worst <= 30, "polygon: differs from supersampled coverage by %d levels", worst);
    // The corner the outline cuts is the backdrop, the notch too, the middle the body.
    check(diff(at(img, s.box.x + 2, s.box.y + 2)[0], 224) <= 1, "polygon: the cut top-left corner is drawn");
    check(diff(at(img, s.box.x + 150, s.box.y + 3)[0], 224) <= 1, "polygon: the step in the top edge is drawn");
    check(diff(at(img, s.box.x + 150, s.box.y + 14)[0], 16) <= 1, "polygon: the body below the step is missing");
    check(diff(at(img, s.box.x + 100, s.box.y + 60)[0], 16) <= 1, "polygon: the middle is not the body");
    // Walked the other way round it is the same outline.
    struct rediwm_pass_shape back;
    polygon_shape(&back, true);
    pass = begin_fill(r, buf, BG, NULL);
    piece(pass, &back, back.box, BODY, NULL);
    finish(pass);
    read_image(r, buf, ref);
    int moved = 0;
    for (int i = 0; i < img->w * img->h * 4; i++) if (diff(img->p[i], ref->p[i]) > 1) moved++;
    check(moved == 0, "polygon: the reversed outline differs in %d values", moved);
    // A ring follows the outline: its colour on a straight edge, the body just inside.
    struct rediwm_pass_shape ringed = s;
    const float red[4] = {1, 0, 0, 1};
    ringed.border = 2;
    memcpy(ringed.border_color, red, sizeof(red));
    pass = begin_fill(r, buf, BG, NULL);
    piece(pass, &ringed, ringed.box, BODY, NULL);
    finish(pass);
    read_image(r, buf, img);
    check(at(img, s.box.x + 60, s.box.y)[0] >= 254 && at(img, s.box.x + 60, s.box.y)[1] <= 1, "polygon: the top ring row is not the border colour");
    check(at(img, s.box.x + 150, s.box.y + 10)[0] >= 254, "polygon: the ring does not follow the step");
    check(diff(at(img, s.box.x + 60, s.box.y + 3)[0], 16) <= 1, "polygon: the row inside the ring is not the body");
    // Pieces tile it: a titlebar and a client in different colours meet with no seam
    // where the outline does not reach.
    const float green[4] = {0, 1, 0, 1};
    const struct wlr_box title = {s.box.x, s.box.y, s.box.width, 40}, client = {s.box.x, s.box.y + 40, s.box.width, 80};
    pass = begin_fill(r, buf, BG, NULL);
    piece(pass, &s, title, red, NULL);
    piece(pass, &s, client, green, NULL);
    finish(pass);
    read_image(r, buf, img);
    for (int y = 14; y < 118; y++) for (int x = 30; x < 170; x++) {
        const bool top = y < 40;
        const uint8_t *px = at(img, s.box.x + x, s.box.y + y);
        check(diff(px[0], top ? 255 : 0) <= 1 && diff(px[1], top ? 0 : 255) <= 1,
            "polygon: seam at (%d,%d): (%d,%d,%d)", x, y, px[0], px[1], px[2]);
    }
    printf("PASS: a polygon outline is within %d levels of area coverage, either winding, with its ring and without seams\n", worst);
}
