# Optional tiling qualification

Updated 2026-10-08. Canvas remains the shipped default; workspace mode is opt-in.
This records qualification of the uncommitted stages 1–6 implementation against
HEAD `a3f4a316bc850169edf55e81325f4b197697e780`. Physical-display qualification
has started after the user compiled, installed and restarted into the new build.
Startup inspection is recorded below; interactive checks remain pending.

## Automated results

Debug, ReleaseSafe (`--prefix zig-out/release-safe`) and `zig build test` pass.
All integration runs use private headless compositors and scratch state.
The baseline was built in a fresh detached worktree at
`/tmp/rediwm-tiling-head`. Logs for this run are in
`/tmp/rediwm-tiling-qualification`; these temporary paths are evidence from this
run, not repository fixtures.

| Check | Implementation | HEAD comparison |
| --- | --- | --- |
| Full `wlr_protocols.py` | Fails at `session_lock`: second client prints EOF instead of `finished`; preceding protocol cases pass | Same assertion in the unmodified HEAD suite |
| Full `xwayland.py` | Reaches native-scaling managed-window test; expects titlebar 41, receives 35 | Focused `test_native_scaling_managed_window()` reproduces 41 vs 35 on HEAD; the unmodified full HEAD suite stops earlier at its legacy stop-server envelope |
| Full workspace suite, pixman, two outputs, 1.5×, negative origins, GTK/Xwayland | Pass | Feature absent on HEAD |
| Full workspace suite, NVIDIA GLES, two outputs, 1.5×, negative origins, GTK/Xwayland | Pass, including scale/origin reload, real input, lock guards, restart, undo and idle | Feature absent on HEAD |
| Intel GLES workspace controls, persistence and automatic layout, two outputs, 1.5×, negative origins | Pass | Feature absent on HEAD |
| Full workspace suite, Intel GLES, one output, GTK/Xwayland | Pass, including idle, lock guards, persistence, controls and canvas restoration | Feature absent on HEAD |
| Intel GLES workspace acceptance, two outputs | Fails idle bound: 70 voluntary main-thread switches in 1.2 s, limit 4 | Matched canvas probe also wakes repeatedly on HEAD; see below |
| Intel GLES GTK/Xwayland workspace routing and canvas restoration, two outputs, 1.5×, negative origins | Pass | Feature absent on HEAD |
| Intel GLES `window_corners.py` | Pass at 1, 1.25, 1.5 and 2×, including Settings resize and light/dark edges | No baseline failure to compare |
| Intel `zig build test-glass` | Pass | Pass |
| NVIDIA `zig build test-glass` | Fails: incompatible EGLImage/target, FBO creation failure, `effect->valid && !engine->failed` assertion | Same failure |

The workspace GTK routing fixture now honors `REDIWM_TEST_RENDERER`; previously
that branch silently used pixman even when the rest of the suite used GLES.
No assertions were relaxed or failures skipped for qualification.

The machine exposes `/dev/dri/renderD128` through i915 and
`/dev/dri/renderD129` through NVIDIA (driver 615.71.09), on kernel
7.2.8-zen1-2-zen. Render-node numbers are machine-specific; discover them again
on another machine. Only `card1-eDP-1` was connected during this run.

The Intel idle comparison used the same three Wayland fixture windows, two
headless outputs, per-output scale/origin reload sequence and 1.2 s sample:

| Configuration | Main-thread voluntary switches | Other surviving threads |
| --- | --- | --- |
| HEAD canvas, GLES | 84 | 0 |
| Implementation canvas, GLES | 76 | 0 |
| Implementation workspaces, GLES | 96 | 0 |
| Implementation workspaces, pixman | 1 | 0 |

This reproduces repeated Intel GLES wakeups without tiling; it does not establish
their cause or prove equal rendering cost. NVIDIA's full workspace acceptance
sample recorded 1 main-thread switch and 0 on other surviving threads, with no
additional client configures. Intel's one-output acceptance also recorded 1/0.
Intel two-output idle and NVIDIA glass remain open renderer qualifications.

## Reproduction

Build HEAD in an isolated worktree and run the failing protocol cases with its
own binary and fixtures:

