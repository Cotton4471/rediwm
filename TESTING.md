# Testing

## Ground rules

Every test runs in its own headless compositor, temporary `XDG_RUNTIME_DIR`
and, where D-Bus is involved, a private `dbus-run-session` bus reached through
`DBUS_SYSTEM_BUS_ADDRESS`. Tests never touch the host display, session bus,
audio, backlight or power state, never submit real passwords, and never
request a real reboot or shutdown. Keep new tests that way. For visual
debugging on the host, see AGENTS.md, "Rendering".

## Layers

| Command | What it checks |
| --- | --- |
| `zig build test` | In-process unit tests: rasterizers vs. full rasters, UI, config, IPC parser/serializer fixtures, glass damage, projection damage and its typed graph (paint order, unrounded edges, list lifetime), lifecycle/allocation failures, Files/desktop logic. No compositor or bus. |
| `zig build test-glass` | The glass registry and an effect's geometry in the graph at every zoom (no GPU). Glass pixels are gated in `test-scene-pass` (stage 5b) and by `tests/glass_reblur.py`. |
| `zig build test-pass-spike` | The owned-pass spike of `docs/plans/scene-graph-stage1.md`: rounded clip, border, shadow, external-OES texture, backdrop blur, buffer-age damage and cost on headless GLES2 (needs a render node; `-Doptimize=ReleaseSafe` for cost). |
| `zig build test-scene-pass` | Stage 3's owned GLES2 drawing backend against wlroots: transforms, crops, filters, premultiplied alpha, damage, external-OES (an RGB EGLImage and a linear NV12 dmabuf; needs gbm), GL/EGL state and acquire/release timelines. Needs a compatible render node (`WLR_RENDER_DRM_DEVICE` on multi-GPU machines); also run with `-Doptimize=ReleaseSafe`. The unavailable-acquire test intentionally logs `drmSyncobjTransfer failed`. Stage 4b's rounded-shape gates are in the same fixture: clip against a supersampled reference, piece joins, border/body, premultiplied edges, the opaque cover, shadow, and partial repaint across a clip edge; the 128 parity cases also run through the shaped programs. Stage 4d's shadow gate compares every pixel with the CPU chrome's shadow formula. |
| `zig build test-lock` | Lock/greeter painter, password editing, PAM transitions (PAM is replaced at link time in test binaries only), greeter↔rediwm-dm conversation. |
| `zig build test-dm` | rediwm-dm relay state machine and framing. |
| `zig build test-dbus`, `test-polkit`, `test-polkit-ui`, `test-notifications`, `test-settings-portal`, `test-power`, `test-power-profiles`, `test-tray`, `test-app-activation`, `test-rediwm-session`, `test-layout-autosave`, `test-files`, `test-images` | Subsystem suites; the D-Bus ones re-exec under `dbus-run-session`. |
| `python3 tests/<name>.py` | Integration tests against the real `zig-out/bin/rediwm` on `WLR_BACKENDS=headless`. |

`zig build test` includes direct test targets for the `ui`, `config` and
`dbus` modules; Zig does not collect dependency-module tests through an
executable's test root.

Build first (`zig build`). Integration tests need Python 3 with Pillow, a C
compiler, `wayland-scanner` and wayland-protocols; D-Bus suites need PyGObject,
`dbus-run-session` and `busctl`. Some need extra tools, listed below.

### Common knobs

- Run from a shell with `umask 077`: suites that create their own runtime
  directory otherwise get a world-readable one, and the compositor refuses to
  open its IPC socket there (`RuntimeDirNotPrivate`).
- Export a scratch `XDG_STATE_HOME`, or tests read and overwrite your real
  layout autosave and saved window sizes.
- Files lists the host's removable and external disks from UDisks2, so every
  Files-launching suite sets `REDIWM_FILES_DEVICES=0`. Do the same in new ones.
- Files records opened files in shared recent history; set a scratch
  `XDG_DATA_HOME` in suites that open files so they never update the host's history.
- The compositor requires GLES2 (the owned output pass, stage 4e of
  `docs/plans/scene-graph-stage4.md`), so every suite runs on a render node:
  `ipc_client.py` sets `WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128` when it is
  unset; suites that start the compositor without it need it in the environment
  on multi-GPU machines. Without a GPU use Mesa's llvmpipe
  (`WLR_RENDERER_ALLOW_SOFTWARE=1`). GLES2 frees CPU scene buffers after
  upload, so `DumpBuffer` reads only what the compositor still holds; compare
  output screenshots for pixels.
