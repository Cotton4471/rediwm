#!/usr/bin/env python3
"""Fixed workload and golden captures for the scene-graph plan (docs/plans/scene-graph.md).

Runs three windows with glass, a 60 fps damage client, drag, resize, a fullscreen
client and camera zoom steps in a headless GLES2 compositor, at scale 1, scale 1.5
and mixed scales (two outputs). Every scenario records process cost from /proc and
`perf stat` (CPU, instructions:u, context switches, RSS) in a "clean" session that
never calls the performance IPC, and the compositor's own frame timers
(`cpu_frame`, `projection_cpu`, `glass_cpu`, `scene_commit_cpu`, `gpu_elapsed`) in a
"stats" session. The first stats call turns on the GPU timer, which costs about
0.17 ms per frame, so process figures are only comparable within a mode.

    python3 tests/scene_baseline.py --out baseline.json --capture golden/
    python3 tests/scene_baseline.py --binary other/rediwm --out new.json --compare golden/
    python3 tests/scene_baseline.py --report new.json --against baseline.json
    python3 tests/scene_baseline.py --modes paired --configs scale1,scale1.5,mixed --out cost.json

"paired" runs owned/legacy/legacy/owned with small repaints clear of and under
glass. Both instruction counts and frame timers are enabled in every run; these
figures must not be compared with the ordinary "clean" sessions. Instructions
are normalized per committed frame. Run without concurrent builds or tests.

Needs a render node (pick one with WLR_RENDER_DRM_DEVICE on multi-GPU machines),
`perf` for instruction counts (optional) and Pillow. Never touches the host session.
Machine-dependent: only compare runs from the same machine, preferably interleaved, and
keep a laptop on AC power (the harness refuses to start on battery, records the power
state at the start and end of every session and warns if it changed).
"""
import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops, ImageDraw

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

MIXED = '[[outputs]]\nname = "HEADLESS-1"\nscale = 1\n[[outputs]]\nname = "HEADLESS-2"\nscale = 1.5\n'
CONFIGS = {
    "scale1": {"scale": "1", "outputs": "1", "toml": ""},
    "scale1.5": {"scale": "1.5", "outputs": "1", "toml": ""},
    # Two outputs of different scales never go idle while glass is on (it re-blurs per
    # output scale, 2026-10-08): mixed_noglass is the reference without that loop.
    "mixed": {"scale": "auto", "outputs": "2", "toml": MIXED},
    "mixed_noglass": {"scale": "auto", "outputs": "2", "toml": MIXED, "env": {"REDIWM_NO_GLASS": "1"}, "golden": False},
}
CLIENT_SIZES = {"a": (480, 300), "b": (520, 320), "c": (400, 260)}
STAGES = ("cpu_frame", "projection_cpu", "glass_cpu", "scene_commit_cpu", "gpu_elapsed",
          "chrome_cpu", "taskbar_cpu", "panels_cpu")
DEFAULT_SECONDS = 4.0


def p_core_cpus():
    """Eight P-core threads (minus the first two) on hybrid Intel; None elsewhere."""
    try:
        text = Path("/sys/devices/cpu_core/cpus").read_text().strip()
    except OSError:
        return None
    cpus = set()
    for part in text.split(","):
        low, _, high = part.partition("-")
        cpus.update(range(int(low), int(high or low) + 1))
    return set(sorted(cpus)[2:10]) or None


