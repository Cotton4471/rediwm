// Pixel gates for the stage 1 pass spike (docs/plans/scene-graph.md); run with
// `zig build test-pass-spike` on a GLES2 host. Each gate is a criterion the
// plan names: no seams or fringe at any scale or zoom, correct premultiplied
// edges, an external-OES texture identical to a 2D one, buffer-age damage
// correct under a backdrop effect, and cost within the stage 0 baseline.
#include "pass_spike.c"
#include <stdarg.h>
#include <wlr/backend/headless.h>
#include <wlr/render/dmabuf.h>
#include <wlr/render/pass.h>

static const float BG[4] = {224 / 255.f, 225 / 255.f, 232 / 255.f, 1};
static const float BODY[4] = {16 / 255.f, 18 / 255.f, 21 / 255.f, 1};
static const float SCALES[] = {1.f, 1.5f, 2.f};
static const float ZOOMS[] = {1.f, .85f, .70f, .55f, .25f};

static void check(bool ok, const char *what, ...)
{
	if (ok)
		return;
	char text[256];
	va_list args;
	va_start(args, what);
	vsnprintf(text, sizeof(text), what, args);
	va_end(args);
	fprintf(stderr, "FAIL: %s\n", text);
	exit(1);
}

struct image {
	int w, h;
	uint8_t *p;
};
static uint8_t *at(const struct image *img, int x, int y) { return img->p + 4 * (y * img->w + x); }
static void read_image(struct spike_target *t, struct image *img)
{
	img->w = t->width;
	img->h = t->height;
	img->p = realloc(img->p, 4 * img->w * img->h);
	spike_read(t, img->p);
}
static int diff(int a, int b) { return abs(a - b); }

// The snapping rule AGENTS.md states: a node's device box is round(off*s) to
// round((off+len)*s), never round(len*s), so neighbours share an edge.
static int snap(double v) { return (int)lround(v); }
struct boxes {
	struct spike_shape shape;
	int title_h, footer_h;
};
static struct boxes window_boxes(float scale, float zoom, float radius_logical)
{
	const float k = scale * zoom;
	struct boxes b;
	int x0 = snap(30 * k), y0 = snap(24 * k);
	b.shape.x = x0 + 8;
	b.shape.y = y0 + 8;
	b.shape.w = snap((30 + 200) * k) - x0;
	b.shape.h = snap((24 + 140) * k) - y0;
	for (int i = 0; i < 4; i++)
		b.shape.radii[i] = radius_logical * k;
	// Title and footer boundaries come from the same snapping as the shape.
	b.title_h = snap((24 + 36) * k) - y0;
	b.footer_h = snap((24 + 140) * k) - snap((24 + 140 - 10) * k);
	return b;
}

// ---- Gate 1: the clip against a supersampled reference -----------------------------
static bool inside_rrect(double px, double py, const struct spike_shape *s)
{
	double x = px - s->x, y = py - s->y;
	if (x < 0 || y < 0 || x > s->w || y > s->h)
		return false;
	double r = (x < s->w / 2.) ? (y < s->h / 2. ? s->radii[0] : s->radii[3])
				    : (y < s->h / 2. ? s->radii[1] : s->radii[2]);
	double cx = x < s->w / 2. ? r : s->w - r, cy = y < s->h / 2. ? r : s->h - r;
	bool corner = (x < r || x > s->w - r) && (y < r || y > s->h - r);
	if (!corner)
		return true;
	return hypot(x - cx, y - cy) <= r;
}
static double reference_coverage(const struct spike_shape *s, int x, int y)
{
	const int n = 8;
	int hits = 0;
	for (int j = 0; j < n; j++)
		for (int i = 0; i < n; i++)
			hits += inside_rrect(x + (i + .5) / n, y + (j + .5) / n, s);
	return (double)hits / (n * n);
}
static void gate_clip_accuracy(struct spike *spike, struct spike_target *t, struct image *img)
{
	int worst = 0, fringe = 0;
	for (size_t si = 0; si < sizeof(SCALES) / sizeof(*SCALES); si++)
		for (size_t zi = 0; zi < sizeof(ZOOMS) / sizeof(*ZOOMS); zi++) {
			struct boxes b = window_boxes(SCALES[si], ZOOMS[zi], 10);
			spike_clear(t, BG);
			spike_begin(t);
			spike_solid(spike, t, &b.shape, 0, NULL, BODY, 0, 0, b.shape.w, b.shape.h);
			read_image(t, img);
			for (int y = b.shape.y - 2; y < b.shape.y + b.shape.h + 2; y++)
				for (int x = b.shape.x - 2; x < b.shape.x + b.shape.w + 2; x++) {
					double c = reference_coverage(&b.shape, x, y);
					const uint8_t bg[3] = {224, 225, 232}, body[3] = {16, 18, 21};
					for (int ch = 0; ch < 3; ch++) {
						double expect = bg[ch] * (1 - c) + body[ch] * c;
						int got = at(img, x, y)[ch];
						if (diff(got, (int)lround(expect)) > worst)
							worst = diff(got, (int)lround(expect));
						// No fringe: never outside the range of the two colours.
						int lo = body[ch] < bg[ch] ? body[ch] : bg[ch];
						int hi = body[ch] < bg[ch] ? bg[ch] : body[ch];
						if (got < lo - 1 || got > hi + 1)
							fringe++;
					}
				}
		}
	check(fringe == 0, "gate 1: %d channel values fall outside the bg/body range (fringe)", fringe);
	// Distance-field AA is the formula glass.c already uses; the bound documents
	// how far it sits from true area coverage (6% of the 208-level range).
	check(worst <= 14, "gate 1: clip differs from supersampled coverage by %d levels", worst);
	printf("PASS gate 1: rounded clip within %d levels of area coverage, no fringe, "
	       "%zu scales x %zu zoom steps\n",
	       worst, sizeof(SCALES) / sizeof(*SCALES), sizeof(ZOOMS) / sizeof(*ZOOMS));
}

