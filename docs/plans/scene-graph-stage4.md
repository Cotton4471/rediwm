# Scene graph plan, stage 4: clipping and primitives

Status: **4a to 4c done, 4d and 4e not started**, 2026-10-10. Stage 3 of
[scene-graph.md](scene-graph.md) (the owned output pass, radius zero) is done
apart from hardware qualification; this stage is why the plan exists: the user
requires clipped client corners, and wlroots 0.20 cannot mask a client. The five
decisions at the end were taken the same day, all as recommended.

## Goal and exit

One rounded-rectangle shape, with a radius per corner, clips a whole window: the
titlebar chrome, the client surface with its subsurfaces, and whatever sits
between. It is evaluated in the fragment shader as a signed-distance coverage in
device pixels, so anti-aliasing is right at any scale and zoom. Borders and
shadows become shader parameters of the same shape.

Exit, from the master plan's corner requirements:

* Client pixels in a clipped corner are transparent (the backdrop shows) with no
  bright fringe and no seam, at scales 1, 1.25, 1.5 and 2 and at every camera
  zoom step down to `camera_zoom_min`.
* The same shape clips chrome and client, and hit tests follow it: a click on a
  transparent rounded corner reaches what is below.
* The skirt, `probeClientEdge`, `side_fills`, the dual border path, the CPU corner
  arcs and `edge_sampling.py` are gone, and the footer is the border width.
* Cost is at or below the stage 0 baseline and the stage 3 figures; resize and
  move frames are cheaper (no footer raster, no arcs), commits no longer pay the
  edge probe's GL readback and acquire-wait stalls.

## What exists today

Verified in the code on 2026-10-09 (`Toplevel.zig`, `chrome.zig`, `scene_data.zig`).

* **A window is a stack of scene nodes in `frame_tree`:** a shadow tree (four
  corner buffers, four edge buffers and a fallback), the titlebar `ChromeBuffer`,
  the client surface tree, a footer `ChromeBuffer` (the skirt), two `side_fills`
  rects, four `border_rects` and the resize-grab node. Frame size is the client
  geometry plus `2 * frame_border` wide and `titlebarHeight + footerHeight` tall.
* **The corners are CPU raster.** `ChromeBuffer` draws the rounded frame (the CPU
  twin of the SDF) for each band; both bands are cut from one rounded rectangle.
  The client has square corners, so the frame reserves a footer of
  `max(frame_border, ceil(radius))` below it (10 px at the default
  `border_radius = 10` and density 1) to hold the bottom arcs. `cornerRadius()` is 0 when
  maximized or fullscreen, otherwise `frameRadius() * chromeDensity()`.
* **The skirt colour is read from the client.** `probeClientEdge` maps the
  surface to its last buffer row, `applyEdgeSample` reads it back with
  `glReadPixels` (after an explicit-sync acquire wait, `edgeAcquireReady`) and
  `chrome.sampleEdge` takes the median, with a format memo, damage
  classification and a retry state machine (`EdgeMapping`, `decideEdgeSample`,
  about 170 lines in `chrome.zig` and about 200 in `Toplevel.zig`).
* **Borders have two paths:** curved corners inside the `ChromeBuffer`, straight
  edges as four `SceneRect`s inset by `ceil(radius)`, backed by `side_fills`.
  A client-side-decorated window draws a plain four-rect outline outside its
  content instead.
* **Shadows are CPU patches.** `ShadowBuffer`, `ShadowPatchBuffer` and
  `ShadowPatchSet` (about 440 lines of `chrome.zig`) cache corner and edge
  rasters by state and share them between windows.
* **Hit testing** is `scene_data.hitTest`: `root.at` on the displayed (projected)
  tree, mapped back with `projection.source`. Chrome buffers carry
  `point_accepts_input` hooks (`chromeAcceptsInput`, `footerAcceptsInput`) that
  evaluate the frame SDF (`insideFrame`). The client surface itself has square
  corners and no shape test, which is correct only because the footer and
  titlebar cover its corners.
