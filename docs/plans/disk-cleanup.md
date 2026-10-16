# Settings storage cleanup plan

Status: draft, 2026-10-17. Start with Phase 0; the first release covers
user-owned caches, thumbnail cleanup and the home Trash.

Add a **Storage** page to Settings that explains where reclaimable space is,
lets the user review individual items, previews the exact work, and reports
the result. Use Safe Disk Cleaner as the feature reference while building a
native Zig implementation with RediWM's shared widgets. Filesystem work runs
in a separate unprivileged process so slow disks cannot stall the compositor.

System cleanup follows separately. RediWM currently permits only rediwm-dm
and the accounts helper to run as root. The reference application's general
`pkexec` cleanup helper therefore cannot be carried over under the current
architecture.

## Reference and existing integration points

The reference checkout is
`/home/alex/Downloads/safe-disk-cleaner-main`. Its `model.py`, `scanners.py`,
`cleaner.py` and `policy.py` separate discovery, explanations, selection,
planning and execution. Keep that separation. Its kernel cleanup supports
APT; package-cache cleanup supports APT, DNF, pacman and zypper; unused-package
cleanup supports APT, DNF and pacman. Capability detection must reflect those
differences rather than presenting universal Linux support.

The existing RediWM pieces to build on are:

| Existing code | Integration |
| --- | --- |
| [`control_center/panel.zig`](../../src/control_center/panel.zig) | Add the Storage page enum, navigation entries, section ownership, build, keyboard handling and teardown. Services currently occupies the last navigation slot and is conditionally hidden; preserve that behavior when inserting Storage. |
| [`sections/printers.zig`](../../src/control_center/sections/printers.zig) and [`printing/client.zig`](../../src/printing/client.zig) | Follow page-owned lifetime, copied snapshots, action generations and refresh callbacks. |
| [`control_center/folder_picker.zig`](../../src/control_center/folder_picker.zig) and [`session/child.zig`](../../src/session/child.zig) | Reuse the asynchronous child-process pattern: bounded pipe reads, event-loop callbacks, pidfds and detached callbacks after the owner disappears. |
| [`files/dirsize.zig`](../../src/files/dirsize.zig) | Reuse sizing ideas such as allocated blocks, cancellation, inode deduplication and partial results. Avoid importing the Files worker pool into the compositor. |
| [`files/thumbs.zig`](../../src/files/thumbs.zig) and [`files/thumb_codec.c`](../../src/files/thumb_codec.c) | Match the existing freedesktop thumbnail locations and URI encoding. Cleanup needs a bounded metadata reader; the current codec's returned metadata does not expose `Thumb::URI`. |
| [`files/ops.zig`](../../src/files/ops.zig) | Files already uses GIO for Trash operations. Its `gio trash --empty` empties everything GIO discovers, so it does not implement a reviewed selection. |
| [`ui/widgets`](../../src/ui/widgets) | Use the existing buttons, checkboxes, rows, scroll containers and confirmation controls with Settings palette and text tokens. |

The reference is MIT licensed. Preserve its attribution if copying code,
substantial explanation text or fixtures. Feature parity does not require a
Python or GTK runtime dependency.

## User experience

Storage opens with filesystem capacity cards, a **Scan** button and a short
explanation of the cleanup scope. Capacity reads happen in the worker; opening
Settings elsewhere starts no storage work. Scanning is explicit and
cancellable, with incremental category results and a last-scanned time.

The page has a summary, category rows and a details area. At narrow widths,
open details within the same scrollable content column. Each category shows
its estimated reclaimable size, selection state and availability. Details
answer four questions: what this data is, why it grows, what deleting it
changes, and what action will run. Show full paths on demand; escape unusual
filenames for display without changing the underlying filename bytes.

Use three labels: **Recreated when needed**, **May require downloads or
rebuilding**, and **Review before deleting**. Diagnostic history and Trash
belong in the last group. Start with nothing selected. A **Select recommended**
action selects only verified, recreatable items; unknown caches, diagnostics,
Trash and package removal never join that selection.

**Review cleanup** freezes a selection and opens an explicit confirmation
showing item counts, affected locations, estimates and consequences. An
expandable **Show exact actions** lists direct filesystem operations or the
fixed command arguments for each operation. This view comes from the same
plan the executor uses. Deleting Trash items must say they cannot be restored
through Trash afterward.