- `REDIWM_TEST_SCALE=1.5` (or a `1.5` / `--scale 1.5` argument, per script):
  fractional scale. `REDIWM_TEST_OUTPUTS=2`: two outputs.
- `python3 tests/scene_baseline.py --out /tmp/scene-cost.json`: clean and stats
  sessions per scale (`--configs`), instructions, frame timers, RSS and power
  conditions; compare with `--report new.json --against old.json`. Use a
  ReleaseSafe build and a render node, keep other builds/tests stopped and AC
  power on. `--report` still reads the stages 3 and 4 "paired" results.
- `REDIWM_*_PREVIEW=/tmp/...` (lock, greeter, OSD, settings, switcher, tray,
  notification): keep the compositor's own screenshots.
- GLES2 at a fractional scale can differ by one level depending on render
  history. Compare integer scales exactly, or allow one level.

## The IPC socket is the test harness

`tests/ipc_client.py` (`IPCClient`, `spawn_compositor`, `stop_process`) and the
helpers in `tests/xwayland.py` (`start_compositor`, `wayland_display_name`,
`wait_for`) start compositors and talk to `$XDG_RUNTIME_DIR/rediwm-*.sock`.
Importing `ipc_client` sets `REDIWM_IPC_AUTOMATION=1`; launchers that build
their own environment must set it, or synthetic input and pixel reads return
`AutomationDisabled` (`tests/ipc_automation.py` checks that gate). `spawn_compositor` also points `XDG_STATE_HOME` into the test
directory: otherwise the layout autosave restore (2–37 s after start) moves
test windows to wherever the last run, or the host session, left them.

- Synthetic input (`MoveCursor`, `PointerButton`, `Key`, `TypeText`, `Drag`, …)
  goes through the normal input path; no libinput device or host is involved.
- Prefer exact state (`GetCamera`, `Windows`, `GetInputState`,
  `GetShellState`, `GetPerformanceStats`, `wait_for` conditions) over pixels.
  Use `Screenshot`/`SamplePixels` plus Pillow only for what IPC cannot report.
- `src/ipc/protocol.zig` is the source of truth for calls and events.

Real Wayland peers are small C fixtures compiled at test time
(`tests/*_client.c` with `wayland-scanner` + `cc`); `desktop_zoom.build_client`
builds the generic xdg toplevel (`zoom_client.c`, `--app-id`, `--title`).
LD_PRELOAD hooks (`*_hook.c`) model hardware the headless backend lacks:
output unplug, gamma LUTs, mode lists, polkit input, short writes.

## Integration tests by area

