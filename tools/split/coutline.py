#!/usr/bin/env python3
"""Outline a C or C++ file to plan a split.

    coutline.py FILE

One line per top-level definition with its line range. Functions show `s`
(static) or `X` (exported), their length and the file's own functions they
call: cut where few calls cross, and the callees that do cross become the
shared helpers (see csplit.py). Approximate: it counts braces and does not
follow macros or C++ namespaces.
"""
import re, sys

def strip(src):
    # blank comments and strings, keep newlines
    out = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', src[i:j])); i = j
        elif src.startswith('//', i):
            j = src.find('\n', i); j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j
        elif src[i] in '"\'':
            q = src[i]; j = i + 1
            while j < n and src[j] != q:
                j += 2 if src[j] == '\\' else 1
            out.append(q + ' ' * (j - i - 1) + q); i = j + 1
        else:
            out.append(src[i]); i += 1
    return ''.join(out)

def defs(path):
    src = open(path).read()
    code = strip(src)
    lines = code.split('\n')
    res = []  # (name, kind, start, end, static)
    depth = 0
    start = None
    for idx, line in enumerate(lines):
        if depth == 0 and start is None and line.strip() and not line.startswith((' ', '\t', '#', '}')):
            start = idx
        for ch in line:
            if ch == '{': depth += 1
            elif ch == '}': depth -= 1
        if depth == 0 and start is not None:
            t = line.rstrip()
            if t.endswith(';') or t.endswith('}'):
                head = ' '.join(lines[start:idx + 1])
                m = re.search(r'(\w+)\s*\([^;{]*\)\s*\{', head)
                if m and '{' in head and not re.match(r'\s*(static\s+)?(const\s+)?struct\s+\w+\s+\w+\s*=', head):
                    res.append((m.group(1), 'fn', start, idx + 1, head.lstrip().startswith('static')))
                else:
                    sm = re.match(r'\s*struct\s+(\w+)\s*\{', head)
                    if sm:
                        res.append((sm.group(1), 'struct', start, idx + 1, False))
                    else:
                        vm = re.search(r'(\w+)\s*(\[[^\]]*\])?\s*(=|;)', head)
                        res.append((vm.group(1) if vm else '?', 'decl', start, idx + 1, 'static' in head))
                start = None
    return src, lines, res

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    src, lines, res = defs(path)
    fns = {r[0] for r in res if r[1] == 'fn'}
    for name, kind, s, e, st in res:
        if kind != 'fn':
            print(f'{s+1:5d}-{e:5d} {kind:6s} {name}')
            continue
        body = '\n'.join(lines[s:e])
        calls = sorted({m for m in re.findall(r'\b(\w+)\s*\(', body) if m in fns and m != name})
        print(f'{s+1:5d}-{e:5d} {"s" if st else "X"} {e-s:4d}L {name}: {" ".join(calls)}')
