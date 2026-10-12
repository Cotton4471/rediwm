# Theme packs

Choose a pack in **Settings → Appearance → Theme**. Changes to colours,
fonts and geometry are stored as overrides of that pack. **Reset to theme**
clears those overrides; choosing a different pack also resets its wallpaper
and cursor. Picking a wallpaper afterward pins that choice until the next
pack switch. **Icon theme** chooses the installed icon theme behind a pack's
own icons (the pack's `icon_theme`, when specified, takes precedence).

**Install theme…** accepts a `.rediwm-theme` or `.zip` file. **Remove** is
available for user-installed packs and switches an active pack to RediWM Dark.
An existing pack requires **Replace installed theme**. **Save look…** saves
the current colours, geometry, wallpaper and logo as an installed pack and a
shareable archive; use a lowercase filename such as `my-look.rediwm-theme`.
Files installs `.rediwm-theme` files when opened and reports the result.

A pack is a directory. Archives contain that directory's files at their root,
or one enclosing directory. No code, bundled fonts or shaders are accepted.

```text
my-look/
  theme.toml
  preview.png            optional, at most 512×320
  logo.svg               optional; logo.png also works
  wallpapers/            PNG, JPEG or WebP
  glyphs/                monochrome SVGs, named like assets/icons/
  icons/                 flat freedesktop names, SVG or PNG
  cursors/
    index.theme          optional built Xcursor theme
    cursors/
```

```toml
[meta]
format = 1
id = "my-look"            # lowercase a–z, digits and hyphens; at most 64
name = "My look"
version = "1.0"
author = "Example"
license = "CC0-1.0"
description = "A blue desktop."

[theme]
accent = "#88c0d0"
start_button_icon = "logo.svg"

[assets]
wallpaper = "night.png"   # inside wallpapers/
color_scheme = "dark"    # dark or light
icon_theme = "Adwaita"    # optional installed theme, behind icons/
cursor_theme = "pack"    # cursors/, or an installed cursor-theme name
```

`[taskbar_theme]` optionally supplies the taskbar's own colours. Unknown
`[theme]` tokens are logged and skipped. Relative asset paths stay inside the
pack; absolute paths, `..` and symlinks are refused. The only symlink exception
is a cursor alias in `cursors/cursors/` whose target is a regular cursor file
in that same directory.

The user's configuration names the pack and just its personal edits:

```toml
[theme]
base = "my-look"
font_size = 14
```

Resolution is defaults → pack → config overrides → `REDIWM_THEME`. A missing
or broken pack falls back to defaults. Configurations without `base`, and
legacy single-file presets in the config directory's `themes/`, still work.
Files and Images resolve the same layers; PDF freezes them before sandboxing.
A pack is read on startup, config reload or apply; no pack directories are
watched and no additional polling is introduced.

Discovery uses the first occurrence of an ID: `$XDG_DATA_HOME/rediwm/themes`,
legacy config presets, the binary's `../share/rediwm/themes`,
`$XDG_DATA_DIRS/rediwm/themes`, then the embedded RediWM Dark, RediWM Light
and Redi Blue packs. Without `XDG_DATA_HOME`, use `~/.local/share`.

The helper is also available from a terminal:

```sh
rediwm-theme validate my-look/
rediwm-theme pack my-look/ my-look.rediwm-theme
rediwm-theme install my-look.rediwm-theme
rediwm-theme install my-look.rediwm-theme --replace
rediwm-theme remove my-look
```

Installs validate in a private staging directory and publish by atomic rename
(or exchange on replacement). Archive parsing and asset validation run in
separate children, restricted by Landlock when supported and seccomp, with
memory and time bounds. There are at most 4,000 entries, 128 MiB unpacked,
40 MiB per file, 512 KiB per icon and 64 KiB per glyph. Glyphs must render
at 256 px in less than 10 ms; wallpaper sides are at most 16,384 px. SVG pack
assets are rendered from data without a base URI. A failed install names the
file and rule, cleans staging, and leaves an existing pack intact.

IPC exposes `theme.list`, `theme.apply` (`{"id":"my-look"}`), and
`theme.install` (`{"path":"/path/pack.rediwm-theme","replace":false}`).
Install completes asynchronously while the event loop stays responsive.
All three follow the IPC session-lock and sandbox allowance checks.

## Asset inventory

| Consumers | Artwork source |
| --- | --- |
| Compositor panels and titlebar controls | Theme tokens and shared shell SVG alpha masks |
| Files, Images and PDF controls | The same shell masks, tinted with their effective theme |
| Desktop Home/Trash | Shared shell masks and pack icon overrides |
| Files directories and desktop folders | XDG special-folder name, then `folder`, through shared icon lookup |
| Files documents | Association candidates and MIME icon names |
| Taskbar, titlebars and Start menu applications | App icon names through shared icon lookup |
| Wallpaper and lock-screen backdrop | Pack wallpaper unless a separate choice is pinned |
| Start button | Pack logo or the embedded RediWM logo |

Glyph filenames are the names in `assets/icons/`, including `wifi.svg`,
`notification-bell.svg`, `speaker.svg`, `trash-outline.svg` and
`view-grid.svg`. Only alpha is used. Flat colour icon overrides include
`folder`, `user-home`, `user-desktop`, `folder-documents`, `folder-download`,
`folder-music`, `folder-pictures`, `folder-videos`, `folder-templates`,
`folder-publicshare`, `user-trash`, MIME names, and application icon names.
XDG special directories come from `user-dirs.dirs`.

The small pack in `tests/fixtures/theme-pack/` supplies a glyph, folder icon,
wallpaper and logo. `tests/theme_packs.py` adds a real cursor and exercises
installation, live switching, restoration, overrides and hostile archives.
The greeter never discovers or reads user packs.