def power_state():
    """What decides CPU/GPU clocks: a laptop on battery runs these loads 3x slower (2026-10-08)."""
    def read(path):
        try:
            return Path(path).read_text().strip()
        except OSError:
            return None
    state = {"ac_online": None}
    for supply in Path("/sys/class/power_supply").glob("*"):
        kind = read(supply / "type")
        if kind == "Mains":
            state["ac_online"] = bool(state["ac_online"]) or read(supply / "online") == "1"
        elif kind == "Battery":
            state["battery"] = read(supply / "status")
    cpu = min(os.sched_getaffinity(0))
    state.update(platform_profile=read("/sys/firmware/acpi/platform_profile"),
                 governor=read(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_governor"),
                 epp=read(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/energy_performance_preference"),
                 no_turbo=read("/sys/devices/system/cpu/intel_pstate/no_turbo"))
    return state


def thread_snapshot(pid):
    threads = {}
    for task in Path(f"/proc/{pid}/task").iterdir():
        try:
            cpu_ns = int((task / "schedstat").read_text().split()[0])
            status = dict(line.split(":", 1) for line in (task / "status").read_text().splitlines() if ":" in line)
            threads[int(task.name)] = (
                (task / "comm").read_text().strip(), cpu_ns,
                int(status["voluntary_ctxt_switches"]), int(status["nonvoluntary_ctxt_switches"]))
        except (OSError, ValueError, KeyError):
            continue
    return threads


def memory_kb(pid):
    wanted = ("VmRSS", "VmHWM", "RssAnon", "RssFile", "RssShmem")
    out = {}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        key, _, value = line.partition(":")
        if key in wanted:
            out[key] = int(value.split()[0])
    return out


class PerfStat:
    """`perf stat` attached to one process; the hybrid core/atom PMUs are summed."""

    def __init__(self, pid):
        self.file = tempfile.NamedTemporaryFile(prefix="rediwm-perfstat-", delete=False)
        self.file.close()
        try:
            self.proc = subprocess.Popen(
                ["perf", "stat", "-e", "instructions:u,cycles:u", "-x,", "-o", self.file.name, "-p", str(pid)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            self.proc = None
        time.sleep(0.15)

    def stop(self):
        if self.proc is None:
            return None
        self.proc.send_signal(signal.SIGINT)
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        totals = {"instructions": 0, "cycles": 0}
        counted = False
        for line in Path(self.file.name).read_text().splitlines():
            fields = line.split(",")
            if len(fields) < 3 or not fields[0].isdigit():
                continue
            for name in totals:
                if name in fields[2]:
                    totals[name] += int(fields[0])
                    counted = True
        Path(self.file.name).unlink(missing_ok=True)
        return totals if counted else None


class Session:
    """One headless compositor with the three fixture windows."""

    def __init__(self, tmp, config, binary, renderer, stats, use_perf, seconds):
        self.tmp, self.name, self.stats, self.use_perf, self.seconds = tmp, config, stats, use_perf, seconds
        spec = CONFIGS[config]
        wallpaper = tmp / "wallpaper.png"
        make_wallpaper(wallpaper)
        text = (f'[compositor]\nxwayland = false\nwallpaper = "{wallpaper}"\n'
                '[desktop]\nenabled = false\n[animations]\nenabled = false\n' + spec["toml"])
        self.process, self.log = spawn_compositor(
            tmp, scale=spec["scale"], outputs=spec["outputs"], config_content=text, renderer=renderer, binary=binary,
            env_extra={"HOME": str(tmp), "XDG_CONFIG_HOME": str(tmp / "config"), "XDG_CACHE_HOME": str(tmp / "cache"),
                       "XDG_DATA_HOME": str(tmp / "data"), "DBUS_SESSION_BUS_ADDRESS": "",
                       "REDIWM_THEME": str(tmp / "rediwm-config.toml"),
                       # The layout autosave restores its own 10 s-old snapshot 2, 7, 17 and 37 s after
                       # start, which moves windows (even a fullscreen one) in the middle of a scenario.
                       # An uncreatable state directory (not under /proc: mkdir answers ENOENT there and
                       # Zig's createDirPath then loops forever) leaves it nothing to save or restore.
                       "XDG_STATE_HOME": "/dev/null/rediwm-scene-baseline-no-state", **spec.get("env", {})})
        self.ipc = IPCClient(tmp, timeout=20).connect()
        self.ipc.wait_for("wallpaper_presented", timeout_ms=15000)
        self.display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")), None),
                                "wayland display")
        self.outputs = sorted(self.ipc.get_outputs(), key=lambda o: o["x"])
        self.clients = {}
        self.ids = {}
        self.shots = {}
        self.manifest = {}

    def close(self):
        for process in self.clients.values():
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        self.ipc.close()
        stop_process(self.process)
        self.log.close()

    # -- fixture windows -------------------------------------------------

    def positions(self):
        if len(self.outputs) == 1:
            return {"a": (60, 50), "b": (300, 180), "c": (700, 40)}
        second = self.outputs[1]["x"]
        return {"a": (60, 50), "b": (second - 220, 180), "c": (second + 230, 40)}

    def start_client(self, key, mode="static", rect=None):
        """mode: static, empty (60 fps empty commits) or damage (60 fps repaint, optionally of `rect`)."""
        old = self.clients.pop(key, None)
        if old is not None:
            old.terminate()
            old.wait(timeout=5)
            wait_for(lambda: self.ids[key] not in [w["id"] for w in self.ipc.get_windows()], "window gone")
        env = dict(os.environ, XDG_RUNTIME_DIR=str(self.tmp), WAYLAND_DISPLAY=self.display, REDIWM_TEST_DECORATION="server")
        for name in ("REDIWM_TEST_PERF", "REDIWM_TEST_PERF_DAMAGE", "REDIWM_TEST_PERF_DAMAGE_RECT"):
            env.pop(name, None)
        if mode in ("empty", "damage"):
            env["REDIWM_TEST_PERF"] = "1"
        if mode == "damage":
            env["REDIWM_TEST_PERF_DAMAGE"] = "1"
            if rect:
                env["REDIWM_TEST_PERF_DAMAGE_RECT"] = rect
        self.clients[key] = subprocess.Popen([str(self.tmp / "client"), "--app-id", key, "--title", key], env=env,
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        window = wait_for(lambda: next((w for w in self.ipc.get_windows() if w["app_id"] == key), None), f"window {key}")
        self.ids[key] = window["id"]
        width, height = CLIENT_SIZES[key]
        self.ipc.action("set_window_size", {"id": window["id"], "width": width, "height": height})
        self.ipc.action("move_window_to", {"id": window["id"], "x": self.positions()[key][0], "y": self.positions()[key][1]})
        want = self.positions()[key]
        # A pending move can land after a later state change (fullscreen), so wait for both.
        wait_for(lambda: self.debug(key)["client_box"]["width"] == width and
                 next(w for w in self.ipc.get_windows() if w["id"] == window["id"])["x"] == want[0] and
                 next(w for w in self.ipc.get_windows() if w["id"] == window["id"])["y"] == want[1], f"{key} placed")
        return window["id"]

    def debug(self, key):
        return self.ipc.get_window_debug(self.ids[key])

    def raise_b(self):
        self.ipc.focus_window(self.ids["b"])

    def spinner_rects(self):
        """Damage rectangles in c's surface coordinates: under b's titlebar glass, and clear of it."""
        b = self.debug("b")
        c = self.debug("c")
        top = b["chrome_box"]
        glass = (top["x"], top["y"], top["width"], b["titlebar_height"])
        client = c["client_box"]
        left, right = max(glass[0], client["x"]), min(glass[0] + glass[2], client["x"] + client["width"])
        mid_x = (left + right) // 2 - client["x"]
        mid_y = top["y"] + b["titlebar_height"] // 2 - client["y"]
        assert right - left > 40 and 0 <= mid_y < client["height"] - 16, (glass, client)
        return f"{mid_x - 8},{mid_y - 8},16,16", f"{client['width'] - 40},8,16,16"

    def settle(self, seconds=0.6):
        time.sleep(seconds)
        self.ipc.wait_for_frame()

    # -- pointer helpers (cursor coordinates are output-local) -------------

    def to_local(self, x, y):
        for output in reversed(self.outputs):
            if x >= output["x"]:
                return round(x - output["x"]), round(y - output["y"]), output["name"]
        return round(x), round(y), self.outputs[0]["name"]

    def pointer(self, x, y):
        lx, ly, name = self.to_local(x, y)
        self.ipc.move_cursor(lx, ly, output=name if len(self.outputs) > 1 else None)

    # -- measurement -------------------------------------------------------

    def measure(self, name, load=None, seconds=None):
        seconds = seconds or self.seconds
        pid = self.process.pid
        if self.stats:
            self.ipc.reset_perf()
        before, mem_before = thread_snapshot(pid), memory_kb(pid)
        perf = PerfStat(pid) if self.use_perf else None
        started = time.monotonic()
        (load or time.sleep)(seconds)
        elapsed = time.monotonic() - started
        counters = perf.stop() if perf else None
        after, mem = thread_snapshot(pid), memory_kb(pid)
        cpu_ns = vol = nonvol = 0
        busiest = []
        by_thread = {}
        for tid, (comm, ns, v, nv) in after.items():
            b = before.get(tid, (comm, 0, 0, 0))
            cpu_ns += ns - b[1]
            vol += v - b[2]
            nonvol += nv - b[3]
            busiest.append((v - b[2], comm))
            by_thread[comm] = by_thread.get(comm, 0) + ns - b[1]
        busiest.sort(reverse=True)
        result = {
            "seconds": round(elapsed, 3),
            "cpu_percent": round(cpu_ns / 1e9 / elapsed * 100, 3),
            "voluntary_switches_per_s": round(vol / elapsed, 1),
            "involuntary_switches_per_s": round(nonvol / elapsed, 1),
            "wakeup_threads": {comm: round(count / elapsed, 1) for count, comm in busiest[:4] if count},
            "cpu_threads_percent": {comm: round(ns / 1e9 / elapsed * 100, 2) for comm, ns in
                                    sorted(by_thread.items(), key=lambda item: -item[1])[:4] if ns > 0},
            "rss_kb": mem.get("VmRSS"), "rss_anon_kb": mem.get("RssAnon"), "rss_hwm_kb": mem.get("VmHWM"),
            "rss_delta_kb": mem.get("VmRSS", 0) - mem_before.get("VmRSS", 0),
        }
        if counters:
            result["instructions_per_s"] = round(counters["instructions"] / elapsed)
            result["cycles_per_s"] = round(counters["cycles"] / elapsed)
            if cpu_ns > 0:
                # User cycles over all CPU time: only meaningful relative to other scenarios.
                result["ghz_user"] = round(counters["cycles"] / cpu_ns, 3)
        if self.stats:
            result["stats"] = condense(self.ipc.get_perf())
        print(f"  {name:18s} cpu {result['cpu_percent']:6.2f}%  switches {result['voluntary_switches_per_s']:7.1f}/s"
              + (f"  commits {result['stats']['output_commits']:4d}  cpu_frame {result['stats']['cpu_frame_avg_ms']:.3f} ms"
                 if self.stats else f"  instr {result.get('instructions_per_s', 0) / 1e6:8.1f} M/s")
              + f"  rss {result['rss_kb'] / 1024:6.1f} MiB", flush=True)
        return result

    # -- golden screenshots ------------------------------------------------

    def capture(self, label):
        """Full-output screenshots with the taskbar (a clock) listed as a mask."""
        self.pointer(self.outputs[0]["x"] + 4, 4)
        self.settle(0.4)
        state = self.ipc.get_shell_state()
        for output in self.outputs:
            path = self.tmp / f"{label}-{output['name']}.png"
            path.unlink(missing_ok=True)
            self.ipc.screenshot(path=str(path), output=output["name"])
            box = next(b for b in state["taskbars"] if b["output"] == output["name"])["box"]
            # Taskbar boxes are layout coordinates; the screenshot is output-local.
            x = box["x"] - output["x"] if box["x"] >= output["x"] else box["x"]
            key = f"{self.name}/{label}-{output['name']}"
            self.shots[key] = path
            self.manifest[key] = {"scale": output["scale"], "output": output["name"],
                                  "mask": [x, box["y"] - output["y"] if box["y"] >= output["y"] else box["y"],
                                           box["width"], box["height"]]}


def make_wallpaper(path):
    """Fine diagonal bands and rings: a blur or a wrong edge colour shows up as a visible change."""
    image = Image.linear_gradient("L").resize((1920, 1080)).convert("RGB")
    draw = ImageDraw.Draw(image)
    for offset in range(-1080, 1920, 36):
        draw.line([(offset, 0), (offset + 1080, 1080)], fill=(200, 90, 40), width=10)
    for radius in range(60, 900, 90):
        draw.ellipse([960 - radius, 540 - radius, 960 + radius, 540 + radius], outline=(40, 180, 220), width=6)
    image.save(path)


def condense(perf):
    work = perf["frame_work"]
    out = {name: {key: work[name][key] for key in ("avg_ms", "p50_ms", "p95_ms", "max_ms", "total_samples")}
           for name in STAGES if name in work}
    flat = {"output_commits": perf["output_commits"], "output_skipped_commits": perf.get("output_skipped_commits"),
            "output_failed_commits": perf["output_failed_commits"], "missed_frames": perf.get("missed_frames"),
            "gpu_timing_available": work["gpu_timing_available"], "titlebar_paints": perf.get("titlebar_paints"),
            "footer_paints": perf.get("footer_paints"), "edge_samples_attempted": perf.get("edge_samples_attempted"),
            "edge_samples_succeeded": perf.get("edge_samples_succeeded"), "frame_work": out}
    for name in STAGES:
        flat[f"{name}_avg_ms"] = out.get(name, {}).get("avg_ms", 0)
    assert flat["output_failed_commits"] == 0, perf
    return flat


# -- scenarios ---------------------------------------------------------------

def paced(seconds, rate, step):
    """Call step(n) at `rate` Hz for `seconds`, absolute-time paced."""
    started, count = time.monotonic(), 0
    while time.monotonic() - started < seconds:
        step(count)
        count += 1
        time.sleep(max(0.0, started + count / rate - time.monotonic()))


def run_session(args, config, stats, results, shots_out):
    with tempfile.TemporaryDirectory(prefix="rediwm-scene-baseline-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        session = Session(tmp, config, args.binary, args.renderer, stats, not stats and not args.no_perf, args.seconds)
        mode = "stats" if stats else "clean"
        print(f"[{config}/{mode}] outputs {[(o['name'], o['scale'], o['logical_width'], o['logical_height']) for o in session.outputs]}",
              flush=True)
        out = results.setdefault(config, {}).setdefault(mode, {})
        out["_power"] = {"start": power_state()}
        try:
            for key in ("a", "b", "c"):
                session.start_client(key)
            session.raise_b()
            session.settle(1.0)
            out["idle"] = session.measure("idle", seconds=max(args.seconds, 5))
            session.capture("windows")

            glass_rect, clear_rect = session.spinner_rects()
            for name, rect in (("spinner_clear", clear_rect), ("spinner_glass", glass_rect)):
                session.start_client("c", "damage", rect)
                session.raise_b()
                session.settle()
                out[name] = session.measure(name)
            session.start_client("c", "damage")
            session.raise_b()
            session.settle()
            out["damage_full"] = session.measure("damage_full")

            session.start_client("c")
            session.raise_b()
            session.settle()
            a = session.debug("a")["chrome_box"]
            grab = (a["x"] + 120, a["y"] + 20)
            span = 2100 if len(session.outputs) > 1 else 500

            def drag(seconds):
                session.pointer(*grab)
                time.sleep(0.2)
                session.ipc.pointer_button(272, True)
                period = seconds

                def step(n):
                    phase = n / 120 / period
                    session.pointer(grab[0] + span * (1 - math.cos(2 * math.pi * phase)) / 2,
                                    grab[1] + 60 * math.sin(4 * math.pi * phase))
                paced(seconds, 120, step)
                session.ipc.pointer_button(272, False)
            out["drag"] = session.measure("drag", drag)
            session.ipc.action("move_window_to", {"id": session.ids["a"], "x": session.positions()["a"][0],
                                                  "y": session.positions()["a"][1]})
            session.pointer(session.outputs[0]["x"] + 4, 4)

            width, height = CLIENT_SIZES["b"]

            def resize(seconds):
                def step(n):
                    phase = n / 60 / seconds
                    session.ipc.action("set_window_size", {"id": session.ids["b"],
                        "width": round(width + 120 * math.sin(2 * math.pi * phase)),
                        "height": round(height + 60 * math.sin(4 * math.pi * phase))})
                paced(seconds, 60, step)
                session.ipc.action("set_window_size", {"id": session.ids["b"], "width": width, "height": height})
            out["resize"] = session.measure("resize", resize)
            session.settle()

            session.start_client("c", "damage")
            session.ipc.fullscreen(session.ids["c"])

            def fullscreen_ready():
                # The flag flips before the client repaints at the new size.
                info = session.debug("c")
                output = next(o for o in session.outputs if o["name"] == info["outputs"][0])
                return (info["fullscreen"] and info["buffer_width"] == output["logical_width"]
                        and info["buffer_height"] == output["logical_height"]
                        and (info["client_box"]["x"], info["client_box"]["y"]) == (output["x"], output["y"]))
            wait_for(fullscreen_ready, "fullscreen client at output size")
            session.settle()
            session.capture("fullscreen")
            out["fullscreen"] = session.measure("fullscreen")

            session.start_client("c", "damage", glass_rect)
            session.raise_b()
            session.settle()
            for percent in (85, 70, 55):
                session.ipc.action("set_zoom", {"percent": percent})
                wait_for(lambda: session.ipc.action("get_camera")["zoom_percent"] == percent, f"zoom {percent}")
                session.settle()
                if percent == 70:
                    session.capture("zoom70")
                out[f"zoom_{percent}"] = session.measure(f"zoom_{percent}")
            session.ipc.action("set_zoom", {"percent": 100})
            session.settle()
            # A held pinch is the only way to sit at camera_zoom_min: release snaps to a zoom level.
            session.ipc.action("pinch", {"phase": "begin", "fingers": 2})
            session.ipc.action("pinch", {"phase": "update", "scale": 0.1})
            session.settle()
            session.capture("zoom_min")
            out["zoom_min_hold"] = session.measure("zoom_min_hold")
            session.ipc.action("pinch", {"phase": "end"})
            session.ipc.action("reset_camera")
        finally:
            out["_power"]["end"] = power_state()
            if out["_power"]["end"]["ac_online"] != out["_power"]["start"]["ac_online"]:
                print(f"WARNING: AC power changed during {config}/{mode}; discard this session", flush=True)
            if not stats and CONFIGS[config].get("golden", True):
                shots_out.update({key: (path.read_bytes(), session.manifest[key]) for key, path in session.shots.items()
                                  if path.exists()})
            session.close()


def machine_info(args):
    def run(*cmd):
        try:
            return subprocess.check_output(cmd, text=True, cwd=ROOT, stderr=subprocess.DEVNULL).strip()
        except (OSError, subprocess.CalledProcessError):
            return None
    cpu = next((l.split(":", 1)[1].strip() for l in Path("/proc/cpuinfo").read_text().splitlines()
                if l.startswith("model name")), None)
    binary = Path(args.binary or ROOT / "zig-out/bin/rediwm")
    return {"commit": run("git", "rev-parse", "--short", "HEAD"), "dirty": bool(run("git", "status", "--porcelain")),
            "binary": str(binary), "binary_bytes": binary.stat().st_size if binary.exists() else None,
            "renderer": args.renderer, "kernel": os.uname().release, "cpu": cpu,
            "pinned_cpus": sorted(os.sched_getaffinity(0)) if args.cpus else None,
            "render_device": os.environ.get("WLR_RENDER_DRM_DEVICE"), "seconds": args.seconds,
            "power": power_state(),
            "date": time.strftime("%Y-%m-%d %H:%M:%S")}


def run_cost_pairs(args):
    """Interleave presenters in the same binary, preserving the raw measurements."""
    order = ("owned", "legacy", "legacy", "owned")
    data = {"mode": "paired", "meta": machine_info(args), "order": order, "runs": []}
    previous = os.environ.get("REDIWM_TEST_SCENE_RENDERER")
    try:
        for config in args.configs.split(","):
            for presenter in order:
                os.environ["REDIWM_TEST_SCENE_RENDERER"] = presenter
                with tempfile.TemporaryDirectory(prefix="rediwm-scene-cost-") as directory:
                    tmp = Path(directory)
                    build_client(tmp)
                    session = Session(tmp, config, args.binary, args.renderer, True, not args.no_perf, args.seconds)
                    power_before = power_state()
                    try:
                        for key in ("a", "b", "c"):
                            session.start_client(key)
                        session.raise_b()
                        session.settle(1)
                        glass, clear = session.spinner_rects()
                        for name, rect in (("clear", clear), ("glass", glass)):
                            session.start_client("c", "damage", rect)
                            session.raise_b()
                            session.settle(1)
                            print(f"[{config}/{presenter}/{name}]", flush=True)
                            result = session.measure(name)
                            commits = result["stats"]["output_commits"]
                            assert commits > 0, "damage client stopped committing"
                            if "instructions_per_s" in result:
                                result["instructions_per_commit"] = result["instructions_per_s"] * result["seconds"] / commits
                            data["runs"].append({"config": config, "presenter": presenter,
                                                 "scenario": name, "result": result,
                                                 "power_before": power_before, "power_after": power_state()})
                    finally:
                        session.close()
                    assert power_before == power_state(), "power conditions changed; discard this session"
                if args.out:
                    args.out.write_text(json.dumps(data, indent=1) + "\n")
    finally:
        if previous is None:
            os.environ.pop("REDIWM_TEST_SCENE_RENDERER", None)
        else:
            os.environ["REDIWM_TEST_SCENE_RENDERER"] = previous
    print_cost_report(data)


def print_cost_report(data):
    print("\nPaired cost (instructions owned/legacy; output CPU legacy -> owned; anonymous RSS delta)")
    groups = {}
    for row in data["runs"]:
        groups.setdefault((row["config"], row["scenario"]), {}).setdefault(row["presenter"], []).append(row["result"])
    for (config, scenario), presenters in groups.items():
        if any(len(presenters.get(presenter, [])) != 2 for presenter in ("owned", "legacy")):
            print(f"  {config:16s} {scenario:6s} incomplete pair; no comparison")
            continue
        def mean(presenter, field):
            return sum(field(r) for r in presenters[presenter]) / len(presenters[presenter])
        have_instructions = all("instructions_per_commit" in r for rows in presenters.values() for r in rows)
        ratio = (f"{mean('owned', lambda r: r['instructions_per_commit']) / mean('legacy', lambda r: r['instructions_per_commit']):.3f}"
                 if have_instructions else "unavailable")
        cpu = [mean(p, lambda r: r["stats"]["scene_commit_cpu_avg_ms"]) for p in ("legacy", "owned")]
        rss = mean("owned", lambda r: r["rss_anon_kb"]) - mean("legacy", lambda r: r["rss_anon_kb"])
        print(f"  {config:16s} {scenario:6s} {ratio:>11s}  {cpu[0]:.3f} -> {cpu[1]:.3f} ms  {rss:+.0f} KiB")


# -- golden comparison -------------------------------------------------------

def compare_images(new_bytes, new_meta, golden_dir, key, tolerance):
    golden = golden_dir / (key.replace("/", "__") + ".png")
    if not golden.exists():
        return {"key": key, "error": "no golden image"}
    with Image.open(golden) as old, Image.open(__import__("io").BytesIO(new_bytes)) as new:
        old, new = old.convert("RGB"), new.convert("RGB")
    if old.size != new.size:
        return {"key": key, "error": f"size {new.size} != golden {old.size}"}
    scale = new_meta["scale"]
    x, y, w, h = (round(v * scale) for v in new_meta["mask"])
    for image in (old, new):
        ImageDraw.Draw(image).rectangle([x, y, x + w, y + h], fill=(0, 0, 0))
    diff = ImageChops.difference(old, new)
    luminance = diff.convert("L")
    histogram = luminance.histogram()
    over = sum(histogram[tolerance + 1:])
    return {"key": key, "max_diff": max((i for i, n in enumerate(histogram) if n), default=0),
            "pixels_over_tolerance": over, "fraction_over": over / (new.size[0] * new.size[1]),
            "bbox": diff.getbbox()}


# -- report ------------------------------------------------------------------

def print_report(data, against=None):
    meta = data.get("meta", {})
    print(f"# {meta.get('commit')}{'+dirty' if meta.get('dirty') else ''}  {meta.get('binary')}  {meta.get('date')}")
    print(f"# {meta.get('cpu')}  pinned {meta.get('pinned_cpus')}  {meta.get('renderer')}")
    for config, modes in data["results"].items():
        print(f"\n## {config}")
        header = f"{'scenario':16s}{'cpu%':>8}{'Minstr/s':>10}{'GHz':>6}{'sw/s':>8}{'rssMiB':>8}{'commits':>8}"
        header += "".join(f"{s.replace('_cpu', '')[:9]:>10}" for s in STAGES[:5])
        print(header + "   (stage columns: avg ms per frame)")
        profiles = {json.dumps(m["_power"]["start"], sort_keys=True) for m in modes.values() if "_power" in m}
        if len(profiles) > 1 or any(m["_power"]["start"]["ac_online"] is False or
                                    m["_power"]["end"]["ac_online"] != m["_power"]["start"]["ac_online"]
                                    for m in modes.values() if "_power" in m):
            print("WARNING: power state differs between sessions or AC was offline; numbers are not comparable")
        for scenario in modes.get("clean", modes.get("stats", {})):
            if scenario.startswith("_"):
                continue
            clean = modes.get("clean", {}).get(scenario, {})
            stats = modes.get("stats", {}).get(scenario, {}).get("stats", {})
            row = f"{scenario:16s}{clean.get('cpu_percent', float('nan')):8.2f}"
            row += f"{clean.get('instructions_per_s', 0) / 1e6:10.1f}{clean.get('ghz_user', 0):6.2f}{clean.get('voluntary_switches_per_s', 0):8.1f}"
            row += f"{(clean.get('rss_kb') or 0) / 1024:8.1f}{stats.get('output_commits', 0):8d}"
            row += "".join(f"{stats.get(f'{s}_avg_ms', 0):10.3f}" for s in STAGES[:5])
            print(row)
            if against:
                old = against["results"].get(config, {})
                before_clean = old.get("clean", {}).get(scenario, {})
                before_stats = old.get("stats", {}).get(scenario, {}).get("stats", {})
                row = f"{'  vs ' + str(against.get('meta', {}).get('commit')):16s}"
                row += pct(clean.get("cpu_percent"), before_clean.get("cpu_percent"), 8)
                row += pct(clean.get("instructions_per_s"), before_clean.get("instructions_per_s"), 10)
                row += pct(clean.get("ghz_user"), before_clean.get("ghz_user"), 6)
                row += pct(clean.get("voluntary_switches_per_s"), before_clean.get("voluntary_switches_per_s"), 8)
                row += pct(clean.get("rss_kb"), before_clean.get("rss_kb"), 8)
                row += pct(stats.get("output_commits"), before_stats.get("output_commits"), 8)
                row += "".join(pct(stats.get(f"{s}_avg_ms"), before_stats.get(f"{s}_avg_ms"), 10) for s in STAGES[:5])
                print(row)


def pct(new, old, width):
    if not new or not old:
        return " " * width
    return f"{(new - old) / old * 100:+.0f}%".rjust(width)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path, help="compositor to run (default zig-out/bin/rediwm)")
    parser.add_argument("--configs", default=",".join(CONFIGS), help=f"comma list of {', '.join(CONFIGS)}")
    parser.add_argument("--modes", default="clean,stats", help="clean (process cost), stats (frame timers), or paired (presenter cost)")
    parser.add_argument("--seconds", type=float, default=DEFAULT_SECONDS, help="per scenario (idle runs at least 5)")
    parser.add_argument("--renderer", default=os.environ.get("REDIWM_TEST_RENDERER", "gles2"))
    parser.add_argument("--cpus", default="auto", help="'auto' (P-cores), 'none' or a list like 2-9")
    parser.add_argument("--no-perf", action="store_true", help="skip perf stat")
    parser.add_argument("--allow-battery", action="store_true", help="run even when AC power is not online")
    parser.add_argument("--out", type=Path, help="write results JSON here")
    parser.add_argument("--capture", type=Path, help="write golden screenshots (+manifest.json) here")
    parser.add_argument("--compare", type=Path, help="compare screenshots with a --capture directory")
    parser.add_argument("--tolerance", type=int, default=2, help="per-pixel level difference ignored by --compare")
    parser.add_argument("--report", type=Path, help="print a results JSON instead of running")
    parser.add_argument("--against", type=Path, help="results JSON to show deltas against")
    args = parser.parse_args()

    against = json.loads(args.against.read_text()) if args.against else None
    if args.report:
        data = json.loads(args.report.read_text())
        if data.get("mode") == "paired":
            print_cost_report(data)
        else:
            print_report(data, against)
        return
    modes = args.modes.split(",")
    if any(mode not in ("clean", "stats", "paired") for mode in modes):
        parser.error("modes must be clean, stats, or paired")
    if "paired" in modes and (modes != ["paired"] or args.capture or args.compare or args.against):
        parser.error("paired runs separately from clean/stats and golden capture/comparison")
    if args.seconds <= 0:
        parser.error("seconds must be positive")
    if args.cpus != "none":
        cpus = p_core_cpus() if args.cpus == "auto" else set(
            c for part in args.cpus.split(",") for c in range(int(part.partition("-")[0]), int(part.rpartition("-")[2]) + 1))
        if cpus:
            os.sched_setaffinity(0, cpus)
        else:
            args.cpus = "none"
    power = power_state()
    if power["ac_online"] is False and not args.allow_battery:
        parser.error("AC power is not online: clocks differ on battery (use --allow-battery to measure anyway)")
    print(f"power: {power}", flush=True)
    unknown = [c for c in args.configs.split(",") if c not in CONFIGS]
    if unknown:
        parser.error(f"unknown config {unknown}")
    if modes == ["paired"]:
        run_cost_pairs(args)
        return
    results, shots = {}, {}
    for config in args.configs.split(","):
        for mode in args.modes.split(","):
            run_session(args, config, mode == "stats", results, shots)
    data = {"meta": machine_info(args), "results": results}
    if args.out:
        args.out.write_text(json.dumps(data, indent=1) + "\n")
    print_report(data, against)
    if args.capture:
        args.capture.mkdir(parents=True, exist_ok=True)
        for key, (payload, _) in shots.items():
            (args.capture / (key.replace("/", "__") + ".png")).write_bytes(payload)
        (args.capture / "manifest.json").write_text(json.dumps({k: m for k, (_, m) in shots.items()}, indent=1) + "\n")
        print(f"\nwrote {len(shots)} golden screenshots to {args.capture}")
    if args.compare:
        failures = 0
        print("\n## golden comparison (taskbar masked)")
        for key, (payload, meta) in sorted(shots.items()):
            r = compare_images(payload, meta, args.compare, key, args.tolerance)
            if "error" in r:
                failures += 1
                print(f"  FAIL {key}: {r['error']}")
                continue
            ok = r["pixels_over_tolerance"] == 0
            failures += not ok
            print(f"  {'ok  ' if ok else 'DIFF'} {key}: max {r['max_diff']}, {r['pixels_over_tolerance']} px over {args.tolerance}"
                  + ("" if ok else f", bbox {r['bbox']}"))
        sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
