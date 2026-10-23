#!/usr/bin/env python3
"""Check that a Zig split moved code verbatim.

    zverify.py REV PARENT GROUP...

Every non-blank line of PARENT at git revision REV must still appear in PARENT
or a GROUP file (ignoring indentation, a `pub ` prefix and `../` in import
paths), and the lines added must be imports, aliases (`const x = a.b;`) or `//!`
docs. Prints what is missing or added otherwise: only the rewrites the tools
make on purpose (`parent.var` references, a group's `test { ... }` block) should
remain.
"""
import re
import subprocess
import sys
from collections import Counter

ALIAS = re.compile(r'^const \w+ = (@import\("[^"]+"\)(\.\w+)*|[\w.]+(\.\w+)*|std\.log\.scoped\(\.\w+\));$')


def norm(line):
    line = re.sub(r'^pub\s+', '', line.strip())
    return re.sub(r'@(import|embedFile)\("(?:\.\./)+', r'@\1("', line)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    rev, paths = sys.argv[1], sys.argv[2:]
    orig = subprocess.run(['git', 'show', f'{rev}:{paths[0]}'], capture_output=True, text=True,
                          check=True).stdout
    before = Counter(norm(l) for l in orig.split('\n') if l.strip())
    after = Counter()
    for p in paths:
        after.update(norm(l) for l in open(p).read().split('\n') if l.strip())
    missing = before - after
    added = {k: v for k, v in (after - before).items() if not ALIAS.match(k) and not k.startswith('//!')}
    for k, v in missing.items():
        print(f'MISSING x{v}: {k[:150]}')
    for k, v in added.items():
        print(f'ADDED x{v}: {k[:150]}')
    print(f'missing={sum(missing.values())} added={sum(added.values())}')


if __name__ == '__main__':
    main()
