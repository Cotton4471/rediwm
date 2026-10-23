#!/usr/bin/env python3
"""Move arms of a function's top-level `switch` into sub-handlers in sibling files.

Spec (see examples/ipc_handlers.spec):
    parent src/ipc/handlers.zig
    function handleAction
    group src/ipc/handlers_input.zig handleInput Synthetic input actions.
      move_cursor click scroll ...

The function's body must be a single exhaustive `switch` whose every arm
returns. Each group becomes `pub fn NAME(<same params>) <same return type>`
with the moved arms verbatim plus `else => unreachable`; the parent keeps one
arm `.a, .b => return group.NAME(params...)` where the first moved arm was.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zsplit import parse, strip_code, rich_tokens, is_copyable, rewrite_import_paths, nested_decls  # noqa: E402


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    spec = open(sys.argv[1]).read().split('\n')
    parent = function = None
    groups = []
    for raw in spec:
        line = raw.split('#', 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith('parent '):
            parent = line.split(None, 1)[1].strip()
        elif line.startswith('function '):
            function = line.split(None, 1)[1].strip()
        elif line.startswith('group '):
            parts = line.split(None, 3)
            groups.append([parts[1], parts[2], parts[3] if len(parts) > 3 else '', []])
        else:
            groups[-1][3].extend(t.lstrip('.') for t in line.split())
    lines = open(parent).read().split('\n')
    decls = parse(lines)
    by_name = {d.name: d for d in decls if d.kind in ('fn', 'const', 'var')}
    fn = by_name[function]
    parent_dir = os.path.dirname(parent)
    parent_stem = os.path.splitext(os.path.basename(parent))[0]

    # Signature: from the decl line to the line ending with `{`.
    sig_end = fn.decl_line
    while not strip_code(lines[sig_end]).rstrip().endswith('{'):
        sig_end += 1
    sig = '\n'.join(lines[fn.decl_line:sig_end + 1])
    m = re.search(r'fn\s+\w+\s*\((.*)\)\s*([^{]*)\{\s*$', sig, re.S)
    params_src, ret = m.group(1), m.group(2).strip()
    params = []
    for p in re.split(r',\s*(?![^()]*\))', params_src):
        p = p.strip()
        if not p:
            continue
        pm = re.match(r'(?:comptime\s+|noalias\s+)?(\w+)\s*:', p)
        params.append((pm.group(1), p))

    # Locate the switch.
    candidates = [k for k in range(sig_end + 1, fn.end) if re.match(r'^    switch \((\w+)\) \{\s*$', lines[k])]
    if not candidates:
        raise SystemExit(f'{function}: no top-level switch')
    sw = candidates[-1]
    for k in range(sig_end + 1, sw):
        if re.match(r'^    (const|var) ', lines[k]):
            raise SystemExit(f'{function}: prelude declares {lines[k].strip()}; arms may depend on it')
    switch_var = re.match(r'^    switch \((\w+)\)', lines[sw]).group(1)
    # Arms: lines indented 8 at switch depth 1.
    arms = []  # [start, end, tags]
    depth = 0
    i = sw
    close = None
    pending_comment = None
    while i < fn.end:
        code = strip_code(lines[i])
        if i > sw and depth == 1:
            st = lines[i]
            if st.startswith('        //') and not st.startswith('         '):
                if pending_comment is None:
                    pending_comment = i
            elif re.match(r'^        \.', st) or re.match(r'^        else\b', st):
                tags = []
                head = code.split('=>', 1)[0]
                tags = re.findall(r'\.(\w+)', head)
                if arms and arms[-1][1] is None:
                    arms[-1][1] = pending_comment if pending_comment is not None else i
                arms.append([pending_comment if pending_comment is not None else i, None, tags])
                pending_comment = None
            elif st.strip() == '}' and st.startswith('    }'):
                pass
            elif st.strip():
                pending_comment = None
        for c in code:
            if c in '{([':
                depth += 1
            elif c in '})]':
                depth -= 1
        if i > sw and depth == 0:
            close = i
            break
        i += 1
    if arms and arms[-1][1] is None:
        arms[-1][1] = close
    tag_arm = {}
    for a in arms:
        for t in a[2]:
            tag_arm[t] = a

    owner = {}
    for gi, g in enumerate(groups):
        for t in g[3]:
            if t not in tag_arm:
                raise SystemExit(f'no arm for .{t}')
            owner[id(tag_arm[t])] = gi

    outputs = []
    for gi, (gpath, gname, gdoc, _) in enumerate(groups):
        gdir = os.path.dirname(gpath)
        mine = [a for a in arms if owner.get(id(a)) == gi]
        body = '\n'.join('\n'.join(lines[a[0]:a[1]]) for a in mine)
        bare, calls, qualified = rich_tokens(body)
        sig_bare = rich_tokens(sig)[0]
        used = (bare | sig_bare) & set(by_name)
        copies, aliases = [], []
        pending = sorted(used)
        seen = set()
        while pending:
            name = pending.pop()
            if name in seen:
                continue
            seen.add(name)
            d = by_name[name]
            text = '\n'.join(lines[d.decl_line:d.end])
            if is_copyable(d, text):
                copies.append(d)
                for ident in rich_tokens(text.split('=', 1)[1])[0]:
                    if ident in by_name and ident not in seen:
                        pending.append(ident)
                continue
            aliases.append(name)
        out = []
        for dl in gdoc.split('\\n') if gdoc else []:
            out.append('//! ' + dl)
        if out:
            out.append('')
        for d in sorted(copies, key=lambda d: d.decl_line):
            text = re.sub(r'^pub\s+', '', '\n'.join(lines[d.decl_line:d.end]))
            out.append(rewrite_import_paths(text, parent_dir, gdir))
        if aliases:
            out.append(f'const {parent_stem} = @import("{os.path.relpath(parent, gdir)}");')
            for name in sorted(aliases, key=lambda n: by_name[n].decl_line):
                out.append(f'const {name} = {parent_stem}.{name};')
        out.append('')
        out.append(f'pub fn {gname}(')
        for pname, p in params:
            out.append(f'    {p},')
        out.append(f') {ret} {{')
        for pname, _ in params:
            if pname not in bare and pname != switch_var:
                out.append(f'    _ = {pname};')
        out.append(f'    switch ({switch_var}) {{')
        out.append(rewrite_import_paths(body, parent_dir, gdir))
        out.append('        else => unreachable,')
        out.append('    }')
        out.append('}')
        if os.path.exists(gpath):
            raise SystemExit(f'{gpath} exists')
        open(gpath, 'w').write('\n'.join(out) + '\n')
        outputs.append((gi, mine, aliases, calls, qualified))

    need_pub = set()
    for gi, mine, aliases, _, _ in outputs:
        need_pub.update(aliases)
    new = list(lines)
    for d in decls:
        if d.kind not in ('const', 'var'):
            continue
        for idx, name, pub in nested_decls(lines, d):
            if pub:
                continue
            if any(name in calls or (d.name, name) in qualified for _, _, _, calls, qualified in outputs):
                new[idx] = re.sub(r'^(\s*)', r'\1pub ', new[idx], count=1)
    for name in need_pub:
        d = by_name[name]
        if not d.pub:
            new[d.decl_line] = re.sub(r'^(\s*)', r'\1pub ', new[d.decl_line], count=1)
    remove = [False] * len(new)
    insert = {}
    args = ', '.join(p for p, _ in params)
    for gi, mine, _, _, _ in outputs:
        gpath, gname = groups[gi][0], groups[gi][1]
        ident = os.path.splitext(os.path.basename(gpath))[0]
        tags = [t for a in mine for t in a[2]]
        insert[mine[0][0]] = f'        {", ".join("." + t for t in tags)} => return {ident}.{gname}({args}),'
        for a in mine:
            for k in range(a[0], a[1]):
                remove[k] = True
    result = []
    for k, line in enumerate(new):
        if k in insert:
            result.append(insert[k])
        if not remove[k]:
            result.append(line)
    # Imports for the groups: after the last top-level @import line.
    last_import = max(i for i, l in enumerate(result) if re.match(r'^(pub )?const \w+ = @import\(', l) and not l.startswith(' '))
    imports = []
    for gi, _, _, _, _ in outputs:
        gpath = groups[gi][0]
        ident = os.path.splitext(os.path.basename(gpath))[0]
        imports.append(f'const {ident} = @import("{os.path.relpath(gpath, parent_dir)}");')
    result[last_import + 1:last_import + 1] = imports
    open(parent, 'w').write('\n'.join(result).rstrip('\n') + '\n')
    for gi, mine, aliases, _, _ in outputs:
        print(f'{groups[gi][0]}: {len(mine)} arms')


if __name__ == '__main__':
    main()
