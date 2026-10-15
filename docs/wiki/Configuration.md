# Configuration

The file is `$XDG_CONFIG_HOME/rediwm/config.toml`. `REDIWM_CONFIG` overrides
the path. It's written with commented defaults on first run and reloads when
you save. A parse error keeps the previous config. You can also reload with
`rediwm-msg reload`, and check status with `rediwm-msg config`.

## Sections

`[theme]`, `[input]`, `[input_method]`, `[compositor]`, `[region]`, `[animations.*]`,
`[idle]`, `[night_light]`, `[notifications]`, `[desktop]`, `[polkit]`, `[ipc]`,
`[keybinds]`, `[[outputs]]`, `[[autostart]]`, `[[window_rules]]`,
`[[notification_rules]]`, `[[sandbox_allow]]`.

## It's not full TOML

The parser reads a **line-based subset**. Don't run it through a generic TOML
formatter. The rules:

- One `key = value` per line. Arrays on one line too.
- Strings use double quotes and are taken verbatim. No escape processing, so
  `\n`, `\"` and `\u` mean exactly those characters.
- No single-quoted strings, no multiline strings or arrays, no inline tables,
  no arbitrary dotted keys, no dates.
- `#` starts a comment outside double quotes.

```toml
app_id = ["firefox", "chromium"]   # fine
```

## Theme

Colors, text sizes, corner radii and control styling belong in `[theme]`.
See the [complete theme reference](Theme.md) for every supported key and its
built-in default. Appearance preserves these overrides when it saves.

## Region & Language

Settings → Region & Language lets you choose a personal language, regional
formats and time zone. Empty choices inherit the login environment; system
defaults are unchanged. RediWM's interface currently uses English.

Personal clock and calendar preferences apply immediately and are saved in
`[region]`:

```toml
[region]
clock_24h = false
clock_show_seconds = false
clock_show_day = true
first_day_of_week = "sunday"
```

`clock_24h` applies to the taskbar, calendar and built-in lock screen.
`clock_show_seconds` adds seconds to the taskbar time. `clock_show_day` shows
the date line beneath it, using the selected regional format (`formats`, or
the inherited locale). Both lines are centered; hiding the date centers the
time vertically. These two options apply only to the taskbar clock.
`first_day_of_week` accepts any lowercase weekday name, and changes both the
weekday headings and date positions in the taskbar calendar. Existing configs
keep 12-hour time and Sunday first until changed.

## Handy `[compositor]` keys

Settings → Appearance includes **Dock position**, **Dock size** and **Dock hover zoom**.
Choose top, bottom, left or right; side docks stack upright icons vertically.
`dock_position = "bottom"` is the default. `dock_height` controls thickness
(height for top/bottom, width for left/right) from 48 to 96 logical pixels.
`dock_hover_zoom = 1.05` is the default; choose 1.0 to disable enlargement,
or up to 1.5. The setting applies immediately and follows the animation and
reduced-motion preferences. A hovered icon springs slightly past its zoom and
settles back, and dips just under its resting size when the pointer leaves; tune
the bounce with `[animations.dock_hover]` (`damping_ratio = 1.0` removes it).

A dock keeps maximized, tiled and newly placed windows out of its strip, beside
the taskbar's. **Auto-hide dock** (`dock_auto_hide = true`) lets windows use that
space instead: the dock hides, and appears when the pointer reaches the screen
edge it is on (and stays while the pointer is on it or its menu is open). Moving
or resizing a window, or holding a button for an app, never reveals it.

Appearance also sets the dock's look. **Dock opacity** (`dock_opacity`, 0.0 to
1.0) replaces the alpha of the dock's background, whatever colour the theme gives
it; unset, the theme's own applies. **Dock corner radius** is the theme's
`dock_radius` (logical pixels, 1 to 48 in the slider); while that is 0 the dock
uses the windows' corner radius, and Appearance's **Radius** choice resets it
to follow them again. **Highlight active app** (`dock_active_highlight`, off by
default) draws a rectangle behind the focused application's icon; the running
pill under each icon shows either way. A dock icon's tooltip, the window title,
appears after the pointer has rested on it for 1.5 seconds.

Hover enlargement keeps each icon's edge nearest the screen fixed: a bottom
dock's icons grow upward, a top dock's downward, and side docks' toward the desktop.

Pinned apps (`dock_pinned_apps`) can be rearranged by dragging a pinned icon
along the dock; the order is saved. Applications, Files, Terminal, Settings and
running apps that are not pinned keep their places.

