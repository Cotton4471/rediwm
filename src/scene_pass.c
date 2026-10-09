// Stage 3 drawing backend. No output, scene traversal or geometry policy here.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "scene_pass.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <assert.h>
#include <stdlib.h>
#include <unistd.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/render/egl.h>
#include <wlr/render/gles2.h>
#include <wlr/render/interface.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/util/log.h>

struct program {
    GLuint id;
    GLint target, dst, color, alpha, opaque, sampler, coords;
};
struct attrib_state {
    GLint enabled, size, type, normalized, stride, buffer;
    void *pointer;
};
struct gl_state {
    EGLDisplay display, previous_display;
    EGLContext context;
    EGLSurface draw, read;
    GLint fbo, program, array_buffer, vertex_array, active_texture, texture, external;
    GLint viewport[4], scissor_box[4];
    GLint src_rgb, dst_rgb, src_alpha, dst_alpha, equation_rgb, equation_alpha;
    GLboolean blend, scissor;
    struct attrib_state attrib;
};
struct rediwm_scene_renderer {
    struct wlr_renderer *renderer;
    struct program solid, texture, external;
    bool active, has_external, has_sync, has_vao;
    GLuint vertex_array, vertices;
    PFNGLGENVERTEXARRAYSOESPROC gen_vertex_arrays;
    PFNGLBINDVERTEXARRAYOESPROC bind_vertex_array;
    PFNGLDELETEVERTEXARRAYSOESPROC delete_vertex_arrays;
    PFNEGLCREATESYNCKHRPROC create_sync;
    PFNEGLDESTROYSYNCKHRPROC destroy_sync;
    PFNEGLWAITSYNCKHRPROC wait_sync;
    PFNEGLDUPNATIVEFENCEFDANDROIDPROC dup_fence;
};
struct pass {
    struct wlr_render_pass base;
    struct rediwm_scene_renderer *renderer;
    struct wlr_buffer *buffer;
    struct gl_state state;
    struct wlr_drm_syncobj_timeline *signal_timeline;
    uint64_t signal_point;
    bool failed;
    GLuint program;
    unsigned targets_set;
    int blend_mode;
};

static bool enter(struct rediwm_scene_renderer *r, struct gl_state *s) {
    struct wlr_egl *egl = wlr_gles2_renderer_get_egl(r->renderer);
    s->display = wlr_egl_get_display(egl);
    s->previous_display = eglGetCurrentDisplay();
    s->context = eglGetCurrentContext();
    s->draw = eglGetCurrentSurface(EGL_DRAW);
    s->read = eglGetCurrentSurface(EGL_READ);
    if (!eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
            wlr_egl_get_context(egl))) return false;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &s->fbo);
    glGetIntegerv(GL_CURRENT_PROGRAM, &s->program);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &s->array_buffer);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &s->active_texture);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &s->texture);
    if (r->has_external) glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &s->external);
    glGetIntegerv(GL_VIEWPORT, s->viewport);
    glGetIntegerv(GL_SCISSOR_BOX, s->scissor_box);
    glGetIntegerv(GL_BLEND_SRC_RGB, &s->src_rgb);
    glGetIntegerv(GL_BLEND_DST_RGB, &s->dst_rgb);
    glGetIntegerv(GL_BLEND_SRC_ALPHA, &s->src_alpha);
    glGetIntegerv(GL_BLEND_DST_ALPHA, &s->dst_alpha);
    glGetIntegerv(GL_BLEND_EQUATION_RGB, &s->equation_rgb);
    glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &s->equation_alpha);
    s->blend = glIsEnabled(GL_BLEND);
    s->scissor = glIsEnabled(GL_SCISSOR_TEST);
    if (r->has_vao) {
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING_OES, &s->vertex_array);
    } else {
        struct attrib_state *a = &s->attrib;
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &a->enabled);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &a->size);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_TYPE, &a->type);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &a->normalized);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &a->stride);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &a->buffer);
        glGetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER, &a->pointer);
    }
    return true;
}
static void leave(struct rediwm_scene_renderer *r, struct gl_state *s) {
    if (r->has_vao) {
        r->bind_vertex_array(s->vertex_array);
    } else {
        const struct attrib_state *a = &s->attrib;
        glBindBuffer(GL_ARRAY_BUFFER, a->buffer);
        glVertexAttribPointer(0, a->size, a->type, a->normalized, a->stride, a->pointer);
        (a->enabled ? glEnableVertexAttribArray : glDisableVertexAttribArray)(0);
    }
    glBindBuffer(GL_ARRAY_BUFFER, s->array_buffer);
    glBindFramebuffer(GL_FRAMEBUFFER, s->fbo);
    glUseProgram(s->program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, s->texture);
    if (r->has_external) glBindTexture(GL_TEXTURE_EXTERNAL_OES, s->external);
    glActiveTexture(s->active_texture);
    glViewport(s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3]);
    glScissor(s->scissor_box[0], s->scissor_box[1], s->scissor_box[2], s->scissor_box[3]);
    glBlendFuncSeparate(s->src_rgb, s->dst_rgb, s->src_alpha, s->dst_alpha);
    glBlendEquationSeparate(s->equation_rgb, s->equation_alpha);
    (s->blend ? glEnable : glDisable)(GL_BLEND);
    (s->scissor ? glEnable : glDisable)(GL_SCISSOR_TEST);
    if (s->previous_display != EGL_NO_DISPLAY)
        eglMakeCurrent(s->previous_display, s->draw, s->read, s->context);
    else
        eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