**Shell and windows**: `focus_zoom.py` (Alt+Tab/taskbar reveal easing, temporary
full-size boosts, camera depth focus, geometry, pixels, input and reduced
motion; supports the renderer/scale knobs), `desktop_zoom.py` (camera, window zoom, input at every
zoom, needs a render node for gles2 runs), `popup_constraint.py` (xdg popups
slide to the visible screen for windows panned or zoomed away from the world
origin), `zoom_osd.py` (shared zoom OSD,
100% camera cap, pixels, timeout and input), `decorations.py`, `kde_decorations.py`, `window_corners.py`
(border antialiasing and filled side edges on dark/light backgrounds at
integer/fractional scales, plus workspace focus outlines on server/client
decorations, mode transitions, fullscreen and default/explicit gaps, transparent
client corners and that a click on a clipped corner reaches the window below),
`switcher.py`,
`switcher_live.py`, `workspaces.py` (floating rules, Settings/IPC layout controls,
versioned restart/named-save restoration, duplicate app occurrences, restored tab groups,
saved canvas state and multi-window layout undo, both sides of tiled/floating
output transfers, dialog transfers, closed-member reconciliation, late configure
replies, keyboard/IPC tiling controls, drag previews and Escape, live
split resizing, unmap/remap, placeholder replacement, automatic split geometry,
constraints/overflow, stable focus,
minimize/maximize/fullscreen reinsertion, manual placement, workspace membership,
hidden input, dialog transfers, Settings, workspace protocol activation,
canvas restore and shortcut overrides; supports `REDIWM_TEST_OUTPUTS=2`,
`REDIWM_TEST_SCALE=1.5`, `REDIWM_TEST_NEGATIVE=1`, and `REDIWM_TEST_XWAYLAND=1` for real GTK click delivery;
GLES requires a render node; `--persistence-only` runs the restart/control checks), `window_snapping.py`, `initial_window_state.py` (startup
maximize/fullscreen placement, restore, window rules and depth), `taskbar_peek.py`,
`taskbar_title_repaint.py`, `window_urgency.py`, `start_menu.py`,
`power_menu.py` (only ever activates Log Out), `control_center.py`,
`control_center.py --services-only` (private systemd and polkit fixture: availability, in-table loading, unlock/lock and prompt cancellation, startup settings, Notify service types and isolated drop-in edits, runtime actions, authorization refusal, analysis, in-place state updates and coalesced reloads, signal-flood resistance, nothing read until the page is shown or while it is hidden, no RefUnit or unloaded-unit reads, the IPC lease, and lifetime),
`calendar_popup.py`, `bluetooth.py` (private BlueZ service; Settings device search,
radio, discovery cleanup, battery updates, PIN/passkey/confirmation pairing,
connect/disconnect, trust, removal, permissions and service restarts), `wifi_popup.py` (private NetworkManager service; popup and
Network settings, password/hidden forms, saved and open joins, radio, wired
details, connect/disconnect and permission errors, service restart and scrolling;
`--settings-only` runs just the settings checks), `battery_popup.py` (fake sysfs and private power-profile
service; charge states, missing details, selection and dismissal),
`keyboard_shortcuts.py`, `panel_damage.py`, `glass_hold.py` (holds and
mixed-scale idle), `glass_reblur.py` (glass re-blurs for changes below it,
never for its own client), `animations.py`, `hotspots.py`, `launch_feedback.py`,
`launch_placeholder.py`, `appearance_*.py`, `desktop_canvas.py`,
`layout_autosave.py`, `mini_map.py` (settings, pixels, timeout and dragging),
`mini_map_lifecycle.py` (focus, multiple outputs, cancellation and idle wakeups),
`mini_map_windows.py` (window outline pixels, size, movement, zoom and lifetime),
`mini_map_canvas.py` (live canvas growth/shrink with open windows, minimap fit
and off-canvas reachability).

`window_tabs.py` covers the Appearance checkbox list, opt-in persistence, explicit
+ launches, independent groups, tab focus, shared geometry, overflow, closing and
disabling without closing clients, close-confirmation dialogs, fullscreen and
failed launches. It supports `REDIWM_TEST_SCALE`,
`REDIWM_TEST_RENDERER`, and `REDIWM_TABS_PREVIEW`.
`REDIWM_TEST_WORKSPACES=1` also checks group layout undo, selected-tab closure
and remapping into the surviving group.

`appearance_settings.py --app-colors-only` exercises the GTK/Qt apply buttons,
configuration preservation and backups, failure reporting, and the persisted
launch environment. When development packages are available it also compiles
small GTK3, GTK4, libadwaita, Qt5 and Qt6 clients to check the actual loaded
colors. All configuration, clients and displays stay in temporary directories.

`kde_decorations.py` covers KDE decoration startup ordering, mode changes,
window rules, fullscreen/remapping, lifetime and titlebar controls. To also
check the installed Ghostty in a private D-Bus session, run
`python3 tests/kde_decorations.py --ghostty`.

**Wayland protocols**: `security_context.py` (wp-security-context-v1
registry hiding, guess-bind rejection, nested context forbidden, IPC window
attribution, sandbox allowances, sandboxed IPC caller detection via `bwrap`
and Flatpak info), `wlr_protocols.py` (wlr-output-management via
wlr-randr, wlr-foreign-toplevel via wlrctl, wlr-screencopy, virtual-pointer,
ext-session-lock via a fixture and real swaylock; workspace enumeration, tags,
content/tearing hints and renderer colour negotiation via the same fixture), `input_protocols.py`
(data-control with wl-clipboard, xdg-activation, text-input/IME,
virtual-keyboard), `dead_keys.py` (a virtual `latam` keyboard types dead-key
sequences into the start menu and Files' rename field under `pt_BR` and
`es_MX`; acute then c must give ç and ć), `pointer_constraints.py`, `shortcuts_inhibit.py`, `cursor_shape.py`,
`single_pixel.py`, `xdg_output.py` (`--xwayland` adds RandR via `xrandr`),
`presentation_time.py`, `explicit_sync.py` (gles2; vkcube), `direct_scanout.py` (gles2;
an opaque fullscreen client, XRGB or ARGB with an opaque region, is scanned out, a
translucent one is not), `layer_lifecycle.py`,
`idle.py`, `layout_ipc.py`, `clipboard_gtk_client.py`/`dnd_gtk_client.py`
(fixtures used by `xwayland.py`).

