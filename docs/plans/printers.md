# Plan: Printers page in Settings (setup, status, and "why didn't it print")

Status: draft, 2026-10-13. Nothing is built. Decisions D1–D6 are proposed,
not taken. Phase 0 settles the facts marked **(verify)** before any UI work.

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
* Same behaviour on Arch, Debian/Ubuntu, Fedora and openSUSE (our release
  families); nothing in the page assumes a package manager.

Non-goals

* No driver of our own (no PPD, no raster filter, no TSPL/ZPL generator);
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

Read and the user-level actions go straight to cupsd over IPP on its unix
socket (`/run/cups/cups.sock` by default; honour `CUPS_SERVER` and
`~/.cups/client.conf` like every CUPS client, so tests and unusual setups need
no hook). A small IPP client in Zig (`src/printing/ipp.zig`: encoder, bounded
decoder, HTTP/1.1 over the socket), in the spirit of `src/dbus`: no new
library, no libcups ABI to match across four distro families, and no
glib. Operations needed: Get-Printers / Get-Printer-Attributes, Get-Jobs /
Get-Job-Attributes, Cancel-Job, Cancel-Jobs (own jobs), Print-Job (tests),
CUPS-Get-Devices, CUPS-Get-PPDs, Pause/Resume-Printer where allowed.

Alternative (not chosen): link libcups. Smaller code, but a new link-time
dependency in every release tarball and the build containers, for a protocol
whose subset we need is under 1,000 lines.

The decoder treats the response as untrusted (cupsd can be remote through
`CUPS_SERVER`): bounded lengths and counts, no recursion beyond collections,
text fields length-capped and stripped of control characters before they reach
a widget.

### Live only while visible, no polling

Same rule as the Services page. The page is live while it is on screen
(`show` from `printers.build`, `hide` from `selectPage`/`detachSettings`); dark
means no subscription, no sockets, nothing held. While live:

* **cupsd changes:** a CUPS event subscription if one can be had without
  polling. cupsd can notify over D-Bus (`org.cups.cupsd.Notifier`) once a
  subscription exists, and `Create-Printer-Subscription` with `dbus://` is the
  standard route. **(verify)** that it is present and readable by an
  unprivileged user on each family. Fallback, if not: reload on page
  show, on the user's action, and when a job we started changes; never on a
  timer.
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
2. **Kernel device node.** For the matched device: `/dev/usb/lp*` exists and is
   a character device, and the user/CUPS can reach it. Fail: node missing
   (`usblp` not loaded or deliberately blocked), or *a regular file sits where
   the node should be* (finding 2). The page never writes to a node itself; the
   check is `stat`.
3. **CUPS running.** IPP answers. If not, say whether the socket exists and
   whether the unit is enabled; offer "Start CUPS" only through the same
   privileged path as the rest (D3).
4. **Queue exists and accepts jobs.** Exists, `printer-state`, `printer-is-
   accepting-jobs`, stopped reasons (`printer-state-reasons`).
5. **Backend reaches it.** The queue's device URI points at the device that
   rung 1 found (a stale `usb://` serial or a vanished `file`/vendor URI is
   the usual cause of "was working yesterday"); last job's backend message if
   any.
6. **Settings fit the media.** Queue default page size and resolution against
   what the user says they load (asked once for label printers); mismatch is
   the finding-7/9 case.
7. **Last job printed something.** From the last job: state, sheets
   completed, `job-state-reasons`, `job-printer-state-message`. A job
   `completed` with 0 sheets and a message like "No pages were found." is
   reported as *finished but printed nothing*, pointing at the filter stage
   (item 9), not at USB.

Network printer: reachable (IPP Get-Printer-Attributes on its URI, with a short
deadline) replaces rungs 1–2; the rest apply. A printer reported by DNS-SD but
not reachable says so (different subnet, VPN, firewall) without scanning.

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
  filters or PPD. **(verify)** that cupsd passes it through unchanged on a
  queue that has a PPD on all four families.

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

