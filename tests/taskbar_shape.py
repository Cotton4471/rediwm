#!/usr/bin/env python3
"""Floating taskbar: gap from the edge, length and corner radius from Appearance,
the theme file and the strip a maximized window leaves."""
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib

from PIL import Image
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver

BAR = 44


def expected_box(output, gap, length, top=False, alignment="center"):
    width = max(min(420, output["w"]), min(output["w"], round(output["w"] * length / 100)))
    x = {"left": 0, "center": (output["w"] - width) // 2, "right": output["w"] - width}[alignment]
    return {"x": x, "y": gap if top else output["h"] - BAR - gap,
            "width": width, "height": BAR}


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-taskbar-shape-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        config_path = tmp / "rediwm-config.toml"
        config = ('[compositor]\nxwayland = false\nfocus_zoom = "keep"\n[desktop]\nenabled = false\n'
                  '[animations]\nenabled = false\n[theme]\nshadow = "#00000000"\n')
        env_extra = {"DBUS_SESSION_BUS_ADDRESS": "", "XDG_DATA_HOME": str(tmp / "data"), "REDIWM_NO_GLASS": "1"}
        process, log = spawn_compositor(tmp, config_content=config, env_extra=env_extra)
        client = None
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)
                info = ipc.get_outputs()[0]
                output = {"w": info["logical_width"], "h": info["logical_height"]}

                def bar_box():
                    return ipc.get_shell_state()["taskbars"][0]["box"]

                def shot(name):
                    ipc.close_panel("control_center")
                    ipc.wait_for_frame()
                    path = tmp / f"{name}.png"
                    path.unlink(missing_ok=True)
                    ipc.screenshot(str(path))
                    return Image.open(path).convert("RGB")

                # The default is the original bar: flush, full width, square.
                assert bar_box() == expected_box(output, 0, 100), bar_box()

                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                                                 if not p.name.endswith(".lock")), None), "display")
                with (tmp / "client.log").open("w") as client_log:
                    client = subprocess.Popen(
                        [str(tmp / "client"), "--app-id", "shape", "--title", "Shape"],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 REDIWM_TEST_DECORATION="server", REDIWM_TEST_RESIZE="1"),
                        stdout=client_log, stderr=client_log)
                win = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "shape"), None), "client map")
                win_id = win["id"]
                ipc.maximize(win_id)
                wait_for(lambda: next(w for w in ipc.get_windows() if w["id"] == win_id).get("is_maximized") is True, "maximize")
                ipc.wait_for("window_geometry_settled", window_id=win_id)
                full = ipc.get_window_debug(win_id)["chrome_box"]
                assert full["y"] + full["height"] == output["h"] - BAR, full

                def slider(name, fraction):
                    widget = ui.scroll_into_view(name)
                    box = widget["global_box"]
                    ipc.click_at(round(box["x"] + min(box["width"] - 1, box["width"] * fraction)),
                                 round(box["y"] + box["height"] / 2))
                    ipc.wait_for_panel_settled("control_center")
                    return tomllib.loads(config_path.read_text())["theme"][name]

                ipc.action("open_appearance")
                ipc.wait_for_panel_settled("control_center")
                gap = slider("taskbar_edge_gap", .25)
                length = slider("taskbar_length", .5)
                radius = slider("taskbar_radius", .5)
                assert (gap, radius) == (12, 21) and 60 <= length <= 70, (gap, length, radius)
                expected = expected_box(output, gap, length)
                wait_for(lambda: bar_box() == expected, f"bar did not float: {bar_box()} != {expected}")

                # Inline choices move the whole bar and survive a page rebuild.
                assert ui.find("taskbar_alignment")["selected_index"] == 1
                for alignment, index in (("left", 0), ("right", 2), ("center", 1)):
                    widget = ui.scroll_into_view("taskbar_alignment")
                    box = widget["global_box"]
                    ipc.click_at(round(box["x"] + box["width"] * (index + .5) / 3),
                                 round(box["y"] + box["height"] / 2))
                    ipc.wait_for_panel_settled("control_center")
                    wait_for(lambda: bar_box() == expected_box(output, gap, length, alignment=alignment),
                             f"taskbar alignment {alignment}")
                    assert tomllib.loads(config_path.read_text())["compositor"]["taskbar_alignment"] == alignment
                    ipc.close_panel("control_center")
                    ipc.action("open_appearance")
                    ipc.wait_for_panel_settled("control_center")
                    assert ui.find("taskbar_alignment")["selected_index"] == index

                # A maximized window gives up the gap along with the bar.
                ipc.wait_for("window_geometry_settled", window_id=win_id)
                floating = ipc.get_window_debug(win_id)["chrome_box"]
                assert floating["y"] == full["y"] and floating["height"] == full["height"] - gap, (full, floating)

                # Rounded ends: the corner shows what is behind the bar, the body keeps its fill.
                pill = shot("pill")
                left, top = expected["x"], expected["y"]
                body = pill.getpixel((left + 150, top + 6))
                assert all(abs(a - b) <= 8 for a, b in zip(body, (24, 28, 34))), body

                def apart(first, second):
                    return sum(abs(a - b) for a, b in zip(pill.getpixel(first), pill.getpixel(second)))

                assert apart((left, top), (left + 150, top + 6)) > 10, "corner of the bar is not cut away"
                assert apart((left - 8, top + BAR // 2), (left + 150, top + 6)) > 10, "bar spills past its length"
                assert apart((left + 150, top + BAR + 4), (left + 150, top + 6)) > 10, "bar fills its gap"

                # The same geometry from the theme file, on the other edge.
                config_path.write_text(config_path.read_text().replace(
                    "[compositor]", '[compositor]\ntaskbar_position = "top"', 1))
                saved = config_path.read_text()
                for key in ("taskbar_edge_gap", "taskbar_length", "taskbar_radius"):
                    saved = "\n".join(line for line in saved.splitlines() if not line.startswith(key + " "))
                config_path.write_text(saved + "\ntaskbar_edge_gap = 20\ntaskbar_length = 50\ntaskbar_radius = 10\n")
                ipc.reload_config()
                expected = expected_box(output, 20, 50, top=True)
                wait_for(lambda: bar_box() == expected, f"theme geometry on top: {bar_box()} != {expected}")
                wait_for(lambda: (lambda b: b["y"] == BAR + 20 and b["y"] + b["height"] == output["h"])(
                    ipc.get_window_debug(win_id)["chrome_box"]), f"maximized window under the top bar: {ipc.get_window_debug(win_id)['chrome_box']}")

                for alignment in ("left", "right", "center"):
                    current = tomllib.loads(config_path.read_text())["compositor"]["taskbar_alignment"]
                    config_path.write_text(config_path.read_text().replace(
                        f'taskbar_alignment = "{current}"', f'taskbar_alignment = "{alignment}"'))
                    ipc.reload_config()
                    wait_for(lambda: bar_box() == expected_box(output, 20, 50, top=True, alignment=alignment),
                             f"reloaded top taskbar alignment {alignment}")

                # Too short a bar keeps room for its items; a bad value is refused.
                config_path.write_text(config_path.read_text().replace("taskbar_length = 50", "taskbar_length = 20"))
                ipc.reload_config()
                wait_for(lambda: bar_box()["width"] == 420, f"bar kept narrower than its items: {bar_box()}")
                config_path.write_text(config_path.read_text().replace("taskbar_length = 20", "taskbar_length = 5"))
                ipc.reload_config()
                assert bar_box()["width"] == 420
            stop_process(process)
            assert process.returncode == 0, (tmp / "compositor.log").read_text()
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            if client is not None:
                stop_process(client)
            if process.poll() is None:
                stop_process(process)
            log.close()
        print("PASS: floating taskbar gap, length, radius, strip and edges")


def fractional_edges():
    """Fractional scale floors the logical size (720 rows at 1.37 are 719.7): the
    flush bar still reaches the last device row and column of the panel."""
    with tempfile.TemporaryDirectory(prefix="rediwm-taskbar-edges-") as directory:
        tmp = Path(directory)
        for scale, position in (("1.37", "bottom"), ("1.37", "top"), ("1.33", "bottom")):
            config = (f'[compositor]\nxwayland = false\ntaskbar_position = "{position}"\n[desktop]\nenabled = false\n'
                      '[animations]\nenabled = false\n')
            process, log = spawn_compositor(tmp, scale=scale, config_content=config,
                                            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "XDG_DATA_HOME": str(tmp / "data")})
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    info = ipc.get_outputs()[0]
                    path = tmp / "edges.png"
                    path.unlink(missing_ok=True)
                    ipc.move_cursor(5, 5)
                    ipc.wait_for_frame()
                    ipc.screenshot(str(path))
                    image = Image.open(path).convert("RGB")
                    assert image.size[0] > info["logical_width"] * float(scale) - 1, (image.size, info)
                    middle = BAR // 2 if position == "top" else image.height - BAR // 2
                    points = [(image.width - 1, middle)]
                    if position == "bottom":
                        points.append((image.width // 2, image.height - 1))
                    for point in points:
                        assert image.getpixel(point) != (0, 0, 0), (scale, position, "bar stops short of the panel", point, image.size)
            finally:
                stop_process(process)
                log.close()
    print("PASS: flush taskbar reaches the panel edge at fractional scales")


if __name__ == "__main__":
    os.environ.pop("REDIWM_THEME", None)
    run()
    fractional_edges()
