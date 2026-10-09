#!/usr/bin/env python3
"""Frame-block A/B of the legacy and owned output presenters (scene graph stage 3 gate).

Session-level pairs (`scene_baseline.py --modes paired`) cannot resolve a few
microseconds: two sessions of the same presenter differ by up to 12 %. This runs
ONE compositor that alternates presenters every 32 frames, so both arms share the
process, clocks, thermal and power state. It needs a measurement build, because
the alternation is a test hook that production must not carry:

    git worktree add /tmp/ab HEAD        # or: git archive HEAD | tar -x -C /tmp/ab
    cd /tmp/ab && git apply <repo>/tests/scene_ab.patch
    zig build -Doptimize=ReleaseSafe
    WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 python3 <repo>/tests/scene_ab.py \\
        --binary /tmp/ab/zig-out/bin/rediwm

Per cell (clear repaint / repaint under glass, at each scale) it collects 3000
samples per presenter of the build call's thread CPU time, its wall time, build
plus commit wall time and GPU elapsed, and compares means against the tolerance
(docs/plans/scene-graph.md, stage 3: +5 % on build CPU and GPU elapsed). Exit
status is 1 if any cell is over. Differences under about 1.5 points are noise;
absolute values move between runs, only the within-run difference means anything.
Keep the machine on AC power and run nothing else: the harness refuses battery.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scene_baseline as sb
from desktop_zoom import build_client

REPORT = re.compile(r"AB (\w+): legacy mean (\d+) med (\d+) p10 (\d+) p90 (\d+) \| "
                    r"owned mean (\d+) med (\d+) p10 (\d+) p90 (\d+) \(ns, n=(\d+)\)")
GATED = ("build_cpu", "gpu")


def parse_reports(text):
    cells = {}
    for match in REPORT.finditer(text):
        v = [int(x) for x in match.groups()[1:]]
        cells[match.group(1)] = {
            "n": v[8], "legacy": dict(mean=v[0], median=v[1], p10=v[2], p90=v[3]),
            "owned": dict(mean=v[4], median=v[5], p10=v[6], p90=v[7])}
    return cells


def run_cell(binary, config, scenario, timeout):
    with tempfile.TemporaryDirectory(prefix="rediwm-scene-ab-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        session = sb.Session(tmp, config, binary, "gles2", False, False, 4.0)
        try:
            for key in ("a", "b", "c"):
                session.start_client(key)
            session.raise_b()
            session.settle(1.0)
            glass, clear = session.spinner_rects()
            session.start_client("c", "damage", glass if scenario == "glass" else clear)
            session.raise_b()
            session.settle(1.0)
            session.ipc.reset_perf()  # the GPU timer exists only after a perf request
            power = sb.power_state()
            log = tmp / "compositor.log"
            deadline = time.monotonic() + timeout
            cells = {}
            while time.monotonic() < deadline:
                time.sleep(5)
                cells = parse_reports(log.read_text(errors="replace"))
                if len(cells) == 4:
                    break
            return cells, power, sb.power_state()
        finally:
            session.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path, required=True, help="measurement build (tests/scene_ab.patch applied)")
    parser.add_argument("--configs", default="scale1,scale1.5,mixed")
    parser.add_argument("--scenarios", default="clear,glass", help="clear repaint, repaint under glass")
    parser.add_argument("--tolerance", type=float, default=5.0, help="allowed increase of owned over legacy, percent")
    parser.add_argument("--timeout", type=float, default=420, help="seconds to wait per cell")
    parser.add_argument("--cpus", default="auto", help="'auto' (P-cores) or 'none'")
    parser.add_argument("--allow-battery", action="store_true")
    parser.add_argument("--out", type=Path, help="write the raw statistics here")
    args = parser.parse_args()

    if b"REDIWM_TEST_AB" not in args.binary.read_bytes():
        parser.error(f"{args.binary} is not a measurement build: apply tests/scene_ab.patch and rebuild")
    unknown = [c for c in args.configs.split(",") if c not in sb.CONFIGS]
    if unknown:
        parser.error(f"unknown config {unknown}")
    if args.cpus == "auto" and sb.p_core_cpus():
        os.sched_setaffinity(0, sb.p_core_cpus())
    power = sb.power_state()
    if power["ac_online"] is False and not args.allow_battery:
        parser.error("AC power is not online: clocks differ on battery (use --allow-battery to measure anyway)")
    os.environ["REDIWM_TEST_AB"] = "1"
    os.environ.pop("REDIWM_TEST_SCENE_RENDERER", None)
    print(f"power: {power}", flush=True)

    results, failures = {}, []
    for config in args.configs.split(","):
        for scenario in args.scenarios.split(","):
            name = f"{config}/{scenario}"
            cells, before, after = run_cell(args.binary, config, scenario, args.timeout)
            if len(cells) != 4:
                failures.append(f"{name}: only {sorted(cells)} reported before the timeout")
                print(f"{name:16s} INCOMPLETE ({sorted(cells)})", flush=True)
                continue
            results[name] = {"cells": cells, "power_before": before, "power_after": after}
            row, bad = [], []
            for metric in ("build_cpu", "commit_wall", "gpu"):
                legacy, owned = cells[metric]["legacy"]["mean"], cells[metric]["owned"]["mean"]
                delta = (owned - legacy) / legacy * 100
                row.append(f"{metric} {legacy / 1e3:6.1f} -> {owned / 1e3:6.1f} us ({delta:+5.1f}%)")
                if metric in GATED and delta > args.tolerance:
                    bad.append(f"{metric} {delta:+.1f}%")
            if before != after:
                row.append("POWER CHANGED")
            print(f"{name:16s} " + "  ".join(row) + ("  OVER: " + ", ".join(bad) if bad else "  ok"), flush=True)
            failures += [f"{name}: {b} over +{args.tolerance:g}%" for b in bad]
    if args.out:
        args.out.write_text(json.dumps(results, indent=1) + "\n")
    if failures:
        print("\nFAIL:\n  " + "\n  ".join(failures))
        sys.exit(1)
    print(f"\nPASS: every cell within +{args.tolerance:g}% on {' and '.join(GATED)}")


if __name__ == "__main__":
    main()
