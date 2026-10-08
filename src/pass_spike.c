// Stage 1 spike of docs/plans/scene-graph.md: the primitives an owned output
// pass needs, drawn on wlroots' own GLES2 context and a wlroots-allocated
// buffer's FBO exactly as glass.c does. Not installed and not linked into the
// compositor; pass_spike_test.c holds the pixel gates. If the design survives,
// stage 2/3 move this into the compositor.
//
// Conventions: device pixels, y down, row 0 of the buffer is the top row (the
// vertex shader maps py/height straight to NDC y, so memory order is image
// order, as in glass.c). Colours are premultiplied. A "shape" is an integer
// device rectangle with one corner radius per corner; every piece of a window
// (titlebar, client, footer, border, shadow) is covered by the same signed
// distance function, so there is no per-piece corner approximation.
#define _POSIX_C_SOURCE 200809L
#define WLR_USE_UNSTABLE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <assert.h>
#include <drm_fourcc.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/render/egl.h>
#include <wlr/render/gles2.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/util/log.h>

// ---------------------------------------------------------------------------
// Context: the renderer's own EGL context, saved and restored around the pass.
struct spike_gl_state {
	EGLDisplay display, previous_display;
	EGLContext previous_context;
	EGLSurface draw, read;
	GLint fbo, program, array_buffer, active_texture, texture, viewport[4];
	GLboolean blend, scissor;
};

struct spike {
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	GLuint vertices;
	struct spike_program {
		GLuint id;
		GLint dst, target, rect, size, radii, border, bcolor, color, alpha, mode, content, src,
		    shadow, opaque, tex, saturation, tint;
	} plain, external;
	struct spike_blur {
		GLuint id;
		GLint tex, step_uv, sigma, limits;
	} blur;
	PFNEGLCREATEIMAGEKHRPROC create_image;
	PFNEGLDESTROYIMAGEKHRPROC destroy_image;
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target_texture;
	bool has_external;
};

