# Scene graph, stage 7: retire the wlr_scene data model

Status: D1-D4 taken as recommended and D5 (idle-CPU items first, done: 6179c18) on
2026-10-15; 7a started on branch `stage7` (see "Findings from starting 7a").

## Why, and what it is not for

Stages 1-6 moved everything that *does* something off wlr_scene: the output pass
(`scene_output.c`), damage, hit testing, frame callbacks and feedback
(`projection.c`). What is left is wlr_scene as the *data model*: the nodes that
panels, popups, the dock, the lock and client windows hang from, and the
`wlr_scene_surface` glue that turns a `wl_surface` into a buffer node.

**This is not a performance stage.** Measured 2026-10-15 (ReleaseSafe, headless
GLES2, `perf record` 5 kHz, 12 s, 60 Hz test client, no damage): 2.18 % of a core;
`wlr_scene_*` + `wlr_addon_find` + `wlr_surface_from_resource` are 11.5 % of those
samples, about 0.25 % of a core, and an own tree still has to do the same
position/enable/buffer updates, so the achievable saving is a fraction of that.
Full damage: 7.57 % of a core, scene symbols 4.7 % of samples. The gate is
therefore **no regression**, not a win.

What it buys: one tree instead of source tree plus resolved items, no
`wlr_scene_node` private-field reads (`out->scene->private.direct_scanout`,
`private.color_manager_v1_destroy`), and node features (clip, shape, effect,
per-node inertness) as fields instead of addons (`wlr_addon_find` is 1.4 % of idle
samples on its own).

## Inventory (2026-10-15, `src/`)

* Zig: 45 `createSceneBuffer`, 36 `createSceneTree`, 1 `createSceneRect`, ~660
  `.destroy(` (mixed), 93 `.node.setEnabled`, 82 `.node.destroy`, 61
  `.node.setPosition`, 36 `setDestSize`, 32 `setFilterMode`, 30 `setBuffer`,
  12 `raiseToTop`, 6 `coords`, 5 `placeBelow`, 4 `setSourceBox`; `wlr.SceneBuffer`
  in ~30 files, `SceneTree` in ~20, `SceneRect` in 9.
* C: `projection.c` walks `struct wlr_scene_node` (56 struct references; fields
  read: `type`, `enabled`, `x`, `y`, `children`, `parent`, `data`);
  `scene_output.c` reads `wlr_scene_output`, `scene->outputs`,
  `scene->private.direct_scanout`, `scene->gamma_control_manager_v1`,
  `output->private.combined_color_transform`; `extra_protocols.c` reaches into
  `scene->color_manager_v1` and its private destroy listener.
* wlroots scene helpers still in use: `createSceneXdgSurface` (Toplevel, Popup),
  `wlr_scene_subsurface_tree_set_clip` (Toplevel), `SceneSurface.tryFromBuffer`
  (scene_data, text_input, capture/window_source), `forEachBuffer` (close
  snapshot, capture, Toplevel fade), `wlr_scene_node_at` (layout trees),
  `Scene.create` (also separate scenes in osd, caret_overlay, lock),
  `SceneOutputLayout`/`createSceneOutput`/`getSceneOutput` (Server, Output,
  reveal, capture, ipc), `wlr_scene_set_color_manager_v1`.

## What wlr_scene still does that must be replaced

1. **Node tree.** parent/children/stacking, position, enabled, `data`, destroy
   signal, reparent, raise/place-below, `coords`.
