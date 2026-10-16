"""Xwayland tests: enabling, scaling, cleanup, managed windows and the switcher."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from xwayland_support import build_client, ipc_connect, request, start_compositor, start_x11_client, wait_for, wayland_display_name


def test_enabled():
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_enabled"] is True, info
                display = info["xwayland_display"]
                assert display and display.startswith(":"), display

                # First X client, immediately after startup, before ready.
                env_path = tmp / "child.env"
                request(sock, reader, {"version": 1, "command": 'spawn', "params": {"argv": [
                    "/bin/sh", "-c", f"env > {env_path}",
                ]}})
                wait_for(lambda: env_path.exists() and env_path.stat().st_size > 0, "child env not written")
                child_env = env_path.read_text()
                assert f"DISPLAY={display}" in child_env, child_env
                assert "WAYLAND_DISPLAY=" in child_env, child_env
                assert "REDIWM_SOCKET=" in child_env, child_env

                probe = subprocess.run(
                    ["xdpyinfo", "-display", display],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    env=dict(os.environ, DISPLAY=display),
                )
                assert probe.returncode == 0, probe.stderr + probe.stdout
                print(f"PASS: enabled Xwayland on {display}")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_native_scaling_root_geometry(factor=2, output_policy=False):
    """When xwayland_native_scaling is enabled, Xwayland root geometry is scaled
    by N = ceil(max_scale) and RESOURCE_MANAGER properties (Xft.dpi and Xcursor.size)
    are set.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-native-scaling-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(
            tmp,
            "[compositor]\nxwayland = true\nxwayland_native_scaling = true\n" +
            (f"xwayland_scale = {factor}\n" if factor != 2 else "") +
            ('[[outputs]]\nname = "HEADLESS-1"\nscale = 1.5\n' if output_policy else ""),
            {"REDIWM_SCALE": "auto" if output_policy else "1.5"},
        )
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_enabled"] is True, info
                assert info["xwayland_native_scaling"] is True, info
                assert info["xwayland_scale"] == factor, info
                assert info["xwayland_scale_pending"] is None, info
                display = info["xwayland_display"]
                assert display and display.startswith(":"), display

                # Native scaling must reserve DISPLAY without launching the
                # server. The first connection still gets settled output scale.
                time.sleep(.2)
                startup = request(sock, reader, {'version': 1, 'command': 'get_performance_stats'})["PerformanceStats"]["startup"]
                assert startup["xwayland_ready_ns"] == 0, startup

                probe = subprocess.run(
                    ["xdpyinfo", "-display", display],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    env=dict(os.environ, DISPLAY=display),
                )
                assert probe.returncode == 0, probe.stderr + probe.stdout
                # Default headless output 1920x1080 @ 1.5x -> 1280x720 logical; * N(2) -> 2560x1440
                assert f"{round(1280 * factor)}x{round(720 * factor)} pixels" in probe.stdout, probe.stdout

                rdb = subprocess.run(
                    ["xrdb", "-display", display, "-query"],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    env=dict(os.environ, DISPLAY=display),
                )
                assert rdb.returncode == 0, rdb.stderr + rdb.stdout
                assert abs(float(next(line.split(":", 1)[1] for line in rdb.stdout.splitlines() if line.startswith("Xft.dpi:"))) - 96 * factor) < 0.01, rdb.stdout
                assert "Xcursor.size:\t24" in rdb.stdout or "Xcursor.size: 24" in rdb.stdout, rdb.stdout
                print(f"PASS: native scaling root geometry and RESOURCE_MANAGER hints on {display}")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_disabled():
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-off-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = false\n")
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_enabled"] is False, info
                assert info["xwayland_display"] is None, info

                env_path = tmp / "child.env"
                request(sock, reader, {"version": 1, "command": 'spawn', "params": {"argv": [
                    "/bin/sh", "-c", f"env > {env_path}",
                ]}})
                wait_for(lambda: env_path.exists() and env_path.stat().st_size > 0, "child env not written")
                child_env = env_path.read_text()
                for line in child_env.splitlines():
                    assert not line.startswith("DISPLAY="), child_env
                    assert not line.startswith("XAUTHORITY="), child_env
                assert "WAYLAND_DISPLAY=" in child_env, child_env
                print("PASS: disabled Xwayland strips host DISPLAY")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_missing_executable():
    """An enabled configuration remains a usable native compositor when
    Xwayland is absent from PATH, and never republishes the host DISPLAY.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-missing-") as directory:
        tmp = Path(directory)
        empty_path = tmp / "empty-bin"
        empty_path.mkdir()
        compositor, log = start_compositor(
            tmp, "[compositor]\nxwayland = true\n", {"PATH": str(empty_path)}
        )
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_enabled"] is False, info
                assert info["xwayland_display"] is None, info
                env_path = tmp / "missing.env"
                request(sock, reader, {"version": 1, "command": 'spawn', "params": {"argv": [
                    "/bin/sh", "-c", f"env > {env_path}",
                ]}})
                wait_for(lambda: env_path.exists(), "native child did not launch without Xwayland")
                assert not any(line.startswith("DISPLAY=") for line in env_path.read_text().splitlines())
                print("PASS: missing Xwayland leaves native clients usable and strips DISPLAY")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_server_stop_cleanup():
    """Stopping the owned Xwayland wrapper removes its published DISPLAY while the
    compositor and its native IPC surface remain alive. A later compositor
    must then be able to reserve and start a fresh Xwayland instance.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-crash-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n", {
            "MALLOC_PERTURB_": "165", "GLIBC_TUNABLES": "glibc.malloc.tcache_count=0",
        })
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                display = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
                client = subprocess.Popen(
                    [str(tmp / "x11-client")],
                    env=dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp)),
                    stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                wait_for(
                    lambda: any(w.get("backend") == "xwayland" for w in request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]),
                    "live X11 client did not map before stop test",
                    timeout=20,
                )
                # One read callback sees both requests before idle dispatch.
                # They must coalesce rather than queue two frees of the wrapper.
                sock.sendall((json.dumps({"version": 1, "command": "stop_xwayland"}) + "\n").encode() * 2)
                for _ in range(2):
                    reply = json.loads(reader.readline())
                    assert "Ok" in reply, reply
                retired = wait_for(
                    lambda: (info if not (info := request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"])["xwayland_enabled"] else None),
                    "compositor did not retire the stopped Xwayland instance",
                )
                assert retired["xwayland_display"] is None, retired
                assert compositor.poll() is None, "Xwayland disconnect terminated the compositor"
                print("PASS: Xwayland failure leaves the native compositor usable")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()

        # A clean next session catches stale X sockets or ownership left by
        # the forced teardown above.
        next_runtime = tmp / "next"
        next_runtime.mkdir(mode=0o700)
        compositor, log = start_compositor(next_runtime, "[compositor]\nxwayland = true\n")
        try:
            sock, reader = ipc_connect(next_runtime)
            with sock:
                display = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
                probe = subprocess.run(["xdpyinfo", "-display", display], capture_output=True, timeout=10)
                assert probe.returncode == 0, probe.stderr
                print("PASS: a subsequent session starts a fresh Xwayland server")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_managed_window():
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-win-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display

                client_log = tmp / "client.log"
                client_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp))
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [str(tmp / "x11-client")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next((w for w in windows() if w.get("backend") == "xwayland"), None),
                    "X11 window did not appear",
                    timeout=20,
                )
                assert win["backend"] == "xwayland"
                assert win["app_id"] == "XwaylandFixture" or win["x11_class"] == "XwaylandFixture", win
                assert win["is_minimized"] is False
                wid = win["id"]

                request(sock, reader, {"version": 1, "command": 'focus_window', "params": {"id": wid}})
                focused = request(sock, reader, {'version': 1, 'command': 'focused_window'})["FocusedWindow"]
                assert focused and focused["id"] == wid, focused

                debug = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]
                assert debug["chrome_box"]["width"] > 0 and debug["chrome_box"]["height"] > 0, debug

                client.stdin.write("title Live X11 Title\n")
                client.stdin.flush()
                wait_for(lambda: next((w for w in windows() if w["id"] == wid and w["title"] == "Live X11 Title"), None),
                         "live X11 title change did not reach IPC/taskbar state")
                client.stdin.write("class live-instance LiveX11Class\n")
                client.stdin.flush()
                wait_for(lambda: next((w for w in windows() if w["id"] == wid and w.get("x11_class") == "LiveX11Class"), None),
                         "live WM_CLASS change did not reach IPC/taskbar state")
                print("PASS: live X11 title and WM_CLASS changes update shared window state")

                request(sock, reader, {"version": 1, "command": 'minimize_window', "params": {"id": wid}})
                wait_for(lambda: next((w for w in windows() if w["id"] == wid and w["is_minimized"]), None),
                         "X11 minimize did not apply")
                request(sock, reader, {"version": 1, "command": 'restore_window', "params": {"id": wid}})
                wait_for(lambda: next((w for w in windows() if w["id"] == wid and not w["is_minimized"]), None),
                         "X11 restore from minimized did not apply")
                print("PASS: X11 minimize and restore work through shared shell controls")

                request(sock, reader, {"version": 1, "command": 'set_window_size', "params": {"id": wid, "width": 480, "height": 320}})
                wait_for(
                    lambda: (d := request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"])
                    and d["client_box"]["width"] == 480 and d["client_box"]["height"] == 320,
                    "resize did not apply",
                )

                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": wid, "x": 180, "y": 140}})
                original = wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and w["x"] == 180 and w["y"] == 140), None),
                    "window did not reach restore-test position",
                )
                original_geometry = (original["x"], original["y"], original["width"], original["height"])

                request(sock, reader, {"version": 1, "command": 'maximize_window', "params": {"id": wid}})
                wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and w["is_maximized"] and w["width"] > original["width"]), None),
                    lambda: (f"X11 maximize did not apply: {next((w for w in windows() if w['id'] == wid), None)}; "
                             f"client events: {client_log.read_text()!r}"),
                )
                request(sock, reader, {"version": 1, "command": 'restore_window', "params": {"id": wid}})
                wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and not w["is_maximized"] and
                                  (w["x"], w["y"], w["width"], w["height"]) == original_geometry), None),
                    "X11 un-maximize did not restore position and size",
                )
                print("PASS: X11 maximize restores saved geometry")

                request(sock, reader, {"version": 1, "command": 'fullscreen_window', "params": {"id": wid}})
                wait_for(
                    lambda: request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["fullscreen"],
                    "X11 fullscreen did not apply",
                )
                request(sock, reader, {"version": 1, "command": 'fullscreen_window', "params": {"id": wid}})
                wait_for(
                    lambda: (not request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["fullscreen"] and
                             (lambda w: (w["x"], w["y"], w["width"], w["height"]) == original_geometry)(
                                 next(w for w in windows() if w["id"] == wid))),
                    "X11 leaving fullscreen did not restore position and size",
                )
                print("PASS: X11 fullscreen restores saved geometry")

                client.stdin.write("unmap\n")
                client.stdin.flush()
                wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 unmap left a visible window")
                client.stdin.write("map\n")
                client.stdin.flush()
                wait_for(lambda: any(w["id"] == wid for w in windows()), "X11 remap did not restore the same window")
                print("PASS: X11 window unmaps and remaps with a stable id")

                role_box = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]
                role_x, role_y = role_box["x"] + 20, role_box["y"] + 20
                client.stdin.write("unmap\n")
                client.stdin.flush()
                wait_for(lambda: all(w["id"] != wid for w in windows()), "managed-to-override transition kept a taskbar window")
                client.stdin.write("override 1\n")
                client.stdin.flush()
                time.sleep(0.1)
                client.stdin.write("map\n")
                client.stdin.flush()
                hit = wait_for(
                    lambda: (h if (h := request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": role_x, "y": role_y}})["HitTest"])["target_type"] == "xwayland_unmanaged" else None),
                    lambda: (f"managed-to-override transition did not create an unmanaged hit target: "
                             f"{request(sock, reader, {"version": 1, "command": 'hit_test', "params": {'x': role_x, 'y': role_y}})['HitTest']}; "
                             f"events={client_log.read_text()!r}"),
                )
                assert hit["target_type"] == "xwayland_unmanaged"

                client.stdin.write("unmap\n")
                client.stdin.flush()
                time.sleep(0.1)
                client.stdin.write("override 0\n")
                client.stdin.flush()
                time.sleep(0.1)
                client.stdin.write("map\n")
                client.stdin.flush()
                transitioned = wait_for(
                    lambda: next((w for w in windows() if w.get("backend") == "xwayland"), None),
                    "override-to-managed transition did not recreate a managed window",
                )
                wid = transitioned["id"]
                print("PASS: live override-redirect role changes work in both directions")

                client.stdin.write("popup\n")
                client.stdin.flush()
                time.sleep(0.3)
                box = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]
                hit = request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": box["x"] + 30, "y": box["y"] + 30}})["HitTest"]
                assert hit["target_type"] in ("xwayland_unmanaged", "window"), hit
                print("PASS: override-redirect popup is hittable")

                request(sock, reader, {"version": 1, "command": 'close_window', "params": {"id": wid}})
                wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 window did not close")
                print("PASS: managed X11 window maps, focuses, resizes, closes")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_native_scaling_managed_window(factor=2):
    """Managed X11 window scaling, projection, input coordinates, resize,
    maximize/restore, and unmanaged popup hit testing with a selectable rendering factor.
    """
    import math
    from PIL import Image

    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-native-win-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(
            tmp,
            f"[compositor]\nxwayland = true\nxwayland_native_scaling = true\nxwayland_scale = {factor}\n",
            {"REDIWM_SCALE": "1.5"},
        )
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_native_scaling"] is True
                assert info["xwayland_scale"] == factor
                display = info["xwayland_display"]
                assert display

                client_log = tmp / "client.log"
                client_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp))
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [str(tmp / "x11-client")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next((w for w in windows() if w.get("backend") == "xwayland"), None),
                    "X11 window did not appear",
                    timeout=20,
                )
                wid = win["id"]

                # Surface pixels map back to logical client dimensions.
                dbg = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]
                cbox = dbg["client_box"]
                # Native-scaled X11 chrome is drawn at density 0.75 of the default 46 px titlebar.
                assert dbg["titlebar_height"] == 35, dbg  # 46 * 0.75 = 34.5, rounded half up
                assert cbox["width"] == math.ceil(400 / factor) and cbox["height"] == math.ceil(300 / factor), f"Unexpected client geometry at factor {factor}: {cbox}"

                # Focus window
                request(sock, reader, {"version": 1, "command": 'focus_window', "params": {"id": wid}})

                # Screenshot check at a 1.5x output scale.
                shot_path = tmp / "shot.png"
                time.sleep(0.3)
                request(sock, reader, {"version": 1, "command": 'screenshot', "params": {"path": str(shot_path)}})
                wait_for(lambda: shot_path.exists() and shot_path.stat().st_size > 0, "screenshot not saved")
                with Image.open(shot_path) as img:
                    white_coords = [
                        (x, y)
                        for y in range(round((cbox["y"] + 10) * 1.5), round((cbox["y"] + 20) * 1.5))
                        for x in range(img.width)
                        if img.getpixel((x, y))[:3] == (255, 255, 255)
                    ]
                    assert white_coords, "no white pixels found in screenshot"
                    min_x = min(x for x, y in white_coords)
                    max_x = max(x for x, y in white_coords)
                    min_y = min(y for x, y in white_coords)
                    # Measure an interior band, excluding text, corners and skirt.
                    assert abs(max_x - min_x + 1 - 600 / factor) <= 1, f"Expected device width near {600 / factor}, got {max_x - min_x + 1}"
                    client_crop = img.crop((min_x, min_y, min_x + int(600 / factor) - 1, min_y + 10))
                    assert client_crop.convert("RGB").getextrema() == ((255, 255), (255, 255), (255, 255)), "client area not solid white"
                print("PASS: native scaled X11 window renders downscaled buffer at expected device pixels")

                # Avoid exact fractional-to-integer boundaries in X11 event truncation.
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": cbox["x"] + 51, "y": cbox["y"] + 41}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})

                def get_client_lines():
                    if not client_log.exists():
                        return []
                    return [l.strip() for l in client_log.read_text().splitlines() if l.strip()]

                wait_for(
                    lambda: f"button-press 1 {math.floor(51 * factor)} {math.floor(41 * factor)}" in get_client_lines(),
                    lambda: f"Expected scaled button event in log, got: {get_client_lines()}",
                    timeout=5,
                )
                print("PASS: pointer button click scales world coordinates x N into X11 coordinates")

                # Pointer motion with implicit grab: drag outside window
                client.stdin.write("log-motion 1\n")
                client.stdin.flush()
                time.sleep(0.1)
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": cbox["x"] + 51, "y": cbox["y"] + 41}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": cbox["x"] + 251, "y": cbox["y"] + 201}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})
                client.stdin.write("log-motion 0\n")
                client.stdin.flush()

                wait_for(
                    lambda: f"motion {math.floor(251 * factor)} {math.floor(201 * factor)}" in get_client_lines(),
                    lambda: f"Expected scaled grab motion in log, got: {get_client_lines()}",
                    timeout=5,
                )
                print("PASS: pointer motion grab extrapolates correctly with scale N")

                # Odd logical sizes must round trip without accumulating pixels.
                request(sock, reader, {"version": 1, "command": 'set_window_size', "params": {"id": wid, "width": 481, "height": 321}})
                wait_for(
                    lambda: any(f"{math.floor(481 * factor + 1e-9)} {math.floor(321 * factor + 1e-9)}" in l for l in get_client_lines() if l.startswith("configure")),
                    lambda: f"Expected scaled configure dimensions in log, got: {get_client_lines()}",
                    timeout=5,
                )
                wait_for(
                    lambda: (d := request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"])
                    and d["client_box"]["width"] == 481 and d["client_box"]["height"] == 321,
                    "resize to 481x321 did not apply in compositor debug box",
                    timeout=5,
                )
                print("PASS: SetWindowSize scales dimensions by N when configuring X11 window")

                # Maximize and Restore
                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": wid, "x": 180, "y": 140}})
                original = wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and w["x"] == 180 and w["y"] == 140), None),
                    "window did not reach restore-test position",
                )
                original_geometry = (original["x"], original["y"], original["width"], original["height"])

                request(sock, reader, {"version": 1, "command": 'maximize_window', "params": {"id": wid}})
                wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and w["is_maximized"] and w["width"] > original["width"]), None),
                    "X11 maximize did not apply",
                    timeout=5,
                )
                request(sock, reader, {"version": 1, "command": 'restore_window', "params": {"id": wid}})
                wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and not w["is_maximized"] and
                                  (w["x"], w["y"], w["width"], w["height"]) == original_geometry), None),
                    "X11 un-maximize did not restore position and size",
                    timeout=5,
                )
                print("PASS: Maximize and Restore roundtrip correctly under native scaling")

                time.sleep(0.3)  # Let the restore presentation settle.

                # Unmanaged override-redirect popup hit testing
                cbox = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]
                client.stdin.write("popup\n")
                client.stdin.flush()

                hit = wait_for(
                    lambda: (
                        h
                        if (h := request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": cbox["x"] + round(60 / factor), "y": cbox["y"] + round(40 / factor)}})["HitTest"])["target_type"] == "xwayland_unmanaged"
                        else None
                    ),
                    lambda: f"override-redirect popup was not hittable: {request(sock, reader, {"version": 1, "command": 'hit_test', "params": {'x': cbox['x'] + 20, 'y': cbox['y'] + 15}})['HitTest']}",
                    timeout=5,
                )
                assert hit["target_type"] == "xwayland_unmanaged", f"Expected xwayland_unmanaged, got {hit}"
                print("PASS: override-redirect popup is positioned and hit-tested with scale 1/N")

                # Click the visibly scaled close control.
                dbg = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]
                frame = dbg["chrome_box"]
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": frame["x"] + frame["width"] - 1 - 22, "y": frame["y"] + dbg["titlebar_height"] // 2}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})
                wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 window did not close")
                print("PASS: native scaled managed X11 window lifecycle completed successfully")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_switcher_input(factor=1):
    """Check X11's actual key state and repeated clicks after switching back."""
    from desktop_zoom import build_client as build_wayland_client
    from ipc_client import IPCClient, stop_process

    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-switcher-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        build_wayland_client(tmp)
        compositor, log = start_compositor(
            tmp, f'[compositor]\nxwayland = true\nxwayland_native_scaling = true\nxwayland_scale = {factor}\n[keybinds]\n"alt+tab" = "focus_next"\n',
            {"XDG_STATE_HOME": str(tmp / "state"), "XDG_DATA_HOME": str(tmp / "data")},
        )
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                display = ipc.query('get_runtime_info')["xwayland_display"]
                client_log = tmp / "x11.log"
                client = start_x11_client(tmp, display, client_log)
                clients.append(client)
                xwin = wait_for(lambda: next((w for w in ipc.get_windows() if w['backend'] == 'xwayland'), None), 'X11 map')
                with (tmp / 'wayland.log').open('w') as out:
                    clients.append(subprocess.Popen(
                        [str(tmp / 'client'), '--title', 'Wayland peer'],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=wayland_display_name(tmp)),
                        stdout=out, stderr=out,
                    ))
                wait_for(lambda: len(ipc.get_windows()) == 2, 'Wayland map')
                def check_keys(label, expected=''):
                    # Xwayland processes Wayland input before answering the X query.
                    time.sleep(.15)
                    client.stdin.write(f'keys {label}\n')
                    client.stdin.flush()
                    line = wait_for(lambda: next((l for l in client_log.read_text().splitlines() if l.startswith(f'keys {label}')), None), 'query X keys')
                    assert line == f'keys {label}{expected}', f'Incorrect X11 keys after focus transfer: {line}'

                for mode in ('tab-first', 'alt-first', 'return'):
                    # Start on X11, switch away, then back with each release order.
                    ipc.action('focus_window', {'id': xwin['id']})
                    ipc.key(56, True)
                    ipc.key_down_up(15)
                    ipc.key(56, False)
                    wait_for(lambda: not next(w for w in ipc.get_windows() if w['id'] == xwin['id'])['is_focused'], 'switch away')
                    ipc.key(56, True)
                    ipc.key(15, True)
                    if mode == 'return':
                        ipc.key_down_up(28)
                    if mode == 'tab-first':
                        ipc.key(15, False)
                        ipc.key(56, False)
                    else:
                        ipc.key(56, False)
                        ipc.key(15, False)
                    wait_for(lambda: next(w for w in ipc.get_windows() if w['id'] == xwin['id'])['is_focused'], 'switch back')
                    check_keys(mode)
                print('PASS: Alt-Tab release order and Return acceptance leave no stuck X11 keys')

                # Genuine client keys must still be carried across focus changes.
                peer = next(w for w in ipc.get_windows() if w['id'] != xwin['id'])
                ipc.action('focus_window', {'id': peer['id']})
                ipc.key(30, True)  # A: evdev 30, X11 38
                ipc.action('focus_window', {'id': xwin['id']})
                check_keys('held', ' 38')
                ipc.key(30, False)
                check_keys('released')

                box = ipc.query('get_window_debug', {'id': xwin['id']})['client_box']
                # Scrollbars sit just inside the right edge; repeated clicks must
                # work without moving away to generate another pointer enter.
                ipc.move_cursor(box['x'] + box['width'] - 5, box['y'] + 80)
                for count in range(1, 4):
                    ipc.pointer_button(272, True)
                    ipc.pointer_button(272, False)
                    wait_for(lambda: client_log.read_text().count('button-release 1 ') == count,
                             lambda: f'Repeated right-edge click {count} lost: {client_log.read_text()}', timeout=3)
                print('PASS: repeated X11 right-edge clicks reach the client after Alt-Tab')
        finally:
            for client in clients:
                stop_process(client)
            stop_process(compositor)
            log.close()


