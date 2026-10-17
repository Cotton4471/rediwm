# Direct CUPS administration

Add a local libcups administration backend when cups-pk-helper is absent.
Keep the established helper path when available; backend selection happens
before a request, never by retrying a failed mutation against another backend.
The existing canonical-local-server gate remains in force. Remote/TLS inventory
support is separate work and must not silently redirect to the local scheduler.

Implementation sequence:

1. Add a page-owned native worker with an eventfd completion/challenge channel,
   bounded local connection/I/O, cancellation, and thread-local libcups state.
   Keep the existing validated actions and chained add/PPD cleanup state machine.
2. Map the helper-independent operations to IPP: discovery, creation, deletion,
   enable/accept, default, description, device, defaults and PPD editing. Rename
   must preserve settings/PPD and reject active jobs/collisions before clone/delete;
   report uncertain or partial changes and refresh instead of automatic rollback.
3. Add username/password controls backed by locked and wiped storage. Only show
   them in response to a CUPS challenge, bound retries, cancel on page hide, and
   never retain passwords between operations or log server-provided prompts.
4. Extend isolated tests for helper-absent administration, challenge/retry/cancel,
   denial, discovery filtering, partial operations, and responsive page teardown.
   Existing helper tests remain regression coverage.
5. Update package/build guidance and subsystem notes. Run Debug and ReleaseSafe
   builds, zig build test, and printer integration tests. Compare failures against
   HEAD in an isolated worktree before attributing regressions.

No production test environment switches, automatic package installation, host
queue changes, or test print jobs are part of this work. Hardware printing and
stock CUPS authentication policy still require separate qualification.

Implementation status: the helper-absent backend, secure credentials controls,
IPP operations, PPD default editing and guarded clone/delete rename are now
implemented. Helper-present behavior remains covered by the original suite.
The private libcups suite covers successful operations, collisions, permission
denial, wrong-password retries and exhaustion, partial rename, active-job refusal,
and cancellation during both I/O and a password challenge. The Settings test
checks actual secret widgets, fresh authentication on subsequent operations,
cancel and hide. No real printer has been exercised.

The direct backend follows the public
[CUPS authentication and request APIs](https://openprinting.github.io/cups/doc/cupspm.html).
PPD support intentionally uses CUPS 2.x compatibility APIs, as the existing
printer page exposes legacy driver controls. Build/install dependencies now
include libcups headers. A real private cupsd check could not run here because
the installed cupsd executable is not executable by this user; synthetic tests
must not be described as stock scheduler/policy qualification.

Direct rename refuses queues in CUPS classes before mutating them; the page
does not model class membership and must not silently discard it.

Validation completed:

- Debug and ReleaseSafe builds passed.
- `zig build test` passed on the final source.
- `zig build test-printers --summary all` and
  `zig build test-printers -Doptimize=ReleaseSafe --summary all` both passed:
  59/59 build steps, 73/73 printing unit tests, the existing helper integration
  suite, and the new native/Settings integration suite.
- Native tests include the 20-second I/O deadline, class-member rename refusal,
  PPD preservation, and no timed wakeups in either idle administration thread.
- `git diff --check`, Python syntax checks and installer shell syntax passed.

These are isolated software checks, not evidence of physical paper output or
stock CUPS authentication policy on a deployed desktop.
