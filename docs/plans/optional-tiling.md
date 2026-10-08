# Plan: optional tiling and conventional workspaces

Status: stages 1–5 and automated stage 6 validation implemented for review; workspace mode remains opt-in.
Updated 2026-10-08.

The first milestone provides opt-in floating workspaces, reversible canvas
transitions, separate shortcut presets and Settings controls. Workspace IDs
1–32 are supported (1–10 in the default preset). Dialogs and tab groups move
together; external activation reveals their workspace. Output removal migrates
workspace ownership to a surviving output without merging membership.

Per-app floating rules and versioned workspace persistence are implemented.
Manual split controls, reversible grabs and multi-window layout undo are implemented. Canvas
autosave is preserved while workspace mode is active. See [README](../../README.md)
for configuration and shortcuts.

Milestone validation: Debug and ReleaseSafe builds, `zig build test`, and
snapping, shortcut editing, focus/zoom, tabs, initial window state, layout IPC,
autosave and output-destruction integrations pass. `tests/workspaces.py`
covers one/two outputs, 1.5× scale, negative origins, dialogs, Settings mode
selection, workspace protocol activation, camera/window restoration and held
keys; its optional GTK check verifies actual Xwayland click routing. Workspace
shortcut editing/disable and hot-unplug variants also pass.

The full protocol suite stops at its second-lock-client assertion; the full
Xwayland suite stops at an outdated IPC envelope in its server-stop test. Both
failures were reproduced on a separate HEAD worktree.

Automatic-layout validation adds pure split/constraint/allocation tests and
headless checks for stable focus, insertion/closure, live minimum/maximum sizes,
overflow recovery, output rotation, decoration changes, manual placement and
minimize/maximize/fullscreen reinsertion. Workspace and tab integrations pass,
including two outputs with negative origins at 1.5× and real GTK/Xwayland tiled
click delivery. Automatic-layout geometry also passes with GLES at 1.5×.
Debug, ReleaseSafe and unit tests pass. The broader output-scale suite's
`BufferNotAttached` failure and Xwayland shutdown's legacy-envelope assertion
were reproduced in a fresh worktree of HEAD (`a3f4a31`).

Layout-undo coverage includes keyboard/IPC operations, manual snaps, no-op
operations, live/released grabs, delayed configure replies, updated client
constraints, dialogs, tab groups and selected-tab closure, placeholder
replacement, and reconciliation after closing a focused member. Transfers
restore both layouts, including tiled/floating moves and windows that remain
maximized or fullscreen, on two outputs with negative origins at 1.5× scale.
Canvas undo, snapping, shortcut editing, focus/zoom, initial window state,
layout IPC/autosave and output-destruction integrations also pass. Debug and
ReleaseSafe builds and all 785 unit tests pass. GLES was not repeated for this change: this environment has no DRM
render node.

Stage 5 validation: Debug and ReleaseSafe builds and all 789 unit tests pass.
Workspace integrations pass on one output and on two outputs with negative
origins at 1.5× scale, including actual GTK/Xwayland clicks. Restart checks cover
duplicate app IDs launched in reverse title order, tab groups and selection,
floating overrides and reinsertion, exact split geometry, empty workspace
preferences, hidden membership, saved canvas state, named saves and delayed
startup beyond the first autosave tick. The full Settings suite, snapping,
shortcut editing, focus/zoom, tabs, initial window state, layout IPC/autosave,
output destruction and window-rule integrations pass. GLES could not run because
this environment has no DRM render node.

Stage 6 validation: Debug and ReleaseSafe builds and `zig build test` pass.
The complete workspace suite passes on one output and on two outputs at 1.5×
with negative origins, including real GTK/Xwayland clicks. New acceptance checks
cover live output density/origin changes during tile grabs, unchanged split
topology, real Wayland click delivery, stable configure counts, per-thread idle
wakeups, workspace IPC/protocol lock guards, unlock restoration and lock-client
death. Idle samples recorded 0–2 voluntary context switches per thread in 1.2 s
and no additional configures.
The GTK routing fixture now honors the requested output count and converts
pointer positions to output-local coordinates for negative-origin displays.

Hot-unplug/reconnect checks retain the connector name, preserve separate visible
and hidden workspace membership on the surviving output, assign an empty
workspace to the returning output and exercise reversible transfers. Shortcut
inhibition now runs in both modes, including tiling, Alt+Tab, number/wheel
navigation, pointer grabs and Super+Escape. The placeholder-undo test now waits
for the neighboring client's split configure before capturing its geometry.

