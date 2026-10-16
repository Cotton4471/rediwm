# Plan: Printers page in Settings (setup, status, and "why didn't it print")

Status: the printer software workflows are implemented, 2026-10-16. Physical
printer acceptance and stock desktop policy qualification remain open. This
plan distinguishes implemented behavior, synthetic tests, isolated CUPS checks
and hardware evidence; a completed CUPS job never establishes paper output.

Implemented scope:

* Settings → Printers lists queues, state/reasons, reported supplies, defaults
  and the current user's recent jobs. Own jobs can be cancelled. Missing or
  private attributes and authorization failures remain visible.
* A bounded IPP codec and cancellable HTTP worker support configured Unix and
  cleartext TCP CUPS endpoints. System/user `client.conf`, `CUPS_SERVER` and
  encryption preferences are checked without falling back to a different
  server. TLS, authentication and escaped configuration syntax are unsupported.
* Local-default-server administration uses `cups-pk-helper`: discovery, queue
  creation, enabling/disabling, accepting/rejecting jobs, descriptions, queue
  rename/removal, connection changes and the system default. Custom Unix and
  remote schedulers remain read-only for these actions. CUPS service start uses
  the existing systemd path and reports unavailability on other service managers.
* Setup combines CUPS discovery, USB evidence and validated typed network
  addresses. Driverless IPP is preferred when supported evidence is available;
  IEEE 1284 driver matches are conservative, ambiguous matches need a choice,
  and raw queues/third-party driver guidance are explicit. Vendor backends must
  come from the current CUPS discovery result, never arbitrary typed input.
* Queue-name collisions are checked before administration. Removal and queue
  rename require separate named confirmations. Rename is the helper's
  non-atomic clone/delete operation, with known-job guards, refreshed queue
  checks and migration of personal defaults/private observations after success.
* Supported IPP values and bounded PPD UI declarations provide media,
  resolution, colour, duplex, quality and exposed label controls. Driver choices
  use the PPD-aware helper API and are refreshed for verification. CUPS can
  report conflicting IPP/PPD defaults; an accepted request is not presented as
  a verified setting when the resulting value cannot be established.
* Per-user defaults preserve existing `~/.cups/lpoptions` options, destinations,
  instances and comments through atomic replacement. `LPDEST`/`PRINTER` overrides
  remain visible; the privileged system default is a separate action.
* Explicitly confirmed PDF, raw-language and ruler tests use actual media
  dimensions, one copy and no banners. PDFs request no scaling or n-up fitting.
  Language samples run individually, and the user records whether output
  appeared. Two-axis measurements suggest only a supported resolution. No node
  write, test print or privileged mutation happens automatically.
* USB uevents, local socket-directory events, show/Refresh and user actions
  trigger reloads without polling. Where a verified indefinite `dbus://` lease
  is available, authenticated CUPS notifier signals also reload the page.
  Hiding closes local workers/listeners and attempts subscription cancellation
  without waiting for a reply.
* Diagnostics retain unknown evidence, mask private identifiers and include
  bounded distro/CUPS version information and user-recorded test outcomes.
  Package guidance covers Arch derivatives, Debian/Ubuntu, Fedora and openSUSE;
  Settings search includes printer terms. Printing adds no root executable,
  package installer, USB rule writer, filter or driver.

[Qualification evidence](printers-qualification.md) records real isolated CUPS
and helper checks on Arch, Debian 13, Ubuntu 24.04 and Fedora 44, including raw
bytes through a synthetic PPD queue. These do not qualify USB/backend hardware,
real media measurements, stock unprivileged polkit behavior, desktop notifier
delivery, real driverless creation or application/portal visibility. openSUSE
has guidance but no release build target or executed qualification image.
The cancellable resolver uses hosts files and ordinary DNS, not NSS/Avahi mDNS;
direct `ipps://`/DNS-SD reachability remains unavailable. The repository-wide
i18n module is still planned (`docs/plans/i18n.md`), so strings follow existing
English call-site conventions rather than a completed extraction pipeline.

Scope: a Printers page in Settings that lists printers and their jobs, adds
and configures them, and, the part that justifies more than a simple list,
tells the user *which layer* failed when a printer does not work. It talks to
CUPS (the only print system on every distro we ship for). It is not tied to
one distro and it ships no print driver.

