# Printing

* `cups.zig` queries the configured Unix or cleartext TCP CUPS endpoint. TLS and
  authentication are explicit unsupported states; never fall back to a
  different server. Configuration read failures are not missing files.
  cups-pk-helper targets its local default server: allow its actions only with
  the canonical local socket, never a custom Unix or remote CUPS endpoint.
* IPP and HTTP replies are untrusted and bounded. Socket operations share an
  absolute deadline and include the worker cancellation fd in every wait.
* `cups.Snapshot` owns an arena. Parser helpers allocate into that arena;
  borrowed decoder fields must not escape it. Display strings are sanitized,
  but URI identity uses the complete validated value, never truncated text.
* `usb_sysfs` only reads sysfs and stats nodes. A unique serial can identify a
  USB queue; product strings and VID:PID alone cannot. Missing `usblp` is normal
  for libusb. Missing/inaccessible evidence stays unknown.
* The ladder is pure and reports evidence, not physical printing. A CUPS
  completed state or sheet counter alone cannot establish paper output.
  Reports exclude arbitrary names, messages, serials and URI authorities/paths.
* Worker lifetime and widget ownership: `src/control_center/AGENTS.md`.
  Remaining features and hardware/distro qualification: `docs/plans/printers.md`.
