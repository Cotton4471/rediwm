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
* **Window frames are shapes** (`docs/plans/scene-graph-stage4.md`).
  `Toplevel.applyShape` gives `frame_tree` one rounded clip carrying the ring
  colour (× window opacity); the pass composites the ring over the body, so
  something must be drawn under every ring pixel: the titlebar `ChromeBuffer`
  (a plain band) on top and the three `frame_fills` rects beside and below the
  client. The footer is `frame_border`. `shadow_tree`, the resize-grab tree and
  every xdg popup carry `setTreeUnclipped` (a new node that hangs outside the
  window needs it too). The shadow is analytic (`setTreeShadow` on
  `shadow_tree`, the CPU formula's smoothstep); its leaf `shadow_node` has no
  buffer and carries footprint, opacity and input only, so the projection
  damages that footprint itself. CSD windows have no shape and keep the
  `border_rects` outline. A changed clip damages its rim itself
  (`projection.c`); a point the shape cuts away is declined by the pick
  (`pick_world`), so the pick falls to what is below. Window capture draws the client alone and is
  handed the shape explicitly. The ring is one `max(1, round(border * scale))`.
  Without the shaped programs (`chrome.shapes` false) windows are square, with
  no ring or shadow.
* **Buffer size ≠ scene size** at fractional scale (`round(len*s)` vs
  `round((off+len)*s)-round(off*s)`). Chrome/panel buffers filter bilinearly:
  never re-raster per device-grid phase (`ChromeBuffer.create` costs 2–8 ms).
* **Nested sessions never set buffer scale:** judge sharpness at
  `REDIWM_SCALE=1`, and debug visuals with IPC screenshots/buffer dumps, not
  host `grim`. Brief vanishing after a startup scale mismatch is not a bug.
* **GLES can NULL `wlr_scene_buffer.buffer`** after upload (the texture
  stays): persist raster sizes.
* **Glass is drawn by the output pass** (stage 5, `docs/plans/scene-graph-stage5.md`).
  `glass.c` only registers effects: a bufferless node just below its target, to
  which resolve gives the target's box. When an effect re-blurs, `scene_output.c`
  redirects the pass (`rediwm_scene_pass_begin_backdrop`) and draws the items
  below it into an image a quarter of the logical size of its padded extent
  (target + 3 sigma), blurs that and composites it through the shape (shaped
  program mode 3), keeping one blur per effect and output. A kept blur is
  re-taken only when a damage event from a leaf painted *below* the effect, or
  damage no event explains, meets that extent, or the region or sigma changed.
  Only leaves that put pixels on screen have damage events (an input-only node
  must not, or it reads as a change below glass), and the software cursor's
  damage counts as explained. Damage a new kind of change through the
  projection's events or it counts as below (safe, slower). Collect keeps items an
  effect reads even where surfaces above hide them (`reads`). Holds (a dragged
  titlebar at ≥ 0.98 opacity, camera motion) carry the blur and re-take it once
  released. Per output, so mixed scales stay idle (`glass_hold.py`); attribution
  is checked by `glass_reblur.py`.
* **Owned GL beside wlroots:** wlroots draws with client-side vertex arrays, so
  any GL work of ours must put `GL_ARRAY_BUFFER` (and the rest of the state it
  touched) back before a wlroots pass runs, as `scene_pass.c`'s `leave()` does; a quad
  VBO left bound makes wlroots draw half a rectangle. A border is drawn in the
  same pass as its body, never over it (`docs/plans/scene-graph-stage1.md`).
* **Commit only via `Output.commitFrameState`**, never
  `wlr_output_commit_state`. `commitIsRedundant` skips commits with no damage,
  colour change, attach-render lock or cursor change; register anything new
  there. Skipped frames get callbacks from `vblank_timer`, never immediately.
  Build output state through `Server.buildOutputState`, including capture: the
  owned GLES2 pass is the only presenter (the session requires GLES2) and keeps
  one swapchain damage history. It reads graph geometry and the buffers,
  textures and wait points of the source nodes
  (`docs/plans/scene-graph-stage3.md`, `scene-graph-stage6.md`).
* **Shapes in the owned pass** (`scene_pass.h`): a window's rounded clip, ring
  and shadow are `rediwm_scene_pass_add_*_shaped` calls, device pixels, snapped by
  the caller. The programs cost the driver about 430 KiB (a GL program costs
  130-150 KiB whatever its size), so `enable_shapes` builds them on request, never
  with the renderer; before it a shaped draw fails the pass. Blend NONE is only
  valid inside `rediwm_clip_opaque`, minus the ring (`scene_output.c` draws a
  clipped item's ring-free core plain and the rest through the shape). The
  distance ramp is not area coverage (up to 18 of 208 levels at one pixel of a
  curved edge): that is expected.
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
  and shows nothing; `present` rounds once (`rediwm_edges_snap`, edges not
  origin+size) and turns what changed into damage events and screen damage.
  Geometry is derived only in `resolve`: a new rule (clip, opacity, fractional
  placement) is a field on the item, not a computation in `present_leaf`. A leaf
  or group leaves its `paint` list before the head is freed (`detach`,
  `destroy_group`). Buffer identity and damage are read from the source node by
  `present`, textures, single-pixel colours, wait points and opaque regions by
  the pass. A tree's rounded clip (`rediwm_projection_set_tree_clip`) is a field
  on each item (`item.clip`), resolved after the tree's own zoom and scale; an
  xdg popup lives under its parent's tree and must carry
  `rediwm_projection_set_tree_unclipped`.
* **The world has no second tree** (`docs/plans/scene-graph-stage6.md`). The
  source tree is disabled, so wlroots computes no outputs, frame callbacks,
  damage or picks for it; the graph does, with wlroots' own rules on our data.
  *Feedback* (`rediwm_projection_feedback_*`, called by the pass's `collect`):
  per build, the pixels of each client surface that nothing above hides, over
  every output; an output is active when it shows more than a tenth of that, the
  primary one shows most (the later wins a tie); `outputs_update` and
  `output_enter/leave` go out on the *source* buffer, again when an active
  output's scale, transform or subpixel changed. Frame callbacks of the world
  come from `Server.sendFrameDone`, never `wlr_scene_output_send_frame_done`
  alone; the pass emits `output_sample` on the source buffer. A layer-shell
  surface below the world (background, bottom) is no longer occluded by windows
  in wlroots' eyes: it keeps frame callbacks while covered. *Damage*: every
  change reaches `p->pending` through `damage_box` and goes to the outputs once,
  at the end of each sync. A change of what a leaf itself shows is cut to what
  was visible of it at the last build (`l->visible`); a move, restyle or removal
  damages the old box (cut) and the new one; a restack damages what moved
  (`damage_restacked`), shadow footprints included; a destroyed node applies at
  once, because a capture can build before the next sync. A new kind of change
  that moves no leaf has to damage itself there (clip rims and shadows do).
  *Picks*: `rediwm_projection_node_at` (graph for the world, wlroots for the
  layout trees), never `wlr_scene_node_at` on the root. GLES2 lets go of a
  plain buffer once uploaded, so "has content" is a buffer, a texture or a
  single-pixel colour (`present_leaf`, `collect`).
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
* **Tiles glide and workspaces slide.** `setAutoTile(rect, animate)` eases
  like snapping (`auto_tiling.Manager.quiet` for non-user reflows). A switch
  keeps the leaving workspace's frames shown but inert
  (`rediwm_projection_set_tree_inert`) until `tickSwitch` settles; anything
  that stops showing a window mid-slide calls `finishSwitch`. Input follows
  what is drawn and `chrome_box` sizes are animated: tests
  `wait_for("window_geometry_settled")` before pointer input or geometry
  snapshots.
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
  `applySizeClip()` surface units; `surfaceScale()` = N.
  Content trees use `rediwm_projection_set_tree_scale(1/N)`; X11 chrome
  density is 0.75.
* Clamp stale off-screen geometry of new X11 windows in
  `handleRequestConfigure` (except `open_rules`/`forcedGeometry()`).
* Keep `scene.restack_xwayland_surfaces = false`; `Toplevel.raise` syncs scene
  and X11 stacking and never raises an owner above its transients. Compositor
  hit tests can't prove X11 routing.

## Security, lock and login

* **Greeter** (`rediwm --greeter`) never unlocks (only `rediwm-dm` decides),
  writes nothing under `$HOME` (it disables the GLES2 shader cache), and runs no Xwayland, autostart, IPC,
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
* **Explicit sync:** the pass emits `output_sample` on the source buffer, which
  carries the wait points; other GPU reads use `ReadFence`, CPU reads check
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
  the effective `window_fg` (placeholder at half alpha) at `text_size`,
  `heading_size` or `status_size`, never hardcoded sizes. Load the theme with
  `files/settings.zig` before the first frame (PDF: before its sandbox).
  That loader resolves `Theme.forApp()` so `app_fg`, menu and field overrides
  can differ from compositor chrome; sidebar text uses `sidebarForeground()`.
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
