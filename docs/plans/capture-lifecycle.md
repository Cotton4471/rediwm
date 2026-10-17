# Capture sources and session lifecycle plan

Status: draft, 2026-10-17. Implementation has not started. Begin with Phase 0;
Phases 1 and 2 deliver graceful source cancellation, then Phase 3 reduces
unnecessary capture work.

Own the lifetime of native window and output capture sources so stopping one
source ends its streams without disconnecting the client or interrupting its
other streams. Preserve the standard capture protocols, content isolation and
lock/authentication policy. Extend the existing owned window renderer and add
an owned output source manager; keep wlroots' image-copy session machinery
until a demonstrated requirement needs a narrower replacement.

The main acceptance case is one client capturing two different sources:
stopping one produces `stopped`, an outstanding frame terminates, the client
connection remains usable, and the other stream continues delivering pixels.

## Current integration

The assessment uses the wlroots 0.20.2 release pinned by
[`scripts/build-wlroots.sh`](../../scripts/build-wlroots.sh).

| Existing code | Relevant behavior |
| --- | --- |
| [`src/capture/manager.zig`](../../src/capture/manager.zig) | Owns policy, session tracking and the capture indicator's count. Stop all, output loss and window minimize currently disconnect capture clients. |
| [`src/capture/window_source.zig`](../../src/capture/window_source.zig) | Owns a source per request and renders the selected content subtree into a swapchain. Source destruction already produces graceful session termination through `base.finish()`. Creation renders immediately; later requests always render and report full damage. |
| [`src/toplevel/lifecycle.zig`](../../src/toplevel/lifecycle.zig) | Retires foreign handles on unmap, but explicitly documents the gap where an unmapped window remains alive and its capture source survives. |
| [`src/toplevel/chrome_actions.zig`](../../src/toplevel/chrome_actions.zig) | Explicitly stops capture on minimize because hiding the frame does not destroy the content tree. |
| [`src/Output.zig`](../../src/Output.zig) | Stops monitor capture on idle blank and output destruction. Other disable/power paths need the same lifecycle contract. |
| [`src/session/lock.zig`](../../src/session/lock.zig) and [`src/polkit/dialog.zig`](../../src/polkit/dialog.zig) | Lock and authentication entry points. Polkit calls Stop all; lock entry needs an explicit capture revocation audit, including existing sessions. |
| [`tests/capture.py`](../../tests/capture.py), [`tests/capture_client.c`](../../tests/capture_client.c), [`tests/screencast.py`](../../tests/screencast.py) | Existing pixel, source-loss, indicator and picker coverage. Several tests currently expect a disconnected client. |

