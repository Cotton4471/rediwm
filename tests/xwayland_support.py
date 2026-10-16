"""Shared helpers for the Xwayland integration tests: compositor start, IPC and X11 clients."""
import json
import os
from pathlib import Path
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(check, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.03)
    raise AssertionError(message() if callable(message) else message)


def start_compositor(tmp, config_text, env_overrides=None):
    (tmp / "config.toml").write_text(config_text)
    env = dict(
        os.environ,
        XDG_RUNTIME_DIR=str(tmp),
        WLR_BACKENDS="headless",
        WLR_HEADLESS_OUTPUTS="1",
        WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
        REDIWM_SCALE="1",
        REDIWM_CONFIG=str(tmp / "config.toml"),
        REDIWM_IPC_AUTOMATION="1",
    )
    env.update(env_overrides or {})
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("REDIWM_SOCKET", None)
    # Host X11 must not leak into the compositor process: children inherit
    # through applyChildEnv, and the nested backend (if any) is Wayland.
    env.pop("DISPLAY", None)
    env.pop("XAUTHORITY", None)
    log = (tmp / "compositor.log").open("w")
    compositor = subprocess.Popen(
        [str(ROOT / "zig-out/bin/rediwm")],
        env=env,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    return compositor, log


def ipc_connect(tmp):
    path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC socket did not appear")
    sock = socket.socket(socket.AF_UNIX)
    sock.settimeout(10)
    sock.connect(str(path))
    return sock, sock.makefile("r")


def wayland_display_name(tmp):
    path = wait_for(
        lambda: next((p for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")), None),
        "Wayland socket did not appear",
    )
    return path.name


def request(sock, reader, value):
    sock.sendall((json.dumps(value) + "\n").encode())
    result = json.loads(reader.readline())
    assert "Ok" in result, result
    return result["Ok"]


def build_client(tmp):
    subprocess.run(
        ["cc", "-Wall", "-Wextra", str(ROOT / "tests/xwayland_client.c"), "-lxcb", "-o", str(tmp / "x11-client")],
        check=True,
    )


def start_x11_client(tmp, display, log_path, *args):
    client_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp))
    client_env.pop("WAYLAND_DISPLAY", None)
    with log_path.open("w") as clog:
        return subprocess.Popen(
            [str(tmp / "x11-client"), *args],
            env=client_env,
            stdin=subprocess.PIPE,
            stdout=clog,
            stderr=clog,
            text=True,
        )


def x11_pointer_window_name(display):
    """Read X11's actual input target, independently of the scene HitTest."""
    import ctypes as c
    xlib = c.CDLL("libX11.so.6")
    ptr, window, integer = c.c_void_p, c.c_ulong, c.c_int
    xlib.XOpenDisplay.argtypes = [c.c_char_p]
    xlib.XOpenDisplay.restype = ptr
    xlib.XDefaultRootWindow.argtypes = [ptr]
    xlib.XDefaultRootWindow.restype = window
    xlib.XQueryPointer.argtypes = [ptr, window, c.POINTER(window), c.POINTER(window),
                                  *[c.POINTER(integer)] * 4, c.POINTER(c.c_uint)]
    xlib.XFetchName.argtypes = [ptr, window, c.POINTER(c.c_char_p)]
    xlib.XFree.argtypes = [ptr]
    xlib.XCloseDisplay.argtypes = [ptr]
    connection = xlib.XOpenDisplay(display.encode())
    assert connection, display
    try:
        root, child = window(), window()
        rx, ry, wx, wy = integer(), integer(), integer(), integer()
        mask = c.c_uint()
        xlib.XQueryPointer(connection, xlib.XDefaultRootWindow(connection),
                           c.byref(root), c.byref(child), c.byref(rx), c.byref(ry),
                           c.byref(wx), c.byref(wy), c.byref(mask))
        if not child.value:
            return None
        name = c.c_char_p()
        xlib.XFetchName(connection, child, c.byref(name))
        try:
            return name.value.decode() if name.value else None
        finally:
            if name.value is not None:
                xlib.XFree(name)
    finally:
        xlib.XCloseDisplay(connection)
