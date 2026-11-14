#!/bin/sh
# Runs a command with the private wlroots prefix from scripts/build-wlroots.sh
# on its pkg-config and library paths. Zig 0.17 runs pkg-config and the tests
# in the environment `zig build` was started with, so build.zig can no longer
# set these for `-Dwlroots-prefix`:
#
#   scripts/with-wlroots.sh PREFIX zig build -Dwlroots-prefix=PREFIX ...
set -eu

prefix=$1
shift
PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# Tests and `zig build run` execute from the cache, where the installed
# RUNPATH doesn't reach lib/rediwm.
LD_LIBRARY_PATH="$prefix/runtime${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH LD_LIBRARY_PATH
exec "$@"
