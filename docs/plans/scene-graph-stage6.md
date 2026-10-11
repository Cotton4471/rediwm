# Scene graph plan, stage 6: one tree

Status: **draft, decisions open**, 2026-10-11. Stages 0 to 5 of
[scene-graph.md](scene-graph.md) are done: the owned output pass is the only
presenter and draws window shapes, shadows and glass from the typed graph. This
stage removes the last mirror: the projection's **view tree**, a second copy of
every window's scene nodes that no longer draws anything but still carries hit
testing, damage and surface feedback. The source scene tree stays as the surface
adapter (the master plan keeps replacing it for a later, separate decision).

## Goal and exit

The graph is the one description of the world: `resolve` reads the source tree,
and the output pass, hit testing, damage and every per-surface protocol event
come from the resolved items. No view nodes, no per-leaf `view_state` cache, no
second lock on client buffers, no listeners moved between nodes.

Exit:

* Clients see the same protocol as today, per output: `wl_surface.enter/leave`,
  preferred buffer scale and transform, frame callbacks, presentation feedback,
  explicit-sync release points, for windows, subsurfaces, popups and Xwayland,
  at every camera zoom and across outputs of different scales.
* Hit testing gives the same node and local coordinates as today at every zoom,
  including rounded corners, popups, the resize reach and peek through dimmed
  windows.
* No frame shows stale pixels and idle makes no wakeups.
* Cost at the stage gate (once, after the last sub-stage): `projection_cpu` and
  instructions per frame lower than stage 5, anonymous memory lower (no view
  nodes), nothing else higher.

## What exists today

Verified in the code on 2026-10-11 (`projection.c`, `scene_output.c`,
`scene_data.zig`, `Output.zig`).

* **Two trees.** `World` creates the projection over `world_tree` (the source,
  disabled so wlroots ignores it) and `world_view`. Every leaf gets a view node;
  `present` positions it, sets its buffer (marking the second client-buffer lock
  ignorable so shm uploads stay in place), opacity, transform, opaque region, and
  moves the client surface's `outputs_update`, `output_sample` and `frame_done`
  listeners onto it (`route_surface`). Other trees (background, desktop, taskbar,
  overlays, IME, lock) are ordinary enabled scene nodes outside the projection.