// ---- Gate 2: pieces of one window share the clip, with no seam ---------------------
static void gate_no_seams(struct spike *spike, struct spike_target *t, struct image *img)
{
	const float red[4] = {1, 0, 0, 1}, green[4] = {0, 1, 0, 1}, blue[4] = {0, 0, 1, 1};
	for (size_t si = 0; si < sizeof(SCALES) / sizeof(*SCALES); si++)
		for (size_t zi = 0; zi < sizeof(ZOOMS) / sizeof(*ZOOMS); zi++) {
			struct boxes b = window_boxes(SCALES[si], ZOOMS[zi], 10);
			struct spike_shape *s = &b.shape;
			spike_clear(t, BG);
			spike_begin(t);
			spike_solid(spike, t, s, 0, NULL, red, 0, 0, s->w, b.title_h);
			spike_solid(spike, t, s, 0, NULL, green, 0, b.title_h, s->w, s->h - b.title_h - b.footer_h);
			spike_solid(spike, t, s, 0, NULL, blue, 0, s->h - b.footer_h, s->w, b.footer_h);
			read_image(t, img);
			int margin = (int)ceilf(s->radii[0]) + 2;
			for (int y = 0; y < s->h; y++)
				for (int x = margin; x < s->w - margin; x++) {
					const float *want = y < b.title_h ? red : y < s->h - b.footer_h ? green : blue;
					uint8_t *px = at(img, s->x + x, s->y + y);
					for (int ch = 0; ch < 3; ch++)
						check(diff(px[ch], (int)lround(want[ch] * 255)) <= 1,
						      "gate 2: seam at scale %.2f zoom %.2f, row %d col %d channel %d = %d",
						      SCALES[si], ZOOMS[zi], y, x, ch, px[ch]);
				}
		}
	puts("PASS gate 2: titlebar, client and footer pieces meet without a seam at every scale and zoom");
}

