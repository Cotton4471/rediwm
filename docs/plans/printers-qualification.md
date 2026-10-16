# Printer qualification evidence

Recorded 2026-10-16. These are isolated software compatibility checks for the
[Printers plan](printers.md), separate from its physical-printer acceptance gates.
No host CUPS socket, host service, USB device, printer, home directory or project
checkout was mounted into a container. Packages were installed only in disposable
rootless Podman containers. The schedulers used private configuration, state,
spool, cache, log and runtime directories under their container's `/tmp`.

## Distro matrix

The cached release-family images were inspected first with `--network=none`,
`--read-only` and `--pull=never`. None initially contained CUPS or cups-pk-helper.
Their packages were then installed from their normal distro repositories inside
throwaway containers; package versions below are the versions actually observed.
Arch's base image identified itself as snapshot `20260927.0.600689`, Debian as
13.7, Ubuntu as 24.04.5, and Fedora as 44.

| Family | CUPS package | cups-pk-helper package | Empty private scheduler | Runtime helper introspection | Raw MIME advertised | `dbus://` subscription |
| --- | --- | --- | --- | --- | --- | --- |
| Arch | `2:2.4.20-1` | `0.2.7-2` | Pass | Pass | Pass | Pass |
| Debian 13 | `2.4.10-3+deb13u2` | `0.2.6-2.1` | Pass | Pass | Pass | Pass |
| Ubuntu 24.04 | `2.4.7-1.2ubuntu7.14` | `0.2.6-1ubuntu8` | Pass | Pass | Pass | Pass |
| Fedora 44 | `2.4.19-3.fc44` | `0.2.7-12.fc44` | Pass | Pass | Pass | Pass |
| openSUSE | Not checked | Not checked | Not checked | Not checked | Not checked | Not checked |

Every checked CUPS package installed `/usr/lib/cups/notifier/dbus`. Each inert
queue reported `application/vnd.cups-raw`, notification scheme `dbus`, and a
supported lease range of `0-2147483647`. Creating a printer subscription with
`notify-recipient-uri=dbus://`, `notify-events=printer-state-changed` and requested
lease `0` succeeded on all four families. Some creation replies included only the
subscription ID, so the absence of a lease in that reply is not a refusal.

