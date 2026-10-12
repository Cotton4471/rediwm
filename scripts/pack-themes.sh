#!/bin/sh
# Packs RediWM's built-in themes (assets/themes/*.toml) into shareable
# .rediwm-theme zips, one per theme, using the built rediwm-theme helper.
#
#   scripts/pack-themes.sh [--out DIR]
#
# Each preset becomes a pack directory: its TOML as theme.toml, plus the
# wallpaper named in [assets] from assets/wallpapers/. The helper validates
# every directory before it is zipped, so a broken preset fails here, not in
# someone else's Appearance picker. DIR defaults to ./release/themes, which
# is ignored by git. Build first: zig build
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/release/themes"
helper="$here/zig-out/bin/rediwm-theme"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out=$2; shift ;;
        *) echo "Usage: $0 [--out DIR]" >&2; exit 1 ;;
    esac
    shift
done

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -x "$helper" ] || die "$helper is missing; run zig build first"
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rediwm-themes.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

for toml in "$here"/assets/themes/*.toml; do
    id=$(sed -n 's/^id = "\(.*\)"$/\1/p' "$toml" | head -n 1)
    [ -n "$id" ] || die "$toml has no [meta] id"
    dir="$work/$id"
    mkdir -p "$dir"
    cp "$toml" "$dir/theme.toml"

    # wallpaper = "name" under [assets] names a file in wallpapers/.
    wallpaper=$(sed -n 's/^wallpaper = "\(.*\)"$/\1/p' "$toml" | head -n 1)
    if [ -n "$wallpaper" ]; then
        mkdir -p "$dir/wallpapers"
        cp "$here/assets/wallpapers/$wallpaper" "$dir/wallpapers/$wallpaper"
    fi

    log "validate $id"
    "$helper" validate "$dir"
    rm -f -- "$out/$id.rediwm-theme"
    log "pack $id -> $out/$id.rediwm-theme"
    "$helper" pack "$dir" "$out/$id.rediwm-theme"
    chmod 644 "$out/$id.rediwm-theme"
done
log "done"