// ---- Gate 3: border and body partition the shape's coverage -------------------------
static void gate_border_partition(struct spike *spike, struct spike_target *t, struct image *img,
				  struct image *ref)
{
	int worst = 0;
	for (size_t si = 0; si < sizeof(SCALES) / sizeof(*SCALES); si++)
		for (size_t zi = 0; zi < sizeof(ZOOMS) / sizeof(*ZOOMS); zi++) {
			struct boxes b = window_boxes(SCALES[si], ZOOMS[zi], 10);
			struct spike_shape *s = &b.shape;
			float border = fmaxf(1.f, roundf(1.f * SCALES[si] * ZOOMS[zi]));
			// Ring and body in one colour, in three pieces: the result must equal
			// a plain body, whatever the split between them, or coverage leaks.
			spike_clear(t, BG);
			spike_begin(t);
			spike_solid(spike, t, s, 0, NULL, BODY, 0, 0, s->w, s->h);
			read_image(t, ref);
			spike_clear(t, BG);
			spike_begin(t);
			spike_solid(spike, t, s, border, BODY, BODY, 0, 0, s->w, b.title_h);
			spike_solid(spike, t, s, border, BODY, BODY, 0, b.title_h, s->w, s->h - b.title_h - b.footer_h);
			spike_solid(spike, t, s, border, BODY, BODY, 0, s->h - b.footer_h, s->w, b.footer_h);
			read_image(t, img);
			for (int i = 0; i < img->w * img->h * 4; i++)
				if (diff(img->p[i], ref->p[i]) > worst)
					worst = diff(img->p[i], ref->p[i]);
			// And the ring really is the ring: its own colour on the outer row of a
			// straight edge, the body colour just inside it.
			const float ring[4] = {1, 0, 0, 1};
			spike_clear(t, BG);
			spike_begin(t);
			spike_solid(spike, t, s, border, ring, BODY, 0, 0, s->w, s->h);
			read_image(t, img);
			int cx = s->x + s->w / 2;
			check(at(img, cx, s->y)[0] >= 254 && at(img, cx, s->y)[1] <= 1,
			      "gate 3: outer row is not the border colour at scale %.2f zoom %.2f", SCALES[si], ZOOMS[zi]);
			check(diff(at(img, cx, s->y + (int)border)[0], 16) <= 1,
			      "gate 3: row inside the border is not the body at scale %.2f zoom %.2f", SCALES[si], ZOOMS[zi]);
		}
	check(worst <= 2, "gate 3: border + body differ from one shape by %d levels", worst);
	printf("PASS gate 3: border ring and body, evaluated in one pass, add up to exactly the shape's coverage (max diff %d)\n", worst);
}

// ---- Gate 4: premultiplied texture edges and opaque (XRGB) textures ------------------
static GLuint texture_2d(int w, int h, const uint8_t *rgba)
{
	GLuint id;
	glGenTextures(1, &id);
	glBindTexture(GL_TEXTURE_2D, id);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
	return id;
}
static void gate_premultiplied(struct spike *spike, struct spike_target *t, struct image *img)
{
	// 50% red, premultiplied: (64, 0, 0, 128) is a quarter-intensity red over 50% alpha.
	uint8_t half[4 * 4 * 4];
	for (int i = 0; i < 16; i++)
		memcpy(half + 4 * i, (uint8_t[]){128, 0, 0, 128}, 4);
	struct spike_texture tex = {GL_TEXTURE_2D, texture_2d(4, 4, half), false};
	struct spike_shape s = {40, 40, 80, 80, {0, 0, 0, 0}};
	const float src[4] = {0, 0, 1, 1};
	spike_clear(t, BG);
	spike_begin(t);
	spike_textured(spike, t, &s, 0, NULL, &tex, src, 1.f, 0, 0, 80, 80);
	read_image(t, img);
	uint8_t *px = at(img, 80, 80);
	// premultiplied "over": 128 + 224*(1-.50196) = 239.5 red; 0 + 225*.498 = 112; 232*.498 = 115.5
	check(diff(px[0], 240) <= 2 && diff(px[1], 112) <= 2 && diff(px[2], 116) <= 2,
	      "gate 4: premultiplied half-transparent texel gave (%d,%d,%d)", px[0], px[1], px[2]);
	// Opacity: alpha .5 on an opaque white texel is a 50% mix with the backdrop.
	uint8_t white[4] = {255, 255, 255, 255};
	struct spike_texture w = {GL_TEXTURE_2D, texture_2d(1, 1, white), false};
	spike_clear(t, (float[4]){0, 0, 0, 1});
	spike_begin(t);
	spike_textured(spike, t, &s, 0, NULL, &w, src, .5f, 0, 0, 80, 80);
	read_image(t, img);
	check(diff(at(img, 80, 80)[0], 128) <= 2, "gate 4: opacity .5 gave %d", at(img, 80, 80)[0]);
	// XRGB: the unused alpha byte must be ignored, not drawn as transparency.
	uint8_t junk[4] = {10, 200, 30, 0};
	struct spike_texture x = {GL_TEXTURE_2D, texture_2d(1, 1, junk), true};
	spike_clear(t, BG);
	spike_begin(t);
	spike_textured(spike, t, &s, 0, NULL, &x, src, 1.f, 0, 0, 80, 80);
	read_image(t, img);
	px = at(img, 80, 80);
	check(diff(px[0], 10) <= 1 && diff(px[1], 200) <= 1 && diff(px[2], 30) <= 1,
	      "gate 4: XRGB texel drawn as (%d,%d,%d)", px[0], px[1], px[2]);
	glDeleteTextures(1, &tex.id);
	glDeleteTextures(1, &w.id);
	glDeleteTextures(1, &x.id);
	puts("PASS gate 4: premultiplied edges, opacity and XRGB textures blend correctly");
}