## Where this comes from

A field report (`~/Documents/arch-xprinter-tspl-troubleshooting.md`, summarised
here so the plan stands alone): a cheap USB 4×6 thermal label printer
(Xprinter/Zijiang family, VID:PID `0416:5011`, advertised 300 dpi, speaks TSPL)
took hours to get printing. Almost none of that time went to fixing; it went to
finding out *where* the failure was. In the order it was met:

| # | What went wrong | Layer |
| - | --- | --- |
| 1 | Printer appeared and vanished in `lsusb`; its USB string said "Virtual Com Port" although its interface class is 7 (Printer) | USB |
| 2 | `usblp` node vanished, a `tee` then created a *regular file* at `/dev/usb/lp0` | device node |
| 3 | Guessed Zebra ZPL / EPL; the self-test (hold FEED while powering on) said TSPL | printer language |
| 4 | CUPS libusb backend: "USB transaction timeout during read", because the printer claims bidirectional USB and cannot do it | CUPS backend |
| 5 | A raw TSPL write to the node printed; that one fact split hardware+USB from CUPS+filters | method |
| 6 | Node name changed after a power cycle (fixed with a udev symlink) | device node |
| 7 | Advertised 300 dpi; 203 dpi gave the right physical size | queue settings |
| 8 | Queue deleted by accident, recreated by hand | queue |
| 9 | Job "ran", label fed, blank. Log: media `4x5.Borderless` not 4×6, `cupsCompression=4294967295`, `rangecheck in .putdeviceprops`, `Sent 0 bytes`, "No pages were found." | filters / PPD |

The report's last state is unresolved (item 9), and several changes were made
at once (quirk, `usblp` blacklist, udev rule, driver, backend), so which of
them mattered was never isolated. Phase 0 does that.

What we take from it, and it holds for any printer, not only labels:

1. Printing is a chain, and a good page shows the chain and marks the first
   broken link (the "ladder").
2. The most useful single test is *send a job that skips the filters*. If that
   prints, the fault is in rendering or the driver, not USB or the printer.
3. Most "it printed nothing" cases leave evidence the user cannot read (the
   CUPS error log is root-only) but CUPS also reports it over IPP.
4. Two settings are wrong far more often than anything else: paper size and
   resolution. Show them next to the queue.
5. A copy-able diagnostic report turns "it doesn't work" into something
   fixable by someone else.

## Goals and non-goals

Goals

* List printers (USB, network, shared) with state, reasons in words
  ("Out of paper", "Cover open", "Toner low") and ink/toner levels where CUPS
  has them.
* Show and cancel jobs; resume a queue CUPS stopped after an error.
* Add a printer without a terminal: detected USB devices, network printers
  CUPS discovers, or a typed address. Pick a driver automatically when there is
  a trustworthy match, otherwise say so plainly.
* Per-printer settings the user can understand: paper size, resolution,
  colour/mono, duplex, quality, and for label printers darkness/speed when the
  driver exposes them. Set as the queue default.
* The ladder, two test prints (through the driver, and skipping it), a ruler
  test for resolution, and "Copy diagnostic report".
* Works with no CUPS, a stopped CUPS, a socket-activated CUPS, and with no
  privileges: what cannot be done says why and what to do.
* Target consistent behavior on the Arch, Debian/Ubuntu and Fedora release
  families, with guidance for openSUSE. Actual policy/hardware qualification is
  tracked separately; the page never runs a package manager.

Non-goals

* No driver of our own: no shipping PPD, raster filter or document-to-TSPL/ZPL
  converter. The bounded diagnostic samples above are the only language output;
  see "Not in this plan".
* No print dialog: applications print through the Print portal or GTK/Qt
  dialogs and CUPS. This page configures what they see.
* No print server features: sharing, CUPS web admin, policies, quotas,
  authentication to remote servers, IPP Fax.
* No scanner/MFP support (that is SANE; separate).
* No Bluetooth pairing for printers (the Bluetooth page owns pairing; a paired
  Bluetooth printer shows up only if CUPS lists it).
* No guessing from the network: no port scanning. Discovery is what CUPS
  already reports (DNS-SD/IPP).

## Design

