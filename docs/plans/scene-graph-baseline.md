# Scene graph plan, stage 0: baseline and inventory

Status: stage 0 of [scene-graph.md](scene-graph.md). Recorded 2026-10-08/09 on
`9e28bd4` (ReleaseSafe) with wlroots 0.20.2 (the pinned release). No behaviour changed; the
only code added is the measurement harness and a small test-client extension.

Contents: [Baseline](#baseline) · [Findings](#findings) ·
[`wlr_scene_output` inventory](#what-wlr_scene_output-does-today) ·
[GLES2 shader inventory](#what-wlroots-gles2-draws) ·
[Decisions](#policy-and-renderer-decisions)

## Baseline

### Harness

`tests/scene_baseline.py` runs a fixed workload in a headless GLES2 compositor
and writes one JSON file; `--capture DIR` also keeps golden screenshots.

```sh
umask 077
export WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128   # the iGPU on a multi-GPU machine
export XDG_STATE_HOME=$(mktemp -d)
python3 tests/scene_baseline.py --out head.json --capture golden/
python3 tests/scene_baseline.py --binary new/rediwm --out new.json --compare golden/
python3 tests/scene_baseline.py --report new.json --against head.json
```

Workload per scale configuration (`scale1`, `scale1.5`, `mixed` = a scale 1
and a scale 1.5 output, `mixed_noglass` = the same with `REDIWM_NO_GLASS=1`):
three overlapping fixture windows on a banded wallpaper with the default
(translucent, glass) theme, animations off, then

| Scenario | What runs |
|---|---|
| `idle` | Three static windows, 5 s. |
| `spinner_clear` | Window C repaints a 16×16 rectangle at 60 fps, clear of any glass. |
| `spinner_glass` | The same rectangle under window B's titlebar glass. |
| `damage_full` | C repaints its whole surface at 60 fps (as `tests/perf.py`). |
| `drag` | Window A dragged by its titlebar, 120 Hz pointer; in `mixed` across both outputs. |
| `resize` | Window B resized by `set_window_size` at 60 Hz. |
| `fullscreen` | C, 60 fps full damage, fullscreen. |
| `zoom_85`, `zoom_70`, `zoom_55` | Camera zoom levels with the glass spinner running. |
| `zoom_min_hold` | A held pinch at `camera_zoom_min` (release snaps back to a level). |

Two sessions per configuration: **clean** never calls the performance IPC and
records, from `/proc` and `perf stat` on the compositor process, CPU (summed
per-thread schedstat), instructions:u, voluntary and involuntary context
switches per second (by thread) and RSS; **stats** records the frame timers
(`cpu_frame`, `projection_cpu`, `glass_cpu`, `scene_commit_cpu`, `gpu_elapsed`,
chrome, taskbar and panel time), output commits and skipped commits. The first
performance call turns on the GPU timer (about 0.17 ms per frame), so process
figures are only comparable within a mode. The process is pinned to eight
P-core threads; compare runs from the same machine, interleaved.

Golden screenshots (`windows`, `fullscreen`, `zoom70`, `zoom_min`, per output)
are full-output IPC screenshots with the taskbar (a clock) masked on compare.
The compositor gets an uncreatable state directory so the layout autosave
cannot move windows mid-scenario (finding 10), and clients are placed and
fullscreened with explicit waits for position and buffer size.

### Results

`9e28bd4` ReleaseSafe (`rediwm`, 26.8 MB), 12th Gen Intel(R) Core(TM) i9-12900H, kernel 7.2.8-zen1-2-zen, GLES2 on the iGPU, pinned to P-core threads 2-9, AC power, platform profile `performance`, governor `schedutil`, EPP `performance`, 4 s per scenario (idle 5 s). Raw data: `docs/plans/scene-graph-baseline/head-9e28bd4.json`.

CPU % is of one core, summed over all compositor threads. Frame columns are mean ms per presented frame from the stats session (GPU timer on). *Commits* is presented output commits in the scenario (both outputs in `mixed`). Wakeups are voluntary context switches per second. Top thread: busiest thread by CPU.

#### Scale 1

| Scenario | CPU % | Minstr/s | wakeups/s | RSS MiB | commits | cpu_frame | projection | glass | scene commit | gpu | top thread |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| `idle` | 0.00 | 0.0 | 1 | 130 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | rediwm 0.0% |
| `spinner_clear` | 4.57 | 37.8 | 193 | 130 | 245 | 0.295 | 0.023 | 0.019 | 0.135 | 0.105 | rediwm 4.6% |
| `spinner_glass` | 5.55 | 68.4 | 191 | 130 | 242 | 0.482 | 0.021 | 0.228 | 0.127 | 0.339 | rediwm 5.6% |
| `damage_full` | 8.85 | 89.1 | 700 | 130 | 242 | 0.522 | 0.022 | 0.243 | 0.151 | 0.417 | rediwm 8.8% |
| `drag` | 3.70 | 74.7 | 172 | 131 | 242 | 0.611 | 0.056 | 0.250 | 0.186 | 0.536 | rediwm 3.7% |
| `resize` | 14.52 | 312.9 | 348 | 131 | 233 | 1.186 | 0.244 | 0.596 | 0.243 | 0.959 | rediwm 14.5% |
| `fullscreen` | 41.91 | 60.9 | 127 | 134 | 231 | 0.361 | 0.024 | 0.008 | 0.234 | 0.549 | rediwm 41.9% |
| `zoom_85` | 5.88 | 66.0 | 195 | 134 | 242 | 0.538 | 0.023 | 0.258 | 0.135 | 0.376 | rediwm 5.9% |
| `zoom_70` | 5.74 | 68.6 | 191 | 135 | 242 | 0.525 | 0.023 | 0.250 | 0.137 | 0.362 | rediwm 5.7% |
| `zoom_55` | 6.33 | 66.0 | 191 | 135 | 242 | 0.512 | 0.022 | 0.245 | 0.130 | 0.349 | rediwm 6.3% |
| `zoom_min_hold` | 4.93 | 38.8 | 193 | 135 | 246 | 0.312 | 0.022 | 0.006 | 0.152 | 0.119 | rediwm 4.9% |

#### Scale 1.5

| Scenario | CPU % | Minstr/s | wakeups/s | RSS MiB | commits | cpu_frame | projection | glass | scene commit | gpu | top thread |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| `idle` | 0.01 | 0.0 | 1 | 134 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | rediwm 0.0% |
| `spinner_clear` | 4.19 | 40.0 | 193 | 135 | 245 | 0.335 | 0.027 | 0.020 | 0.153 | 0.136 | rediwm 4.2% |
| `spinner_glass` | 6.86 | 71.1 | 189 | 135 | 244 | 0.395 | 0.017 | 0.184 | 0.106 | 0.304 | rediwm 6.9% |
| `damage_full` | 9.52 | 95.6 | 696 | 135 | 242 | 0.503 | 0.020 | 0.220 | 0.164 | 0.446 | rediwm 9.5% |
| `drag` | 3.68 | 78.3 | 172 | 135 | 242 | 0.673 | 0.063 | 0.266 | 0.218 | 0.651 | rediwm 3.7% |
| `resize` | 15.62 | 489.6 | 340 | 135 | 232 | 1.183 | 0.236 | 0.591 | 0.264 | 1.089 | rediwm 15.6% |
| `fullscreen` | 33.38 | 64.4 | 154 | 143 | 230 | 0.419 | 0.026 | 0.010 | 0.280 | 0.899 | rediwm 33.4% |
| `zoom_85` | 6.34 | 69.4 | 191 | 143 | 242 | 0.479 | 0.020 | 0.223 | 0.131 | 0.353 | rediwm 6.3% |
| `zoom_70` | 6.60 | 71.3 | 193 | 143 | 243 | 0.433 | 0.020 | 0.200 | 0.117 | 0.305 | rediwm 6.6% |
| `zoom_55` | 6.79 | 69.6 | 190 | 143 | 242 | 0.511 | 0.021 | 0.237 | 0.135 | 0.358 | rediwm 6.8% |
| `zoom_min_hold` | 5.17 | 40.9 | 192 | 143 | 246 | 0.290 | 0.021 | 0.005 | 0.144 | 0.114 | rediwm 5.2% |

#### Mixed scales (1 and 1.5), glass on

| Scenario | CPU % | Minstr/s | wakeups/s | RSS MiB | commits | cpu_frame | projection | glass | scene commit | gpu | top thread |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| `idle` | 8.91 | 215.6 | 71 | 133 | 594 | 0.687 | 0.012 | 0.454 | 0.141 | 0.905 | rediwm 8.9% |
| `spinner_clear` | 11.88 | 236.9 | 194 | 138 | 473 | 0.791 | 0.017 | 0.524 | 0.164 | 0.959 | rediwm 11.9% |
| `spinner_glass` | 11.02 | 238.6 | 193 | 138 | 475 | 0.758 | 0.016 | 0.502 | 0.159 | 0.888 | rediwm 11.0% |
| `damage_full` | 15.90 | 256.7 | 690 | 138 | 474 | 0.747 | 0.016 | 0.493 | 0.159 | 0.912 | rediwm 15.9% |
| `drag` | 10.25 | 249.3 | 173 | 138 | 494 | 0.897 | 0.039 | 0.575 | 0.188 | 0.976 | rediwm 10.2% |
| `resize` | 22.45 | 650.5 | 342 | 138 | 454 | 1.128 | 0.130 | 0.716 | 0.204 | 1.284 | rediwm 22.4% |
| `fullscreen` | 35.18 | 159.6 | 152 | 143 | 459 | 0.617 | 0.020 | 0.351 | 0.163 | 0.766 | rediwm 35.2% |
| `zoom_85` | 12.79 | 235.4 | 193 | 143 | 470 | 0.914 | 0.020 | 0.603 | 0.188 | 0.971 | rediwm 12.8% |
| `zoom_70` | 11.63 | 236.1 | 193 | 143 | 470 | 0.945 | 0.019 | 0.624 | 0.201 | 0.974 | rediwm 11.6% |
| `zoom_55` | 13.14 | 225.7 | 191 | 143 | 474 | 0.695 | 0.016 | 0.463 | 0.138 | 0.894 | rediwm 13.1% |
| `zoom_min_hold` | 12.63 | 230.5 | 192 | 143 | 476 | 0.673 | 0.013 | 0.445 | 0.137 | 0.771 | rediwm 12.6% |

#### Mixed scales (1 and 1.5), `REDIWM_NO_GLASS=1`

| Scenario | CPU % | Minstr/s | wakeups/s | RSS MiB | commits | cpu_frame | projection | glass | scene commit | gpu | top thread |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| `idle` | 0.01 | 0.0 | 1 | 131 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | rediwm 0.0% |
| `spinner_clear` | 4.66 | 37.1 | 252 | 136 | 246 | 0.184 | 0.017 | 0.000 | 0.068 | 0.055 | rediwm 4.7% |
| `spinner_glass` | 5.84 | 38.9 | 248 | 136 | 245 | 0.210 | 0.018 | 0.000 | 0.086 | 0.072 | rediwm 5.8% |
| `damage_full` | 9.53 | 63.4 | 748 | 136 | 246 | 0.172 | 0.014 | 0.000 | 0.079 | 0.081 | rediwm 9.5% |
| `drag` | 3.65 | 59.2 | 209 | 136 | 496 | 0.208 | 0.033 | 0.000 | 0.097 | 0.124 | rediwm 3.6% |
| `resize` | 16.89 | 459.9 | 358 | 136 | 480 | 0.378 | 0.131 | 0.000 | 0.180 | 0.222 | rediwm 16.9% |
| `fullscreen` | 43.90 | 57.9 | 121 | 140 | 464 | 0.210 | 0.016 | 0.000 | 0.126 | 0.255 | rediwm 43.9% |
| `zoom_85` | 5.06 | 39.8 | 250 | 140 | 260 | 0.126 | 0.010 | 0.000 | 0.052 | 0.035 | rediwm 5.1% |
| `zoom_70` | 5.50 | 41.8 | 250 | 141 | 247 | 0.143 | 0.012 | 0.000 | 0.059 | 0.042 | rediwm 5.5% |
| `zoom_55` | 5.18 | 42.2 | 249 | 141 | 245 | 0.208 | 0.018 | 0.000 | 0.085 | 0.080 | rediwm 5.2% |
| `zoom_min_hold` | 6.46 | 40.6 | 252 | 141 | 256 | 0.139 | 0.011 | 0.000 | 0.054 | 0.038 | rediwm 6.5% |

### Run-to-run noise

The same binary, twice in a row on the same session of the machine (scenario-level, clean and stats sessions together). Treat differences below the *90th percentile* as noise.

| Metric | median |Δ| | p90 |Δ| | max |Δ| | n |
|---|--:|--:|--:|--:|
| CPU % | 7.0% | 21.1% | 30.7% | 41 |
| instructions/s | 0.4% | 2.8% | 189.0% | 44 |
| wakeups/s | 0.7% | 14.2% | 66.7% | 44 |
| RSS | 0.2% | 0.9% | 11.7% | 44 |
| cpu_frame ms | 9.3% | 26.3% | 34.1% | 41 |
| projection ms | 14.7% | 29.9% | 41.0% | 41 |
| glass ms | 9.8% | 26.5% | 31.5% | 27 |
| scene commit ms | 9.7% | 24.9% | 33.7% | 41 |
| gpu ms | 10.2% | 29.1% | 54.1% | 41 |

## Findings

1. **No meaningful regression since `190cb65` (2026-09-23).** Interleaved
   ref/head/head/ref on AC power, each binary driven by its own commit's
   harness (the IPC envelope changed in between, and the desktop has since
   moved into the compositor, so desktop workloads compare reference
   compositor + `rediwm-desktop` CPU against HEAD compositor CPU). HEAD against
   the reference: empty-commit frames -32 % (HEAD skips redundant commits: 6-7
   commits in 4 s against 247), full damage -10 %, start-button hover -18 %,
   tray hover CPU -33 %, idle 0.00 % in both. Two rows are worse and
   consistent across rounds: **window drag** +73 % CPU and +76 % frame cost
   (finding 3), **menu open/scroll** +17 % frame cost (`scene_commit_cpu`
   0.18 → 0.32 ms, `glass_cpu` 0.33 → 0.50 ms; not investigated) and
   **desktop pan** +26 % CPU / +48 % frame cost, which is `scene_commit_cpu`
   0.19 → 0.28 ms with glass flat: the desktop canvas is now drawn by the
   compositor's own pass instead of a separate client, so it is not a
   like-for-like row. The
   compositor binary grew from 17.8 to 26.8 MB.
2. **Two outputs at different scales never go idle while glass is on.** With
   no windows at all, outputs at scales 1 and 1.5 (or 1 and 2) commit about
   118 frames/s forever: 7-9 % CPU (two runs: 6.9 and 8.9 %), ~216 M
   instructions/s, 70 wakeups/s, glass re-blurring every frame. Two outputs at the *same* scale are idle, and
   `REDIWM_NO_GLASS=1` takes the mixed case to 0 commits and 0.00 % CPU
   (`mixed_noglass`). It reproduces on `190cb65`, so it is not a regression.
   No panel, taskbar or animation counter moves; the likely mechanism is
   `glass.c` updating shared effect nodes once per output with that output's
   scale, so each output's update damages the other (not yet confirmed). It
   violates "idle makes no wakeups" for anyone with mixed-scale monitors. The
   mechanism is confirmed: the effect's output buffer is `width × scale` and
   its hash includes `scale`, but `rediwm_glass_update` passed the scale of
   whichever output was updating, so each output re-rendered the shared effect
   at its own scale and damaged the other. **Fixed** in
   `glass.c`: `effect_scale` takes the highest scale among the outputs the
   effect's target overlaps, independent of the caller. All five output
   scale pairs tried (1/1, 1.5/1.5, 1/1.5, 1/2, 1.5/1) now idle at 0 commits;
   single-scale screenshots are unchanged. `glass_hold.py` gained a mixed-scale
   idle case (180 commits in 1.5 s without the fix, 0 with). The mixed rows
   below are the unfixed baseline; `mixed_noglass` is the reference without
   the loop. Same harness, unfixed → fixed (`glass-scale-fix.json`):

   | Mixed scales | CPU % | Minstr/s | commits |
   |---|--:|--:|--:|
   | `idle` | 8.91 → 0.00 | 215.6 → 0.0 | 594 → 0 |
   | `spinner_clear` | 11.88 → 5.93 | 236.9 → 48.4 | 473 → 247 |
   | `drag` | 10.25 → 5.16 | 249.3 → 81.3 | 494 → 491 |
   | `resize` | 22.45 → 17.68 | 650.5 → 550.1 | 454 → 465 |
   | `zoom_70` | 11.63 → 6.76 | 236.1 → 78.0 | 470 → 246 |

   Scale 1.5 on the same two builds: instructions/s within 2 % on all eleven
   scenarios (e.g. `spinner_glass` 71.1 → 71.2, `resize` 489.6 → 487.7), so the
   fix costs nothing where it does not apply.
3. **The default theme no longer holds glass during a drag.** Default
   `window_bg` alpha went from 0.98 to 0.80 (`ui/theme.zig`), the hold needs
   at least 0.98 (`chrome.titlebarGlassMayHold`, unchanged), so a drag now
   re-blurs the titlebar every frame: against `190cb65` (AC A/B) `glass_cpu`
   0.006 → 0.231 ms and `gpu_elapsed` 0.29 → 0.52 ms per drag frame. `tests/glass_hold.py` fails on its first (`default`)
   case for the same reason: the test still expects the default to hold.
4. **One re-blurred glass effect costs about 0.17 ms CPU and 0.2 ms GPU per
   frame** (`spinner_glass` against `spinner_clear`, scale 1.5, AC, two runs:
   `glass_cpu` 0.184-0.201 vs 0.017-0.020, `gpu_elapsed` +0.17-0.23 ms,
   instructions 71 vs 40 M/s, CPU 5.2-6.9 % vs 4.1-4.2 %). Resize is the heaviest compositor-side load (14-16 %
   CPU, 313-490 M instr/s) and glass is half of its frame time (0.5-0.6 of
   1.0-1.2 ms). This is the cost stage 5 targets; the earlier ~0.35 ms figure
   in the plan was measured at lower clocks.
5. **A fullscreen 60 fps client costs 33-40 % of a core**, all on the main
   thread, with only 0.35-0.40 ms in the frame stages and about 1 M
   instructions per frame (stalled or kernel time, not compute), and +6 to
   +27 MiB RSS. Same with glass off. It sits outside the frame timers and
   outside this plan; the cause is unprofiled (likely the shm upload in the
   commit handler), but it dominates that row, so judge `fullscreen` by
   instructions and the stages, not CPU %.
6. **Direct scanout has never engaged in the retained live logs, and per-surface
   dmabuf feedback is never sent** (rows 9 and 10 above). The stage 3 exit
   criterion "scanout where it applied" may be vacuous; confirm on hardware.
7. **Gate on instructions and RSS; treat timers with care.** Two identical runs
   differ by a median 0.4 % (p90 2.8 %) in instructions/s and 0.2 % (p90
   0.9 %) in RSS, but ~10 % (p90 25-30 %) in every frame-stage timer and 7 %
   (p90 21 %) in CPU %. Only compare timers across a margin above ~30 % or
   over repeated runs.
8. **Power state invalidated a first attempt.** On battery the same work ran
   about twice as slow (`scene_commit_cpu` 0.19 vs 0.098 ms for the same
   spinner; effective clock 0.7 vs 1.1 GHz). The harness now refuses to start
   off AC power and records the power state of every session; `--allow-battery`
   overrides. The first A/B and trial runs of this stage were repeated on AC.
9. **Goldens are deterministic on this machine.** 16 screenshots (4 per
   output: `windows`, `fullscreen`, `zoom70`, `zoom_min`) were identical, to the
   level, between two runs, so `--compare` can use a tolerance of 0-2 levels
   locally. Other GPUs or Mesa versions will differ (GLES2 at a fractional
   scale can move one level with render history).
10. **The layout autosave can move a window back within 37 s of start.**
    `session/layout_autosave.zig` writes the layout every 10 s and restores
    from that same file at about 2, 7, 17 and 37 s after start. A window moved,
    resized or made fullscreen shortly before a restore tick is put back at its
    previous saved position; a fullscreen window kept its fullscreen size but
    was moved to its old origin (seen: `client_box` jumped from (0,0) to
    (700,40) while `fullscreen` stayed true). Not investigated further; the
    harness avoids it by giving the compositor an uncreatable state directory.

## What `wlr_scene_output` does today

References are to wlroots 0.20.2 `types/scene/wlr_scene.c` (`W:`) and
`types/scene/surface.c` (`S:`); RediWM files are in `src/`. RediWM does not
render its source tree: `projection.c` mirrors it into a second tree of plain
`wlr_scene_buffer`/`wlr_scene_rect` nodes (the view) and routes each surface's
`outputs_update`, `output_sample` and `frame_done` listeners onto the view
node, so every item below is evaluated on the *presented* geometry. That table
is the checklist for stage 3: an owned pass must either reproduce a row or
record a conscious drop.

| # | Behaviour (wlroots) | How RediWM gets it today | Stage 3 check |
|---|---|---|---|
| 1 | **Output lifecycle.** Create attaches commit/damage/needs-frame listeners and a damage ring (W:1766); a commit that changes mode, enabled, transform, scale or subpixel damages the whole output and re-evaluates every buffer node's outputs (W:1700); destroy leaves all nodes (W:1832); position follows the output layout (W:1884). | `Output.zig` `createSceneOutput` + `scene_output_layout.addOutput`; `scene_output.destroy()` runs first in the output teardown, before any scene mutation. | `output_destroy`, `display_arrangement`, `output_scale`, hotplug and mode-change cases of the suites below. |
| 2 | **Damage.** Node moves, resizes, buffer changes and visibility changes damage every output they touch (W:397); `wlr_damage_ring` rotated by swapchain buffer age gives the region to repaint (W:2535); `pending_commit_damage` is what the backend has not acknowledged (W:1709); scale, transform or gamma-transform changes damage everything (W:2357-2371, 2338). `needs_frame` = output latch, pending damage or gamma change (W:2183). | `Output.runFrame` asks `scene_output.needsFrame()`; `commitIsRedundant` reads `scene_output.private.pending_commit_damage` and `gamma_lut_changed` directly, so skipped commits depend on private wlroots fields. | `desktop_damage`, `panel_damage`, `glass_hold`, `zig build test-projection`; buffer-age correctness under an effect (stage 1 gate). |
| 3 | **Visibility and culling.** Every node keeps a `visible` region (opaque regions above subtract, W:650/722); nodes with an empty region are skipped in the render list and in frame-done (W:1961, 1122); a black rect, and at integer scale an opaque black single-pixel buffer, is not drawn because the background is black (W:1941-1959); the black clear covers only damage not under an opaque node, grown by 1 px at fractional scale (W:2538-2579); opaque nodes blend with `NONE` (W:1549). | Projection sets each view node's opaque region from `buffer_is_opaque`; partial client opaque regions are conservatively empty (`projection.c`, `next.opaque`). | Occlusion cases in `popup_constraint`, `layer_lifecycle`, `lock_screen`; CPU/GPU cost against baseline. |
| 4 | **Per-node draw.** Paint order = tree order; clip = visible ∩ damage in buffer coordinates, rounded outward at fractional scale; destination box by `round(len·s)` vs `round((off+len)·s)−round(off·s)`; buffer/output transform composition; `src_box`; bilinear/nearest by node mode; alpha = node opacity; premultiplied blend; single-pixel buffers drawn as rects (W:1451-1582). A node whose texture cannot be created re-damages itself (W:1520). | Same code, fed by view nodes; projection picks bilinear whenever zoom ≠ 1. | `screenshot_regressions`, `edge_sampling` (until deleted), mixed-scale and zoom suites, pixel diff against the stage 0 goldens. |
| 5 | **Explicit sync.** Each buffer carries `wait_timeline/point`, waited on GPU-side with an EGL wait-sync before sampling (GLES2 `pass.c:206`). Release points are `scene_output.in_timeline/in_point`, signalled from an EGL fence imported as a sync file (`pass.c:42`; otherwise `glFlush`); only created with a DRM backend and renderer timeline support (W:1794). | Projection copies the wait point to the view (`projection.c`, `.wait_timeline`); `explicit_sync.c` adds `ReadFence` and `AcquireWait` for other GPU or CPU reads. | `explicit_sync` (a real vkcube client on headless GLES2; skips without vkcube or a GPU); release points on a DRM backend are manual. |
| 6 | **Frame callbacks.** `send_frame_done` walks enabled nodes; a buffer node emits `frame_done` only when its visible region is non-empty (W:1120, 2664); the surface handler delivers `wl_surface.frame` only for the surface's pacing output: the entered, non-suspended output with the highest refresh (S:182). | `Output.zig` calls `scene_output.sendFrameDone` after each commit and, for skipped commits, from `vblank_timer` (`deferFrameDone`). | Frame-callback pacing in `perf`/`idle`, `desktop_damage`, `presentation_time`. |
| 7 | **Enter/leave and preferred scale.** Per buffer node: output overlap > 10 % of its visible area makes the output active, the largest overlap is the primary output (W:416-536); the `outputs_update` handler sends `wl_surface.enter/leave`, with *no* leave when a node becomes fully hidden (suspended), the fractional preferred scale = largest entered-output scale, `preferred_buffer_scale = ceil` and the colour-manager preferred description (S:93-156). | Routed onto view nodes, so enter/leave follows the zoomed, on-screen footprint. Preferred scale ignores camera zoom (see the client-density note in memory). | `output_scale`, `wlr_protocols`, `xwayland_fractional`, mixed-scale and zoom suites. |
| 8 | **Presentation feedback.** `output_sample` marks the surface `textured` (or `scanned_out`) on its pacing output; `wlr_presentation` sends the feedback from the output's present event (S:158). | `Server.zig` creates `wlr.Presentation`; the sample event comes from view nodes. | `presentation_time`. |
| 9 | **dmabuf feedback and preferred transform.** Scanout/composition tranches per surface (W:1988), only when `wlr_scene_set_linux_dmabuf_v1` was called and the node is a surface. | **Not provided today.** RediWM never calls `wlr_scene_set_linux_dmabuf_v1`, and view nodes carry no surface addon: clients only see the default (main-device) feedback. | None to reproduce. Decide whether to keep it dropped or add tranches with scanout. |
| 10 | **Direct scanout.** Tried only when the render list has exactly one entry (after culling), no colour transform, no pending modeset, scanout allowed on the output, the buffer's transform and colour description match, and `wlr_output_test_state` accepts it; release through the out-timeline; hardware cursor stays on its plane (W:2061-2181, 2446). | Available in principle for an opaque fullscreen client with everything else culled; `tearingAllowed`/`commitFrameState` sit beside it. **Never logged in the two retained live logs** (`session.log`, `session.previous.log`: 28 k wlroots debug lines, no "Direct scan-out" line), and headless cannot exercise it. | Manual on hardware with a fullscreen opaque client (`WLR_DEBUG` "Direct scan-out enabled"). The stage 3 exit criterion "scanout where it applied" may be vacuous: confirm on hardware before relying on it. |
| 11 | **Software cursors** are drawn into the same pass, limited to damage (W:2619). | `CursorState`/`committed_cursor` decide whether a skipped commit is safe. | Cursor suites (`client_cursor`, `cursor_shape`), `commitIsRedundant` cases. |
| 12 | **Colour.** An output colour transform (gamma LUT, image description) is only rendered when the renderer has `output_color_transform`; GLES2 and pixman do not (`renderer.c:529`), so wlroots tries a KMS gamma state instead (W:2212, 2506). | RediWM never sets the scene's gamma-control manager; night light rides `Output.color` in `commitFrameState`. The colour-management protocol is wired (`extra_protocols.c`) but with GLES2 (`input_color_transform = false`) advertises no transfer functions or primaries, so only default sRGB/gamma 2.2 buffers exist. | Night-light and colour suites; nothing to reproduce in an owned GLES2 shader. |
| 13 | **State build outside the frame path.** `build_state` consumes a swapchain buffer, rotates the damage ring and, with a timer, brackets the pass (W:2313). | Screenshots (`screenshot/capture.zig`) and IPC `sample_pixels` call it directly on the live scene output. | `capture`, `screencast`, `screenshot_regressions`: the buffer-age contract must survive a capture between two frames. |
| 14 | **Hit testing** is `wlr_scene_node_at` with per-buffer `point_accepts_input`. | View nodes install `accepts`, which maps back to the source node. | `hotspots`, `popup_constraint`, input suites; shape-aware hit tests are new in stage 4. |
| 15 | **Xwayland stacking.** The scene restacks X11 surfaces unless told not to (W:560-605). | `scene.restack_xwayland_surfaces = false`; `Toplevel.raise` owns the order. | `xwayland` suite. |

## What wlroots GLES2 draws

Everything the owned shader must reproduce or consciously drop, from
`render/gles2` in 0.20.2. The whole shader set is five files totalling 111
lines.

| Item | Today | Owned pass |
|---|---|---|
| Programs | `quad` (uniform premultiplied colour), `tex_rgba` (`texture2D · alpha`), `tex_rgbx` (rgb, alpha forced to 1), `tex_external` (`samplerExternalOES · alpha`). | Reproduce all four; pick by `texture->target` and `has_alpha` exactly as `pass.c:175`. |
| External-OES | Used for dmabufs only importable that way (extension `GL_OES_EGL_image_external` required); also the path for driver-converted YUV. | Needed: shader variant plus `gles2_get_texture` attribs (`wlr_gles2_texture_get_attribs`). |
| Blending | `glBlendFunc(ONE, ONE_MINUS_SRC_ALPHA)` set once per pass; blending disabled when the node is opaque or (`!has_alpha && alpha == 1`). | Same; premultiplied everywhere (AGENTS.md: colours are premultiplied). |
| Clipping | `render()` scissors each rectangle of the clip region; the pass starts with scissor off. | Replaced by the SDF clip plus damage scissor. |
| Filtering | `glTexParameteri(MIN/MAG)` on the *shared* texture each draw. | Mutates state `glass.c` also reads: set it explicitly per draw or use sampler state. |
| Texture transform | `tex_proj` matrix from buffer transform composed with the output transform and normalised `src_box`. | Reproduce (rotation, flips, viewport crops). |
| Colour | `transfer_function`, `primaries`, `color_encoding`, `color_range`, `luminance_multiplier` and the pass `color_transform` are accepted and **ignored**; the shader samples RGB as stored. Nothing is advertised to clients on GLES2. | Nothing to match. If Vulkan ever becomes a target this is where parity would start. |
| Sync | Acquire: `eglWaitSync` per texture; release: EGL fence → sync file → timeline, else `glFlush` at submit; context saved and restored around the pass. | Reproduce, including the single `glFlush` per pass that `glass.c` currently repeats per effect. |
| Timing | `EXT_disjoint_timer_query` timer inside the pass. | RediWM uses its own `gpu_timing.c` around the frame; keep. |
| Formats | `has_alpha` from the DRM format; swapchain format chosen by `wlr_output_configure_primary_swapchain`. | Unchanged. |
| Not present | SDF clip, analytic borders and shadows, backdrop sampling. | New in the plan (stages 1, 4, 5). |

Reading: the shader itself is trivial and colour is already a no-op on
GLES2, so parity risk sits in the state machinery around it (context save and
restore, scissor and damage, sync, texture target selection), not in colour.

## Policy and renderer decisions

The plan asks stage 0 to confirm these. Each has a recommendation and the
evidence found; the last column is what is still open.

| Decision | Recommendation | Evidence | Open |
|---|---|---|---|
| **Renderer policy** | Require GLES2 for the session; no pixman path. | Glass is already GLES2-only (`glass.c`); masked draws need it. `Renderer.autocreate` only lands on pixman when GLES2 init fails. Tests default to pixman (53 scripts read `REDIWM_TEST_RENDERER`) but only 4 use `DumpBuffer`, so flipping the default is mostly a default change plus those 4. A machine without a GPU would need Mesa llvmpipe via `WLR_RENDERER_ALLOW_SOFTWARE`. | **Decided 2026-10-09: require GLES2.** |
| **Corner radius** | `Toplevel.cornerRadius`: `frameRadius × chromeDensity`, 0 when maximized or fullscreen. | Confirmed in code (`Toplevel.zig:1278`). | Confirmed. |
| **Client-side-decorated windows** | Not clipped unless a rule asks. | A CSD client draws its own corners (and shadow) in its alpha; clipping them again with a different radius would shave or double them. Server-decorated native, Xwayland and `.shell` windows are clipped. | **Decided 2026-10-09: unclipped by default; a rule opts in.** |
| **Footer reservation** | Drop `max(border, ceil(radius))` to the border width. | Needs the audit the plan lists (snap, resize edges, layout, saved layouts, Xwayland, tabs, tests pinning titlebar/body heights). | Audit at stage 4. |
| **Colour management** | Nothing to reproduce; drop. | GLES2 ignores transfer function, primaries, range, encoding and luminance, cannot apply output transforms, and the colour manager advertises no transfer functions or primaries (`input_color_transform` is false). | Decided by evidence. |
| **dmabuf feedback** | Keep dropped for now. | Never sent today (row 9). | Revisit with scanout. |
| **Direct scanout** | Verify on hardware before stage 3's exit criterion. | Never logged in the retained live logs; headless cannot test it. | A fullscreen opaque client on a real session. |
| **Mixed-scale idle loop** | Fix in `glass.c` independently, now. | Finding 2: a pre-existing idle regression with a small likely cause. | **Decided 2026-10-09 and done** (finding 2). |
| **`glass_hold.py`** | The default theme follows the backdrop; keep the 0.98 case as the hold. | Finding 3. | Done: the default case now expects a follow. |