static bool spike_enter(struct spike *spike, struct spike_gl_state *state)
{
	struct wlr_egl *egl = wlr_gles2_renderer_get_egl(spike->renderer);
	state->display = wlr_egl_get_display(egl);
	state->previous_display = eglGetCurrentDisplay();
	state->previous_context = eglGetCurrentContext();
	state->draw = eglGetCurrentSurface(EGL_DRAW);
	state->read = eglGetCurrentSurface(EGL_READ);
	if (!eglMakeCurrent(state->display, EGL_NO_SURFACE, EGL_NO_SURFACE, wlr_egl_get_context(egl)))
		return false;
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &state->fbo);
	glGetIntegerv(GL_CURRENT_PROGRAM, &state->program);
	glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &state->array_buffer);
	glGetIntegerv(GL_ACTIVE_TEXTURE, &state->active_texture);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &state->texture);
	glGetIntegerv(GL_VIEWPORT, state->viewport);
	state->blend = glIsEnabled(GL_BLEND);
	state->scissor = glIsEnabled(GL_SCISSOR_TEST);
	return true;
}
static void spike_leave(struct spike_gl_state *state)
{
	glBindFramebuffer(GL_FRAMEBUFFER, state->fbo);
	glUseProgram(state->program);
	glBindTexture(GL_TEXTURE_2D, state->texture);
	glActiveTexture(state->active_texture);
	glViewport(state->viewport[0], state->viewport[1], state->viewport[2], state->viewport[3]);
	(state->blend ? glEnable : glDisable)(GL_BLEND);
	(state->scissor ? glEnable : glDisable)(GL_SCISSOR_TEST);
	glBindBuffer(GL_ARRAY_BUFFER, state->array_buffer);
	if (state->previous_display != EGL_NO_DISPLAY)
		eglMakeCurrent(state->previous_display, state->draw, state->read,
			       state->previous_context);
	else
		eglMakeCurrent(state->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

// ---------------------------------------------------------------------------
// Shaders. One fragment source, built for a 2D or an external-OES sampler.
static const char spike_vertex_source[] =
    "attribute vec2 position; uniform vec4 dst; uniform vec2 target; uniform vec4 rect;"
    "varying vec2 v_px;"
    "void main(){ vec2 px=dst.xy+position*dst.zw; v_px=px-rect.xy;"
    "gl_Position=vec4(px.x/target.x*2.-1.,px.y/target.y*2.-1.,0.,1.); }";

static const char spike_fragment_body[] =
    "precision highp float; varying vec2 v_px;"
    "uniform vec2 size; uniform vec4 radii, color, bcolor, content, src, shadow;"
    "uniform float border, alpha, mode, opaque, saturation; uniform vec4 tint;"
    "float sdf(vec2 p, vec2 sz, vec4 r){ vec2 q=p-sz*.5;"
    "float rad=q.x<0.?(q.y<0.?r.x:r.w):(q.y<0.?r.y:r.z);"
    "vec2 d=abs(q)-(sz*.5-vec2(rad));"
    "return length(max(d,0.))+min(max(d.x,d.y),0.)-rad; }"
    "float cov(float d){ return clamp(.5-d,0.,1.); }"
    // Abramowitz-Stegun 7.1.26, |error| < 1.5e-7.
    "float erf1(float x){ float s=x<0.?-1.:1.; x=abs(x); float t=1./(1.+.3275911*x);"
    "float y=1.-(((((1.061405429*t-1.453152027)*t)+1.421413741)*t-.284496736)*t+.254829592)*t*exp(-x*x);"
    "return s*y; }"
    "vec4 sample_content(){ vec2 uv=mix(src.xy,src.zw,(v_px-content.xy)/content.zw);"
    "return texture2D(tex,uv); }"
    "void main(){"
    "float d=sdf(v_px,size,radii);"
    // 0: texture body, 1: solid body. A border is part of the same pass: the
    // body keeps the inside of the inset shape and the ring the rest, both
    // evaluated at this fragment, so their coverages add to the shape's. As
    // two draws they would multiply (a seam where each is partly covered).
    "if(mode<1.5){ float inner=border>0.?cov(d+border):cov(d);"
    "float ring=border>0.?cov(d)-cov(d+border):0.;"
    "vec4 t=mode<.5?sample_content():color; if(opaque>.5) t.a=1.;"
    "gl_FragColor=t*alpha*inner+bcolor*ring; }"
    // 3: shadow, a Gaussian-blurred shape approximated through its distance field.
    "else if(mode<3.5){ float ds=sdf(v_px-shadow.xy,size,radii);"
    "float s=.5*(1.-erf1(ds/(shadow.z*1.41421356)));"
    "if(shadow.w>.5) s*=1.-cov(d); gl_FragColor=color*s; }"
    // 4: blurred backdrop composited through the clip.
    "else { vec3 rgb=sample_content().rgb; float l=dot(rgb,vec3(.213,.715,.072));"
    "rgb=clamp(vec3(l)+(rgb-vec3(l))*saturation,0.,1.); rgb=mix(rgb,tint.rgb,tint.a);"
    "float inner=border>0.?cov(d+border):cov(d); float ring=border>0.?cov(d)-cov(d+border):0.;"
    "gl_FragColor=vec4(rgb,1.)*inner*alpha+bcolor*ring; }"
    "}";

static const char spike_blur_vertex[] =
    "attribute vec2 position; varying vec2 uv;"
    "void main(){ uv=position*.5+.5; gl_Position=vec4(position,0.,1.); }";
// The kernel glass.c uses: 49 taps, sigma in texels of the target.
static const char spike_blur_fragment[] =
    "precision highp float; varying vec2 uv; uniform sampler2D tex;"
    "uniform vec2 step_uv; uniform float sigma; uniform vec4 limits;"
    "void main(){ vec4 sum=vec4(0.); float weight=0.;"
    "for(int i=-24;i<=24;i++){ float x=float(i); float w=exp(-.5*x*x/(sigma*sigma));"
    "sum+=texture2D(tex,clamp(uv+x*step_uv,limits.xy,limits.zw))*w; weight+=w; }"
    "gl_FragColor=sum/weight; }";

static GLuint spike_shader(GLenum type, const char *prefix, const char *source)
{
	const char *parts[2] = {prefix, source};
	GLuint id = glCreateShader(type);
	glShaderSource(id, 2, parts, NULL);
	glCompileShader(id);
	GLint ok;
	glGetShaderiv(id, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024];
		glGetShaderInfoLog(id, sizeof(log), NULL, log);
		fprintf(stderr, "spike shader: %s\n", log);
		glDeleteShader(id);
		return 0;
	}
	return id;
}
static GLuint spike_link(const char *vertex_prefix, const char *vertex, const char *fragment_prefix,
			 const char *fragment)
{
	GLuint vs = spike_shader(GL_VERTEX_SHADER, vertex_prefix, vertex);
	GLuint fs = spike_shader(GL_FRAGMENT_SHADER, fragment_prefix, fragment);
	if (!vs || !fs)
		return 0;
	GLuint id = glCreateProgram();
	glAttachShader(id, vs);
	glAttachShader(id, fs);
	glBindAttribLocation(id, 0, "position");
	glLinkProgram(id);
	glDeleteShader(vs);
	glDeleteShader(fs);
	GLint ok;
	glGetProgramiv(id, GL_LINK_STATUS, &ok);
	return ok ? id : 0;
}
static bool spike_build_program(struct spike_program *p, bool external)
{
	const char *prefix = external ? "#extension GL_OES_EGL_image_external : require\n"
				        "#define EXTERNAL\nprecision highp float;\n"
				        "uniform samplerExternalOES tex;\n"
				      : "precision highp float;\nuniform sampler2D tex;\n";
	// The sampler declaration comes before the shared body, which only uses it.
	p->id = spike_link("", spike_vertex_source, prefix, spike_fragment_body);
	if (!p->id)
		return false;
#define LOC(field, name) p->field = glGetUniformLocation(p->id, name)
	LOC(dst, "dst"), LOC(target, "target"), LOC(rect, "rect"), LOC(size, "size");
	LOC(radii, "radii"), LOC(border, "border"), LOC(bcolor, "bcolor"), LOC(color, "color");
	LOC(alpha, "alpha");
	LOC(mode, "mode"), LOC(content, "content"), LOC(src, "src"), LOC(shadow, "shadow");
	LOC(opaque, "opaque"), LOC(tex, "tex"), LOC(saturation, "saturation"), LOC(tint, "tint");
#undef LOC
	return true;
}

static struct spike *spike_create(struct wlr_renderer *renderer, struct wlr_allocator *allocator)
{
	if (!wlr_renderer_is_gles2(renderer))
		return NULL;
	struct spike *spike = calloc(1, sizeof(*spike));
	assert(spike);
	spike->renderer = renderer;
	spike->allocator = allocator;
	struct spike_gl_state state;
	if (!spike_enter(spike, &state)) {
		free(spike);
		return NULL;
	}
	bool ok = spike_build_program(&spike->plain, false);
	spike->has_external = wlr_gles2_renderer_check_ext(renderer, "GL_OES_EGL_image_external");
	if (spike->has_external) {
		spike->create_image = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
		spike->destroy_image = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
		spike->image_target_texture = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress(
		    "glEGLImageTargetTexture2DOES");
		spike->has_external = spike->create_image && spike->destroy_image &&
				      spike->image_target_texture && spike_build_program(&spike->external, true);
	}
	spike->blur.id = spike_link("", spike_blur_vertex, "", spike_blur_fragment);
	ok = ok && spike->blur.id;
	spike->blur.tex = glGetUniformLocation(spike->blur.id, "tex");
	spike->blur.step_uv = glGetUniformLocation(spike->blur.id, "step_uv");
	spike->blur.sigma = glGetUniformLocation(spike->blur.id, "sigma");
	spike->blur.limits = glGetUniformLocation(spike->blur.id, "limits");
	const GLfloat quad[] = {0, 0, 1, 0, 0, 1, 1, 1};
	glGenBuffers(1, &spike->vertices);
	glBindBuffer(GL_ARRAY_BUFFER, spike->vertices);
	glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
	spike_leave(&state);
	if (!ok) {
		free(spike);
		return NULL;
	}
	return spike;
}

// ---------------------------------------------------------------------------
// Targets: a wlroots-allocated buffer drawn through the renderer's FBO for it.
struct spike_target {
	struct wlr_buffer *buffer;
	GLuint fbo;
	int width, height;
};
static bool spike_target_create(struct spike *spike, struct spike_target *target, int width,
				int height)
{
	uint64_t modifier = DRM_FORMAT_MOD_INVALID;
	struct wlr_drm_format format = {
	    .format = DRM_FORMAT_ARGB8888, .len = 1, .capacity = 1, .modifiers = &modifier};
	target->buffer = wlr_allocator_create_buffer(spike->allocator, width, height, &format);
	if (!target->buffer)
		return false;
	target->width = width;
	target->height = height;
	target->fbo = wlr_gles2_renderer_get_buffer_fbo(spike->renderer, target->buffer);
	return target->fbo != 0;
}

// ---------------------------------------------------------------------------
// Drawing.
struct spike_shape {
	int x, y, w, h;	  // integer device rectangle
	float radii[4];	  // tl, tr, br, bl, device px
};
struct spike_texture {
	GLenum target;	  // GL_TEXTURE_2D or GL_TEXTURE_EXTERNAL_OES
	GLuint id;
	bool opaque;	  // XRGB: alpha is not meaningful
};

static struct spike_program *spike_program_for(struct spike *spike, GLenum target)
{
	return target == GL_TEXTURE_EXTERNAL_OES ? &spike->external : &spike->plain;
}
static void spike_bind_quad(void)
{
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
}
static void spike_set_common(struct spike *spike, struct spike_program *p, struct spike_target *t,
			     const struct spike_shape *shape, float border, const float *bcolor)
{
	glUseProgram(p->id);
	glBindBuffer(GL_ARRAY_BUFFER, spike->vertices);
	spike_bind_quad();
	glUniform2f(p->target, t->width, t->height);
	glUniform4f(p->rect, shape->x, shape->y, shape->w, shape->h);
	glUniform2f(p->size, shape->w, shape->h);
	glUniform4f(p->radii, shape->radii[0], shape->radii[1], shape->radii[2], shape->radii[3]);
	glUniform1f(p->border, border);
	glUniform4f(p->bcolor, bcolor ? bcolor[0] : 0, bcolor ? bcolor[1] : 0, bcolor ? bcolor[2] : 0,
		    bcolor ? bcolor[3] : 0);
	glUniform1f(p->alpha, 1.f);
	glUniform1f(p->opaque, 0.f);
	glUniform1f(p->saturation, 1.f);
	glUniform4f(p->tint, 0, 0, 0, 0);
	glUniform4f(p->shadow, 0, 0, 1, 0);
	glUniform1i(p->tex, 0);
}
// A quad in shape-local device pixels; (x, y, w, h) is also the piece's content rectangle.
static void spike_quad(struct spike_program *p, const struct spike_shape *shape, float x, float y,
		       float w, float h)
{
	glUniform4f(p->dst, shape->x + x, shape->y + y, w, h);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static void spike_begin(struct spike_target *t)
{
	glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
	glViewport(0, 0, t->width, t->height);
	// Premultiplied "over": the same blend wlroots' own pass uses. The scissor
	// is the caller's: a partial repaint keeps it across every piece.
	glEnable(GL_BLEND);
	glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

// A solid piece of the window body: rect (x, y, w, h) in shape-local pixels.
static void spike_solid(struct spike *spike, struct spike_target *t, const struct spike_shape *shape,
			float border, const float *bcolor, const float color[4], int x, int y, int w,
			int h)
{
	struct spike_program *p = &spike->plain;
	spike_set_common(spike, p, t, shape, border, bcolor);
	glUniform1f(p->mode, 1.f);
	glUniform4f(p->color, color[0], color[1], color[2], color[3]);
	spike_quad(p, shape, x, y, w, h);
}
// A textured piece: the whole texture (or `src`, in uv) is stretched over (x, y, w, h).
static void spike_textured(struct spike *spike, struct spike_target *t,
			   const struct spike_shape *shape, float border, const float *bcolor,
			   const struct spike_texture *tex, const float src[4], float alpha, int x,
			   int y, int w, int h)
{
	struct spike_program *p = spike_program_for(spike, tex->target);
	spike_set_common(spike, p, t, shape, border, bcolor);
	glUniform1f(p->mode, 0.f);
	glUniform4f(p->content, x, y, w, h);
	glUniform4f(p->src, src[0], src[1], src[2], src[3]);
	glUniform1f(p->alpha, alpha);
	glUniform1f(p->opaque, tex->opaque);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(tex->target, tex->id);
	glTexParameteri(tex->target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(tex->target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(tex->target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(tex->target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	spike_quad(p, shape, x, y, w, h);
	glBindTexture(tex->target, 0);
}
// Shadow behind the shape: drawn over a quad that reaches 3 sigma past it.
static void spike_shadow(struct spike *spike, struct spike_target *t, const struct spike_shape *shape,
			 float offset_x, float offset_y, float sigma, const float color[4],
			 bool clip_inside)
{
	struct spike_program *p = &spike->plain;
	spike_set_common(spike, p, t, shape, 0, NULL);
	glUniform1f(p->mode, 3.f);
	glUniform4f(p->color, color[0], color[1], color[2], color[3]);
	glUniform4f(p->shadow, offset_x, offset_y, sigma, clip_inside ? 1.f : 0.f);
	int pad = (int)ceilf(3 * sigma) + (int)ceilf(fmaxf(fabsf(offset_x), fabsf(offset_y)));
	spike_quad(p, shape, -pad, -pad, shape->w + 2 * pad, shape->h + 2 * pad);
}

// ---------------------------------------------------------------------------
// Backdrop effect: copy the framebuffer under the shape, blur it at quarter
// size in two separable passes, composite through the clip. Replaces glass.c's
// prefix re-render of the scene into a private buffer.
struct spike_backdrop {
	GLuint copy, a, b;
	GLuint fbo_a, fbo_b;
	int copy_w, copy_h, small_w, small_h;
};
static GLuint spike_texture_new(int w, int h)
{
	GLuint id;
	glGenTextures(1, &id);
	glBindTexture(GL_TEXTURE_2D, id);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	return id;
}
static void spike_backdrop_init(struct spike_backdrop *b, int copy_w, int copy_h)
{
	b->copy_w = copy_w;
	b->copy_h = copy_h;
	b->small_w = (copy_w + 3) / 4;
	b->small_h = (copy_h + 3) / 4;
	b->copy = spike_texture_new(copy_w, copy_h);
	b->a = spike_texture_new(b->small_w, b->small_h);
	b->b = spike_texture_new(b->small_w, b->small_h);
	glGenFramebuffers(1, &b->fbo_a);
	glBindFramebuffer(GL_FRAMEBUFFER, b->fbo_a);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, b->a, 0);
	glGenFramebuffers(1, &b->fbo_b);
	glBindFramebuffer(GL_FRAMEBUFFER, b->fbo_b);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, b->b, 0);
}
static void spike_backdrop_destroy(struct spike_backdrop *b)
{
	glDeleteTextures(1, &b->copy);
	glDeleteTextures(1, &b->a);
	glDeleteTextures(1, &b->b);
	glDeleteFramebuffers(1, &b->fbo_a);
	glDeleteFramebuffers(1, &b->fbo_b);
}
struct spike_blur_params {
	float sigma;		// device px
	float saturation;
	float tint[4];		// rgb, mix amount
	float alpha;
	int padding;		// capture margin around the shape, device px
	float border;		// device px; the ring is drawn in the composite pass
	float border_color[4];
};
// Returns false when the capture could not be taken.
static void spike_backdrop_draw(struct spike *spike, struct spike_target *t,
				struct spike_backdrop *b, const struct spike_shape *shape,
				const struct spike_blur_params *params)
{
	// 1. Copy the region the blur reads, clamped to the framebuffer. Texels
	// that fall outside are replicated by CLAMP_TO_EDGE, never black.
	int x0 = shape->x - params->padding, y0 = shape->y - params->padding;
	int x1 = x0 + b->copy_w, y1 = y0 + b->copy_h;
	int cx0 = x0 < 0 ? 0 : x0, cy0 = y0 < 0 ? 0 : y0;
	int cx1 = x1 > t->width ? t->width : x1, cy1 = y1 > t->height ? t->height : y1;
	// The caller's scissor limits what is repainted, not what is read or blurred.
	const GLboolean scissored = glIsEnabled(GL_SCISSOR_TEST);
	glDisable(GL_SCISSOR_TEST);
	glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, b->copy);
	glCopyTexSubImage2D(GL_TEXTURE_2D, 0, cx0 - x0, cy0 - y0, cx0, cy0, cx1 - cx0, cy1 - cy0);
	// 2. Separable blur at quarter size: horizontal into a, vertical into b.
	glDisable(GL_BLEND);
	glUseProgram(spike->blur.id);
	glBindBuffer(GL_ARRAY_BUFFER, spike->vertices);
	const GLfloat clip_quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
	GLuint clip_vbo;
	glGenBuffers(1, &clip_vbo);
	glBindBuffer(GL_ARRAY_BUFFER, clip_vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(clip_quad), clip_quad, GL_STREAM_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
	glUniform1i(spike->blur.tex, 0);
	float sigma_small = params->sigma / 4.f;
	glUniform1f(spike->blur.sigma, sigma_small);
	float lx = (float)(cx0 - x0) / b->copy_w + .5f / b->copy_w;
	float ly = (float)(cy0 - y0) / b->copy_h + .5f / b->copy_h;
	float hx = (float)(cx1 - x0) / b->copy_w - .5f / b->copy_w;
	float hy = (float)(cy1 - y0) / b->copy_h - .5f / b->copy_h;
	glViewport(0, 0, b->small_w, b->small_h);
	glBindFramebuffer(GL_FRAMEBUFFER, b->fbo_a);
	glUniform2f(spike->blur.step_uv, 1.f / b->small_w, 0);
	glUniform4f(spike->blur.limits, lx, ly, hx, hy);
	glBindTexture(GL_TEXTURE_2D, b->copy);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	glBindFramebuffer(GL_FRAMEBUFFER, b->fbo_b);
	glUniform2f(spike->blur.step_uv, 0, 1.f / b->small_h);
	glUniform4f(spike->blur.limits, 0.f, 0.f, 1.f, 1.f);
	glBindTexture(GL_TEXTURE_2D, b->a);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	glDeleteBuffers(1, &clip_vbo);
	// 3. Composite through the clip.
	spike_begin(t);
	if (scissored)
		glEnable(GL_SCISSOR_TEST);
	struct spike_program *p = &spike->plain;
	spike_set_common(spike, p, t, shape, params->border, params->border_color);
	glUniform1f(p->mode, 4.f);
	glUniform4f(p->content, -params->padding, -params->padding, b->copy_w, b->copy_h);
	glUniform4f(p->src, 0, 0, 1, 1);
	glUniform1f(p->saturation, params->saturation);
	glUniform4f(p->tint, params->tint[0], params->tint[1], params->tint[2], params->tint[3]);
	glUniform1f(p->alpha, params->alpha);
	glBindTexture(GL_TEXTURE_2D, b->b);
	spike_quad(p, shape, 0, 0, shape->w, shape->h);
	glBindTexture(GL_TEXTURE_2D, 0);
}

// ---------------------------------------------------------------------------
// Readback in image order (row 0 = top) for the tests.
static void spike_read(struct spike_target *t, uint8_t *rgba)
{
	glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
	glPixelStorei(GL_PACK_ALIGNMENT, 1);
	glReadPixels(0, 0, t->width, t->height, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
}
static void spike_clear(struct spike_target *t, const float color[4])
{
	glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
	glDisable(GL_SCISSOR_TEST);
	glClearColor(color[0], color[1], color[2], color[3]);
	glClear(GL_COLOR_BUFFER_BIT);
}