1. Printers CUPS already lists (`CUPS-Get-Devices`: USB, DNS-SD, socket).
   Devices CUPS lists whose URI is already used by a queue are hidden.
2. Detected USB printers that CUPS did not list (the ladder's rungs 1–2 data):
   shown with *why* it is missing ("the kernel driver did not create a
   device", "CUPS cannot open it") instead of silently absent.
3. A typed address: `ipp://`, `ipps://`, `socket://`, `lpd://`, and hostnames
   resolving to those. Allow-list of schemes. No `file:`, no `smb:` (the
   latter carries credentials), no scripts or vendor backends the user types.

Driver choice, no driver of ours:

1. **Driverless first:** an IPP Everywhere / AirPrint printer, or a USB printer
   exposed over IPP by `ipp-usb` when that is present, is added with the
   `everywhere` model; no PPD. **(verify)** the model name per CUPS version.
2. **Match by device ID:** `CUPS-Get-PPDs` with the device's IEEE 1284 ID;
   take the best match CUPS ranks (`ppd-match`), show make/model and the
   driver's package name so the user can see what they get.
3. **No match:** say so. Offer a *raw queue* (jobs pass through untouched,
   fine for applications that already emit the printer's language), and show
   the known-devices note ("this model speaks TSPL; ordinary PDF printing needs
   a third-party TSPL driver, not shipped in your distribution's repositories"),
   with the project name and URL, not an install command we cannot vouch for.
   We do not download or install third-party code.

New queues are created enabled and accepting, named from the model with
characters CUPS allows, and *never* silently replace an existing queue of the
same name (finding 8: the report lost queues to accidents; deleting needs a
confirmation that names the printer, and "Remove" is separate from "Disable").

### Known devices: a small data table

`src/printing/known_devices.zig` (or an embedded TOML like theme presets), keyed
by `vid:pid` and optionally IEEE 1284 make/model:

```
0416:5011  command_set=TSPL  resolution=203  media=4x6  bidirectional=false
           note="Advertises 300 dpi; measured 203. USB class 7, product string 'POS Label Printer'."
```

Fields are facts about the *hardware*, never instructions we run. It feeds the
language probe, the default resolution, the ladder's rung-6 hint, and the
report. It starts with the one device we have tested and grows by pull request.
An entry means "verified on that hardware, source in the commit message".

### Privileged actions (D3)

Creating, modifying and removing queues, and starting CUPS, need rights an
unprivileged user and a compositor must not have. In order of preference:

1. **`cups-pk-helper`** (`org.opensuse.CupsPkHelper.Mechanism` on the system
   bus; it is what GNOME Settings and `system-config-printer` use). Polkit
   handles the authorization and our polkit agent already shows the prompt. We
   write no root code. Present on the families we ship for **(verify)** and
   packaged as a recommended, not required, dependency.
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
anywhere. Contents: distro and CUPS version, the ladder with reasons, the
printer's VID:PID, interface class and node type, queue URI with credentials
and hostnames of *other* machines masked, queue options, the last N jobs'
state/sheets/reasons/messages, `printer-state-reasons`, and
which tests were run with their outcome. No document names, no user names,
no job content, no log lines we cannot read without root.

### Page layout

Left: printers (icon, name, state dot, "Default" tag). Right, for the selected
printer, top to bottom:

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

All controls come from `ui/widgets/` (no hand-drawn controls); text through the
i18n mechanism; the ladder uses the existing shell icons plus text, never
colour alone.

## Decisions to take

* **D1** hand-rolled IPP client vs libcups: proposed hand-rolled.
* **D2** discovery: only what CUPS reports + USB sysfs + typed address:
  proposed yes, no scanning.
* **D3** privilege path: cups-pk-helper first, no helper of ours unless Phase 0
  proves a need: proposed.
* **D4** test pair (through driver / skipping filters) and the language
  probe: proposed.
* **D5** USB quirks: advise only, never edit package files: proposed.
* **D6** per-user vs system default printer: per-user default lives in
  `~/.cups/lpoptions` and is what applications' dialogs honour; the CUPS-wide
  default needs rights. Proposed: set the per-user default, offer the
  system default only if the privileged path is present.

## Phases

### Phase 0: facts, no UI (small)

On the author's printer and on at least one printer that needs no special
handling; record results in this plan.

* Rebuild a throwaway queue from scratch for the label printer and find the
  *minimal* set of changes (quirk vs `usblp` vs udev symlink vs backend choice)
  and the cause of `cupsCompression=4294967295` (queue PPD vs the installed
  Ghostscript/cups-filters). Decides whether a quirk note exists at all.
* Verify every **(verify)** item above on Arch plus one of each other family in
  the existing podman setup (never the live session; see the release notes).
* Confirm what an unprivileged user can read over IPP (jobs of others, device
  list, PPD list, subscriptions) on a default install.
* Output: facts here, and fixtures for Phase 1 (recorded IPP exchanges).

### Phase 1: read-only page (medium)

`src/printing/{ipp,cups,usb_sysfs,ladder,known_devices}.zig`,
`control_center/sections/printers.zig`.

* Printer list, state in words, jobs, ink/toner.
* The ladder, rungs 1–7, from IPP plus sysfs.
* Cancel own jobs; resume a stopped queue where allowed.
* Hotplug via uevents; CUPS events or action-driven reload.
* Empty states; Copy diagnostic report.
* Test page through the driver; raw test (Phase 1b if the passthrough check
  needs work).
* Gate: ladder verdicts match reality on the label printer for each induced
  fault (unplugged, queue stopped, wrong URI, filter fail).

### Phase 2: set up and configure (medium)

* Add flow (sources, driverless/PPD match/raw), remove, rename, set default.
* Driver options as groups from the PPD or IPP `-supported` attributes; media
  and resolution in plain words.
* Privileged actions through cups-pk-helper; absence handled.
* Label printers: media class, "Check scale", language probe, known-devices
  hints.
* Gate: a printer is added, configured, test-printed and removed with no
  terminal on Arch and one other family.

### Phase 3: polish and distro coverage (small)

* Per-distro guidance strings (missing package names), `os-release` aware.
* Reload on cupsd restart, graceful loss of CUPS mid-use.
* `AGENTS.md`, `TESTING.md`, release notes, Settings search keywords, i18n
  extraction for the new strings.

### Optional: our own helper (only if Phase 0 requires it)

See D3 item 3. Not scheduled.

## Tests

* **Unit (Zig):** IPP encode/decode round-trips and hostile inputs (truncated,
  oversized counts, nested collections, bad UTF-8); ladder verdicts as a pure
  function of (sysfs snapshot, IPP snapshot); sysfs scan over fixture trees,
  including the regular-file-at-the-node case and the `0416:5011` "Virtual Com
  Port" string; URI allow-list; report masking.
* **Integration (`tests/printers.py`):** a fake cupsd on a private unix socket,
  selected through `CUPS_SERVER` (a real CUPS variable, so no test hook), speaking
  the IPP subset above, with scripted failure modes: not running, stopped
  queue, job completed with zero sheets and the "No pages were found." message,
  slow server, garbage reply. The page is driven over IPC like the other
  Settings pages; clicks use the settle/wait rules in `TESTING.md`.
* **Never** the real cupsd or a real printer in a test: the author has a
  working queue attached. Hardware checks (USB layer, real test prints) are
  manual and written into the Phase 1/2 gate notes.
* The sysfs layer cannot be faked end to end without a production hook, so it
  is covered by the fixture-tree unit tests plus the manual hardware gate.
* Cost gate: opening the page makes no wakeups while idle (per-thread context
  switch count), and closing it releases the socket and the listener.

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
* Remote cupsd (`CUPS_SERVER=host`): supported for reading; setup actions are
  disabled with a reason. Encrypted/authenticated remote servers are out.
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
* Network scanning or probing of any kind.