* **`footerHeight` has about 20 compositor-side call sites:** `auto_tiling.zig` (2),
  `Input.zig` (3), `ipc/handlers.zig` (1), `chrome.zig` (the band height) and
  about 14 in `Toplevel.zig` (size clip, layout, snap, maximize and fullscreen
  geometry, input regions, resize edges). Restore and tiling code keep the
  client size and add the chrome back (`saved.height + titlebarHeight +
  footerHeight`), so a footer change moves the frame, not that saved size;
  whether the layout autosave file stores client or frame size is part of the
  4c audit. (`files/app.zig` has its own, unrelated `footerHeight`.)
* **Glass is already rounded** (`glass.Effect.configure(effect, cornerRadius, ..)`),
  but its blur is stage 5.
* **Tests pinned to this design:** `window_corners.py` (283 lines),
  `edge_sampling.py` (229, tests the probe itself), `appearance_chrome.py`,
  `decorations.py`, `kde_decorations.py`, `window_snapping.py` and `xwayland.py`
  (mentions the skirt; also the known 41 vs 35 titlebar assertion).

## Why stage 4 cannot run beside the legacy presenter unchanged

`wlr_scene` draws a client as an unmasked rectangle. As soon as the client extends
into the corner band, only the owned pass can show it clipped. Deleting the
footer, skirt and arcs therefore breaks the legacy presenter's corners, and the
frame height (hence every `footerHeight` consumer) would differ between
presenters. Two ways to live with that, chosen in D1.

## Design

### Clip shape in the graph

`scene_graph.h` gets a clip: the frame's unrounded layout-space edges, four radii
(composed scale applied), and a border width. It is a property of a group
(`Toplevel.frame_tree`), set through a new projection call beside
`rediwm_projection_set_tree_scale`, and resolve copies it onto every leaf of the
group, so chrome, client and subsurfaces share one shape. Popups are separate
trees in the sense that they belong to no window's shape, but the source graph
makes them children of their parent surface's tree (`Popup.create` uses
`parent_tree.createSceneXdgSurface`), under `content_tree` and `frame_tree`. A
tree clip would clip menus and tooltips that hang outside the window, so a popup's
tree carries a barrier (`rediwm_projection_set_tree_unclipped`, set by
`Popup.create` in 4c) that ends the inherited clip. Radius 0 means no clip: maximized
and fullscreen windows, and client-side-decorated windows (decided in stage 0:
unclipped unless a rule asks). `.shell` windows (Settings) are clipped like
native ones.

The edges are snapped once, with the same `rediwm_edges_snap` as the pieces, so
the shape and the quads that tile it agree on pixel columns (the stage 1
convention: a window is an integer device rectangle). Xwayland needs nothing
special: the clip lives in layout space, the `1/N` tree scale only changes how
the texture maps.

### Pass

`scene_pass.c` gains clip variants of its three programs (solid, 2D, external).
A draw sets the frame rectangle in device pixels, the radii and the border width
as uniforms; the fragment shader computes `d = sdf(p - frame_centre, size, radii)`
and multiplies by `coverage(d)`. This is the stage 1 shader
(`pass_spike.c`: per-corner SDF, `cov`, border ring, `erf` shadow), moved over,
not rewritten. Rules the spike proved and the production code must keep:

* **The border is part of each piece's fragment,** never a second draw over it
  (`inner = cov(d + b)`, `ring = cov(d) - cov(d + b)`); two partial coverages
  drawn over each other leave a 53-level seam.
* Premultiplied throughout; the external-OES path equals the 2D path.
* A shadow is cut out of the window only when the body is translucent.

Culling and damage stay correct by two rules. An item's opaque region becomes its
rectangle minus the four corner squares (a cross of two rectangles), never the
full rectangle, or occluded content would be culled through a transparent corner.
Damage that reaches a clip edge is expanded by one device pixel for anti-aliasing,
as fractional scale already is. Direct scanout needs radius 0, which fullscreen
already has.

### Hit tests

