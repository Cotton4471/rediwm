# Plan: compositor-owned scene graph and render pass

Status: decided, not started. Updated 2026-10-08. Replaces the September 2026
proposal.

Decision (2026-10-08): clipped, rounded client corners are a hard requirement,
and the way to get them is an owned render pass. Doing it properly matters more
than doing it quickly. CPU and RAM are constraints this work must not break,
not its motivation (see [Resource expectations](#resource-expectations)).

## Why `wlr_scene` cannot do it

RediWM draws through `wlr_scene` plus two layers built to work around it:

* **Client corners are square.** `wlr_scene` and the wlroots 0.20 render pass
  cannot mask a texture. The frame reserves a footer band under the client
  (`chrome.footerHeight`, at least `ceil(radius)` tall) and draws the bottom
  arcs there. `Toplevel.probeClientEdge` reads back the client's last buffer
  row (GL readback, explicit-sync waits) to colour that band. Borders have two
  paths (`ChromeBuffer` arcs, `Toplevel.syncBorders` straight rects with
  `side_fills`). Shadows are CPU-rasterized corner/edge buffers.
* **Integer coordinates.** `src/projection.c` mirrors every source node into
  a second tree to apply camera zoom, Xwayland `1/N` scale and fractional
  positioning, with a per-leaf `view_state` cache to keep the sync affordable.
* **Backdrop effects are a side channel.** `src/glass.c` re-walks the scene
  (`capture_prefix`) into a private capture buffer per effect, enters its own
  GL context state per effect and flushes per effect (about 0.35 ms per
  re-blurred effect, 2026-09 measurement). It is GLES2-only
  (`wlr_renderer_is_gles2`; otherwise a CSS-style tint).

Scene API reach: about 45 distinct `wlr_scene_*` functions, ~260 references,
scene types in 49 source files. The frame path is `Output.handleFrame` →
`scene_output.buildState` → `Output.commitFrameState`; screenshots
(`screenshot/capture.zig`) and IPC capture call `buildState` too.

## Target design

**Retained from wlroots:** backends, `wlr_output`/`wlr_output_state` and
`Output.commitFrameState`, swapchain and allocator, `wlr_damage_ring`, the
GLES2 renderer's context, texture import and buffer FBOs, seat/input, Xwayland,
and every protocol implementation (`wlr_surface`, subsurface, xdg-shell,
layer-shell, viewporter, presentation, linux-dmabuf, drm-syncobj, screencopy).
Client surface semantics stay behind an adapter; they are not reimplemented.

**Owned:**

* *Node graph.* Typed nodes (tree, rect, texture/surface, shadow, backdrop
  effect) with float logical coordinates, translate + uniform scale, opacity,
  and a clip shape. One source of geometry truth; zoom, `1/N` Xwayland scale
  and fractional placement are node properties, not a second tree.
* *Clip groups.* A rounded-rect clip (per-corner radii) applies to a whole
  subtree: titlebar chrome, client surface and its subsurfaces, footer. It is
  evaluated in the fragment shader as a signed-distance coverage in device
  pixels, so AA is right at any scale or zoom. One shape function replaces the
  skirt, `probeClientEdge`, `side_fills`, the straight-rect border path and the
  chrome arcs. xdg popups are separate trees and are never clipped by a
  parent's shape.
* *Analytic primitives.* Borders and shadows become shader primitives. CPU
  raster is left for what is really content: title text, icons, buttons.
* *Output pass.* Per output: acquire swapchain buffer (age), accumulate
  damage, walk in paint order with opaque-region culling, draw with an owned
  GLES2 program driven directly on the wlroots context and buffer FBO, as
  `glass.c` already does (`wlr_gles2_renderer_get_buffer_fbo`,
  `wlr_gles2_texture_get_attribs`). The wlroots render pass has no custom
  shader or stencil, so it cannot be used for masked draws.
* *Backdrop effects in the pass.* An effect samples the framebuffer drawn so
  far (a region copy), blurs, and composes through its clip shape. No prefix
  re-render, no separate pass, no per-effect context switch. Culling must keep
  what a blur reads, and damage under an effect expands to the effect's padded
  extent (a swapchain buffer's pixels outside the damage are stale).
* *Distribution of surface feedback.* Frame callbacks, `wl_surface.enter/leave`,
  preferred scale, presentation feedback, dmabuf feedback tranches,
  explicit-sync acquire/release, primary output.
* *Direct scanout* for an opaque fullscreen client with no clip, transform or
  effect above it (test with `wlr_output_test_state`).
* *Hit testing and capture of node subsets.* Float hit tests honour the clip
  shape, so clicks on a transparent rounded corner reach the window below.
  Capture renders a node subset, replacing the owned adapter around
  wlroots' leaky scene capture helper.

**Policy defaults (assumed, change in stage 0 if wrong):** radius is
`border_radius` scaled by chrome density, 0 when maximized or fullscreen
(the current `Toplevel.cornerRadius`). It applies to server-decorated native
and Xwayland windows and to `.shell` windows (Settings). Client-side-decorated
windows are not clipped by the compositor unless a rule asks. The footer
reservation drops from `max(border, ceil(radius))` to the border width, so the
radius-tall band returns to the client; every `footerHeight` consumer (snap,
resize edges, layout, saved layouts, Xwayland, tabs, tests that pin titlebar
or body heights) needs an audit.

## Stages

Every stage leaves a working compositor. The graph is the only geometry truth;
a presenter consumes it and holds no geometry of its own. Switching between
presenters during the migration uses a temporary config key (not an
environment variable: no test hooks in production), removed in stage 6.

0. **Baseline and inventory (no behaviour change).** *Done 2026-10-09 except
   the decisions: harness `tests/scene_baseline.py`, numbers, findings, both
   inventories and the decisions to confirm are in
   [scene-graph-baseline.md](scene-graph-baseline.md).*
   * Fixed workload and harness: three windows with glass, a 60 fps damage
     client, drag and resize, a fullscreen client, zoom steps and
     scales 1, 1.5 and mixed. Record `cpu_frame`, `projection_cpu`,
     `glass_cpu`, `scene_commit_cpu`, `gpu_elapsed`, wakeups, RSS and
     instructions:u; keep golden IPC screenshots of chrome, corners and glass.
   * Inventory exactly what `wlr_scene_output` does today for the projected
     tree (frame-done, enter/leave, presentation, dmabuf feedback, scanout,
     release points, primary output, damage/culling). That table is the
     checklist for stage 3.
   * Inventory what wlroots' GLES2 texture shader does that an owned shader
     must reproduce or consciously drop: external-OES targets, transfer
     function and primaries, range/encoding, premultiplied blending, filters.
   * Confirm the policy defaults above and the renderer decision below.
1. **Pass spike (noninstalled fixture, `test-glass`-style pixel tests).**
   Draw a 2D and an external-OES client texture through the rounded clip at
   fractional scale and zoom; analytic border and shadow; blur from a
   framebuffer copy. Gate: no seams or fringe (extend `window_corners.py`
   criteria), correct premultiplied edges, measured cost within the stage 0
   baseline, buffer-age damage correct under an effect. Failing the gate is a
   result: revise the design before stage 2.
2. **Typed node model behind the existing presenter.** `projection.c`'s
   view sync consumes the typed graph (float coordinates, clip, opacity) and
   rounds for `wlr_scene`. No visible change; existing tests pass unchanged.
3. **Owned output pass at parity (radius 0).** Everything in the stage 0
   inventory, plus capture, screenshots, lock coverage and hotplug through the
   new path. Exit: pixel-equivalent to the legacy presenter within tolerance
   and cost at or below baseline, including scanout where it applied.
4. **Clipping and primitives.** Clip groups on frames, analytic borders and
   shadows, shape-aware hit testing; delete the skirt, `probeClientEdge`,
   `side_fills`, the dual border path and `edge_sampling.py`; shrink the footer.
5. **Backdrop effects in the pass.** Delete `glass.c`'s prefix capture,
   per-effect contexts, dependency hashing and the drag hold; keep glass pixel
   tests, converted.
6. **Delete.** `wlr_scene` output rendering, the projection view tree, the
   legacy presenter and the temporary config key. Update `AGENTS.md`
   (rendering and damage rules, the two-border-path and skirt notes),
   `TESTING.md` and the area notes.

The old wlr_scene source tree stays as the surface adapter until a separate,
later decision; replacing it is not part of this plan.

## Resource expectations

Hypotheses to confirm in stages 0, 1 and 3; the stage 0 baseline defines the
numbers.

| Area | Expectation |
|---|---|
| Idle CPU, wakeups | Unchanged. The pass adds no timers or polling. |
| Per-frame, no glass overlap | About unchanged; the floor is wlroots/Mesa driver cost (parity with labwc at 60 fps damage in 2026-09). |
| Glass over damage | Lower: no prefix re-render, context switch or flush per effect. The new cost is one backdrop region copy per effect. |
| Client edge probe | Gone, with its GL readback and acquire-wait stalls. |
| Chrome CPU on resize/move | Lower if arcs, borders and shadows stop being CPU rasters; title text still is. |
| GPU | A mask multiply per client pixel is negligible; the backdrop copy is the real cost. Check `gpu_elapsed`. |
| Scanout | Preserved for opaque fullscreen clients. |
| RAM | Not above baseline: per-effect capture/output/intermediate buffers shrink, shadow/skirt buffers go; shader programs and damage rings are tiny. |

## Acceptance requirements

Preserve surface commit ordering, explicit-sync fences, frame callbacks,
presentation feedback, damage, hit-testing, colour transforms and colour
descriptions, capture isolation, output hotplug and lock coverage. Include
popups, IME candidates, subsurfaces, mixed and fractional scale, camera zoom
steps down to `camera_zoom_min`, Xwayland at `N > 1`, tiles and maximize,
close snapshots and the Settings shell window.

Corner-specific: client pixels in the clipped corner are transparent (the
backdrop shows through) with no bright fringe and no seam at any zoom step or
scale; the same shape clips chrome and client; hit tests follow the shape.

Run through existing suites, extended rather than duplicated: `window_corners`,
`appearance_chrome`, `decorations`, `kde_decorations`, `capture`,
`screencast`, `screenshot_regressions`, `explicit_sync`, `presentation_time`,
`output_scale`, `output_destroy`, `lock_screen`, `layer_lifecycle`,
`popup_constraint`, `focus_zoom`, `desktop_zoom`, `mini_map*`, `window_snapping`,
`desktop_damage`, `panel_damage`, `single_pixel`, `wlr_protocols`, the perf
scripts and `zig build test-glass` / `zig build test`. Compare CPU/GPU frame
cost and scanout/plane use against the legacy renderer; do not assume glass
makes scanout irrelevant. The render invariants are in
[AGENTS.md](../../AGENTS.md) and the commands in [TESTING.md](../../TESTING.md).

## Risks and open decisions

* **Renderer policy (decided 2026-10-09).** The session requires GLES2, as
  glass already does; no pixman path is kept. Tests that default to pixman move
  to a render node (as `test-glass` already does); a machine without a GPU needs
  Mesa llvmpipe through `WLR_RENDERER_ALLOW_SOFTWARE`. Client-side-decorated
  windows are not clipped unless a rule asks (decided the same day).
* **Reimplementing `wlr_scene_output` behaviour** is the main regression risk
  (frame callbacks, presentation timestamps, dmabuf feedback, enter/leave,
  release points). The stage 0 table and per-item tests are the mitigation.
* **Colour management and external textures** must be matched in the owned
  shader or consciously dropped; decide in stage 0.
* **Blur with buffer age.** Damage expansion under effects must be exact, or
  stale pixels appear in the blur.
* **Binding gaps.** zig-wlroots lacks some needed APIs (damage ring,
  swapchain, GLES2 attribs); hand-declare them and keep the wlroots 0.20 ABI
  pin in `build.zig.zon`.
* **Xwayland coupling.** `scene.restack_xwayland_surfaces = false` and
  `Toplevel.raise` sync scene and X11 stacking; the graph must keep that
  ordering contract.
* **Footer change** alters client geometry; saved layouts and tests that pin
  titlebar/body sizes (the known 41 vs 35 titlebar assertion) need review.
* **No second truth.** A temporary presenter or adapter must not grow its own
  geometry; if it does, stop and fold it into the graph.

Independent of this plan and cheap: batch glass effects into one EGL
enter/leave and drop the per-effect `glFlush` in `glass.c`.
