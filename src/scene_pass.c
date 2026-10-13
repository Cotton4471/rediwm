// Stage 3 drawing backend. No output, scene traversal or geometry policy here.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "scene_pass.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <assert.h>
#include <math.h>
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
    unsigned bit; // which bit of pass.targets_set tracks this program's target size
    GLint target, dst, color, alpha, opaque, sampler, coords;
    // Shaped programs only (-1 elsewhere): the shape, and the shadow's own terms.
    GLint mode, origin, size, radii, border, bcolor, glow, gcolor, offset, softness, hide, use_shape;
    // The backdrop composite (shaped mode 3) and the blur program.
    GLint bmap, fmap, saturation, front, front_alpha, has_front;
    GLint step_uv, sigma, limits, src_scale;
};
struct rediwm_backdrop {
    GLuint tex, fbo;
    int width, height;     // the reduced size
    int x, y;              // device pixel the image starts at
    float extent_w, extent_h; // device pixels it covers (width * factor)
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
    // Rounded-rectangle shapes (stage 4b), built by enable_shapes: one program for
    // a 2D texture, a solid colour and the shape's shadow (they differ in a mode
    // uniform, which every fragment of a draw reads the same), one for external.
    struct program shaped, shaped_external;
    // Backdrops (stage 5b), built by enable_backdrops: the blur, and scratch the
    // size of the largest region so far: the copy, and the horizontal pass.
    struct program blur;
    GLuint prefix_tex, prefix_fbo, small_tex, small_fbo;
    int small_w, small_h;
    bool has_backdrops, backdrops_tried;
    bool active, has_external, has_sync, has_vao, has_shapes, shapes_tried;
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
    // Between begin_backdrop and end_backdrop draws land in a quarter-size image
    // of `region` (stage 5f): boxes move by its origin, scissors shrink by four.
    bool redirected;
    struct wlr_box region, valid; // device pixels; `valid` is the part in the buffer
    float factor;                 // device pixels per pixel of the image
    int small_w, small_h;
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

// Shaped draws (stage 4b): the same quad and texture coordinates, plus the
// position relative to the shape's corner, evaluated in the vertex stage so the
// fragment's distance function works on window-sized numbers, not on output ones.
static const char shaped_vertex[] =
    "attribute vec2 position; uniform vec2 target, origin; uniform vec4 dst, coords[2];"
    "varying vec2 uv; varying vec2 local;"
    "void main(){ vec4 row=position.y<.5?coords[0]:coords[1];"
    "uv=position.x<.5?row.xy:row.zw; vec2 p=dst.xy+position*dst.zw;"
    "local=p-origin; gl_Position=vec4(p/target*2.-1.,0.,1.); }";
// One distance function for every piece of a window, so titlebar, client, border
// and shadow agree on the arc to the last bit. The radius is picked by quadrant
// and capped to what fits, as the compositor caps it before scaling.
#define SHAPED_HEAD \
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n" \
    "varying vec2 uv; varying vec2 local; uniform vec2 size; uniform vec4 radii, bcolor, color;" \
    "uniform float border; uniform vec4 glow, gcolor;" \
    "float sdf(vec2 p, vec4 r){ vec2 q=p-size*.5;" \
    "float rad=q.x<0.?(q.y<0.?r.x:r.w):(q.y<0.?r.y:r.z);" \
    "rad=clamp(rad,0.,min(size.x,size.y)*.5);" \
    "vec2 d=abs(q)-(size*.5-vec2(rad));" \
    "return length(max(d,0.))+min(max(d.x,d.y),0.)-rad; }" \
    "float cov(float d){ return clamp(.5-d,0.,1.); }"
// A border is part of the same pass as its body. The ring is composited OVER the
// body inside the shape and the result is scaled by the shape's coverage, which
// is what the border rects of the legacy path do (a translucent border, as the
// default theme has, tints the fill beneath it instead of replacing it). For an
// opaque ring this equals splitting the pixel into body and ring coverage that
// add up to the shape's, the spike's model. As two draws the coverages would
// multiply, and a seam would show where each is partly covered.
//
// `mode` 0 draws the texture, 1 the solid colour, 3 a backdrop composite (see
// add_backdrop), 2 the shape's shadow: the
// shape moved by `offset`, falling off over `softness` outside it with the
// smoothstep of the CPU chrome's shadow (`chrome.shadowCoverage`, the same
// distance field, so corners match it as exactly as edges), kept out of the shape
// when `hide` is set, which matters under translucent windows. One program for the
// three because a program costs the driver 130-150 KiB however small it is.
static const char shaped_fragment[] = SHAPED_HEAD
    "uniform float alpha, opaque, mode, softness, hide; uniform vec2 offset;"
    "uniform sampler2D front; uniform vec4 bmap, fmap; uniform float saturation, front_alpha, has_front, use_shape;"
    "void main(){"
    // 3: a backdrop composite (stage 5b). `tex` is the kept blur; the alpha is
    // chosen against the surface drawn over it, so the pair has the coverage.
    "if(mode>2.5){ vec3 rgb=texture2D(tex,(local+bmap.xy)*bmap.zw).rgb;"
    "float l=dot(rgb,vec3(.213,.715,.072)); rgb=clamp(vec3(l)+(rgb-vec3(l))*saturation,0.,1.);"
    "float c=cov(sdf(local,radii))*alpha;"
    "float f=has_front>.5?texture2D(front,(local+fmap.xy)*fmap.zw).a*front_alpha:0.;"
    "float a=f>=.99999?0.:clamp((c-f)/(1.-f),0.,1.); gl_FragColor=vec4(rgb*a,a); return; }"
    "if(mode>1.5){ float s=clamp(1.-sdf(local-offset,radii)/softness,0.,1.); s=s*s*(3.-2.*s);"
    "if(hide>.5)s*=1.-cov(sdf(local,radii)); gl_FragColor=color*s; return; }"
    "vec4 c=color; if(mode<.5){ c=texture2D(tex,uv); if(opaque>.5)c.a=1.; c*=alpha; }"
    // Without a shape (every plain draw) the colour is written as it is: the
    // plain programs are gone (stage 5, D4), and this costs one uniform branch.
    "if(use_shape<.5){ gl_FragColor=c; return; }"
    "float d=sdf(local,radii);"
    "float w=border>0.?1.-cov(d+border):0.;"
    "vec4 o=c*(1.-bcolor.a*w)+bcolor*w;"
    // The highlight (a smoothstep of the distance from its point), over the ring
    // and, when it has depth, fading inward past it.
    "if(glow.z>0.){ float g=clamp(1.-length(local-glow.xy)/glow.z,0.,1.); g=g*g*(3.-2.*g);"
    "float t=glow.w>0.?1.-smoothstep(0.,1.,(-d-border)/glow.w):w;"
    "o=o*(1.-gcolor.a*g*t)+gcolor*(g*t); }"
    "gl_FragColor=o*cov(d); }";

// The backdrop blur (stage 5b): glass.c's kernel, 49 taps, sigma in texels of the
// target, reading a source texture that may be larger than the region (scratch),
// clamped to the texels that were really copied, so an edge replicates.
static const char blur_vertex[] =
    "attribute vec2 position; varying vec2 uv;"
    "void main(){ uv=position; gl_Position=vec4(position*2.-1.,0.,1.); }";
static const char blur_fragment[] =
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n"
    "varying vec2 uv; uniform sampler2D tex;"
    "uniform vec2 step_uv, src_scale; uniform float sigma; uniform vec4 limits;"
    "void main(){ vec4 sum=vec4(0.); float weight=0.; vec2 at=uv*src_scale;"
    "for(int i=-24;i<=24;i++){ float x=float(i); float w=exp(-.5*x*x/(sigma*sigma));"
    "sum+=texture2D(tex,clamp(at+x*step_uv,limits.xy,limits.zw))*w; weight+=w; }"
    "gl_FragColor=vec4(sum.rgb/weight,1.); }";

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
static bool program_init(struct program *p, unsigned bit, const char *vertex_source,
        const char *prefix, const char *source) {
    p->bit = bit;
    GLuint vs = shader(GL_VERTEX_SHADER, "", vertex_source);
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
    p->mode = glGetUniformLocation(p->id, "mode");
    p->origin = glGetUniformLocation(p->id, "origin");
    p->size = glGetUniformLocation(p->id, "size");
    p->radii = glGetUniformLocation(p->id, "radii");
    p->border = glGetUniformLocation(p->id, "border");
    p->bcolor = glGetUniformLocation(p->id, "bcolor");
    p->glow = glGetUniformLocation(p->id, "glow");
    p->gcolor = glGetUniformLocation(p->id, "gcolor");
    p->offset = glGetUniformLocation(p->id, "offset");
    p->softness = glGetUniformLocation(p->id, "softness");
    p->hide = glGetUniformLocation(p->id, "hide");
    p->use_shape = glGetUniformLocation(p->id, "use_shape");
    p->bmap = glGetUniformLocation(p->id, "bmap");
    p->fmap = glGetUniformLocation(p->id, "fmap");
    p->saturation = glGetUniformLocation(p->id, "saturation");
    p->front = glGetUniformLocation(p->id, "front");
    p->front_alpha = glGetUniformLocation(p->id, "front_alpha");
    p->has_front = glGetUniformLocation(p->id, "has_front");
    p->step_uv = glGetUniformLocation(p->id, "step_uv");
    p->sigma = glGetUniformLocation(p->id, "sigma");
    p->limits = glGetUniformLocation(p->id, "limits");
    p->src_scale = glGetUniformLocation(p->id, "src_scale");
    // Samplers default to unit 0, and two of different types there (the external
    // program's `tex` and `front`) make every draw invalid: `front` is unit 1.
    if (p->front >= 0) {
        glUseProgram(p->id);
        glUniform1i(p->front, 1);
    }
    return true;
}
static const char ext_prefix[] =
    "#extension GL_OES_EGL_image_external : require\nuniform samplerExternalOES tex;\n";
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
    // Every draw goes through the shaped programs; one without a shape costs a
    // uniform branch. A GL program costs the driver 130-150 KiB however small,
    // so the plain ones are gone (stage 5, D4 of docs/plans/scene-graph-stage5.md).
    bool ok = program_init(&r->shaped, 8, shaped_vertex, "uniform sampler2D tex;\n", shaped_fragment) &&
        (!r->has_external || program_init(&r->shaped_external, 16, shaped_vertex, ext_prefix, shaped_fragment));
    r->has_shapes = r->shapes_tried = ok;
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
        glDeleteProgram(r->shaped.id);
        glDeleteProgram(r->shaped_external.id);
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
        glDeleteProgram(r->shaped.id);
        glDeleteProgram(r->shaped_external.id);
        glDeleteProgram(r->blur.id);
        glDeleteTextures(1, &r->prefix_tex);
        glDeleteFramebuffers(1, &r->prefix_fbo);
        glDeleteTextures(1, &r->small_tex);
        glDeleteFramebuffers(1, &r->small_fbo);
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
    if (!(p->targets_set & program->bit)) {
        if (p->redirected) glUniform2f(program->target, p->small_w * p->factor, p->small_h * p->factor);
        else glUniform2f(program->target, p->buffer->width, p->buffer->height);
        p->targets_set |= program->bit;
    }
    if (p->redirected) {
        box.x -= p->region.x;
        box.y -= p->region.y;
    }
    glUniform4f(program->dst, box.x, box.y, box.width, box.height);
    if (p->blend_mode != (int)blend) {
        (blend == WLR_RENDER_BLEND_MODE_NONE ? glDisable : glEnable)(GL_BLEND);
        p->blend_mode = blend;
    }
}
static void draw(const struct pass *p, const pixman_region32_t *clip) {
    if (!clip) {
        glDisable(GL_SCISSOR_TEST);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        return;
    }
    int n;
    const pixman_box32_t *boxes = pixman_region32_rectangles((pixman_region32_t *)clip, &n);
    glEnable(GL_SCISSOR_TEST);
    for (int i = 0; i < n; i++) {
        if (p->redirected) {
            // Outward to whole small pixels; the region's origin is a multiple of none.
            const int x1 = (int)floorf((boxes[i].x1 - p->region.x) / p->factor);
            const int y1 = (int)floorf((boxes[i].y1 - p->region.y) / p->factor);
            const int x2 = (int)ceilf((boxes[i].x2 - p->region.x) / p->factor);
            const int y2 = (int)ceilf((boxes[i].y2 - p->region.y) / p->factor);
            glScissor(x1, y1, x2 - x1, y2 - y1);
        } else {
            glScissor(boxes[i].x1, boxes[i].y1, boxes[i].x2 - boxes[i].x1, boxes[i].y2 - boxes[i].y1);
        }
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
}
// The shape's uniforms. A degenerate or non-finite shape is the caller's bug;
// it fails the pass at submit like any other bad draw.
static bool shape_usable(const struct rediwm_pass_shape *s) {
    if (!isfinite(s->border) || s->border < 0) return false;
    for (int i = 0; i < 4; i++) if (!isfinite(s->radii[i]) || s->radii[i] < 0) return false;
    for (int i = 0; i < 4; i++) if (!isfinite(s->border_color[i]) || !isfinite(s->glow_color[i])) return false;
    return isfinite(s->glow_radius) && isfinite(s->glow_depth) && s->glow_radius >= 0 && s->glow_depth >= 0 &&
        isfinite(s->glow_center[0]) && isfinite(s->glow_center[1]);
}
static void set_shape(const struct pass *p, const struct program *g, const struct rediwm_pass_shape *s) {
    glUniform1f(g->use_shape, 1.f);
    if (p->redirected) glUniform2f(g->origin, s->box.x - p->region.x, s->box.y - p->region.y);
    else glUniform2f(g->origin, s->box.x, s->box.y);
    glUniform2f(g->size, s->box.width, s->box.height);
    glUniform4f(g->radii, s->radii[0], s->radii[1], s->radii[2], s->radii[3]);
    glUniform1f(g->border, s->border);
    glUniform4f(g->bcolor, s->border_color[0], s->border_color[1], s->border_color[2],
        s->border_color[3]);
    glUniform4f(g->glow, s->glow_center[0], s->glow_center[1], s->glow_radius, s->glow_depth);
    glUniform4f(g->gcolor, s->glow_color[0], s->glow_color[1], s->glow_color[2], s->glow_color[3]);
}
static void add_rect(struct wlr_render_pass *base, const struct wlr_render_rect_options *o) {
    struct pass *p = wl_container_of(base, p, base);
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    struct wlr_box box;
    wlr_render_rect_options_get_box(o, p->buffer, &box);
    struct program *g = &p->renderer->shaped;
    setup(p, g, box, o->blend_mode);
    glUniform4f(g->color, o->color.r, o->color.g, o->color.b, o->color.a);
    glUniform1f(g->mode, 1.f);
    glUniform1f(g->use_shape, 0.f);
    draw(p, o->clip);
}
static void rect_shaped(struct pass *p, const struct wlr_render_rect_options *o,
        const struct rediwm_pass_shape *shape) {
    struct program *g = &p->renderer->shaped;
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    if (!g->id || !shape_usable(shape)) { p->failed = true; return; }
    struct wlr_box box;
    wlr_render_rect_options_get_box(o, p->buffer, &box);
    setup(p, g, box, o->blend_mode);
    glUniform4f(g->color, o->color.r, o->color.g, o->color.b, o->color.a);
    glUniform1f(g->mode, 1.f);
    set_shape(p, g, shape);
    draw(p, o->clip);
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
        struct wlr_gles2_texture_attribs a, const struct rediwm_pass_shape *shape) {
    struct rediwm_scene_renderer *r = p->renderer;
    struct program *program = a.target == GL_TEXTURE_2D ? &r->shaped :
        a.target == GL_TEXTURE_EXTERNAL_OES ? &r->shaped_external : NULL;
    if (!program || !program->id || (shape && !shape_usable(shape))) { p->failed = true; return; }
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
    glUniform1f(program->mode, 0.f);
    if (shape) set_shape(p, program, shape);
    else glUniform1f(program->use_shape, 0.f);
    draw(p, o->clip);
}
static void texture_add(struct wlr_render_pass *base, const struct wlr_render_texture_options *o,
        const struct rediwm_pass_shape *shape) {
    struct pass *p = wl_container_of(base, p, base);
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    if (!wlr_texture_is_gles2(o->texture) || o->texture->renderer != p->renderer->renderer ||
            !wait_point(p, o->wait_timeline, o->wait_point)) {
        p->failed = true;
        return;
    }
    struct wlr_gles2_texture_attribs a;
    wlr_gles2_texture_get_attribs(o->texture, &a);
    texture_draw(p, o, a, shape);
}
static void add_texture(struct wlr_render_pass *base, const struct wlr_render_texture_options *o) {
    texture_add(base, o, NULL);
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

// The shaped programs are built with the renderer (stage 5, D4): every draw uses
// them. Kept so callers need not know.
bool rediwm_scene_renderer_enable_shapes(struct rediwm_scene_renderer *r) {
    assert(!r->active);
    return r->has_shapes;
}
// Only a pass from rediwm_scene_pass_begin carries these: handing in a wlroots
// pass is a programming error, not something to degrade around.
static struct pass *owned_pass(struct wlr_render_pass *base) {
    assert(base->impl == &impl);
    struct pass *p = wl_container_of(base, p, base);
    return p;
}
void rediwm_scene_pass_add_rect_shaped(struct wlr_render_pass *base,
        const struct wlr_render_rect_options *o, const struct rediwm_pass_shape *shape) {
    rect_shaped(owned_pass(base), o, shape);
}
void rediwm_scene_pass_add_texture_shaped(struct wlr_render_pass *base,
        const struct wlr_render_texture_options *o, const struct rediwm_pass_shape *shape) {
    owned_pass(base);
    texture_add(base, o, shape);
}
void rediwm_scene_pass_add_shadow(struct wlr_render_pass *base,
        const struct rediwm_pass_shape *shape, const struct rediwm_pass_shadow *shadow) {
    struct pass *p = owned_pass(base);
    struct program *g = &p->renderer->shaped;
    if (p->failed || (shadow->clip && !pixman_region32_not_empty(shadow->clip))) return;
    if (!g->id || !shape_usable(shape) || !isfinite(shadow->offset_x) ||
            !isfinite(shadow->offset_y) || !isfinite(shadow->softness) || shadow->softness > 4096 ||
            fabsf(shadow->offset_x) > 65536 || fabsf(shadow->offset_y) > 65536) {
        p->failed = true;
        return;
    }
    // A quarter pixel is a hard edge; zero would divide by it.
    const float softness = shadow->softness < .25f ? .25f : shadow->softness;
    // The quad reaches the softness past the shape, and as far again as the offset.
    const int pad = (int)ceilf(softness) + (int)ceilf(fmaxf(fabsf(shadow->offset_x), fabsf(shadow->offset_y)));
    const struct wlr_box box = {shape->box.x - pad, shape->box.y - pad,
        shape->box.width + 2 * pad, shape->box.height + 2 * pad};
    setup(p, g, box, WLR_RENDER_BLEND_MODE_PREMULTIPLIED);
    glUniform4f(g->color, shadow->color[0], shadow->color[1], shadow->color[2], shadow->color[3]);
    struct rediwm_pass_shape bare = *shape; // the shadow has no border of its own
    bare.border = 0;
    set_shape(p, g, &bare);
    glUniform1f(g->mode, 2.f);
    glUniform2f(g->offset, shadow->offset_x, shadow->offset_y);
    glUniform1f(g->softness, softness);
    glUniform1f(g->hide, shadow->hide_inside ? 1.f : 0.f);
    draw(p, shadow->clip);
}

// ---- Backdrops (stage 5b) -------------------------------------------------------
bool rediwm_scene_renderer_enable_backdrops(struct rediwm_scene_renderer *r) {
    assert(!r->active);
    if (r->backdrops_tried) return r->has_backdrops;
    r->backdrops_tried = true;
    if (!r->has_shapes) return false;
    struct gl_state state;
    if (!enter(r, &state)) return false;
    r->has_backdrops = program_init(&r->blur, 32, blur_vertex, "", blur_fragment);
    if (!r->has_backdrops) {
        wlr_log(WLR_ERROR, "scene pass: blur program failed to build, glass is a plain tint");
        glDeleteProgram(r->blur.id);
        r->blur.id = 0;
    }
    leave(r, &state);
    return r->has_backdrops;
}
static void texture_storage(GLuint tex, GLenum format, int w, int h) {
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, format, w, h, 0, format, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}
static bool attach(GLuint fbo, GLuint tex) {
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}
// Two quarter-size scratch images shared by every effect, grown to the largest
// so far: what lies below the effect, and the horizontal blur pass.
static bool scratch(struct rediwm_scene_renderer *r, int small_w, int small_h) {
    if (!r->prefix_tex) glGenTextures(1, &r->prefix_tex);
    if (!r->prefix_fbo) glGenFramebuffers(1, &r->prefix_fbo);
    if (!r->small_tex) glGenTextures(1, &r->small_tex);
    if (!r->small_fbo) glGenFramebuffers(1, &r->small_fbo);
    if (small_w > r->small_w || small_h > r->small_h) {
        r->small_w = small_w > r->small_w ? small_w : r->small_w;
        r->small_h = small_h > r->small_h ? small_h : r->small_h;
        texture_storage(r->prefix_tex, GL_RGBA, r->small_w, r->small_h);
        texture_storage(r->small_tex, GL_RGBA, r->small_w, r->small_h);
        if (!attach(r->prefix_fbo, r->prefix_tex) || !attach(r->small_fbo, r->small_tex)) return false;
    }
    return true;
}
void rediwm_scene_renderer_destroy_backdrop(struct rediwm_scene_renderer *r, struct rediwm_backdrop *b) {
    if (!b) return;
    assert(!r->active);
    struct gl_state state;
    if (enter(r, &state)) {
        glDeleteTextures(1, &b->tex);
        glDeleteFramebuffers(1, &b->fbo);
        leave(r, &state);
    }
    free(b);
}
void rediwm_scene_pass_begin_backdrop(struct wlr_render_pass *base, struct wlr_box region, float factor) {
    struct pass *p = owned_pass(base);
    struct rediwm_scene_renderer *r = p->renderer;
    if (p->failed) return;
    if (!r->has_backdrops || p->redirected || region.width <= 0 || region.height <= 0 ||
            region.width > 16384 || region.height > 16384 || !isfinite(factor) || factor < 1 || factor > 64) {
        p->failed = true;
        return;
    }
    // Whole pixels of the image: it covers a little more than the region.
    const int small_w = (int)ceilf(region.width / factor), small_h = (int)ceilf(region.height / factor);
    if (!scratch(r, small_w, small_h)) { p->failed = true; return; }
    p->factor = factor;
    p->small_w = small_w;
    p->small_h = small_h;
    struct wlr_box buffer = {0, 0, p->buffer->width, p->buffer->height};
    if (!wlr_box_intersection(&p->valid, &region, &buffer)) { p->failed = true; return; }
    p->region = region;
    p->redirected = true;
    p->targets_set = 0;
    glBindFramebuffer(GL_FRAMEBUFFER, r->prefix_fbo);
    glViewport(0, 0, small_w, small_h);
    // Black where nothing is drawn, as the output is; the blur never reads
    // outside the buffer (see end_backdrop).
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
}
void rediwm_scene_pass_end_backdrop(struct wlr_render_pass *base, struct rediwm_backdrop **out, float sigma) {
    struct pass *p = owned_pass(base);
    struct rediwm_scene_renderer *r = p->renderer;
    if (!p->redirected) { p->failed = true; return; }
    p->redirected = false;
    p->targets_set = 0;
    p->program = 0;
    p->blend_mode = -1;
    GLuint pass_fbo = wlr_gles2_renderer_get_buffer_fbo(r->renderer, p->buffer);
    if (p->failed || !isfinite(sigma) || sigma <= 0 || sigma > 1024) {
        p->failed = true;
        glBindFramebuffer(GL_FRAMEBUFFER, pass_fbo);
        glViewport(0, 0, p->buffer->width, p->buffer->height);
        return;
    }
    struct rediwm_backdrop *b = *out;
    if (!b) {
        b = calloc(1, sizeof(*b));
        if (!b) { p->failed = true; return; }
        glGenTextures(1, &b->tex);
        glGenFramebuffers(1, &b->fbo);
        *out = b;
    }
    const int small_w = p->small_w, small_h = p->small_h;
    if (b->width != small_w || b->height != small_h) {
        texture_storage(b->tex, GL_RGBA, small_w, small_h);
        if (!attach(b->fbo, b->tex)) { p->failed = true; return; }
        b->width = small_w;
        b->height = small_h;
    }
    b->x = p->region.x;
    b->y = p->region.y;
    b->extent_w = small_w * p->factor;
    b->extent_h = small_h * p->factor;
    // Separable blur: horizontal into scratch, vertical into the backdrop. Only
    // what lies in the buffer is read: beyond it the edge is replicated.
    struct program *g = &r->blur;
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glActiveTexture(GL_TEXTURE0);
    glUseProgram(g->id);
    glUniform1i(g->sampler, 0);
    const float aw = r->small_w, ah = r->small_h;
    const float vx1 = (p->valid.x - p->region.x) / p->factor, vy1 = (p->valid.y - p->region.y) / p->factor;
    const float vx2 = fminf(small_w, (p->valid.x + p->valid.width - p->region.x) / p->factor);
    const float vy2 = fminf(small_h, (p->valid.y + p->valid.height - p->region.y) / p->factor);
    glUniform2f(g->src_scale, small_w / aw, small_h / ah);
    glUniform1f(g->sigma, sigma / p->factor);
    glBindFramebuffer(GL_FRAMEBUFFER, r->small_fbo);
    glViewport(0, 0, small_w, small_h);
    glBindTexture(GL_TEXTURE_2D, r->prefix_tex);
    glUniform2f(g->step_uv, 1.f / aw, 0);
    glUniform4f(g->limits, (vx1 + .5f) / aw, (vy1 + .5f) / ah, (vx2 - .5f) / aw, (vy2 - .5f) / ah);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindFramebuffer(GL_FRAMEBUFFER, b->fbo);
    glBindTexture(GL_TEXTURE_2D, r->small_tex);
    glUniform2f(g->step_uv, 0, 1.f / ah);
    glUniform4f(g->limits, .5f / aw, (vy1 + .5f) / ah, (small_w - .5f) / aw, (vy2 - .5f) / ah);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindFramebuffer(GL_FRAMEBUFFER, pass_fbo);
    glViewport(0, 0, p->buffer->width, p->buffer->height);
}
void rediwm_scene_pass_add_backdrop(struct wlr_render_pass *base, const struct rediwm_pass_shape *shape,
        struct wlr_box box, const struct rediwm_pass_backdrop *o) {
    struct pass *p = owned_pass(base);
    struct program *g = &p->renderer->shaped;
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    const struct rediwm_backdrop *b = o->backdrop;
    if (!g->id || !shape_usable(shape) || !b || !b->width || !isfinite(o->saturation) ||
            !isfinite(o->opacity) || !isfinite(o->front_opacity)) {
        p->failed = true;
        return;
    }
    struct wlr_gles2_texture_attribs front = {0};
    if (o->front) {
        if (!wlr_texture_is_gles2(o->front) || o->front_box.width <= 0 || o->front_box.height <= 0) {
            p->failed = true;
            return;
        }
        wlr_gles2_texture_get_attribs(o->front, &front);
    }
    const bool has_front = o->front && front.target == GL_TEXTURE_2D;
    setup(p, g, box, WLR_RENDER_BLEND_MODE_PREMULTIPLIED);
    struct rediwm_pass_shape bare = *shape; // the ring belongs to the surface over it
    bare.border = 0;
    set_shape(p, g, &bare);
    glUniform1f(g->mode, 3.f);
    glUniform1f(g->alpha, o->opacity);
    glUniform1f(g->saturation, o->saturation);
    glUniform4f(g->bmap, shape->box.x - b->x, shape->box.y - b->y, 1.f / b->extent_w, 1.f / b->extent_h);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, has_front ? front.tex : 0);
    if (has_front) {
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }
    glUniform1f(g->has_front, has_front ? 1.f : 0.f);
    glUniform1f(g->front_alpha, o->front_opacity);
    glUniform4f(g->fmap, shape->box.x - o->front_box.x, shape->box.y - o->front_box.y,
        has_front ? 1.f / o->front_box.width : 0, has_front ? 1.f / o->front_box.height : 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, b->tex);
    glUniform1i(g->sampler, 0);
    draw(p, o->clip);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0);
}

