# Scene graph plan, stage 2: typed node model behind the presenter

Status: stage 2 of [scene-graph.md](scene-graph.md), done 2026-10-09 on the machine
and conditions of the [stage 0 baseline](scene-graph-baseline.md). Result: **no
visible change** (16 of 16 golden screenshots bit-identical), instructions/s and RSS
flat, and a measured **+13 % on a steady-state projection sync** (about 1.3 µs on a
288-leaf desktop). `projection.h` and every Zig caller are untouched.

## What was built

`projection.c`'s one `project()` walk composed the transform, rounded and wrote
`wlr_scene` setters in the same function. It is now two phases around a typed graph:

* **`src/scene_graph.h`** (pure, no wlroots calls, no state): `rediwm_xform` (uniform
  scale plus translation, composed by `rediwm_xform_scale_about`), `rediwm_edges`
  (a rectangle as four unrounded edges), `rediwm_edges_snap` (the only rounding),
  `rediwm_content` (opacity, colour, source box, transform, filter, colour
  description) and `rediwm_item` (kind, enabled, source size, scale, edges,
  content). The kinds are `RECT`, `SURFACE`, `BUFFER` (compositor-owned raster) and
  `EFFECT` (a glass backdrop). `EFFECT` replaces the old test of a node's
  `point_accepts_input` function pointer.
* **`resolve()`** walks the source tree and writes, for every leaf, a `rediwm_item`
  and, for every top-level group, an unrounded origin; groups and the leaves under
  them are linked in paint order (`projection->paint`, `group->items`). It moves,
  sizes and shows no view node.
* **`present()`** reads only that graph (plus the content the source still owns, see
  below), rounds once and applies: group origins, reparenting, ordering, the setters
  behind the `view_state` cache, buffer swaps and damage, and hiding what the pass
  no longer reaches. It derives no geometry.

Every expression in `scene_graph.h` is the one `project()` evaluated inline (same
operands, same order); a rounding that moves by one pixel at a half-pixel edge would
be a visible change. A rectangle is carried as **edges, not origin and size**, so a
size is always the difference of two rounded edges and neighbours that share an edge
share a pixel column at any zoom.

## Gates

| # | Gate | Result |
|---|---|---|
| 1 | The existing `projection_test.c` assertions pass unchanged. | Pass. Only the glass stub became controllable (it returned `false`; it now returns whether the node is the test's effect node). |
| 2 | The 16 stage 0 goldens (scale 1, 1.5 and mixed; windows, fullscreen, zoom 0.70 and `camera_zoom_min`; both outputs) against a `HEAD` binary built from the parent commit. | **All 16 identical: max difference 0, 0 pixels over tolerance.** |
| 3 | `zig build test`, `test-glass`, `test-pass-spike`, Debug and `-Doptimize=ReleaseSafe` builds. | Pass; `zig build test` prints the same two stderr lines as `HEAD`. |
| 4 | Cost in the harness (A-B-B-A, `HEAD` against this change, scale 1, 1.5 and mixed, 10 scenarios each). | Instructions/s geometric mean new/head **1.007, 1.003, 1.001** (worst scenario 1.046); RSS 1.004–1.007 (under 1 MiB). |
| 5 | Cost of the sync itself (`projection.c` old against new, same compiler, 12 windows × 24 leaves, nothing moving, interleaved). | **+13 %**: about 9.5–10.6 µs → 11.0–11.2 µs per sync. In the harness `projection_cpu` reads +22.9 % against control timers (`scene_commit`, `glass`, `cpu_frame`) that drifted +9.5 to +11.5 % in the same runs, so about +12 % net: the same figure by two methods. |

The extra cost is list work per leaf (detach, insert, an 88-byte content copy);
about 4.5 ns a leaf, 0.3 % of a typical 0.4 ms frame. It was not reduced: the stage 3
pass will iterate these lists instead of the view tree, which is where it pays back.

The harness runs overlapped with other work on the machine (compiles and bus probes
of mine, and the live session's own load, see
[the Services client](#unrelated-finding-the-services-client)), so its CPU % and
frame timers swing ±20–60 %; only instructions/s, RSS and the paired comparisons
above are claimed.

## Tests

`test_graph` in `projection_test.c` pins what the stage adds:

* resolve alone moves no view (positions, sizes, the applied-state cache);
* items are typed (`RECT`, `BUFFER`, `SURFACE` once wlroots binds a surface,
  `EFFECT`) and hold the **exact, unrounded** edges at fractional zoom and window
  scale, in the order the camera, the window zoom about its origin and the size
  compose;
* scaled content is filtered bilinearly whatever the client asked for;
* every presented view is exactly the snap of its item (`assert_presented`), at zoom
  steps across a fixed-desktop group;
* paint order through raise, reparent, a disabled branch and a subtree the pass no
  longer reaches, and the lists after each destruction order.

Mutants confirmed the guards bite: removing the detach in `finish_group` fails the
list-lifetime probe, leaving stale leaf links in `resolve` trips a wlroots assert,
and moving a view in `resolve` fails the existing damage test.

**A trap found on the way.** The first lifetime test passed with the bug in place.
The dangling list head only arises in the view-first teardown (`group_view_destroy`
frees the group, then a leaf's own teardown writes into it), and glibc 2.44 does not
poison small freed chunks (they go straight to the tcache, contents intact), neither
under `mallopt(M_PERTURB)` nor `MALLOC_PERTURB_`. The test now puts a probe addon on
each leaf view, which runs after the group is freed and before the leaf's own
teardown, and checks the links directly; it also counts its checks so a wrong
ordering assumption fails loudly instead of checking nothing.

## What stage 2 does not do

* **No `clip` and no tree opacity.** The plan lists them for the graph; nothing can
  produce or consume them before stage 4 (a producer on `Toplevel`, a consumer in the
  owned pass), and a resolved but unused field is dead code with nothing to test it.
  They enter with their first producer: a field on the item, not a computation in
  `present_leaf` (this is in `AGENTS.md`).
* **Content identity is still the source's.** `present` reads the buffer, its wait
  point and the opaque region from the source node, and tracks surface damage in the
  leaf. They move into the item with the first consumer that is not `wlr_scene`
  (stage 3, which needs the texture and the acquire point).
* **The source tree is still integer and `wlr_scene`.** About 108 Zig call sites set
  positions on it; floats enter as the camera, window zoom and Xwayland `1/N` scale
  compose. A fractional placement needs a producer like `setTreeZoom`.
* **Others still read the view tree's geometry:** `glass.c` (`wlr_scene_node_coords`,
  `dst_width`, `rediwm_projection_node_zoom`) until stage 5, and hit testing
  (`accepts` maps through the view's size) until stage 4.

## Next: stage 3

The graph is complete enough for the owned pass to consume without the view tree:
groups in paint order, leaves in paint order, float edges, scale, kind and content.
What it still needs from the source, in the order the baseline's `wlr_scene_output`
inventory lists it: the texture and acquire point, the opaque region (to cull), and
per-output damage. The owned pass replaces `present` for rendering while `present`
keeps serving `wlr_scene_output` until stage 6.

## Unrelated finding: the Services client

Found while measuring: the live session's PID 1 and polkitd were each at about 50 %
of a core. That is `systemd.zig`, not this work, and is fixed in the same working
tree (see `src/control_center/AGENTS.md`, "The Services client").
