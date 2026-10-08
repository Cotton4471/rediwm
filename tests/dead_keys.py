#!/usr/bin/env python3
"""Dead keys and Compose sequences typed into compositor-drawn fields.

A virtual keyboard with the Latin American layout types into the start menu's
search box. xkbcommon gives a dead key no text, so without the shell's Compose
step the accent is lost; the table must also follow `[region] language`
(acute then c is ç in Portuguese, ć elsewhere).
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from xwayland import wait_for, wayland_display_name

ACUTE, A, C, BACKSPACE, B = 26, 30, 46, 14, 48  # evdev codes on `latam`
ENTER, F2, HOME = 28, 60, 102


def compile_client(tmp):
    xml = ROOT / "protocol/virtual-keyboard-unstable-v1.xml"
    for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
        subprocess.run(["wayland-scanner", mode, str(xml), str(tmp / f"vk-{suffix}")], check=True)
    # The generated header is included by its protocol name.
    (tmp / "virtual-keyboard-unstable-v1-client-protocol.h").write_text((tmp / "vk-client-protocol.h").read_text())
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}", str(ROOT / "tests/virtual_keyboard_client.c"),
                    str(tmp / "vk-protocol.c"), "-lwayland-client", "-lxkbcommon",
                    "-o", str(tmp / "virtual-keyboard-client")], check=True)


class Keyboard:
    def __init__(self, tmp, layout):
        env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=wayland_display_name(tmp))
        env.pop("DISPLAY", None)
        self.log = tmp / "keyboard.log"
        with self.log.open("w") as out:
            self.process = subprocess.Popen([str(tmp / "virtual-keyboard-client"), layout], env=env,
                                            stdin=subprocess.PIPE, stdout=out, stderr=out, text=True)
        wait_for(lambda: "ready\n" in self.log.read_text(), lambda: f"keyboard did not start: {self.log.read_text()}")

    def send(self, line):
        before = self.log.read_text().count(f"ack {line}\n")
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()
        wait_for(lambda: self.log.read_text().count(f"ack {line}\n") > before, f"no ack for {line}")

    def press(self, code, hold=0.0):
        self.send(f"key {code} 1")
        time.sleep(hold)
        self.send(f"key {code} 0")

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.write("quit\n")
            self.process.stdin.flush()
            self.process.wait(timeout=5)


def search_text(ipc):
    return ipc.get_shell_state()["start_menu"].get("search_text") or ""


def session(tmp, language, accented_c):
    config = f'[compositor]\nxwayland = false\n[region]\nlanguage = "{language}"\n[input]\nkey_repeat_delay = 300\n'
    process, log = spawn_compositor(tmp, config_content=config, env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
    keyboard = None
    try:
        with IPCClient(tmp, timeout=15) as ipc:
            ipc.wait_for("wallpaper_presented", timeout_ms=10000)
            ipc.action("open_start_menu")
            wait_for(lambda: ipc.get_shell_state()["start_menu"]["state"] == "open", "start menu did not open")
            keyboard = Keyboard(tmp, "latam")

            # Dead key then letter: one accented letter, nothing for the dead key.
            keyboard.press(ACUTE)
            assert search_text(ipc) == "", repr(search_text(ipc))
            keyboard.press(A)
            wait_for(lambda: search_text(ipc) == "á", lambda: f"expected á, got {search_text(ipc)!r}")

            # The table follows the language.
            keyboard.press(ACUTE)
            keyboard.press(C)
            expected = "á" + accented_c
            wait_for(lambda: search_text(ipc) == expected, lambda: f"{language}: expected {expected!r}, got {search_text(ipc)!r}")

            # Backspace ends a pending sequence instead of deleting text.
            keyboard.press(ACUTE)
            keyboard.press(BACKSPACE)
            time.sleep(0.2)
            assert search_text(ipc) == expected, repr(search_text(ipc))
            keyboard.press(B)
            wait_for(lambda: search_text(ipc) == expected + "b", lambda: f"after cancel: {search_text(ipc)!r}")

            # Neither the dead key nor the key that completes it repeats.
            keyboard.send(f"key {ACUTE} 1")
            time.sleep(1.0)
            keyboard.send(f"key {ACUTE} 0")
            keyboard.send(f"key {A} 1")
            time.sleep(1.0)
            keyboard.send(f"key {A} 0")
            time.sleep(0.2)
            assert search_text(ipc) == expected + "bá", f"repeat leaked: {search_text(ipc)!r}"

            # Plain keys still repeat.
            keyboard.send(f"key {B} 1")
            time.sleep(1.0)
            keyboard.send(f"key {B} 0")
            assert search_text(ipc).startswith(expected + "bá" + "bbb"), f"plain key stopped repeating: {search_text(ipc)!r}"
    except Exception:
        print((tmp / "compositor.log").read_text()[-3000:])
        raise
    finally:
        if keyboard:
            keyboard.close()
        stop_process(process)
        log.close()
    assert "panic:" not in (tmp / "compositor.log").read_text()


def files_rename(tmp, language, accented_c):
    """The same sequences in an app client: Files' rename field."""
    home = tmp / "home"
    home.mkdir()
    (home / "x.txt").write_text("x")
    for name in ("data", "config", "state"):
        (tmp / name).mkdir()
    # An app gets its language from the environment the compositor builds for
    # it; stand in for that here.
    env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(tmp), XDG_DATA_HOME=str(tmp / "data"),
               XDG_CONFIG_HOME=str(tmp / "config"), XDG_STATE_HOME=str(tmp / "state"),
               REDIWM_FILES_DEVICES="0", LC_CTYPE=language, LANG=language)
    env.pop("LC_ALL", None)
    process, log = spawn_compositor(tmp, config_content="[compositor]\nxwayland = false\n",
                                    env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "HOME": str(home)})
    files = keyboard = None
    try:
        with IPCClient(tmp, timeout=15) as ipc:
            ipc.wait_for("wallpaper_presented", timeout_ms=10000)
            env["WAYLAND_DISPLAY"] = wayland_display_name(tmp)
            env.pop("DISPLAY", None)
            with (tmp / "files.log").open("w") as out:
                files = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-files"), str(home)], env=env, stdout=out, stderr=out)
            window = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-files"), None),
                              "Files did not map")
            ipc.focus_window(window["id"])
            time.sleep(0.5)
            keyboard = Keyboard(tmp, "latam")
            keyboard.press(HOME)  # selects the one file
            keyboard.press(F2)
            time.sleep(0.3)
            for key in (ACUTE, A, ACUTE, C):
                keyboard.press(key)
            keyboard.press(ENTER)
            expected = "á" + accented_c + ".txt"
            wait_for(lambda: (home / expected).exists(),
                     lambda: f"expected {expected!r}, found {sorted(p.name for p in home.iterdir())}")
    except Exception:
        print((tmp / "compositor.log").read_text()[-3000:])
        print((tmp / "files.log").read_text()[-3000:] if (tmp / "files.log").exists() else "")
        raise
    finally:
        if keyboard:
            keyboard.close()
        if files:
            stop_process(files)
        stop_process(process)
        log.close()
    assert "panic:" not in (tmp / "compositor.log").read_text()


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-dead-keys-") as directory:
        tmp = Path(directory)
        compile_client(tmp)
        for language, accented_c in (("pt_BR.utf8", "ç"), ("es_MX.utf8", "ć")):
            sub = tmp / language
            sub.mkdir(mode=0o700)
            for name in ("virtual-keyboard-client",):
                (sub / name).symlink_to(tmp / name)
            session(sub, language, accented_c)
            print(f"PASS: dead keys compose under {language}")
            app = tmp / (language + "-files")
            app.mkdir(mode=0o700)
            (app / "virtual-keyboard-client").symlink_to(tmp / "virtual-keyboard-client")
            files_rename(app, language, accented_c)
            print(f"PASS: Files rename composes under {language}")


if __name__ == "__main__":
    run()
