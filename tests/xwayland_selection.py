"""Xwayland tests: clipboard, drag and drop and primary selection."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from xwayland_support import ROOT, ipc_connect, request, start_compositor, wait_for, wayland_display_name


def test_clipboard_bidirectional():
    """Clipboard between a real X11 client and a real native Wayland client
    (clipboard_gtk_client.py runs as both - GDK's clipboard API is backend-
    agnostic). Exercises wlroots' own XWM selection bridge: there is no
    compositor-side clipboard code at all beyond wlr.DataDeviceManager.create()
    in Server.zig and wlr_xwayland.setSeat() in Xwayland.zig.

    Both directions work, but not symmetrically, and the difference matters
    for real usage - confirmed by reading src/xwayland/selection/{incoming,
    outgoing}.c's DEBUG/ERROR log lines while writing this test, and cross-
    checked against a real upstream report (swaywm/sway#4678) of the same
    "denying write access to clipboard: no xwayland surface focused" line:

    - Wayland owns the selection, X11 requests it (outgoing.c): works
      regardless of current focus. Confirmed below with the Wayland side
      long gone from focus by the time X11 pastes.
    - X11 owns the selection, Wayland requests it (incoming.c): wlroots'
      XWM refuses to relay X11's selection content unless an Xwayland
      surface is *currently* focused at the moment Wayland asks for it -
      not at copy time. Since pasting into a Wayland app requires that app
      to be focused, this makes "copy in an X11 app, click a Wayland app,
      paste" - probably the single most common mixed-session clipboard
      workflow - fail every time, not an edge case. test_x11_to_wayland_
      clipboard_focus_limitation below pins this exact behavior so a
      wlroots upgrade that fixes it will make that test fail and flag
      itself for review.

    The tests here stay in the direction/focus combinations that actually
    work, so this test is a real regression check, not just documentation.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-clipboard-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        x11_client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display
                wl_display = wayland_display_name(tmp)
                fixture = str(ROOT / "tests/clipboard_gtk_client.py")

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                def send(client, line):
                    client.stdin.write(line + "\n")
                    client.stdin.flush()

                def last_line(log_path):
                    lines = [
                        ln for ln in log_path.read_text().splitlines()
                        if ln and "DeprecationWarning" not in ln and not ln.strip().startswith("window.")
                    ]
                    return lines[-1] if lines else ""

                x11_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="x11")
                x11_env.pop("WAYLAND_DISPLAY", None)
                x11_log_path = tmp / "x11-clip.log"
                with x11_log_path.open("w") as x11_log:
                    x11_client = subprocess.Popen(
                        [sys.executable, fixture], env=x11_env,
                        stdin=subprocess.PIPE, stdout=x11_log, stderr=x11_log, text=True,
                    )
                wait_for(lambda: any(w.get("backend") == "xwayland" for w in windows()),
                         "X11 clipboard client did not appear", timeout=20)
                time.sleep(0.3)

                # X11 -> Wayland while X11 is still the (only, so focused)
                # window: this is the case wlroots' incoming.c actually
                # supports (see docstring).
                send(x11_client, "copy hello-from-x11")
                wait_for(lambda: last_line(x11_log_path).startswith("copied"), "X11 client did not copy")
                wl_env = dict(os.environ, WAYLAND_DISPLAY=wl_display, XDG_RUNTIME_DIR=str(tmp))
                wl_env.pop("DISPLAY", None)
                r = subprocess.run(["wl-paste"], env=wl_env, capture_output=True, text=True, timeout=10)
                assert r.returncode == 0 and r.stdout == "hello-from-x11\n", r
                print("PASS: clipboard text copied on X11 (still focused) reaches a native Wayland reader")

                # Large transfer, same (working) direction/focus combination.
                big = "y" * 200_000
                send(x11_client, f"copy {big}")
                wait_for(lambda: last_line(x11_log_path) == "copied 200000 bytes", "X11 client did not copy large text")
                r = subprocess.run(["wl-paste"], env=wl_env, capture_output=True, text=True, timeout=10)
                assert r.returncode == 0 and r.stdout == big + "\n", "large transfer did not arrive intact"
                print("PASS: large (200KB) clipboard transfer from X11 arrives intact")

                # Selection owner exit: close the owning client and confirm
                # the compositor and a subsequent, unrelated client are both
                # still healthy - not that content survives, which nothing
                # in this compositor implements (no clipboard-manager
                # persistence), so "nothing copied" is the correct outcome.
                send(x11_client, "quit")
                x11_client.wait(timeout=5)
                x11_client = None
                r = subprocess.run(["wl-paste"], env=wl_env, capture_output=True, text=True, timeout=10)
                assert r.returncode != 0, f"stale clipboard content survived the owner's exit: {r.stdout!r}"
                print("PASS: clipboard cleanly reports empty after its owner's process exits")

                # Wayland -> X11: works regardless of current focus. Prove it
                # by letting focus land on the *replacement* X11 client
                # (created last, so focused per this compositor's map policy)
                # well after the Wayland side copied and lost focus.
                wl_log_path = tmp / "wl-clip.log"
                with wl_log_path.open("w") as wl_log:
                    wl_client = subprocess.Popen(
                        [sys.executable, fixture], env=wl_env | {"GDK_BACKEND": "wayland"},
                        stdin=subprocess.PIPE, stdout=wl_log, stderr=wl_log, text=True,
                    )
                try:
                    wait_for(lambda: any(w.get("backend") == "xdg" for w in windows()),
                             "native Wayland clipboard client did not appear", timeout=20)
                    send(wl_client, "copy hello-from-wayland")
                    wait_for(lambda: last_line(wl_log_path).startswith("copied"), "Wayland client did not copy")

                    x11_log2_path = tmp / "x11-clip-2.log"
                    with x11_log2_path.open("w") as x11_log2:
                        x11_client = subprocess.Popen(
                            [sys.executable, fixture], env=x11_env,
                            stdin=subprocess.PIPE, stdout=x11_log2, stderr=x11_log2, text=True,
                        )
                    wait_for(lambda: sum(1 for w in windows() if w.get("backend") == "xwayland") >= 1,
                             "replacement X11 client did not appear", timeout=20)
                    time.sleep(0.3)
                    send(x11_client, "paste")
                    wait_for(
                        lambda: last_line(x11_log2_path) == "pasted 18 bytes: 'hello-from-wayland'",
                        lambda: f"X11 could not read Wayland-sourced clipboard: {last_line(x11_log2_path)!r}",
                        timeout=5,
                    )
                    print("PASS: clipboard text copied on native Wayland reaches X11 even after Wayland lost focus")
                finally:
                    if wl_client.poll() is None:
                        wl_client.terminate()
                        wl_client.wait(timeout=5)
        finally:
            if x11_client and x11_client.poll() is None:
                x11_client.terminate()
                x11_client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_x11_to_wayland_clipboard_focus_limitation():
    """Pins a real, confirmed wlroots XWM limitation (not a bug in this
    compositor - there is no clipboard API surface in the pinned wlroots
    0.20 Xwayland bindings to influence this from application code): once
    keyboard focus has moved away from every Xwayland surface, wlroots
    refuses to relay X11-sourced clipboard content to a Wayland requester,
    logging "denying write access to clipboard: no xwayland surface
    focused" (src/xwayland/selection/incoming.c). Since pasting into a
    Wayland app requires that app to be focused, this breaks "copy in an
    X11 app, click a Wayland app, paste" - not a rare edge case.

    This intentionally asserts the CURRENT broken behavior. If a wlroots
    upgrade fixes it, this assertion starts failing - the failure is a
    signal to update this test (and re-check the plan's clipboard item),
    not a regression to chase.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-clipboard-limit-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        x11_client = None
        wl_client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display
                wl_display = wayland_display_name(tmp)
                fixture = str(ROOT / "tests/clipboard_gtk_client.py")

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                def send(client, line):
                    client.stdin.write(line + "\n")
                    client.stdin.flush()

                def last_line(log_path):
                    lines = [
                        ln for ln in log_path.read_text().splitlines()
                        if ln and "DeprecationWarning" not in ln and not ln.strip().startswith("window.")
                    ]
                    return lines[-1] if lines else ""

                x11_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="x11")
                x11_env.pop("WAYLAND_DISPLAY", None)
                x11_log_path = tmp / "x11.log"
                with x11_log_path.open("w") as x11_log:
                    x11_client = subprocess.Popen(
                        [sys.executable, fixture], env=x11_env,
                        stdin=subprocess.PIPE, stdout=x11_log, stderr=x11_log, text=True,
                    )
                wait_for(lambda: any(w.get("backend") == "xwayland" for w in windows()), "no x11", timeout=20)

                wl_env = dict(os.environ, WAYLAND_DISPLAY=wl_display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="wayland")
                wl_env.pop("DISPLAY", None)
                wl_log_path = tmp / "wl.log"
                with wl_log_path.open("w") as wl_log:
                    wl_client = subprocess.Popen(
                        [sys.executable, fixture], env=wl_env,
                        stdin=subprocess.PIPE, stdout=wl_log, stderr=wl_log, text=True,
                    )
                wait_for(lambda: any(w.get("backend") == "xdg" for w in windows()), "no wl", timeout=20)

                time.sleep(0.3)
                send(x11_client, "copy hello-from-x11")
                wait_for(lambda: last_line(x11_log_path).startswith("copied"), "X11 client did not copy")

                wl_win = next(w for w in windows() if w.get("backend") == "xdg")
                request(sock, reader, {"version": 1, "command": 'focus_window', "params": {"id": wl_win["id"]}})
                wait_for(
                    lambda: (f := request(sock, reader, {'version': 1, 'command': 'focused_window'})["FocusedWindow"]) and f["id"] == wl_win["id"],
                    "could not focus the Wayland window",
                )

                KEY_LEFTCTRL, KEY_V = 29, 47
                for keycode, pressed in ((KEY_LEFTCTRL, True), (KEY_V, True), (KEY_V, False), (KEY_LEFTCTRL, False)):
                    request(sock, reader, {"version": 1, "command": 'key', "params": {"keycode": keycode, "pressed": pressed}})

                wait_for(lambda: last_line(wl_log_path) in ("pasted-none", "pasted 14 bytes: 'hello-from-x11'"),
                         "Ctrl+V produced no reaction at all", timeout=5)
                result = last_line(wl_log_path)
                assert result == "pasted-none", (
                    f"X11-to-Wayland clipboard now works after a focus switch (got {result!r}) - "
                    "wlroots appears to have fixed the incoming.c focus check; update this test and "
                    "TESTING.md/plan-xwayland.md, this is good news, not a failure to chase blindly"
                )
                print("PASS (documents a known limitation): X11 clipboard content is unavailable to a "
                      "focused Wayland app once focus has left every Xwayland surface")
        finally:
            for c in (x11_client, wl_client):
                if c and c.poll() is None:
                    c.terminate()
                    c.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def _dnd_client_env(backend, display, wl_display, tmp):
    if backend == "x11":
        env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="x11")
        env.pop("WAYLAND_DISPLAY", None)
    else:
        env = dict(os.environ, WAYLAND_DISPLAY=wl_display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="wayland")
        env.pop("DISPLAY", None)
    return env


def _run_drag(sock, reader, tmp, display, wl_display, src_backend, dst_backend):
    """Drives one drag gesture between a source and destination
    dnd_gtk_client.py instance (each either X11 or native Wayland) and
    returns (dst_log_text, src_log_text). The gesture is composed from raw
    MoveCursor/PointerButton calls rather than the compositor's built-in
    Drag IPC action: Drag's fixed 10-step interpolation moves too fast for
    DnD's async per-motion accept handshake between destination and source
    (confirmed while writing this test - GTK's drag-motion status round trip
    needs more, and slower, motion events than a plain resize/move drag
    does).
    """
    fixture = str(ROOT / "tests/dnd_gtk_client.py")

    def windows():
        return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

    wanted_backend = {"x11": "xwayland", "wayland": "xdg"}

    src_log_path = tmp / "dnd-src.log"
    with src_log_path.open("w") as src_log:
        src = subprocess.Popen(
            [sys.executable, fixture, "source"],
            env=_dnd_client_env(src_backend, display, wl_display, tmp),
            stdin=subprocess.PIPE, stdout=src_log, stderr=src_log, text=True,
        )
    wait_for(lambda: any(w.get("backend") == wanted_backend[src_backend] for w in windows()),
             "drag source client did not appear", timeout=20)

    dst_log_path = tmp / "dnd-dst.log"
    with dst_log_path.open("w") as dst_log:
        dst = subprocess.Popen(
            [sys.executable, fixture, "dest"],
            env=_dnd_client_env(dst_backend, display, wl_display, tmp),
            stdin=subprocess.PIPE, stdout=dst_log, stderr=dst_log, text=True,
        )
    if src_backend == dst_backend:
        wait_for(lambda: sum(1 for w in windows() if w.get("backend") == wanted_backend[dst_backend]) >= 2,
                 "drag destination client did not appear", timeout=20)
    else:
        wait_for(lambda: any(w.get("backend") == wanted_backend[dst_backend] for w in windows()),
                 "drag destination client did not appear", timeout=20)

    try:
        wlist = windows()
        src_win = next(w for w in wlist if "source" in w["title"])
        dst_win = next(w for w in wlist if "dest" in w["title"])
        request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": src_win["id"], "x": 100, "y": 100}})
        request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": dst_win["id"], "x": 500, "y": 100}})

        def box(wid):
            return request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]

        wait_for(lambda: abs(box(src_win["id"])["x"] - 100) <= 1, "drag source did not move")
        wait_for(lambda: abs(box(dst_win["id"])["x"] - 500) <= 1, "drag destination did not move")
        sbox, dbox = box(src_win["id"]), box(dst_win["id"])
        fx, fy = sbox["x"] + 50, sbox["y"] + 50
        tx, ty = dbox["x"] + 50, dbox["y"] + 50

        def move(x, y):
            request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": round(x), "y": round(y)}})

        move(fx, fy)
        request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
        time.sleep(0.05)
        steps = 12
        for i in range(1, steps + 1):
            t = i / steps
            move(fx + (tx - fx) * t, fy + (ty - fy) * t)
            time.sleep(0.05)
        for _ in range(3):
            time.sleep(0.1)
            move(tx, ty)
        time.sleep(0.3)
        request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})
        # The data-fetch round trip after "drag-drop" is async and, for a
        # cross-process/cross-backend destination, can take a little longer
        # than the fixed delays used to drive the gesture above - poll for
        # it rather than guessing a single sleep length.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and "drag-data-received" not in dst_log_path.read_text():
            time.sleep(0.05)
        request(sock, reader, {"version": 1, "command": 'close_window', "params": {"id": src_win["id"]}})
        request(sock, reader, {"version": 1, "command": 'close_window', "params": {"id": dst_win["id"]}})
    finally:
        for c in (src, dst):
            if c.poll() is None:
                c.terminate()
                c.wait(timeout=5)
    return dst_log_path.read_text(), src_log_path.read_text()


def test_drag_and_drop():
    """Real-GTK drag-and-drop (URI target, text/uri-list) between a source
    and a destination window, for the three source/destination combinations
    that actually work: X11->X11, native Wayland->X11, and native
    Wayland->native Wayland.

    Getting this working required two real fixes in src/Input.zig, neither
    Xwayland-specific (confirmed with two native Wayland clients, Xwayland
    disabled entirely):

    - passthroughMotion only kept an implicit pointer grab (motion routed to
      the surface a button went down on, not whatever's now under the
      cursor) for layer-shell surfaces. For ordinary client content it kept
      re-hit-testing during a held-button drag, silently re-entering
      whatever the cursor crossed into and invalidating the seat's pointer
      grab serial before the source client could recognize the gesture and
      call wl_data_device.start_drag.
    - Even with that fixed, clicking an *unfocused* window to start a drag
      from it still failed: World.focusSurface()'s keyboard-enter call ran
      after pointerNotifyButton, so the client saw a keyboard-focus-change
      event (a separate, later serial) right after the button press, and
      GTK's start_drag request ended up referencing that later serial
      instead of the button's. wlroots then rejects the drag as stale
      ("Pointer grab serial validation failed", wlr_seat_pointer.c). Fixed
      by requesting the focus change before pointerNotifyButton instead of
      after. Clicking an unfocused window to drag from it is an entirely
      ordinary gesture, not a rare edge case - both bugs would have hit any
      real multi-window drag, X11 or native.

    The fourth combination, X11 source -> native Wayland destination, still
    doesn't work - see test_x11_source_drag_to_wayland_limitation.

    Only the URI target is checked here even though the fixture offers both
    text/uri-list and text/plain: GTK's own target negotiation consistently
    picks text/uri-list first in practice (observed while writing this
    test), and forcing text/plain instead isn't worth the added complexity
    for what these fixes needed to prove.

    Each combination gets its own compositor instance: a second drag within
    one session was unreliable even for a combination that passes reliably
    as the only drag in its session (the source's drag-data-get was never
    even asked for) - another instance of the same "state left over from an
    earlier interaction confuses the next one" class this session already
    hit for clicks (see test_gtk_menu_alignment_zoomed's settle-delay note)
    and for two clicks at an identical local pixel (test_gtk_menu_alignment).
    Not worth its own investigation on top of those; giving each combination
    a clean seat sidesteps it the same way test_gtk_menu_multi_output and
    test_gtk_menu_fractional_scale already do for unrelated reasons.
    """
    for src_backend, dst_backend, label in (
        ("x11", "x11", "X11 -> X11"),
        ("wayland", "x11", "native Wayland -> X11"),
        ("wayland", "wayland", "native Wayland -> native Wayland"),
    ):
        with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-dnd-") as directory:
            tmp = Path(directory)
            compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
            try:
                sock, reader = ipc_connect(tmp)
                with sock:
                    info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                    display = info["xwayland_display"]
                    assert display
                    wl_display = wayland_display_name(tmp)

                    dst_text, src_text = _run_drag(sock, reader, tmp, display, wl_display, src_backend, dst_backend)
                    assert "drag-data-received text/uri-list ['file:///tmp/drag-test-file.txt']" in dst_text, (
                        f"{label}: destination did not receive the dropped URI\nsrc: {src_text}\ndst: {dst_text}"
                    )
                    print(f"PASS: drag-and-drop works {label}")
            finally:
                compositor.terminate()
                compositor.wait(timeout=5)
                log.close()


def test_x11_source_drag_to_wayland_limitation():
    """Pins a real, confirmed limitation of the pinned wlroots (0.20.x): a
    drag started on an X11 window never reaches a native Wayland
    destination. Unlike test_drag_and_drop's two fixes, this isn't
    something this compositor's code can influence - Input.zig's
    requestStartDrag (src/Input.zig) never fires at all for an X11-sourced
    drag (confirmed by temporarily logging inside it while writing this
    test), meaning Xwayland's XWM never asks our seat to start a Wayland
    drag for it in the first place. There is no drag/DnD API in the pinned
    wlroots 0.20 Xwayland bindings (checked the vendored zig-wlroots source,
    same as the clipboard and multi-output findings elsewhere in this file)
    for the compositor to influence this. X11 -> X11 drags keep working
    (confirmed in test_drag_and_drop) because XDND between two Xwayland
    windows never needs to leave Xwayland's own embedded X server.

    This intentionally asserts the CURRENT broken behavior. If a wlroots
    upgrade fixes it, this assertion starts failing - update this test (and
    test_drag_and_drop to cover the newly-working combination) rather than
    treating the failure as a regression to chase.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-dnd-limit-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display
                wl_display = wayland_display_name(tmp)

                dst_text, src_text = _run_drag(sock, reader, tmp, display, wl_display, "x11", "wayland")
                assert "drag-data-received" not in dst_text, (
                    "X11-to-Wayland drag-and-drop now works (a wlroots upgrade may have fixed the "
                    "underlying XWM gap) - update this test and test_drag_and_drop, this is good "
                    f"news, not a failure to chase blindly\nsrc: {src_text}\ndst: {dst_text}"
                )
                print("PASS (documents a known limitation): a drag started on an X11 window never "
                      "reaches a native Wayland destination")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_primary_selection_bidirectional():
    """PRIMARY selection (X11's separate "select text, middle-click to
    paste" selection - distinct from CLIPBOARD) between a real X11 client
    and wl-paste/wl-copy --primary.

    Landing this required real compositor changes, unlike clipboard/DnD
    which only needed tests: this project had no primary-selection protocol
    at all before this session (no wlr_primary_selection_v1_device_manager,
    no seat request_set_primary_selection listener - grep found zero
    matches). Added both, mirroring the existing CLIPBOARD wiring exactly
    (Server.zig: wlr.PrimarySelectionDeviceManagerV1.create() next to
    wlr.DataDeviceManager.create(); Input.zig: requestSetPrimarySelection
    next to requestSetSelection, same one-line body).

    Bidirectional transfer through wlroots' XWM bridge works immediately
    with no further changes, at the same X11-must-be-focused-to-relay-to-
    Wayland asymmetry documented for CLIPBOARD above (same
    xwayland/selection/incoming.c code path, just XA_PRIMARY instead of
    CLIPBOARD) - not re-verified separately here to avoid redundant
    investigation of a limitation already characterized in detail.

    The Wayland-to-X11 direction uses an actual middle click. Input.zig holds
    the press until motion distinguishes a camera pan from a click; a click
    is then delivered to the client as button 2 and GTK pulls PRIMARY.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-primary-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        x11_client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display
                wl_display = wayland_display_name(tmp)
                fixture = str(ROOT / "tests/clipboard_gtk_client.py")

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                def send(client, line):
                    client.stdin.write(line + "\n")
                    client.stdin.flush()

                def last_line(log_path):
                    lines = [
                        ln for ln in log_path.read_text().splitlines()
                        if ln and "DeprecationWarning" not in ln and not ln.strip().startswith("window.")
                    ]
                    return lines[-1] if lines else ""

                x11_env = dict(
                    os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp),
                    GDK_BACKEND="x11", CLIPBOARD_SELECTION="primary",
                )
                x11_env.pop("WAYLAND_DISPLAY", None)
                x11_log_path = tmp / "x11-primary.log"
                with x11_log_path.open("w") as x11_log:
                    x11_client = subprocess.Popen(
                        [sys.executable, fixture], env=x11_env,
                        stdin=subprocess.PIPE, stdout=x11_log, stderr=x11_log, text=True,
                    )
                wait_for(lambda: any(w.get("backend") == "xwayland" for w in windows()),
                         "X11 client did not appear", timeout=20)
                time.sleep(0.3)

                # X11 -> Wayland, X11 still focused (see docstring).
                send(x11_client, "copy primary-from-x11")
                wait_for(lambda: last_line(x11_log_path).startswith("copied"), "X11 client did not copy")
                wl_env = dict(os.environ, WAYLAND_DISPLAY=wl_display, XDG_RUNTIME_DIR=str(tmp))
                wl_env.pop("DISPLAY", None)
                r = subprocess.run(["wl-paste", "--primary"], env=wl_env, capture_output=True, text=True, timeout=10)
                assert r.returncode == 0 and r.stdout == "primary-from-x11\n", r
                print("PASS: PRIMARY selection set on X11 (still focused) reaches a native Wayland reader")

                # Wayland -> X11, via a fresh client so focus naturally lands
                # there (mirrors test_clipboard_bidirectional's own pattern).
                send(x11_client, "quit")
                x11_client.wait(timeout=5)
                x11_client = None
                wc = subprocess.Popen(["wl-copy", "--primary", "primary-from-wayland"], env=wl_env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    time.sleep(0.3)
                    x11_log2_path = tmp / "x11-primary-2.log"
                    with x11_log2_path.open("w") as x11_log2:
                        x11_client = subprocess.Popen(
                            [sys.executable, fixture], env=x11_env,
                            stdin=subprocess.PIPE, stdout=x11_log2, stderr=x11_log2, text=True,
                        )
                    wait_for(lambda: any(w.get("backend") == "xwayland" for w in windows()),
                             "replacement X11 client did not appear", timeout=20)
                    time.sleep(0.3)
                    x11_window = next(w for w in windows() if w.get("backend") == "xwayland")
                    box = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": x11_window["id"]}})["WindowDebug"]["client_box"]
                    request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {
                        "x": box["x"] + box["width"] // 2,
                        "y": box["y"] + box["height"] // 2,
                    }})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 274, "pressed": True}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 274, "pressed": False}})
                    wait_for(
                        lambda: last_line(x11_log2_path) == "pasted 20 bytes: 'primary-from-wayland'",
                        lambda: f"X11 could not read Wayland-sourced PRIMARY selection: {last_line(x11_log2_path)!r}",
                        timeout=5,
                    )
                    print("PASS: a real X11 middle click pastes PRIMARY set by native Wayland")
                finally:
                    if wc.poll() is None:
                        wc.terminate()
        finally:
            if x11_client and x11_client.poll() is None:
                x11_client.terminate()
                x11_client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()
