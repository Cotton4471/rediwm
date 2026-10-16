# Files terminal drawer plan

Status: draft, 2026-10-16. Implementation starts with Phase 0 below.

Add a terminal drawer beneath the file list, opened with F4 or a small
terminal icon at the bottom right. Embed libvterm in the Files process and
connect it to the user's shell through a pseudoterminal (PTY). Files owns
the drawer, terminal rendering, input, scrollback, and shell session.

The primary design priority is compositor stability. Keep terminal behaviour
inside Files, presented through its existing Wayland window. Terminal
hosting protocols and special cases in compositor focus, stacking,
projection, tiling, and window lifetime are outside this feature's scope.
Shared UI additions must preserve their existing callers' behaviour.

The drawer slides upward, resizes from its top edge, and follows the Files
window when it moves or resizes. Folder navigation updates the shell's
directory only when it is safe to do so. Hiding the drawer preserves the
session and running commands.

## User experience

```text
┌──────────────┬─────────────────────────────────┐
│              │  Folder path / toolbar          │
│  Places      ├─────────────────────────────────┤
│              │                                 │
│  Home        │  Files and folders              │
│  Documents   │                                 │
│  Downloads   ├──────── drag to resize ──────────┤
│              │  >_ Terminal    ~/Projects   ▾  │
│              │  alex@desktop:~/Projects $      │
│              │                                 │
│              ├─────────────────────────────────┤
│              │  24 items                  [>_] │
└──────────────┴─────────────────────────────────┘
```

The sidebar remains full height. The drawer occupies the file-list column,
above the existing status bar. Its header shows the terminal icon, the
shell's actual directory when known, and a collapse control. Use shared
buttons, icons, separators, and theme tokens. Use the existing terminal
palette tokens, app palette fallbacks, and configured monospace font. The
embedded terminal uses the user's shell configuration; settings from their
external terminal application are not automatically imported.

* **Open and hide:** F4 and the status-bar button toggle visibility. Opening
  focuses the terminal; hiding returns focus to the file list. The tooltip
  is "Terminal · F4", and the visible drawer gives its button an accent
  highlight. F4 fires once per press and also works with terminal focus.
* **Initial size:** start at approximately one-third of the space below the
  Files toolbar. Persist the requested height, clamp it to the current
  window, and retain usable file-list space and terminal rows. Set exact
  minimums after testing compact windows in the prototype. A temporary
  clamp must not overwrite the user's preferred height.
* **Resize:** the top separator has a generous pointer target, vertical
  resize cursor, and shared hover treatment. Dragging changes height
  directly. Outer window resizing changes both the terminal's width and
  available height. Recompute the cell grid and notify the PTY only when
  rows or columns change.
* **Motion:** use the existing panel-slide curve and reduced-motion setting.
  Reversing a toggle continues from the current position. Painting and hit
  testing follow the same visible boundary throughout the slide.
* **Session:** create one terminal session lazily per Files window. Preserve
  it while hidden. Show a restrained launch/error state and a Restart action
  after the terminal exits. Newly opened Files windows start with the drawer
  hidden; remember height, not a previous shell process.
* **Focus:** clicking the file list or sidebar restores Files input. Terminal
  shortcuts and Escape reach the terminal while it is focused, except for
  the explicitly reserved drawer toggle and existing compositor shortcuts.
  Modal Files dialogs take precedence and restore the prior focus on close.

The drawer belongs to normal Files windows. Open/Save/folder chooser dialogs
do not expose it. Include an Open external terminal action using the configured
default terminal, starting a separate session in the current real folder.
Tabs and multiple embedded terminal sessions can follow later.

## Following the current folder

The selected behaviour is to follow Files when the shell is idle, preserving
running commands and partly typed input. Opening starts in the displayed
real directory. Recent, Trash, and archive views retain the last real
directory; if none exists, use the user's home directory.