### Talk to CUPS over IPP, unprivileged (D1)

Reads, own-job cancellation and explicit test submissions go straight to the
configured cupsd over IPP. The default is `/run/cups/cups.sock`; system and user
`client.conf`, `CUPS_SERVER` and encryption settings determine the actual target.
Cleartext TCP `host[:port][/version=1.0|1.1]` and supported IPP authorities are
also accepted. No request silently changes servers. A small IPP client in Zig
(`src/printing/ipp.zig`: encoder, bounded decoder, HTTP/1.1 transport), in the spirit of `src/dbus`: no new
library, no libcups ABI to match across four distro families, and no
glib. It queries printers, attributes, own jobs, PPD metadata and PPD content,
cancels an individual own job, submits explicit tests, and creates/inspects/
cancels notification subscriptions. Discovery and administrative changes use
the privileged APIs below. Any future cancel-all-own action must use
Cancel-My-Jobs rather than Cancel-Jobs; that bulk action is not exposed here.

Alternative: link libcups. Its transport, authentication, configuration and
destination APIs avoid reimplementing substantial compatibility behavior.
The bounded client supports a documented Unix/cleartext TCP subset, not full
libcups compatibility. TLS, authentication, escaped client configuration and
NSS/Avahi mDNS resolution are not implemented. DNS, connect, upload and response
share one three-second request deadline and the page cancellation path. See the
qualification findings below before extending compatibility claims.

The decoder treats the response as untrusted (cupsd can be remote through
`CUPS_SERVER`): bounded lengths and counts, no recursion beyond collections,
text fields length-capped and stripped of control characters before they reach
a widget.

### Live only while visible, no polling

Same rule as the Services page. The page is live while it is on screen
(`show` from `printers.build`, `hide` from `selectPage`/`detachSettings`). Hiding
joins the cancellable worker and releases local sockets, matches and watches;
subscription cancellation is a best-effort nonblocking send. While live:

* **cupsd changes:** a page-owned system-bus listener validates the notifier
  interface/path/member and authenticates each unique sender through bus
  credentials. CUPS's notifier does not acquire a well-known service name.
  The worker requests an indefinite `dbus://` printer subscription and verifies
  the granted lease, querying it separately when creation omits the duration.
  If unavailable, finite or unauthorized, the page keeps explicit/action-driven
  refresh; no polling or renewal timer runs. Default desktop delivery remains a
  qualification gate. An inotify watch on the local socket's parent also detects
  daemon disappearance/recreation without contacting a host service manager.
* **USB hotplug:** a kernel uevent listener (netlink `NETLINK_KOBJECT_UEVENT`,
  subsystems `usb` and `usbmisc`) that triggers one sysfs rescan. The scan is
  a pure function from a sysfs root to a list of printer-class devices
  (class 7, VID:PID, manufacturer/product/serial strings, bound driver, the
  matching `/dev/usb/lp*` node and its file type). Debounce: a plug event
  arrives as a burst.
* Work happens on a worker thread that signals an eventfd; nothing blocks the
  compositor loop. The IPP client has deadlines, because a half-dead cupsd
  must not hang the page.

### The ladder

For the selected printer, one row per layer. Each row is pass / fail / unknown
(not applicable or cannot tell), with a one-line reason; the first failing row
is expanded with its fix. Layers by connection kind:

USB printer

1. **Found on USB.** Interface class 7 from sysfs. Fail text names what was
   seen ("a device 0416:5011 is attached but is not a printer class device").
   Never read the product string as truth (finding 1 above).
2. **Backend access path.** Report the matched `/dev/usb/lp*` node, if any,
   and its file type. A missing `usblp` node is normal for the CUPS libusb
   backend and for `ipp-usb`; it cannot fail this rung. A queue whose backend
   explicitly uses that node can fail if it is missing or a regular file.
   `stat` cannot prove CUPS's access permissions or USB communication; those
   remain unknown without backend evidence. The page never writes to a node.
3. **CUPS running.** IPP answers. If not, distinguish installation evidence
   from a running/reachable scheduler; offer "Start CUPS" only through the
   existing privileged systemd path (D3). No failed request proves that a unit
   is disabled or that CUPS is absent.