During cleanup, disable selection changes and show completed items, skipped
items and errors. **Stop** prevents subsequent operations; already completed
deletions stay completed. Afterward, show the result per category and the
observed free-space change on each affected filesystem. Offer **Scan again**;
never silently retry a failed or interrupted deletion.

## Feature scope

| Reference category | Delivery | Required behavior |
| --- | --- | --- |
| App caches in the user's cache directory | First release | Start with a small reviewed catalog of cache subdirectories and app identities. Unknown folders show sizes and an Open in Files action, with deletion disabled. Keep RediWM's active caches protected. |
| Picture previews | First release | Offer orphaned previews of definitely missing local files. Keep previews with unknown metadata, inaccessible originals or offline sources. Clearing other previews is a separate opt-in action. |
| Trash | First release for home Trash | List individual items with original location and deletion date when available. Delete only reviewed entries and handle their restore metadata together. |
| Flatpak and Snap app caches | Next user-data increment | Support reviewed app IDs and precise cache locations only; never whole app profiles, revision folders or app data. Block known running apps. |
| Unused Flatpak runtimes | Later adapter | Separate user and named system installations; ask Flatpak for unused refs in the correct user context, then revalidate the approved refs before execution. |
| Downloaded package files | Later system increment | Use the package manager's supported cleanup operation. For pacman, retain downgrade versions rather than wiping its cache. Show the retention policy in the review. |
| System journal | Later system increment | Vacuum archived entries through a supported authority. Show loss of diagnostic history and distinguish total journal size from the amount eligible for vacuuming. |
| Crash reports and core dumps | Later system increment | Restrict roots, file types and age; keep recent or active diagnostics. Treat them as review items. |
| Rotated logs | Later system increment | Restrict roots and filename rules; exclude live logs and journal files. A one-hour freshness guard from the reference is a starting rule, not proof that a file is unused. |
| Disabled Snap revisions | Later adapter | Re-query snapd and remove only the selected revision while it is still disabled. Explain the loss of that rollback version. |
| Packages no longer needed | Final package increment | Preview a concrete removal transaction, keep user configuration, and refuse additional removals outside the approved transaction. |
| Old kernels | Final package increment | Start with a qualified APT adapter. Keep the running kernel, newest kernel, held packages and an identified bootable fallback. Unknown bootability or dependency changes disable removal. |

Mounted-volume Trash, including both `.Trash/<uid>` and `.Trash-<uid>`, follows
the home Trash implementation. Show separate volumes and handle unmounts;
do not discover Trash by scanning every disk recursively.

Persistent journal limits and Snap revision retention are separate later
settings with their own Apply and restore-default actions. Cleaning once
must not change retention settings. Automatic cleanup, startup scans,
browser history/cookies, downloads, documents, duplicate-file removal and
arbitrary directory deletion are outside this scope.

## Architecture

Introduce these modules, keeping policy and filesystem code independent of
compositor types:

| Proposed file | Responsibility |
| --- | --- |
| `src/control_center/sections/storage.zig` | Widgets, selected item IDs, details, confirmation and progress presentation. |
| `src/storage/client.zig` | Own the worker process, pipe readiness, generations, deadlines and callback lifetime. |
| `src/storage/model.zig` and `protocol.zig` | Typed categories, item identities, estimates, plans, progress, results and a bounded versioned protocol. |
| `src/storage/scan.zig`, `policy.zig` and `plan.zig` | Root discovery, capability detection, cache catalog, eligibility rules and immutable plan construction. |
| `src/storage/fs.zig`, `thumbnails.zig` and `trash.zig` | Descriptor-relative traversal, metadata parsing, sizing and targeted deletion. |
| `src/storage/main.zig` | Entry point for the installed, unprivileged `rediwm-storage-worker` executable. |
| `src/storage/adapters/` | Later qualified Flatpak, Snap, package and journal integrations. |

Each item carries a category and item ID, root ID and relative location,
filesystem/object identity, size estimate, explanation, availability,
blocked reason and typed operation. Represent unavailable, empty, incomplete,
permission-denied and unsupported states separately. Permission failure must
never appear as zero bytes available for cleanup.