Navigation publishes a desired directory. Shell integration applies it only
at a safe editing point with an empty command line. While busy or editing,
retain only the latest requested directory and show that following is
pending. Revalidate the request before applying it, and acknowledge the
actual directory afterward. Handle paths that disappear or become
inaccessible without restarting the shell.

Implement this through an explicit shell integration channel. Do not infer
readiness from silence, a window title, or the foreground PID alone, and do
not type a synthetic `cd` command into the terminal. A prompt callback alone
does not prove that the current command line is empty. Phase 0 must prove a
safe mechanism for the first supported shell before automatic following is
claimed. Pass paths as data, including spaces, quotes, newlines, and Unicode.

Shell integration is installed for the launched session without overwriting
the user's startup files. Preserve their startup configuration. Use an
authenticated local channel with bounded messages and explicit session
lifetime, separate from terminal output. Output from a command must not be
interpreted as permission to execute a directory change. Phase 0 establishes
the shell bootstrap and how integration waits for and services requests
without polling or disrupting line editing.

Qualify Bash, Zsh, and Fish separately. Unsupported shells still open in the
correct initial folder, but show that automatic following is unavailable.
For those shells, offer opening an external terminal in the current folder.
A shell reporting its own directory changes updates
the header; it does not automatically navigate Files. Remote shells and
terminal multiplexers suspend following unless explicitly supported.

## Existing code to extend

| Area | Existing entry points | Planned responsibility |
| --- | --- | --- |
| Files state | `src/files/app.zig`, `app_model.zig` | Terminal session, visibility, requested height, focus restoration |
| Files controller | New `src/files/app_terminal.zig` | Drawer actions, lifecycle events, folder-follow state |
| Terminal engine | New `src/files/terminal/` modules | libvterm wrapper, PTY session, rendering, scrollback, input, shell integration |
| Layout and painting | `app_layout.zig`, `app_scroll.zig`, `app_paint.zig` | Drawer geometry, file viewport and scrollbars, header and status button |
| Files input and event loop | `app_keyboard.zig`, `app_pointer.zig`, `main.zig` | Toggle, terminal input, clipboard, PTY readiness, child exit |
| Preferences | `src/files/preferences.zig` | Height persistence with migration from existing formats |
| Shared divider | `src/ui/widgets/splitter.zig` | Horizontal divider support alongside the existing vertical divider |
| External terminal launch | Existing default-app resolution and launch helpers | Explicit external action with configured desktop ID and existing fallback rules |
| Process lifetime | `src/session/app_scope.zig` and existing child tracking | Separate shell app scope, session ownership, exit handling |
| Build | `build.zig` and dependency/install documentation | libvterm dependency for Files and its tests |

`contentBottom()` currently derives the file viewport from the footer and
horizontal scrollbar. Extend that shared geometry so selection, scrolling,
drop targets, edge shadows, and keyboard navigation all stop above the
drawer. Keep App method bodies in concern files with aliases in `app.zig`.

## Terminal architecture

