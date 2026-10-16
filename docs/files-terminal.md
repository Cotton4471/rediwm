# Files terminal

F4 and the bottom-right terminal button toggle a drawer in normal Files
windows. The sidebar keeps its full height. Drag the drawer's upper divider
to resize it. Height is remembered; a new window always starts with the drawer
hidden and creates a fresh shell only when opened. Choosers have no drawer.

Opening focuses the terminal. Clicking the file list, toolbar or sidebar
restores Files shortcuts. F4 works in either focus and never repeats; other
keys, including Escape, Ctrl+C/D/Z, Alt combinations and key repeat, go to the
terminal while focused. Modal dialogs take precedence and preserve focus.
Ctrl+Shift+C/V copies or pastes. Drag to select; Shift selects locally when an
application enables terminal mouse reporting. Wheel/scrollbar browse history;
typing returns to the live screen. Shift+PageUp/PageDown scroll by a page.

The drawer uses the configured monospace font, shared font fallback, app text
size, terminal palette tokens and app foreground/background fallbacks. It
uses the normal panel animation and reduced-motion setting. It reserves 48
pixels for the file list (less the horizontal scrollbar) and needs at least
96 pixels for its header and terminal. Very small windows temporarily hide
it and return input to Files, retaining the shell and preferred height.

## Shells and folder following

The shell is a valid executable absolute `$SHELL`, otherwise the account's
shell, otherwise `/bin/sh`. It is interactive, with a controlling PTY and
normal job control. Bash loads its system startup configuration normally and
the user's `~/.bashrc` through an anonymous, session-only rcfile. No startup
file is changed. A private loadable builtin is loaded for this session only;
if it cannot load, the shell remains usable without automatic following.
Other shells use their normal interactive startup configuration.

| Shell | Initial directory | Automatic following |
| --- | --- | --- |
| Bash | Current real folder | Session builtin; qualified on Bash 5.3 with Readline 8.3 |
| Fish | Current real folder | Unavailable |
| Zsh and other shells | Current real folder | Unavailable; not separately qualified |

Bash following uses an inherited `SOCK_SEQPACKET` socket, separate from
terminal output. Files accepts status only with the launched shell's kernel
credentials. The shell checks its peer's credentials and makes its channel
close-on-exec before sourcing the user's rcfile. There is no listening socket,
polling timer, signal-as-command transport or synthetic `cd` text.

The builtin waits for terminal input and the socket together at Readline's
input hook. It applies the latest directory request only at a primary prompt,
with an empty line and no search, completion, key sequence, macro or builtin
read in progress. Paths are bounded data passed directly to Bash's `cd`
builtin with `--`; quotes, newlines and Unicode are preserved. Bash validates
the directory and maintains PWD/OLDPWD. Failed changes are acknowledged and
displayed without restarting the shell. The user's prompt is re-expanded
after a successful change; prompt commands and traps are preserved.

While editing, running a command, inside a nested/remote shell or a
multiplexer, following waits for the owned Bash prompt. Background jobs are
reported too. Only the newest navigation request is retained. The header
shows the shell's reported directory and whether following is pending or
unavailable. Shell navigation never navigates Files. Recent, Trash and
archive views retain the last real folder, falling back to Home.

## Terminal contract and lifetime

Files statically embeds upstream libvterm **0.3.3**, pinned by URL and Zig
content hash in `build.zig.zon`. Distro libvterm packages are not used. GNU
Readline development files build the Bash builtin; Bash's loadable-builtin
loader rejects unavailable symbols. The installed helper and builtin are
`bin/rediwm-files-terminal` and `lib/rediwm/files-bash.so`, beside the Files
installation. The libvterm license is installed under `share/licenses/rediwm`.