`window_titles.py` checks malformed initial and updated titles and valid Unicode.
It requires the patched private wlroots build
described in `patches/wlroots/README.md`.

**Displays**: `output_scale.py`, `output_destroy.py` (hook unplugs an output),
`display_arrangement.py` (Settings' arrangement: drag, snap, 0,0 normalization,
saved positions, windows carried along, main display, hidden with one output),
`night_light.py` (gamma hook: reject/accept modes, schedules via
`SetNightLightClock`).

**Capture**: `capture.py` (ext-image-copy-capture for outputs and windows over
shm and, with a render node, dmabuf; occlusion, camera, resize, destroy,
minimize, idle blank, unplug, `get_capture_state`; under `owned` a captured
server-decorated window has transparent bottom corners), `screencast.py` (portal
config packaging, `rediwm-share-picker --xdpw-dmenu` contract, Stop sharing
indicator), `screenshot_tool.py`, `screenshot_regressions.py` (save hook
injects write failures).

**Lock, login, authentication**: `lock_screen.py`, `greeter.py`, `dm.py`
(real daemon unprivileged with `--test` and `pam_start_confdir` stacks),
`polkit_dialog.py`, `polkit.py`.

**Session**: `session_restart.py` (uses `zig-out/release-safe`),
`rediwm_session.py`, `session_services.py`, `session_bus.py`,
`session_readiness.py`, `notification_services.py`, `app_activation.py`,
`settings_portal.py`, `power.py`, `power_profiles.py`, `notifications.py`,
`tray.py`, `hardware_keys.py` and `audio_balance.py` (private PipeWire; need
`pipewire`, `pipewire-pulse`, `pactl`, `pw-metadata`), `startup.py`,
`startup_warmup.py`. `audio_balance.py --scale 1.5` also checks fractional-scale
settings; it covers balance, volume keys, silence/mute and stereo/surround/mono
channel maps without accessing host audio. `audio_mute_fade.py` (also needs
WirePlumber's smart filters, `dbus-run-session`, `pw-record`, `pw-link`,
`paplay`) records the bass filter's output: mute fades out before the device
mutes, unmute fades in, a quick re-press turns the fade around, quitting
mid-fade still mutes.

`python3 tests/workspaces.py --controls-only` isolates tiling controls and lifecycle
checks; `--automatic-only` skips the older workspace-mode suite.
`--acceptance-only` runs live scale/origin reloads, tile-grab cancellation,
actual Wayland click delivery, per-thread idle wakeups, configure stability and
workspace IPC/protocol lock guards, including lock-client death. It uses
per-output scaling (`REDIWM_SCALE=auto`) and also supports two outputs.
The split engine also has pure unit tests in `src/auto_layout.zig`, included in
`zig build test`.

The [optional tiling qualification record](docs/plans/optional-tiling-qualification.md)
contains the renderer-specific GLES results, HEAD failure comparisons and the
pending physical-display checklist. Workspace GTK/Xwayland routing honors
`REDIWM_TEST_RENDERER` too. Select `WLR_RENDER_DRM_DEVICE` explicitly on multi-GPU
machines: headless multi-output idle and glass results can differ by driver.

`REDIWM_TEST_WORKSPACES=1 python3 tests/output_destroy.py` repeats hot-unplug
and reconnects the same connector, checking visible/hidden workspace ownership,
activation after migration and undo of transfers to the reconnected output. Use the same
flag with `keyboard_shortcuts.py` to exercise workspace preset editing and
disabling through Settings, or `window_tabs.py` for tab groups in automatically
tiled workspaces. `shortcuts_inhibit.py` also supports this flag for tiled/floating
bindings, Alt+Tab, number/wheel navigation, Super-drag and Super+Escape revocation.

**Xwayland**: `xwayland.py` (needs Xwayland, libxcb, `xdpyinfo`, PyGObject/GTK 3;
never uses the host `DISPLAY`), `xwayland_fractional.py`,
`xwayland_hardening.py` (extreme/invalid client size hints and recovery; needs
Xwayland and libxcb).