wlroots exposes source initialization, resource creation and `finish` through
its [source implementation interface](https://wlroots.pages.freedesktop.org/wlroots/wlr/interfaces/wlr_ext_image_capture_source_v1.h.html).
In the pinned source, finishing a source ends its sessions, fails pending
frames and makes remaining source resources inert. There is no public general
session-stop operation in the pinned
[`wlr_ext_image_copy_capture_v1.h`](https://gitlab.freedesktop.org/wlroots/wlroots/-/blob/0.20.2/include/wlr/types/wlr_ext_image_copy_capture_v1.h).
Use that supported source boundary first.

## Scope and behavior

The first release covers `ext-image-copy-capture-v1` over output sources and
native xdg window sources. A source resource can create multiple sessions:
source cancellation ends all of those sessions. Stopping a target cancels
every owned source for that window or output. Selecting one session while
another session on the same source continues is a separate, conditional step.

| Trigger | Required result |
| --- | --- |
| Window close, unmap or minimize | Stop all sources for that window gracefully; preserve other windows, outputs and the client's unrelated Wayland resources. |
| Output unplug, successful disable, power off or idle blank | Stop sources for that output before its backing objects disappear. A rejected disable must not leave a permanently stopped source solely because an attempted transition failed. |
| Stop sharing from the taskbar or IPC | Stop every active modern source. Clear active-session accounting through the normal teardown path. |
| Built-in lock, client session lock or authentication | Revoke capture before further source reads/delivery, including existing sessions and sources created without a session yet. Reject new capture while policy denies it. |
| Window resize or output format/geometry change | Publish fresh constraints before a frame using them; invalidate old cache contents and validate client buffers against the current constraints. |
| Occlusion or camera movement | Preserve isolated window content; unrelated windows and desktop pixels never enter its frames. |
| Restore, remap, wake or unlock | Old stopped resources remain inert. A fresh allowed source/session request can recover. |
| Client/session/source-resource destruction | Release only the affected references and work. Destroying a factory global or a source descriptor must not prematurely free objects still needed by live sessions. |

Keep the existing native-window content boundary: client content and its
current subtree semantics, transparent shaped corners, and no server chrome,
shadows or backdrop glass. Keep the existing logical-resolution window raster
initially. Higher-density capture, broader popup bounds, X11 window capture,
new picker UI and a new portal backend are separate work.

Legacy `wlr-screencopy-v1` has frame objects rather than these sessions. Retain
`guardScreencopy` and the existing fail-closed disconnect fallback where its
API requires it. The new guarantee of preserving unrelated streams initially
applies to modern capture; a legacy fallback can still disconnect a mixed
connection. Replacing the legacy implementation is outside this first release.

## Ownership and lifetime

Introduce a shared owned-source record with a target identity, generation,
state (`active`, `revoked`, `finished`), pending-work handle, session/resource
references and a stop reason. Windows use stable window IDs; outputs use an
owned registration identity/generation with a destroy listener. Reusing a
pointer or an output name must never revive an earlier source.

Create one owned source per source request. Keep cancellation identities
separate even if a later optimization shares immutable rendered content for
the same target. Replace `session.source.toOutput()` with lookup in the owned
source registry: wlroots' helper recognizes only its own output sources.

The stop path is idempotent and performs no allocation:

1. Mark the source revoked and invalidate its generation synchronously.
2. Cancel queued render/copy work and block new reads or frame delivery.
3. Finish the source once, allowing wlroots to terminate its sessions and
   frames and leave wire resources inert.
4. Detach listeners, release buffers/locks and free the owner when callbacks
   and remaining work can no longer access it.

Finishing emits callbacks that can remove session records immediately. Use
mutation-safe iteration and never retain a session pointer across that call.
Do not free a source while its own `request_frame`/`copy_frame` callback or a
wlroots dispatcher is still using it. Defer final destruction when necessary,
but finish dependent objects and release output locks while the output is
still valid. A queued completion must check its source generation.

Track resource destruction, active sessions and pending work independently.
Reclaim sources requested but never used, failed accepts and abandoned cached
buffers. Ending the last session stops active work; do not rely on a window
eventually closing to release per-request allocations.

Admission checks belong before source-content rendering, in session start,
and at render/copy delivery. `new_session` alone is too late: the pinned
wlroots implementation calls the source's `start` before emitting that event.
Prepare valid buffer constraints before accepting a source, without reading
window pixels merely to create the descriptor.

## Implementation phases

### Phase 0: establish the protocol and lifetime baseline

Extend `tests/capture_client.c` to hold named sources and sessions concurrently
on one Wayland connection. Add commands for creating/destroying descriptors,
sessions and frames independently, selecting an output, waiting for events,
and checking connection liveness with `wl_display.sync`. Preserve existing
fixture commands so current tests remain useful.

Verify the pinned contracts for source finish, outstanding frames, descriptor
destruction with a live session, duplicate stop, constraints, cursor options
and disconnect during delivery. Check how to observe resource destruction
through public libwayland callbacks, and how source start/stop callbacks pair
when multiple sessions share a source.

Record the current capture suites and the disconnect expectations before
changing behavior. Use a HEAD worktree to classify existing failures, and
account separately for unrelated working-tree changes. Establish a baseline
for static capture, animated content, two consumers and compositor idle cost.

Exit gate: the fixture can prove that stopping one stream did not kill its
connection or accidentally stop another, and the supported lifetime boundary
is understood without editing private wlroots session lists.

### Phase 1: graceful window source cancellation

Add the shared lifetime/state helpers and a manager-owned stop path. Route
minimize, close and unmap through source cancellation, including unmap without
destruction. Remove the modern window path's client-disconnect fallback.

Separate constraint preparation from rendering. Guard source creation,
activation and frame delivery; reject unavailable targets without leaving a
registered source or scheduling a render. Clean up allocation/accept failures
and unused source requests.

Wire lock and authentication revocation explicitly. Preserve `Lock.announce`
as the first lock action; establish the capture-denied state and revoke
sources before lock/authentication content can be sampled. Include client
session-lock entry. Keep greeter capture globals unavailable. Until output
sources are migrated, retain their existing fallback during global stops.

Exit gate: minimizing/unmapping one captured window produces `stopped` while
another stream and ordinary client requests remain usable. Restore/remap
requires a new source. Repeated stop and target destruction during a pending
frame are clean under Debug allocation checks.

### Phase 2: own output capture sources

Add `src/capture/output_source.zig` and a small owned factory for
`ext_output_image_capture_source_manager_v1`. A C bridge is acceptable where
the pinned Zig bindings lack the public resource helper; keep it under
`src/capture/` and generate the required protocol bindings in `build.zig`.
Advertise exactly one output-source manager.

Adapt the pinned output-source logic with retained attribution. Use
`wlr_ext_image_capture_source_v1_create_resource` so wlroots' retained
image-copy manager recognizes the resource implementation. Map sessions to
owned sources explicitly; leave the foreign-toplevel list and compatible
foreign-toplevel source factory in use.

Preserve output buffer constraints, SHM/DMA-BUF copying, damage, timestamps,
transforms, pointer-cursor sources and attach-render lock accounting. Pair
every render/software-cursor lock across start, stop, failure and output loss.
Qualify concurrent sessions with different `paint_cursors` choices: pixel
variants must match each session's option, including cursor-only changes.
Sharing one raster must not silently bake the wrong cursor mode into a stream.

Use the existing output commit/render path. Any additional rendered output
state goes through `Server.buildOutputState`; real output commits remain on
`Output.commitFrameState`. Preserve explicit synchronization and buffer locks
through the copy. Revoke pending sources before their output dependencies are
destroyed, and audit successful disable/power transitions as well as unplug.

Update Stop all and the capture indicator to operate on the owned registry.
The existing IPC fields retain their meaning; report source kinds and target
identities without titles or pixels. Update legacy-disconnect wording in
touched comments and documentation to describe the remaining scope precisely.

Exit gate: on one client connection, an output stream can stop while a second
output or window stream continues; client-owned windows survive. Pending
frames terminate on blank/unplug, and a new source succeeds after wake.
Phases 1 and 2 are the first shippable milestone.

### Phase 3: render capture only when needed

Observe content changes before output-visibility culling. Screen damage alone
cannot describe an occluded window's changing content. Connect capture
invalidation to owned node/buffer changes, subtree structure and capture
geometry; detach observations before freeing nodes. Start with conservative
whole-source invalidation for uncertain structural changes.

Honor the source's `schedule_frame` contract. Produce the first frame promptly;
afterward a waiting capture may remain pending until content changes. Render
only when a consumer needs a frame and the cached content is stale. Reuse a
valid snapshot for a lagging consumer without repainting the source. Coalesce
bursts into bounded work and retain one pending frame per session as required
by the protocol; use event readiness and real deadlines, not a polling loop.

Keep three histories distinct: source content changes, each owned swapchain
buffer's paint history, and each consumer's buffer/session damage. Newly
allocated/resized buffers need a complete valid image. Merge client-reported
buffer damage correctly, never write a busy buffer, and preserve acquire/release
fences. Geometry, shape, format and cursor-mode changes invalidate the relevant
cached content.

Window capture remains rooted at `content_tree` with explicit shape handling.
For animated occluded windows, verify that frame callbacks still allow the
client to progress. Integrate any capture-induced callback scheduling with
`Server.sendFrameDone` so a displayed surface does not receive duplicates.

Exit gate: unchanged content causes no repeated window-render submissions;
unrelated desktop damage does not repaint an isolated window capture; a
content change wakes a pending consumer and produces correct pixels. No
capture-generated timers or render work remain after the final consumer ends.
Measure per-thread wakeups and CPU/GPU work against the Phase 0 baseline.

### Conditional follow-up: own individual session control

Source ownership is sufficient for the first milestone. Reconsider the
image-copy session manager only if a concrete requirement needs independent
cancellation of sessions sharing one source, or the Phase 0/2 cursor and
lifetime probes demonstrate a public-API gap that source ownership cannot
handle.

First check whether a small upstream API addition solves the gap. If a local
implementation is justified, port the pinned session code under a RediWM
namespace, preserve attribution, and retain protocol validation, cursor
sessions, constraints and frame failure semantics. Qualify it as a separate
change; do not make the whole project depend on replacing it preemptively.

## Validation and completion

Extend the existing fixtures and suites rather than add production test hooks.

| Coverage | Required cases |
| --- | --- |
| Cancellation isolation | Two outputs, two windows, and output plus window on one connection; multiple sessions sharing one source; unrelated client resources still usable after `stopped`. |
| Lifetime | Pending frame, duplicate stop, unused source, failed accept, session/source/global destruction in different orders, client disconnect, unmap/remap and output removal. |
| Policy | Stop all, built-in lock, client session lock, authentication, requests queued across revocation, inert old sources after recovery, legacy/mixed capture paths and greeter exclusion. |
| Pixels and synchronization | Existing SHM/DMA-BUF cases, premultiplied alpha, shaped corners, occlusion, camera movement, resize, transforms, mixed scales, cursor options and screenshot coexistence. |
| Damage and scheduling | Buffer rotation, lagging/slow consumers, first frame on an idle source, static source waiting without polling, content changes under full occlusion, invalidation during an in-flight copy and clean final-consumer shutdown. |
| Desktop integration | Correct IPC session counts, taskbar indicator and Stop sharing behavior; existing picker and portal configuration tests. |

Update the tests that currently expect disconnects to assert protocol events,
pending-frame completion and a working connection. Extend `tests/screencast.py`
as well as `tests/capture.py`; keep the pixel-isolation fixtures authoritative.
Use pure unit tests for state transitions and damage accounting where they
exercise behavior unavailable through the existing integration fixtures, and
import them into an actual Zig test root.

For implementation, complete Debug and ReleaseSafe builds, `zig build test`,
`python3 tests/capture.py` and `python3 tests/screencast.py`. Run the affected
lock/client-lock/authentication, output-lifecycle and screenshot suites from
[`TESTING.md`](../../TESTING.md). Changes to render/damage/sync integration also
require the relevant scene-pass and damage-audit checks. Compare failures with
HEAD before labeling them regressions.

GLES2/DMA-BUF and explicit-sync qualification need a compatible render node;
record unavailable hardware coverage separately. Browser/OBS sharing through
the actual portal is a manual acceptance gate, distinct from direct-protocol
tests. This work does not itself add native-window selection to a portal that
does not expose it.

Finish implementation by updating the capture area notes, the relevant
`TESTING.md` entries and stale capture-contract references in touched files.
Record which phases and hardware paths passed before changing this plan's
status to complete.
