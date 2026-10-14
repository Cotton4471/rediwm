#!/usr/bin/env python3
"""When glass re-blurs (stage 5c of docs/plans/scene-graph-stage5.md, D1).

The output pass keeps each glass effect's blur and re-takes it only when
something painted below the effect changed in the region the blur reads. Two
clients repaint with full damage every frame:

* window A's own client lies inside its titlebar's blur region but above the
  effect: A's titlebar must not re-blur;
* window B, below A and inside that region, must make it re-blur every frame;
  moved out of the region, it must not;
* moving A re-blurs its titlebar.

Counts come from `glass_reblurs` in the performance stats. Runs at scales 1 and
1.5 on GLES2; never connects to the host desktop.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def reblurs_over(ipc, seconds):
    ipc.action("reset_performance_stats")
    time.sleep(seconds)
    perf = ipc.get_perf()
    return perf["glass_reblurs"], perf["output_commits"]


def run(scale, sidebar=False):
    with tempfile.TemporaryDirectory(prefix="rediwm-glass-reblur-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        config = '[compositor]\nxwayland = false\n[desktop]\nenabled = false\n[animations]\nreduced_motion = "on"\n'
        if sidebar:
            config += '[theme]\napp_sidebar = "rgba(27,33,40,0.72)"\napp_sidebar_blur = true\n'
        process, log = spawn_compositor(tmp, scale=str(scale), config_content=config,
                                        env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_TEST_DECORATION": "server"})
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))

                def start(name, color):
                    live = tmp / f"{name}.live"
                    live.write_text(f"{color} 400 260 {name}")
                    clients.append(subprocess.Popen(
                        [str(tmp / "client"), "--app-id", "rediwm-files" if sidebar and name == "A" else "rediwm.zoom-fixture"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 REDIWM_TEST_LIVE_FILE=str(live))))
                    return wait_for(lambda: next((w for w in ipc.get_windows() if w["title"] == name), None),
                                    f"{name} did not map")

                # B first, so A (mapped later) is above it.
                b = start("B", "ff40a060")
                a = start("A", "b8203040" if sidebar else "ff203040")
                ipc.action("move_window_to", {"id": a["id"], "x": 200, "y": 150})
                ipc.action("move_window_to", {"id": b["id"], "x": 150, "y": 100})
                ipc.move_cursor(5, 5)
                time.sleep(.6)
                assert [w["title"] for w in ipc.get_windows()][-1] in ("A", "B")

                reblurs, commits = reblurs_over(ipc, 1)
                assert commits > 20, ("clients did not keep repainting", commits)
                assert reblurs >= commits // 2, ("a window below did not re-blur the titlebar above it", scale, reblurs, commits)

                if sidebar:
                    assert reblurs >= commits, ("sidebar and titlebar should both refresh", scale, reblurs, commits)

                # B out of the region A's titlebar blur reads: A's own client keeps
                # repainting under the titlebar, but it is above the effect.
                ipc.action("move_window_to", {"id": b["id"], "x": 760, "y": 60})
                time.sleep(.4)
                reblurs, commits = reblurs_over(ipc, 1)
                assert commits > 20, ("clients did not keep repainting", commits)
                assert reblurs == 0, ("glass re-blurred for damage above it", scale, reblurs, commits)

                # Moving the window re-blurs its titlebar.
                ipc.action("reset_performance_stats")
                ipc.action("move_window_to", {"id": a["id"], "x": 210, "y": 150})
                time.sleep(.3)
                assert ipc.get_perf()["glass_reblurs"] >= 1, ("a moved titlebar kept its old blur", scale)
                print(f"PASS scale {scale}, sidebar={sidebar}: glass re-blurs for changes below it, never for its own client")
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    for scale in (1, 1.5):
        run(scale)
        run(scale, sidebar=True)