`xwayland.py` checks actual GTK click delivery on negative-origin outputs and
after panning beyond the physical display in either direction, including 1.5x
X11 rendering and clicking an already-open menu after another pan. X11 root
coordinates follow the camera viewport; scene and native Wayland coordinates
remain in world space.

**File dialogs**: `zig build test-file-chooser` (private D-Bus; OpenFile,
SaveFile, SaveFiles, filters, multiple selection, breadcrumbs, overwrite
confirmation, cancellation and Settings portal preferences). The chooser can
also be launched with `rediwm-files --open`, `--save` or `--folder`; it returns
a JSON result on stdout.

**Desktop, Files, Images**: `desktop_icons.py`, `desktop_damage.py`,
`files_browser.py` (file-path selection; with `REDIWM_FORCE_DBUS=1` on a private
`dbus-run-session` bus, also checks `FileManager1.ShowItems`), `files_controls.py`, `files_decoration.py`,
`files_controls.py --places-only` isolates navigation, Recent history and sidebar
controls from the Git checks. `files_thumbnails.py` (draws real pictures and reads thumbnail pixels back: shape,
colour, EXIF rotation, the shared freedesktop cache read and write, a 240-picture
folder, the `REDIWM_FILES_THUMBNAILS=0` switch and idle wakeups; it sets a scratch
`XDG_CACHE_HOME`), `files_fixes.py` (wl-clipboard), `files_associations.py` (private MIME/app
databases; needs update-mime-database, update-desktop-database and gio), `files_drag.py` (GTK 3; `--browser` tests
real Brave uploads with an isolated profile; `--select` selects by dragging
from empty space, `--list` exercises list view, and `--pin` drags folders and a
file onto PLACES: insertion line, order, refused drops, open and remove;
`--transfer` moves/copies into folders and between Files windows in grid/list), `files_drag_dodge.py`
(Files slides aside while a file is dragged out onto a window it covers, and
back on drop or Escape; also camera zoom, the setting off and nothing to uncover;
`browser` runs the real Brave upload and is not in the default set), `images_viewer.py`, `client_cursor.py` (grim;
themed cursor pixels, live theme reload and client cursor serials).

**Text editor**: `zig build test-editor` (document history, Unicode boundaries,
line segmentation and folding, the scrolling view, file classification, loading
and safe saving), `python3 tests/editor.py` (Files Space, tab reuse and
activation, typing, undo/redo, clipboard, Save As, unsaved-close prompts,
external-change protection, and a 46 MiB file opened, edited at its end and
saved exactly). `python3 tests/editor_visuals.py` checks
caret blinking and idle wakeups, and title glyph dimensions across resizes
(`REDIWM_EDITOR_DRAG=1` exercises pointer resizing). Supports `REDIWM_TEST_SCALE`,
`REDIWM_TEST_RENDERER`, and `REDIWM_EDITOR_PREVIEW=/tmp/editor.png`.

**PDF viewer**: `zig build test-pdf`, `pdf_viewer.py` (rendering, navigation,
text selection/copying, tiled fit width, and print dismissal/failure through a
fake Print portal on a private bus; run
it with `REDIWM_SCALE=2` too, where tiles split differently), `pdf_sandbox.py`
(a test-only parser hook checks file, syscall, inherited-FD, environment and
Wayland restrictions, that the print helper's socket cannot pass descriptors,
plus failure to install the sandbox). Requires Poppler GLib, libseccomp, Linux
Landlock ABI 3+, Python Cairo, `wl-paste`, and `dbus-daemon`.

**Browsers**: `brave_input.py` (optional; `REDIWM_TEST_BRAVE=/path`), a smoke
test of focus, clipboard, navigation and scrolling in a fresh profile.

**CLI**: `msg.py` runs `rediwm-msg` against a fake socket using the captured
cases in `tests/msg_v1.json`.

### Known limitations pinned by tests

These assertions are expected to start failing when wlroots fixes them; that
is the signal to revisit, not a regression.

- X11 → Wayland clipboard requires an Xwayland window focused at paste time
  (`test_x11_to_wayland_clipboard_focus_limitation`); PRIMARY behaves the same.
- X11 → Wayland drag-and-drop never starts (`test_x11_source_drag_to_wayland_limitation`).
- Synthetic pointer input over a GTK window on a second output does not reach
  the client, although hit-testing and RandR geometry are right.