The smallest correct change: keep `root.at`, and after it names a window's node,
test the point against that window's shape; if it falls outside, repeat the pick
with that window's frame skipped. Chrome's `insideFrame` hooks and the new test
then share one function. The alternative, a float hit test over the resolved
items that honours clip and input regions, is the better end state and is what
stage 6 needs when the view tree goes, but it must reproduce popups, subsurface
order, input regions and the peek-preview rule in `hitTest`, so it is not first.

### What stays CPU raster

Title text, icons, buttons and the tab strip stay in the titlebar `ChromeBuffer`;
it loses its corner arcs and its footer twin, so a plain-rectangle titlebar
re-rasters only on width, title or state changes. Panels, Settings, Files and the
rest are untouched.

## Sub-stages

Each leaves a working compositor and its own gates.

**4a. Clip in the model (no visible change). Done.** `scene_graph.h` has
`rediwm_clip_spec` (what a tree sets: size, four radii, border, in source units),
`rediwm_clip` (the same in layout space), `rediwm_clip_resolve`, the per-corner
signed distance `rediwm_sd_rounded_box` (the stage 1 shader's formula),
`rediwm_coverage` and `rediwm_clip_opaque`. `projection.c` has two tree addons
beside zoom and scale: `rediwm_projection_set_tree_clip` (NULL removes it; bad
sizes, negative or non-finite radii and borders are refused) and
`rediwm_projection_set_tree_unclipped` (the popup barrier). Resolve evaluates a
tree's clip after that tree's own zoom and scale, so it follows its window and an
inner scale never changes it; an inner clipped tree replaces the outer shape for
its own leaves, and nothing intersects them. Each leaf stores its copy and
`item.clip` points at it (NULL when unclipped); the glass effect item takes its
target's clip into storage of its own. No compositor code sets a clip yet.

The opaque cover is the snapped frame minus a square at each corner two pixels
deeper than the radius (the margin keeps the anti-aliased arc, and the outward
rounding of a region converted to device pixels at any scale of 1 or more, out of
the claim). It returns up to three rectangles, or one full-height column when the
corners leave no room for a middle band: the first version returned nothing for a
pill-shaped window, which the property test caught. Tests (`test-projection`):
the geometry above against hand-computed distances including per-corner radii and
mirroring; a property test over six sizes, seven radius sets and scales 1 to 2
with fractional origins, asserting every claimed pixel has full coverage under the
shape, claims never overlap, square corners lose nothing and what is left out is
bounded; and the projection path (zoom, camera, nested scale, sibling window,
effect inheritance, replacement, removal, refusal of bad shapes, popup barrier,
destruction). Zoom, scale, clip and the barrier share one per-tree addon
(`tree_props`), so resolve does one lookup per tree, where zoom and scale had two.

Gate met. The existing projection tests are unchanged and pass; Debug and
ReleaseSafe build; `zig build test` passes; and screenshots from both presenters
at scale 1, 1.5 and mixed are **bit-identical to ones captured before 4a**
(16 of 16 each, tolerance 0). Cost was measured by timing `resolve()` on a
30-window scene of 120 trees and 600 leaves, built against the committed
`projection.c` and against this one, alternating runs: 10.1-10.2 us before and
10.9 us after, about **+0.7 us per resolve, 1 ns per leaf**. Ablation found where
it comes from: the unified lookup and the clip math cost nothing measurable; the
cost is writing the new `item.clip` field on every leaf, and writing only when it
changes (`else if (item->clip)`) halved it from 1.5 us. A typical scene has a
fraction of those leaves, so this is far below what any frame-level measure can
resolve; it is recorded rather than hidden because the gate said no cost change.

**4b. Clip, border and shadow in the pass. Done.** `scene_pass.h` gains
`rediwm_pass_shape` (a snapped device box, four radii, a border width and colour),
`rediwm_pass_shadow`, and three calls on a pass from `rediwm_scene_pass_begin`:
`rediwm_scene_pass_add_rect_shaped`, `_add_texture_shaped` and `_add_shadow`. They
take the same options as the wlroots calls, plus the shape; `wlr_render_pass` has
no way to carry one, hence the extension calls. The pass stays free of geometry
policy: the caller snaps the box (`rediwm_edges_snap`) and scales radii and border,
and nothing is rounded in the pass. Unclipped draws do not change at all: they keep
the stage 3 programs, and the shaped ones are separate.

The shader is the spike's, with three changes. The body, the ring and the
shadow are one fragment program with a `mode` uniform (texture, solid, shadow;
every fragment of a draw reads the same mode, so the branch costs nothing), built
twice, for `sampler2D` and for external. The shape's position relative to its
corner is computed in the vertex stage, so the distance function works on
window-sized numbers. And a radius is clamped to what fits, so a bad radius never
produces junk. The backdrop mode of the spike is not ported: glass keeps its own
blur until the stage that replaces it.

**Memory decided the program count.** Measured as anonymous RSS on the Intel node:
a GL program costs the driver 130-150 KiB **whatever its size** (the same for a
one-line solid fill and the full shaped shader). The first version built four
shaped programs with the renderer and added 600 KiB for nothing, on top of the
0.44 MiB stage 3 is already carrying. Now there are two, and they are built by
`rediwm_scene_renderer_enable_shapes` (once, outside a pass; idempotent), which
costs **about 430 KiB when called and nothing otherwise**. 4c calls it only when
the owned presenter will draw analytic frames. Until then a shaped draw fails the
pass at submit (tested), so a missed call cannot draw square corners silently.
If the build fails, plain drawing is unaffected and the caller learns it from the
return value.

Gates, all in `test-scene-pass` and run in Debug and ReleaseSafe:

* **Unclipped draws unchanged:** the 128 parity cases against wlroots stay at
  maximum difference **0**, and the same 128 run through the **shaped** programs
  with a shape that covers the whole buffer are also at 0 (so transform, crop,
  filter, alpha, XRGB, damage clip, no-VAO fallback and the external sampler are all
  exact there), plus external-OES shaped equal to wlroots, and a rounded shape on
  external equal to the same shape on the 2D texture.
* **Clip against an 8x8 supersampled reference** at scales 1, 1.25, 1.5 and 2 and
  zoom 1 to .25, windows built with `rediwm_clip_resolve` and `rediwm_edges_snap`:
  zero fringe, maximum error **18 levels of 208**. The spike's 12 did not include
  scale 1.25; the worst pixel is (2,2) of an 8.75 px radius, where area coverage is
  .33 and the one-pixel distance ramp gives .41. That is the ramp itself, not a
  defect: on a curved 45-degree edge it cannot equal area coverage, and `glass.c`
  already uses it. The bound is 20.
* **Piece joins:** titlebar, client and footer meet with no seam at every scale
  and zoom, and the snapped pieces tile the shape exactly.
* **Border and body are one shape:** three pieces with a ring in the body's colour
  equal one plain body (difference 0), and the ring is its own colour on the outer
  row and the left edge.
* **Premultiplied edges:** half-transparent, XRGB with a junk alpha byte and a
  half-opacity texture, inside and on every edge pixel against area coverage.
* **The opaque cover of 4a, in real pixels:** drawing `rediwm_clip_opaque`'s
  rectangles with blending off and then the window over them changes nothing, at
  every scale and zoom. This is the claim 4c's blend decisions rest on.
* **Shadow** against the `erfc` profile (difference 0 levels), monotonic, kept out
  of the window when asked, and showing through when not.
* **Damage across a clip edge:** a full frame, then a second one painted only
  inside damage that cuts through two corner arcs, the ring and the shadow, equals
  the full repaint exactly (all four channels, 8 scale/zoom cases), with a control
  that the two frames really differ on both sides of the damage edge.

The gates can fail: a coverage ramp offset, a halved ring, a shadow that ignores
`hide`, a shaped texture that ignores the opaque flag, and a ring colour that is
dropped each fail a gate when injected into the shader.

Outside the fixture: Debug and ReleaseSafe builds and `zig build test` pass; the
owned presenter matches the legacy one on all 16 goldens at tolerance 0; and
`explicit_sync`, `direct_scanout`, `screenshot_regressions`, `appearance_chrome`,
`output_scale`, `desktop_damage` and `panel_damage` pass on the owned path.

Left for later, from what the numbers allow: the 128-case result means the shaped
program with no shape is exactly the plain one, so 4e could replace the three
plain programs by the two shaped ones and give back about 410 KiB, if the cost of
the solid fill (every rectangle goes through it) is acceptable. It is not done here.

**4c. Analytic frames, owned path only. Done.** When the owned presenter starts
and `enable_shapes` works, `Server.init` sets `chrome.analytic_frames` (before any
window exists: every frame height depends on it) and the legacy path is untouched.

What a decorated window is then:

* `Toplevel.applyShape` gives `frame_tree` one clip (frame size, the radius on all
  four corners, `frame_border`, and the ring colour times the window opacity), from
  `syncChrome` and `applyOpacity`. A maximized window has a square one, for its
  border; CSD and fullscreen windows have none and keep the rect outline.
* The footer is `frame_border`, so the frame is 9 px shorter at the default radius
  and the client reaches the bottom. `chrome.footerHeight` reads the flag, so the
  ~20 call sites followed without edits. Saved layouts store client geometry, so
  they restore at the same client size.
* Titlebar and footer are plain bands (`ChromeState.radius` 0, no outer
  anti-aliasing: the shader gives them corners and edge); the footer buffer stays as
  a one-row fill and is deleted in 4e. Border rects are off; side fills stay rects.
  No edge probe runs (`applyEdgeSample`), so a commit no longer pays its GL
  readback and acquire wait.
* `shadow_tree`, a new tree holding only the invisible resize grab, and every xdg
  popup carry `setTreeUnclipped`. Window capture, which draws the client alone in its
  own loop, is handed the frame's shape (`PassShape`) so a captured window keeps
  transparent bottom corners (D3).
* **Hit tests** needed no post-filter after all: the view's `point_accepts_input`
  (`accepts()` in `projection.c`) evaluates the shape, and `wlr_scene_node_at`
  already goes on to the next node under a point that declines. Pointer constraints,
  tablets and touch share it. A rect cannot decline, but the only rects under a
  shape are the 1 px side fills, which are resize edges anyway.
* **A changed clip damages its rim** (`damage_clip_change`, new `scene_damage.c`,
  tested without a GPU): the border colour changes on hover with no view moving, so
  nothing else would tell wlroots. The rim is as wide as the largest radius plus the
  border and a margin.

Deviations from the plan, each forced by something found on the way:

* **The ring is composited over the body, not split from it.** The default
  `window_border` is `rgba(1,1,1,0.09)`; the spike's partition (body keeps the inset
  shape, the ring the rest) assumes an opaque ring and would draw a nearly invisible
  one over a transparent window. The shader now computes
  `(body * (1 - ring.a * w) + ring * w) * coverage`, which equals the partition for
  an opaque ring and matches the legacy border rects for a translucent one (gate 3
  has the case). This changed the 4b shader.
