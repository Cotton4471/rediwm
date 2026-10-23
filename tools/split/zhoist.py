#!/usr/bin/env python3
"""Hoist a nested `pub const Name = struct { ... };` into its own file-struct.

    zhoist.py PARENT NAME NEWFILE

The parent keeps `pub const Name = @import("NEWFILE");` (with the doc
comment). The new file gets the imports the body uses, aliases for the
parent's other declarations it uses, `const Name = @This();` and the
dedented body.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zsplit import parse, rich_tokens, is_copyable, rewrite_import_paths, strip_code, nested_decls  # noqa: E402


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    parent, name, newfile = sys.argv[1:4]
    lines = open(parent).read().split('\n')
    decls = parse(lines)
    by_name = {d.name: d for d in decls if d.kind in ('fn', 'const', 'var')}
    d = by_name[name]
    head = lines[d.decl_line]
    if not re.match(r'^(pub\s+)?const\s+' + name + r'\s*=\s*(extern\s+|packed\s+)?struct\s*\{\s*$', head):
        raise SystemExit(f'unexpected container header: {head}')
    if lines[d.end - 1].strip() != '};':
        raise SystemExit('container does not end with `};`')
    body = lines[d.decl_line + 1:d.end - 1]
    ded = []
    for l in body:
        if l.startswith('    '):
            ded.append(l[4:])
        elif l.strip() == '':
            ded.append('')
        else:
            ded.append(l)
    body_text = '\n'.join(ded)
    parent_dir = os.path.dirname(parent)
    new_dir = os.path.dirname(newfile)
    parent_stem = os.path.splitext(os.path.basename(parent))[0]

    bare, calls, qualified = rich_tokens(body_text)
    inner = {x.name: x for x in parse(ded) if x.kind in ('fn', 'const', 'var')}
    copies, aliases = [], []
    pending = sorted(n for n in bare if n in by_name and n != name and n not in inner)
    seen = set()
    while pending:
        n = pending.pop()
        if n in seen:
            continue
        seen.add(n)
        x = by_name[n]
        text = '\n'.join(lines[x.decl_line:x.end])
        if is_copyable(x, text):
            copies.append(x)
            for ident in rich_tokens(text.split('=', 1)[1])[0]:
                if ident in by_name and ident not in seen and ident != name:
                    pending.append(ident)
            continue
        if x.kind == 'var':
            raise SystemExit(f'body uses parent var {n}; handle by hand')
        aliases.append(n)

    # Parent code that reaches private members of the container.
    rest = '\n'.join(lines[:d.start] + lines[d.end:])
    _, rcalls, rqual = rich_tokens(rest)
    widen = set()
    for n, x in inner.items():
        if not x.pub and (n in rcalls or (name, n) in rqual):
            widen.add(x.decl_line)
    for k in widen:
        ded[k] = re.sub(r'^(\s*)', r'\1pub ', ded[k], count=1)

    # Fields share the file-struct's namespace with declarations.
    fields = set()
    for x in parse(ded):
        if x.kind == 'field':
            fm = re.match(r'^\s*(\w+)\s*:', ded[x.decl_line])
            if fm:
                fields.add(fm.group(1))
    renames = {}
    for x in copies:
        if x.name in fields:
            renames[x.name] = x.name + '_mod'
    for n in aliases:
        if n in fields:
            raise SystemExit(f'alias {n} collides with a field; handle by hand')
    if renames:
        def ren(line):
            code = strip_code(line)
            out_l, last = [], 0
            for m in re.finditer(r'[A-Za-z_][A-Za-z0-9_]*', code):
                st = m.start()
                prev = code[st - 1] if st > 0 else ''
                if m.group(0) in renames and prev not in ('.', '@') and not (prev.isalnum() or prev == '_'):
                    # skip field declarations `name: T`
                    if code[m.end():].lstrip().startswith(':') and code[:st].strip() == '':
                        continue
                    out_l.append(line[last:st])
                    out_l.append(renames[m.group(0)])
                    last = m.end()
            out_l.append(line[last:])
            return ''.join(out_l)
        ded = [ren(l) for l in ded]
        print(f'renamed imports clashing with fields: {renames}')

    doc = [l for l in lines[d.start:d.decl_line]]
    out = []
    for l in doc:
        s = l.strip()
        if s.startswith('///'):
            out.append('//!' + s[3:])
    if out:
        out.append('')
    for x in sorted(copies, key=lambda x: x.decl_line):
        text = re.sub(r'^pub\s+', '', '\n'.join(lines[x.decl_line:x.end]))
        if x.name in renames:
            text = re.sub(r'^const\s+' + x.name + r'\b', 'const ' + renames[x.name], text)
        out.append(rewrite_import_paths(text, parent_dir, new_dir))
    if aliases:
        out.append(f'const {parent_stem} = @import("{os.path.relpath(parent, new_dir)}");')
        for n in sorted(aliases, key=lambda n: by_name[n].decl_line):
            out.append(f'const {n} = {parent_stem}.{n};')
    out.append(f'const {name} = @This();')
    out.append('')
    out.append(rewrite_import_paths('\n'.join(ded), parent_dir, new_dir).strip('\n'))
    if os.path.exists(newfile):
        raise SystemExit(f'{newfile} exists')
    open(newfile, 'w').write('\n'.join(out) + '\n')

    new = list(lines)
    # Members of the parent's other containers that the body reaches.
    for x in decls:
        if x is d or x.kind not in ('const', 'var'):
            continue
        for idx, mname, mpub in nested_decls(lines, x):
            if not mpub and (mname in calls or (x.name, mname) in qualified):
                new[idx] = re.sub(r'^(\s*)', r'\1pub ', new[idx], count=1)
    for n in aliases:
        x = by_name[n]
        if not x.pub:
            new[x.decl_line] = re.sub(r'^(\s*)', r'\1pub ', new[x.decl_line], count=1)
    pub = 'pub ' if head.startswith('pub') else ''
    repl = new[d.start:d.decl_line] + [f'{pub}const {name} = @import("{os.path.relpath(newfile, parent_dir)}");']
    new[d.start:d.end] = repl
    open(parent, 'w').write('\n'.join(new).rstrip('\n') + '\n')
    print(f'{newfile}: {len(body)} lines; {len(aliases)} parent aliases, {len(widen)} members widened')


if __name__ == '__main__':
    main()
