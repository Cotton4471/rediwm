#!/usr/bin/env python3
"""Direct scan-out of an opaque fullscreen client (wlr_scene's single-entry path).

wlroots hands a client buffer straight to the output only when the scene has one
visible entry left, so everything under the client has to be culled. That needs
the projection to carry the client's opaque region (an XRGB buffer, or an ARGB
buffer with set_opaque_region) onto the projected node; it never did, so a
fullscreen client always left the wallpaper in the list and nothing was scanned
out. The headless backend accepts any buffer, so wlroots' own log lines are the
observable: "Direct scan-out enabled" / "disabled".

GLES2 (the required renderer): the pixman renderer lets wlroots see an shm
buffer's format through the wrapper, so it scans out even without the fix.
Needs a render node (WLR_RENDER_DRM_DEVICE on multi-GPU machines). Isolated
compositor, no host display. Run after zig build.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def scanning_out(log):
    """The last scan-out transition wlroots logged: on, off, or never on."""
    state = False
    for line in log.splitlines():
        if line.endswith("Direct scan-out enabled"):
            state = True
        elif line.endswith("Direct scan-out disabled"):
            state = False
    return state


def fullscreen_log(tmp, label, client_env):
    """Fullscreens one client under `client_env`; returns the compositor log."""
    run = tmp / label
    run.mkdir()
    process, log = spawn_compositor(
        run, renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
        # Not black: wlroots drops a black rect from the render list whether or not it is occluded.
        config_content=f'[compositor]\nxwayland = false\nwallpaper = "{tmp / "wallpaper.png"}"\n'
                       '[desktop]\nenabled = false\n[animations]\nenabled = false\n',
        env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_THEME": str(run / "rediwm-config.toml")})
    client = None
    try:
        with IPCClient(run, timeout=15) as ipc:
            ipc.wait_for("wallpaper_presented", timeout_ms=10000)
            display = wait_for(lambda: next((p.name for p in run.glob("wayland-*")
                                             if not p.name.endswith(".lock")), None), "display unavailable")
            env = dict(os.environ, XDG_RUNTIME_DIR=str(run), WAYLAND_DISPLAY=display, REDIWM_TEST_DECORATION="server",
                       REDIWM_TEST_PERF="1", REDIWM_TEST_PERF_DAMAGE="1", REDIWM_TEST_NO_CHILD="1",
                       REDIWM_TEST_HIDE_CURSOR="1", **client_env)
            client = subprocess.Popen([str(tmp / "client")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            win = wait_for(lambda: next(iter(ipc.get_windows()), None), "window unavailable")
            ipc.fullscreen(win["id"])
            wait_for(lambda: (lambda d: d["fullscreen"] and d["buffer_width"] == d["client_box"]["width"] == 1280)(
                ipc.get_window_debug(win["id"])), "fullscreen at output size")
            ipc.move_cursor(640, 300)
            time.sleep(1.0)
            ipc.wait_for_frame()
    finally:
        if client is not None and client.poll() is None:
            client.terminate()
            client.wait(timeout=3)
        stop_process(process)
        log.close()
    return (run / "compositor.log").read_text()


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-scanout-test-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        Image.new("RGB", (64, 64), (200, 90, 40)).save(tmp / "wallpaper.png")
        cases = (
            ("xrgb", {"REDIWM_TEST_OPAQUE": "1"}, True, "an XRGB buffer covers the output"),
            ("argb-region", {"REDIWM_TEST_OPAQUE_REGION": "1"}, True, "an ARGB buffer with an opaque region covers it"),
            ("argb", {}, False, "a translucent ARGB buffer leaves the wallpaper visible"),
        )
        for label, client_env, scanned, description in cases:
            log = fullscreen_log(tmp, label, client_env)
            assert scanning_out(log) == scanned, (label, description, [l for l in log.splitlines() if "scan-out" in l])
            print(f"PASS: {description}: {'scanned out' if scanned else 'composited'}")


if __name__ == "__main__":
    run()