// ---- Gate 5: an external-OES texture equals the same pixels as a 2D texture ----------
static void gate_external(struct spike *spike, struct spike_target *t, struct image *img,
			  struct image *ref)
{
	if (!spike->has_external) {
		puts("SKIP gate 5: no GL_OES_EGL_image_external");
		return;
	}
	// A dmabuf-backed buffer holding a pattern (drawn through its own FBO), imported
	// twice: as an EGLImage bound to an external texture, and read back into a 2D one.
	struct spike_target src;
	check(spike_target_create(spike, &src, 64, 64), "gate 5: cannot allocate the source dmabuf");
	glBindFramebuffer(GL_FRAMEBUFFER, src.fbo);
	glEnable(GL_SCISSOR_TEST);
	const float colors[4][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {1, 1, 0, 1}};
	for (int i = 0; i < 4; i++) {
		glScissor((i % 2) * 32, (i / 2) * 32, 32, 32);
		glClearColor(colors[i][0], colors[i][1], colors[i][2], colors[i][3]);
		glClear(GL_COLOR_BUFFER_BIT);
	}
	glDisable(GL_SCISSOR_TEST);
	struct image pattern = {0};
	struct spike_target src_view = src;
	read_image(&src_view, &pattern);
	struct wlr_dmabuf_attributes dma;
	check(wlr_buffer_get_dmabuf(src.buffer, &dma), "gate 5: the buffer is not a dmabuf");
	EGLint attribs[32];
	int n = 0;
	attribs[n++] = EGL_WIDTH, attribs[n++] = dma.width;
	attribs[n++] = EGL_HEIGHT, attribs[n++] = dma.height;
	attribs[n++] = EGL_LINUX_DRM_FOURCC_EXT, attribs[n++] = dma.format;
	attribs[n++] = EGL_DMA_BUF_PLANE0_FD_EXT, attribs[n++] = dma.fd[0];
	attribs[n++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT, attribs[n++] = dma.offset[0];
	attribs[n++] = EGL_DMA_BUF_PLANE0_PITCH_EXT, attribs[n++] = dma.stride[0];
	if (dma.modifier != DRM_FORMAT_MOD_INVALID) {
		attribs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, attribs[n++] = dma.modifier & 0xffffffff;
		attribs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, attribs[n++] = dma.modifier >> 32;
	}
	attribs[n++] = EGL_NONE;
	struct wlr_egl *egl = wlr_gles2_renderer_get_egl(spike->renderer);
	EGLImageKHR image = spike->create_image(wlr_egl_get_display(egl), EGL_NO_CONTEXT,
						EGL_LINUX_DMA_BUF_EXT, NULL, attribs);
	check(image != EGL_NO_IMAGE_KHR, "gate 5: eglCreateImageKHR failed (0x%x)", eglGetError());
	struct spike_texture ext = {GL_TEXTURE_EXTERNAL_OES, 0, false};
	glGenTextures(1, &ext.id);
	glBindTexture(GL_TEXTURE_EXTERNAL_OES, ext.id);
	spike->image_target_texture(GL_TEXTURE_EXTERNAL_OES, image);
	struct spike_texture flat = {GL_TEXTURE_2D, texture_2d(64, 64, pattern.p), false};
	const float uv[4] = {0, 0, 1, 1};
	int worst = 0;
	for (size_t si = 0; si < sizeof(SCALES) / sizeof(*SCALES); si++)
		for (size_t zi = 0; zi < sizeof(ZOOMS) / sizeof(*ZOOMS); zi++) {
			struct boxes b = window_boxes(SCALES[si], ZOOMS[zi], 10);
			struct spike_texture *draws[2] = {&flat, &ext};
			struct image *outs[2] = {ref, img};
			for (int k = 0; k < 2; k++) {
				spike_clear(t, BG);
				spike_begin(t);
				spike_textured(spike, t, &b.shape, 0, NULL, draws[k], uv, 1.f, 0, 0, b.shape.w, b.shape.h);
				read_image(t, outs[k]);
			}
			for (int i = 0; i < img->w * img->h * 4; i++)
				if (diff(img->p[i], ref->p[i]) > worst)
					worst = diff(img->p[i], ref->p[i]);
		}
	check(worst <= 2, "gate 5: external texture differs from the 2D one by %d levels", worst);
	glDeleteTextures(1, &ext.id);
	glDeleteTextures(1, &flat.id);
	spike->destroy_image(wlr_egl_get_display(egl), image);
	wlr_buffer_drop(src.buffer);
	free(pattern.p);
	printf("PASS gate 5: external-OES texture through the clip matches the 2D path (max diff %d)\n", worst);
}

// ---- Gate 6: analytic shadow ----------------------------------------------------------
static double erfc_ref(double x) { return erfc(x); }
static void gate_shadow(struct spike *spike, struct spike_target *t, struct image *img)
{
	const float white[4] = {1, 1, 1, 1};
	const float black_half[4] = {0, 0, 0, .5f};
	struct spike_shape s = {80, 60, 200, 120, {0, 0, 0, 0}};
	const float sigma = 12.f, oy = 6.f;
	spike_clear(t, white);
	spike_begin(t);
	spike_shadow(spike, t, &s, 0, oy, sigma, black_half, true);
	read_image(t, img);
	int x = s.x + s.w / 2, bottom = s.y + s.h;
	int worst = 0, last = 0;
	for (int dy = 0; dy < 60; dy++) {
		// Distance of the pixel centre below the offset shape's bottom edge.
		double d = (dy + .5) - oy;
		double expect = 255 * (1 - .5 * .5 * erfc_ref(d / (sigma * 1.41421356237)));
		int got = at(img, x, bottom + dy)[0];
		worst = diff(got, (int)lround(expect)) > worst ? diff(got, (int)lround(expect)) : worst;
		check(got >= last, "gate 6: shadow is not monotonic at %d px (%d after %d)", dy, got, last);
		last = got;
	}
	check(worst <= 3, "gate 6: shadow profile differs from the Gaussian edge by %d levels", worst);
	check(at(img, 10, 10)[0] == 255 && at(img, x, s.y + s.h / 2)[0] == 255,
	      "gate 6: shadow reaches outside its footprint or inside the window");
	printf("PASS gate 6: analytic shadow follows the Gaussian edge (max diff %d), clipped out of the window\n",
	       worst);
}

// ---- Gate 7: backdrop blur from a framebuffer copy -----------------------------------
static void gate_backdrop(struct spike *spike, struct spike_target *t, struct image *img)
{
	const int pad = 60;
	struct spike_shape s = {100, 100, 200, 80, {12, 12, 12, 12}};
	struct spike_blur_params params = {.sigma = 12, .saturation = 1, .tint = {0, 0, 0, 0}, .alpha = 1,
					   .padding = pad};
	struct spike_backdrop b;
	spike_backdrop_init(&b, s.w + 2 * pad, s.h + 2 * pad);
	// Left half red, right half blue.
	spike_clear(t, (float[4]){1, 0, 0, 1});
	glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
	glEnable(GL_SCISSOR_TEST);
	glScissor(200, 0, t->width - 200, t->height);
	glClearColor(0, 0, 1, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glDisable(GL_SCISSOR_TEST);
	spike_backdrop_draw(spike, t, &b, &s, &params);
	read_image(t, img);
	int mid = 200, y = s.y + s.h / 2;
	uint8_t *left = at(img, s.x + 12, y), *center = at(img, mid, y), *right = at(img, s.x + s.w - 12, y);
	check(left[0] >= 250 && left[2] <= 5, "gate 7: far-left backdrop is (%d,%d,%d), expected red", left[0], left[1], left[2]);
	check(right[2] >= 250 && right[0] <= 5, "gate 7: far-right backdrop is (%d,%d,%d), expected blue", right[0], right[1], right[2]);
	check(diff(center[0], 128) <= 8 && diff(center[2], 128) <= 8,
	      "gate 7: blur centre is (%d,%d,%d), expected an even mix", center[0], center[1], center[2]);
	int last = 256;
	for (int x = mid - 40; x <= mid + 40; x++) {
		int r = at(img, x, y)[0];
		check(r <= last, "gate 7: blurred edge is not monotonic at x=%d", x);
		last = r;
	}
	check(at(img, 50, y)[0] == 255 && at(img, 340, y)[2] == 255, "gate 7: pixels outside the clip changed");
	// Nothing drawn outside the shape: the row above is the unblurred backdrop.
	check(at(img, mid - 20, s.y - 2)[0] == 255 && at(img, mid + 20, s.y - 2)[2] == 255,
	      "gate 7: the effect leaked past its clip");
	spike_backdrop_destroy(&b);
	puts("PASS gate 7: backdrop copy, two-pass blur and clipped composite behave as a blur of what is below");
}
// Edge handling: a window at the bottom of the framebuffer samples a replicated
// edge, not black from beyond it.
static void gate_backdrop_edge(struct spike *spike, struct spike_target *t, struct image *img)
{
	const int pad = 60;
	struct spike_shape s = {100, t->height - 60, 200, 60, {0, 0, 0, 0}};
	struct spike_blur_params params = {.sigma = 12, .saturation = 1, .tint = {0, 0, 0, 0}, .alpha = 1, .padding = pad};
	struct spike_backdrop b;
	spike_backdrop_init(&b, s.w + 2 * pad, s.h + 2 * pad);
	spike_clear(t, (float[4]){0, 0, 1, 1});
	spike_backdrop_draw(spike, t, &b, &s, &params);
	read_image(t, img);
	for (int y = s.y; y < t->height; y += 7)
		for (int x = s.x; x < s.x + s.w; x += 9)
			check(at(img, x, y)[2] >= 250 && at(img, x, y)[0] <= 5,
			      "gate 7b: edge blur bled black at (%d,%d): (%d,%d,%d)", x, y, at(img, x, y)[0],
			      at(img, x, y)[1], at(img, x, y)[2]);
	spike_backdrop_destroy(&b);
	puts("PASS gate 7b: a blur at the framebuffer edge replicates the edge, no black bleed");
}

// ---- Gate 8: buffer-age damage under a backdrop effect --------------------------------
struct scene {
	struct spike_shape shape;
	struct spike_backdrop backdrop;
	struct spike_blur_params params;
	int square_x;
};
static void draw_scene(struct spike *spike, struct spike_target *t, struct scene *sc,
		       const int *scissor)
{
	glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
	// GL window y runs with the buffer's rows here (row 0 is the top), so an
	// image-space rectangle is a scissor rectangle as it stands.
	if (scissor) {
		glEnable(GL_SCISSOR_TEST);
		glScissor(scissor[0], scissor[1], scissor[2], scissor[3]);
	} else {
		glDisable(GL_SCISSOR_TEST);
	}
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	spike_begin(t);
	struct spike_shape full = {0, 0, t->width, t->height, {0, 0, 0, 0}};
	const float bands[4][4] = {{.9f, .2f, .1f, 1}, {.1f, .8f, .2f, 1}, {.1f, .2f, .9f, 1}, {.9f, .9f, .1f, 1}};
	for (int i = 0; i < 4; i++)
		spike_solid(spike, t, &full, 0, NULL, bands[i], i * t->width / 4, 0, t->width / 4, t->height);
	// A small white square that moves between frames.
	struct spike_shape square = {sc->square_x, sc->shape.y - 30, 24, 24, {0, 0, 0, 0}};
	spike_solid(spike, t, &square, 0, NULL, (float[4]){1, 1, 1, 1}, 0, 0, 24, 24);
	spike_backdrop_draw(spike, t, &sc->backdrop, &sc->shape, &sc->params);
	glDisable(GL_SCISSOR_TEST);
}
static void gate_damage(struct spike *spike, struct spike_target *t, struct spike_target *t2,
			struct image *img, struct image *ref)
{
	struct scene sc = {.shape = {120, 120, 300, 100, {10, 10, 10, 10}},
			   .params = {.sigma = 10, .saturation = 1, .tint = {0, 0, 0, 0}, .alpha = 1, .padding = 40,
				      .border = 1, .border_color = {1, 1, 1, 1}}};
	spike_backdrop_init(&sc.backdrop, sc.shape.w + 80, sc.shape.h + 80);
	// Frame 1: the square sits above the window's left part; frame 2 moves it
	// within the blur's reach (3 sigma = 30 px) but outside the shape itself.
	sc.square_x = 150;
	draw_scene(spike, t, &sc, NULL);
	int old_x = sc.square_x;
	sc.square_x = 260;
	int square_y = sc.shape.y - 30;
	// Damage: both positions of the square.
	int dx0 = old_x, dx1 = sc.square_x + 24;
	int damage[4] = {dx0, square_y, dx1 - dx0, 24};
	// Reference: frame 2 rendered from scratch.
	draw_scene(spike, t2, &sc, NULL);
	read_image(t2, ref);
	// Without expanding the damage to the effect, the blur under it is stale.
	draw_scene(spike, t, &sc, damage);
	read_image(t, img);
	int stale = 0;
	for (int i = 0; i < img->w * img->h * 4; i++)
		if (diff(img->p[i], ref->p[i]) > 2)
			stale++;
	check(stale > 0, "gate 8: the unexpanded damage should leave a stale blur (control)");
	// Expand: damage within the effect's sample extent (shape + padding) pulls in the shape.
	int ex0 = sc.shape.x - sc.params.padding, ey0 = sc.shape.y - sc.params.padding;
	int ex1 = sc.shape.x + sc.shape.w + sc.params.padding, ey1 = sc.shape.y + sc.shape.h + sc.params.padding;
	bool touches = damage[0] < ex1 && damage[0] + damage[2] > ex0 && damage[1] < ey1 && damage[1] + damage[3] > ey0;
	check(touches, "gate 8: the test damage must reach the effect's sample extent");
	int x0 = damage[0] < sc.shape.x ? damage[0] : sc.shape.x, y0 = damage[1] < sc.shape.y ? damage[1] : sc.shape.y;
	int x1 = damage[0] + damage[2] > sc.shape.x + sc.shape.w ? damage[0] + damage[2] : sc.shape.x + sc.shape.w;
	int y1 = damage[1] + damage[3] > sc.shape.y + sc.shape.h ? damage[1] + damage[3] : sc.shape.y + sc.shape.h;
	int expanded[4] = {x0, y0, x1 - x0, y1 - y0};
	// Reset to the frame 1 content, then repaint with the expanded damage.
	sc.square_x = old_x;
	draw_scene(spike, t, &sc, NULL);
	sc.square_x = 260;
	draw_scene(spike, t, &sc, expanded);
	read_image(t, img);
	int bad = 0;
	for (int i = 0; i < img->w * img->h * 4; i++)
		if (diff(img->p[i], ref->p[i]) > 2)
			bad++;
	check(bad == 0, "gate 8: %d values differ after painting only the expanded damage", bad);
	spike_backdrop_destroy(&sc.backdrop);
	printf("PASS gate 8: partial repaint with damage expanded under the effect equals a full repaint "
	       "(the unexpanded one leaves %d stale values)\n", stale);
}

// ---- Gate 10: the same buffer, drawn by wlroots' own pass and by the spike ------------
static void gate_matches_wlroots(struct spike *spike, struct spike_gl_state *state,
				 struct spike_target *t, struct image *img, struct image *ref)
{
	// A premultiplied half-transparent rectangle off the origin: any flip of the
	// image, wrong blend or colour-space difference between the two shows up.
	const float tint[4] = {.2f, .1f, .05f, .5f};
	// wlroots draws with client-side vertex arrays, which read from the bound
	// GL_ARRAY_BUFFER if there is one: handing it a context with the spike's
	// quad buffer still bound draws half a rectangle. leave() restores what
	// was bound before the spike, as glass.c's does.
	spike_leave(state);
	struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(spike->renderer, t->buffer, NULL);
	check(pass != NULL, "gate 10: cannot begin a wlroots pass");
	wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
					   .box = {0, 0, t->width, t->height},
					   .color = {BG[0], BG[1], BG[2], 1},
					   .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
	wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
					   .box = {40, 30, 100, 60},
					   .color = {tint[0], tint[1], tint[2], tint[3]}});
	check(wlr_render_pass_submit(pass), "gate 10: the wlroots pass failed");
	check(spike_enter(spike, state), "gate 10: cannot re-enter the context after a wlroots pass");
	read_image(t, ref);
	struct spike_shape s = {40, 30, 100, 60, {0, 0, 0, 0}};
	spike_clear(t, BG);
	spike_begin(t);
	spike_solid(spike, t, &s, 0, NULL, tint, 0, 0, 100, 60);
	read_image(t, img);
	int worst = 0;
	for (int i = 0; i < img->w * img->h * 4; i++)
		worst = diff(img->p[i], ref->p[i]) > worst ? diff(img->p[i], ref->p[i]) : worst;
	check(worst <= 1, "gate 10: the spike and wlroots' pass differ by %d levels", worst);
	check(at(ref, 41, 31)[0] != at(ref, 41, 100)[0] || at(ref, 41, 31)[1] != at(ref, 41, 100)[1],
	      "gate 10: the control rectangle was not drawn where expected");
	printf("PASS gate 10: same orientation, blend and colour as wlroots' own render pass (max diff %d)\n", worst);
}

