#!/usr/bin/env python3
"""Outline a Zig file's declarations to pick split points.

    zoutline.py FILE [--in NAME] [--min LINES]

Prints each declaration's line range (from its declaration line, which is what
a spec's N-M range matches), its length including doc comments, its size and
its first line. --in NAME lists the members of the top-level container
`const NAME = struct { ... };` instead, with the file's own line numbers (for
znested.py and zhoist.py); --min hides declarations shorter than LINES.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zsplit import parse  # noqa: E402


def main():
    args = sys.argv[1:]
    path, container, minimum = None, None, 0
    while args:
        a = args.pop(0)
        if a == '--in' and args:
            container = args.pop(0)
        elif a == '--min' and args:
            minimum = int(args.pop(0))
        elif path is None and not a.startswith('-'):
            path = a
        else:
            raise SystemExit(__doc__)
    if path is None:
        raise SystemExit(__doc__)
    lines = open(path).read().split('\n')
    offset = 0
    if container:
        d = next((x for x in parse(lines) if x.name == container), None)
        if d is None:
            raise SystemExit(f'{path}: no top-level declaration {container}')
        print(f'{container}: lines {d.decl_line + 1}-{d.end}')
        offset = d.decl_line + 1
        lines = [l[4:] if l.startswith('    ') else l for l in lines[offset:d.end - 1]]
    for d in parse(lines):
        count = d.end - d.start
        if count < minimum or d.kind == 'field':
            continue
        size = sum(len(l) + 1 for l in lines[d.start:d.end])
        print(f'{d.decl_line + offset + 1:5d}-{d.end + offset:5d} {count:4d}L {size:6d}B  '
              f'{lines[d.decl_line].strip()[:100]}')


if __name__ == '__main__':
    main()
