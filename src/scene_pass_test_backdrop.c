// Stage 5b backdrop gates: blur, properties, the front surface, redirection
// and dimming.
// Included by scene_pass_test.c, in its one unit with scene_pass.c.

// ---- Stage 5b: backdrops ------------------------------------------------------------
static struct wlr_buffer *target_format(struct wlr_allocator *allocator, int w, int h, uint32_t fmt) {
    uint64_t modifier = DRM_FORMAT_MOD_INVALID;
    struct wlr_drm_format format = {.format = fmt, .len = 1, .capacity = 1, .modifiers = &modifier};
    struct wlr_buffer *b = wlr_allocator_create_buffer(allocator, w, h, &format);
    assert(b);
    return b;
}
static const float BANDS[5][4] = {{1, 0, 0, 1}, {0, .8f, 0, 1}, {0, 0, 1, 1}, {1, 1, 1, 1}, {.1f, .1f, .1f, 1}};
static void bands(struct wlr_render_pass *pass, int width, int height) {
    for (int x = 0, i = 0; x < width; x += 40, i++)
        wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
            .box = {x, 0, 40, height}, .color = {BANDS[i % 5][0], BANDS[i % 5][1], BANDS[i % 5][2], 1}});
}
static void fill(struct wlr_render_pass *pass, const float color[4]) {
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, GW, GH}, .color = {color[0], color[1], color[2], color[3]}});
}
// Vertical bands 40 px wide, then a backdrop of `region` composited over `box`.
static float backdrop_factor = 4;
static struct rediwm_backdrop *draw_backdrop(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
        struct rediwm_backdrop *b, struct wlr_box region, struct wlr_box box, float sigma,
        const struct rediwm_pass_backdrop *opts, const pixman_region32_t *clip) {
    struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
    bands(pass, buf->width, buf->height);
    // What lies below the effect, drawn again into the quarter-size backdrop.
    rediwm_scene_pass_begin_backdrop(pass, region, backdrop_factor);
    bands(pass, buf->width, buf->height);
    rediwm_scene_pass_end_backdrop(pass, &b, sigma);
    struct rediwm_pass_backdrop o = opts ? *opts : (struct rediwm_pass_backdrop){.saturation = 1, .opacity = 1};
    o.backdrop = b;
    o.clip = clip;
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = box}, box, &o);
    finish(pass);
    return b;
}
// The exact full-resolution Gaussian of the bands, clamped at the buffer edge, as
// the reference the quarter-size blur approximates.
static double band_channel(int x, int width, int c) {
    x = x < 0 ? 0 : x >= width ? width - 1 : x;
    return BANDS[(x / 40) % 5][c];
}
static void gate_backdrop_blur(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator, struct image *img) {
    const struct wlr_box region = {100, 100, 400, 200}, box = {148, 148, 304, 104};
    int worst[4] = {0};
    for (int f = 0; f < 4; f++) {
        // ARGB and XRGB buffers, reduced by 4 (scale 1) and by 6 (glass at 1.5).
        backdrop_factor = f < 2 ? 4 : 6;
        // Sigma in reduced pixels as glass has it (22 logical px over a quarter of
        // the logical size): the same at every scale.
        const float sigma = 4 * backdrop_factor;
        struct wlr_buffer *buf = target_format(allocator, GW, GH, f % 2 ? DRM_FORMAT_XRGB8888 : DRM_FORMAT_ARGB8888);
        struct rediwm_backdrop *b = draw_backdrop(r, buf, NULL, region, box, sigma, NULL, NULL);
        read_image(r, buf, img);
        for (int x = box.x; x < box.x + box.width; x++) {
            double want[3] = {0};
            double weight = 0;
            for (int k = -96; k <= 96; k++) {
                const double w = exp(-.5 * k * k / (sigma * sigma));
                // Clamped to the copied region, as the blur's limits are.
                int sx = x + k;
                sx = sx < region.x ? region.x : sx >= region.x + region.width ? region.x + region.width - 1 : sx;
                for (int c = 0; c < 3; c++) want[c] += w * band_channel(sx, GW, c);
                weight += w;
            }
            for (int y = box.y; y < box.y + box.height; y += 13)
                for (int c = 0; c < 3; c++) {
                    const int d = diff(at(img, x, y)[c], (int)lround(255 * want[c] / weight));
                    if (d > worst[f]) worst[f] = d;
                }
        }
        rediwm_scene_renderer_destroy_backdrop(r, b);
        wlr_buffer_drop(buf);
    }
    // Reduced by 4 the bands' edges fall on whole pixels of the image; by 6 they do
    // not, and an edge drawn at reduced size moves by up to half a pixel (3 device
    // pixels), which on a blurred step of sigma 24 is 255 / (sqrt(2 pi) 24) levels
    // per pixel: 13. glass.c drew its reduced capture the same way.
    for (int f = 0; f < 4; f++)
        check(worst[f] <= (f < 2 ? 2 : 15), "the reduced blur differs from the exact Gaussian by %d levels (case %d)", worst[f], f);
    backdrop_factor = 4;
    printf("PASS: backdrop blur against the exact Gaussian: %d levels reduced by 4, %d by 6 (edge quantisation), ARGB and XRGB\n",
        worst[0] > worst[1] ? worst[0] : worst[1], worst[2] > worst[3] ? worst[2] : worst[3]);
}
static void gate_backdrop_properties(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator, struct image *img) {
    struct wlr_buffer *buf = target_sized(allocator, GW, GH);
    struct rediwm_backdrop *b = NULL;
    // A red/blue step at x = 320 blurs to an even mix there, monotonic across,
    // unchanged far from it.
    struct wlr_render_pass *pass = begin_fill(r, buf, (float[4]){1, 0, 0, 1}, NULL);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){.box = {320, 0, 320, GH}, .color = {0, 0, 1, 1}});
    const struct wlr_box region = {120, 100, 400, 200}, box = {168, 148, 304, 104};
    rediwm_scene_pass_begin_backdrop(pass, region, 4);
    fill(pass, (float[4]){1, 0, 0, 1});
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){.box = {320, 0, 320, GH}, .color = {0, 0, 1, 1}});
    rediwm_scene_pass_end_backdrop(pass, &b, 16);
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = box}, box,
        &(struct rediwm_pass_backdrop){.backdrop = b, .saturation = 1, .opacity = 1});
    finish(pass);
    read_image(r, buf, img);
    const int y = 200;
    check(diff(at(img, 320, y)[0], 128) <= 12 && diff(at(img, 320, y)[2], 128) <= 12,
        "the step does not blur to an even mix (%d, %d)", at(img, 320, y)[0], at(img, 320, y)[2]);
    for (int x = box.x + 1; x < box.x + box.width; x++)
        check(at(img, x, y)[0] <= at(img, x - 1, y)[0] + 1, "the blurred step is not monotonic at %d", x);
    check(at(img, box.x, y)[0] >= 250 && at(img, box.x + box.width - 1, y)[2] >= 250,
        "the blur reaches too far (%d, %d)", at(img, box.x, y)[0], at(img, box.x + box.width - 1, y)[2]);
    // At the buffer edge the blur replicates it: no black comes in.
    pass = begin_fill(r, buf, (float[4]){0, 1, 0, 1}, NULL);
    const struct wlr_box edge_region = {-60, 100, 200, 200}, edge_box = {0, 148, 92, 104};
    rediwm_scene_pass_begin_backdrop(pass, edge_region, 4);
    fill(pass, (float[4]){0, 1, 0, 1});
    rediwm_scene_pass_end_backdrop(pass, &b, 16);
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = edge_box}, edge_box,
        &(struct rediwm_pass_backdrop){.backdrop = b, .saturation = 1, .opacity = 1});
    finish(pass);
    read_image(r, buf, img);
    for (int x = 0; x < 92; x++)
        check(at(img, x, 200)[1] >= 253 && at(img, x, 200)[0] <= 2, "the buffer edge darkens the blur at %d", x);
    // Saturation as glass.c applies it, on a uniform colour the blur keeps.
    const float c[3] = {.2f, .4f, .6f};
    pass = begin_fill(r, buf, (float[4]){c[0], c[1], c[2], 1}, NULL);
    rediwm_scene_pass_begin_backdrop(pass, region, 4);
    fill(pass, (float[4]){c[0], c[1], c[2], 1});
    rediwm_scene_pass_end_backdrop(pass, &b, 16);
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = box}, box,
        &(struct rediwm_pass_backdrop){.backdrop = b, .saturation = 1.5f, .opacity = 1});
    finish(pass);
    read_image(r, buf, img);
    const double l = .213 * c[0] + .715 * c[1] + .072 * c[2];
    for (int i = 0; i < 3; i++) {
        const int want = (int)lround(255 * (l + (c[i] - l) * 1.5));
        check(diff(at(img, 300, 200)[i], want) <= 2, "saturation: channel %d is %d, not %d", i, at(img, 300, 200)[i], want);
    }
    rediwm_scene_renderer_destroy_backdrop(r, b);
    wlr_buffer_drop(buf);
    puts("PASS: a blurred step mixes evenly and monotonically, the buffer edge replicates, saturation matches glass");
}
static void gate_backdrop_front(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator, struct image *img) {
    struct wlr_buffer *buf = target_sized(allocator, GW, GH);
    uint32_t half[16 * 16];
    for (int i = 0; i < 16 * 16; i++) half[i] = 0x80000000; // alpha 128, premultiplied black
    struct wlr_texture *front = wlr_texture_from_pixels(r->renderer, DRM_FORMAT_ARGB8888, 16 * 4, 16, 16, half);
    assert(front);
    struct rediwm_backdrop *b = NULL;
    const struct wlr_box region = {100, 100, 200, 200}, box = {150, 150, 100, 100};
    // On a transparent buffer the composite's alpha is what it adds to the front.
    struct wlr_render_pass *pass = begin_fill(r, buf, (float[4]){1, 1, 1, 1}, NULL);
    rediwm_scene_pass_begin_backdrop(pass, region, 4);
    fill(pass, (float[4]){1, 1, 1, 1});
    rediwm_scene_pass_end_backdrop(pass, &b, 8);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){.box = {0, 0, GW, GH},
        .color = {0, 0, 0, 0}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = box}, box,
        &(struct rediwm_pass_backdrop){.backdrop = b, .saturation = 1, .opacity = .5f,
            .front = front, .front_box = box, .front_opacity = .5f});
    finish(pass);
    read_image(r, buf, img);
    const double f = 128 / 255.0 * .5, want = (.5 - f) / (1 - f);
    check(diff(at(img, 200, 200)[3], (int)lround(255 * want)) <= 1, "front alpha: %d, not %d",
        at(img, 200, 200)[3], (int)lround(255 * want));
    // An opaque front leaves nothing for the effect to add.
    pass = begin_fill(r, buf, (float[4]){1, 1, 1, 1}, NULL);
    rediwm_scene_pass_begin_backdrop(pass, region, 4);
    fill(pass, (float[4]){1, 1, 1, 1});
    rediwm_scene_pass_end_backdrop(pass, &b, 8);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){.box = {0, 0, GW, GH},
        .color = {0, 0, 0, 0}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = box}, box,
        &(struct rediwm_pass_backdrop){.backdrop = b, .saturation = 1, .opacity = 1,
            .front = front, .front_box = box, .front_opacity = 2.f});
    finish(pass);
    read_image(r, buf, img);
    check(at(img, 200, 200)[3] == 0, "an opaque front still gets a backdrop (%d)", at(img, 200, 200)[3]);
    // A clipped composite equals that part of a full one: the copy and the blur
    // ignore the clip.
    struct image full = {0};
    b = draw_backdrop(r, buf, b, (struct wlr_box){100, 100, 400, 200}, (struct wlr_box){148, 148, 304, 104}, 16, NULL, NULL);
    read_image(r, buf, &full);
    pixman_region32_t clip;
    pixman_region32_init_rect(&clip, 148, 148, 150, 104);
    b = draw_backdrop(r, buf, b, (struct wlr_box){100, 100, 400, 200}, (struct wlr_box){148, 148, 304, 104}, 16, NULL, &clip);
    read_image(r, buf, img);
    for (int y = 148; y < 252; y++) for (int x = 148; x < 298; x++) for (int c = 0; c < 4; c++)
        check(at(img, x, y)[c] == at(&full, x, y)[c], "a clipped composite differs at %d,%d", x, y);
    pixman_region32_fini(&clip);
    free(full.p);
    wlr_texture_destroy(front);
    rediwm_scene_renderer_destroy_backdrop(r, b);
    wlr_buffer_drop(buf);
    puts("PASS: the backdrop makes up the front's alpha to the coverage; a clipped composite equals a full one");
}
// The redirect moves boxes, shape origins and scissors into the quarter-size
// image: a rounded piece and a clipped rect land where they belong in it.
static void gate_backdrop_redirect(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator, struct image *img) {
    struct wlr_buffer *buf = target_sized(allocator, GW, GH);
    struct rediwm_backdrop *b = NULL;
    const struct wlr_box region = {100, 80, 400, 240};
    const float gray[4] = {.5f, .5f, .5f, 1};
    struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
    rediwm_scene_pass_begin_backdrop(pass, region, 4);
    fill(pass, gray);
    const struct rediwm_pass_shape shape = {.box = {148, 120, 200, 120}, .radii = {40, 40, 40, 40}};
    rediwm_scene_pass_add_rect_shaped(pass, &(struct wlr_render_rect_options){
        .box = shape.box, .color = {1, 0, 0, 1}}, &shape);
    pixman_region32_t left;
    pixman_region32_init_rect(&left, 380, 200, 32, 60);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {380, 200, 64, 60}, .color = {0, 0, 1, 1}, .clip = &left});
    rediwm_scene_pass_end_backdrop(pass, &b, .5f);
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = region}, region,
        &(struct rediwm_pass_backdrop){.backdrop = b, .saturation = 1, .opacity = 1});
    finish(pass);
    read_image(r, buf, img);
    struct { int x, y; float c[3]; const char *what; } probes[] = {
        {248, 180, {1, 0, 0}, "inside the rounded piece"},
        {152, 124, {.5f, .5f, .5f}, "a corner the arc cuts away"},
        {392, 230, {0, 0, 1}, "the clipped rect"},
        {432, 230, {.5f, .5f, .5f}, "outside the clip"},
        {110, 90, {.5f, .5f, .5f}, "the region's corner"},
    };
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++)
        for (int c = 0; c < 3; c++)
            check(diff(at(img, probes[i].x, probes[i].y)[c], (int)lround(255 * probes[i].c[c])) <= 10,
                "redirected drawing: %s is %d,%d,%d", probes[i].what, at(img, probes[i].x, probes[i].y)[0],
                at(img, probes[i].x, probes[i].y)[1], at(img, probes[i].x, probes[i].y)[2]);
    pixman_region32_fini(&left);
    rediwm_scene_renderer_destroy_backdrop(r, b);
    wlr_buffer_drop(buf);
    puts("PASS: redirected draws land in the quarter-size image with their shape, offset and clip");
}
// The composite shows what is behind its window, so a dimmed window dims it too.
static void gate_backdrop_dim(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator, struct image *img) {
    struct wlr_buffer *buf = target_sized(allocator, GW, GH);
    struct rediwm_backdrop *b = NULL;
    const struct wlr_box region = {120, 100, 400, 200}, box = {168, 148, 304, 104};
    const float c[3] = {.2f, .4f, .6f};
    const double in[3] = {c[0], c[1], c[2]};
    double want[3];
    struct wlr_render_pass *pass = begin_fill(r, buf, (float[4]){c[0], c[1], c[2], 1}, NULL);
    rediwm_scene_pass_begin_backdrop(pass, region, 4);
    fill(pass, (float[4]){c[0], c[1], c[2], 1});
    rediwm_scene_pass_end_backdrop(pass, &b, 16);
    rediwm_scene_pass_set_dim(pass, .1f, .2f);
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = box}, box,
        &(struct rediwm_pass_backdrop){.backdrop = b, .saturation = 1, .opacity = 1});
    rediwm_scene_pass_set_dim(pass, 0, 0);
    finish(pass);
    read_image(r, buf, img);
    graded(in, .1, .2, want);
    check_pixel(img, 300, 200, want, "a dimmed backdrop");
    check_pixel(img, 20, 20, in, "outside it");
    rediwm_scene_renderer_destroy_backdrop(r, b);
    wlr_buffer_drop(buf);
    puts("PASS: a dimmed backdrop composite is graded like the window it backs");
}
static void backdrop_gates(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator) {
    struct image img = {0};
    gate_backdrop_blur(r, allocator, &img);
    gate_backdrop_properties(r, allocator, &img);
    gate_backdrop_front(r, allocator, &img);
    gate_backdrop_redirect(r, allocator, &img);
    gate_backdrop_dim(r, allocator, &img);
    free(img.p);
}