The worker retains the scan inventory. The UI requests a plan from selected
IDs, receives its exact preview, and confirms that plan's token. Execute only
the retained plan from the same worker and generation; reject stale, unknown
or replayed tokens. New files and changed directories cannot silently expand
the approved deletion set. Deduplicate overlapping roots, entries and
operations before calculating totals or executing them.

Send incremental bounded messages over private inherited pipes or a
socketpair. Bound message size, path size, inventory memory, recursion depth
and work per event-loop callback. Large results use paged details and report
truncation; they must not collapse unseen items into an implicitly selected
"everything else" operation. Disconnects invalidate pending plans.

The process runs only while Storage is active. Leaving the page, closing
Settings, locking the session or shutdown cancels discovery and requests a
stop between filesystem operations. Detach callbacks before freeing the
section, and reap children through `session/child.zig`; never wait for disk
I/O on the Wayland thread. In-flight filesystem work can complete after Stop,
so reopening starts with a fresh scan. Future package transactions need their
own safe completion and cancellation contract before they are enabled.

Use readiness notifications and deadlines only for active work. Hidden pages
retain no worker owner; a stopped child can finish being reaped asynchronously.
While Storage is visible, an idle worker may retain its inventory while blocked
on its request pipe, with no recurring timer, process scan or wakeups. Copy
display strings into the section arena before releasing worker snapshots.
Requests and completions carry generations so older results cannot replace a
newer selection. Follow the existing launch/scope rules for child applications.

## Filesystem safety and accounting

Resolve `XDG_CACHE_HOME` and `XDG_DATA_HOME` with the standard home fallbacks;
reject relative or dangerously broad cleanup roots. Validate ownership and
root identity, and pin approved roots by directory descriptors. Requests
cannot supply new base directories. Refuse overlaps that would turn the
home, configuration, application data or state directories into cache roots.
The worker refuses to run as root; permission errors never trigger elevation.

Walk and delete relative to pinned directories without following symlinks.
Check mount identity as well as device identity so bind mounts cannot expand
the cleanup scope. Revalidate object identity and eligibility immediately
before deletion; skip changed objects. A selected Trash symlink can be
unlinked as a link, without touching its target. Never delete a root itself
or use a shell command, glob or generic `rm -r` for this engine.

Phase 0 must prove the deletion strategy against link replacement, directory
renames and changes between scan, confirmation and execution. A stat check
followed by pathname deletion alone is insufficient. Qualify an approach
such as private staging within the same filesystem, with identity checked
after the atomic move and before unlinking. Unexpected replacements must be
preserved, with recovery information if they cannot be restored. Interrupted
staging must also have a defined recovery path before destructive UI ships.

Trash metadata supplies display information only. Its original `Path=` is
never a deletion target. Keep restore metadata until removal of its matching
contents succeeds; interruption or failure must not leave remaining contents
without their metadata. Recheck running-app evidence immediately before each
app-cache action. Process names alone do not provide an exclusive lock;
ambiguous app identity keeps the item blocked, and the UI must not promise
that a process check prevents every concurrent write.

Read thumbnail PNG metadata with bounded chunks and URI decoding, without
decoding image pixels. Only a definite missing original on a known available
local source qualifies as an orphan. An unknown mount, unavailable network
location, permission error or malformed URI keeps the preview. Recheck the
original before deletion. Do not infer all mount locations from `/media`
and `/mnt` prefixes alone.

Estimate allocated blocks, deduplicate hardlinks across selections, and
avoid claiming hardlink space is reclaimed while unselected links remain.
Shared extents, compression and open deleted files can make actual recovery
smaller than the estimate. Sample available bytes before and after on each
unique affected filesystem, distinguishing mounts that share the same
capacity pool. Report signed observed changes separately from removed-item
totals because other processes can allocate space concurrently. Do not call
a machine-wide `sync` or add all mounted-filesystem free space together.

## System authority and distro qualification

Keep all first-release operations unprivileged. For later system actions,
first qualify existing distro services that expose the required operation,
enforce their own authorization and allow the actual transaction to match
the preview. RediWM's polkit agent presents authentication; it does not grant
the compositor permission to execute arbitrary root commands.

