# System Monitor plan

Status: implemented, 2026-10-17. Collector, native monitor window, process
actions, shortcut and desktop integration are present. See the
[user guide](../system-monitor.md) for behavior, shortcuts and configuration
migration, and the validation record below.

Add a native **System Monitor** application, `rediwm-monitor`, opened by
**Ctrl+Alt+Del**. Use [Mission Center](https://missioncenter.io/) as the feature
reference for a resource overview and process list, with a small first version
that follows RediWM's existing app styles.

Run it as a separate Wayland application using RediWM's shared UI and theme.
Process collection runs independently of the compositor.

## First version

Use one resizable window:

| Area | Content |
| --- | --- |
| Top | CPU usage and RAM used/total, each with a simple 60-second history graph. |
| Toolbar | Search, My processes / All processes, and Pause updates. |
| Main area | Sortable process list: Name, PID, User, CPU %, Memory, State. |
| Bottom | Process count, swap usage, and actions for the selected process. |

Default to the current user's processes, sorted by CPU usage. Keep selection
attached to the process as rows move, and preserve scroll position during
refreshes.

**End process** requests termination. A separate **Force quit** action handles
processes that ignore it, with confirmation naming the target. Other users'
processes are viewable where permitted; v1 manages the current user's own
processes and protects essential RediWM session components.

GPU monitoring, disk/network charts, per-core views and application grouping
can follow once this foundation is solid.

## Visual design

Use existing window decorations, fonts, spacing, theme colors, selection
states, fields, buttons, dialogs and scrollbars. Graphs use the theme accent.
Support live theme changes and fractional scaling from the start.

Use `ui/cairo.zig`, theme text and color tokens, and the shared controls in
`ui/widgets/`. Load the effective app theme through `files/settings.zig`
before the first frame. New controls must follow the shared UI ownership,
callback and lifetime rules.

## Implementation

### 1. Collector and process model

Add `src/system_monitor/` with process enumeration, CPU sampling, memory
accounting and bounded history. Read Linux's `/proc` data in a worker and
deliver snapshots to the UI. System memory uses available memory when
calculating usage; process memory is labeled as resident memory. Follow the
[Linux proc filesystem documentation](https://docs.kernel.org/filesystems/proc.html).

The existing sampler in
[`src/ipc/processes.zig`](../../src/ipc/processes.zig) covers only processes
owning windows. Extract useful parsing logic while preserving that IPC
command's behavior. The new collector must also include background processes
and handle processes disappearing during sampling.

Keep collection and process identity logic independent of compositor types.
Worker snapshots own their data, and workers do not access Wayland or UI
objects.

### 2. Native window

Follow the existing app-client patterns, using
[`src/ui/cairo.zig`](../../src/ui/cairo.zig), shared widgets and
[`src/files/settings.zig`](../../src/files/settings.zig) for theme loading.
Refresh once per second, paint visible rows, and support keyboard search and
navigation.

Stop sampling when paused or closed. Include visibility signaling for
suspension while minimized: the current client protocol setup does not
provide that automatically. Add and validate that lifecycle support rather
than treating loss of keyboard focus as proof that the window is hidden.

### 3. Process actions

Identify selections by PID and process start time, revalidate the target, and
signal through a pidfd so PID reuse cannot redirect an action. Validate the
pidfd target against the selected identity before sending a signal. Show
clear outcomes such as "Process already exited" or "Permission denied".
Follow the [Linux pidfd signal documentation](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html).

End process sends SIGTERM. Force quit sends SIGKILL after explicit
confirmation naming the selected process. Recheck ownership and protected
session identities when executing the action, including after a confirmation
has been open while the process list changes.

### 4. Desktop integration

Add an `open_system_monitor` action that launches the app or restores and
focuses its existing window. Route launching through the existing app-scope
machinery. Install a desktop entry and icon for the application launcher.

Both presets now bind Ctrl+Alt+Del to `open_system_monitor`; the canvas
previously used `poweroff`. Explicit bindings are preserved and require the
[documented configuration change](../system-monitor.md#existing-shortcut-configuration).
Existing lock, greeter and shortcut-inhibition rules still apply.

Relevant integration points:

| Existing code | Planned integration |
| --- | --- |
| [`src/config/keybinds.zig`](../../src/config/keybinds.zig) | Add the named action. |
| [`src/config/default.zig`](../../src/config/default.zig) | Change the canvas Ctrl+Alt+Del default. |
| [`src/config/workspace_defaults.zig`](../../src/config/workspace_defaults.zig) | Add the workspace Ctrl+Alt+Del default. |
| [`src/config_runtime/actions.zig`](../../src/config_runtime/actions.zig) | Dispatch launch or restore/focus through the existing launch path. |
| [`src/session/app_scope.zig`](../../src/session/app_scope.zig) | Preserve per-application scope placement. |
| [`src/control_center/sections/shortcuts.zig`](../../src/control_center/sections/shortcuts.zig) | Add the shortcut description and appropriate grouping. |
| [`build.zig`](../../build.zig) and `data/` | Build and install the executable, desktop entry and icon. |

### 5. Validation

Extend existing tests where practical and add focused coverage for the new
collector and application:

* CPU calculations and memory accounting from controlled samples.
* Disappearing processes, PID reuse, unavailable data and permission errors.
* Sorting, search, stable selection and scroll position during updates.
* End process and Force quit using disposable fixture processes, including a
  fixture that ignores SIGTERM.
* Shortcut launch, restore/focus, repeated activation and both desktop modes.
* Existing lock, greeter and shortcut-inhibition behavior.
* Live theme changes, fractional scaling, keyboard navigation and resizing.
* Sampling suspension, cancellation and worker lifetime when paused,
  minimized, restored or closed.

Use isolated headless integration tests as described in
[`TESTING.md`](../../TESTING.md). Process-action tests must only signal their
own disposable fixtures.

Before completing implementation, build Debug and ReleaseSafe, run
`zig build test`, and run the affected integration suites. Compare failures
against a worktree of HEAD before calling them regressions.

## Delivery order

1. Collector and process model with focused tests.
2. Usable native monitor window with summaries, history, search and sorting.
3. Process actions, shortcut integration, launcher packaging and end-to-end
   validation.

## Implementation and validation record

The collector, bounded history and process model live in `src/system_monitor/`.
IPC reuses its stat reader and retains the existing window-only sampling
behavior. The standalone app uses persistent shared widgets, released shm
buffers, filesystem theme notifications, fractional-scale/viewporter, and an
eventfd worker. xdg-shell v6 suspension is sent by the compositor when a
window is minimized and cleared on restore. Process actions validate the
pidfd, start time, ownership and protected executable at execution. Launcher
files and the session/release installer lists include the new executable.

Validated on 2026-10-17:

* Debug and ReleaseSafe builds; `zig build test` and `zig build test-monitor`.
* `tests/system_monitor.py`: canvas and workspaces at scale 1 and 1.5,
  disposable TERM/KILL targets, confirmation cancel, a target exiting while
  confirmation is open, protection changing across exec, stable list model,
  pause, focus loss, minimize/restore, hidden close, resizing and live themes.
  The canvas suite also passes against the ReleaseSafe compositor and app
  using `REDIWM_TEST_BINARY=.../zig-out/release-safe/bin/rediwm`.
* `keyboard_shortcuts.py` and `shortcuts_inhibit.py` in both desktop modes;
  the latter explicitly checks the monitor chord under an inhibitor.
* `lock_screen.py`, `greeter.py`, `output_scale.py`, `images_viewer.py`,
  `files_controls.py --places-only`, and `editor.py`.
* ReleaseSafe executable strings contain no monitor preview or production
  `REDIWM_TEST_*` hooks. Installer shell syntax and diff whitespace checks pass.
  UI action tests use a noninstalled seccomp notification guard that permits
  signals only to their own recorded child identities, with a separate guard
  check against an unlisted disposable process.

Two broader suites retain failures reproduced in a detached worktree of
HEAD (`3170a17`): `wlr_protocols.py` expects `finished` for a second session-lock
request but receives EOF; `pdf_viewer.py` times out waiting for a double-clicked
PDF window to close. Workspace inhibition's initial restore-drag assertion
passed on rerun.
