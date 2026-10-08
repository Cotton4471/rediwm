# Scene graph plan, stage 1: pass spike

Status: stage 1 of [scene-graph.md](scene-graph.md), run 2026-10-09 on the
machine and conditions of the [stage 0 baseline](scene-graph-baseline.md).
Result: **every gate passes, after two design changes the gates forced.** Stage
2 can start on this design; the open integration risks are listed at the end.

## What was built

A noninstalled fixture, not linked into the compositor:

* `src/pass_spike.c`: the primitives an owned output pass needs, drawn on
  wlroots' own GLES2 context and a wlroots-allocated buffer's FBO, entering and
  leaving that context the way `glass.c` does. One fragment shader family (2D
  and external-OES samplers) evaluates a rounded-rectangle signed distance field
  in device pixels for the body (texture or solid), the border, an analytic
  shadow and a blurred-backdrop composite; the backdrop is a framebuffer copy,
  two blur passes at quarter size and a clipped composite.
* `src/pass_spike_test.c`: ten pixel gates and a cost measurement.
* `zig build test-pass-spike` (needs a render node; `WLR_RENDER_DRM_DEVICE` on a
  multi-GPU machine; add `-Doptimize=ReleaseSafe` for cost figures).

Conventions the spike fixes: device pixels, y down, buffer row 0 is the top row
(`ndc_y = py / height * 2 - 1`, so a GL scissor rectangle is an image
rectangle), colours premultiplied, `glBlendFunc(ONE, ONE_MINUS_SRC_ALPHA)`. A
window is an integer device rectangle with one radius per corner; titlebar,
client and footer are quads that tile it (edges snapped as
`round(off*s)`..`round((off+len)*s)`), all covered by the same distance field.

## Gates

| # | Gate | Result |
|---|---|---|
| 1 | Rounded clip against an 8×8 supersampled area-coverage reference at scales 1, 1.5, 2 and zoom 1, .85, .70, .55, .25; no channel outside the range of body and background (no fringe). | Pass: max error 12 levels (5.8 % of the 208-level range, the usual cost of distance-based AA on arcs), zero fringe values. |
| 2 | Titlebar, client and footer pieces: every interior pixel is exactly its piece's colour, at every scale and zoom (no seam, no background leak). | Pass. |
| 3 | Border and body in the same colour must equal one plain shape; with distinct colours the outer row is the border and the next row the body. | Pass (max diff 0) **after a design change, below.** |
| 4 | Premultiplied edges: a 50 % premultiplied texel over the backdrop, opacity 0.5, and an XRGB texel with a junk alpha byte. | Pass (±2). |
| 5 | An external-OES texture (an EGLImage of a dmabuf, bound to `GL_TEXTURE_EXTERNAL_OES`) through the clip equals the same pixels in a 2D texture, across the scale and zoom grid. | Pass (max diff 0). |
| 6 | Analytic shadow: monotonic falloff, zero outside its footprint and inside the window, equal to the Gaussian edge profile on a straight edge. | Pass (max diff 0 against `erfc`). Corners are approximate; not compared to the current CPU shadow yet. |
| 7 | Backdrop from a framebuffer copy: red/blue step under the window blurs to an even mix at the step, monotonic, far sides unchanged, nothing leaks past the clip; at the buffer edge the blur replicates the edge, no black. | Pass. |
| 8 | Buffer-age damage under an effect: repaint only the damaged rectangle into the previous frame's buffer. | Pass: expanding damage to the effect's shape when it reaches its sample extent equals a full repaint; without the expansion 3146 values stay stale (the control). |
| 9 | Cost against the stage 0 baseline. | Pass, below. |
| 10 | The spike and wlroots' own render pass draw the same premultiplied rectangle into the same buffer identically (orientation, blend, colour). | Pass (max diff 0), **after a test fix that is itself an integration rule, below.** |

### Cost (783×69 titlebar effect at scale 1.5, ReleaseSafe, AC, 5 runs)

