#!/usr/bin/env python3
"""Calculator keyboard/keypad arithmetic and layout in a private compositor."""
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageChops
from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from xwayland_support import wait_for


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-calculator-") as directory:
        tmp = Path(directory)
        env = dict(HOME=directory, XDG_CONFIG_HOME=str(tmp / "config"),
                   XDG_DATA_HOME=str(tmp / "data"), XDG_CACHE_HOME=str(tmp / "cache"),
                   XDG_STATE_HOME=str(tmp / "state"), DBUS_SESSION_BUS_ADDRESS="",
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus",
                   WLR_RENDERER_ALLOW_SOFTWARE="1", LANG="C", LC_ALL="C")
        compositor, log = spawn_compositor(
            tmp, scale=str(scale), env_extra=env,
            config_content='[compositor]\nxwayland = false\nfocus_zoom = "keep"\n[animations]\nenabled = false\n',
            binary=os.environ.get("REDIWM_TEST_BINARY"))
        app = None
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                app_env = dict(os.environ, **env, XDG_RUNTIME_DIR=directory,
                               WAYLAND_DISPLAY=display, REDIWM_CONFIG=str(tmp / "rediwm-config.toml"))
                app_env.pop("REDIWM_THEME", None)
                with (tmp / "calculator.log").open("w") as app_log:
                    app = subprocess.Popen([os.environ.get("REDIWM_TEST_CALCULATOR",
                                            str(ROOT / "zig-out/bin/rediwm-calculator"))],
                                           env=app_env, stdout=app_log, stderr=app_log)
                ipc.wait_for("window_mapped", app_id="rediwm-calculator")
                win = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-calculator")
                ipc.focus_window(win["id"])
                ipc.wait_for("window_geometry_settled", window_id=win["id"])
                ipc.move_cursor(0, 0)

                def box():
                    return ipc.get_window_debug(win["id"])["client_box"]

                def capture(region=None):
                    ipc.wait_for_frame()
                    path = tmp / "screen.png"
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        b = box()
                        factor = image.width / ipc.get_outputs()[0]["logical_width"]
                        x1, y1, x2, y2 = region or (0, 0, b["width"], b["height"])
                        return image.convert("RGB").crop(tuple(round(v * factor) for v in
                            (b["x"] + x1, b["y"] + y1, b["x"] + x2, b["y"] + y2)))

                def readout():
                    return capture((16, 36, box()["width"] - 16, 96))

                def same(left, right):
                    return ImageChops.difference(left, right).getbbox() is None

                zero = readout()

                def clear():
                    ipc.key_down_up(1)  # Escape
                    wait_for(lambda: same(zero, readout()), "clear did not reset the readout")

                # Compare rendered results against directly entered reference
                # values: no OCR, test-only app API or font-specific goldens.
                cases = [
                    ("100+5%", "105"), ("200-10%", "180"),
                    ("200*10%", "20"), ("200/10%", "2000"),
                    ("200+10%+5%", "231"), ("200+(5+5)%", "220"),
                    ("100+200*5%", "110"), ("2+3*4", "14"),
                    ("(2+3)*4", "20"), ("0.1+0.2", "0.3"),
                ]
                references = {"0": zero}
                for expected in dict.fromkeys([value for _, value in cases] + ["5", "8", "11", "110.25", "115.7625"]):
                    clear()
                    ipc.type_text(expected)
                    wait_for(lambda: not same(zero, readout()), "numeric entry was not painted")
                    references[expected] = readout()
                for expression, expected in cases:
                    clear()
                    ipc.type_text(expression)
                    ipc.key_down_up(28)  # Enter
                    wait_for(lambda: same(references[expected], readout()),
                             f"{expression} did not display {expected}")

                clear()
                ipc.type_text("2+3=")
                wait_for(lambda: same(references["5"], readout()), "equals key failed")
                ipc.type_text("=")
                wait_for(lambda: same(references["8"], readout()), "repeated equals key failed")
                ipc.key_down_up(28)
                wait_for(lambda: same(references["11"], readout()), "repeated Enter failed")

                def click_button(row, column):
                    b = box()
                    cell_w = (b["width"] - 56) / 4
                    cell_h = (b["height"] - 112 - 56) / 6
                    ipc.click_at(round(b["x"] + 16 + column * (cell_w + 8) + cell_w / 2),
                                 round(b["y"] + 112 + row * (cell_h + 8) + cell_h / 2))

                clear()
                for row, column in [(4, 0), (5, 0), (5, 0), (3, 3), (3, 1), (1, 1), (4, 3)]:
                    click_button(row, column)  # 100+5%=
                ipc.move_cursor(0, 0)
                wait_for(lambda: same(references["105"], readout()), "keypad percentage failed")
                for expected in ("110.25", "115.7625"):
                    click_button(4, 3)
                    ipc.move_cursor(0, 0)
                    wait_for(lambda: same(references[expected], readout()), "keypad repeated equals failed")

                clear()
                ipc.type_text("200+10%")
                ipc.key_down_up(67)  # F9 / ±
                ipc.key_down_up(28)
                wait_for(lambda: same(references["180"], readout()), "percentage sign toggle failed")

                clear()
                ipc.type_text("200/0%")
                ipc.key_down_up(28)
                wait_for(lambda: any(low != high for low, high in
                         capture((16, 8, box()["width"] - 16, 34)).getextrema()),
                         "division-by-zero notice was not painted")
                ipc.key_down_up(14)
                ipc.key_down_up(14)
                ipc.type_text("10%")
                ipc.key_down_up(28)
                wait_for(lambda: same(references["2000"], readout()), "error correction failed")

                # The removed shortcut line stays blank below the larger entry.
                strip = capture((16, 96, box()["width"] - 16, 110))
                assert all(low == high for low, high in strip.getextrema()), "shortcut line remains"
                destination = os.environ.get("REDIWM_TEST_CAPTURE")
                if destination:
                    capture().save(destination)
                ipc.close_window(win["id"])
                ipc.wait_for("window_closed", window_id=win["id"])
                assert app.wait(timeout=5) == 0
                print(f"Calculator: arithmetic, keyboard, keypad and layout passed at scale {scale}")
        finally:
            if app is not None and app.poll() is None:
                stop_process(app)
            stop_process(compositor)
            log.close()
            for path in (tmp / "compositor.log", tmp / "calculator.log"):
                if path.exists():
                    errors = path.read_text()
                    assert "panic" not in errors and "error(gpa)" not in errors, errors[-6000:]


if __name__ == "__main__":
    os.umask(0o077)
    run(float(os.environ.get("REDIWM_TEST_SCALE", "1")))