Snapping, shortcut editing, focus/zoom, tabs, initial window state, layout
IPC/autosave, output destruction/arrangement/scale, security contexts and X11
size-hint hardening pass. Workspace variants of shortcut editing and tabs pass.
The protocol suite's expanded Canvas response expectation and Xwayland's old
stop-server request envelope are updated. The full protocol suite still fails
at the second lock client; the full/fractional Xwayland suites stop at a stale
41-pixel titlebar assertion (the compositor reports 35). These failures were
reproduced in a fresh HEAD worktree (`a3f4a31`). At that validation run, GLES and
physical-display qualification were pending because no DRM render node was available.

Follow-up qualification (2026-10-08): render nodes are now available. The lock
client and 41-vs-35 Xwayland titlebar failures were reproduced again against a
fresh HEAD build. The complete workspace suite passes with NVIDIA GLES on two
outputs at 1.5× with negative origins and real GTK input. Intel GLES passes
the full one-output suite, two-output controls/layout/persistence/routing and border
checks; its two-output idle limit still fails, with repeated wakeups reproduced
in HEAD canvas mode. Glass GPU tests pass on Intel and fail identically on HEAD
and the implementation on NVIDIA. Physical-display checks remain pending by
user choice. See the [qualification record and hardware checklist](optional-tiling-qualification.md)
for commands, evidence and open checks. Canvas remains the default.

Physical follow-up: the user rebuilt and restarted the installed ReleaseSafe
compositor. Its running binary hash matches the checkout; IPC confirms GLES2,
`nested = false`, a physical 2560×1600 panel at 1.5×/60 Hz and Canvas startup.
Interactive tiling, physical output changes and multi-display checks remain
pending in the qualification checklist.

The user then confirmed physical tiling, real clicks, pointer rearrangement,
split resizing and Escape cancellation. Their requested workspace styling adds
a 1 logical px red active-window outline (including CSD/floating clients) and
an 8 px default tile gap. Explicit `window_gap` settings still override that
default; Canvas retains its styling and zero-gap default. The focus colour is
the `workspace_active_border` theme token. The visual update needs a new physical
rebuild/restart for user confirmation.

## Agreed direction

Keep the existing pan-and-zoom canvas as the default. Add an optional
conventional workspace mode with automatic tiling, floating exceptions, and
manual window placement. Use a Hyprland-style default shortcut preset in
workspace mode. Returning to canvas mode restores its existing shortcuts.

Workspace mode is a desktop-wide choice. Within that mode, each workspace can
use automatic tiling or floating placement. Its shortcut preset stays consistent
when switching between tiled and floating workspaces or focusing a floating
window.

## Existing foundations

- [snap.zig](../../src/snap.zig) already implements manual half/quarter tiles,
  edge snapping, previews, and keyboard placement steps.
- [Toplevel.zig](../../src/Toplevel.zig) owns forced geometry, layout changes,
  floating restore geometry, and backend-specific configure requests.
- [World.zig](../../src/World.zig) owns the shared canvas and focus stack.
  Its toplevel list changes with focus and must not become the tiling order.
- Current desktop navigation moves the camera between canvas grid positions;
  it does not switch window membership or visibility. The workspace protocol
  currently advertises one Canvas workspace.
- Canvas persistence currently restores by app ID and still needs a versioned
  workspace format. Workspace undo now owns snapshots of affected split trees
  and members; canvas undo retains its single-window/camera behavior.

## User-visible behavior

In canvas mode, retain pan, desktop/window zoom, floating placement, and manual
snapping. In workspace mode, use a fixed camera and normal window scale, with
one visible workspace per output. New workspaces default to automatic tiling.

Save canvas positions and window zoom before entering workspace mode. Initially
place existing windows in a workspace on their current output. Returning to
canvas restores saved state for surviving windows and gives newly opened windows
sensible floating positions. Clamp restored positions when the output topology
has changed so windows remain reachable.

Dialogs and transient utilities float by default. Users can toggle any eligible
window between floating and tiled placement, with per-app rules for exceptions.
An existing tab group occupies one tile. Explicit manual half/quarter snapping
removes the window from automatic arrangement; the remaining tiles reflow.

Fullscreen and maximize temporarily override placement and remember the prior
tile. Minimize removes the window from arrangement while retaining reinsertion
information. Restore these windows deterministically even if the original
neighbours have closed.