2. **Buffer node.** buffer, dest size, source box, opacity, filter, transform,
   opaque region, `primary_output`, and the signals the protocol glue relies on
   (stage 6 emits wlroots' own signals on source buffers: these become ours).
3. **Surface binding** (`wlr_scene_surface`, `wlr_scene_xdg_surface`,
   `wlr_scene_subsurface_tree`): wl_surface to buffer node, subsurface tracking
   and stacking, client-buffer lock, damage, xdg geometry origin, popup parenting,
   the subsurface clip. This is the only hard part, about 600 lines of wlroots.
4. **Output scene** (`wlr_scene_output`): the `needs_frame` latch (the frame loop
   hangs off it, see idle notes), position from the output layout, the bits of
   state `scene_output.c` reads from the scene (direct scanout flag, gamma and
   colour manager presence), `output_sample`/frame-done helpers.
5. **Hit test and iteration** for the layout trees (`node_at`, `for_each_buffer`).

## Findings from starting 7a (2026-10-15)

Reading `projection.c`, `scene_output.c` and `scene_damage.c` before writing code
showed that the sub-stages below understate 7a:

* **Layout trees are not resolved by the projection.** Only the world's source
  tree becomes leaves; the six layout trees (background, desktop, taskbar,
  overlay, IME, lock) are still wlroots nodes that `visit_items` walks and whose
  damage `wlr_scene_output` computes itself. The projection reports its own
  damage into wlroots' ring through `scene_damage.c`
  (`rediwm_scene_damage_layout`), and `scene_output.c` reads
  `out->private.pending_commit_damage` and `damage_ring`. So own nodes have to
  become projection sources too, as extra groups with an identity transform (the
  `sync_fixed` path already does this for one subtree), or layout damage is lost.
* **A mutation must ask for a frame.** The world's leaves hear their changes from
  surface commits and listeners; a plain `setPosition` on a layout node was heard by
  wlroots. The own mutators call the scene's `changed` hook for this
  (`node.c`), and the projection finds what moved by comparing items at the next
  sync, as it does for the world.
* **`scene_output.c` depends on `wlr_scene_buffer` internals** (`private.texture`,
  `renderer_destroy`, `own_buffer`, `wait_timeline`/`wait_point`,
  `is_single_pixel_buffer`, `buffer_is_opaque`, `buffer_width/height`), so the own
  buffer node has to carry the texture cache and wait points that
  `wlr_scene_buffer_set_buffer_with_options` keeps, not just the public fields.
* **More wlroots scene helpers in use** than the inventory listed:
  `wlr.SceneLayerSurfaceV1` (`LayerSurface.zig`), `createSceneSubsurfaceTree` (4
  sites: Toplevel, xwayland_unmanaged, text_input, client_lock).
* **Mixed trees** are needed while windows still use wlr_scene_xdg_surface: the
  `REDIWM_NODE_FOREIGN` kind holds a wlr subtree inside an own tree, hosted under
  one hidden disabled wlr_scene root. The projection resolves it with its existing
  wlr walk at the foreign node's accumulated position.

Revised 7a order, each step gated by identical goldens and the suites that pass on HEAD:

1. `node.h`/`node.c` and `node_test.c` (`zig build test-node`): the data model, the
   change hook, stacking, picking, teardown. **Done.**

**7a landed 2026-10-15 (steps 2 and 4 below, in one change).** Own buffer and rect
nodes keep a hidden wlr_scene *carrier* (kept in step by every setter) that
`scene_output.c` and `glass.c` read unchanged, so step 3 moves to 7c with the
carrier's removal. The projection resolves the own scene's layers (the six layout
trees and the world) into one graph, so `visit_items`, `layout_item` and the
wlroots pick are gone; layout damage comes from the projection, and
`set_buffer_with_damage` reports to it through the scene's `buffer_damaged` hook.
Gates: `test-node`, `test-projection`, `test-glass`, `test-scene-pass`, `zig build
test` pass; 100 of 136 integration scripts pass and the other 36 fail on HEAD with
the same last error line (`scene_baseline` is a benchmark, not run).
2. The projection reads `rediwm_node` sources (leaf/group/addons on the own node),
   resolves foreign subtrees, and takes the layout trees as extra groups with an
   identity transform; damage and picking for them move out of wlr_scene.
3. `scene_output.c` draws own buffers: texture cache, wait points, single-pixel
   colour, `output_sample`; `glass.c` effect nodes become own buffer nodes.
4. The Zig wrapper (`node.zig`, wlr_scene's method names) and the mechanical swap
   of call sites, layout trees first, then the compositor-drawn UI; windows keep
   `wlr.SceneTree` under a foreign node until 7b.

## Design

An own node module, C core with a thin Zig wrapper, living beside `scene_graph.h`:

* `rediwm_node` (kind tree | buffer | rect; parent, intrusive child list, x, y,
  enabled, `data`, destroy signal). `rediwm_buffer` and `rediwm_rect` embed it.
  `projection.c` walks these instead of `wlr_scene_node`; its tree-walk is
  already the resolve step, so the change is the type it reads.
* The Zig wrapper keeps the method names (`node.setPosition`, `setEnabled`,
  `createSceneBuffer` becomes `createBuffer`...) so the ~700 call sites change by
  rename, not by rewrite, and the diff is reviewable.
* `node_surface.c`: the surface binding, modelled on wlroots' `wlr_scene_surface`
  (MIT-licensed; keep the credit), reusing `wlr_client_buffer`, the existing
  feedback/frame-done code in `projection.c` and the long-held lock rules from
  AGENTS.md.
* `output_scene.c`: the per-output state `Output.zig` needs (needs-frame latch,
  position, damage hand-off to the pass), replacing `wlr_scene_output` and
  `SceneOutputLayout`; colour manager and gamma are plain pointers handed over by
  `extra_protocols.c`, which also removes the private-listener workaround.

## Sub-stages

* **7a** Own node/buffer/rect types and wrapper; migrate the compositor-drawn UI
  (panels, dock, taskbar, popups, lock, OSD, selector, toast, mini-map). Windows
  still use wlr_scene_surface, so 7a keeps a bridge: a wlr scene buffer node that
  is a *child of* an own tree is wrapped as an own buffer node with a listener
  (removed in 7b). Gate: goldens identical at tolerance 0, `zig build test`,
  the layout/hit-test suites.
* **7b** Surface binding: xdg toplevels, popups, subsurfaces, layer surfaces,
  Xwayland, IME popups, drag icons, session-lock surfaces, subsurface clip.
  Gate: the protocol suites (`wlr_protocols`, `popups`, xwayland, text-input,
  dnd) and a fresh damage audit build.
* **7c** Output scene and layout; remove `wlr_scene_output`, the colour-manager
  workaround and the `private.*` reads. Gate: output hot-plug suites (headless
  multi-output), `commitIsRedundant`, night light/power-off tests; VT checklist
  step 4 (hotplug) still unrun on hardware.
* **7d** Delete the `wlroots` scene dependency (`wlr/types/wlr_scene.h`); the
  separate `Scene.create` users go with it.
* **7e** Cost gate once, as in stage 6 (benchmark at stage end): same session
  A/B against stage 6, performance profile, idle floor, instructions:u, RSS.
  Tolerance: no regression beyond noise; the expected delta is -0 to -0.1 % of a
  core.

## Decisions to take

* **D1 API shape.** (A, recommended) keep wlroots' method names so call sites
  change by rename; (B) redesign the node API now. B is cleaner and a week longer
  with far more review surface.
* **D2 Surface binding.** (A, recommended) port wlroots' logic onto the own
  buffer node and keep `wlr_client_buffer`; (B) rewrite from the protocol spec.
  B risks every subsurface edge case wlroots already learned.
* **D3 Branch.** Work on `stage7`, one commit per sub-stage, merge to master only
  after 7e (same discipline as `stage4e`).
* **D4 Layout trees.** (A, recommended) migrate them in 7a too, so there is one
  tree type at the end; (B) leave them on wlr_scene and keep the dependency.
  B contradicts the point of the stage.
* **D5 Order with the idle-CPU items.** The per-frame ticks in `Output.runFrame`
  (`frame_metrics` timestamps, `anim`, Dock/Taskbar per-frame checks) and the
  per-frame `memset`/`clock_gettime` are independent of this stage and carry the
  measurable gain. (Recommended) do them first so the stage 7 gate measures
  against the improved baseline.

## Risks

* The surface binding is where the regressions will be (subsurface order, popups
  that outlive their parent, client-buffer lifetime). Nothing about the idle cost
  justifies shipping a regression there; 7b is the stage most likely to be cut.
* `wlr_scene_output_needs_frame` is the frame loop's latch. Replace it exactly
  or the loop spins (13,000 fps) or stalls; see the idle-CPU notes.
* The headless GLES2 suites have 34 known failures on HEAD: compare against a
  `git worktree` of HEAD before calling anything a regression.