[libvterm](https://www.leonerd.org.uk/code/libvterm/) provides terminal
emulation independently of a graphics toolkit. Files supplies the PTY,
rendering, history storage, and user interaction around it. Keep the wrapper
and session code in Files modules, and link the library into Files and its
test targets. Phase 0 pins the supported dependency version, packaging
requirements, and terminal capabilities.

### Shell and PTY

Select the user's shell from a valid absolute `$SHELL`, then their account
shell, with a documented fallback. Start an interactive session in the
resolved directory. Set up the controlling terminal, process/session groups,
initial window size, inherited environment, and file descriptors explicitly.
Advertise only a verified `TERM`/terminfo combination; qualify colour support
and full-screen applications against that contract.

Files is already multithreaded. Use a safe spawn/helper design for PTY setup
and exec; avoid allocation or other unsafe library work in a forked child.
Place the shell in its own app scope through `app_scope.place`, preserving
the existing nested/headless policy. Shell descendants must not inherit
Files' app scope merely because Files launched them. Reuse or extract the
client-safe launch helpers needed for this without importing compositor
runtime modules into Files.

Use nonblocking reads and queued writes with partial-write handling. Integrate
PTY readiness and child-exit notifications with the existing event loop.
Give each loop iteration a bounded parsing budget so continuous output does
not starve Wayland dispatch, file navigation, or close actions. Poll for
writability only while bytes are queued; apply backpressure to large pastes.

### Screen rendering and scrollback

Wrap libvterm's screen and output callbacks with explicit allocator ownership
and cleanup. Draw the terminal cell grid through the existing Cairo pipeline,
using monospace metrics, theme terminal colours, and a clipped content rect.
Support attributes, cursor modes, alternate screen, wide characters,
combining characters, and font fallback. Confirm these behaviours against
the chosen library version rather than assuming every terminal extension is
implemented.

Own a bounded scrollback ring with both line and byte limits. Define wrapped
line metadata, selection across history, and resize/reflow behaviour in the
prototype. Preserve scrolled-back reading position as output arrives, and
return to the live screen on user input. Reuse the shared scrollbar.

Translate changed cells, cursor movement, and selection changes into Files
damage. Publish through the existing buffer-history path and never paint a
busy shm buffer. Coalesce output bursts into available frames. Hidden or
unmapped drawers continue draining and parsing the PTY with bounded history,
but schedule no terminal paint or cursor-blink frames. Cursor blinking, if
enabled, uses deadlines only while visible and focused. With a steady cursor
and no I/O, the terminal adds no idle wakeups.

### Input and resizing

Add terminal focus within Files and route keys before file-management
shortcuts, after modal UI and plain F4. Use libvterm's input encoding for
special keys and terminal modes. Preserve Ctrl+C, Ctrl+D, Ctrl+Z, Alt keys,
key repeat, compose/dead keys, and text input. Audit Files' existing text-input
support and implement any missing client-side IME handling needed for the
drawer; this must not require a compositor exception.

Support selection, Ctrl+Shift+C/V, bracketed paste, and terminal mouse
reporting. Provide Shift as the local selection override when an application
captures the mouse. Clipboard data goes through the existing Wayland transfer
code. Terminal escape sequences must not silently read or write the desktop
clipboard or launch programs; define the supported OSC policy explicitly.

Keep the cell grid consistent with the current drawable bounds and notify
libvterm and the PTY when its dimensions change. Coalesce updates to a frame,
avoid zero-sized PTYs while collapsed, and preserve the last usable grid
while hidden. The slide and file layout share one animation state, including
reversal and reduced motion. Resizing must preserve terminal state and keep
full-screen applications usable without stretching raster text.

## External terminal action

Open external terminal uses `[compositor] default_terminal` and existing
fallback rules. Preserve desktop-entry arguments, theme handling, app scopes,
and working-directory semantics through client-safe launch helpers. It starts
a new independent session; it does not transfer the embedded shell or its
running jobs. Changing the default terminal affects this action, while the
embedded session continues using its selected shell.

## Session lifetime and failures

Track starting, running, exited, and failed session states separately from
drawer visibility. Hiding while starting must not steal focus on completion.
Handle PTY EOF/hangup and child exit in either order, drain remaining output,
and keep the last screen with exit status and a Restart action. Avoid
automatic restart loops and stale callbacks after destruction.

Normal Files close offers confirmation when a command or shell job is known
to be active, or when activity cannot be established safely. Include hidden
sessions in that check. Cancellation preserves the window and session.
After confirmed close, end the owned PTY session, reap the shell, and release
its integration channel and history. Use bounded asynchronous cleanup and
session-specific ownership; never kill processes by executable name.
Shell integration should report background jobs as well as foreground work.

An unexpected Files crash loses the embedded terminal and closes its PTY;
jobs may receive a hangup according to normal terminal semantics. Session
survival requires an explicit multiplexer or future supervisor and is not
promised by this design. Failure handling must remain within the Files
application and its shell session.

## Implementation phases

### Phase 0 Prove libvterm and shell coordination

- [ ] Pin the library version and dependency delivery, compile a Files-only
  prototype, and record the tested shell and terminfo configuration.
- [ ] Prove safe PTY launch, app-scope placement, Cairo rendering, keyboard
  input, grid resize, alternate screen, Unicode, and shell exit.
- [ ] Establish scrollback and reflow behaviour; measure continuous-output
  responsiveness and memory limits before choosing the final loop budgets.
- [ ] Prove folder following with an empty prompt, partial input, a running
  command, and rapid navigation. Qualify the shell integration transport.
- [ ] Record capability limits and lifecycle decisions before UI polish.

### Phase 1 Add terminal engine and process lifetime

- [ ] Implement the libvterm wrapper, PTY session, bounded input/output work,
  child tracking, app scopes, and cleanup.
- [ ] Implement cell rendering, scrollback, selection, cursor, colours, and
  damage through the Files buffer pipeline.
- [ ] Add terminal input encoding, compose/IME, clipboard, bracketed paste,
  mouse reporting, and the supported escape-sequence policy.

### Phase 2 Build the Files drawer

- [ ] Add controller state, F4, the status icon, header, and launch/exit/error
  states using shared UI controls.
- [ ] Extend the splitter, viewport geometry, scrollbars, hit testing, and
  height preference migration.
- [ ] Add slide animation, reversal, reduced motion, compact layouts, and
  correct focus restoration.

### Phase 3 Add directory following and lifecycle polish

- [ ] Add the qualified shell integration and coalesced desired-directory
  requests, acknowledgements, and actual-directory display.
- [ ] Handle virtual locations, inaccessible paths, unsupported shells,
  nested shells, remote sessions, and multiplexer behaviour explicitly.
- [ ] Complete close-with-command/job, PTY hangup, shell exit/restart,
  launch failure, and hidden-session behaviour.
- [ ] Add Open external terminal with existing default-app resolution and
  explicit independent-session behaviour.

### Phase 4 Validate and document support

- [ ] Extend existing unit suites for geometry, preference migration,
  lifecycle, focus routing, and directory-request state where appropriate.
  Add terminal fixtures for chunked escape sequences, Unicode cells,
  scrollback bounds, partial writes, resize, and allocation failures.
- [ ] Add a focused Files terminal headless suite with an isolated shell and
  deterministic PTY fixtures. Test two Files windows for independent state.
- [ ] Exercise supported shells, copy/paste, dead keys, IME, selection,
  scrolling, mouse modes, and full-screen tools such as `vim` and `top`.
- [ ] Check rapid toggles, divider dragging, outer-window resizing, delayed
  buffer release, grid/list modes, horizontal overflow, modal dialogs,
  workspace slides, minimize/restore, output moves, and fractional scale.
- [ ] Check launch/close/crash races, shell jobs, capture, idle wakeups,
  hidden-session continuity, and memory bounds under sustained output.
  Verify Files navigation and normal compositor interactions remain responsive.
- [ ] Build Debug and `-Doptimize=ReleaseSafe`; run `zig build test`,
  `zig build test-files`, the terminal integration suite, and relevant Files
  controls/decoration/browser and dead-key suites. Exercise normal focus,
  workspace, and minimize behaviour with the drawer open. Review shared UI
  changes against their existing callers.
  Compare existing failures with a separate HEAD worktree before identifying
  regressions.

Follow `TESTING.md`: use isolated headless sessions and temporary home/XDG
directories, set `REDIWM_FILES_DEVICES=0`, and keep shell commands and test
files inside scratch directories. Document the supported libvterm version,
terminal capabilities, shell-integration matrix, and external-terminal action
with the completed feature.