* **The ring is uniform: `max(1, round(border * scale))`.** The legacy straight edge
  is a snapped rect whose width follows the device grid (at 1.25 the right edge is two
  pixels, the left one). The two agree on integer scales; `frame_parity` leaves the
  rightmost column out on fractional scales.
* **A clipped item is drawn in two parts** (`scene_output.c`): the ring-free interior
  as before, one rectangle deeper than the corner arcs and the ring (a cross of three
  rectangles cost about twelve scissored draws per window), and the rest through the
  shape. Only that interior may block what is below or skip blending; the model's
  cover is used for occlusion, minus a margin for the ring. A window's items share one
  clip, so its cover is built once per run. Scanout refuses a clipped item.
* Output transforms permute the radii (`device_radii`, derived from the same
  function that places the boxes).

Gates:

* **Screenshots, legacy and owned side by side** (`frame_parity`, at 1, 1.25, 1.5 and
  2): titlebar band, left and right side columns, the client interior and the shadow
  are **bit-identical** (maximum difference 0); the frame is 9 px shorter and its
  client box equal. The corner arcs differ by at most one level. The goldens cannot
  match whole any more (the bottom band differs, and the shadow moves up with it),
  and a recapture at scale 1 shows the client regions at the same positions.
* **Corners and clicks** (`window_corners.py`, owned): the client's bottom corner
  pixels are the wallpaper, the interior next to the arc keeps the client colour, a
  hit test at a clipped corner reaches nothing (`none`) while the interior is the
  window's. Unit tests in `projection_test.c`: the same point falls through to a
  window below, and a changed border colour, a new shape and a removed one damage the
  rim and only the rim, nothing for an unchanged one or a hidden window.