```sh
git worktree add --detach /tmp/rediwm-tiling-head HEAD
cd /tmp/rediwm-tiling-head
zig build
umask 077
baseline_state=$(mktemp -d /tmp/rediwm-head-state.XXXXXX)
export XDG_STATE_HOME="$baseline_state"
python3 -u tests/wlr_protocols.py
PYTHONPATH=tests python3 -u -c 'import xwayland; xwayland.test_native_scaling_managed_window()'
```

Run from the implementation checkout, selecting each available render node:

```sh
zig build
zig build -Doptimize=ReleaseSafe --prefix zig-out/release-safe
zig build test
umask 077
REDIWM_TEST_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=/dev/dri/renderD129 \
  REDIWM_TEST_OUTPUTS=2 REDIWM_TEST_SCALE=1.5 REDIWM_TEST_NEGATIVE=1 \
  REDIWM_TEST_XWAYLAND=1 python3 -u tests/workspaces.py
REDIWM_TEST_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 \
  python3 -u tests/workspaces.py --acceptance-only
WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 zig build test-glass
WLR_RENDER_DRM_DEVICE=/dev/dri/renderD129 zig build test-glass
REDIWM_TEST_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 \
  python3 -u tests/window_corners.py
```

Repeat the two-output workspace command with Intel to reproduce the idle
failure. To exercise its later GTK/canvas cases independently after that failure:

```sh
REDIWM_TEST_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 \
  REDIWM_TEST_OUTPUTS=2 REDIWM_TEST_SCALE=1.5 REDIWM_TEST_NEGATIVE=1 \
  PYTHONPATH=tests python3 -u -c 'import workspaces; workspaces.xwayland_routing(); workspaces.run(2)'
```

## Physical-display qualification

After the user's rebuild and restart on 2026-10-08, the running
`/proc/3159569/exe` hash matches both `/usr/local/bin/rediwm` and the checkout's
`zig-out/release-safe/bin/rediwm`:
`98ce6266aebba7d4febd49ff4ec56052123bf5533c09915527a6b5698d3c8b1c`.
Read-only IPC reports GLES2, `nested = false`, one enabled BOE `0x0A0B` panel
on `eDP-1`, 2560×1600 pixels / 1706×1066 logical units, scale 1.5 and 60 Hz.
The active workspace is Canvas. This verifies startup on the intended build
and physical output; it does not qualify interactive tiling or scanout changes.
The runtime/output/workspace snapshot is saved at
`/tmp/rediwm-tiling-qualification/physical-startup.json`.

The user subsequently confirmed that workspace tiling, real clicks, tile
rearrangement, live split resizing and Escape cancellation work on this display.
Other physical checks remain pending. Their follow-up request adds a 1 logical
pixel red active-window outline and an 8 px workspace gap default; those visual
changes need a rebuild/restart before physical confirmation. Explicit gap
settings, including zero, remain authoritative; Canvas defaults stay unchanged.

Focus-style validation: Debug and ReleaseSafe builds and all 789 unit tests pass.
The expanded `window_corners.py` passes on pixman and Intel GLES at 1, 1.25,
1.5 and 2×, covering focus transfer, straight edges and both corner bands, CSD
edge clicks, fullscreen, mode transitions and default/explicit-zero gaps.
The NVIDIA GLES focus check also passes at 1.5×. Complete two-output workspace
suites pass on pixman and NVIDIA GLES at 1.5× with negative origins and real
GTK/Xwayland clicks. Snapping, decoration negotiation, workspace tabs and
focus/zoom integrations pass. Logs are in `/tmp/rediwm-tiling-focus`.

### Checklist

Run the checkout's ReleaseSafe binary in a disposable physical session. The
installed binary had a different hash during the earlier automated run; the
new running binary now matches, as recorded above. A nested Wayland window or a headless GLES pass does not verify
DRM modesetting, scanout, physical input or EDID-derived scale.

Save work and leave the existing graphical session before starting the test from
a normal user's local VT login. Run without root. Keep the installed binaries
and normal configuration intact; use scratch configuration and state instead:

```sh
cd /home/alex/projects/wlroots
umask 077
qualification_dir=$(mktemp -d /tmp/rediwm-physical-tiling.XXXXXX)
mkdir -p "$qualification_dir/config" "$qualification_dir/state" \
  "$qualification_dir/cache" "$qualification_dir/data"
cat > "$qualification_dir/config.toml" <<'EOF'
[compositor]
xwayland = true
EOF
sha256sum zig-out/release-safe/bin/rediwm > "$qualification_dir/binary.sha256"
dbus-run-session -- env -u WAYLAND_DISPLAY -u DISPLAY -u REDIWM_SOCKET \
  REDIWM_CONFIG="$qualification_dir/config.toml" REDIWM_SCALE=auto \
  XDG_CONFIG_HOME="$qualification_dir/config" XDG_STATE_HOME="$qualification_dir/state" \
  XDG_CACHE_HOME="$qualification_dir/cache" XDG_DATA_HOME="$qualification_dir/data" \
  WLR_BACKENDS=drm WLR_RENDERER=gles2 \
  /home/alex/projects/wlroots/zig-out/release-safe/bin/rediwm \
  > "$qualification_dir/compositor.log" 2>&1
```

Use a terminal launched inside that session for inspection. Record the scratch
directory, binary hash, driver/kernel versions, connector names, modes, refresh
rates, effective scales and results below. `rediwm-msg runtime`, `outputs`,
`workspaces`, `windows` and `window-debug ID` inspect the test compositor;
verify `nested = false`, GLES and the real connector names before counting a pass.
Use the checkout's `zig-out/release-safe/bin/rediwm-msg`.

| Exercise | Pass criterion | Result |
| --- | --- | --- |
| Default startup | Starts in Canvas; original pan/zoom, manual snapping and canvas bindings work | Canvas startup verified; interactive canvas behavior pending |
| Opt-in and return | Select Workspaces in Settings; select Canvas again; surviving window positions, size, zoom and canvas shortcuts return | Pending |
| Physical input | Real keyboard, mouse/touchpad and Super+wheel reach the active workspace; hidden clients receive no clicks/keys | Pending |
| Tile geometry | Open three native Wayland clients and real GTK/Xwayland clients; gaps, titlebars, footer skirts and borders remain clean and non-overlapping | Pending |
| Tile controls | Super+V/J, directional focus/swap/resize, automatic/floating workspace toggle, tile insertion and live divider resize work | User confirmed tiling, real clicks, pointer rearrangement and split resizing; remaining controls pending |
| Cancellation and undo | Escape restores a grab; Super+Z restores both layouts after a transfer; closing a member mid-grab leaves no stale tile | User confirmed Escape cancellation; undo/closure cases pending |
| Lifecycle | Minimize/restore, maximize/fullscreen, dialogs, Settings, tabs and client closure preserve focus and valid layout | Pending |
| Scale and scanout | Test scale 1, auto and 1.5 on the physical connector; check sharpness, hover borders, glass and real native/X11 menu click alignment | Pending |
| Two physical outputs | One visible workspace per connector; focus/transfer across outputs and a negative origin preserve real input and geometry | Pending; needs another display |
| Physical unplug/reconnect | Unplug an external display during a tile grab; grab ends, hidden/visible membership survives separately, reconnect gets valid ownership | Pending; needs another display |
| Modes/rotation | Change a supported mode, refresh and rotation in Settings; layout reflows without configure storms or stale imagery | Pending |
| Idle | After startup and animations settle, compare Canvas/Workspaces per-thread voluntary switches over equal samples with static clients; no tiling-driven repeating wakeups/configures | Pending |
| Lock/unlock | Lock and unlock this disposable session normally; geometry, focus and real input resume correctly | Pending |
| Restart | In the scratch config, select Workspaces, save layout and exit; restart the same binary/config/state and reopen matching apps; membership, splits and floating overrides restore | Pending |

For pixels, use compositor IPC screenshots with automation enabled only in this
disposable session, or the compositor's own screenshot action. Do not use host
`grim` as evidence about a nested compositor. Capture logs for any failure and
compare the same operation with HEAD before assigning it to tiling. Restore the
test output settings before exit; retain scratch evidence until reviewed.

Physical qualification is complete only after results are recorded for the
available hardware. Mark unavailable multi-display cases pending, not passed.
Keep tiling opt-in while these checks and renderer limitations remain open.