static const char vertex[] =
    "attribute vec2 position; uniform vec2 target; uniform vec4 dst, coords[2];"
    // Select the exact supplied corner, avoiding cancellation in a UV matrix
    // at nearest-filter half-texel boundaries. Only four vertices run this.
    "varying vec2 uv; void main(){ vec4 row=position.y<.5?coords[0]:coords[1];"
    "uv=position.x<.5?row.xy:row.zw; vec2 p=dst.xy+position*dst.zw;"
    "gl_Position=vec4(p/target*2.-1.,0.,1.); }";
static const char solid[] =
    "precision mediump float; uniform vec4 color; void main(){gl_FragColor=color;}";
static const char fragment[] =
    "precision mediump float; varying vec2 uv; uniform float alpha, opaque;"
    "void main(){vec4 c=texture2D(tex,uv); if(opaque>0.5)c.a=1.; gl_FragColor=c*alpha;}";

static GLuint shader(GLenum type, const char *prefix, const char *source) {
    GLuint id = glCreateShader(type);
    if (!id) return 0;
    const char *strings[] = {prefix, source};
    glShaderSource(id, 2, strings, NULL);
    glCompileShader(id);
    GLint ok;
    glGetShaderiv(id, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(id, sizeof(log), NULL, log);
        wlr_log(WLR_ERROR, "scene pass shader: %s", log);
        glDeleteShader(id);
        return 0;
    }
    return id;
}
static bool program_init(struct program *p, const char *prefix, const char *source) {
    GLuint vs = shader(GL_VERTEX_SHADER, "", vertex);
    GLuint fs = shader(GL_FRAGMENT_SHADER, prefix, source);
    if (vs && fs) {
        p->id = glCreateProgram();
        glAttachShader(p->id, vs);
        glAttachShader(p->id, fs);
        glBindAttribLocation(p->id, 0, "position");
        glLinkProgram(p->id);
        GLint ok;
        glGetProgramiv(p->id, GL_LINK_STATUS, &ok);
        // The linked executable owns everything needed for draws. Deleting an
        // attached shader only marks it for deletion; detach it as well so the
        // driver can release its source and compiler IR now.
        glDetachShader(p->id, vs);
        glDetachShader(p->id, fs);
        if (!ok) {
            glDeleteProgram(p->id);
            p->id = 0;
        }
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (!p->id) return false;
    p->target = glGetUniformLocation(p->id, "target");
    p->dst = glGetUniformLocation(p->id, "dst");
    p->color = glGetUniformLocation(p->id, "color");
    p->alpha = glGetUniformLocation(p->id, "alpha");
    p->opaque = glGetUniformLocation(p->id, "opaque");
    p->sampler = glGetUniformLocation(p->id, "tex");
    p->coords = glGetUniformLocation(p->id, "coords[0]");
    return true;
}
static const GLfloat positions[] = {0, 0, 1, 0, 0, 1, 1, 1};
struct rediwm_scene_renderer *rediwm_scene_renderer_create(struct wlr_renderer *renderer) {
    if (!wlr_renderer_is_gles2(renderer)) return NULL;
    struct rediwm_scene_renderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->renderer = renderer;
    r->has_external = wlr_gles2_renderer_check_ext(renderer, "GL_OES_EGL_image_external");
    r->gen_vertex_arrays = (PFNGLGENVERTEXARRAYSOESPROC)eglGetProcAddress("glGenVertexArraysOES");
    r->bind_vertex_array = (PFNGLBINDVERTEXARRAYOESPROC)eglGetProcAddress("glBindVertexArrayOES");
    r->delete_vertex_arrays = (PFNGLDELETEVERTEXARRAYSOESPROC)eglGetProcAddress("glDeleteVertexArraysOES");
    r->has_vao = wlr_gles2_renderer_check_ext(renderer, "GL_OES_vertex_array_object") &&
        r->gen_vertex_arrays && r->bind_vertex_array && r->delete_vertex_arrays;
    r->create_sync = (PFNEGLCREATESYNCKHRPROC)eglGetProcAddress("eglCreateSyncKHR");
    r->destroy_sync = (PFNEGLDESTROYSYNCKHRPROC)eglGetProcAddress("eglDestroySyncKHR");
    r->wait_sync = (PFNEGLWAITSYNCKHRPROC)eglGetProcAddress("eglWaitSyncKHR");
    r->dup_fence = (PFNEGLDUPNATIVEFENCEFDANDROIDPROC)eglGetProcAddress("eglDupNativeFenceFDANDROID");
    r->has_sync = renderer->features.timeline && r->create_sync &&
        r->destroy_sync && r->wait_sync && r->dup_fence;
    struct gl_state state;
    if (!enter(r, &state)) { free(r); return NULL; }
    bool ok = program_init(&r->solid, "", solid) &&
        program_init(&r->texture, "uniform sampler2D tex;", fragment) &&
        (!r->has_external || program_init(&r->external,
            "#extension GL_OES_EGL_image_external : require\nuniform samplerExternalOES tex;", fragment));
    if (ok && r->has_vao) {
        r->gen_vertex_arrays(1, &r->vertex_array);
        r->bind_vertex_array(r->vertex_array);
        glGenBuffers(1, &r->vertices);
        glBindBuffer(GL_ARRAY_BUFFER, r->vertices);
        glBufferData(GL_ARRAY_BUFFER, sizeof(positions), positions, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
        glEnableVertexAttribArray(0);
        ok = r->vertex_array && r->vertices && glGetError() == GL_NO_ERROR;
    }
    if (!ok) {
        if (r->vertex_array) r->delete_vertex_arrays(1, &r->vertex_array);
        glDeleteBuffers(1, &r->vertices);
        glDeleteProgram(r->solid.id);
        glDeleteProgram(r->texture.id);
        glDeleteProgram(r->external.id);
    }
    leave(r, &state);
    if (!ok) { free(r); return NULL; }
    return r;
}
void rediwm_scene_renderer_destroy(struct rediwm_scene_renderer *r) {
    if (!r) return;
    assert(!r->active);
    struct gl_state state;
    if (enter(r, &state)) {
        if (r->vertex_array) r->delete_vertex_arrays(1, &r->vertex_array);
        glDeleteBuffers(1, &r->vertices);
        glDeleteProgram(r->solid.id);
        glDeleteProgram(r->texture.id);
        glDeleteProgram(r->external.id);
        leave(r, &state);
    }
    free(r);
}

static void setup(struct pass *p, struct program *program, struct wlr_box box,
        enum wlr_render_blend_mode blend) {
    if (p->program != program->id) {
        glUseProgram(program->id);
        p->program = program->id;
    }
    unsigned bit = program == &p->renderer->solid ? 1 : program == &p->renderer->texture ? 2 : 4;
    if (!(p->targets_set & bit)) {
        glUniform2f(program->target, p->buffer->width, p->buffer->height);
        p->targets_set |= bit;
    }
    glUniform4f(program->dst, box.x, box.y, box.width, box.height);
    if (p->blend_mode != (int)blend) {
        (blend == WLR_RENDER_BLEND_MODE_NONE ? glDisable : glEnable)(GL_BLEND);
        p->blend_mode = blend;
    }
}
static void draw(const pixman_region32_t *clip) {
    if (!clip) {
        glDisable(GL_SCISSOR_TEST);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        return;
    }
    int n;
    const pixman_box32_t *boxes = pixman_region32_rectangles((pixman_region32_t *)clip, &n);
    glEnable(GL_SCISSOR_TEST);
    for (int i = 0; i < n; i++) {
        glScissor(boxes[i].x1, boxes[i].y1, boxes[i].x2 - boxes[i].x1, boxes[i].y2 - boxes[i].y1);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
}
static void add_rect(struct wlr_render_pass *base, const struct wlr_render_rect_options *o) {
    struct pass *p = wl_container_of(base, p, base);
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    struct wlr_box box;
    wlr_render_rect_options_get_box(o, p->buffer, &box);
    setup(p, &p->renderer->solid, box, o->blend_mode);
    glUniform4f(p->renderer->solid.color, o->color.r, o->color.g, o->color.b, o->color.a);
    draw(o->clip);
}
static bool wait_point(struct pass *p, struct wlr_drm_syncobj_timeline *timeline, uint64_t point) {
    if (!timeline) return true;
    struct rediwm_scene_renderer *r = p->renderer;
    if (!r->has_sync) return false;
    int fd = wlr_drm_syncobj_timeline_export_sync_file(timeline, point);
    if (fd < 0) return false;
    EGLint attrs[] = {EGL_SYNC_NATIVE_FENCE_FD_ANDROID, fd, EGL_NONE};
    EGLSyncKHR sync = r->create_sync(p->state.display, EGL_SYNC_NATIVE_FENCE_ANDROID, attrs);
    if (sync == EGL_NO_SYNC_KHR) { close(fd); return false; }
    // EGL owns the fd after a successful import. GPU wait, never a CPU poll.
    bool ok = r->wait_sync(p->state.display, sync, 0) == EGL_TRUE;
    r->destroy_sync(p->state.display, sync);
    return ok;
}
static void texture_draw(struct pass *p, const struct wlr_render_texture_options *o,
        struct wlr_gles2_texture_attribs a) {
    struct program *program = a.target == GL_TEXTURE_2D ? &p->renderer->texture :
        a.target == GL_TEXTURE_EXTERNAL_OES ? &p->renderer->external : NULL;
    if (!program || !program->id) { p->failed = true; return; }
    struct wlr_box dst;
    struct wlr_fbox src;
    wlr_render_texture_options_get_dst_box(o, &dst);
    wlr_render_texture_options_get_src_box(o, &src);
    setup(p, program, dst, o->blend_mode);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(a.target, a.tex);
    GLint filter = o->filter_mode == WLR_SCALE_FILTER_NEAREST ? GL_NEAREST : GL_LINEAR;
    glTexParameteri(a.target, GL_TEXTURE_MIN_FILTER, filter);
    glTexParameteri(a.target, GL_TEXTURE_MAG_FILTER, filter);
    glUniform1i(program->sampler, 0);
    glUniform1f(program->alpha, wlr_render_texture_options_get_alpha(o));
    glUniform1f(program->opaque, !a.has_alpha);
    GLfloat uv[8];
    for (int i = 0; i < 4; i++) {
        double x = positions[2 * i], y = positions[2 * i + 1], u, v;
        // Map destination corners back to the untransformed source rectangle.
        switch (o->transform) {
        case WL_OUTPUT_TRANSFORM_NORMAL: u = x; v = y; break;
        case WL_OUTPUT_TRANSFORM_90: u = 1 - y; v = x; break;
        case WL_OUTPUT_TRANSFORM_180: u = 1 - x; v = 1 - y; break;
        case WL_OUTPUT_TRANSFORM_270: u = y; v = 1 - x; break;
        case WL_OUTPUT_TRANSFORM_FLIPPED: u = 1 - x; v = y; break;
        case WL_OUTPUT_TRANSFORM_FLIPPED_90: u = y; v = x; break;
        case WL_OUTPUT_TRANSFORM_FLIPPED_180: u = x; v = 1 - y; break;
        case WL_OUTPUT_TRANSFORM_FLIPPED_270: u = 1 - y; v = 1 - x; break;
        default: p->failed = true; return;
        }
        uv[2 * i] = (src.x + u * src.width) / o->texture->width;
        uv[2 * i + 1] = (src.y + v * src.height) / o->texture->height;
    }
    glUniform4fv(program->coords, 2, uv);
    draw(o->clip);
}
static void add_texture(struct wlr_render_pass *base, const struct wlr_render_texture_options *o) {
    struct pass *p = wl_container_of(base, p, base);
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    if (!wlr_texture_is_gles2(o->texture) || o->texture->renderer != p->renderer->renderer ||
            !wait_point(p, o->wait_timeline, o->wait_point)) {
        p->failed = true;
        return;
    }
    struct wlr_gles2_texture_attribs a;
    wlr_gles2_texture_get_attribs(o->texture, &a);
    texture_draw(p, o, a);
}
static bool submit(struct wlr_render_pass *base) {
    struct pass *p = wl_container_of(base, p, base);
    struct rediwm_scene_renderer *r = p->renderer;
    bool ok = !p->failed;
    if (p->signal_timeline) {
        EGLSyncKHR sync = r->create_sync(p->state.display, EGL_SYNC_NATIVE_FENCE_ANDROID, NULL);
        if (sync == EGL_NO_SYNC_KHR) {
            ok = false;
        } else {
            glFlush();
            int fd = r->dup_fence(p->state.display, sync);
            r->destroy_sync(p->state.display, sync);
            if (fd < 0) ok = false;
            else {
                ok = wlr_drm_syncobj_timeline_import_sync_file(p->signal_timeline, p->signal_point, fd) && ok;
                close(fd);
            }
        }
        wlr_drm_syncobj_timeline_unref(p->signal_timeline);
    } else {
        glFlush();
    }
    // Failed submissions must not leave untracked reads in flight: callers
    // register release points only after success (see explicit_sync.c).
    if (!ok) glFinish();
    leave(r, &p->state);
    wlr_buffer_unlock(p->buffer);
    r->active = false;
    free(p);
    return ok;
}
static const struct wlr_render_pass_impl impl = {
    .submit = submit, .add_rect = add_rect, .add_texture = add_texture,
};
struct wlr_render_pass *rediwm_scene_pass_begin(struct rediwm_scene_renderer *r,
        struct wlr_buffer *buffer, const struct wlr_buffer_pass_options *options) {
    if (r->active || (options && (options->timer || options->color_transform ||
            (options->signal_timeline && !r->has_sync)))) return NULL;
    struct pass *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    if (!enter(r, &p->state)) { free(p); return NULL; }
    GLuint fbo = wlr_gles2_renderer_get_buffer_fbo(r->renderer, buffer);
    if (!fbo) { leave(r, &p->state); free(p); return NULL; }
    p->renderer = r;
    p->buffer = wlr_buffer_lock(buffer);
    if (options && options->signal_timeline) {
        p->signal_timeline = wlr_drm_syncobj_timeline_ref(options->signal_timeline);
        p->signal_point = options->signal_point;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, buffer->width, buffer->height);
    glBlendEquation(GL_FUNC_ADD);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    p->blend_mode = -1;
    if (r->has_vao) {
        r->bind_vertex_array(r->vertex_array);
    } else {
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, positions);
        glEnableVertexAttribArray(0);
    }
    r->active = true;
    wlr_render_pass_init(&p->base, &impl);
    return &p->base;
}
