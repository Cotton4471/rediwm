# Plan: file-type associations ("which app opens what")

Status: draft, 2026-10-09. Nothing is implemented. Next step is Phase 0, a
spike that pins down how GIO resolves defaults before any UI is built.

Scope: a place in Settings to see and change which app opens each kind of
file, and a line in Files' Properties that says which app will open this file
and why. It edits the standard `mimeapps.list` through GIO, so every other
program (Brave, `xdg-open`, portals, GTK/Qt apps) agrees with it. It adds no
store of its own.

## Where we are

Both ends of the system already speak GIO and `~/.config/mimeapps.list`:

* **Files** resolves a double-click with `associations.launchDefault`
  (`g_app_info_get_default_for_type`), shows icons from the same lookup, and
  its Open With dialog (`open_with.zig`) lists `g_app_info_get_all_for_type`
  first, then every other app that takes files or URLs. Ticking "remember"
  calls `g_app_info_set_as_default_for_type`.
* **Settings** has a Default applications card (`sections/default_apps.zig`,
  on the General page) for exactly two choices, File Manager and Terminal.
  Those are RediWM config (`[compositor] default_*`); the file manager choice
  also writes `inode/directory` and resets `x-scheme-handler/file`.

What is missing: any way to see or edit the other defaults in one place, and
any explanation of why a file opened with the app it did. The start-menu
catalog (`AppEntry`) does not parse `MimeType=`, so it cannot answer either.

### Survey (author's machine, 2026-10-09)

* 1,124 types in shared-mime-info; **445** are claimed by at least one
  installed app, **168** by two or more (those are the ones where the winner
  can be an accident), and 27 are URL schemes. `text/plain` alone has 20+
  claimants.
* `~/.config/mimeapps.list` holds 60 app references. **14 (23%) name apps that
  are not installed** (GNOME Text Editor, Showtime, VLC, Clash Verge, LM
  Studio).
* **4 lines use an alias spelling** of a type (`video/x-matroska` is an alias
  of `video/matroska`; `application/x-shellscript` of `text/x-shellscript`).
  The file has `video/x-matroska=mpv` and `video/matroska=Celluloid`; GIO
  reports **mpv for both**, so the canonical-keyed Celluloid line loses and
  nothing says so.
* `video/mp4` has an `[Added Associations]` entry (Showtime, missing) and no
  `[Default Applications]` line. Its winner, Celluloid, is whatever order
  `mimeinfo.cache` happens to give. Install another player and it can change.
* `Avahi SSH Server Browser` (`bssh.desktop`) has no `MimeType=` and no `%f`/
  `%u` in `Exec`. It is never offered for anything, and Open With already
  filters apps that take neither files nor URLs. Hidden entries do leak in
  through claims: `kitty-open.desktop` (NoDisplay) is a candidate for shell
  scripts.

### Why the wrong app opens

Observed above or visible in the code:

1. **No explicit default.** Winner = install order. Looks like a choice,
   isn't one.
2. **Alias keys.** Two spellings of one type coexist and one shadows the
   other.
3. **Dead lines.** A default naming a missing app is skipped silently, so the
   next claimant wins.
4. **`x-scheme-handler/file`.** GIO checks the scheme before the content type
   (already handled once in `default_apps.zig`'s `setDirectoryDefault`).
5. **Name-only detection.** `launchDefault` guesses the type from the file
   name and never reads contents (deliberate: the directory worker must not).
   `xdg-open`/`gio open` also sniff, so an extensionless file can resolve
   differently in Files and elsewhere. To verify in Phase 0.

## Goals and non-goals

Goals:

* One mental model: file kinds in about ten groups, each with the app that
  opens it, with the exceptions visible.
* Show *why*: chosen by you / automatic / from the system / app missing.
* Never offer an app that cannot open the type (claimants only, same
  file-or-URL filter as Open With).
* Heal the file when asked: remove dead and shadowed lines.
* No new wakeups, no GIO enumeration on the compositor's Wayland thread.

Non-goals:

* Editing shared-mime-info (new types, globs, icons).
* Content sniffing in Files (revisit only if Phase 0 shows it is the common
  complaint).
* Launch-time overrides, per-file "always use X", or changing what a single
  app declares in its `.desktop` file.
* Replacing the Open With dialog. It stays the per-file path.

## Design

### Effective answer vs provenance

Two separate questions, answered by two separate things:

* **What will open it** is whatever GIO says
  (`g_app_info_get_default_for_type`), the same call `launchDefault` makes. We
  never recompute it, so the page and the double-click cannot disagree.
* **Why** comes from reading the user's `mimeapps.list` ourselves (pure Zig, a
  parser plus an atomic rewriter, unit-tested on fixtures; lives in `config/`).
  For a type:

  | State | Meaning |
  | --- | --- |
  | Chosen | the user's `[Default Applications]` names an installed app and it is the effective one |
  | Automatic | no valid explicit line; winner is the first of N claimants |
  | System | winner comes from a system or desktop-specific list |
  | Missing app | explicit line names an app that is not installed |
  | Shadowed | an alias-keyed or earlier line overrides this one |

  Only the user file is parsed. System lists are detected by "effective app
  differs from every user line and from claimant order".