The advertised contract is `TERM=xterm-256color` with the distribution's
ncurses xterm-256color terminfo, and `COLORTERM=truecolor`. Supported features
include ANSI/256/RGB colours, bold, synthetic italic, underline, strike,
reverse/conceal, cursor visibility/shapes, application cursor keys, alternate
screen, bracketed paste, focus reporting and terminal mouse modes. Wide cells,
combining characters (up to libvterm's six codepoints per cell) and font
fallback are retained. Cursor and blinking text are steady: there is no blink
timer. Graphics protocols, hyperlinks, desktop clipboard escape sequences and
program-launch escape sequences are not exposed. In particular OSC 52 cannot
read or write the Wayland clipboard, and OSC output cannot authorize following.

Scrollback stores at most **4,096 physical rows and 8 MiB**, whichever comes
first. Wrapped-row metadata controls selection copying. Resize clips/pads
physical rows, without reflowing old history. Scrolled-back reading stays in
place as output arrives, until the retained history limit evicts it. Selection
is cleared on a column-count change. The grid is capped at 512 by 512 cells.

PTY reads and writes have a **64 KiB budget per event-loop iteration**. Input
has a **1 MiB** queue; larger/full-queue pastes are refused with a notice.
Writes handle partial progress and EAGAIN, and request POLLOUT only while
queued. Pasted ESC/control bytes are filtered to prevent terminating a
bracketed paste; tabs and line endings are retained. Hidden sessions continue
parsing with bounded history and add no paint or cursor timer wakeups.
Allocator failures release the emulator's tracked allocations and fail that
session without taking down Files.

A fresh helper process performs PTY setup and exec; Files never runs unsafe
library code in a forked child of its multithreaded process. On native login,
the helper places the shell in a separate transient app.slice scope before
executing startup files. Placement is best effort, like compositor app scopes.
Nested/headless sessions skip it unless `REDIWM_APP_SCOPES=1` explicitly forces
it. The compositor publishes its resolved setting to app clients through this
existing flag, while continuing to strip private supervisor authority. PIDfds
join the existing poll loop for exit notifications and reaping.

Hiding keeps the session alive. After exit or failure the screen/error remains
with a Restart action. Every live shell requires confirmation on Files close,
including hidden sessions: an earlier status snapshot cannot prove no job has
started since. Cancel preserves the session. Confirm sends hangup to this
session, then uses bounded asynchronous cleanup and pidfds to kill/reap it if
necessary. Remaining members of the owned PTY session are ended when its shell
exits; intentionally detached `setsid` processes are independent. A Files crash
closes its PTY with ordinary terminal hangup semantics; session survival is not
promised.

Open external terminal uses `[compositor] default_terminal`, preserving its
desktop-entry arguments, theme handling, app scope and working directory.
A missing preference falls back to `$TERMINAL` or `foot`. It creates an
independent session in Files' current real folder; existing jobs stay in the
drawer. Changing the default terminal affects only this external action.

## Validation

`zig build test-files-terminal` runs the Files units and an isolated headless
suite with scratch HOME/XDG paths, disabled device enumeration, no host bus
and no host app scopes. `REDIWM_TEST_SCALE=1.5` repeats at fractional scale.
Unit fixtures cover chunked UTF-8/escape sequences, wide/combining cells,
alternate screen, key/mouse/paste encoding, OSC policy, history bounds,
allocator failures, preferences, viewport geometry, focus and chooser guards.
The PTY fixture exercises empty/partial/busy prompts, coalescing, unusual paths,
failed directory changes, nested shells, jobs, partial writes and full-screen
tools. UI checks cover the held F4 toggle, keyboard input, hidden continuity,
navigation, divider preferences, idle wakeups, independent windows and close.
The drawer also stays live through workspace slides, tiled/canvas size changes
and minimize/restore, including the fractional-scale run.

Physical output moves and real fcitx5/IBus candidate windows remain manual
qualification, as for the other app clients. Terminal text-input-v3 handles
bounded UTF-8 commits and local preedit; it advertises no editable surrounding
terminal output and rejects deletion requests. No compositor exception is used.