4. **Queue exists and accepts jobs.** Exists, `printer-state`, `printer-is-
   accepting-jobs`, stopped reasons (`printer-state-reasons`).
5. **Backend reaches it.** The queue's device URI points at the device that
   rung 1 found (a stale `usb://` serial or a vanished `file`/vendor URI is
   the usual cause of "was working yesterday"); last job's backend message if
   any.
6. **Settings fit the media.** Queue default page size and resolution against
   what the user says they load (asked once for label printers); mismatch is
   the finding-7/9 case.
7. **Last job outcome.** From the last job: state, sheets
   completed, `job-state-reasons`, `job-printer-state-message`. A job
   `completed` with 0 sheets and a message like "No pages were found." is
   reported as *finished; no pages reported*, with the filter message shown.
   Missing counters, zero counters alone and `completed` do not prove that
   paper emerged or that it was blank. Omitted/private attributes and absent
   history stay unknown; this page cannot recover every filter log over IPP.

Network printer: a bounded Get-Printer-Attributes on an exact `ipp://` device
URI replaces rungs 1–2; it never scans hosts or ports. TLS, DNS-SD service URIs
and mDNS-only names cannot be checked by this transport and retain unavailable
or unknown evidence. CUPS's own backend can still support those connections;
a direct reachability result is separate from CUPS backend success.

The ladder only *reports*. Each fix is an explicit button, and none runs
unasked.

### Two tests, and why there are two (D4)

* **Test page through the driver:** CUPS's own test page, or a small PDF
  sized to the queue's media with a border and a 1-inch square. Exercises
  the whole chain.
* **Test skipping the filters:** Print-Job with `document-format`
  `application/vnd.cups-raw` (what `lp -o raw` does) carrying a tiny
  command-language test chosen from the known-devices table or the printer's
  `printer-device-id` (`CMD:` field: `TSPL`, `ZPL`, `EPL`, `CPCL`, `PCL`,
  `POSTSCRIPT`, ...). It exercises backend, USB and the printer, and not
  filters or PPD. Isolated CUPS checks passed a bounded binary payload unchanged
  through synthetic PPD queues on all four release families; actual printer
  command execution and backend/USB behavior remain hardware gates.

Implementation refinement: only complete `CMD:`/`COMMAND SET:` tokens count as
device-ID language evidence. The known-devices table supplies a visible hint,
never permission to select a language automatically from a shared USB ID. A
user confirms the language and each individual print. Availability of this
explicit diagnostic tool does not certify physical output or every installed
backend/policy. The [isolated raw checks](printers-qualification.md) qualify the
tested CUPS software path only.

Read together: raw prints and filtered does not → filters/PPD/media; neither
prints → backend/USB/printer/paper. This is finding 5 as a button pair.

If the printer's language is unknown (no `CMD:` and no table hit), a
**"Which language does it speak?"** step sends one probe label per language,
one at a time, asking "did anything print?" after each. The page also says,
in words, to hold FEED while powering on for the self-test sheet, since that
page names the language and the real resolution.

### Resolution and size: a ruler, not trust

Product listings lie about dpi (finding 7). For queues the user marks as a
label printer (or whose driver reports a label media class), "Check scale"
prints a rectangle of known size (for example 2 × 3 in) and asks what was
measured, in the user's unit. If it is off, the page suggests the supported
resolution that corrects it and sets it as the queue default. The ratio is
computed, not looked up. For other printers, margins and page size are shown
and editable from the driver's options; no ruler.

### Adding a printer (D2)

Sources, in order shown:

1. Devices returned by the helper's `DevicesGet` CUPS discovery operation
   (USB, DNS-SD, socket and validated installed vendor backends), through the
   privileged path. An authorization failure means
   discovery is unavailable, not that no devices exist.
   Devices CUPS lists whose URI is already used by a queue are hidden.
