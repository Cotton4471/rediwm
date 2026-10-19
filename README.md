# RediWM

<div align="center">
<img width="1085" height="233" alt="redi-logo" src="https://github.com/user-attachments/assets/4e80c572-bd30-4800-bcf3-acb95299358d" />


### A Wayland compositor with its own desktop shell, built in Zig

</div>   

RediWM is a single process [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) compositor
that draws its whole shell itself: taskbar, start menu, settings, lock and login
screens, notifications and OSDs, all in one process, benchmarked against
[labwc](https://labwc.github.io/) to stay as lean (192mb idle ram usage, <1% CPU usage)



https://github.com/user-attachments/assets/34c20760-f1ec-4776-a00b-063e3c8a5ffb



## Features

- **One process, not a stack:** no waybar, greeter, launcher or notification
  daemon to wire up.
- **Pan-and-zoom desktop:** a canvas several screens wide; zoom the desktop or
  single windows.
- **Lock and login screens** with PAM, plus `rediwm-dm`, a small display manager.
- **Notification daemon** with actions, images and do-not-disturb rules.
- **Sharp X11 apps on HiDPI** through Xwayland native scaling.
- **GPU glass** behind shell surfaces, re-blurred only when needed.
- **Works with wlroots tools:** wlr-randr, kanshi, swaylock, swayidle, grim,
  wf-recorder, wayvnc, docks.
- **JSON IPC** (`rediwm-msg`), desktop icons, a file manager and an image viewer.
- **Crash-resilient:** bounded restarts and layout autosave.

## Installing

```sh
curl -fsSL https://rediwm.redios.org/install.sh | sh    # add `-s -- --dm` for rediwm-dm
```

## Themes and screenshots

|  |  |
| :---: | :---: |
| <img width="100%" alt="Screenshot 1" src="https://github.com/user-attachments/assets/b4cbd48c-ccab-452e-8457-2d1b8c096def" /> | <img width="100%" alt="Screenshot 2" src="https://github.com/user-attachments/assets/10f9becc-bcd9-4089-872b-4a03d1dba818" /> |
| <img width="100%" alt="Screenshot 3" src="https://github.com/user-attachments/assets/a0ccd5f3-7476-4171-80c5-5f74a751e6b7" /> | <img width="100%" alt="Screenshot 4" src="https://github.com/user-attachments/assets/dd0cdae7-4c4d-401c-9624-80895897d0de" /> |

`scripts/install.sh` installs the prebuilt release for your distro (Arch
and derivatives such as Artix and CachyOS, Debian, Ubuntu and Fedora).
Installing never replaces your login manager

## Building and running

Requirements: Zig 0.16, wlroots 0.20, and the development files for Wayland,
wayland-protocols, xkbcommon, pixman, FreeType, HarfBuzz, Fontconfig,
librsvg/GdkPixbuf, PangoCairo, libinput, PAM, libpulse, libpipewire-0.3, Poppler GLib,
libseccomp, libarchive, libjpeg, libpng, libwebp and GNU Readline. Files embeds
the pinned libvterm 0.3.3 source (downloaded by Zig; no system libvterm needed). Optional:
Xwayland, `foot`, `brightnessctl`, `gio`/`xdg-open`, `git` (optional).

Printer support uses an existing CUPS server (`cups`).

Run from a checkout, `scripts/install.sh` builds that checkout (dependencies,
then `install-session.sh` with the arguments you give it).

```sh
zig build run -- foot                     # nested in your current Wayland session
zig build -Doptimize=ReleaseSafe          # for daily use and measurements
sh scripts/install-session.sh             # install and restart the running session
sh scripts/install-session.sh --no-restart --dm   # install only, plus rediwm-dm
```
 
## Using it

| Keys | Action |
| --- | --- |
| Super+Space | centered app launcher |
| Super+T / E / B | terminal / Files / browser |
| Super+Q, Super+F, Super+M | close, fullscreen, maximize |
| Super+arrows | slide to the neighbouring desktop |
| Super+Ctrl+arrows | focus the window in that direction |
| Alt+Tab | window switcher |
| Super+1…5, Super+=/-/0 | window zoom |
| Super+Shift+=/-/0 | desktop zoom |
| Super+L | lock |
| Ctrl+Shift+S, Print | region / full-screen screenshot |
| Super+Z | undo the last window move or resize |
| Super+Shift+E | quit |

Canvas bindings live in `[keybinds]`; `"noop"` disables one.

## Protocols

Beyond xdg-shell, layer-shell and Xwayland:

| Area | Protocols | Works with |
| --- | --- | --- |
| Displays | `wlr-output-management-v1`, `xdg-output-v1` | wlr-randr, kanshi, nwg-displays |
| Window lists | `wlr-foreign-toplevel-management-v1`, `ext-foreign-toplevel-list-v1` | docks, waybar, rofi/fuzzel, wlrctl |
| Capture | `wlr-screencopy-v1`, `ext-image-copy-capture-v1` | grim, wf-recorder, OBS, xdg-desktop-portal-wlr |
| Locking and idle | `ext-session-lock-v1`, `ext-idle-notify-v1`, `idle-inhibit-v1` | swaylock, gtklock, swayidle |
| Remote input | `virtual-pointer-v1`, `virtual-keyboard-v1` | wayvnc, KDE Connect, wtype |
| Input | `text-input-v3`, `input-method-v2`, `relative-pointer-v1`, `pointer-constraints-v1`, `keyboard-shortcuts-inhibit-v1`, `pointer-gestures-v1`, `cursor-shape-v1` | fcitx5, IBus, games, virt-manager |
| Window metadata | `xdg-toplevel-tag-v1`, `content-type-v1`, `xdg-activation-v1` | window rules, content hints, authorized activation |
| Colour | `color-management-v1`, `color-representation-v1` | renderer-supported colour spaces and pixel representations |
| Presentation | `tearing-control-v1`, `drm-lease-v1` | opt-in fullscreen tearing, DRM-connected VR headsets |
| Rendering | `fractional-scale-v1`, `viewporter`, `single-pixel-buffer-v1`, `linux-dmabuf-v1`, `linux-drm-syncobj-v1`, `presentation-time` | |
and more 
 
## Configuration

`$XDG_CONFIG_HOME/rediwm/config.toml` (`REDIWM_CONFIG` overrides) is written with
commented defaults on first run and reloads on save; a parse error keeps the
previous config. 
Sections: 
`[theme]`
`[input]`
`[input_method]`
`[compositor]`
`[region]`
`[idle]`
`[night_light]`
`[notifications]`
`[desktop]`
`[polkit]`
`[ipc]`
and more


Window rules match by globs; for each property the last matching rule wins:

```toml
[[window_rules]]
app_id = ["firefox", "chromium"]
title = "*Picture-in-Picture*"
opacity = 0.9
skip_taskbar = true
focus = false
```

Matchers: `app_id`, `title`, `x11_class`, `x11_instance`, `backend`, `dialog`
and `exclude_*`. Properties: `output`, `x`, `y`, `center`, `width`, `height`,
`maximized`, `fullscreen`, `focus`, `depth`, `opacity`, `decorations`,
`skip_taskbar`.

## IPC

The socket is `$XDG_RUNTIME_DIR/rediwm-<WAYLAND_DISPLAY>.sock` (or
`REDIWM_SOCKET`), in a private directory only. `rediwm-msg` wraps it
(`rediwm-msg outputs`, `output-config DP-1 --scale 1.5`, `notifications`, …);
`src/ipc/protocol.zig` is the reference. Synthetic input and pixel reads need
`[ipc] automation = true` (or `REDIWM_IPC_AUTOMATION=1`), and everything is
refused while locked.

IPC v1 is UTF-8 JSON, one request and one response per newline. Every request
uses this envelope (command names are case-sensitive snake_case):

```json
{"version":1,"id":1,"command":"windows"}
{"version":1,"id":2,"command":"move_cursor","params":{"x":100,"y":200}}
```

## More

- [SECURITY.md](SECURITY.md): security boundaries and decisions.
- [TESTING.md](TESTING.md): unit and headless integration tests.
- [D-Bus transport](src/dbus/README.md) and [polkit agent](src/polkit/README.md).
- Fonts: Manrope and JetBrains Mono (OFL); cursors:
  [phinger-cursors](https://github.com/phisch/phinger-cursors) (CC BY-SA 4.0).

## License

RediWM's own code is dual-licensed under either of

- [Apache License, Version 2.0](LICENSE-APACHE)
- [MIT license](LICENSE-MIT)

at your option. Unless you explicitly state otherwise, any contribution
intentionally submitted for inclusion in RediWM by you, as defined in the
Apache-2.0 license, shall be dual-licensed as above, without any additional
terms or conditions.

Bundled third-party assets keep their own licenses: the fonts under
`assets/fonts` (SIL OFL 1.1) and the cursors under `assets/cursors` (CC BY-SA 4.0).