**Show Trash** (`dock_show_trash`, on by default) puts a Trash icon at the
dock's far end (right, or bottom on a side dock), past a divider; clicking it
opens the trash in the default file manager. Right-click it to remove it, which
turns the switch off.

A window launched from a dock icon (a pinned app, Files or Terminal) grows out
of that icon into its place. Its timing is `[animations.window_launch]`; with
animations off or reduced motion it opens like any other window.

The taskbar has **Left**, **Center**, and **Right** sections in Appearance.
Start and the window list default to the left, and application tray
icons plus Battery, Network, Volume, and Clock to the right. Drag an item's row
anywhere into any section to reorder or move it (Escape cancels); an empty
section shows where to drop. Up/Down on a focused row handle moves it one step,
into the next section at a section's end. Visibility toggles keep its place.
The center group stays centered on the display when it fits, and shifts or
narrows the window list to avoid the side groups.

For example, `taskbar_items = ["left:start", "left:windows", "right:capture", "right:tray",
"right:battery", "right:network", "right:volume", "right:clock", "-right:power"]` is the default.
Power is off by default on the right; enable it in Appearance to open the same
power menu as the Start menu’s power icon.
Screen capture is enabled by default at the start of the right section and
shows **Stop sharing** while recording or sharing. Move or hide it independently
in Appearance → Taskbar sections. Use `"-right:capture"` to hide it for recordings;
capture continues normally. Hiding it is not recommended because recording and
sharing can continue without a visible indicator or stop button; Settings shows
a warning while it is hidden. Existing lists gain this item enabled on the right.
Use `"-right:clock"` to hide the clock. Existing four-item status lists still
load, preserving their order and visibility alongside Start and the window list.
A theme pack can set the same list in its `[layout]` section
(see `docs/themes.md`); a `taskbar_items` of your own here takes precedence over
the theme's until you choose a theme again. The bar's gap from the screen edge,
length, corner radius and outline are `[theme]` tokens (`docs/wiki/Theme.md`).
Appearance's **Bold clock text** and **Italic clock text** switches style both
time and date (`clock_bold` and `clock_italic` in `[theme]`, or
`[taskbar_theme]` when a separate taskbar theme is selected).

| Key | Default | Notes |
| --- | --- | --- |
| `allow_tearing` | `false` | lets focused fullscreen clients request async presentation |
| `window_tab_apps` | `[]` | app IDs that get tabs |
| `default_file_manager`, `default_terminal` | `""` | desktop IDs, empty means Files / auto terminal |
| `taskbar_position` | `"bottom"` | `top` or `bottom` |
| `dock_position` | `"bottom"` | `top`, `bottom`, `left` or `right`; inside the usable area beside the taskbar |
| `dock_auto_hide` | `false` | `true` hides the dock until the pointer reaches its edge, and frees its strip for windows; `false` reserves it |
| `dock_opacity` | unset | 0.0 to 1.0, the dock background's alpha; unset keeps the theme's |
| `dock_active_highlight` | `false` | `true` draws a rectangle behind the focused app's dock icon |
| `dock_show_trash` | `true` | a Trash icon at the dock's far end that opens the trash in the default file manager |
| `taskbar_items` | Start and window list left, tray/status items right, Power hidden | ordered `section:item` entries; prefix with `-` to hide an item |
| `focus_follows_mouse` | `false` | |
| `canvas_columns`, `canvas_rows` | `3`, `3` | 1 to 10 |
| `mini_map_enabled` | `true` | |
| `mini_map_position` | `"bottom_right"` | `bottom_left`, `bottom_center`, `bottom_right` |
| `mini_map_hide_ms` | `1500` | 500 to 10000 |
| `desktop_icons_fixed` | `true` | |
| `desktop_switch_ms` | `220` | Super+arrow slide, 100 to 3000 |
| `zoom_steps` | `[1.0, 0.85, 0.70, 0.55, 0.40]` | |
| `camera_zoom_min`, `camera_zoom_max` | `0.25`, `1.0` | |
| `focus_zoom` | `"boost"` | `keep`, `boost`, `camera` |
| `window_gap` | `0` | px between snapped windows |
| `snap_to_edges` | `true` | |
| `dodge_file_drags` | `true` | file manager slides aside while you drag a file out |
| `drag_feedback` | `true` | softly lift a window during a move drag; suppressed by reduced motion |
| `drag_scale` | `1.002` | drag lift multiplier, `1.000`–`1.100`; adjustable in Appearance |
| `files_single_click_open` | `true` | Files opens files and folders with one click on their icon in list or icons view |
| `switcher_opacity`, `inactive_opacity` | `1.0` | |
| `terminal_opacity` | unset | 0.0 to 1.0, background alpha of terminals RediWM launches: Foot, kitty, Alacritty, Ghostty and WezTerm (new windows only; text stays opaque). Konsole, GNOME Terminal and other VTE terminals take it only from their own profiles. Unset keeps the opacity of your own terminal configuration. Adjustable in Appearance |
| `inactive_dim` | `true` | windows that are not the focus lose a little brightness and colour; fullscreen windows never dim. Settings, Appearance has the switch |
| `inactive_dim_amount` | `0.08` | 0.0 to 0.5, the fraction of brightness and of colour an unfocused window loses |
| `border_radius` | `10` | Legacy frame radius; `[theme].radius_lg` takes precedence. |
| `xwayland` | `true` | `false` means native only |
| `xwayland_native_scaling` | `false` | sharp X11 on fractional scales, restart needed |
| `xwayland_scale` | `0` | 0 is automatic, 1.0 to 4.0 explicit, restart needed |
| `dark_mode` | `false` | live, goes through the Settings portal |
| `placeholder_delay_ms` | `0` | splash only if the app is this slow to show, 0 disables |
| `wallpaper` | unset | file in `~/.local/share/rediwm/wallpapers`, or a path |
| `lid_close` | `"display_off"` | `display_off`, `lock`, `suspend`, `ignore` |
| `lock_on_suspend` | `true` | |
| `sound_theme`, `sound_enabled`, `sound_disabled_events` | `"freedesktop"`, `true`, `[]` | event sounds, used by `play_sound` |