* **What the view tree still does:**
  1. *Hit testing.* `scene_data.hitTest` calls `wlr_scene_node_at` on the scene
     root, which reaches the view nodes (with `accepts()` declining points a
     window's shape cuts away) and maps back with `projection.source`;
     `mini_map.zig` does one more pick.
  2. *Damage.* wlroots damages each output's ring when a view node moves, changes
     or gets a new buffer; the owned pass reads that ring. The graph already
     records the same changes as damage events (stage 5a), used by glass only.
  3. *Surface feedback.* wlroots computes each view buffer's outputs and primary
     output from its visibility and emits `outputs_update`/`output_enter`/
     `output_leave`; `Output.sendFrameDone` walks the scene for frame callbacks;
     the pass emits `output_sample` on the view (release points, presentation).
     `wlr_scene_surface` turns these into the protocol.
  4. *Transport.* The pass reads buffers, textures, single-pixel colours, wait
     points and opaque regions from the view nodes, which copy them from the
     source each sync.
* **Cost** (stage 5 gate): `projection_cpu` is 0.03 to 0.24 ms a frame, most of
  it `present` writing views; each view is a `wlr_scene_buffer` plus a cache entry.

## Design

The pass already walks the graph per output. Each of the four jobs moves to it:

* **Hit testing** walks the same items top to bottom (world items in paint order,
  layout nodes as today): the float edges, the window shape, then the source
  buffer's own `point_accepts_input` in source-local coordinates. Layout trees can
  keep `wlr_scene_node_at` (D1).
* **Damage** for the world comes from the graph's damage events, mapped to each
  output's device pixels, added to its ring and commit damage, plus a frame
  request. Layout trees keep wlroots' damage.
* **Feedback**: per output frame, the pass knows which surface items it drew and
  how much of each is visible. From that it keeps, per source buffer, the active
  outputs and a primary output (wlroots' rule, D3), and emits the scene buffer's
  own `outputs_update`/`output_enter`/`output_leave` and `frame_done`
  (`wlr_scene_buffer_send_frame_done`) on the *source* buffer, where
  `wlr_scene_surface` listens natively. `output_sample` moves to the source too.
  An item that is culled or off every output still needs its outputs cleared and
  no frame callbacks, as wlroots does for hidden nodes.
* **Transport** reads the source buffer directly: textures are cached on it, the
  single-pixel colour and wait points are already there, and with one lock per
  client buffer the in-place upload rule needs no marking.

## Decisions to take

* **D1. Scope.** (A) **Recommended**: the world only. Background, desktop,
  taskbar, overlays, IME and lock stay ordinary scene nodes with wlroots' own
  damage, feedback and picking; the graph keeps reading them as layout items.
  They are few, mostly compositor-owned, and have no camera. (B) Everything
  through the graph, ending wlroots' scene output bookkeeping entirely: more
  code and more risk for nodes that gain nothing from it.
* **D2. Who sends the protocol.** (A) **Recommended**: emit wlroots' own scene
  buffer signals on the source buffers, so `wlr_scene_surface` keeps sending
  enter/leave, preferred scale and transform, frame callbacks and release points,
  as it does for every other compositor on wlroots. (B) Send the protocol
  ourselves: full control, but it duplicates what wlroots maintains and must
  track its fixes.
* **D3. Primary output.** (A) **Recommended**: wlroots' rule (the output showing
  the largest visible area), so preferred scale and frame pacing do not change
  for any client. (B) The sharpest output the surface touches, which would make
  a window spanning a 1x and a 2x output render at 2x (sharper, dearer).
* **D4. Migration safety.** (A) **Recommended**: build each replacement beside the
  view tree and compare in Debug builds (hit results, damage and active outputs
  against what wlroots computes on the views), then delete the views once all
  three agree. (B) Switch each job directly: faster, but a mismatch shows as a
  client bug rather than an assertion.
* **D5. Per-surface dmabuf feedback** (scanout tranches), absent in both presenters
  since stage 0: (A) **Recommended**: not in this stage; it is a feature, and the
  feedback paths built here make it a small follow-up. (B) Add it here.

## Sub-stages

Each leaves a working compositor with its own correctness gates; cost is judged
once, after 6e.

* **6a. Feedback from the graph, beside the views.** Per output and source buffer:
  active outputs and primary output from what the pass drew; emit on the source
  buffers behind a switch, while the views still emit. Debug check (D4): the
  sets agree with wlroots' on the views for every surface, every frame. Suites:
  `presentation_time`, `explicit_sync`, `output_scale`, `xdg_output`,
  `xwayland_fractional`, `capture`, `screencast`, and a multi-output, zoomed-camera
  case with a window spanning outputs.
* **6b. Damage from the graph, beside the views.** Device damage from the events;
  Debug check that it covers what wlroots damaged on the views. Suites:
  `desktop_damage`, `panel_damage`, `single_pixel`, `glass_reblur`, the pixel
  goldens of `scene_baseline.py` and a forced-full-repaint comparison.
* **6c. Hit testing on the graph.** `scene_data.hitTest` and `mini_map` pick from
  the items; Debug check against `wlr_scene_node_at` on the views over a grid of
  points at every zoom step. Suites: `window_corners` (clipped corners),
  `desktop_zoom`, `popup_constraint`, `taskbar_peek`, `input_protocols`,
  `files_drag`, `wlroots`-level pointer constraints.
* **6d. Delete the view tree.** `present` keeps only what the graph needs (the
  snap, events, clip and shadow damage); views, `view_state`, `route_surface`,
  the lock marking, `rediwm_projection_node`/`source` and the group view trees
  go. The pass reads source buffers. Rewrite the projection notes in
  `AGENTS.md` and the master plan's stage 6 entry.
* **6e. Stage cost gate** against stage 5, as 5e/5f ran it (same session, the
  performance profile, `glass_reblurs` recorded).

## Cost expectations

| Area | Expectation |
|---|---|
| Projection CPU | Lower: no view setters, no opaque-region mirroring, no buffer re-set per commit. |
| Output build | About level: a visibility tally per surface item it already visits. |
| Memory | Lower: one scene buffer and cache entry fewer per window leaf. |
| Wakeups | Unchanged; frame callbacks still only from presented frames. |

## Risks

* **Silent protocol drift.** A wrong active set or primary output shows up as a
  client rendering at the wrong scale or stalling without frame callbacks, not as
  a crash. D4's comparisons exist for this; the suites above cover the protocols.
* **Hidden surfaces.** wlroots clears outputs for disabled and fully occluded
  nodes; the replacement must do the same, or a minimized client keeps getting
  frame callbacks (idle wakeups) or never gets them back.
* **Xwayland stacking** stays in the source tree (`Toplevel.raise`); hit testing
  in paint order must keep matching it.
* **Pointer constraints, tablets, touch and drag-and-drop** all go through
  `hitTest`; one path keeps them consistent, and their suites run in 6c.
