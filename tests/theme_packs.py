#!/usr/bin/env python3
"""Theme packs: isolated installs, live assets, layering and hostile archives."""
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import tempfile
import time
import tomllib
import zipfile
import zlib
from PIL import Image
from ipc_client import IPCClient, IPCError, spawn_compositor, stop_process
from desktop_zoom import wait_for
from ui_driver import UIDriver

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "zig-out/bin/rediwm-theme"
FIXTURE = ROOT / "tests/fixtures/theme-pack"
PINK = (244, 44, 160)
HOME_COLOR = (32, 211, 231)
TRASH_COLOR = (180, 91, 237)


def helper(env, *args, ok=True):
    result = subprocess.run([str(HELPER), *map(str, args)], env=env, capture_output=True, text=True, timeout=35)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return result


def hostile_archives(tmp, env):
    manifest = (FIXTURE / "theme.toml").read_bytes()
    cases = {
        "traversal": [("../outside", b"x", None)],
        "absolute": [("/tmp/escape", b"x", None)],
        "symlink": [("logo.svg", b"/etc/passwd", stat.S_IFLNK | 0o777)],
        "device": [("device", b"", stat.S_IFCHR | 0o600)],
        "script": [("run.sh", b"echo hostile", None)],
        "malformed": [("theme.toml", b"[theme\naccent nope", None)],
        "bomb": [("wallpapers/bomb.png", b"\0" * (40 * 1024 * 1024 + 1), None)],
        "count": [(f"icons/{i}.svg", b"", None) for i in range(4001)],
        "glyph-size": [("glyphs/wifi.svg", b"x" * (64 * 1024 + 1), None)],
        "format": [("theme.toml", b"[meta]\nformat = 2\n", None)],
        "cursor-alias": [("cursors/cursors/default", b"../outside", stat.S_IFLNK | 0o777)],
    }
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    giant = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 40000, 40000, 8, 2, 0, 0, 0)) + chunk(b"IEND", b"")
    chunk_data = b"\0" * (34 * 1024 * 1024)
    cases["total-limit"] = [(f"wallpapers/{i}.png", chunk_data, None) for i in range(4)]
    slow = b'<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><defs><filter id="f">' + b'<feGaussianBlur stdDeviation="5"/>' * 1000 + b'</filter></defs><rect width="256" height="256" filter="url(#f)"/></svg>'
    cases["slow-glyph"] = [("glyphs/wifi.svg", slow, None)]
    cases["huge-image"] = [("wallpapers/test.png", giant, None)]
    for name, entries in cases.items():
        archive = tmp / f"bad-{name}.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as out:
            if name not in ("malformed", "format"):
                out.writestr("theme.toml", manifest)
            for path, data, mode in entries:
                info = zipfile.ZipInfo(path)
                info.compress_type = zipfile.ZIP_DEFLATED
                if mode is not None:
                    info.create_system = 3
                    info.external_attr = mode << 16
                out.writestr(info, data)
        result = helper(env, "install", archive, ok=False)
        assert result.stderr.strip(), name
        themes = Path(env["XDG_DATA_HOME"]) / "rediwm/themes"
        assert not any(themes.iterdir()), (name, list(themes.iterdir()))
    source = tmp / "symlink-source"
    shutil.copytree(FIXTURE, source)
    (source / "icons/folder.svg").unlink()
    (source / "icons/folder.svg").symlink_to("/etc/passwd")
    helper(env, "install", source, ok=False)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-theme-packs-") as directory:
        tmp = Path(directory)
        env = dict(os.environ, XDG_DATA_HOME=str(tmp / "data"), XDG_STATE_HOME=str(tmp / "state"),
                   XDG_CONFIG_HOME=str(tmp / "config"), XDG_CACHE_HOME=str(tmp / "cache"),
                   DBUS_SESSION_BUS_ADDRESS="", DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent",
                   REDIWM_FILES_DEVICES="0", REDIWM_DESKTOP_BUILTINS="1", REDIWM_DESKTOP_DIR=str(tmp / "desktop"))
        env.pop("REDIWM_THEME", None)
        env.pop("REDIWM_CONFIG", None)
        env.pop("REDIWM_SOCKET", None)
        hostile_archives(tmp, env)
        pack = tmp / "source"
        shutil.copytree(FIXTURE, pack)
        for name, color in (("user-home", HOME_COLOR), ("user-trash", TRASH_COLOR)):
            fill = "#%02x%02x%02x" % color
            (pack / f"icons/{name}.svg").write_text((pack / "icons/folder.svg").read_text().replace("#f42ca0", fill))
        # A real built cursor with the sole allowed alias form.
        (pack / "cursors/cursors").mkdir(parents=True)
        shutil.copyfile(ROOT / "zig-out/share/icons/phinger-cursors-dark/cursors/default", pack / "cursors/cursors/left_ptr")
        (pack / "cursors/cursors/default").symlink_to("left_ptr")
        (pack / "cursors/index.theme").write_text("[Icon Theme]\nName=Test pack cursors\n")
        with (pack / "theme.toml").open("a") as out:
            out.write('cursor_theme = "pack"\n')
        archive = tmp / "fixture.rediwm-theme"
        helper(env, "validate", pack)
        helper(env, "pack", pack, archive)
        (tmp / "desktop/Folder").mkdir(parents=True)
        (tmp / "files/Folder").mkdir(parents=True)
        proc, log = spawn_compositor(tmp, config_content='[compositor]\nxwayland = false\n[desktop]\nenabled = true\n[input]\npointer_speed = 0.4\n', env_extra={k: v for k, v in env.items() if k.startswith(("XDG_", "REDIWM_", "DBUS_")) and k != "XDG_RUNTIME_DIR"})
        files = None
        try:
            with IPCClient(tmp, timeout=30) as ipc:
                before = ipc.query("theme.list")
                assert {p["id"] for p in before["packs"]} >= {"rediwm-dark", "rediwm-light", "redi-blue", "redi-mocha", "gold"}
                mocha = next(p for p in before["packs"] if p["id"] == "redi-mocha")
                assert mocha["name"] == "Redi-Mocha" and not mocha["user_installed"], mocha
                ipc.action("theme.apply", {"id": "redi-mocha"})
                look = ipc.action("get_theme")
                assert look["dark_mode"]
                manifest = tomllib.loads((ROOT / "assets/themes/redi-mocha.toml").read_text())
                for key in ("app_bg", "window_fg", "shell_accent", "desktop_selection_border", "switcher_selected_border"):
                    expected = tuple(int(manifest["theme"][key][i:i+2], 16) / 255 for i in (1, 3, 5)) + (1,)
                    assert all(abs(a - b) < .001 for a, b in zip(look["tokens"][key], expected)), key
                wait_for(lambda: (ipc.query("get_wallpaper")["displayed_path"] or "").endswith("/wallpaper-mocha.png"), "Mocha wallpaper was not presented")
                assert tomllib.loads((tmp / "rediwm-config.toml").read_text())["theme"] == {"base": "redi-mocha"}
                # Gold is a complete installed pack, including layout defaults.
                ipc.action("theme.apply", {"id": "gold"})
                gold = ipc.action("get_theme")
                assert gold["tokens"]["notification_blur"] is True
                assert gold["tokens"]["app_fg"] != gold["tokens"]["window_fg"]
                assert gold["tokens"]["app_sidebar"][3] == 1
                for key in ("app_item_hover", "app_sidebar_hover", "app_surface_hover",
                            "surface_hover", "start_menu_selected_bg"):
                    assert abs(gold["tokens"][key][3] - 0.96) < .001, key
                wait_for(lambda: UIDriver(ipc).widgets("dock"), "Gold dock did not appear")
                assert ipc.get_shell_state()["taskbars"][0]["box"]["y"] == 0
                assert UIDriver(ipc).widgets("dock")[0]["global_box"]["height"] == 76
                wait_for(lambda: (ipc.query("get_wallpaper")["displayed_path"] or "").endswith("/wallpaper-gold.png"), "Gold wallpaper was not presented")
                cfg = tomllib.loads((tmp / "rediwm-config.toml").read_text())
                assert not {"dock_enabled", "dock_position", "dock_height", "dock_hover_zoom", "taskbar_position"} & cfg["compositor"].keys()
                if shutil.which("foot"):
                    helper(dict(env, REDIWM_CONFIG=str(tmp / "rediwm-config.toml")), "terminal", "foot", "--check-config", "--config=/dev/null")
                config_path = tmp / "rediwm-config.toml"
                config_path.write_text(config_path.read_text().replace("[compositor]", '[compositor]\ndock_enabled = false\ndock_position = "left"\ntaskbar_position = "bottom"\ndock_height = 48\ndock_hover_zoom = 1.5', 1))
                wait_for(lambda: not UIDriver(ipc).widgets("dock"), "explicit dock override did not win")
                assert ipc.get_shell_state()["taskbars"][0]["box"]["y"] > 0
                ipc.action("theme.apply", {"id": "gold"})
                wait_for(lambda: UIDriver(ipc).widgets("dock"), "reset did not restore Gold layout")
                assert not {"dock_enabled", "dock_position", "dock_height", "dock_hover_zoom", "taskbar_position"} & tomllib.loads(config_path.read_text())["compositor"].keys()
                # Every other bundled theme restores the standard bar and no dock.
                for theme_id in ("rediwm-dark", "rediwm-light", "redi-blue", "redi-mocha"):
                    ipc.action("theme.apply", {"id": "gold"})
                    wait_for(lambda: UIDriver(ipc).widgets("dock"), "Gold dock did not appear")
                    ipc.action("theme.apply", {"id": theme_id})
                    wait_for(lambda: not UIDriver(ipc).widgets("dock"), f"Gold dock layout leaked into {theme_id}")
                    assert ipc.action("get_theme")["tokens"]["taskbar_size"] == 44, theme_id
                    bar = ipc.get_shell_state()["taskbars"][0]["box"]
                    output = ipc.get_outputs()[0]
                    assert bar["height"] == 44, (theme_id, bar)
                    assert bar["y"] == output["y"] + output["logical_height"] - 44, (theme_id, bar)
                installed = ipc.action("theme.install", {"path": str(archive)})
                assert installed["id"] == "test-pack", installed
                try:
                    ipc.action("theme.install", {"path": str(archive)})
                    raise AssertionError("duplicate install accepted without replacement")
                except IPCError as err:
                    assert "AlreadyInstalled" in str(err)
                ipc.action("theme.apply", {"id": "test-pack"})
                assert ipc.query("theme.list")["active"] == "test-pack"
                cfg = tomllib.loads((tmp / "rediwm-config.toml").read_text())
                assert cfg["theme"] == {"base": "test-pack"}, cfg["theme"]
                assert cfg["compositor"]["wallpaper"] == ""
                assert cfg["compositor"]["dark_mode"]
                assert cfg["input"]["pointer_speed"] == .4
                assert cfg["input"]["cursor_theme"] == "rediwm-test-pack-cursors"
                cursor_link = tmp / "data/icons/rediwm-test-pack-cursors"
                assert cursor_link.is_symlink()
                wait_for(lambda: ipc.query("get_wallpaper")["displayed_path"] == str(tmp / "data/rediwm/themes/test-pack/wallpapers/test.png"), "pack wallpaper was not presented")
                ipc.wait_for_frame()
                shot = tmp / "pack.png"
                ipc.screenshot(str(shot))
                colors = dict((color, count) for count, color in Image.open(shot).convert("RGB").getcolors(1280 * 720 * 4))
                assert colors.get((18, 90, 130), 0) > 5000, "pack wallpaper pixels missing"
                def desktop_has_icons():
                    shot.unlink(missing_ok=True)
                    ipc.screenshot(str(shot))
                    with Image.open(shot) as image:
                        colors = dict((color, count) for count, color in image.convert("RGB").getcolors(image.width * image.height))
                    return all(colors.get(color, 0) > 100 for color in (PINK, HOME_COLOR, TRASH_COLOR))
                wait_for(desktop_has_icons, "desktop folder, Home or Trash did not use pack icons")
                assert colors.get((33, 219, 175), 0) > 10, "pack start logo pixels missing"
                # App clients resolve base through their normal settings worker.
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                client_env = dict(env, WAYLAND_DISPLAY=display, XDG_RUNTIME_DIR=str(tmp), REDIWM_CONFIG=str(tmp / "rediwm-config.toml"))
                files = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-files"), str(tmp / "files")], env=client_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                wait_for(lambda: any(w["app_id"] == "rediwm-files" for w in ipc.get_windows()), "Files did not map")
                win = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-files")
                ipc.action("move_window_to", {"id": win["id"], "x": 180, "y": 80})
                ipc.wait_for("window_geometry_settled", window_id=win["id"])
                files_shot = tmp / "files-pack.png"
                def files_has_folder():
                    files_shot.unlink(missing_ok=True)
                    ipc.screenshot(str(files_shot))
                    box = ipc.get_window_debug(win["id"])["client_box"]
                    pixels = Image.open(files_shot).convert("RGB").crop((box["x"], box["y"], box["x"] + box["width"], box["y"] + box["height"]))
                    return any(color == PINK for color in pixels.getdata())
                wait_for(files_has_folder, "Files did not use pack folder icon")
                def files_has_sidebar_icons():
                    files_shot.unlink(missing_ok=True)
                    ipc.screenshot(str(files_shot))
                    box = ipc.get_window_debug(win["id"])["client_box"]
                    with Image.open(files_shot) as image:
                        sidebar = image.convert("RGB").crop((box["x"], box["y"], box["x"] + 50, box["y"] + box["height"]))
                        colors = dict((color, count) for count, color in sidebar.getcolors(sidebar.width * sidebar.height))
                    return all(colors.get(color, 0) > 50 for color in (PINK, HOME_COLOR, TRASH_COLOR))
                wait_for(files_has_sidebar_icons, "Files sidebar did not use pack folder, Home and Trash icons")
                ipc.action("theme.apply", {"id": "gold"})
                def files_has_gold_palette():
                    files_shot.unlink(missing_ok=True)
                    ipc.screenshot(str(files_shot))
                    with Image.open(files_shot) as image:
                        colors = dict((color, count) for count, color in image.convert("RGB").getcolors(image.width * image.height))
                    return (colors.get((238, 230, 219), 0) > 5000
                            and colors.get((68, 61, 58), 0) > 5000
                            and colors.get((57, 51, 46), 0) > 100
                            and colors.get((241, 231, 219), 0) > 100)
                wait_for(files_has_gold_palette, "Gold app, sidebar and chrome foregrounds were not separated")
                ipc.action("theme.apply", {"id": "test-pack"})
                wait_for(files_has_folder, "Files did not restore pack icons after Gold")
                wait_for(files_has_sidebar_icons, "Files sidebar did not restore pack icons after Gold")
                ipc.action("set_accent_color", {"color": "#112233"})
                cfg = tomllib.loads((tmp / "rediwm-config.toml").read_text())
                assert set(cfg["theme"]) == {"base", "accent"}, cfg["theme"]
                # Atomic replacement updates unset tokens, keeping the override.
                replacement = tmp / "replacement"
                shutil.copytree(pack, replacement, symlinks=True)
                manifest_path = replacement / "theme.toml"
                manifest_path.write_text(manifest_path.read_text().replace('version = "1.0"', 'version = "2.0"').replace('window_bg = "#142850"', 'window_bg = "#204060"'))
                ipc.action("theme.install", {"path": str(replacement), "replace": True})
                tokens = ipc.action("get_theme")["tokens"]
                assert all(abs(a - b) < .001 for a, b in zip(tokens["accent"], [17/255, 34/255, 51/255, 1]))
                assert all(abs(a - b) < .001 for a, b in zip(tokens["window_bg"], [32/255, 64/255, 96/255, 1]))
                exported = tmp / "exported.rediwm-theme"
                export_env = dict(env, REDIWM_CONFIG=str(tmp / "rediwm-config.toml"))
                helper(export_env, "share", "exported", tmp / "rediwm-config.toml", tmp / "data/rediwm/themes/test-pack/wallpapers/test.png", tmp / "data/rediwm/themes/test-pack/logo.svg", exported)
                assert exported.is_file()
                helper(env, "validate", tmp / "data/rediwm/themes/exported")
                assert (tmp / "data/rediwm/themes/exported/icons/folder.svg").read_bytes() == (pack / "icons/folder.svg").read_bytes()
                assert (tmp / "data/rediwm/themes/exported/glyphs/wifi.svg").read_bytes() == (pack / "glyphs/wifi.svg").read_bytes()
                helper(env, "remove", "exported")
                ipc.action("theme.apply", {"id": "test-pack"})
                assert tomllib.loads((tmp / "rediwm-config.toml").read_text())["theme"] == {"base": "test-pack"}
                ipc.action("open_appearance")
                ui = UIDriver(ipc)
                ui.wait_present("theme_reset")
                ipc.wait_for_panel_settled("control_center")
                ipc.move_cursor(2, 2)
                nav = next(w for w in ipc.get_widget_tree("control_center")["widgets"] if w.get("name") == "network" and w.get("role") == "row")
                panel = ipc.get_shell_state()["control_center"]["box"]
                box = nav["box"]
                glyph_shot = tmp / "glyph.png"
                ipc.screenshot(str(glyph_shot))
                x = round(panel["x"] + box["x"] + 16)
                y = round(panel["y"] + box["y"] + (box["height"] - 22) / 2)
                glyph = Image.open(glyph_shot).convert("RGB").crop((x, y, x+22, y+22))
                fg = tuple(round(c*255) for c in ipc.action("get_theme")["tokens"]["window_fg"][:3])
                assert sum(color == fg for color in glyph.getdata()) > 350, "shell glyph override missing"
                ui.click("theme_reset")
                assert ipc.query("theme.list")["active"] == "test-pack"
                ipc.action("close_panel", {"panel": "control_center"})
                ipc.action("theme.apply", {"id": "rediwm-light"})
                assert not ipc.action("get_theme")["dark_mode"]
                wait_for(lambda: "test-pack" not in (ipc.query("get_wallpaper")["displayed_path"] or ""), "wallpaper did not restore")
                ipc.action("theme.apply", {"id": "test-pack"})
                ipc.action("open_appearance")
                ui.click(ui.scroll_into_view("theme_remove"))
                wait_for(lambda: all(p["id"] != "test-pack" for p in ipc.query("theme.list")["packs"]), "active pack was not removed")
                assert ipc.query("theme.list")["active"] == "rediwm-dark"
                ipc.action("close_panel", {"panel": "control_center"})
                assert not cursor_link.exists()
                assert all(p["id"] != "test-pack" for p in ipc.query("theme.list")["packs"])
                # A user pack can shadow a built-in ID; removal restores embedded art.
                shadow = tmp / "shadow"
                shutil.copytree(pack, shadow, symlinks=True)
                manifest_path = shadow / "theme.toml"
                manifest_path.write_text(manifest_path.read_text().replace('id = "test-pack"', 'id = "rediwm-dark"'))
                ipc.action("theme.install", {"path": str(shadow)})
                ipc.action("theme.apply", {"id": "rediwm-dark"})
                ipc.action("open_appearance")
                ui.click(ui.scroll_into_view("theme_remove"))
                wait_for(lambda: not next(p for p in ipc.query("theme.list")["packs"] if p["id"] == "rediwm-dark")["user_installed"] and ipc.action("get_theme")["tokens"]["start_button_icon"] == "", "embedded pack was not restored")
                tokens = ipc.action("get_theme")["tokens"]
                assert tokens["start_button_icon"] == "", tokens["start_button_icon"]
                ipc.action("close_panel", {"panel": "control_center"})
                # Missing pack falls back; the config remains usable.
                config = tmp / "rediwm-config.toml"
                config.write_text(config.read_text().replace('base = "rediwm-dark"', 'base = "missing-pack"'))
                ipc.reload_config()
                assert ipc.get_outputs()
            stop_process(proc)
            assert proc.returncode == 0, (tmp / "compositor.log").read_text()
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            if files is not None:
                stop_process(files)
            if proc.poll() is None:
                stop_process(proc)
            log.close()
        print("PASS: pack installs, security limits, assets, layering, reset, cursors and removal")

if __name__ == "__main__":
    run()