Where no suitable existing authority exists, show the action as unsupported
under the current architecture. A new installed privileged helper requires
a separate architecture decision changing the root-process rule, an explicit
operation allowlist, authorization policy and independent security review.
Do not extend the accounts helper into a general disk-cleaning service.

Every adapter must revalidate the current backend state, use fixed argument
arrays and trusted executables, distinguish permission denial from missing
tools, and honor package-manager locks. Never expose a command-string or
arbitrary-path execution operation. Scanning must not refresh repositories,
authenticate or modify package state. Unsupported backend versions fail
closed. Prove transaction and kernel protections separately for each distro;
the reference's APT checks do not establish equivalent DNF or pacman safety.

## Delivery phases and completion criteria

1. **Phase 0 — filesystem and authority prototype.** Pin the initial cache
   catalog and root rules, define the worker protocol and prove traversal,
   staging/recovery, cancellation and accounting on temporary trees. Record
   the capability matrix and system-authority constraints. Completion means
   containment tests pass under concurrent mutations and worker teardown
   cannot block or call a destroyed Settings owner.
2. **Phase 1 — read-only Storage page.** Add navigation, capacity cards,
   explicit scan/cancel, known and unknown cache sizes, thumbnail groups and
   home Trash details. Completion means partial results, inaccessible paths,
   missing roots and large inventories remain useful, the desktop stays
   responsive, and idle/hidden pages add no wakeups.
3. **Phase 2 — first cleanup release.** Enable reviewed known cache contents,
   eligible thumbnails and selected home Trash items through frozen plans.
   Add confirmation, Stop, per-item outcomes and filesystem deltas. Completion
   means only the reviewed inventory is eligible, changed entries are
   skipped, and partial failure/interruption preserves recoverability of
   surviving Trash entries and staged data.
4. **Phase 3 — additional user locations.** Add reviewed Flatpak/Snap cache
   adapters, mounted-volume Trash and user Flatpak runtimes once backend
   semantics are qualified. Completion includes active-app blocking,
   offline volumes, multiple installations and dependency changes.
5. **Phase 4 — qualified system cleanup.** Resolve the authority design,
   then add package caches, journal, diagnostics, system Flatpak runtimes and
   disabled Snap revisions one adapter at a time. Completion requires real
   distro qualification in disposable systems, authorization cancellation,
   locked/busy backends and exact-action review. Retention settings follow
   with independent confirmation and readback.
6. **Phase 5 — package and kernel removal.** Add transaction previews and
   conservative kernel protection for explicitly supported backends.
   Completion requires testing changed dependency graphs, held packages,
   missing/running/fallback kernels and unapproved extra removals. An adapter
   stays disabled when those guarantees cannot be established.

## Validation

Extend existing coverage where it fits and add a focused storage suite for
the destructive engine. Link unit tests into the build explicitly. Tests use
temporary home/cache/data/state trees, private buses and fake command
backends; they never delete host data or contact the host package manager.

Required cases include symlink and bind-mount escapes, rename/replacement
races, unsafe XDG overrides, hardlinks, sparse files, overlapping selections,
deep/large inventories, unusual filenames, permission errors, malformed PNG
metadata, offline originals, hostile `.trashinfo`, newly started apps, stale
plan tokens, disconnects, cancellation and interrupted staging recovery.
Adapters add changed package/ref state, authorization denial, busy locks and
unapproved transaction expansion cases as they are introduced.

Add `tests/storage_cleanup.py` using the existing Settings widget/IPC
inspection and private fixture process. Cover selection and details,
confirmation cancellation, targeted deletion, partial failure, UI
responsiveness, page switching, close, lock, reopen and per-thread idle
wakeups. Use stable widget names; no new destructive IPC endpoint or
production test environment hooks are needed. Check compact layout and
fractional scale, and confirm the greeter starts no storage worker.

For implementation changes, run Debug and ReleaseSafe builds, `zig build
test`, the focused storage suite, `tests/control_center.py` and
`tests/greeter.py`. Run Files thumbnail/Trash regression coverage if shared
code changes. Compare pre-existing failures against a clean HEAD worktree
before assigning regressions. Actual privilege/backend qualification belongs
in disposable distro environments, with results recorded per adapter.