- wlrctl 0.2.2 cannot match `state:maximized` (enum value 0); `wlr_protocols.py`
  checks maximize through IPC instead.

### Timing rules learned the hard way

- Allow ~150 ms after `SetZoom`/`SetCamera` before clicking: IPC reflects the
  camera at once, but projection settles on the next frame.
- Two clicks at the same surface-local pixel send no `wl_pointer.motion`, and
  Xwayland ignores the second; vary the offset.
- Give each drag-and-drop combination its own compositor; a second drag in one
  session is unreliable. Native → X11 DnD still flakes about 1 in 8.
- Synchronize on protocol acknowledgements, IPC events and `wait_for_frame`,
  not sleeps, wherever possible.

## Fixtures that must stay stable

`src/ipc_serializers.jsonl` pins response serialization. `src/ipc_tests.zig`
checks every canonical v1 command and rejection of legacy envelopes/names.
`tests/msg_v1.json` specifies CLI requests in the v1 format; `tests/msg.py`
checks them against an owned fake socket. Update expected contracts explicitly
when the protocol changes; never regenerate expectations from the implementation.

## Performance

Measure with ReleaseSafe (`zig build -Doptimize=ReleaseSafe`); keep renderer,
scale, input rate and compiler backend identical across comparisons.

- `perf.py` checks metric invariants on empty commits, full damage and menus.
  `perf.py --socket $REDIWM_SOCKET --seconds 10` observes a running desktop
  (resets its counters).
- `motion_perf.py` measures idle, pointer motion, selection, hover, drags and
  panning (`--rate 1000` for high-rate mice); it asserts that motion over
  unchanged desktop content repaints nothing.
- `scene_baseline.py` is the fixed workload for `docs/plans/scene-graph.md`:
  three glass windows, 60 fps damage, drag, resize, fullscreen and camera
  zoom on GLES2 at scale 1, 1.5 and mixed. A "clean" session records process
  cost (CPU, `perf stat` instructions:u, context switches, RSS) and a "stats"
  session the frame timers; `--out`/`--report --against` diff two builds,
  `--capture`/`--compare` keep and check golden screenshots. See
  `docs/plans/scene-graph-baseline.md`.
- `spawn_latency.py` times spawn → map → first presented frame.
- `startup_perf.py --binary zig-out/release-safe/bin/rediwm --runs 7`
  measures process entry → first scene commit, responsive IPC, catalogue and
  wallpaper in isolated headless sessions. `--native-scaling` includes X11
  native scaling; `--publication-delay-ms 1000` models slow login environment
  publication. `--cold-cache` disables reuse of the app catalogue between runs
  without flushing OS caches. Compare the same renderer, scale and build mode.
  `startup.py` also checks startup and shutdown with stalled audio;
  `session_readiness.py` withholds the supervisor's acknowledgement while
  exercising frames, input, IPC and exec restart.
- `GetPerformanceStats.frame_time_ms` is the interval between commits, not
  frame cost. `frame_work` has per-stage wall times over the last 512 samples
  (`cpu_frame`, `taskbar_cpu`, `chrome_cpu`, `panels_cpu`, `projection_cpu`,
  `glass_cpu`, `scene_commit_cpu`, `gpu_elapsed`; `glass_cpu` stays empty since
  the output pass draws glass, which `scene_commit_cpu` now includes, and
  `glass_reblurs` counts the blurs it re-took). CPU and GPU overlap; don't
  add them or invert them into FPS.
- The GPU timer starts on the first stats request and stops after five idle
  minutes; it costs CPU per frame. For CPU A/B runs, make no stats requests and
  read process CPU time (per-thread schedstat) instead.

## Still manual

Not covered by any automated test: a real login through rediwm-dm (logind, VT
hand-off, keyring), real-account PAM unlock, real polkit helper/pkexec
authentication, xdg-desktop-portal-wlr with a browser or OBS, DRM modesetting
and EDID scale on physical panels, physical backlight permissions, and IME
behaviour across real toolkits (fcitx5/IBus with GTK, Qt, foot, Firefox).

During the 2026-10-02 review the user confirmed real password login through
rediwm-dm, unlock and native polkit authentication on the development machine.
Keyring unlock and browser/OBS sharing remain unverified. See
[desktop readiness](desktop-readiness.md) for review results and known baseline
failures, and [screen sharing](docs/screen-sharing.md#remaining-qualification)
for the remaining capture acceptance checks.
