# Plan: theme packs (colours plus icons, wallpapers and cursors)

Status: implemented, 2026-10-13. Phases 0–6 use the proposed D1–D5 design.
The implementation and author instructions are in `docs/themes.md`; the
fixture and integration gates are in `tests/theme_packs.py`.

The inventory below records the pre-implementation baseline. Pack discovery
now lives in `config/theme_pack.zig`, application in `config_runtime/`, and
archive handling in the separate `rediwm-theme` helper. The helper reuses
Files' archive path normalization and direct image codecs; bounded ZIP
streaming, cursor aliases and atomic publication have their own native path.

Scope: a theme becomes a *pack*: the `[theme]` tokens it is today, plus the
pictures that go with them (wallpapers, the start logo, shell glyphs, folder
and file icons, optionally a cursor theme). A pack is shared as one file (a
zip), installed with one click and applied as one choice in Appearance. No
code, shaders or fonts travel in a pack.

## Baseline before implementation

A theme is TOML only, and only colours, sizes and font names:

* **Tokens.** `ui/theme.zig`'s `Theme` struct (over 200 fields: colours,
  radii, sizes, `font`, `mono_font`, `start_button_icon`). The tiny parser
  reads a `[theme]` section; `writeInto` writes only the values that differ
  from the built-in defaults.
