#!/usr/bin/env python3
"""Capture an isolated language-review walk and report measured text overflow.

Build first. Output contains PNGs, widget trees and review.json. Authentication
and lock screens deliberately reject IPC screenshots and are listed for manual
review; this tool never changes authentication/capture policy.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from i18n import isolated_environment, overflow_issues
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver
from xwayland import wayland_display_name


PAGES = ("general", "input", "displays", "audio", "network", "appearance", "shortcuts",
         "desktop", "bluetooth", "region", "users", "printers", "services")


def walk(language, destination, scale, apps=True):
    destination.mkdir(parents=True, exist_ok=True)
    report = {"language": language, "scale": scale, "complete": False, "captures": [], "overflow": [],
              "manual_review": ["Lock screen and greeter (IPC is disabled while locked)",
                                "Authentication dialog (IPC screenshots are forbidden)",
                                "Wi-Fi, battery and hardware-dependent dialogs require private device fixtures"],
              "notes": ["Fuzzy catalog entries fall back to English. Review drafts before removing fuzzy flags."]}
    with tempfile.TemporaryDirectory(prefix="rediwm-i18n-review-") as directory:
        tmp = Path(directory)
        env = isolated_environment(tmp)
        bus = None
        if shutil.which("dbus-daemon") and shutil.which("busctl"):
            bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--nopidfile", "--print-address=1"],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().strip()
            if not env["DBUS_SESSION_BUS_ADDRESS"]:
                stop_process(bus)
                raise RuntimeError("private review session bus failed to start")
            env["REDIWM_FORCE_DBUS"] = "1"
        else:
            report["manual_review"].append("Notification popup: dbus-daemon/busctl unavailable")
        config = ('[compositor]\nxwayland = false\n[animations]\nenabled = false\n'
                  '[polkit]\nenable = false\n[region]\n'
                  f'language = {json.dumps(language)}\nformats = "C"\n')
        try:
            process, log = spawn_compositor(tmp, scale=scale, config_content=config, env_extra=env)
        except Exception:
            if bus:
                stop_process(bus)
            raise
        children = []
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.wait_for("catalog_published", timeout_ms=10000)
                ui = UIDriver(ipc)

                def capture(name, panel=None):
                    ipc.wait_for_frame()
                    image = destination / f"{name}.png"
                    image.unlink(missing_ok=True)
                    ipc.screenshot(str(image))
                    item = {"name": name, "image": image.name, "panel": panel}
                    if panel:
                        tree = ipc.get_widget_tree(panel)
                        (destination / f"{name}.json").write_text(json.dumps(tree, ensure_ascii=False, indent=2))
                        widgets = tree.get("widgets", [])
                        item["measured_labels"] = sum(w.get("text_width") is not None for w in widgets if w.get("label"))
                        if panel != "taskbar" and not item["measured_labels"]:
                            raise RuntimeError("widget text measurements unavailable; rebuild RediWM before review")
                        found = overflow_issues(widgets)
                        for issue in found:
                            issue["capture"] = name
                        report["overflow"].extend(found)
                        item["widgets"] = len(tree.get("widgets", []))
                        item["overflow_count"] = len(found)
                    else:
                        item["measurement"] = "Visual review; no compositor widget tree for this surface"
                    report["captures"].append(item)

                capture("desktop", "taskbar")
                for action, panel in (("open_start_menu", "start_menu"), ("open_launcher", "start_menu"),
                                      ("open_power_menu", "power_menu")):
                    try:
                        if action == "open_launcher":
                            ipc.key(125, True)
                            ipc.key_press("space")
                            ipc.key(125, False)
                        else:
                            ipc.action(action)
                        ui.wait_settled(panel)
                        capture(action.removeprefix("open_"), panel)
                    finally:
                        ipc.key_down_up(1)
                        ui.wait_absent(panel)

                # The calendar uses private LC_TIME; it has no retained widget tree.
                taskbar = ipc.get_shell_state()["taskbars"][0]
                clock = next(i["box"] for i in taskbar["right_items"] if i["name"] == "clock")
                ipc.click_at(clock["x"] + clock["width"] // 2, clock["y"] + clock["height"] // 2)
                capture("calendar")
                ipc.key_down_up(1)
                ipc.key(29, True)
                ipc.key(42, True)
                ipc.key_press("s")
                ipc.key(42, False)
                ipc.key(29, False)
                capture("screenshot-selector")
                ipc.key_down_up(1)

                if bus:
                    # Empty sender/summary exercise the compositor's fallback
                    # title; the body is fixture content supplied by a client.
                    command = ["busctl", "--address=" + env["DBUS_SESSION_BUS_ADDRESS"], "--timeout=5", "call",
                               "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                               "org.freedesktop.Notifications", "Notify", "susssasa{sv}i",
                               "", "0", "", "", "Language review", "0", "0", "0"]
                    subprocess.run(command, check=True, capture_output=True, text=True)
                    ipc.wait_for({"notification_count": {"count": 1}}, timeout_ms=5000)
                    capture("notification")
                    ipc.action("clear_notifications")

                ipc.action("open_control_center")
                ui.wait_settled("control_center")
                for page in PAGES:
                    if not any(widget.get("name") == page for widget in ui.widgets("control_center")):
                        report["manual_review"].append(f"Settings/{page}: unavailable in this isolated session")
                        continue
                    ui.click(ui.scroll_into_view(page, panel="control_center"), panel="control_center")
                    ui.wait_settled("control_center")
                    capture(f"settings-{page}-0", "control_center")
                    # Walk every vertical viewport, including intermediate pages.
                    for index in range(1, 16):
                        widgets = ui.widgets("control_center")
                        containers = [w for w in widgets if w["role"] == "scroll_container" and w.get("name") == "content_scroll"]
                        if not containers:
                            containers = [w for w in widgets if w["role"] == "scroll_container"]
                        if not containers:
                            break
                        viewport = max(containers, key=lambda w: w["box"]["width"])
                        before = [(w.get("path"), w["box"]["y"]) for w in widgets if w.get("label")]
                        box = viewport["global_box"]
                        ipc.move_cursor(box["x"] + box["width"] - 8, box["y"] + box["height"] // 2)
                        ipc.scroll(0, -360)
                        ui.wait_settled("control_center")
                        after = [(w.get("path"), w["box"]["y"]) for w in ui.widgets("control_center") if w.get("label")]
                        if before == after:
                            break
                        capture(f"settings-{page}-{index}", "control_center")
                window = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-settings")
                ipc.close_window(window["id"])
                ui.wait_absent("control_center")

                if apps:
                    from PIL import Image
                    home = tmp / "home"
                    (home / "Notes.txt").write_text("RediWM language review\n\nRésumé — Терминал — Cámara\n", encoding="utf-8")
                    image = Image.new("RGB", (480, 320), (72, 108, 138))
                    image.save(home / "Picture.png")
                    image.save(home / "Document.pdf")
                    app_env = dict(os.environ, **env, XDG_RUNTIME_DIR=directory,
                                   WAYLAND_DISPLAY=wayland_display_name(tmp), REDIWM_CONFIG=str(tmp / "rediwm-config.toml"),
                                   LANG="C.UTF-8", LC_MESSAGES=language, LANGUAGE=language)
                    for key in ("LC_ALL", "DISPLAY", "REDIWM_SOCKET"):
                        app_env.pop(key, None)
                    launches = (("files", "rediwm-files", [str(home)]),
                                ("editor", "rediwm-editor", [str(home / "Notes.txt")]),
                                ("images", "rediwm-images", [str(home / "Picture.png")]),
                                ("pdf", "rediwm-pdf", [str(home / "Document.pdf")]),
                                ("calculator", "rediwm-calculator", []),
                                ("system-monitor", "rediwm-monitor", []),
                                ("share-picker", "rediwm-share-picker", []))
                    for name, app_id, arguments in launches:
                        executable = ROOT / "zig-out/bin" / app_id
                        if not executable.exists():
                            report["manual_review"].append(f"{name}: binary unavailable")
                            continue
                        with (destination / f"{name}.log").open("w") as output:
                            child = subprocess.Popen([str(executable), *arguments], env=app_env, stdout=output, stderr=output,
                                                     stdin=subprocess.PIPE if name == "share-picker" else subprocess.DEVNULL)
                        children.append(child)
                        if name == "share-picker":
                            child.stdin.write(b"Monitor: Fixture display\nWindow: Language review\n")
                            child.stdin.close()
                        ipc.wait_for({"window_mapped": {"app_id": app_id}}, timeout_ms=10000)
                        window = next(w for w in ipc.get_windows() if w["app_id"] == app_id)
                        ipc.wait_for("window_geometry_settled", window_id=window["id"])
                        ipc.focus_window(window["id"])
                        capture(name)
                        if name == "files":
                            def client_key(key):
                                ipc.key_press(key)
                                # IPC's output barrier cannot wait for a future
                                # client commit. Allow this client to process
                                # the key and publish its dialog before capture.
                                time.sleep(.2)
                                ipc.wait_for_frame()

                            client_key("Home")
                            client_key("F2")
                            capture("files-rename")
                            client_key("Escape")
                            client_key("Delete")
                            capture("files-delete")
                            client_key("Escape")
                        ipc.close_window(window["id"])
                        ipc.wait_for("window_closed", window_id=window["id"])
                report["notes"].append("Client app captures require visual overflow review; only shell widget trees expose measured text.")
                report["complete"] = True
        except Exception as error:
            report["error"] = f"{type(error).__name__}: {error}"
            raise
        finally:
            for child in children:
                stop_process(child)
            stop_process(process)
            if bus:
                stop_process(bus)
            log.close()
            (destination / "compositor.log").write_text(Path(log.name).read_text())
            (destination / "review.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("language", help="Catalog tag such as de, es, pt_BR, ru or qps")
    parser.add_argument("--scale", default="1")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--shell-only", action="store_true", help="Skip client-app captures")
    parser.add_argument("--allow-overflow", action="store_true", help="Write findings without failing the review walk")
    args = parser.parse_args()
    destination = (args.out or Path("/tmp") / f"rediwm-i18n-{args.language}-{args.scale}").resolve()
    report = walk(args.language, destination, args.scale, not args.shell_only)
    print(f"{len(report['captures'])} screenshots; {len(report['overflow'])} overflow findings; {destination / 'review.json'}")
    return 1 if report["overflow"] and not args.allow_overflow else 0


if __name__ == "__main__":
    raise SystemExit(main())