The Debian packaged `lpadmin(8)` documentation explicitly described the
`everywhere` model querying the supplied IPP device. Minimal images on the other
families did not expose that manual through the checked paths. Their actual
Everywhere queue creation against an IPP device was not exercised. Upstream
[CUPS lpadmin documentation](https://openprinting.github.io/cups/doc/man-lpadmin.html)
also describes that model; documentation alone does not qualify discovery or
creation on real printers.

## Actual helper interface

All four installed helpers were started directly on a private system bus, then
introspected at destination `org.opensuse.CupsPkHelper.Mechanism`, object path
`/`, interface `org.opensuse.CupsPkHelper.Mechanism`. The following signatures
were identical across the two observed helper versions:

| Method | Input signature | Output signature |
| --- | --- | --- |
| `DevicesGet` | `iiasas` | `sa{ss}` |
| `PrinterAdd` | `sssss` | `s` |
| `PrinterDelete` | `s` | `s` |
| `PrinterRename` | `ss` | `s` |
| `PrinterSetDefault` | `s` | `s` |
| `PrinterSetEnabled` | `sb` | `s` |
| `PrinterSetAcceptJobs` | `sbs` | `s` |
| `PrinterAddOptionDefault` | `ssas` | `s` |

This establishes the installed wire interface and executable availability. The
private bus and scheduler used permissive fixture policies; this does not establish
a desktop user's stock polkit authorization, service activation, discovery rights
or successful queue administration through the helper on an installed desktop.

## Subscription lease and byte transport

The follow-up harness queries `Get-Subscription-Attributes` after creation rather
than assuming that the requested lease was granted. Its raw transport check adds
one synthetic PPD queue whose only backend copies the job into a private file.
The PPD declares a deliberately missing PDF filter. One bounded binary payload is
submitted with `lp -o raw`, then compared byte-for-byte with the captured file.
This checks CUPS raw bypass through a PPD queue; no hardware backend is installed
in the fixture's `ServerBin`, and no document is sent to a real printer.

The granted lease was independently queried with `Get-Subscription-Attributes`
on all four families, and each returned `notify-lease-duration=0`. Explicit
`Cancel-Subscription` is also exercised before the raw fixture changes its queue.
Each final comparison passed for the same 35-byte payload, including NUL,
`0xff`, ESC, LF and CRLF. Debian/Ubuntu used `cmp`; Arch/Fedora minimal images
lacked `cmp`, so the follow-up compared complete, untruncated `od -An -v -tx1`
output. The checked backend copies input without invoking filters or opening a
printer connection.

| Family | Granted lease `0` | Explicit subscription cancellation | Raw bytes through synthetic PPD |
| --- | --- | --- | --- |
| Arch / CUPS 2.4.20 | Pass | Pass | Pass, 35 bytes |
| Debian / CUPS 2.4.10 | Pass | Pass | Pass, 35 bytes |
| Ubuntu / CUPS 2.4.7 | Pass | Pass | Pass, 35 bytes |
| Fedora / CUPS 2.4.19 | Pass | Pass | Pass, 35 bytes |

An earlier fixture run replaced `ServerBin` without retaining CUPS's
`daemon/cups-exec` launcher. Queue changes then triggered a missing-launcher
notifier retry, and the raw comparison could not run. The final harness retains
that launcher while keeping hardware and network backends absent, cancels the
subscription before changing the PPD queue, and bounds the private log size.
This was a fixture setup failure, not evidence of raw passthrough or a product
regression. An earlier Debian rename follow-up also encountered a cleanup-only
race: its raw and lease checks had passed, but removing the private server root
raced the terminating daemon and exited with status 1. The entire disposable
container was removed; the documented recipe adds a wait before directory
removal. Arch/Fedora follow-ups and the corrected final Debian fixture exited 0.

## Rename source review and runtime limit

`PrinterRename(ss) -> s` exists in the installed helper interfaces. The
[official Debian 0.2.6 source archive](https://deb.debian.org/debian/pool/main/c/cups-pk-helper/cups-pk-helper_0.2.6.orig.tar.xz)
and [upstream 0.2.7 archive](https://www.freedesktop.org/software/cups-pk-helper/releases/cups-pk-helper-0.2.7.tar.xz)
were downloaded and `src/cups.c:cph_cups_printer_class_rename` reviewed.

Both implementations check that the destination is absent, reject pending or
processing jobs, create a replacement queue from the old PPD and selected
attributes, attempt to move held jobs, then delete the old queue. The procedure
is not atomic. Several updates/moves/deletion results are ignored; arbitrary
queue defaults are not comprehensively copied. A concurrent destination creation
can race the initial check. The 0.2.7 changes in this function only adjust class
member loop integer types. It must not be described as an atomic or universally
preserving rename.

Initial private runtime calls in Debian, Arch and Fedora were refused before
execution: the test bus admitted root but disconnected the packaged polkit
service after it dropped to its service UID. The fixture policy was corrected
to admit its container users, and the Debian check was repeated with the same
private bus also available at the container's conventional system-bus path.
No host bus or queue was used.

On Debian 13, helper 0.2.6 and CUPS 2.4.10 then demonstrated:

| Check | Actual result |
| --- | --- |
| Quiet `RenameSource` to unused `RenameNew` | Empty error string; old name disappeared; `fixture:/source` was preserved under the new name. |
| `RenameNew` to existing `RenameExisting` | Refused; `RenameNew` retained `fixture:/source` and `RenameExisting` retained `fixture:/existing`. |
| Rename with a pending job on paused `RenameNew` | Refused; source remained and no destination appeared. The bounded job targeted only the inert fixture backend and was cancelled afterwards. |

Both refusals returned the nonempty error string `successful-ok`. That string
occupies the helper's error field and is a failure despite its wording; only an
empty error string denotes success. The final Debian fixture exited 0.

These sequential checks establish the helper's basic rename, collision and
pending-job behavior in this private root-authorized fixture. They do not
establish atomicity, preservation of all defaults/history, held-job migration or
unprivileged desktop authorization. Arch/Fedora rename behavior remains a source
review plus interface check, rather than a successful runtime rename test.

Source archive SHA-256 values:

* 0.2.6: `959af8f2f5a2761e7e498b61c9caf25ae963335031eae9972d999e9a0d97a228`
* 0.2.7: `66070ddb448fe9fcee76aa26be2ede5a80f85563e3a4afd59d2bfd79fbe2e831`

## Actual option-setting semantics

A follow-up Debian 13 fixture used CUPS 2.4.10, cups-pk-helper 0.2.6 and a
synthetic PPD with A4/4x6 media, 203/300 dpi, duplex, color, quality and custom
Darkness choices. After each helper call, `Get-Printer-Attributes` and the stored
PPD's `*Default` lines were inspected. No option test submitted a print job.

`PrinterAddOptionDefault` returned an empty error string for canonical media,
resolution and duplex choices, but CUPS then returned duplicate default
attributes: the requested 4x6/203 dpi/duplex values followed by the old
A4/300 dpi/one-sided PPD values. `ipptool` correctly marked those replies as
invalid due to duplicate attributes. The PPD defaults remained unchanged.
Using that method with `PageSize`, `Resolution` and `Darkness` similarly stored
IPP overrides without changing the PPD. A helper success string is therefore
insufficient evidence that a driver choice was applied consistently.

Those fixture overrides were removed with `PrinterDeleteOptionDefault` before
checking `PrinterAddOption`, the PPD-aware method. Its observed effects were:

| Method/key/value | Stored PPD after call | Reported IPP default |
| --- | --- | --- |
| `PrinterAddOption`, `PageSize=4x6` | `DefaultPageSize: 4x6` | media 4x6 |
| `PrinterAddOption`, `Resolution=203dpi` | `DefaultResolution: 203dpi` | resolution 203 dpi |
| `PrinterAddOption`, `Darkness=12` | `DefaultDarkness: 12` | Custom choice verified in PPD |
| `PrinterAddOption`, `sides=two-sided-long-edge` | `DefaultDuplex: DuplexNoTumble` | two-sided-long-edge |
| `PrinterAddOption`, `media=iso_a4_210x297mm` | `DefaultPageSize: A4` | A4 |
| `PrinterAddOption`, `printer-resolution=300dpi` | `DefaultResolution: 300dpi` | resolution 300 dpi |
| `PrinterAddOption`, `sides=one-sided` | `DefaultDuplex: None` | one-sided |
| `PrinterAddOption`, `print-color-mode=monochrome` | `DefaultColorModel: Gray` | monochrome |
| `PrinterAddOption`, `print-quality=4` | `DefaultcupsPrintQuality: Normal`, previously High | normal, also reported before the change |

These PPD-aware replies had one copy of each standard default attribute and
passed the IPP tool's response checks. Quality needs special care: this fixture reported
IPP quality `normal` even when its initial PPD quality default was `High`, so
that IPP field alone did not describe the PPD default. Selecting canonical quality `5` did change the stored PPD back to `High`, but
IPP quality still reported `normal`.

`PrinterDeleteOptionDefault` was also tested after the PPD setters for
`PageSize`, `Resolution`, `Darkness`, `media`, `printer-resolution`, `sides`,
`print-color-mode` and `print-quality`, including a repeated absent `Darkness`
clear. Every call returned an empty success string. The stored PPD defaults
survived; nondefault 4x6 media, 203 dpi and duplex remained correct in IPP.
However, clearing `print-color-mode` reverted the reported IPP default to `color`
while the PPD remained `Gray`. Clearing before reapplying `monochrome` did not
repair that IPP field when the PPD was already Gray and the helper consequently
had no changed PPD to upload. A blanket setter-then-clear sequence is therefore
not a valid assumption for every canonical field. Default deletion removes an
IPP override; it does not restore a rewritten PPD's original driver default.
These checks establish stored PPD changes, not how every application's print
dialog interprets a conflicting IPP/PPD default.

This behavior matches the helper source's separate default-attribute and
PPD-editing paths. Upstream
[`cupsMarkOptions`](https://github.com/OpenPrinting/cups/blob/v2.4.10/cups/ppd-mark.c)
maps canonical media, resolution, sides, color and quality values to PPD choices.
The
[driverless PPD generator](https://github.com/OpenPrinting/cups/blob/v2.4.10/cups/ppd-cache.c)
also emits standard ColorModel, Duplex and cupsPrintQuality choices, but several
branches expose resolution through quality presets and a `DefaultResolution`
line without an editable `Resolution` option. This is source evidence, not a
runtime driverless-printer qualification; standalone resolution changes can be
unavailable or ignored on those PPDs. Re-read the actual choice/default before
reporting a setting as applied.

## Scope still requiring qualification

* The label-printer isolation exercise, an ordinary printer, command-language
  responses, real paper output and ruler measurements remain manual hardware
  gates. A synthetic backend cannot establish physical printing or USB access.
* The shipped distro policies, unprivileged polkit prompts, helper discovery and
  administration, systemd service start, and end-to-end notifier delivery on
  installed desktops remain separate checks. These fixtures use a private bus
  and fixture policies, and do not run a host service manager.
* Real driverless discovery/creation, device-ID-to-driver matches, and visibility
  in application/portal print dialogs were not qualified by these containers.
* No openSUSE image was cached. The release script currently targets Arch,
  Debian, Ubuntu and Fedora; no openSUSE release qualification is claimed.

## Reproduction and recorded commands

Images used (local image IDs, before package installation):

| Image | Local ID |
| --- | --- |
| `docker.io/library/archlinux:latest` | `66e676a0a26efc7da658cc3763b65e9bd1927de617c30fd2db7a5b405d5cfc4d` |
| `docker.io/library/debian:13` | `36c636ddb9c578b068df381216d26a921c64fc2534e20baf7d0c53fb800b3a74` |
| `docker.io/library/ubuntu:24.04` | `69f919497cada9a8611f3de61df902d9f94bf20f84552ef5bd93125c38608ef9` |
| `docker.io/library/fedora:latest` | `ccb55df1d2413428166d80b08aa37a4bdcb61a63d09fff6f8abc0d561f311053` |

Read-only inventory command:

```sh
podman images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}'
podman run --rm --pull=never --network=none --cap-drop=all \
  --security-opt=no-new-privileges --read-only --tmpfs /tmp IMAGE \
  sh -c 'cat /etc/os-release; command -v cupsd || true'
```

The harness below reproduces the final container-only test recipe from this
session, with an explicit container guard added. The successful runtime rename
and option portions were run on Debian; the software matrix above also uses earlier isolated
Arch/Ubuntu/Fedora runs of the same CUPS checks.
Save it as a temporary `qualification.sh`, then use each image above and its
family (`arch`, `debian`, `ubuntu`, `fedora`):

```sh
podman run --rm --pull=never --security-opt=no-new-privileges \
  -v /absolute/path/to/qualification.sh:/qualification.sh:ro \
  IMAGE sh /qualification.sh FAMILY
```

Package installation needs repository network access inside the disposable
container. No host directory other than the read-only harness is mounted, and no
ports or devices are passed through. Debian/Ubuntu package service-start hooks
are denied with a container-only `policy-rc.d`. Arch's temporary image runs
`systemd-sysusers` for its packaged CUPS service account because its base image
has not booted a service manager. The standalone fixture scheduler is explicitly
started from the harness. The rootless container's UID 0 is not host root.

```sh
#!/bin/sh
set -eu
# This recipe belongs inside a disposable Podman container only.
[ -e /run/.containerenv ] || { echo "Run through podman, not on the host" >&2; exit 1; }
family=$1
qual_root=$(mktemp -d /tmp/rediwm-printer-qualify.XXXXXX)
cups_pid=
bus_pid=
cleanup() {
    [ -z "$cups_pid" ] || kill "$cups_pid" 2>/dev/null || true
    [ -z "$bus_pid" ] || kill "$bus_pid" 2>/dev/null || true
    [ -z "$cups_pid" ] || wait "$cups_pid" 2>/dev/null || true
    rm -rf "$qual_root"
}
trap cleanup EXIT HUP INT TERM
export SYSTEMD_OFFLINE=1
case "$family" in
 arch) pacman -Sy --noconfirm cups cups-pk-helper dbus polkit > "$qual_root/packages.log" 2>&1 || { tail -60 "$qual_root/packages.log"; exit 20; }; pacman -Q cups cups-pk-helper dbus ;;
 debian|ubuntu)
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    export DEBIAN_FRONTEND=noninteractive
    apt-get update > "$qual_root/packages.log" 2>&1 && apt-get install -y --no-install-recommends cups-daemon cups-client cups-ipp-utils cups-pk-helper cups-server-common dbus dbus-bin polkitd >> "$qual_root/packages.log" 2>&1 || { tail -60 "$qual_root/packages.log"; exit 20; }
    dpkg-query -W cups-daemon cups-client cups-pk-helper dbus
    ;;
 fedora)
    dnf -y --setopt=install_weak_deps=False install cups cups-client cups-ipptool cups-pk-helper dbus-daemon polkit > "$qual_root/packages.log" 2>&1 || { tail -60 "$qual_root/packages.log"; exit 20; }
    rpm -q cups cups-client cups-ipptool cups-pk-helper dbus-daemon
    ;;
esac
printf '\nPACKAGED NOTIFIER\n'
for path in /usr/lib/cups/notifier/dbus /usr/lib64/cups/notifier/dbus /usr/libexec/cups/notifier/dbus; do
    [ ! -e "$path" ] || ls -l "$path"
done
printf '\nHELPER XML\n'
for path in /usr/share/dbus-1/interfaces/*Cups* /usr/share/cups-pk-helper/* /usr/share/dbus-1/system-services/*Cups* /usr/share/polkit-1/actions/*cups*; do
    [ ! -f "$path" ] || { printf '%s\n' "$path"; case "$path" in *.xml) cat "$path" ;; esac; }
done
printf '\nEVERYWHERE DOCUMENTATION\n'
for path in /usr/share/man/man8/lpadmin.8.gz /usr/share/man/en/man8/lpadmin.8.gz; do
    [ ! -f "$path" ] || zcat "$path" | grep -A6 -B2 everywhere || true
done
printf '\nCUPS FILE CONFIG\n'
cups_user=$(awk '/^User[ \t]/{print $2;exit}' /etc/cups/cups-files.conf)
cups_group=$(awk '/^Group[ \t]/{print $2;exit}' /etc/cups/cups-files.conf)
[ -n "$cups_user" ] || cups_user=lp
[ -n "$cups_group" ] || cups_group=lp
if [ "$family" = arch ]; then systemd-sysusers /usr/lib/sysusers.d/cups.conf >/dev/null 2>&1 || true; fi
printf 'SERVICE USER=%s GROUP=%s\n' "$cups_user" "$cups_group"
mkdir -p "$qual_root/server" "$qual_root/state" "$qual_root/spool" "$qual_root/cache" "$qual_root/tmp" "$qual_root/run" "$qual_root/bin/daemon" "$qual_root/bin/backend" "$qual_root/bin/filter" "$qual_root/bin/notifier"
# Avoid real USB, DNS-SD and network backends entirely, including discovery.
for source in /usr/lib/cups/notifier/dbus /usr/lib64/cups/notifier/dbus /usr/libexec/cups/notifier/dbus; do
    if [ -x "$source" ]; then ln -s "$source" "$qual_root/bin/notifier/dbus"; break; fi
done
for source in /usr/lib/cups/daemon/cups-exec /usr/lib64/cups/daemon/cups-exec /usr/libexec/cups/daemon/cups-exec; do
    if [ -x "$source" ]; then ln -s "$source" "$qual_root/bin/daemon/cups-exec"; break; fi
done
chmod 755 "$qual_root" "$qual_root/server" "$qual_root/state" "$qual_root/spool" "$qual_root/cache" "$qual_root/tmp" "$qual_root/run" "$qual_root/bin" "$qual_root/bin/notifier"
cat > "$qual_root/cups-files.conf" <<CONF
User $cups_user
Group $cups_group
SystemGroup root
ServerRoot $qual_root/server
StateDir $qual_root/state
RequestRoot $qual_root/spool
CacheDir $qual_root/cache
TempDir $qual_root/tmp
ServerBin $qual_root/bin
DataDir /usr/share/cups
DocumentRoot /usr/share/cups/doc-root
ErrorLog $qual_root/error.log
AccessLog $qual_root/access.log
PageLog $qual_root/page.log
Printcap $qual_root/printcap
CONF
cat > "$qual_root/cupsd.conf" <<CONF
Listen $qual_root/run/cups.sock
Listen 127.0.0.1:8631
Browsing Off
WebInterface No
DefaultAuthType Basic
LogLevel debug
MaxLogSize 1048576
<Location />
  Order allow,deny
  Allow all
</Location>
<Policy default>
  <Limit All>
    Order allow,deny
    Allow all
  </Limit>
</Policy>
CONF
# A private bus is used only by this container's notifier/helper checks.
cat > "$qual_root/bus.conf" <<CONF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>system</type><listen>unix:path=$qual_root/run/bus.sock</listen><auth>EXTERNAL</auth><policy context="default"><allow user="*"/><allow own="*"/><allow send_destination="*"/><allow send_type="signal"/><allow receive_sender="*"/></policy></busconfig>
CONF
bus_output=$(dbus-daemon --config-file="$qual_root/bus.conf" --fork --print-address=1 --print-pid=1)
DBUS_SYSTEM_BUS_ADDRESS=$(printf '%s\n' "$bus_output" | head -n1)
export DBUS_SYSTEM_BUS_ADDRESS
bus_pid=$(printf '%s\n' "$bus_output" | tail -n1)
/usr/sbin/cupsd -t -c "$qual_root/cupsd.conf" -s "$qual_root/cups-files.conf"
/usr/sbin/cupsd -f -c "$qual_root/cupsd.conf" -s "$qual_root/cups-files.conf" > "$qual_root/cupsd.log" 2>&1 &
cups_pid=$!
# Single bounded startup wait; no persistent polling.
sleep 15
if [ ! -S "$qual_root/run/cups.sock" ]; then cat "$qual_root/cupsd.log" "$qual_root/error.log" 2>/dev/null || true; exit 21; fi
export CUPS_SERVER="$qual_root/run/cups.sock"
printf '\nEMPTY SCHEDULER\n'
lpstat -r
lpstat -p || true
cat > "$qual_root/bin/backend/fixture" <<'BACKEND'
#!/bin/sh
# An inert, container-only backend: no hardware or network I/O, no jobs sent.
exit 0
BACKEND
chmod 755 "$qual_root/bin/backend/fixture"
lpadmin -p Qualification -E -v fixture:/never -m raw
cat > "$qual_root/formats.test" <<'IPP'
{
 NAME "Private scheduler formats"
 OPERATION Get-Printer-Attributes
 GROUP operation-attributes-tag
 ATTR charset attributes-charset utf-8
 ATTR language attributes-natural-language en
 ATTR uri printer-uri ipp://localhost/printers/Qualification
 ATTR keyword requested-attributes document-format-supported,ipp-versions-supported,notify-schemes-supported,notify-lease-duration-supported
 STATUS successful-ok
 DISPLAY document-format-supported
 DISPLAY ipp-versions-supported
 DISPLAY notify-schemes-supported
 DISPLAY notify-lease-duration-supported
}
IPP
printf '\nRAW FORMAT AND NOTIFY CAPABILITIES\n'
ipptool -T 3 -tv "ipp://127.0.0.1:8631/printers/Qualification" "$qual_root/formats.test" || true
printf '\nHELPER RUNTIME INTROSPECTION\n'
helper=$(sed -n 's/^Exec=//p' /usr/share/dbus-1/system-services/org.opensuse.CupsPkHelper.Mechanism.service)
for path in /usr/lib/cups-pk-helper-mechanism /usr/libexec/cups-pk-helper-mechanism /usr/lib64/cups-pk-helper-mechanism; do
    [ ! -x "$path" ] || helper=$path
done
if [ -n "$helper" ] && command -v dbus-send >/dev/null; then
    "$helper" > "$qual_root/helper.log" 2>&1 &
    helper_pid=$!
    sleep 1
    dbus-send --system --reply-timeout=3000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / org.freedesktop.DBus.Introspectable.Introspect || true
    kill "$helper_pid" 2>/dev/null || true
    cat "$qual_root/helper.log"
else
    printf 'helper executable or dbus-send unavailable\n'
fi
printf '\nSUBSCRIPTION CAPABILITY\n'
cat > "$qual_root/subscribe.test" <<'IPP'
{
 NAME "Private scheduler dbus subscription"
 OPERATION Create-Printer-Subscriptions
 GROUP operation-attributes-tag
 ATTR charset attributes-charset utf-8
 ATTR language attributes-natural-language en
 ATTR uri printer-uri ipp://localhost/
 ATTR name requesting-user-name qualification
 GROUP subscription-attributes-tag
 ATTR uri notify-recipient-uri dbus://
 ATTR keyword notify-events printer-state-changed
 ATTR integer notify-lease-duration 0
 STATUS successful-ok
 DISPLAY notify-subscription-id
 DISPLAY notify-lease-duration
}
IPP
ipptool -T 3 -tv "ipp://127.0.0.1:8631/" "$qual_root/subscribe.test" || true
printf '\nGRANTED SUBSCRIPTION LEASE\n'
cat > "$qual_root/subscription-attributes.test" <<'IPP'
{
 NAME "Private subscription granted lease"
 OPERATION Get-Subscription-Attributes
 GROUP operation-attributes-tag
 ATTR charset attributes-charset utf-8
 ATTR language attributes-natural-language en
 ATTR uri printer-uri ipp://localhost/
 ATTR name requesting-user-name qualification
 ATTR integer notify-subscription-id 1
 STATUS successful-ok
 DISPLAY notify-lease-duration
 DISPLAY notify-recipient-uri
}
IPP
ipptool -T 3 -tv "ipp://127.0.0.1:8631/" "$qual_root/subscription-attributes.test" || true
cat > "$qual_root/cancel-subscription.test" <<'IPP'
{
 NAME "Cancel private notification subscription"
 OPERATION Cancel-Subscription
 GROUP operation-attributes-tag
 ATTR charset attributes-charset utf-8
 ATTR language attributes-natural-language en
 ATTR uri printer-uri ipp://localhost/
 ATTR name requesting-user-name qualification
 ATTR integer notify-subscription-id 1
 STATUS successful-ok
}
IPP
ipptool -T 3 -tv "ipp://127.0.0.1:8631/" "$qual_root/cancel-subscription.test"
printf '\nRAW PASSTHROUGH WITH PPD TO FILE-ONLY FIXTURE BACKEND\n' 
mkdir "$qual_root/received"
chown "$cups_user:$cups_group" "$qual_root/received" "$qual_root/tmp"
chmod 700 "$qual_root/received"
cat > "$qual_root/bin/backend/fixture" <<BACKEND
#!/bin/sh
if [ \$# -eq 0 ]; then exit 0; fi
if [ \$# -ge 6 ]; then
    cat "\$6" > "$qual_root/received/job-\$1.bin"
else
    cat > "$qual_root/received/job-\$1.bin"
fi
BACKEND
chmod 755 "$qual_root/bin/backend/fixture"
cat > "$qual_root/fixture.ppd" <<'PPD'
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName: "QUALIFY.PPD"
*Manufacturer: "RediWM test fixture"
*Product: "(Inert fixture)"
*ModelName: "Inert fixture"
*NickName: "Inert fixture"
*PSVersion: "(3010.000) 0"
*cupsVersion: 1.1
*cupsManualCopies: True
*cupsFilter: "application/pdf 0 deliberately-missing-filter"
*ColorDevice: True
*DefaultColorSpace: Gray
*OpenUI *Resolution/Resolution: PickOne
*DefaultResolution: 300dpi
*Resolution 203dpi/203 DPI: "<</HWResolution [203 203]>>setpagedevice"
*Resolution 300dpi/300 DPI: "<</HWResolution [300 300]>>setpagedevice"
*CloseUI: *Resolution
*OpenUI *Darkness/Print Darkness: PickOne
*DefaultDarkness: 8
*Darkness 8/Light: ""
*Darkness 12/Dark: ""
*CloseUI: *Darkness
*OpenUI *Duplex/Duplex: PickOne
*DefaultDuplex: None

*Duplex None/Off: "<</Duplex false>>setpagedevice"
*Duplex DuplexNoTumble/Long edge: "<</Duplex true /Tumble false>>setpagedevice"
*CloseUI: *Duplex
*OpenUI *ColorModel/Color Mode: PickOne
*DefaultColorModel: RGB
*ColorModel Gray/Monochrome: "<</ProcessColorModel /DeviceGray>>setpagedevice"
*ColorModel RGB/Color: "<</ProcessColorModel /DeviceRGB>>setpagedevice"
*CloseUI: *ColorModel
*OpenUI *cupsPrintQuality/Quality: PickOne
*DefaultcupsPrintQuality: High
*cupsPrintQuality Draft/Draft: ""
*cupsPrintQuality Normal/Normal: ""
*cupsPrintQuality High/High: ""
*CloseUI: *cupsPrintQuality
*OpenUI *PageSize/Media Size: PickOne
*DefaultPageSize: A4
*PageSize A4: "<</PageSize [595 842]>>setpagedevice"
*PageSize 4x6/4 x 6 inch: "<</PageSize [288 432]>>setpagedevice"
*ImageableArea 4x6: "0 0 288 432"
*PaperDimension 4x6: "288 432"
*ImageableArea A4: "0 0 595 842"
*PaperDimension A4: "595 842"
*CloseUI: *PageSize
PPD
if ! lpadmin -p QualificationPpd -E -v fixture:/never -P "$qual_root/fixture.ppd"; then
    tail -40 "$qual_root/error.log"
    exit 22
fi
printf 'RediWM raw passthrough\n\000\377\033%%finite\015\012' > "$qual_root/expected.bin"
lp -d QualificationPpd -o raw "$qual_root/expected.bin"
sleep 3
if [ "$(od -An -v -tx1 "$qual_root/expected.bin")" = "$(od -An -v -tx1 "$qual_root/received/job-1.bin")" ]; then
    printf 'RAW_PPD_BYTE_COMPARISON=PASS\n'
    wc -c "$qual_root/expected.bin"
else
    printf 'RAW_PPD_BYTE_COMPARISON=FAIL\n'
    lpstat -l -W all -o || true
    tail -35 "$qual_root/error.log"
fi
printf '\nPRIVATE HELPER RENAME\n'
mkdir -p /run/dbus
ln -s "$qual_root/run/bus.sock" /run/dbus/system_bus_socket
polkit=
for path in /usr/lib/polkit-1/polkitd /usr/libexec/polkit-1/polkitd; do
    [ ! -x "$path" ] || polkit=$path
done
if [ -n "$polkit" ]; then
    "$polkit" > "$qual_root/polkit.log" 2>&1 &
    polkit_pid=$!
    "$helper" > "$qual_root/rename-helper.log" 2>&1 &
    rename_helper_pid=$!
    sleep 5
    dbus-send --system --reply-timeout=3000 --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames
    lpadmin -p RenameSource -E -v fixture:/source -m raw
    lpadmin -p RenameExisting -E -v fixture:/existing -m raw
    lpadmin -p RenameSource -o printer-info='Retain this description' -o job-sheets-default=none,none
    printf 'BEFORE RENAME\n'
    lpstat -v
    dbus-send --system --reply-timeout=10000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / org.opensuse.CupsPkHelper.Mechanism.PrinterRename string:RenameSource string:RenameNew || true
    printf 'AFTER NEW NAME\n'
    lpstat -v || true
    dbus-send --system --reply-timeout=10000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / org.opensuse.CupsPkHelper.Mechanism.PrinterRename string:RenameNew string:RenameExisting || true
    printf 'AFTER COLLISION\n'
    lpstat -v || true
    printf 'PENDING JOB GUARD ON PAUSED QUEUE\n'
    cupsdisable RenameNew || true
    lp -d RenameNew -o raw "$qual_root/expected.bin" || true
    lpstat -l -W not-completed -o || true
    dbus-send --system --reply-timeout=10000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / org.opensuse.CupsPkHelper.Mechanism.PrinterRename string:RenameNew string:RenamePending || true
    lpstat -v
    cancel -a RenameNew || true
    printf 'PRIVATE OPTION SEMANTICS\n'
    cat > "$qual_root/options.test" <<'IPP'
{
 NAME "Actual option defaults"
 OPERATION Get-Printer-Attributes
 GROUP operation-attributes-tag
 ATTR charset attributes-charset utf-8
 ATTR language attributes-natural-language en
 ATTR uri printer-uri ipp://localhost/printers/QualificationPpd
 ATTR keyword requested-attributes media-default,printer-resolution-default,sides-default,print-color-mode-default,print-quality-default,Darkness-default,PageSize-default,Resolution-default
 STATUS successful-ok
 DISPLAY media-default
 DISPLAY printer-resolution-default
 DISPLAY sides-default
 DISPLAY print-color-mode-default
 DISPLAY print-quality-default
 DISPLAY Darkness-default
 DISPLAY PageSize-default
 DISPLAY Resolution-default
}
IPP
    query_options() {
        printf '\nOPTION SNAPSHOT %s\n' "$1"
        ipptool -T 3 -tv "ipp://127.0.0.1:8631/printers/QualificationPpd" "$qual_root/options.test" || true
        grep '^\*Default' "$qual_root/server/ppd/QualificationPpd.ppd"
    }
    set_option() {
        printf '\nSET OPTION method=%s key=%s value=%s\n' "$1" "$2" "$3"
        dbus-send --system --reply-timeout=10000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / "org.opensuse.CupsPkHelper.Mechanism.$1" string:QualificationPpd "string:$2" "array:string:$3"
    }
    query_options baseline
    set_option PrinterAddOptionDefault media na_index-4x6_4x6in
    set_option PrinterAddOptionDefault printer-resolution 203dpi
    set_option PrinterAddOptionDefault sides two-sided-long-edge
    query_options ipp-default-api
    set_option PrinterAddOptionDefault PageSize 4x6
    set_option PrinterAddOptionDefault Resolution 203dpi
    set_option PrinterAddOptionDefault Darkness 12
    query_options ppd-keys-default-api
    printf 'CLEAR PREVIOUS IPP DEFAULT OVERRIDES\n'
    for key in media printer-resolution sides PageSize Resolution Darkness; do
        dbus-send --system --reply-timeout=10000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / org.opensuse.CupsPkHelper.Mechanism.PrinterDeleteOptionDefault string:QualificationPpd "string:$key"
    done
    query_options cleared-overrides
    set_option PrinterAddOption PageSize 4x6
    set_option PrinterAddOption Resolution 203dpi
    set_option PrinterAddOption Darkness 12
    query_options ppd-keys-ppd-api
    set_option PrinterAddOption sides two-sided-long-edge
    query_options canonical-duplex-positive
    set_option PrinterAddOption media iso_a4_210x297mm
    set_option PrinterAddOption printer-resolution 300dpi
    set_option PrinterAddOption sides one-sided
    set_option PrinterAddOption print-color-mode monochrome
    set_option PrinterAddOption print-quality 4
    query_options canonical-ppd-api
    printf 'CLEAR ABSENT OVERRIDES AFTER PPD SETTERS\n'
    for key in PageSize Resolution Darkness media printer-resolution sides print-color-mode print-quality; do
        printf 'CLEAR AFTER PPD key=%s\n' "$key"
        dbus-send --system --reply-timeout=10000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / org.opensuse.CupsPkHelper.Mechanism.PrinterDeleteOptionDefault string:QualificationPpd "string:$key"
    done
    printf 'REPEAT ABSENT CLEAR Darkness\n'
    dbus-send --system --reply-timeout=10000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / org.opensuse.CupsPkHelper.Mechanism.PrinterDeleteOptionDefault string:QualificationPpd string:Darkness
    query_options absent-clear-after-ppd
    printf 'CANONICAL NONDEFAULTS BEFORE AND AFTER CLEANUP\n'
    set_option PrinterAddOption media na_index-4x6_4x6in
    set_option PrinterAddOption printer-resolution 203dpi
    set_option PrinterAddOption sides two-sided-long-edge
    set_option PrinterAddOption print-color-mode monochrome
    set_option PrinterAddOption print-quality 5
    query_options canonical-nondefaults-before-clear
    for key in media printer-resolution sides print-color-mode print-quality; do
        printf 'CLEAR CANONICAL AFTER key=%s\n' "$key"
        dbus-send --system --reply-timeout=10000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / org.opensuse.CupsPkHelper.Mechanism.PrinterDeleteOptionDefault string:QualificationPpd "string:$key"
    done
    query_options canonical-nondefaults-after-clear
    printf 'CLEANUP BEFORE EACH CANONICAL SETTER\n'
    for pair in media:na_index-4x6_4x6in printer-resolution:203dpi sides:two-sided-long-edge print-color-mode:monochrome print-quality:5; do
        key=${pair%%:*}
        value=${pair#*:}
        dbus-send --system --reply-timeout=10000 --print-reply --dest=org.opensuse.CupsPkHelper.Mechanism / org.opensuse.CupsPkHelper.Mechanism.PrinterDeleteOptionDefault string:QualificationPpd "string:$key"
        set_option PrinterAddOption "$key" "$value"
    done
    query_options canonical-cleanup-before-set


    cat "$qual_root/rename-helper.log" "$qual_root/polkit.log"
    kill "$rename_helper_pid" "$polkit_pid" 2>/dev/null || true
else
    printf 'Private polkit daemon unavailable; rename authorization not exercised\n'
fi
printf '\nPRIVATE SCHEDULER LOG TAIL\n'   
tail -12 "$qual_root/error.log" || true
```