| | Stage 0 baseline (one re-blurred `glass.c` effect) | Spike |
|---|---|---|
| CPU per frame | +0.17 ms | 0.006-0.019 ms submit |
| GPU per frame | +0.2 ms | 0.208-0.224 ms wall including the GPU |
| One full window (shadow, three pieces, border) | n/a | 0.003-0.007 ms submit, 0.079-0.089 ms wall |

The CPU cost nearly disappears (no scene prefix walk, no private render pass,
no per-effect context switch or `glFlush`); the GPU cost is the same, since the
copy and the blur remain. The wall figures are one `glFinish` per 300 frames, so
they are throughput, not latency.

## Design changes the gates forced

1. **The border belongs in the piece's fragment shader, not in a second draw.**
   A ring drawn "over" a body leaves `dst × a_body × a_ring` of the backdrop
   showing through wherever both are partly covered: a bright seam of 53 levels
   along the inner edge of every border (gate 3 failed on this). Both are
   evaluated at the same fragment (`inner = cov(d + b)`, `ring = cov(d) -
   cov(d + b)`), so their coverages add to the shape's. The same rule applies to
   the backdrop composite. The plan's separate "border primitive" becomes a
   parameter of every piece.
2. **A scissor and damage rule for effects.** A partial repaint of a buffer with
   age must also repaint every effect whose sample extent (shape plus padding)
   the damage touches, even though the effect's own rectangle is undamaged; the
   copy then reads current pixels in the damage and valid stale ones elsewhere.
   The effect's composite runs under the caller's scissor while its copy and
   blur passes run unscissored (gate 8).

Smaller points the spike settled: piece joins on integer device pixels need no
special seam handling (a quad covers each pixel once; only the shape edge is
anti-aliased); a shadow is clipped out of the window only when the body is
translucent (otherwise it would be attenuated twice at the edge); the backdrop
copy is clamped to the framebuffer with the blur's sampling limits set, which
replicates the edge instead of bleeding black.

## Integration rules found

* **wlroots draws with client-side vertex arrays**, which read from the bound
  `GL_ARRAY_BUFFER` if there is one. Calling wlroots' pass with the spike's quad
  buffer still bound drew half a rectangle (gate 10 failed on this, 103 levels).
  Any owned GL work has to restore the array-buffer binding (and, as `glass.c`'s
  `leave()` does, the rest of the state it touches) before wlroots draws, and
  re-enter afterwards. Once the output pass is owned, this is only a concern for
  the remaining wlroots entry points (screenshots, texture uploads).
* The owned pass can write the swapchain buffer through
  `wlr_gles2_renderer_get_buffer_fbo` and agrees with wlroots' pass on
  orientation, blend and colour (gate 10), so scanout and capture see the same
  image.

## Not yet proven (for stage 2 and 3)

* Real client textures: shm uploads through `wlr_client_buffer`, the texture
  target wlroots reports (`wlr_gles2_texture_get_attribs`), and YUV dmabufs that
  need external sampling with driver conversion. The spike imports one RGBA
  dmabuf itself.
* The swapchain's real buffer age and `wlr_damage_ring` (the spike keeps one
  persistent buffer), explicit-sync acquire and release points, software
  cursors, and subsurface and popup ordering.
* Direct scanout: finding 6 of the baseline made it work in the old presenter;
  the owned pass must keep one entry per scanout-eligible client or it
  regresses that.
* Quality of the quarter-size blur against `glass.c` side by side, the analytic
  shadow's corners against the CPU shadow, and the colour of window opacity
  under zoom.
* Multi-output with different scales (the pass renders per output; effects are
  per output and need no shared scale, which also removes the idle loop the
  stage 0 glass fix addressed).

## Verdict

The primitives work on wlroots' own GLES2 context and buffers, produce no seams
or fringe at any tested scale or zoom, draw an external-OES texture identically
to a 2D one, handle damage under an effect, and cost no more than the current
glass path (far less CPU, the same GPU). Proceed to stage 2, carrying the two
design changes above.