* **Window capture** (`capture.py`, owned, server-decorated fixture): bottom corners
  are transparent (premultiplied black, alpha 0), interior intact.
* Skirt check of `window_corners.py` made footer-aware; the Xwayland titlebar pin
  (41, stale since the default `chrome_height` became 46; the code gives
  `round(46 * 0.75)` = 35) is corrected and `test_native_scaling_managed_window`
  passes on both presenters.
* Owned-path runs of `appearance_chrome`, `decorations`, `kde_decorations`,
  `window_snapping`, `window_tabs`, `direct_scanout`, `explicit_sync`,
  `desktop_damage`, `panel_damage`, `capture`, `screenshot_regressions`,
  `output_scale`, `popup_constraint`, `focus_zoom`, `initial_window_state`,
  `workspaces`, `output_destroy`, `pointer_constraints` and `mini_map_windows` pass.
  Failures that also occur identically on legacy (`desktop_canvas`, `desktop_zoom`,
  `mini_map`, `mini_map_canvas`, `files_decoration`, `glass_hold`, `wifi_popup`, and
  `window_titles`, whose client sends an invalid UTF-8 title) are not this stage's.
  `workspace_focus` in `window_corners.py` flaked on both presenters.

Cost, measured on one binary with analytic frames on and off, interleaved on, off,
off, on at scale 1 (`scene-graph-stage4-results.json`; pair spread 0.1 to 23 %, so
read only the larger differences): resize is cheaper (`projection_cpu` -17 %,
`cpu_frame` -5 %). Where a whole window repaints it is dearer: `damage_full` and
drag read **+10 to +14 % output-build CPU and +10 to +12 % GPU** (about +40 to +90
us a frame), the lighter scenarios 0 to +7 %. That is a finding against "no rise in
build CPU or GPU": the shaded rim, program switches between the plain and the shaped
program, and about five draws per window item instead of one. Memory: nothing from
the frames themselves, but `enable_shapes` costs **about 1.3 MiB of anonymous
memory** in the real compositor (the isolated link measured 430 KiB; the driver
holds more once the programs exist), on top of the 0.44 MiB of stage 3. Both are
expected to come back in 4e (footer buffers, the plain programs, the probe's state),
and 4d removes the shadow patch cache if it passes.

Consequence for input: with the client reaching the bottom edge, the resize grab
inside the frame at the bottom shrinks from the 10 px footer to about 1 px (the 10 px
reach outside is unchanged), like the left and right edges, and the south corner
zones shrink with it. Revisit if it is felt.

Leftover: the 4b A/B reference (legacy vs owned, before 4c) reads +5.1 % in
mixed/glass, 0.1 point over its limit and the same cell that read +4.4 % in stage 3.

**4d. Analytic shadows (owned path).** Replace the CPU patch set with the
spike's analytic shadow. Gate: side-by-side against the CPU shadow, especially
corners (the spike compared only straight edges: approximate at corners), within
an agreed tolerance and no visible change in `appearance_chrome`. If the corners
do not pass, keep the CPU patches and drop this sub-stage; it is not on the
critical path.

**4e. Flip and delete.** Make `owned` the default (it requires the stage 3 hardware
checklist to have passed on a real KMS session), then delete the code only the
legacy presenter needed: `probeClientEdge` and the edge-sample machinery in
`Toplevel.zig` and `chrome.zig`, `EdgeMapping`/`decideEdgeSample`/`sampleEdge`,
`side_fills`, `border_rects` for decorated windows, the footer `ChromeBuffer`,
`FooterMemo`, the CPU arcs, the shadow patch cache if 4d passed, and
`edge_sampling.py`. Rewrite the "Borders have two paths" and "Skirt colour" notes
in `AGENTS.md`. The audit of the ~22 footer sites happens here for the legacy flag
(D1 decides whether it disappears).

## Cost expectations

| Area | Expectation |
|---|---|
| Idle CPU, wakeups | Unchanged; no new timers. |
| Commit of a client | Lower: no edge probe (GL readback, acquire wait, format memo). |
| Resize and move frames | Lower: the footer raster and the titlebar arcs go; titlebar re-rasters only on width/title/state. |
| Output build CPU | Within the stage 3 tolerance of the stage 3 figures. |
| GPU | A distance-field multiply per fragment of clipped windows only; check `gpu_elapsed`. |
| RAM | Lower after 4e: footer buffers, and with 4d the shadow patch cache, are freed. 4c adds the shaped programs (about 430 KiB, `enable_shapes`) on the owned path only; judge the net of the two. |

The live legacy/owned A/B (`tests/scene_ab.py`) stops being meaningful once the
frames differ (4c), so record an owned reference with it, and the `clean` baseline,
before 4c and judge the stage against those.

## Risks

* **Client geometry changes.** At the default radius a floating window of a given
  client size is 9 logical px shorter, and a tile or other fixed-frame window
  gains 9 px of client height. Snap, resize edges, tabs, Xwayland and the pinned
  tests need the audit above; known assertions (Xwayland 41 vs 35) get rewritten
  with the explicit numbers, not loosened.
* **Opaque-region culling through corners** (over-culling shows holes) and **damage
  at the clip edge** (stale edge pixels): both have explicit rules and gates.
* **Hit-test post-filter** must keep pointer constraints, tablets, touch and
  drag-and-drop on one path (they all use `hitTest`).
* **Consumers that bypass the group** (audited in 4a): the close-animation
  snapshot is a child of `content_tree`, hence inside the clipped tree, and
  inherits the shape. The taskbar peek only changes the real window's opacity.
  The switcher shows a scaled thumbnail of the client buffer on a card and the
  mini-map draws rectangles; neither shows a framed window, so neither changes.
  **Window capture does bypass it:** `WindowCaptureSource` walks the content tree
  with `wlr_scene_node_for_each_buffer` and draws each buffer in its own loop
  (through the selected pass). It captures the client without the chrome, so D3
  reduces to the client's two bottom corners; making them transparent means giving
  that loop the frame's clip and the clip shader (4c), not a graph change.
* **Fractional zoom and 1/N:** the arc is analytic, but the quad edges still snap;
  gates cover the full grid.
* **Pre-existing failures** in suites this stage rewrites (`window_corners` flake,
  the Xwayland titlebar assertion) are fixed here rather than carried.

## Decisions (taken 2026-10-09, all as recommended)

* **D1. The legacy presenter goes at 4e.** The `legacy` choice is removed there,
  folding the chrome-related part of stage 6 into this stage, and the footer flag
  disappears with it. It follows the stage 3 hardware checklist and a period of
  use with `owned` as the default; until then 4c keeps the old geometry behind the
  flag. Cost: no fallback if the owned path misbehaves on some GPU, which is why
  the checklist comes first.
* **D2. Shadows:** try analytic in 4d and keep the CPU patches as the fallback if
  the corners do not pass.
* **D3. Window capture:** the client's bottom corners are transparent in a
  captured window (see the audit above for how).
* **D4. CSD windows:** stay unclipped, with the rect outline.
* **D5. Hit tests:** a shape post-filter on the existing pick now; the graph hit
  test arrives with stage 6.

## Not in this stage

Backdrop blur in the pass (stage 5), deleting `wlr_scene` output rendering and the
projection view tree (stage 6), per-surface dmabuf feedback, and any change to
text, icons or the Cairo-drawn clients.
