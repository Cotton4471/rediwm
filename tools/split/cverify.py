#!/usr/bin/env python3
"""Line accounting for a C or C++ split.

    cverify.py ORIGINAL NEW...

ORIGINAL is a path or REV:path (read with `git show`). Prints the stripped,
non-blank lines that the NEW files lack or add as a multiset. What remains
should be only the edits the split meant: dropped `static`, renamed shared
functions, the new headers, includes and file comments.
"""
import subprocess
import sys
from collections import Counter


def read(path):
    if ':' in path and not path.startswith('/'):
        return subprocess.run(['git', 'show', path], capture_output=True, text=True, check=True).stdout
    return open(path).read()


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    before = Counter(l.strip() for l in read(sys.argv[1]).split('\n') if l.strip())
    after = Counter()
    for p in sys.argv[2:]:
        after.update(l.strip() for l in open(p).read().split('\n') if l.strip())
    for k, v in (before - after).items():
        print(f'MISSING x{v}: {k[:140]}')
    for k, v in (after - before).items():
        print(f'ADDED   x{v}: {k[:140]}')
    print(f'missing={sum((before - after).values())} added={sum((after - before).values())}')


if __name__ == '__main__':
    main()