### File-kind groups

A static table, canonical MIME names plus media-type prefixes, matched on the
unaliased type so an alias cannot fall between rows:

| Group | Types |
| --- | --- |
| Web links | `x-scheme-handler/http`, `https`, `about`, `text/html`, `application/xhtml+xml` |
| Images | `image/*` |
| Video | `video/*` (+ a few `application/*` containers) |
| Audio | `audio/*` |
| PDF and e-books | `application/pdf`, `epub+zip`, `postscript`, djvu |
| Office files | OpenDocument and OOXML families, `text/csv` |
| Text and code | `text/*` minus `text/html` and `text/csv`, JSON, XML, shell scripts |
| Archives | zip, tar, gzip, 7z, rar, zstd (Files extracts in-app; this is for everyone else) |
| Mail | `x-scheme-handler/mailto` |
| Torrents | `x-scheme-handler/magnet`, `application/x-bittorrent` |
| Folders | `inode/directory` (this is the existing File Manager row) |

Rows with no claimed type on the machine are hidden. Anything outside the
table lives in the advanced list under "Other".

### Settings: a "Default apps" page

New `Page.apps` in `control_center/panel.zig`; `nav_rows` is already sized from
`page_names`. The General card is replaced by a link card ("Default apps"
button, same pattern as the Audio and Display cards), and File Manager and
Terminal move to the top of the new page unchanged.

**Group rows.** Each row is a `select` (`ui/widgets/select.zig`):

* Options are the apps that claim *any* type in the group, ranked by how many
  of the group's types they handle, labelled "Celluloid, 9 of 12 types". A
  NoDisplay claimant is hidden unless it is the current default.
* Choosing an app sets the **canonical** key for every type in the group that
  the app claims. Types it does not claim are left alone, so picking Pinta for
  Images does not hand it SVG.
* If the group's claimed types disagree, the row reads "Mixed" (an
  inert first label, like the existing "Unavailable: id" entry) and a disclosure
  lists the exceptions.
* Callbacks carry `owner` + `id`; the page rebuilds on a write, as the
  existing section does (`cc.refresh()`).

**Advanced: "All file types".** A disclosure below the groups.

* One group at a time (`segmented`), a search field, and "contested only" on
  by default. At most 40 rows are drawn; the rest are reached by search or
  "show more". Row storage is a fixed array added to the `max(...)` that sizes
  `content_children`, and rows go in through `layout.appendRow` (a raw index
  here once crashed the whole session).
* A row: type description and `video/matroska`, the current app, a state
  badge from the table above, and a select of claimants.
* A summary line at the top: "14 lines point to apps that are not installed ·
  4 use old type names · 9 types have no default", with **Clean up**. It
  removes only missing-app and shadowed lines, after writing
  `mimeapps.list.bak`.
* Optional, last: **Hide this app for this type** (`[Removed Associations]`,
  `g_app_info_remove_supports_type`), which is the real fix for a text editor
  that claims `text/plain` on every box.

### Files: "Opens with" in Properties

`properties.zig` gets two rows in the info block, under Type:

* The raw MIME type next to the description, dimmed: "Matroska video
  (video/matroska)". Makes a mis-detected file obvious.
