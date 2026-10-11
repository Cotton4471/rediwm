// Compare the actual owned drawing backend with wlroots, independently of
// scene traversal and output policy. A noninstalled, real-GPU fixture.
#include "scene_pass.c"
#include "scene_graph.h"
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <drm_fourcc.h>
#include <drm.h>
#include <gbm.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/render/allocator.h>
#include <wlr/render/drm_format_set.h>

enum { WIDTH = 127, HEIGHT = 93, TW = 23, TH = 17 };
static struct wlr_buffer *target(struct wlr_allocator *allocator) {
    uint64_t modifier = DRM_FORMAT_MOD_INVALID;
    struct wlr_drm_format format = {
        .format = DRM_FORMAT_ARGB8888, .len = 1, .capacity = 1, .modifiers = &modifier,
    };
    struct wlr_buffer *b = wlr_allocator_create_buffer(allocator, WIDTH, HEIGHT, &format);
    assert(b);
    return b;
}
static void read_pixels(struct rediwm_scene_renderer *r, struct wlr_buffer *b, uint8_t *pixels) {
    struct gl_state state;
    assert(enter(r, &state));
    glBindFramebuffer(GL_FRAMEBUFFER, wlr_gles2_renderer_get_buffer_fbo(r->renderer, b));
    glReadPixels(0, 0, WIDTH, HEIGHT, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    assert(glGetError() == GL_NO_ERROR);
    leave(r, &state);
}
static int compare(struct rediwm_scene_renderer *r, struct wlr_buffer *a, struct wlr_buffer *b) {
    uint8_t actual[WIDTH * HEIGHT * 4], expected[sizeof(actual)];
    read_pixels(r, a, actual);
    read_pixels(r, b, expected);
    int worst = 0;
    for (size_t i = 0; i < sizeof(actual); i++) {
        int d = abs(actual[i] - expected[i]);
        if (d > worst) worst = d;
    }
    return worst;
}
static void clear(struct wlr_render_pass *pass) {
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, WIDTH, HEIGHT}, .color = {.11, .23, .37, 1},
        .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
    });
}
// With a shape the owned pass draws through its shaped programs; wlroots' pass,
// which has no such thing, is always given NULL.
static void paint(struct wlr_render_pass *pass, struct wlr_texture *texture,
        int transform, int filter, int crop, float alpha, const pixman_region32_t *clip,
        const struct rediwm_pass_shape *shape) {
    struct wlr_render_rect_options rects[2] = {
        {.box = {8, -7, 49, 63}, .color = {.3, .06, .17, .5}, .clip = clip},
        {.box = {41, 29, 37, 53}, .color = {.1, .2, .05, .4}, .clip = clip},
    };
    struct wlr_render_texture_options t = {
        .texture = texture, .dst_box = {-3, 11, 112, 77},
        .src_box = crop ? (struct wlr_fbox){2.25, 3.5, 16.5, 11.25} : (struct wlr_fbox){0},
        .transform = transform, .filter_mode = filter, .alpha = &alpha, .clip = clip,
    };
    if (shape) rediwm_scene_pass_add_rect_shaped(pass, &rects[0], shape);
    else wlr_render_pass_add_rect(pass, &rects[0]);
    if (shape) rediwm_scene_pass_add_texture_shaped(pass, &t, shape);
    else wlr_render_pass_add_texture(pass, &t);
    if (shape) rediwm_scene_pass_add_rect_shaped(pass, &rects[1], shape);
    else wlr_render_pass_add_rect(pass, &rects[1]);
}
static struct wlr_texture *texture_create(struct wlr_renderer *renderer, bool opaque) {
    uint32_t pixels[TW * TH];
    for (int y = 0; y < TH; y++) for (int x = 0; x < TW; x++) {
        unsigned a = opaque ? (x * 47 + y * 19) % 256 : 80 + (x * 11 + y * 17) % 176;
        unsigned limit = opaque ? 256 : a + 1;
        pixels[y * TW + x] = a << 24 | ((x * 13 + y * 3) % limit) << 16 |
            ((x * 3 + y * 13) % limit) << 8 | ((x * 7 + y * 11) % limit);
    }
    struct wlr_texture *t = wlr_texture_from_pixels(renderer,
        opaque ? DRM_FORMAT_XRGB8888 : DRM_FORMAT_ARGB8888, TW * 4, TW, TH, pixels);
    assert(t);
    return t;
}
// `shaped` runs every case through the shaped programs, with a shape that covers
// the whole buffer and has no corners: it must still equal wlroots exactly.
static void parity(struct rediwm_scene_renderer *r, struct wlr_buffer *actual,
        struct wlr_buffer *expected, bool shaped) {
    const struct rediwm_pass_shape cover = {.box = {-50, -50, WIDTH + 100, HEIGHT + 100}};
    const struct rediwm_pass_shape *shape = shaped ? &cover : NULL;
    pixman_region32_t clip;
    pixman_region32_init_rect(&clip, -10, 8, 65, 31);
    pixman_region32_union_rect(&clip, &clip, 71, 43, 81, 80);
    int worst = 0, cases = 0;
    for (int opaque = 0; opaque < 2; opaque++) {
        struct wlr_texture *t = texture_create(r->renderer, opaque);
        for (int tr = 0; tr < 8; tr++) for (int filter = 0; filter < 2; filter++)
        for (int crop = 0; crop < 2; crop++) for (int partial = 0; partial < 2; partial++) {
            float alpha = partial ? .61 : 1;
            struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(r->renderer, expected, NULL);
            assert(pass);
            clear(pass);
            paint(pass, t, tr, filter, crop, alpha, partial ? &clip : NULL, NULL);
            assert(wlr_render_pass_submit(pass));
            pass = rediwm_scene_pass_begin(r, actual, NULL);
            assert(pass);
            clear(pass);
            paint(pass, t, tr, filter, crop, alpha, partial ? &clip : NULL, shape);
            assert(wlr_render_pass_submit(pass));
            int d = compare(r, actual, expected);
            if (d > 1) {
                fprintf(stderr, "parity: shaped=%d opaque=%d transform=%d filter=%d crop=%d partial=%d diff=%d\n",
                    shaped, opaque, tr, filter, crop, partial, d);
                abort();
            }
            if (d > worst) worst = d;
            cases++;
        }
        wlr_texture_destroy(t);
    }
    pixman_region32_fini(&clip);
    printf("PASS: %d texture/transform/crop/filter/alpha/damage cases%s (max difference %d)\n", cases,
        shaped ? " through the shaped programs" : "", worst);
}
// Before enable_shapes there are no shaped programs: a shaped draw must fail the
// pass at submit, not draw something else, and the next pass must work.
static void shapes_fail_closed(struct rediwm_scene_renderer *r, struct wlr_buffer *buffer) {
    const struct rediwm_pass_shape shape = {.box = {10, 10, 50, 50}, .radii = {5, 5, 5, 5}};
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(pass);
    rediwm_scene_pass_add_rect_shaped(pass, &(struct wlr_render_rect_options){
        .box = {10, 10, 50, 50}, .color = {1, 0, 0, 1}}, &shape);
    assert(!wlr_render_pass_submit(pass));
    pass = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(pass && wlr_render_pass_submit(pass));
    puts("PASS: a shaped draw before enable_shapes fails the pass and the next pass works");
}
static void damage(struct rediwm_scene_renderer *r, struct wlr_buffer *actual,
        struct wlr_buffer *expected) {
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, actual, NULL);
    assert(pass);
    clear(pass);
    assert(wlr_render_pass_submit(pass));
    uint8_t before[WIDTH * HEIGHT * 4], after[sizeof(before)];
    read_pixels(r, actual, before);
    pixman_region32_t clip;
    pixman_region32_init_rect(&clip, 11, 13, 23, 17);
    pixman_region32_union_rect(&clip, &clip, 71, 60, 13, 19);
    struct wlr_texture *t = texture_create(r->renderer, false);
    pass = rediwm_scene_pass_begin(r, actual, NULL);
    assert(pass);
    paint(pass, t, 3, 0, 1, .73, &clip, NULL);
    assert(wlr_render_pass_submit(pass));
    read_pixels(r, actual, after);
    int changed = 0;
    for (int y = 0; y < HEIGHT; y++) for (int x = 0; x < WIDTH; x++) {
        bool same = memcmp(&before[4 * (y * WIDTH + x)], &after[4 * (y * WIDTH + x)], 4) == 0;
        if (!pixman_region32_contains_point(&clip, x, y, NULL)) assert(same);
        else changed += !same;
    }
    assert(changed > 0);
    // An empty damage region must not paint anything, even after a prior clip.
    pixman_region32_clear(&clip);
    pass = rediwm_scene_pass_begin(r, actual, NULL);
    assert(pass);
    paint(pass, t, 1, 1, 0, 1, &clip, NULL);
    assert(wlr_render_pass_submit(pass));
    read_pixels(r, actual, before);
    assert(memcmp(before, after, sizeof(before)) == 0);
    // NONE must replace rather than alpha blend, on both texture and rect paths.
    for (int owned = 0; owned < 2; owned++) {
        pass = owned ? rediwm_scene_pass_begin(r, actual, NULL) :
            wlr_renderer_begin_buffer_pass(r->renderer, expected, NULL);
        assert(pass);
        clear(pass);
        wlr_render_pass_add_texture(pass, &(struct wlr_render_texture_options){
            .texture = t, .dst_box = {17, 19, TW, TH}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
        });
        wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
            .box = {71, 8, 11, 13}, .color = {.1, .2, .1, .3}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
        });
        assert(wlr_render_pass_submit(pass));
    }
    assert(compare(r, actual, expected) <= 1);
    wlr_texture_destroy(t);
    pixman_region32_fini(&clip);
    puts("PASS: disjoint and empty damage preserve untouched pixels; disabled blending matches wlroots");
}
static void state_restoration(struct rediwm_scene_renderer *r, struct wlr_buffer *buffer) {
    struct gl_state original;
    assert(enter(r, &original));
    GLuint vbo, textures[2], caller_vao = 0;
    if (r->has_vao) {
        r->gen_vertex_arrays(1, &caller_vao);
        r->bind_vertex_array(caller_vao);
    }
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, 128, NULL, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 16, (void *)4);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1, 2, GL_SHORT, GL_TRUE, 8, (void *)16);
    glDisableVertexAttribArray(1);
    glGenTextures(2, textures);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, textures[0]);
    glActiveTexture(GL_TEXTURE3);
    glBindTexture(GL_TEXTURE_2D, textures[1]);
    glViewport(7, 9, 53, 41);
    glScissor(2, 3, 19, 23);
    glEnable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE, GL_ZERO, GL_ONE_MINUS_SRC_ALPHA);
    glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT, GL_FUNC_SUBTRACT);
    struct gl_state before = {0}, after = {0};
    assert(enter(r, &before));
    leave(r, &before);
    struct wlr_texture *t = texture_create(r->renderer, false);
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(pass);
    assert(!rediwm_scene_pass_begin(r, buffer, NULL)); // no nested owned passes
    clear(pass);
    paint(pass, t, 1, 0, 1, .5, NULL, NULL);
    assert(wlr_render_pass_submit(pass));
    assert(enter(r, &after));
    leave(r, &after);
    assert(memcmp(&before, &after, sizeof(before)) == 0);
    GLint value;
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &value);
    assert(value == (GLint)vbo);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &value);
    assert(value == 3);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &value);
    assert(value == 16);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_SIZE, &value);
    assert(value == 2);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_TYPE, &value);
    assert(value == GL_SHORT);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &value);
    assert(!value);
    assert(glGetError() == GL_NO_ERROR);
    wlr_texture_destroy(t);
    glDeleteBuffers(1, &vbo);
    glDeleteTextures(2, textures);
    if (caller_vao) r->delete_vertex_arrays(1, &caller_vao);
    leave(r, &original);
    puts("PASS: GL bindings, attributes, blend/scissor/viewport and EGL context restored");
}
static void external_texture(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator,
        struct wlr_buffer *actual, struct wlr_buffer *expected) {
    if (!r->has_external) { puts("SKIP: external-OES unavailable"); return; }
    struct wlr_buffer *source = target(allocator);
    struct wlr_texture *pattern = texture_create(r->renderer, false);
    struct wlr_render_pass *base = wlr_renderer_begin_buffer_pass(r->renderer, source, NULL);
    assert(base);
    clear(base);
    paint(base, pattern, 0, 1, 0, 1, NULL, NULL);
    assert(wlr_render_pass_submit(base));
    wlr_texture_destroy(pattern);
    struct wlr_texture *reference = wlr_texture_from_buffer(r->renderer, source);
    assert(reference);
    struct wlr_dmabuf_attributes dma;
    assert(wlr_buffer_get_dmabuf(source, &dma) && dma.n_planes == 1);
    EGLint attrs[32] = {EGL_WIDTH, dma.width, EGL_HEIGHT, dma.height,
        EGL_LINUX_DRM_FOURCC_EXT, dma.format, EGL_DMA_BUF_PLANE0_FD_EXT, dma.fd[0],
        EGL_DMA_BUF_PLANE0_OFFSET_EXT, dma.offset[0], EGL_DMA_BUF_PLANE0_PITCH_EXT, dma.stride[0]};
    int n = 12;
    if (dma.modifier != DRM_FORMAT_MOD_INVALID) {
        attrs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
        attrs[n++] = dma.modifier & UINT32_MAX;
        attrs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
        attrs[n++] = dma.modifier >> 32;
    }
    attrs[n] = EGL_NONE;
    PFNEGLCREATEIMAGEKHRPROC create_image = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    PFNEGLDESTROYIMAGEKHRPROC destroy_image = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC bind_image =
        (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    assert(create_image && destroy_image && bind_image);
    struct gl_state state;
    assert(enter(r, &state));
    EGLImageKHR image = create_image(state.display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
    assert(image != EGL_NO_IMAGE_KHR);
    struct wlr_gles2_texture_attribs a = {.target = GL_TEXTURE_EXTERNAL_OES, .has_alpha = true};
    glGenTextures(1, &a.tex);
    glBindTexture(a.target, a.tex);
    bind_image(a.target, image);
    glTexParameteri(a.target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(a.target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    leave(r, &state);
    for (int tr = 0; tr < 8; tr++) for (int filter = 0; filter < 2; filter++) {
        float alpha = .73;
        struct wlr_render_texture_options o = {
            .texture = reference, .src_box = {4.25, 8.5, 107.5, 71.25},
            .dst_box = {7, 9, 111, 79}, .transform = tr, .filter_mode = filter, .alpha = &alpha,
        };
        base = wlr_renderer_begin_buffer_pass(r->renderer, expected, NULL);
        assert(base);
        clear(base);
        wlr_render_pass_add_texture(base, &o);
        assert(wlr_render_pass_submit(base));
        base = rediwm_scene_pass_begin(r, actual, NULL);
        assert(base);
        clear(base);
        struct pass *p = wl_container_of(base, p, base);
        // Force a real external EGLImage through the same draw routine; this
        // driver's normal import of an RGB dmabuf chooses a 2D target.
        texture_draw(p, &o, a, NULL);
        assert(wlr_render_pass_submit(base));
        assert(compare(r, actual, expected) <= 1);
        // The shaped external program with a cover-everything shape is the same draw.
        const struct rediwm_pass_shape cover = {.box = {-50, -50, WIDTH + 100, HEIGHT + 100}};
        base = rediwm_scene_pass_begin(r, actual, NULL);
        assert(base);
        clear(base);
        p = wl_container_of(base, p, base);
        texture_draw(p, &o, a, &cover);
        assert(wlr_render_pass_submit(base));
        assert(compare(r, actual, expected) <= 1);
        // And through a rounded, bordered shape the external texture equals the 2D
        // one of the same pixels: the clip does not depend on the sampler.
        const struct rediwm_pass_shape round = {.box = {12, 14, 100, 70},
            .radii = {18, 9, 25.5f, 3}, .border = 2, .border_color = {.5f, .1f, .1f, .5f}};
        base = rediwm_scene_pass_begin(r, expected, NULL);
        assert(base);
        clear(base);
        rediwm_scene_pass_add_texture_shaped(base, &o, &round);
        assert(wlr_render_pass_submit(base));
        base = rediwm_scene_pass_begin(r, actual, NULL);
        assert(base);
        clear(base);
        p = wl_container_of(base, p, base);
        texture_draw(p, &o, a, &round);
        assert(wlr_render_pass_submit(base));
        assert(compare(r, actual, expected) <= 1);
        // Two blank images would also match: the corner must be cut, the middle drawn.
        uint8_t shown[WIDTH * HEIGHT * 4];
        read_pixels(r, actual, shown);
        assert(memcmp(&shown[4 * (15 * WIDTH + 13)], &shown[0], 4) == 0);
        assert(memcmp(&shown[4 * (50 * WIDTH + 60)], &shown[0], 4) != 0);
    }
    assert(enter(r, &state));
    glDeleteTextures(1, &a.tex);
    destroy_image(state.display, image);
    leave(r, &state);
    wlr_texture_destroy(reference);
    wlr_buffer_drop(source);
    puts("PASS: external-OES EGLImage matches wlroots across all transforms and filters, plain and shaped");
}
// Driver-converted YUV. A linear NV12 dmabuf is imported by wlroots exactly as a
// video client's would be. Mesa reports it external-only, so both passes must
// sample it through samplerExternalOES and leave the YUV->RGB conversion to the
// driver. Mesa's gbm cannot allocate NV12, so a linear R8 buffer 1.5x as tall is
// described as two planes of one dmabuf (chroma on a page boundary), as a video
// client would send it. This covers the external program with real YUV; it does
// not cover other drivers' conversion or any tiled/compressed modifier.
static void external_yuv(struct rediwm_scene_renderer *r, struct wlr_buffer *actual,
        struct wlr_buffer *expected) {
    enum { YW = 64, YH = 64 };
    if (!r->has_external) { puts("SKIP: external-OES unavailable"); return; }
    int drm_fd = wlr_renderer_get_drm_fd(r->renderer);
    struct gbm_device *gbm = drm_fd >= 0 ? gbm_create_device(drm_fd) : NULL;
    struct gbm_bo *bo = gbm ? gbm_bo_create(gbm, YW, YH * 3 / 2, GBM_FORMAT_R8, GBM_BO_USE_LINEAR) : NULL;
    if (!bo || gbm_bo_get_modifier(bo) != DRM_FORMAT_MOD_LINEAR) {
        puts("SKIP: gbm cannot allocate a linear buffer for NV12");
        if (bo) gbm_bo_destroy(bo);
        if (gbm) gbm_device_destroy(gbm);
        return;
    }
    uint32_t stride = gbm_bo_get_stride(bo);
    struct wlr_dmabuf_attributes dma = {.width = YW, .height = YH, .format = DRM_FORMAT_NV12,
        .modifier = DRM_FORMAT_MOD_LINEAR, .n_planes = 2,
        .offset = {0, stride * YH}, .stride = {stride, stride}};
    assert(dma.offset[1] % 4096 == 0);
    for (int i = 0; i < 2; i++) {
        dma.fd[i] = gbm_bo_get_fd(bo);
        assert(dma.fd[i] >= 0);
    }
    size_t length = dma.offset[1] + (size_t)dma.stride[1] * (YH / 2);
    uint8_t *map = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, dma.fd[0], 0);
    assert(map != MAP_FAILED);
    struct dma_buf_sync sync = {.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE};
    ioctl(dma.fd[0], DMA_BUF_IOCTL_SYNC, &sync);
    for (int y = 0; y < YH; y++) for (int x = 0; x < YW; x++)
        map[dma.offset[0] + y * dma.stride[0] + x] = 16 + (x * 3 + y * 5) % 220;
    for (int y = 0; y < YH / 2; y++) for (int x = 0; x < YW / 2; x++) {
        uint8_t *uv = &map[dma.offset[1] + y * dma.stride[1] + 2 * x];
        uv[0] = 32 + (x * 11 + y * 3) % 192;
        uv[1] = 32 + (x * 5 + y * 13) % 192;
    }
    sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE;
    ioctl(dma.fd[0], DMA_BUF_IOCTL_SYNC, &sync);
    munmap(map, length);
    struct wlr_texture *texture = wlr_texture_from_dmabuf(r->renderer, &dma);
    struct wlr_gles2_texture_attribs a = {0};
    if (texture) wlr_gles2_texture_get_attribs(texture, &a);
    if (!texture || a.target != GL_TEXTURE_EXTERNAL_OES) {
        puts(texture ? "SKIP: driver imports NV12 as GL_TEXTURE_2D" : "SKIP: renderer cannot import linear NV12");
    } else {
        assert(!a.has_alpha);
        float alpha = .81f;
        for (int tr = 0; tr < 8; tr++) for (int filter = 0; filter < 2; filter++) {
            struct wlr_render_texture_options o = {
                .texture = texture, .src_box = {2.25, 3.5, 40.5, 30.25},
                .dst_box = {7, 9, 111, 79}, .transform = tr, .filter_mode = filter, .alpha = &alpha,
            };
            struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(r->renderer, expected, NULL);
            assert(pass);
            clear(pass);
            wlr_render_pass_add_texture(pass, &o);
            assert(wlr_render_pass_submit(pass));
            pass = rediwm_scene_pass_begin(r, actual, NULL);
            assert(pass);
            clear(pass);
            wlr_render_pass_add_texture(pass, &o);
            assert(wlr_render_pass_submit(pass));
            assert(compare(r, actual, expected) <= 1);
        }
        // Parity with a blank image would prove nothing: the video must have drawn.
        uint8_t pixels[WIDTH * HEIGHT * 4];
        read_pixels(r, actual, pixels);
        int drawn = 0;
        for (size_t i = 0; i < sizeof(pixels); i += 4)
            if (abs(pixels[i] - 28) > 8 || abs(pixels[i + 1] - 59) > 8 || abs(pixels[i + 2] - 94) > 8) drawn++;
        assert(drawn > 4000);
        puts("PASS: external-only NV12 dmabuf matches wlroots across all transforms and filters");
    }
    if (texture) wlr_texture_destroy(texture);
    wlr_dmabuf_attributes_finish(&dma);
    gbm_bo_destroy(bo);
    gbm_device_destroy(gbm);
}
static void synchronization(struct rediwm_scene_renderer *r, struct wlr_buffer *buffer) {
    if (!r->has_sync) { puts("SKIP: renderer timelines unavailable"); return; }
    struct wlr_drm_syncobj_timeline *timeline =
        wlr_drm_syncobj_timeline_create(wlr_renderer_get_drm_fd(r->renderer));
    assert(timeline);
    assert(wlr_drm_syncobj_timeline_signal(timeline, 1));
    struct wlr_texture *t = texture_create(r->renderer, false);
    struct wlr_render_pass *base = rediwm_scene_pass_begin(r, buffer,
        &(struct wlr_buffer_pass_options){.signal_timeline = timeline, .signal_point = 2});
    assert(base);
    clear(base);
    wlr_render_pass_add_texture(base, &(struct wlr_render_texture_options){
        .texture = t, .dst_box = {7, 9, TW, TH}, .wait_timeline = timeline, .wait_point = 1,
    });
    assert(wlr_render_pass_submit(base));
    uint8_t pixels[WIDTH * HEIGHT * 4];
    read_pixels(r, buffer, pixels); // finish the submitted GPU work before querying
    bool signaled = false;
    assert(wlr_drm_syncobj_timeline_check(timeline, 2, DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT, &signaled));
    assert(signaled);
    base = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(base);
    // A point that has never materialized must fail closed, without sampling.
    wlr_render_pass_add_texture(base, &(struct wlr_render_texture_options){
        .texture = t, .wait_timeline = timeline, .wait_point = 99,
    });
    assert(!wlr_render_pass_submit(base));
    // Failure released the destination lock and the renderer's active pass.
    base = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(base && wlr_render_pass_submit(base));
    wlr_texture_destroy(t);
    wlr_drm_syncobj_timeline_unref(timeline);
    puts("PASS: acquire/release timeline points and recovery from unavailable acquire");
}

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
    assert(enter(r, &state));
    img->w = b->width;
    img->h = b->height;
    img->p = realloc(img->p, 4 * (size_t)img->w * img->h);
    glBindFramebuffer(GL_FRAMEBUFFER, wlr_gles2_renderer_get_buffer_fbo(r->renderer, b));
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, img->w, img->h, GL_RGBA, GL_UNSIGNED_BYTE, img->p);
    assert(glGetError() == GL_NO_ERROR);
    leave(r, &state);
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

// ---- Gate 5: the opaque cover of the model is fully covered in real pixels -------------
// rediwm_clip_opaque promises its rectangles are inside full coverage; the output
// pass will draw them without blending and trust that. Painting them first with
// blending off, then the whole window over them, must change nothing.
static void gate_opaque_cover(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
        struct image *img, struct image *ref) {
    for (size_t si = 0; si < COUNT(SCALES); si++) for (size_t zi = 0; zi < COUNT(ZOOMS); zi++) {
        struct window w = make_window(SCALES[si], ZOOMS[zi], 10, 1);
        struct rediwm_pass_shape s = w.shape;
        memcpy(s.border_color, BODY, sizeof(BODY));
        struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
        piece(pass, &s, s.box, BODY, NULL);
        finish(pass);
        read_image(r, buf, ref);
        // Border colour equals the body's here, so the cover may include the ring.
        struct rediwm_snap cover[3];
        int n = rediwm_clip_opaque(&w.clip, cover);
        check(n > 0, "no opaque cover at scale %.2f zoom %.2f", SCALES[si], ZOOMS[zi]);
        pass = begin_fill(r, buf, BG, NULL);
        for (int i = 0; i < n; i++)
            wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
                .box = box_of(cover[i]), .color = {BODY[0], BODY[1], BODY[2], 1},
                .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
        piece(pass, &s, s.box, BODY, NULL);
        finish(pass);
        read_image(r, buf, img);
        for (int i = 0; i < img->w * img->h * 4; i++)
            check(diff(img->p[i], ref->p[i]) <= 1, "cover pixel differs at scale %.2f zoom %.2f (%d vs %d)",
                SCALES[si], ZOOMS[zi], img->p[i], ref->p[i]);
    }
    puts("PASS: the opaque cover draws without blending and changes nothing, at every scale and zoom");
}

// ---- Gate 6: analytic shadow ------------------------------------------------------------
// The CPU chrome's shadow (chrome.zig: ShadowBuffer.rasterize, shadowCoverage,
// edgeCoverage) at one pixel: smoothstep falloff from the moved shape, cut out of
// the unmoved one with a one-pixel ramp. Every pixel is compared, corners too.
static double cpu_shadow(double px, double py, const struct rediwm_pass_shape *s, double oy, double softness) {
    const double radii[4] = {s->radii[0], s->radii[1], s->radii[2], s->radii[3]};
    const double d = rediwm_sd_rounded_box(px, py, s->box.x, s->box.y + oy, s->box.width, s->box.height, radii);
    const double frame_d = rediwm_sd_rounded_box(px, py, s->box.x, s->box.y, s->box.width, s->box.height, radii);
    double t = 1 - d / softness;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    double inside = .5 - frame_d;
    inside = inside < 0 ? 0 : inside > 1 ? 1 : inside;
    return t * t * (3 - 2 * t) * (1 - inside);
}
static void gate_shadow(struct rediwm_scene_renderer *r, struct wlr_buffer *buf, struct image *img) {
    const float white[4] = {1, 1, 1, 1};
    // The default theme: radius 10, softness 24, offset 8, at scale 1 and 1.5.
    const float scales[] = {1, 1.5f};
    int worst = 0;
    for (int si = 0; si < 2; si++) {
        const float k = scales[si];
        const float softness = 24 * k, oy = roundf(8 * k), radius = 10 * k;
        const struct rediwm_pass_shape s = {.box = {80, 60, 200, 120}, .radii = {radius, radius, radius, radius}};
        struct wlr_render_pass *pass = begin_fill(r, buf, white, NULL);
        rediwm_scene_pass_add_shadow(pass, &s, &(struct rediwm_pass_shadow){
            .offset_y = oy, .softness = softness, .color = {0, 0, 0, .5f}, .hide_inside = true});
        finish(pass);
        read_image(r, buf, img);
        for (int y = 0; y < img->h; y++)
            for (int x = 0; x < img->w; x++) {
                const int want = (int)lround(255 * (1 - .5 * cpu_shadow(x + .5, y + .5, &s, oy, softness)));
                const int got = at(img, x, y)[0];
                if (diff(got, want) > worst) worst = diff(got, want);
            }
        const int cx = s.box.x + s.box.width / 2, bottom = s.box.y + s.box.height;
        int last = 255;
        for (int dy = (int)oy; dy < 60; dy++) {
            const int got = at(img, cx, bottom + dy)[0];
            check(got >= last || dy == (int)oy, "shadow is not monotonic at %d px (%d after %d)", dy, got, last);
            last = got;
        }
        check(at(img, 10, 10)[0] == 255 && at(img, cx, s.box.y + s.box.height / 2)[0] == 255,
            "shadow reaches outside its footprint or inside the window");
    }
    check(worst <= 1, "shadow differs from the CPU chrome's by %d levels", worst);
    // Not hidden inside: the same draw shows through the window.
    const struct rediwm_pass_shape s = {.box = {80, 60, 200, 120}};
    struct wlr_render_pass *pass = begin_fill(r, buf, white, NULL);
    rediwm_scene_pass_add_shadow(pass, &s, &(struct rediwm_pass_shadow){
        .offset_y = 6, .softness = 24, .color = {0, 0, 0, .5f}});
    finish(pass);
    read_image(r, buf, img);
    check(at(img, s.box.x + s.box.width / 2, s.box.y + s.box.height / 2)[0] < 200,
        "an unhidden shadow does not show under the shape");
    printf("PASS: analytic shadow equals the CPU chrome's at every pixel, corners included (max diff %d), "
        "and stays out of the window\n", worst);
}

// ---- Gate 7: a partial repaint across a clip edge equals a full repaint -----------------
static void draw_scene(struct rediwm_scene_renderer *r, struct wlr_buffer *buf, const struct window *w,
        int variant, const pixman_region32_t *clip) {
    const float bodies[2][3][4] = {
        {{.2f, .3f, .5f, 1}, {.9f, .9f, .9f, 1}, {.3f, .3f, .3f, 1}},
        {{.8f, .2f, .2f, 1}, {.1f, .6f, .2f, 1}, {.6f, .6f, .1f, 1}},
    };
    struct rediwm_pass_shape s = w->shape;
    const float rings[2][4] = {{1, 1, 1, 1}, {1, 0, 0, 1}};
    memcpy(s.border_color, rings[variant], sizeof(rings[variant]));
    struct wlr_render_pass *pass = begin_fill(r, buf, BG, clip);
    rediwm_scene_pass_add_shadow(pass, &s, &(struct rediwm_pass_shadow){
        .offset_y = 12, .softness = 24,
        .color = {0, 0, 0, .4f}, .hide_inside = true, .clip = clip});
    piece(pass, &s, w->title, bodies[variant][0], clip);
    piece(pass, &s, w->client, bodies[variant][1], clip);
    piece(pass, &s, w->footer, bodies[variant][2], clip);
    finish(pass);
}
static void gate_damage_at_clip_edge(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator,
        struct image *img) {
    struct wlr_buffer *a = target_sized(allocator, GW, GH), *b = target_sized(allocator, GW, GH),
        *c = target_sized(allocator, GW, GH);
    struct image one = {0}, two = {0};
    int differing_inside = 0, differing_outside = 0;
    const float zooms[] = {1.f, .55f};
    for (size_t si = 0; si < COUNT(SCALES); si++) for (size_t zi = 0; zi < COUNT(zooms); zi++) {
        struct window w = make_window(SCALES[si], zooms[zi], 10, 1);
        const struct wlr_box *bx = &w.shape.box;
        // Damage whose edges cut through the corner arcs, the ring and the shadow:
        // a square over the top-left arc, one over the bottom-right, and a band.
        pixman_region32_t damage;
        pixman_region32_init_rect(&damage, bx->x - 5, bx->y - 5, 13, 13);
        pixman_region32_union_rect(&damage, &damage, bx->x + bx->width - 9, bx->y + bx->height - 11, 30, 29);
        pixman_region32_union_rect(&damage, &damage, bx->x + bx->width / 3, bx->y + 3, 7, bx->height + 20);
        draw_scene(r, a, &w, 0, NULL);
        draw_scene(r, b, &w, 1, NULL);
        draw_scene(r, c, &w, 0, NULL);
        draw_scene(r, c, &w, 1, &damage);
        read_image(r, a, &one);
        read_image(r, b, &two);
        read_image(r, c, img);
        for (int y = 0; y < GH; y++) for (int x = 0; x < GW; x++) {
            bool in = pixman_region32_contains_point(&damage, x, y, NULL);
            const uint8_t *want = at(in ? &two : &one, x, y);
            for (int ch = 0; ch < 4; ch++)
                check(at(img, x, y)[ch] == want[ch],
                    "partial repaint differs at (%d,%d) channel %d (%s damage): %d, wanted %d (scale %.2f)",
                    x, y, ch, in ? "inside" : "outside", at(img, x, y)[ch], want[ch], SCALES[si]);
            if (memcmp(at(&one, x, y), at(&two, x, y), 4)) in ? differing_inside++ : differing_outside++;
        }
        pixman_region32_fini(&damage);
    }
    // The control: the two frames really differ both where the damage is and where it is not.
    check(differing_inside > 0 && differing_outside > 0, "the test frames do not differ across the damage edge");
    free(one.p);
    free(two.p);
    wlr_buffer_drop(a);
    wlr_buffer_drop(b);
    wlr_buffer_drop(c);
    puts("PASS: repainting only damage that cuts through arcs, ring and shadow equals a full repaint");
}

static void shaped_gates(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator) {
    struct wlr_buffer *buf = target_sized(allocator, GW, GH);
    struct image img = {0}, ref = {0};
    gate_clip_accuracy(r, buf, &img);
    gate_no_seams(r, buf, &img);
    gate_border_partition(r, buf, &img, &ref);
    gate_premultiplied(r, buf, &img);
    gate_opaque_cover(r, buf, &img, &ref);
    gate_shadow(r, buf, &img);
    gate_damage_at_clip_edge(r, allocator, &img);
    free(img.p);
    free(ref.p);
    wlr_buffer_drop(buf);
}
// ---- Stage 5b: backdrops ------------------------------------------------------------
static struct wlr_buffer *target_format(struct wlr_allocator *allocator, int w, int h, uint32_t fmt) {
    uint64_t modifier = DRM_FORMAT_MOD_INVALID;
    struct wlr_drm_format format = {.format = fmt, .len = 1, .capacity = 1, .modifiers = &modifier};
    struct wlr_buffer *b = wlr_allocator_create_buffer(allocator, w, h, &format);
    assert(b);
    return b;
}
static const float BANDS[5][4] = {{1, 0, 0, 1}, {0, .8f, 0, 1}, {0, 0, 1, 1}, {1, 1, 1, 1}, {.1f, .1f, .1f, 1}};
// Vertical bands 40 px wide, then a backdrop of `region` composited over `box`.
static struct rediwm_backdrop *draw_backdrop(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
        struct rediwm_backdrop *b, struct wlr_box region, struct wlr_box box, float sigma,
        const struct rediwm_pass_backdrop *opts, const pixman_region32_t *clip) {
    struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
    for (int x = 0, i = 0; x < buf->width; x += 40, i++)
        wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
            .box = {x, 0, 40, buf->height}, .color = {BANDS[i % 5][0], BANDS[i % 5][1], BANDS[i % 5][2], 1}});
    rediwm_scene_pass_capture_backdrop(pass, &b, region, sigma);
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
    const float sigma = 16;
    const struct wlr_box region = {100, 100, 400, 200}, box = {148, 148, 304, 104};
    int worst = 0;
    for (int f = 0; f < 2; f++) {
        struct wlr_buffer *buf = target_format(allocator, GW, GH, f ? DRM_FORMAT_XRGB8888 : DRM_FORMAT_ARGB8888);
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
                    if (d > worst) worst = d;
                }
        }
        rediwm_scene_renderer_destroy_backdrop(r, b);
        wlr_buffer_drop(buf);
    }
    check(worst <= 6, "the quarter-size blur differs from the exact Gaussian by %d levels", worst);
    printf("PASS: backdrop blur within %d levels of the exact Gaussian, ARGB and XRGB buffers\n", worst);
}
static void gate_backdrop_properties(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator, struct image *img) {
    struct wlr_buffer *buf = target_sized(allocator, GW, GH);
    struct rediwm_backdrop *b = NULL;
    // A red/blue step at x = 320 blurs to an even mix there, monotonic across,
    // unchanged far from it.
    struct wlr_render_pass *pass = begin_fill(r, buf, (float[4]){1, 0, 0, 1}, NULL);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){.box = {320, 0, 320, GH}, .color = {0, 0, 1, 1}});
    const struct wlr_box region = {120, 100, 400, 200}, box = {168, 148, 304, 104};
    rediwm_scene_pass_capture_backdrop(pass, &b, region, 16);
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
    rediwm_scene_pass_capture_backdrop(pass, &b, edge_region, 16);
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = edge_box}, edge_box,
        &(struct rediwm_pass_backdrop){.backdrop = b, .saturation = 1, .opacity = 1});
    finish(pass);
    read_image(r, buf, img);
    for (int x = 0; x < 92; x++)
        check(at(img, x, 200)[1] >= 253 && at(img, x, 200)[0] <= 2, "the buffer edge darkens the blur at %d", x);
    // Saturation as glass.c applies it, on a uniform colour the blur keeps.
    const float c[3] = {.2f, .4f, .6f};
    pass = begin_fill(r, buf, (float[4]){c[0], c[1], c[2], 1}, NULL);
    rediwm_scene_pass_capture_backdrop(pass, &b, region, 16);
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
    rediwm_scene_pass_capture_backdrop(pass, &b, region, 8);
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
    rediwm_scene_pass_capture_backdrop(pass, &b, region, 8);
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
static void backdrop_gates(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator) {
    struct image img = {0};
    gate_backdrop_blur(r, allocator, &img);
    gate_backdrop_properties(r, allocator, &img);
    gate_backdrop_front(r, allocator, &img);
    free(img.p);
}
int main(void) {
    wlr_log_init(WLR_ERROR, NULL);
    struct wl_display *display = wl_display_create();
    assert(display);
    struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(display));
    assert(backend);
    struct wlr_renderer *renderer = wlr_renderer_autocreate(backend);
    assert(renderer && wlr_renderer_is_gles2(renderer));
    struct wlr_allocator *allocator = wlr_allocator_autocreate(backend, renderer);
    assert(allocator);
    struct rediwm_scene_renderer *r = rediwm_scene_renderer_create(renderer);
    assert(r);
    struct wlr_buffer *actual = target(allocator), *expected = target(allocator);
    parity(r, actual, expected, false);
    shapes_fail_closed(r, actual);
    assert(rediwm_scene_renderer_enable_shapes(r));
    assert(rediwm_scene_renderer_enable_shapes(r)); // idempotent
    parity(r, actual, expected, true);
    damage(r, actual, expected);
    state_restoration(r, actual);
    external_texture(r, allocator, actual, expected);
    external_yuv(r, actual, expected);
    synchronization(r, actual);
    shaped_gates(r, allocator);
    assert(rediwm_scene_renderer_enable_backdrops(r));
    assert(rediwm_scene_renderer_enable_backdrops(r)); // idempotent
    backdrop_gates(r, allocator);
    // The ordinary wlroots pass must still work after owned GL has run.
    parity(r, actual, expected, false);
    if (r->has_vao) {
        // Exercise the GLES2 fallback even on hosts with vertex arrays.
        r->has_vao = false;
        parity(r, actual, expected, false);
        parity(r, actual, expected, true);
        state_restoration(r, actual);
        r->has_vao = true;
    }
    rediwm_scene_renderer_destroy(r);
    wlr_buffer_drop(actual);
    wlr_buffer_drop(expected);
    wlr_allocator_destroy(allocator);
    wlr_renderer_destroy(renderer);
    wlr_backend_destroy(backend);
    wl_display_destroy(display);
    puts("scene pass gates passed");
    return 0;
}
