# Notes for agents working on RediWM

Details that are easy to get wrong; read the section for what you touch.
Tests: `TESTING.md`. Area notes are in an `AGENTS.md` beside the code; read
the one for the directory you work in: `src/files`, `src/editor`,
`src/desktop`, `src/input`, `src/control_center`, `src/ui`, `src/session`,
`src/dm`, `src/accounts_helper`, `scripts`.

## Working rules

* Tool use is costly: no tight polling (wait 15–30 s between checks of long
  operations), batch checks, don't re-read unchanged files.
* Add tests only when really needed or asked; prefer extending existing ones.
* Before finishing: build Debug and `-Doptimize=ReleaseSafe`, run
  `zig build test` and the integration tests for what you touched. Some
  suites fail on HEAD: compare with a `git worktree` of HEAD before calling a
  failure a regression.

## Rendering and damage

* **Colours are premultiplied** in wlroots rects; theme colours are
  `col.Straight`. Create/recolour rects only via `col.createRect`/`setRect`,
  pack pixels with `Straight.argb()`/`Premul.argb()`. Symptom of a mix-up:
  white border edges.
* **Borders have two paths; change both:** `chrome.ChromeBuffer` draws curved
  corners, `Toplevel.syncBorders` straight `SceneRect`s inset by
  `ceil(frame_radius)`, with `side_fills` behind them. Chrome is a title band
  plus a footer skirt under the client (wlroots 0.20 can't mask clients):
  check `frame.band`, not `py`; `footerHeight()` keeps the skirt ≥
  `ceil(frame_radius)`.
* **Skirt colour** comes from `probeClientEdge` (median of the last buffer
  row; shm is premultiplied). Resample only on damage to that row or a
  mapping change; pointer reuse proves nothing. `readFormat` stays memoized
  per texture (it binds GL).
* **Buffer size ≠ scene size** at fractional scale (`round(len*s)` vs
  `round((off+len)*s)-round(off*s)`). Chrome/panel buffers filter bilinearly:
  never re-raster per device-grid phase (`ChromeBuffer.create` costs 2–8 ms).
* **Nested sessions never set buffer scale:** judge sharpness at
  `REDIWM_SCALE=1`, and debug visuals with IPC screenshots/buffer dumps, not
  host `grim`. Brief vanishing after a startup scale mismatch is not a bug.
* **GLES can NULL `wlr_scene_buffer.buffer`** after upload (the texture
  stays): persist raster sizes; test with `REDIWM_TEST_RENDERER=gles2`.
* **Glass** samples `wlr_client_buffer_get(buffer)->texture` and tracks
  source-surface damage per effect. Empty commits and buffer rotation keep the
  blur. Drags may hold titlebar blur at ≥ 0.98 opacity (the default theme is
  0.80, so it follows), so every path ending a move schedules a frame. An
  effect's scale comes from the outputs its target overlaps (`effect_scale`),
  never from the output being updated: it is in the effect's hash, and an
  output-dependent value made outputs of different scales re-blur and damage
  each other forever (`glass_hold.py`).
* **Owned GL beside wlroots:** wlroots draws with client-side vertex arrays, so
  any GL work of ours must put `GL_ARRAY_BUFFER` (and the rest of the state it
  touched) back before a wlroots pass runs, as `glass.c`'s `leave()` does; a quad
  VBO left bound makes wlroots draw half a rectangle. A border is drawn in the
  same pass as its body, never over it (`docs/plans/scene-graph-stage1.md`).
* **Commit only via `Output.commitFrameState`**, never
  `wlr_output_commit_state`. `commitIsRedundant` skips commits with no damage,
  colour change, attach-render lock or cursor change; register anything new
  there. Skipped frames get callbacks from `vblank_timer`, never immediately.
  Build output state through `Server.buildOutputState`, including capture: it
  selects the legacy or owned presenter and keeps one swapchain damage history.
  The temporary `[compositor] scene_renderer = "owned"` requires GLES2 and a
  restart. The owned pass reads graph geometry; scene nodes remain resource and
  feedback transports until stage 6 (`docs/plans/scene-graph-stage3.md`).
* **Idle makes no wakeups:** timers only for real deadlines, workers signal an
  eventfd, `text.applySize` instead of re-sizing faces, title changes repaint
  only their span and taskbar chip. Measure with per-thread context switches.
* **Damage:** each reusable shm buffer tracks damage since its own last paint;
  never write a busy one. `panel_paint.Background` keeps the last full image
  (`paintIncremental` repairs); widget setters `markDirty`/`markPaintDirty`,
  moves damage old and new bounds; convert publish damage at the real raster
  scale. Compositor-owned world buffers send full damage unless reported
  (`Projection.damageBuffer` after `setBuffer`, or `presentOwned`). Cache keys
  include visual state, text, geometry and Cairo transform; round globally
  before subtracting projection group origins.
* **Projection is resolve, then present** (`projection.c`, `scene_graph.h`).
  `resolve` turns the source tree into typed items (kind, unrounded
  layout-space edges, composed scale, content) listed in paint order per group
  and moves no view; `present` rounds once (`rediwm_edges_snap`, edges not
  origin+size) and applies. Geometry is derived only in `resolve`: a new rule
  (clip, opacity, fractional placement) is a field on the item, not a
  computation in `present_leaf`. A leaf or group leaves its `paint` list before
  the head is freed (`detach`, `finish_group`). Buffer identity, wait points and
  opaque regions are still read from the source node by `present`. A tree's
  rounded clip (`rediwm_projection_set_tree_clip`) is a field on each item
  (`item.clip`), resolved after the tree's own zoom and scale; an xdg popup
  lives under its parent's tree and must carry
  `rediwm_projection_set_tree_unclipped`.
* **Client buffers:** `wlr_client_buffer_apply_damage` works in place only
  without extra locks, so mark long-held locks ignorable. v4
  `attach(buffer, 0, 0)` still sets OFFSET; only nonzero dx/dy remaps. Don't
  resend unchanged `set_buffer_scale`; prefer compositor v5.

## Windows and focus

* **Unmapped ≠ destroyed.** `frame_tree` stays disabled until `handleMapped`;
  `focusSurface`/`minimize`/`restore` need `in_world`; `destroyNow` asserts
  `backend_gone` (or a compositor-owned backend).
* **Tiles are compositor-owned geometry** like maximize (`snap.zig`,
  `forcedGeometry()`). `Toplevel.layout()` reads the `maximized` field, not
  `isMaximized()` (xdg acks later). Leaving a layout without moving goes
  through `leaveLayout()`.
* **`Backend.shell` windows** (Settings) paint into `scene_tree` and present
  with `presentOwned`. No wl_surface: focused = first in `world.toplevels`,
  activated, no seat focus (`hasKeyboardFocus`). Never close one from a
  widget callback; details in `src/control_center/AGENTS.md`.
* **Desktop keyboard focus is shell focus:** taking it clears seat focus; a
  surface gaining seat focus, or a `.shell` window, takes it back.
* **Input** details are in `src/input/AGENTS.md`. Cross-cutting: every client
  motion path calls `clientMotion` then `sync`; Escape cancels drags through
  `Input.cancelDrag` (wlroots doesn't); compositor drop targets
  (`desktop_drop.Target`) end the grab before negotiating;
  `wlr_data_source_send` closes its fd.

## Xwayland

* X11 renders at N = `ceil(max output scale)`. `Xwayland.create` runs before
  outputs exist; `refreshScale` recomputes N after `Output.create`. Reproduce
  ordering bugs with per-output config scale, not `REDIWM_SCALE`. Scale
  changes wait for a restart once X11 surfaces exist.
* Units: `clientSurfaceGeometry()` X units; `clientGeometry()`,
  `requestSize()`, `commitPosition()` world units (`ceil(surface/N)`);
  `applySizeClip()`, `probeClientEdge()` surface units; `surfaceScale()` = N.
  Content trees use `rediwm_projection_set_tree_scale(1/N)`; X11 chrome
  density is 0.75.
* Clamp stale off-screen geometry of new X11 windows in
  `handleRequestConfigure` (except `open_rules`/`forcedGeometry()`).
* Keep `scene.restack_xwayland_surfaces = false`; `Toplevel.raise` syncs scene
  and X11 stacking and never raises an owner above its transients. Compositor
  hit tests can't prove X11 routing.

## Security, lock and login

* **Greeter** (`rediwm --greeter`) never unlocks (only `rediwm-dm` decides),
  writes nothing under `$HOME`, and runs no Xwayland, autostart, IPC,
  notifications, tray, portal, polkit, services, audio, desktop or
  external-tool globals: skip anything new that owns a bus name, spawns or
  writes (`tests/greeter.py`). Secrets stay in mlocked, wiped buffers.
* **A crash never unlocks.** `Lock.announce` reports state on
  `REDIWM_SESSION_FD` first thing in `engage`; `rediwm-session` queues `lock`
  for a compositor that died locked, and `main.zig` locks before the backend
  starts. Lock-before-sleep holds a logind delay inhibitor until
  `Lock.covered()`. Only `REDIWM_LOGIN_SESSION`'s logind `Lock` is followed;
  `Unlock` is ignored on purpose. The lock never polls.
* **Only rediwm-dm and the accounts helper run as root** (see their
  `AGENTS.md`); never the compositor.
* **No test hooks in production:** `REDIWM_*_PREVIEW` only in `test` blocks,
  `REDIWM_TEST_*` only in noninstalled fixtures; only `polkit_test_service`
  reads `REDIWM_POLKIT_HELPER_SOCKET` (it decides where passwords go).
  `strings` a ReleaseSafe `rediwm` after touching env handling.
* **App scopes:** every user-app launch calls `app_scope.place` (own scope in
  app.slice, since systemd-oomd kills whole cgroups); workers hand pids to the
  main thread first. Off nested/headless unless `REDIWM_APP_SCOPES=1`; never
  in the greeter.
* **IPC** fails with `SessionLocked` while `locker != null` (subscriptions
  re-check). Synthetic input and pixel reads need `[ipc] automation`. Socket
  only in a private directory, umask 0177. Sandboxed callers need an explicit
  `[[sandbox_allow]]` `ipc` allowance, fail closed and are re-checked on
  reload. `scroll` is natural by default (negative dy pages down).
* **Security context** (`global_filter.zig`) hides privileged globals from
  `wp_security_context_v1` clients (guess-binds are protocol errors) unless
  `[[sandbox_allow]]` grants the group; nested contexts are fatal.
* **Protocols:** a client ext-session-lock is a `Lock` with
  `origin = .client`, so `locker` guards apply and its death keeps the session
  locked. Screencopy policy is `guardScreencopy`; foreign-toplevel sync sits
  beside every `onWindowChanged`/`onWindowMoved`; output management goes
  through `Output.applyAndPersist`; only a client `on` clears
  `Output.power_off`.
* **Explicit sync:** projection moves `output_sample` to the view with its
  wait points; other GPU reads use `ReadFence`, CPU reads check
  `AcquireWait.ready`.

## Shared UI

* Widget callbacks carry `owner` + `id`: a stable host pointer that outlives
  the tree, never a global. Finish state updates before calling back, reset
  the dispatcher on rebuild, defer host destruction until dispatch returns.
* `ui/widgets/` owns every control's look (fields, buttons, dialogs,
  checkboxes, toggles, scrollbars, sliders, battery badge): never hand-draw or
  hand-hit-test one (`src/ui/AGENTS.md`).
* App clients (Files, Images, PDF) draw through `ui/cairo.zig` with theme
  tokens (`app_*`, `shellPalette().accent`) and shell icons. Text is
  `window_fg` only (placeholder at half alpha) at `text_size`,
  `heading_size` or `status_size`, never hardcoded sizes. Load the theme with
  `files/settings.zig` before the first frame (PDF: before its sandbox).
* Secrets live in `secret_input.Input` over caller-owned mlocked storage;
  hand-laid secret fields draw the caret with `CaretOverlay`.
* **Dead keys:** `xkb_state_key_get_utf8` returns nothing for them, so any
  code turning xkb presses into text feeds `ui.compose.Compose` first (shared
  lazy table from the user's language: ´+c is ç in `pt_BR`, ć elsewhere):
  `Keyboard.composeShell` for compositor fields, `deliverKey` in app clients.
  Reset on focus loss or Ctrl/Alt, no repeat for a consumed key
  (`willConsume`/`consumed`), `compose.preload` before a sandbox closes the
  filesystem (PDF). `tests/dead_keys.py`.

## Build and platform

* `ui`, `dbus` and `config` are named modules with one-way dependencies (no
  compositor imports). Parsing/persistence is `config/`, applying and reloads
  `config_runtime/`, shared raster code (`text`, `anim`, `sdf`, icons) `ui/`.
  `memory` owns the process allocator; executables own its shutdown.
* ReleaseSafe's `_FORTIFY_SOURCE` breaks translate-c on `bits/fcntl2.h`: use
  `std.os.linux` or `@cUndef("_FORTIFY_SOURCE")`. Never `@cInclude`
  glib/gobject/gio/librsvg; hand-declare the ABI. No runtime `parseColor()`
  in comptime defaults.
* `std.os.linux.*` return `-errno` in `usize` (`std.os.linux.errno`);
  `std.posix.system.*` are libc (`std.posix.errno`).
* zig-wlroots: `ext.*`/`wp.*` types need the protocol in `build.zig`'s
  scanner. `ForeignToplevelHandleV1.event.Fullscreen.output` and
  `ScreencopyFrameV1.buffer` can be NULL: read through `*const ?*T`.
  `wlr.Pointer` is 8 bytes short: embed it in an extern wrapper
  (`input/virtual.zig`) or `wlr_pointer_init` overwrites the next field.
* Debug `main.gpa` is `DebugAllocator`: freed memory reads `0xaa…` (glibc
  `MALLOC_PERTURB_`: `0xa5…`), leaks print at exit in the compositor log. Free
  process-lifetime caches in `main.start`'s defers; state workers read during
  shutdown comes from `std.heap.c_allocator`. Never mix allocators.
* Cairo `ARGB32` is premultiplied `0xAARRGGBB`, like our buffers. `png.zig`
  reads only 8-bpc non-interlaced truecolour(+alpha). Read
  `/sys/class/power_supply/*/uevent` only on uevents and the minute tick.
