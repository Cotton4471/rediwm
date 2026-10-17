# CPU usage reduction plan

Status: draft, 2026-10-17. Implement four increments in the order below,
measuring each separately. Reduce unnecessary main-thread work during static
desktop use, capture and active rendering while preserving responsiveness.

## Baseline

Record ReleaseSafe runs for an empty desktop, static windows, a client that
requests frame callbacks without changing content, animation/drag/resize, and
static/animated capture. Include one output and mixed-scale multiple outputs.
Keep hardware, power settings, renderer and workloads identical.

Measure per-thread CPU time and context switches without performance IPC;
use a separate instrumented run for frame-stage and GPU timing. Follow
[`TESTING.md`](../../TESTING.md) and extend the existing performance fixtures.

## 1. Schedule only affected outputs

In [`src/projection.c`](../../src/projection.c), replace the per-commit scan of
surface feedback with a maintained direct lookup. Track which outputs need
work for known surfaces, including both old and new bounds when they move.
Keep conservative scheduling for unknown/new surfaces and global changes.
Distinguish visual damage from requests that only need frame callbacks.

**Acceptance:** activity on one output does not repeatedly process unrelated
outputs. New popups, moves across outputs, output changes and captured/hidden
surfaces still receive the work they require.

## 2. Add a lightweight path for callback-only commits

In [`src/output/frame.zig`](../../src/output/frame.zig) and the surface binding,
track why a frame was requested. When only callbacks are pending and scene
state is already resolved, bypass unnecessary shell ticks, window walks and
render preparation. Route damage, animations, layout changes, cursor/output
state and capture requests through the appropriate full path.

Preserve paced frame callbacks; do not reply immediately in a loop or delay
the next real visual update. Add a fixture that alternates empty commits with
real damage so the optimization cannot strand a client.

**Acceptance:** callback-only workloads cost less CPU without extra output
commits, animation stalls or increased presentation latency.

## 3. Reuse unchanged capture content

Follow Phase 3 of the [capture lifecycle plan](capture-lifecycle.md), after its
source ownership and cancellation milestones. Observe source changes before
visibility culling, render when requested content is stale, and reuse valid
snapshots. Preserve separate source, swapchain-buffer and consumer damage
histories, constraints, cursor modes and explicit synchronization.

**Acceptance:** static capture produces no repeated source rendering; changed
content reaches waiting consumers, including fully occluded windows. The last
consumer leaving removes capture-generated work and timers.

## 4. Reduce renderer and resource overhead

Profile EGL context transitions, GL state queries, texture uploads/imports and
readback around [`src/scene_pass.c`](../../src/scene_pass.c). Implement scoped
batching and resource reuse where the measurements show avoidable work.

If the wlroots renderer boundary remains a significant cost, prototype an
owned renderer/resource implementation behind its existing interface, keeping
wlroots' display backends and input machinery. Expand ownership only where an
A/B comparison justifies it. GL state restoration remains required wherever
wlroots still draws; preserve buffer release and acquire/release fences.

**Acceptance:** repeatable CPU improvement during active rendering, with
correct SHM/DMA-BUF imports, external textures, capture, cursors and GPU sync.
Record the result even if profiling rules out a larger renderer replacement.

## Validation and delivery

Land each increment separately with its before/after measurements. Extend
existing tests where practical. For implementation, build Debug and
ReleaseSafe, run `zig build test`, and run affected performance, multi-output,
capture, screenshot and scene-pass suites. Use damage-audit checks for changes
to damage or output scheduling; compare existing failures with a HEAD worktree.

Check pixels, callback pacing, input responsiveness, frame latency and idle
wakeups alongside CPU usage. Record hardware-dependent gaps separately. Mark
each increment complete only when its behavior checks pass and its measured
result is documented.