2. Detected USB printers that CUPS did not list (the ladder's rungs 1–2 data):
   shown with *why* it is missing ("the kernel driver did not create a
   device", "CUPS cannot open it") instead of silently absent.
3. A typed address: `ipp://`, `ipps://`, `socket://`, `lpd://`, and hostnames
   when entered as network addresses. Typed schemes are allow-listed. No
   `file:`, credential-bearing `smb:`, scripts or arbitrary typed vendor
   backends are accepted. Discovered vendor URIs must exactly match a current
   helper result and pass the separate discovered-backend validation.

Driver choice, no driver of ours:

1. **Driverless first:** an IPP Everywhere / AirPrint printer, or a USB printer
   exposed over IPP by `ipp-usb` when that is present, is added with the
   `everywhere` model. CUPS 2.4 documents that model name and queries the IPP
   device; it can generate a PPD internally, so "driverless" does not mean
   "no PPD file" on CUPS 2.x. **(verify)** actual add behavior per version.
2. **Match by device ID:** retrieve PPD metadata and compare the IEEE 1284
   make/model/device ID conservatively. The documented CUPS-Get-PPDs API
   does not promise `ppd-match` rankings or a driver package name. Matching
   and any optional distro package attribution need their own verified
   implementation; ambiguous matches require an explicit choice.
3. **No match:** say so. Offer a *raw queue* (jobs pass through untouched,
   fine for applications that already emit the printer's language), and show
   the known-devices note ("this model speaks TSPL; ordinary PDF printing needs
   a third-party TSPL driver, not shipped in your distribution's repositories"),
   with the project name and URL, not an install command we cannot vouch for.
   We do not download or install third-party code.

New queues are created enabled and accepting with a unique validated name.
The UI refreshes names and refuses known collisions before calling the helper;
"Remove" has a named confirmation and is separate from "Disable". Queue rename
has its own confirmation and rejects known active/held jobs. The helper itself
uses a non-atomic clone/delete operation, so concurrent administration remains
a race; this is not an atomic create-or-rename guarantee. After rename, the page
checks refreshed queue identities and migrates personal defaults/observations.
See the [actual helper checks](printers-qualification.md) for collision refusal,
pending-job refusal and preservation limits.

### Known devices: a small data table

`src/printing/known_devices.zig` stores bounded hardware observations and a
third-party driver project link. Its initial entry is:

```
vid:pid=0416:5011  language_hint=TSPL  resolution_hint_dpi=203  provisional=true
note="One unresolved field report; confirm command language and physical scale."
```

Fields describe observations about the *hardware*, never instructions we run.
The initial entry is explicitly **provisional**, sourced from the unresolved
single-device field report above; it is not a universally verified TSPL/203-dpi
identification for every device sharing `0416:5011`. Its note calls out both
the advertised 300 dpi and the reported 203 dpi measurement. It supplies a
language-probe/media hint, not an automatic language or resolution default.
Future verified entries need isolated hardware evidence and its source in the
commit message.

### Privileged actions (D3)

Creating, modifying and removing queues, and starting CUPS, need rights an
unprivileged user and a compositor must not have. In order of preference:

1. **`cups-pk-helper`** (`org.opensuse.CupsPkHelper.Mechanism` on the system
   bus; it is what GNOME Settings and `system-config-printer` use). Polkit
   handles the authorization and our polkit agent already shows the prompt. We
   write no root code. Starting CUPS is a separate service-manager action;
   cups-pk-helper is not a general service controller. Its installed interface
   was checked in four isolated release-family containers; stock desktop
   authorization remains unqualified. It is an optional runtime recommendation
   documented in README, not a generated binary-library dependency. The helper
   targets its canonical local server, so custom Unix and remote endpoints are
   not allowed to administer an unrelated local scheduler.
2. If it is absent: the page is read-only for those actions and says exactly
   which package is missing, by name for the detected distro (`/etc/os-release`
   `ID`/`ID_LIKE`), without running it.
3. Only if Phase 0 shows something the user needs that neither covers (for
   example a CUPS USB quirk, if it proves necessary and survives package
   updates), a narrow `rediwm-printers-helper` under `pkexec`, built to the
   rules in `src/accounts_helper/AGENTS.md`: argv arrays only, absolute paths,
   every field validated, a polkit action in `data/`, kept out of greeter mode.
   The root-code list in `AGENTS.md` must be amended in the same change.

Writing a USB quirk is the one thing that needs a decision (D5): the quirk may
be unnecessary (the working queue in the report used a backend that writes the
node and so avoids libusb), and a file in `/usr/share/cups/usb/` is owned by
the package. **(verify)** whether cupsd reads every file in that directory, so
a separate drop-in would survive upgrades. If a quirk is needed we *tell the
user*, with the exact line and where to put it; we do not edit package files.

### Diagnostic report

"Copy diagnostic report" puts plain text on the clipboard; it is never sent
anywhere. It includes allow-listed distro/version information, ladder verdicts,
USB VID:PID/interface/node evidence, URI scheme/connection class, bounded media
and resolution data, reported job state/sheets and user-recorded test outcomes.
Credentials, URI authorities/paths, arbitrary queue/document/user names, USB
serials and freeform messages are excluded. Known failure messages inform the
ladder but are not copied verbatim into the report. No job content or privileged
log read is involved.

### Page layout

A printer selector leads to the selected queue's details and controls. The
scrollable content includes:

* header: name, model, status sentence, ink/toner bars if reported;
* ladder (collapsed to one line when everything passes);
* jobs: list with cancel; "Resume printer" when stopped;
* settings: paper size, resolution, colour, duplex, quality, driver options
  as the driver's own groups, "Set as default";
* tools: Test page, Test without driver, Check scale, Copy report;
* danger zone: Remove printer (confirmation naming it).

Empty states: CUPS not installed (say what and how, by distro), CUPS stopped,
no printers ("Add a printer" with detected USB first), printer unplugged
(ladder shows rung 1 failing, settings dimmed).

All controls come from `ui/widgets/`; the ladder uses text as well as state
styling. English strings follow current repository conventions. The shared
i18n/extraction system is still a separate planned dependency.

## Decisions applied

* **D1:** a bounded Zig IPP/HTTP client, with explicit compatibility limits.
* **D2:** CUPS discovery, USB sysfs and typed allow-listed network addresses;
  no scans or guessed driver identity.
* **D3:** the existing cups-pk-helper and systemd APIs; no new root helper.
* **D4:** separately confirmed driver/raw/ruler samples and one language probe
  at a time, with user observations distinct from CUPS job state.
* **D5:** advice only for USB quirks; no package-file or device-node writes.
* **D6:** preserving per-user defaults, visible environment overrides and a
  separate privileged system-default action. Applications can retain their own
  printer choice; this page does not override their print dialogs.

## Phases

### Phase 0: isolated software evidence captured; hardware gates open

The isolated software checks are recorded below and in the qualification file.
The manual hardware exercise still requires the author's printer and one
ordinary printer; it is not part of an automated test or permission to touch
host queues/services.

* Rebuild a throwaway queue from scratch for the label printer and find the
  *minimal* set of changes (quirk vs `usblp` vs udev symlink vs backend choice)
  and the cause of `cupsCompression=4294967295` (queue PPD vs the installed
  Ghostscript/cups-filters). Decides whether a quirk note exists at all.
* Verify every **(verify)** item above on Arch plus one of each other family in
  the existing podman setup (never the live session; see the release notes).
* Confirm what an unprivileged user can read over IPP (jobs of others, device
  list, PPD list, subscriptions) on a default install.
* Output: facts here, and fixtures for Phase 1 (recorded IPP exchanges).

#### Evidence and remaining gates, 2026-10-16

The host scheduler, its queues/jobs and attached printers were not used for
qualification. Automated UI exchanges are synthetic. Separate disposable
containers ran actual CUPS/helper software with private sockets, buses and state;
their only output backend captured a bounded binary fixture into a private file.
The [qualification record](printers-qualification.md) contains exact image IDs,
package versions, commands, outcomes and limits.

Observed software evidence:

* Arch CUPS 2.4.20, Debian 2.4.10, Ubuntu 2.4.7 and Fedora 2.4.19 exposed the
  tested helper ABI and packaged notifier. Indefinite subscription grants,
  explicit cancellation and raw bytes through a synthetic PPD queue passed in
  each container. This does not establish hardware output or stock policy.
* Debian's real helper renamed an idle throwaway queue, refused an existing
  destination and refused a paused queue's pending job. Source review of helper
  0.2.6/0.2.7 establishes its non-atomic clone/delete behavior and partial error/
  option-preservation limits; no stronger rename guarantee is claimed.
* Real helper option checks exposed duplicate IPP defaults from the generic
  default-attribute API. The PPD-aware API updates actual driver choices.
  Colour/quality IPP fields can disagree with the PPD, and deleting an override
  can change reported defaults. The page verifies refreshed driver values and
  keeps unverified outcomes explicit; the qualification record preserves the
  actual before/after results rather than inferring success from an empty error.
* The unit suite covers bounded/hostile codecs and identity, allocation failures,
  URI validation, driver matching, PPD declarations/dimensions, PDF offsets,
  language samples, calibration, preserving defaults and private observations,
  socket watches, notifier credentials and active DNS cancellation.
* `tests/printers.py` exercises the real Settings UI with private scheduler,
  helper and service-manager fixtures. It covers confirmed test bytes, setup,
  defaults/options, guarded rename/removal, failures, remote administration
  isolation, privacy and idle/hidden/closed worker lifetime. Current validation
  commands and dependencies are in [TESTING.md](../../TESTING.md).

Useful upstream constraints remain:

* Raw printing/queues and PPD drivers are deprecated. CUPS documents raw jobs
  as bypassing filters; a CUPS completed state still says nothing about paper.
  [Printing guidance](https://openprinting.github.io/cups/),
  [driver migration](https://openprinting.github.io/cups/drivers.html).
* Default policies place discovery and queue administration behind permissions;
  own-job cancellation, privacy and retained history also depend on policy.
  [CUPS policy template](https://github.com/OpenPrinting/cups/blob/v2.4.20/conf/cupsd.conf.in).
* PPD metadata does not promise ranked matches or package names. `everywhere`
  queries an IPP device and can generate a PPD on CUPS 2.x.
  [IPP extensions](https://openprinting.github.io/cups/doc/spec-ipp.html),
  [lpadmin](https://openprinting.github.io/cups/doc/man-lpadmin.html).
* libusb can detach the kernel driver and does not require `/dev/usb/lp*`.
  Source supports separate quirk files, but no isolated hardware evidence shows
  that this printer needs one. No automatic quirk change is implemented.
  [USB backend source](https://github.com/OpenPrinting/cups/blob/master/backend/usb-libusb.c).

Open acceptance work: isolate the original label-printer fault, test one ordinary
printer, verify real driverless discovery/creation and hardware-specific driver
matches, measure physical media/ruler output, exercise stock unprivileged polkit
and notifier delivery on installed release-family desktops, and check newly
created queues in application/portal print dialogs. An openSUSE image/release
matrix is absent. Shared-USB-ID hints remain provisional; TLS/authenticated
remote CUPS, mDNS resolution and the repository-wide i18n pipeline are outside
the implemented subset. No hardware gate is marked passed by the software tests.

### Phase 1: status, diagnostics and explicit tests — software implemented

`src/printing/` and `control_center/sections/printers.zig`.

* Printer list, state in words, jobs, ink/toner.
* The ladder, rungs 1–7, from IPP plus sysfs.
* Cancel own jobs; resume a stopped queue where allowed.
* Hotplug via uevents; CUPS events or action-driven reload.
* Empty states; Copy diagnostic report.
* Separately confirmed driver PDF, raw language sample and ruler tests.
* Acceptance remains open: the software matrix does not establish physical output.
* Gate: ladder verdicts match reality on the label printer for each induced
  fault (unplugged, queue stopped, wrong URI, filter fail).

### Phase 2: setup and configuration — software implemented

* Add flow (discovery/typed URI, driverless/PPD match/raw), guarded removal,
  descriptions, confirmed queue rename, connection editing and personal/system
  defaults.
* Driver options as groups from the PPD or IPP `-supported` attributes; media
  and resolution in plain words.
* Privileged actions through cups-pk-helper; absence handled.
* Label printers: media class, "Check scale", language probe, known-devices
  hints.
* Gate: a printer is added, configured, test-printed and removed with no
  terminal on Arch and one other family.

### Phase 3: integration implemented; distro/hardware qualification remains

* Per-distro guidance strings (missing package names), `os-release` aware.
* Reload on cupsd restart, graceful loss of CUPS mid-use.
* `AGENTS.md`, `TESTING.md`, README optional dependencies and Settings search
  keywords are updated. No printing package is added to generated library
  `DEPENDS`; release tooling has no optional `RECOMMENDS` facility.
* Shared i18n extraction remains blocked on the repository-wide i18n project.
* The isolated software matrix is recorded; stock desktop and hardware gates
  above remain open.

### Optional: our own helper (only if Phase 0 requires it)

See D3 item 3. Not scheduled.

## Tests

* `zig build test` includes `src/printing/tests.zig`; `zig build test-printers`
  also runs the private Settings integration. Run at scale 1 and 1.5, and check
  the ReleaseSafe build as described in [TESTING.md](../../TESTING.md).
* Unit fixtures cover bounded IPP/HTTP and collections, response framing and
  version privacy, full validated identities, URI allow-lists, conservative
  driver matching, USB/sysfs/node types, pure ladder verdicts/report masking,
  PPD choices and dimensions, allocation failure, test PDF geometry/xref,
  language samples, two-axis resolution suggestions, preserving preferences,
  socket events, notifier authentication and cancellable DNS.
* `tests/printers.py` uses private Unix/TCP schedulers and a private D-Bus helper/
  service-manager fixture. A noninstalled `LD_PRELOAD` connect shim redirects
  only the canonical CUPS socket during administration tests, so the production
  local-server safety gate is exercised without contacting host CUPS. Confirmed
  documents terminate in fixture memory; no real print backend is involved.
* Disposable-container qualification is separate from the normal test target:
  [exact results and reproduction](printers-qualification.md). Its capture-only
  backend establishes tested software passthrough, not physical printing.
* Never run automated tests against the host scheduler or a real printer. The
  USB layer uses fixture trees; physical USB, paper and desktop policy checks
  remain explicit manual acceptance work.
* Idle workers block without periodic queries. Integration checks per-thread
  context switches and scheduler requests, and verifies that hiding or closing
  Settings cancels I/O, joins its worker and releases local activity.

## Risks and open questions

* One physical test printer. The generic parts (ladder, test pair, media
  check, report) are testable against a fake and any printer; the quirks and
  device facts are only as good as the hardware we have. The known-devices
  table says so in each entry.
* CUPS behaviour differs between versions (2.3/2.4, cups-filters 1.x/2.x, the
  new libcups3/`cups-browsed` split, `ipp-usb` presence). Phase 0 checks the
  families we ship; anything newer is reported honestly as "unknown".
* cups-pk-helper is not installed everywhere. If it is missing on a family,
  D3 item 2 is the user experience there, and it should be acceptable, not an
  error.
* Remote cupsd (`CUPS_SERVER=host`): cleartext reads and bounded user requests
  are supported; local administrative actions are disabled. TLS/authenticated
  endpoints are unsupported. The resolver uses ordinary DNS and hosts files,
  not NSS/Avahi mDNS; direct `ipps://` and DNS-SD reachability stay unavailable.
* Indefinite subscriptions avoid renewal wakeups. Cancellation is best effort:
  a failed send or crash can leave a CUPS-owned subscription; local listeners
  and sockets are still closed. Server-side cleanup/delivery remains part of
  desktop policy/lifetime qualification.
* Rename is a helper clone/delete operation, not atomic. Concurrent changes,
  hidden jobs and arbitrary option/history preservation need care; refresh and
  named confirmation do not turn it into a transactional server operation.
* Sandboxed callers (`[[sandbox_allow]]`) and the security-context filter are
  untouched; the page runs inside the compositor's own process, like the other
  Settings pages.
* The Print portal path (rediwm-pdf) is separate and unchanged. A queue this
  page creates must be visible to it; check in Phase 2.
* Hotplug without a udev library: kernel uevents are enough for "something
  changed, rescan", but their format is a kernel ABI; keep the parser tiny and
  tolerant.

## Not in this plan

* **A print driver of our own** (PPD generation, PDF→raster→TSPL/ZPL, a CUPS
  filter or backend). Decided against: unsupported printers get a clear
  explanation, a raw queue, and a pointer to the third-party driver, not a
  driver from us.
* Scanning, MFPs, SANE.
* CUPS server administration, sharing, quotas, authenticated remote servers.
* Print preview, a print dialog, a print-to-PDF queue.
* Bluetooth printer pairing and Bluetooth backends.
* Network or port scanning, unsolicited device probes, and guessed endpoints.
  A bounded request to an exact selected/discovered IPP URI is the only direct
  reachability check.
