# Scene graph plan, stage 5: backdrop effects in the pass

Status: **draft, decisions open**, 2026-10-11. Stage 4 of
[scene-graph.md](scene-graph.md) is done (window shapes, analytic shadows, the
owned pass as the only presenter). This stage moves glass, the blurred backdrop
behind titlebars, the taskbar and the start and power menus, from its side
channel (`src/glass.c`) into the owned output pass.

## Goal and exit

An effect is an item in the graph, drawn in paint order by the output pass: copy
the framebuffer region it samples, blur it, and composite it through the
target's shape and alpha. No scene re-walk, no private render pass, no per-effect
GL context switch or `glFlush`, no effect buffers published back into the scene.

Exit:

* Glass looks the same: side by side with `glass.c` at scales 1, 1.5 and mixed,
  for each kind (titlebar, taskbar, panel), within an agreed tolerance; no seam
  with the target, no black at output edges, clipped by the window shape.
* Idle makes no wakeups, and an effect is not re-blurred when nothing behind it
  changed (typing in a terminal must not re-blur its own titlebar).
* Cost at the stage gate (run once, after the last sub-stage): CPU per frame
  lower than stage 4 wherever glass is on screen, GPU not above it, anonymous
  memory lower (the per-effect capture, output and intermediate buffers go).
* `glass.c`'s capture walk, dependency tracking, per-effect contexts, effect
  output buffers and `effect_scale` are deleted.

## What exists today

Verified in the code on 2026-10-11 (`glass.c`, `Output.zig`, `Input.zig`,
`World.zig`, `scene_output.c`).

* **Four attach sites, three kinds.** `Toplevel` (titlebar, one per window),
  `Taskbar` (taskbar), `start_menu/panel.zig` and `power_menu.zig` (panel).
  Sigma 22, 24 and 26 logical px (times the window zoom), saturation 1.5 or 1.6.