// ---- Gate 9: cost ---------------------------------------------------------------------
static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}
static void gate_cost(struct spike *spike)
{
	// Window B's titlebar effect at scale 1.5, as in the stage 0 baseline:
	// 522x46 logical -> 783x69 device, sigma 22 logical (33 device), 3 sigma padding.
	struct spike_target t;
	check(spike_target_create(spike, &t, 1920, 1080), "gate 9: cannot allocate 1920x1080");
	struct spike_shape effect = {300, 200, 783, 69, {15, 15, 0, 0}};
	struct spike_blur_params params = {.sigma = 33, .saturation = 1.5f, .tint = {.06f, .07f, .08f, .5f},
					   .alpha = 1, .padding = 99};
	struct spike_backdrop b;
	spike_backdrop_init(&b, effect.w + 2 * params.padding, effect.h + 2 * params.padding);
	struct spike_shape window = {300, 200, 783, 534, {15, 15, 15, 15}};
	const float colors[3][4] = {{.06f, .07f, .08f, .8f}, {.06f, .07f, .08f, .8f}, {.06f, .07f, .08f, .8f}};
	const int iterations = 300;
	double effect_cpu = 0, effect_wall = 0, window_cpu = 0, window_wall = 0;
	for (int round = 0; round < 2; round++) {
		spike_clear(&t, BG);
		glFinish();
		double start = now_ms(), cpu = 0;
		for (int i = 0; i < iterations; i++) {
			double c0 = now_ms();
			spike_backdrop_draw(spike, &t, &b, &effect, &params);
			cpu += now_ms() - c0;
		}
		glFinish();
		if (round) {
			effect_cpu = cpu / iterations;
			effect_wall = (now_ms() - start) / iterations;
		}
		start = now_ms();
		cpu = 0;
		for (int i = 0; i < iterations; i++) {
			double c0 = now_ms();
			spike_begin(&t);
			spike_shadow(spike, &t, &window, 0, 6, 12, (float[4]){0, 0, 0, .4f}, true);
			const float ring[4] = {.3f, .3f, .3f, 1};
			spike_solid(spike, &t, &window, 1, ring, colors[0], 0, 0, window.w, 69);
			spike_solid(spike, &t, &window, 1, ring, colors[1], 0, 69, window.w, window.h - 69 - 15);
			spike_solid(spike, &t, &window, 1, ring, colors[2], 0, window.h - 15, window.w, 15);
			cpu += now_ms() - c0;
		}
		glFinish();
		if (round) {
			window_cpu = cpu / iterations;
			window_wall = (now_ms() - start) / iterations;
		}
	}
	printf("COST one backdrop effect (783x69 at scale 1.5): CPU submit %.3f ms, with GPU %.3f ms per frame\n",
	       effect_cpu, effect_wall);
	printf("COST one window (shadow, 3 pieces, border): CPU submit %.3f ms, with GPU %.3f ms per frame\n",
	       window_cpu, window_wall);
	// Stage 0 baseline, one re-blurred effect (spinner under glass vs clear, scale 1.5):
	// +0.17 ms CPU and +0.2 ms GPU per frame.
	check(effect_cpu <= 0.17 * 1.5, "gate 9: effect CPU %.3f ms exceeds the baseline's 0.17 ms by more than 50%%", effect_cpu);
	check(effect_wall <= (0.17 + 0.2) * 1.5, "gate 9: effect wall %.3f ms exceeds the baseline's 0.37 ms by more than 50%%", effect_wall);
	puts("PASS gate 9: a backdrop effect costs no more than glass.c's re-blur in the stage 0 baseline");
	spike_backdrop_destroy(&b);
	wlr_buffer_drop(t.buffer);
}