## Shortcut presets

Use Hyprland's upstream example configuration as the reference for familiar
bindings, rather than assuming every tiling compositor uses the same defaults.
The following mappings were checked against the
[official Hyprland example configuration](https://github.com/hyprwm/Hyprland/blob/main/example/hyprland.lua)
on 2026-10-08. RediWM should ship a stable preset; upstream changes should not
silently change existing users' bindings.

| Workspace-mode shortcut | RediWM action |
| --- | --- |
| Super+Q | Open the configured terminal |
| Super+C | Close the focused window |
| Super+E | Open the configured file manager |
| Super+R | Open the start menu / launcher |
| Super+V | Toggle the focused window between tiled and floating |
| Super+J | Toggle the relevant split direction |
| Super+arrows | Focus in that direction |
| Super+1…9, Super+0 | Switch to workspace 1…10 |
| Super+Shift+1…9, Super+Shift+0 | Move the focused window to workspace 1…10 and follow it |
| Super+wheel | Cycle existing workspaces |
| Super+left-drag | Move a floating window or rearrange a tile |
| Super+right-drag | Resize a floating window or adjust a tiled split |

Use RediWM's configured applications and shell actions for these bindings; no
Hyprland companion programs are required. Adapt Super+M to RediWM's session/power
menu instead of its canvas maximize action. Hyprland's example assigns that key
to its shutdown/exit flow; the shell menu is the proposed RediWM equivalent.

Keep useful RediWM bindings such as Super+F for fullscreen, Super+L for lock,
Alt+Tab, screenshots, media controls, and Super+Z for undo where they do not
conflict. Add the following RediWM extensions, clearly labelled as extensions
rather than Hyprland defaults:

| Additional workspace shortcut | Action |
| --- | --- |
| Super+Shift+arrows | Move/swap the focused tile in that direction |
| Super+Ctrl+arrows | Adjust the relevant split size |
| Super+Shift+Space | Toggle automatic tiling for the current workspace |

Keep manual snap actions configurable and available through window controls.
Their canvas shortcuts remain Super+Shift+arrows; workspace mode uses those keys
for rearrangement. Pseudotiling and special/scratchpad workspaces are deferred,
so leave Hyprland's corresponding Super+P and Super+S combinations unassigned
until those features exist.

### Configuration and compatibility

- Select the workspace preset automatically when entering workspace mode, and
  restore the canvas preset when leaving it. Do not persistently rewrite bindings
  during a mode change.
- Keep existing `[keybinds]` configuration behavior for canvas mode. Add a
  separate workspace override table (proposed spelling: `[keybinds.workspace]`)
  layered over the workspace preset. This avoids importing canvas depth/pan
  bindings into the workspace preset accidentally.
- Explicit workspace bindings, including `noop`, win over preset defaults.
  Allow users to edit or disable every preset binding through Settings.
- Show the active mode/preset in shortcut settings and display conflicts there.
  Highlight changed meanings such as Super+Q, Super+M, arrows, and number keys.
- Keyboard, pointer modifiers, and wheel actions must all switch together.
  Finish or cancel current gestures before switching modes; avoid held-key
  repeats executing an action from the previous mode.
- Preserve shortcut inhibition, lock handling, keyboard-layout fallback,
  hardware controls, and the existing shortcut-inhibition escape binding.

## Implementation stages

### 1. Real workspace ownership

Add a workspace manager responsible for stable workspace IDs, membership,
visibility, output assignment, remembered focus, and an independent tiling order.
Start with conventional floating workspaces.

Update focus traversal, hit testing, taskbar, switcher, activation/reveal paths,
and workspace protocol reporting. A hidden workspace must not accept input.
Switching to a workspace already visible on another output should focus that
output rather than display the workspace twice. Define deterministic migration
and focus fallback when an output is disconnected.

Checkpoint: switching and moving windows between floating workspaces works on
one or multiple outputs, including dialogs and compositor-owned Settings windows.

### 2. Reversible mode switching and shortcut presets

Implement Canvas / Workspaces selection, canvas state capture/restore, the fixed
workspace camera, and the mode-specific shortcut resolver described above.
Keep window-depth and canvas-pan actions inactive in workspace mode. Add the
workspace switching/moving actions and Settings support for editing the preset.

Configuration parsing belongs in `src/config/`; applying mode changes belongs
in `src/config_runtime/`. Audit `Input.zig` pointer modifier handling as well as
the keyboard action table. Preserve custom canvas configurations and reload
behavior.

Checkpoint: repeated mode changes preserve windows and focus, activate the right
keyboard/mouse preset, and restore canvas geometry and bindings without edits to
the user's existing shortcut table.

### 3. Automatic layout engine — implemented

The pure `auto_layout.zig` split tree supports insertion/removal, swapping,
rotation and ratio adjustments. `auto_tiling.zig` coalesces compositor changes
through an event-loop idle callback and admits eligible members in stable
workspace insertion order. Windows use a separate arbitrary automatic target
in the existing forced-geometry path. Focus changes do not rearrange the tree.
The existing `window_gap` applies to output edges and internal splits; client
limits include decoration extents. Overflow leaves later members floating and
retries on membership, constraints or usable-area changes. Bounded clients may
leave unused space inside their tile. Dialogs and fixed-size clients float.

Stage 4 now supplies manipulation shortcuts and drag insertion previews.
Explicit manual placement/snapping opts a window out; tiled pointer grabs keep
it in the split tree. Minimize/maximize/fullscreen suspend a leaf, and tabs share
one leaf. Stage 5 now supplies multi-window undo.

Original stage requirements:

Implement one recursive split layout in a separate module: leaves represent
windows or tab groups; internal nodes store direction and split ratio. Support
insertion, removal, swapping, split rotation, and resizing. Focus changes alone
must not reorder tiles.

Keep geometry calculation independent of scene mutation. Extend the existing
compositor-owned geometry path to accept arbitrary tile rectangles rather than
representing automatic placement as a manual half/quarter tile. Keep layout
state explicit so focus zoom, drag handling, and other floating-only behavior
recognize automatic tiles.

Account for usable output area, titlebars, borders, gaps, fractional scale, and
client size constraints. Define a stable fallback when minimum sizes cannot fit:
leave a newly inserted window floating, and use a deterministic member order for
overflow after an output shrinks. Never loop between client configure replies
and relayout indefinitely.

Recompute only for membership, layout, constraints, or usable-area changes;
coalesce related changes and send only changed geometry. Add no idle polling.

Checkpoint: opening, closing, and resizing windows gives stable, non-overlapping
tiles with valid sizes and no focus-dependent rearrangement.

### 4. Manual controls and lifecycle integration — implemented

The workspace preset now assigns Super+V/J, Super+Shift+arrows,
Super+Ctrl+arrows and Super+Shift+Space. The same tiling actions are editable in
Settings and available through IPC `tiling_action` under its usual lock,
modal and sandbox checks. Each workspace retains its own automatic/floating
choice without changing shortcut presets.

Tile moves stage an insertion preview and apply only on release. Split resizes
are live and own a tree snapshot; Escape restores it and reconciles current
membership, so closing a window cannot resurrect a stale member. Output removal,
mode changes and a grabbed window becoming hidden or fullscreen cancel the grab.
Cross-output insertion and workspace transfers update both layouts. Floating
toggles and unmap/remap retain reinsertion hints; tab identity changes rename the
leaf when possible, remapped tabs rejoin surviving groups, and placeholder
replacement preserves its member identity.
Normal floating drags/resizes and canvas snapping remain available.

Split operations use the complete layout snapshots supplied in stage 5.
Per-workspace choices and ratios now persist in the stage 5 workspace snapshot.

Original stage requirements:


Wire keyboard rearrangement, split resizing, automatic-layout toggling, and
floating toggles into the shared actions used by Settings and IPC. Show an
insertion preview while dragging a tile. Escape restores its previous layout;
moving across outputs/workspaces updates both source and destination layouts.

Cover minimize/restore, maximize/fullscreen, client unmap/remap, destruction,
output removal, tab membership changes, and placeholder-to-client replacement.
Keep dialogs above their owners and avoid counting hidden tabs as extra tiles.
Preserve backend geometry conventions and actual Xwayland input routing.

Checkpoint: mouse and keyboard manipulation agree, cancellation is reversible,
and lifecycle events leave no stale members, empty splits, or unreachable windows.

### 5. Settings, rules, persistence, IPC, and undo

Layout undo is implemented in `layout_undo.zig`, backed by owned snapshots in
`undo.zig`. It captures only affected workspace trees and their member state,
including both sides of transfers. Shared keyboard/IPC actions, tile insertion,
split resizing, manual snapping, floating moves/resizes and explicit IPC
placement use the same undo slot. No-op operations retain the previous entry;
Escape discards a tiled gesture, while undo during a live grab ends it first.
Window IDs and stable insertion identities reconcile closures, tab identity
changes and placeholder replacement. Restoring uses live constraints and output
ownership, and preserves current minimize/maximize/fullscreen overrides.
Snapshots are freed on replacement, cancellation, mode changes, lock and shutdown.

Settings now edits workspace placement, gaps and per-app floating defaults.
Existing window rules accept a live `floating` property; explicit per-window
placement overrides stay independent. IPC reports output/visibility, gaps,
split nodes and window placement, with typed setters under the existing lock,
modal and sandbox guards.

`config/workspace_layout.zig` owns the bounded version 2 JSON format;
`workspace_persistence.zig` applies it. Workspace autosave uses its own state
file, and named saves use the same serializer. Unversioned canvas TOML stays
readable. Snapshots retain output ownership, workspace choices, split topology,
ratios, occurrence identities, floating geometry, tab grouping/selection and
saved canvas state. Startup reads once and consumes each app/backend/title/
instance match once; reverse launch order and missing members are reconciled.
Restoration runs after initial placement and before map-time focus, then finishes
group repair after tab reconciliation. Explicit layout operations protect affected
workspaces from later split rebuilds, and the finite startup restore window frees
the loaded snapshot after 37 seconds. Periodic saves preserve the original file
while matches are pending; explicit saves and shutdown capture current state.
Atomic writes skip unchanged snapshots.

Expose mode, workspace layout, gaps, shortcut overrides, and per-app floating
rules. Extend IPC with workspace/layout state and actions through its existing
lock and sandbox checks.

Version the saved layout format and read older saves. Persist workspace
membership, split structure, ratios, floating restore geometry, and saved canvas
state. Match multiple windows from one app explicitly, consume each match once,
and tolerate missing or ambiguous matches. Coordinate autosave restoration with
initial window placement so the two cannot fight each other.

Extend undo to snapshot all affected layout state for rearrangements, resizes,
floating toggles, and transfers, including both workspaces when applicable.
Destroyed windows must not invalidate undo of surviving members.

Checkpoint: restart and undo restore coherent groups rather than isolated window
coordinates, and config reload respects explicit binding overrides.

### 6. Validation and rollout — automated checks implemented

The automated acceptance and regression coverage above makes the opt-in feature
reviewable. Keep Canvas as the shipped default. GLES results and open renderer
limitations are recorded in the [qualification record](optional-tiling-qualification.md).
Physical-display checks remain pending; reproducing failures on HEAD does not
count as passing those checks.

Extend existing suites where practical and add focused tests for workspace
ownership and layout calculations. Follow [TESTING.md](../../TESTING.md) and the
applicable directory instructions; use isolated headless sessions and scratch
state directories.

Acceptance coverage:

- Canvas behavior and manual snapping remain unchanged with the feature off.
- Hidden workspaces cannot receive focus/input; activation reveals the correct
  workspace without bypassing lock or shortcut inhibition.
- Preset selection, collisions, explicit overrides, `noop`, reloads, held keys,
  pointer modifiers, and return to canvas all behave consistently.
- Wayland, Xwayland, Settings, dialogs, tabs, placeholders, and remapped windows
  participate correctly.
- Minimize, fullscreen, maximize, dragging, cancellation, and window closure
  preserve layout invariants.
- Multiple outputs, unplug/reconnect, negative origins, scale changes, and
  fractional-scale/GLES rendering preserve geometry and real input delivery.
- Restart, older saves, duplicate app IDs, and multi-window undo are reliable.
- Idle behavior adds no wakeups and layout changes do not cause configure storms.

For implementation, build Debug and ReleaseSafe, run `zig build test`, and run
the relevant integrations: snapping, keyboard shortcuts, focus/zoom, tabs,
initial window state, layout IPC/autosave, output destruction/arrangement,
workspace protocols, and Xwayland. Compare failures against a HEAD worktree
before treating them as regressions.

## Delivery boundary

The first reviewable milestone is conventional floating workspaces, reversible
canvas transitions, and the Hyprland-style shortcut preset. Automatic splits,
manual controls and multi-window undo now build on that foundation. Workspace
Settings, per-app floating rules, richer layout IPC and persistence now complete
that milestone. Keep the feature opt-in throughout development.

Additional layout algorithms, pseudotiling, scratchpads, and full Hyprland
configuration compatibility are outside this first implementation.