* **Per frame, before each output build**, `Output.zig` calls
  `glass.Engine.update`, which walks the scene for effect nodes and, per effect,
  walks the **scene prefix** (everything below the effect, across all outputs)
  to hash it and record dependencies; a changed hash re-renders the prefix into
  a private quarter-size capture buffer (`capture_prefix`, its own render pass),
  blurs it twice (49 taps each way) into two per-effect intermediate textures,
  and runs a finish shader (saturation, rounded coverage, alpha chosen against
  the target's alpha so the pair has exactly the coverage) into a per-effect
  output buffer, which is set on the effect's scene node. The owned pass then
  draws that node as an ordinary texture (`REDIWM_ITEM_EFFECT`).
* **Dependencies** (`glass_dependency`) keep every commit of every surface below
  an effect until the effect next looks, so a commit beneath an opaque window
  still invalidates the blur. Things above the effect (the window's own client)
  are not dependencies: typing in a terminal never re-blurs its titlebar.
* **Holds.** A dragged window's titlebar keeps its blur until release when it is
  at least 98 % opaque (`Input.heldGlass`), and camera pans, pinches and zoom
  animations hold every effect (`World.holdingGlass`). The default theme
  (window_bg 0.80) does not hold titlebars.
* **One scale per effect** (`effect_scale`): the sharpest output the target
  touches, because one scene node shows one buffer. It had to be made
  output-independent to stop mixed-scale desktops re-blurring forever.
* **Cost** (memory notes and stage 0): about 0.35 ms per re-blurred effect, CPU
  dominated by the prefix walk, the private pass and the flush; the stage 1 spike
  did the same blur in-pass for 0.006-0.019 ms CPU and the same GPU.
* **Memory** per effect: a capture buffer, two intermediate textures and two
  output buffers. Two GL programs (blur, finish), about 280 KiB.

## The design problem: what invalidates a blur

The spike's rule (stage 1, gate 8) is that an effect copies the framebuffer at
its place in paint order. With buffer age, pixels outside this frame's damage
hold the **last frame's final image**, which includes everything drawn above the
effect (the window's own client, other windows). So whenever an effect is
re-blurred, its whole sample extent (target plus 3 sigma padding) must be
repainted from the bottom up first: damage expands to the padded extent. And
culling must not drop items below the effect inside the padded extent even when
an opaque item above the effect hides them on screen.

That is correct but, applied to every damage, it re-blurs a titlebar whenever
its own client commits (the client lies inside the titlebar's padding): every
keystroke, every video frame. Today's dependency tracking avoids that. Hence D1.

## Decisions to take

* **D1. When an effect is re-blurred.**
  * (A) Whenever any damage touches its padded extent. Simplest; deletes all
    caching. Re-blurs titlebars on their own client's commits: a GPU cost of
    about 0.2 ms per frame per visible glass titlebar during ordinary use.
  * (B) **Recommended.** Only when something *below* the effect changed in its
    padded extent: the graph attributes damage to items (resolve already knows
    each leaf's commit damage, buffer replacement and geometry change), so the
    pass can tell below-damage from above-damage. Each effect keeps its last
    blur as one small quarter-size texture per output; when nothing below
    changed, a damaged target is composited from that texture without copying
    or blurring. Keeps today's "typing never re-blurs" property at a fraction of
    today's memory.
  * (C) Keep a per-effect offscreen prefix render, as `glass.c` does, but driven
    by the pass's item list. Keeps the behaviour but not the saving: still a
    second render of everything behind each effect.
* **D2. Holds.** The master plan said to delete the drag hold. With D1 (B) a
  hold costs nothing extra: it is "reuse the cached blur, do not re-blur".
  * (A) **Recommended.** Keep both holds (drag at ≥ 98 % opacity, camera motion)
    as cache reuse; the separate hold machinery in `glass.c` goes.
  * (B) Delete them: blur stays live while dragging and panning, at the re-blur
    cost every frame of the motion (today's cost when the hold does not apply).
* **D3. Multi-output.** (A) **Recommended**: an effect is drawn per output at that
  output's scale from that output's framebuffer; a window spanning two outputs
  blurs each side with what that output shows, replicating the edge where it
  ends. Removes `effect_scale` and the mixed-scale idle-loop hazard by
  construction. (B) Keep one blur per effect at the sharpest scale, as today:
  needs the cross-output prefix, i.e. D1 (C).
* **D4. Programs.** (A) **Recommended**: the composite becomes mode 3 of the
  existing shaped program (it already has the shape, coverage and ring), and the
  blur is one new program: net one program fewer than today (about 140 KiB).
  Fold in stage 4's memory follow-up here: the three plain programs go if solid
  and texture draws through the shaped program cost nothing measurable (4b
  showed them bit-identical). (B) Port both glass programs as they are.

## Sub-stages

Each leaves a working compositor and its own correctness gates; cost is judged
once, after 5e (see [scene-graph-stage4.md](scene-graph-stage4.md), Measurement).

* **5a. Effect items and damage attribution in the graph.** An effect item carries
  its kind, sigma, saturation, opacity, target link and padded extent; resolve
  records per-item damage in layout space (the input to D1 (B)). Pure tests in
  `projection_test.c`: below/above attribution, geometry changes, hidden and
  destroyed items.
* **5b. Backdrop primitives in `scene_pass`.** Region copy from the pass's
  framebuffer, the two quarter-size blur passes (unscissored), the composite
  through the shape with the target's alpha. Gates in `test-scene-pass`: the
  result equals `glass.c`'s finish for the same input within tolerance; edge
  replication at the buffer edge; a partial repaint with damage expansion equals
  a full repaint (spike gate 8); no seam between composite and target.
* **5c. Output pass integration behind `glass.c`.** `scene_output.c` draws effect
  items itself: un-cover the padded extent below an effect while collecting,
  expand damage per D1, keep the per-effect, per-output cache, apply holds per D2.
  `glass.c` stops rendering but still owns attach/configure. Gates: `glass_test`
  converted to the pass, `glass_hold.py`, appearance and window suites, IPC
  screenshots against stage 4 glass within tolerance at 1, 1.5 and mixed.
* **5d. Delete.** The capture walk, dependencies, contexts, effect output
  buffers, intermediate textures, `effect_scale`, `rediwm_glass_project` and the
  effect scene nodes; the Zig `glass.Effect` API shrinks to attach/configure.
  Rewrite the Glass notes in `AGENTS.md`.
* **5e. Stage cost gate** against stage 4 (and the stage 0 baseline): the same
  harness as 4e, clean sessions for CPU and memory; a same-session GPU
  comparison if the stats timers stay too noisy across builds.

## Risks

* **Stale blur.** Missing a below-damage leaves an old blur on screen. The
  attribution tests in 5a and a forced-full-repaint comparison in 5c cover it.
* **Over-repaint.** Expanding damage to padded extents makes the damaged area
  larger than today's on every re-blur; the gain is in CPU, not in pixels.
* **Glass across outputs** looks different at the output edge under D3 (A): the
  edge is replicated rather than the other output's content.
* **Capture.** Screenshots and screencopy already build through the pass and get
  glass for free; window capture draws the client alone and is unaffected.