* **Where they live.** The applied theme is the `[theme]` section of
  `config.toml` (plus `[taskbar_theme]`, the taskbar's own colours), with
  `REDIWM_THEME` overlaid on top.
* **Presets.** Three TOMLs embedded at build time (`assets/themes/`, listed by
  `ui/theme_presets.zig`) plus every `*.toml` in `~/.config/rediwm/themes/`.
  Picking one **copies** its values into `theme.global` and saves them to
  `[theme]`. Which preset is active is not stored: Appearance re-parses every
  preset and selects the one equal to the current theme, else "Custom".
* **App clients.** Files, Images and PDF follow `config.toml`'s `[theme]`
  through `files/settings.zig` (stat once per second, re-read on change). PDF
  reads it once, before its sandbox closes the filesystem.

Everything visual that is not a token is a separate setting, chosen
separately:

| What | Today | Chosen by |
| --- | --- | --- |
| Wallpaper | `[compositor] wallpaper`: file name in `share/rediwm/wallpapers` or `~/.local/share/rediwm/wallpapers`, or a path | Appearance strip |
| Apps light/dark | `[compositor] dark_mode` (settings portal) | Appearance |
| Start logo | `[theme] start_button_icon`, an **absolute** path | Appearance |
| Shell glyphs (wifi, battery, sidebar, toolbar icons) | 49 SVGs `@embedFile`d into `ui/shell_icons.zig`, alpha masks tinted at paint time | nothing: compiled in |
| Folder icons in Files | hand-drawn vector, `file_folder_back/front` tokens | tokens only |
| File icons in Files, desktop icons, app icons | freedesktop icon theme, `icon_theme.zig` | `REDIWM_ICON_THEME` env only (default Adwaita), read at startup |
| Cursors | Xcursor theme by name, `[input] cursor_theme`; phinger built and installed to `share/icons` | Appearance |
| Sounds | freedesktop sound theme by name, `sound_theme` | config |

So the user's reading is right: switching "theme" today changes colours and
geometry; the wallpaper, glyphs and folder icons stay put. Two inconsistencies
fall out of the survey and this plan fixes them in passing: the desktop draws
folders with the icon theme's `folder` while Files draws its own vector one,
and the icon theme is the only appearance setting with no UI and no config key.

## Design

### A pack on disk

A pack is a directory; the zip is only how it travels (D1).

```
nord/
  theme.toml          required
  preview.png         optional, picker thumbnail (≤ 512×320)
  logo.svg            optional, start button
  wallpapers/         optional, *.png *.jpg *.jpeg *.webp
  glyphs/             optional, monochrome shell glyph overrides
  icons/              optional, flat colour icon overrides (D4)
  cursors/            optional, a built Xcursor theme (Phase 6)
```

`theme.toml` is today's format with two more sections. Everything in
`[theme]` and `[taskbar_theme]` is read by the existing parser, so a single
`.toml` preset is already a pack without assets, and keeps working:

```toml
[meta]
format = 1                # packs from a newer format are refused with a message
id = "nord"               # [a-z0-9-], ≤ 64; defaults to the directory name
name = "Nord"
version = "1.2"
author = "…"
license = "CC-BY-SA-4.0"
description = "Arctic blues."

[theme]                   # unchanged token set
accent = "#88c0d0"
start_button_icon = "logo.svg"   # relative: inside the pack

[taskbar_theme]           # optional, unchanged

[assets]
wallpaper = "nord-night.jpg"     # default wallpaper, from wallpapers/
color_scheme = "dark"            # sets [compositor] dark_mode
icon_theme = "Papirus-Dark"      # optional base icon theme, by name (D4)
cursor_theme = "pack"            # "pack" = cursors/, or an installed name
```

Rules that keep packs safe and forward compatible:

* Asset paths are relative and must resolve inside the pack (no `..`, no
  absolute paths, no symlinks). An absolute `start_button_icon` stays legal in
  `config.toml` only.
* Unknown `[theme]` keys in a pack are logged and skipped, not fatal (today the
  config loader fails on them), so a pack made for a newer RediWM still loads.
* Glyphs are named like `assets/icons/` (`wifi.svg`, `view-grid.svg`,
  `trash-outline.svg`), so an author starts by copying that directory. Only
  alpha is used: they are tinted like the built-in ones.

### Where packs are found

In order, the first id wins (as `wallpapers.zig` does for file names):

1. `$XDG_DATA_HOME/rediwm/themes/<id>/` (installed by the user)
2. `~/.config/rediwm/themes/*.toml` (today's single-file presets; id = stem)
3. `<prefix>/share/rediwm/themes/<id>/`, then `$XDG_DATA_DIRS/rediwm/themes/`
   (distribution packs)
4. The embedded presets (`rediwm-dark`, `rediwm-light`, `redi-blue`), which
   stay embedded so a broken install still has a theme.

Discovery and parsing go in `config/theme_pack.zig` (parsing is `config/`);
applying goes in `config_runtime/`, beside today's reload path.

### Config: a reference plus overrides (D2)

`config.toml` names the pack and keeps only what the user changed on top:

```toml
[theme]
base = "nord"        # new key; absent = built-in defaults, i.e. today
font_size = 14       # the user's own tweak, kept across pack updates
```

Layering: built-in defaults ← pack `[theme]` ← `config.toml [theme]` ←
`REDIWM_THEME`. `writeInto` diffs against the resolved pack instead of
`Theme{}`, so Appearance edits stay small and an updated pack reaches the
user. Picking a pack clears the overrides (the same as a preset replacing
everything today), and a "Reset to theme" button does the same without
switching. Configs without `base` read exactly as today: that is Phase 1's
regression test.

`files/settings.zig` resolves `base` the same way, so Files and Images follow
a pack switch; PDF keeps the pack it was started with (it has to read before
its sandbox), as it already does for colours.

### Assets at runtime

* **Wallpaper.** An empty `[compositor] wallpaper` means "the theme's" (the
  pack's `[assets] wallpaper`, else `default.png`). Picking an image in the
  strip pins it; applying a pack resets it to "the theme's" (D3). The strip
  gains the active pack's `wallpapers/` as a group. The lock screen uses the
  same image, so it follows for free.
* **Start logo.** `start_button_icon` relative to the pack.
* **Glyphs.** `shell_icons.source` asks the active pack for `glyphs/<name>.svg`
  first, then the embedded SVG. The mask cache is flushed on a pack switch
  (`shell_icons.deinit`). Rasterising is synchronous on the caller's thread
  (the compositor paints with it), so install-time validation bounds a glyph's
  size and render time (below).
* **Folder and file icons (D4).** A flat `icons/` directory (`<name>.svg` or
  `<name>.png`, freedesktop names) is searched before the icon theme chain in
  `icon_theme.zig`, which every icon user goes through: Files, the desktop, the
  taskbar and the start menu. That makes overriding an *app* icon
  (`firefox.svg`) free as well. The chain behind it is `[assets] icon_theme`,
  else a new `[compositor] icon_theme` setting, else `REDIWM_ICON_THEME`, else
  Adwaita. Files then draws a directory with the first icon found among its
  XDG special name (`user-home`, `user-desktop`, `folder-documents`,
  `folder-download`, `folder-music`, `folder-pictures`, `folder-videos`,
  `folder-templates`, `folder-publicshare`, `user-trash`, from
  `user-dirs.dirs`) and `folder`, and keeps today's vector folder when the
  pack supplies neither. The desktop uses the same lookup, which ends the
  Files/desktop mismatch. Icon caches (`icon_cache`, `icon_service`, Files'
  and the desktop's) key on a pack generation so a switch re-resolves.
* **Cursors (Phase 6).** `cursors/` is a built Xcursor theme (`index.theme`
  plus `cursors/`). Installing links it as
  `~/.local/share/icons/rediwm-<id>-cursors`, which is on `XCURSOR_PATH` for
  wlroots, Xwayland and children, and applying sets `cursor_theme` through the
  existing picker path. Xcursor aliases are symlinks, so the installer allows
  exactly one kind: inside `cursors/cursors/`, a target with no `/`.

Nothing here adds a wakeup: packs are read on apply, on config reload and on
start, and no pack directory is watched.

### Installing, removing, sharing

The compositor never opens an untrusted archive and does not link libarchive.
A small helper, `rediwm-theme`, does, reusing `files/archive.zig` (libarchive,
already rejecting unsafe paths, links, special files and oversized entry
counts):

```
rediwm-theme install <file.rediwm-theme|.zip|dir>   # validate, extract, print id
rediwm-theme validate <dir>                         # for authors
rediwm-theme pack <dir> <out.rediwm-theme>          # for authors
rediwm-theme remove <id>
```

Install extracts into `themes/.staging-XXXXXX/`, validates there, then renames
into `themes/<id>/` (`RENAME_EXCHANGE` when upgrading, then deletes the old
copy), so a running compositor never sees half a pack. Validation:

* Zip only; the pack is the archive root or its single top-level directory.
* Regular files and directories only (plus the cursor alias exception); at
  most 4,000 entries, 128 MiB unpacked in total, 40 MiB per file, counted
  while streaming so a bomb stops early.
* Allowed by place: `theme.toml`, `preview.png`, `logo.svg|png`,
  `wallpapers/*.{png,jpg,jpeg,webp}`, `glyphs/*.svg`, `icons/*.{svg,png}`,
  `cursors/**`, and `README*`, `LICENSE*`. Anything else is refused by name.
* `theme.toml` parses; every image decodes; every SVG renders at 256 px.
  Glyphs: ≤ 64 KiB and under 10 ms to render at 256 px; icons: ≤ 512 KiB.
  Wallpapers: ≤ 16384 px a side. A failure names the file and the rule.
* An id already installed asks "Replace Nord 1.1 with 1.2?" in Appearance.

The helper is a child of the compositor (or of Files), runs with no
privileges, and can enter a Landlock/seccomp sandbox limited to the staging
directory, like PDF's (`rediwm_pdf_sandbox_enter`); a crafted archive that
breaks libarchive or librsvg then crashes the helper, not the session.
Appearance runs it as a job with an eventfd, as it does the GTK/Qt colour
export (`AppColorsJob`).

Entry points:

* Appearance: "Install theme…" (file chooser), and "Remove" on user-installed
  packs. Removing the active pack switches to RediWM Dark first.
* Files: a `.rediwm-theme` file opens with "Install theme" (a shared-mime-info
  type `application/x-rediwm-theme`, glob `*.rediwm-theme`, in `data/`).
* IPC: `theme.list`, `theme.apply`, `theme.install` for tests and scripts.
  They are settings writes: `SessionLocked` while locked, and sandboxed callers
  need an `[[sandbox_allow]]` allowance like the rest of settings IPC.
* "Save current look as theme…" (Phase 5): writes a pack from the current
  tokens, wallpaper and logo into `themes/<id>/`; `rediwm-theme pack` zips it.

### Security notes

* The greeter loads no packs (it reads nothing from a user's home and
  writes nothing under `$HOME`); `tests/greeter.py` must still pass. Themed
  login screens from system packs (`share/rediwm/themes`, chosen in
  `rediwm-dm.conf`) are a possible later item, not this plan.
* A broken or missing pack never blocks locking: lock UI and wallpaper are
  already optional there, and every asset falls back to the built-in one.
* SVGs are rendered from data with no base URI, so they cannot pull in files
  outside themselves.
* No fonts, scripts, shaders, `.desktop` files or anything executable. Fonts
  are referenced by family name; bundling them (private `FcConfigAppFontAddDir`
  for RediWM processes only) is a possible later item.

## Decisions

* **D1, zip at runtime or only in transit.** Chosen: only in transit; the
  installed form is a directory. Xcursor and icon loaders, the wallpaper
  decoder, Files, the desktop and the sandboxed PDF viewer all take paths;
  the compositor would otherwise need libarchive and decompression on its
  paths; validation happens once instead of on every read; and authors edit a
  directory and see the result. Cost: a pack takes its unpacked size on disk.
* **D2, reference or copy.** Chosen: `[theme] base = "<id>"` plus overrides
  (above). Alternative: keep copying tokens and only add `base` for assets;
  simpler, but pack updates never reach colours and Appearance keeps guessing
  the active preset by equality.
* **D3, wallpaper on switch.** Chosen: applying a pack resets the wallpaper
  to the pack's; a later pick in the strip pins it until the next switch.
  Alternative: keep the user's wallpaper unless it was the theme's.
* **D4, icons.** Chosen: a flat `icons/` override directory in packs, plus a
  base icon theme referenced by name. Full freedesktop icon themes (10,000 to
  50,000 files, tens of MiB) are not carried inside packs.
* **D5, file name.** Chosen: `.rediwm-theme` (a zip) registered for
  double-click install, and plain `.zip` accepted by the helper and the file
  chooser.

## Phases

Each phase ends with the usual gate: Debug and ReleaseSafe builds,
`zig build test`, the touched integration tests, HEAD comparison for
known-failing suites.

0. **Inventory** (no code). The glyphs each surface uses (compositor, Files,
   Images, PDF, desktop), the icon names Files and the desktop ask for, and a
   sample pack in `tests/fixtures/theme-pack/` (one glyph, `folder.svg`, a
   small wallpaper, a logo) that every later phase tests with.
1. **Packs without assets.** `config/theme_pack.zig` (format, discovery,
   `[meta]`), `[theme] base`, layered resolve, `writeInto` against the base,
   unknown pack keys skipped. Appearance lists packs with their names and
   remembers the active one; "Reset to theme". `files/settings.zig` resolves
   `base`. Unit tests: a config without `base` resolves to today's theme; a
   save writes only overrides; the three presets resolve as before.
2. **Wallpaper, logo, colour scheme.** `[assets] wallpaper` and
   `color_scheme`, relative `start_button_icon`, the strip's pack group, D3's
   reset. The lock screen check that it follows.
3. **Glyphs.** Override lookup in `shell_icons`, cache flush on switch, app
   clients follow, PDF reads its pack before the sandbox.
4. **Folder and file icons.** The flat `icons/` lookup in `icon_theme.zig`,
   `[compositor] icon_theme` with a picker, generation-keyed caches, Files'
   special-folder names, the desktop on the same lookup.
5. **Install, remove, share.** `rediwm-theme` (install, validate, pack,
   remove), its sandbox, Appearance install/remove/replace, Files double-click
   and the MIME type, IPC `theme.*`, "Save current look as theme…".
6. **Cursors.** `cursors/` in packs, the alias exception, the
   `~/.local/share/icons` link, applied through the cursor picker path.

Phases 2 to 4 can land in any order after 1; 5 needs only 1, so packs can be
installed (and tested from a zip) as soon as there is anything to install.

## Tests

* Unit: pack parsing (format, ids, relative paths, unknown keys), layering
  and saving, discovery order and id collisions, the installer's path rules.
* Integration, a new `tests/theme_packs.py` on the fixture pack: install by
  IPC from a zip, apply, then check by IPC screenshot that a glyph, the Files
  folder icon, the desktop folder, the wallpaper and the start logo changed;
  switch back and check they return; remove the active pack.
* Hostile archives, each refused with its message and nothing left in
  `themes/`: `../` and absolute paths, a symlink out, a device node, a zip
  bomb, 10,000 entries, a disallowed file, a glyph that takes 2 s to render,
  a wallpaper of 40000×40000, a malformed `theme.toml`.
* `tests/greeter.py` (no packs read), and the existing Appearance and
  wallpaper tests with a scratch `XDG_STATE_HOME` and `XDG_DATA_HOME`.

## Not in this plan

* Downloading packs (no catalog, no network).
* Fonts inside packs; exporting a pack's icons to GTK/Qt apps (the GTK/Qt
  colour export stays as it is); light and dark variants in one pack (one pack
  per look, like RediWM Dark and Light today); sounds; themed login screens.
