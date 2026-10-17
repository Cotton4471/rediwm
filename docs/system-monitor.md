# System Monitor

Open **System Monitor** from the launcher, with **Ctrl+Alt+Del**, or by
running `rediwm-monitor`. The shortcut restores and focuses an existing
window, including one on another workspace.

CPU and RAM summaries have 60-second graphs. System RAM usage is
`MemTotal - MemAvailable`; process memory is resident memory. A process
using one CPU core reads 100%, so multithreaded processes can exceed 100%.
New processes and the first sample after resuming show an em dash until
there is a second CPU measurement. Unavailable data also shows an em dash.
Nonlocal account names fall back to their numeric UID.

The list starts with your processes, sorted by CPU usage. Click a column to
sort; click again to reverse. **My processes / All processes** changes the
ownership filter. Search matches names, PIDs and users. Selection follows
the PID and start time as rows move; refreshes preserve the scroll offset.

**End process** sends SIGTERM. **Force quit** requires confirmation naming
the target before sending SIGKILL. Both actions recheck identity, ownership
and essential RediWM session protection at execution, including after a
confirmation has been open. Signals use a validated pidfd. Other users'
processes can be viewed where `/proc` permits but cannot be managed here.
The monitor never requests elevated privileges.

| Key | Action |
| --- | --- |
| Ctrl+F | Focus search and select its text |
| Up / Down | Select a process; leave search for the list |
| Page Up / Page Down | Move by a visible page |
| Home / End | First / last process when outside search |
| Tab / Shift+Tab | Navigate controls |
| Enter / Space | Activate the focused control |
| Delete | End selected process |
| Shift+Delete | Open Force quit confirmation |
| Escape | Cancel confirmation or clear search |
| Ctrl+Q / Ctrl+W | Close |

Collection runs once per second in a worker in the monitor process.
**Pause updates** and minimizing suspend collection; restoring respects the
pause setting. Losing keyboard focus does not suspend collection. The
worker blocks without periodic wakes when paused or minimized. Closing
cancels collection and joins it. Minimize signaling uses xdg-shell v6's
`suspended` state, supplied by RediWM; other compositors must support that
state for minimize suspension. Live themes use filesystem notifications.
Fractional scaling uses fractional-scale-v1 and viewporter when available.

## Existing shortcut configuration

Both presets now use `open_system_monitor`. Explicit user bindings are
preserved. For an older canvas config containing
`"ctrl+alt+delete" = "poweroff"`, replace that line in
`~/.config/rediwm/config.toml`:

```toml
[keybinds]
"ctrl+alt+delete" = "open_system_monitor"
```

For explicit workspace overrides, use the existing section:

```toml
[keybinds.workspace]
"Ctrl+Alt+Delete" = "open_system_monitor"
```

Shortcut inhibition and lock/greeter rules still apply. The app gets its
own application scope when scope management is enabled.

## Building and testing

`zig build` installs the app, desktop entry and icon in the build prefix.
`zig build monitor` builds just those files. The session installer includes
them too. `zig build test-monitor` tests accounting, collection, identity,
process actions, the list model and worker lifetime.

`python3 tests/system_monitor.py` exercises both desktop modes in private
headless compositors; repeat with `REDIWM_TEST_SCALE=1.5`. All action targets
are disposable test children. See [TESTING.md](../TESTING.md).

Accounting follows the [Linux proc documentation](https://docs.kernel.org/filesystems/proc.html);
actions follow the [pidfd signal contract](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html).