* **Opens with**: app icon + name, then the state in dim text ("you chose
  this", "automatic, first of 4 apps", "no app installed") and a **Change…**
  button.

**Change…** reuses the Open With dialog in a choose-only mode: "Remember" is
forced on, the button reads "Set default", and nothing launches. Geometry
changes shift the Permissions block (`fullHeight()` and the hit-test rows move
together; scroll already handles overflow). Special files (pipes, sockets,
devices) show neither row.

### Writing

Prefer GIO for the write (`g_app_info_set_as_default_for_type`,
`g_app_info_reset_type_associations`): correct format, same code path as Open
With. Phase 0 decides whether GIO can also remove lines keyed by an alias or
for a missing app. If it cannot, the user-file rewriter does that part: read,
change only the three association groups, keep every other group and comment,
write to a temp file in the same directory and `rename`. Other programs write
this file too, so it is read-modify-write with no lock; the window is small
and the failure is "your edit lost", never corruption.

Before writing a choice, drop any alias-keyed line for the same type, or it
will shadow the new one (the mpv/Celluloid case).

### Where it runs

* GIO enumeration (`g_app_info_get_all_for_type`, registered types,
  `mimeinfo.cache` order) is file IO. In the compositor it runs on a worker
  that builds an immutable snapshot and signals an eventfd, as the start-menu
  catalog does. The Wayland thread only reads snapshots.
* The snapshot is built when the page opens and after our own writes. No new
  watcher and no timers (`AGENTS.md`: idle makes no wakeups). If the catalog
  already exposes a revision, rebuild when it changes; otherwise reopening the
  page is the refresh.
* Files is its own process and calls GIO directly on its worker, as it does
  now.
* The two sides share the parser, the group table and the state logic. The
  parser is pure Zig in `config/`; GIO externs stay in thin adapters
  (`files/associations.zig` and a compositor-side one). Whether one adapter
  file can serve both is a `build.zig` question for Phase 0.

## Phases

### Phase 0: spike, no UI (small)

Answer, with a test that pins each answer, using private `XDG_CONFIG_HOME`,
`XDG_DATA_HOME` and `XDG_DATA_DIRS` (extend `tests/files_associations.py`;
it already builds private MIME and app databases):

1. How GIO merges a canonical key and an alias key in one list (observed:
   the alias line wins, mpv). Does file order decide?
2. What `set_as_default_for_type` and `reset_type_associations` do with the
   alias spelling versus the canonical one, and with lines for missing apps.
3. Whether the lookup walks parent types (`text/x-csrc` to `text/plain`), and
   how to tell which type supplied the winner.
4. Name-only versus sniffed detection: does `gio open` pick a different app
   from `launchDefault` for an extensionless file?
5. Which lists exist beside the user's: `$XDG_CURRENT_DESKTOP-mimeapps.list`,
   `/etc/xdg`, `/usr/share/applications/mimeapps.list`. And who ignores them
   (portal OpenURI, Flatpak apps).

Output: a "Findings" section appended here, and the write-path decision.

### Phase 1: Properties "Opens with" (small)

`config/mimeapps.zig` parser + provenance, unit tests on fixtures; the
Properties rows; choose-only mode in `open_with.zig`.

Done when: for fixture files in private databases the row names exactly the
app a real double-click launches (the test launches it), each state shows,
and **Change…** pins a default that survives reopening and is what
`launchDefault` then launches.

### Phase 2: Default apps page, groups (medium)

Page, snapshot worker, group table, group rows, the General link card, File
Manager and Terminal moved over.

Done when: choosing in a group changes what Files launches without a restart;
a Mixed group shows its exceptions; unclaimed types are never written;
`inode/directory` still has a single writer (`setDirectoryDefault`); opening
and closing the page leaves no timer and no extra wakeups; the compositor
thread never blocks on GIO (check with the debug allocator build and a slow
fixture).

### Phase 3: Advanced list, clean up, hide-app (medium)

Search, group tabs, 40-row cap, state badges, summary + **Clean up** with
backup, then (optional) **Hide this app for this type**.

Done when: Clean up on a copy of the author's file removes the 14 missing
and the shadowed lines, leaves the rest byte-identical, and the result
round-trips through GIO unchanged in effect.

## Tests

* Zig unit tests: parser, state classification, rewriter (comments and unknown
  groups preserved, atomic write), group matching on aliases.
* `tests/files_associations.py`: GIO behaviour pins (Phase 0) and the
  Properties row against real launches.
* `tests/control_center.py` already drives the Default applications card
  (`default_file_manager` by widget name, around line 377): extend it for
  group rows, Mixed and Clean up. `desktop_icons.py` only sets the
  `default_file_manager` config key, so moving the card must keep that key.
* **No test or spike may touch the real `~/.config/mimeapps.list`.** Every
  compositor and Files instance under test gets private XDG dirs (same
  contamination class as `XDG_STATE_HOME`). Settings tests need the scratch
  config home before the page is built.
* Compare any failing suite against a `git worktree` of HEAD first; several
  already fail there.

## Risks and open questions

* **GIO is the only oracle, and it is opaque.** Phase 0 exists so the UI is
  not built on a guess about alias merging.
* **Group table drift.** New types appear with new apps. "Other" plus the
  advanced list is the safety net; the table is data, not logic.
* **Two writers.** GTK apps and `xdg-mime` rewrite the same file; see Writing.
* **A 40-row cap hides things.** Search and "contested only" must make the
  common case (a handful of conflicts) fit on screen, or raise the cap.
* To confirm before Phase 2: General keeps a link card rather than the full
  card (recommended); Clean up writes a `.bak` (recommended); Archives stay a
  group even though Files extracts in-app (recommended, for other apps); hide
  app per type is in scope as Phase 3's last item (recommended, droppable).