int main(void)
{
	wlr_log_init(WLR_ERROR, NULL);
	struct wl_display *display = wl_display_create();
	struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(display));
	assert(backend);
	struct wlr_renderer *renderer = wlr_renderer_autocreate(backend);
	assert(renderer && wlr_renderer_is_gles2(renderer));
	struct wlr_allocator *allocator = wlr_allocator_autocreate(backend, renderer);
	assert(allocator);
	struct spike *spike = spike_create(renderer, allocator);
	check(spike != NULL, "the spike's programs failed to build");
	struct spike_gl_state state;
	check(spike_enter(spike, &state), "cannot enter the renderer's context");

	struct spike_target t, t2;
	check(spike_target_create(spike, &t, 640, 480) && spike_target_create(spike, &t2, 640, 480),
	      "cannot allocate the 640x480 targets");
	struct image img = {0}, ref = {0};
	gate_clip_accuracy(spike, &t, &img);
	gate_no_seams(spike, &t, &img);
	gate_border_partition(spike, &t, &img, &ref);
	gate_premultiplied(spike, &t, &img);
	gate_external(spike, &t, &img, &ref);
	gate_shadow(spike, &t, &img);
	gate_backdrop(spike, &t, &img);
	gate_backdrop_edge(spike, &t, &img);
	gate_damage(spike, &t, &t2, &img, &ref);
	gate_matches_wlroots(spike, &state, &t, &img, &ref);
	gate_cost(spike);

	spike_leave(&state);
	free(img.p);
	free(ref.p);
	wlr_buffer_drop(t.buffer);
	wlr_buffer_drop(t2.buffer);
	wlr_allocator_destroy(allocator);
	wlr_renderer_destroy(renderer);
	wlr_backend_destroy(backend);
	wl_display_destroy(display);
	puts("pass spike gates passed");
	return 0;
}