def test_unmapped_window_has_no_chrome():
    """An X11 window that is configured and titled but never mapped must not
    show a frame. Its chrome used to be painted and hit-testable at the
    configured position, and clicking it focused a toplevel that was never
    linked into the window stack, crashing the compositor (seen live with
    ONLYOFFICE, which creates windows it never maps)."""
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-unmapped-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                display = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
                client_log = tmp / "client.log"
                client = start_x11_client(tmp, display, client_log, "--no-map", "--title", "Never Mapped")
                wait_for(lambda: "created" in client_log.read_text(), "X11 client did not start", timeout=20)
                client.stdin.write("configure 200 150 500 400\n")
                client.stdin.flush()
                time.sleep(0.3)  # The retitle must see the configured size.
                client.stdin.write("title Never Mapped Retitled\n")
                client.stdin.flush()
                time.sleep(0.5)

                points = [(450, 160), (450, 180), (210, 300), (450, 350), (699, 300)]
                for x, y in points:
                    hit = request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": x, "y": y}})["HitTest"]
                    assert hit["target_type"] == "none", (x, y, hit)
                    request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": x, "y": y}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})
                assert compositor.poll() is None, "compositor died clicking where an unmapped X11 window sits"
                assert all(w.get("backend") != "xwayland" for w in request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"])

                client.stdin.write("map\n")
                client.stdin.flush()
                win = wait_for(
                    lambda: next((w for w in request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]
                                  if w.get("backend") == "xwayland"), None),
                    "X11 window did not appear once mapped",
                )
                debug = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]
                title_x = debug["chrome_box"]["x"] + debug["chrome_box"]["width"] // 2
                title_y = debug["chrome_box"]["y"] + 10
                hit = request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": title_x, "y": title_y}})["HitTest"]
                assert hit["target_type"] == "chrome", hit
                print("PASS: an unmapped X11 window has no visible or clickable frame until it maps")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_withdrawn_window_survives_close_animation():
    """Unmapping without destroying (an X11 withdraw, a tray app hiding its
    window) plays the close animation. When it finished, the toplevel used to
    be freed while the X11 surface still had its listeners attached, so the
    next map or destroy ran on freed memory."""
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-withdraw-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                display = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
                client_log = tmp / "client.log"
                client = start_x11_client(tmp, display, client_log)

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                wid = wait_for(
                    lambda: next((w["id"] for w in windows() if w.get("backend") == "xwayland"), None),
                    "X11 window did not appear",
                    timeout=20,
                )
                for _ in range(2):
                    time.sleep(0.8)  # Let the open animation settle.
                    client.stdin.write("unmap\n")
                    client.stdin.flush()
                    wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 unmap left a visible window")
                    time.sleep(1.5)  # Outlast the close animation.
                    assert compositor.poll() is None, "compositor died finishing a withdrawn window's close animation"
                    client.stdin.write("title Withdrawn And Back\n")
                    client.stdin.flush()
                    client.stdin.write("map\n")
                    client.stdin.flush()
                    wait_for(lambda: any(w["id"] == wid for w in windows()),
                             "withdrawn X11 window did not come back with its id")
                client.stdin.write("close\n")
                client.stdin.flush()
                wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 window did not close")
                time.sleep(1.5)
                assert compositor.poll() is None, "compositor died destroying a previously withdrawn window"
                request(sock, reader, {'version': 1, 'command': 'windows'})
                print("PASS: a withdrawn X11 window outlives its close animation and remaps")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()
