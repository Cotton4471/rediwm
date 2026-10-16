# Dock implementation notes

Read when changing `src/Dock.zig`, `src/dock_drag.zig`, or their output,
taskbar, OSD and input integration. General rules remain in
[AGENTS.md](../../AGENTS.md); integration coverage is in `tests/dock.py`.

* **The dock repaints cells, not itself** (`Dock.zig`). It keeps its last
  raster and, when only some items' looks changed (hover zoom, pills), clears
  and repaints just their `itemCell`s (each item at the largest hover zoom, across
  the dock's thickness) under a clip, publishing that damage alone. Dock-wide
  state (theme, scale, count, drop slot, hover zoom, active-app highlight, the
  background `Dock.background` makes of `dock_opacity`) is `base_key` and
  repaints all. Draw nothing outside an item's cell without keying it in
  `base_key`, or it goes stale. `tests/dock.py` compares an animated dock with a
  whole repaint. The icon tooltip waits `tooltip_delay_ms` on its own one-shot
  timer, re-armed only when the hovered icon changes. Icons use `drawImageSmooth` (area average): `drawImageCover`
  samples the nearest pixel and shows stair-steps at the dock's fractional
  downscale.

* Hover zoom keeps the screen-edge side fixed and grows toward the desktop.
  Its spring (`dock_hover`) is underdamped: `zoomRange` gives the overshoot
  headroom that rasters, icon size and cells are sized for, so never clamp a
  look to `dock_hover_zoom` itself.
  `rasterBox` pads the painted buffer for overflow; `glass_anchor` keeps the
  background's extent. Input uses tree-local coordinates and `input_root`
  covers the expanded icons. Item cells span the expanded raster's thickness.

* **The dock reserves space only when it doesn't auto-hide.** `Output.usableBox`
  is `dockAreaBox` (output less the taskbar) less `Dock.reservedStrip`, a pure
  function of config and that box (`Dock.fits`), so it never flips with a lock
  or fullscreen window. The dock and the taskbar's popups/menus are placed in
  `dockAreaBox`, never `usableBox`. A setting that changes the strip calls
  `applyTaskbarPosition` (`Dock.reserves` before/after). The OSD keeps clear
  of `Dock.footprint` (the resting dock, auto-hiding or not) on the bottom
  edge. Auto-hide fades and slides the node (`reveal`, opacity + position, no
  repaint; the glass opacity follows it too) and parks it (no rebuilds, no
  frames) once away; reveal/hide wait on one `wl` timer
  (`Dock.pointerAt` from `Input.processCursorMotion`, `retime`).

* **Compositor-internal drags** (`dock_drag.zig`: start menu app -> dock pin,
  and a pinned dock icon -> another place among the pins) are not wl_data_device
  ones: a press arms, motion past a threshold starts, and starting rebuilds the
  menu so its release is no click. A pinned icon acts on release (`Dock.clickPin`)
  so a drag can start from it. Closing the menu or Escape (`cancelDrag`; for a
  dock icon `Keyboard.zig` takes it ahead of every shell panel, for a menu app
  before the menu's own Escape) abandons it. A dock
  holds resolved pins as copies (`pin_arena`); `config_index` maps a slot back
  into `dock_pinned_apps`, which also lists apps no longer installed.