Drag lift uses a gentle spring around the grab point and returns smoothly on
release. Its timing can be adjusted with `[animations.window_drag]`.

## Outputs

```toml
[[outputs]]
name = "DP-2"
x = -1920              # negative origin is only possible here
y = 0
scale = "auto"         # "auto" or 1 to 3
width = 1920           # optional mode
height = 1080
refresh_mhz = 60000    # omit for the highest at this size
enabled = true
primary = false
transform = "normal"   # normal, 90, 180, 270, flipped variants
night_light = false    # never tint this monitor
gamma = 1.0            # 0.5 to 2.0
```

Omit coordinates for automatic left-to-right placement. Scale and placement
apply live. `REDIWM_SCALE` overrides every output. Changes from Settings,
`wlr-randr`, kanshi or `rediwm-msg output-config` are all saved here.

## Idle and night light

```toml
[idle]
blank_after_seconds = 600    # 0 disables
suspend_after_seconds = 0    # 0 disables

[night_light]
enabled = true
schedule = "always"          # "always", "fixed" or "sun"
temperature = 5000           # 1700 to 10000 K
# fixed: day_temperature, start, end, transition_minutes (0 to 180)
# sun:   latitude, longitude
```

Night light is on by default as a soft warm tint all day.

## Window rules

Matched by glob. For each property the last matching rule wins.

```toml
[[window_rules]]
app_id = ["firefox", "chromium"]
title = "*Picture-in-Picture*"
opacity = 0.9
skip_taskbar = true
focus = false
```

- **Matchers:** `app_id`, `title`, `tag`, `x11_class`, `x11_instance`,
  `backend`, `dialog`, and `exclude_*` versions.
- **Properties:** `output`, `x`, `y`, `center`, `width`, `height`, `maximized`,
  `fullscreen`, `focus`, `depth`, `opacity`, `decorations`, `skip_taskbar`.

To debug a rule, ask the compositor:

```sh
rediwm-msg window-rules 12                       # what matched this window
rediwm-msg match-window-rules --app-id foo       # dry run
```

`tag` comes from the client (xdg-toplevel-tag), so it's metadata, not trusted
identity.

## `[ipc]`

```toml
[ipc]
automation = true   # synthetic input and screen capture. Restart required
```

Read once at startup. Details on [IPC](IPC.md).

## `[polkit]`

```toml
[polkit]
enable = true
helper_socket = "/run/polkit/agent-helper.socket"
```

## `[[autostart]]`

```toml
[[autostart]]
cmd = "nm-applet"    # one entry per program
```

## `[[sandbox_allow]]`

See [Protocols and Sandboxing](Protocols-and-Sandboxing.md).
