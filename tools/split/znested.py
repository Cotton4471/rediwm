#!/usr/bin/env python3
"""Move methods out of a nested `pub const Name = struct { ... };` into sibling files.

Spec (see examples/dbus_connection.spec):
    parent src/images/app.zig
    container App
    group src/images/app_paint.zig Painting.
      paint paintToolbar 600-800   # inner names or original line ranges

Group files import the container as `const App = @import("app.zig").App;`
(like desktop/app.zig). The container keeps one alias per moved declaration
that anything still uses; group imports go at the parent's top level.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zsplit import parse, rich_tokens, is_copyable, rewrite_import_paths, nested_decls, strip_code  # noqa: E402

PUB = lambda line: re.sub(r'^(\s*)', r'\1pub ', line, count=1)  # noqa: E731


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    spec = open(sys.argv[1]).read().split('\n')
    parent = cname = None
    groups = []
    for raw in spec:
        line = raw.split('#', 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith('parent '):
            parent = line.split(None, 1)[1].strip()
        elif line.startswith('container '):
            cname = line.split(None, 1)[1].strip()
        elif line.startswith('group '):
            parts = line.split(None, 2)
            groups.append([parts[1], parts[2] if len(parts) > 2 else '', []])
        else:
            groups[-1][2].extend(line.split())
    lines = open(parent).read().split('\n')
    outer = parse(lines)
    outer_by = {d.name: d for d in outer if d.kind in ('fn', 'const', 'var')}
    C = outer_by[cname]
    if not re.match(r'^(pub\s+)?const\s+' + cname + r'\s*=\s*struct\s*\{\s*$', lines[C.decl_line]):
        raise SystemExit('unexpected container header')
    body_start = C.decl_line + 1
    body_end = C.end - 1  # index of `};`
    ded = [l[4:] if l.startswith('    ') else l for l in lines[body_start:body_end]]
    inner = parse(ded)
    off = body_start
    inner_by = {d.name: d for d in inner if d.kind in ('fn', 'const', 'var')}
    parent_dir = os.path.dirname(parent)
    parent_stem = os.path.splitext(os.path.basename(parent))[0]

    owner = {}
    for gi, (gpath, gdoc, sels) in enumerate(groups):
        for sel in sels:
            rm = re.match(r'^(\d+)-(\d+)$', sel)
            if rm:
                lo, hi = int(rm.group(1)) - 1, int(rm.group(2)) - 1
                matched = [d for d in inner if lo <= d.decl_line + off <= hi and d.kind != 'field']
            elif sel in inner_by:
                matched = [inner_by[sel]]
            else:
                rx = re.compile('^(?:' + sel + ')$')
                matched = [d for d in inner if d.kind in ('fn', 'const', 'var') and rx.match(d.name)]
            if not matched:
                raise SystemExit(f'selector {sel!r} matched nothing')
            for d in matched:
                if d.kind in ('field', 'test', 'comptime'):
                    raise SystemExit(f'cannot move {d}')
                if d.kind == 'var':
                    raise SystemExit(f'cannot move container var {d.name}')
                owner[id(d)] = gi
    moved = [d for d in inner if id(d) in owner]

    def gtext(gi):
        return '\n'.join('\n'.join(ded[d.start:d.end]) for d in moved if owner[id(d)] == gi)
    container_rest = '\n'.join('\n'.join(ded[d.start:d.end]) for d in inner if id(d) not in owner)
    outer_rest = '\n'.join('\n'.join(lines[d.start:d.end]) for d in outer if d is not C)
    info = {g: rich_tokens(gtext(g)) for g in range(len(groups))}
    info_c = rich_tokens(container_rest)
    info_o = rich_tokens(outer_rest)

    inner_pub = set()      # inner (unmoved) names to make pub
    outer_pub = set()      # outer names to make pub
    alias_needed, alias_pub = set(), set()
    nested_pub_lines = set()   # absolute line indexes in `lines` (outer structs / unmoved inner structs)
    group_nested_pub = {}      # (gi, ded index) -> True for members of moved structs
    copies = {g: [] for g in range(len(groups))}
    inner_alias = {g: [] for g in range(len(groups))}
    outer_alias = {g: [] for g in range(len(groups))}
    need_container = {g: False for g in range(len(groups))}

    def loc(d):
        return owner.get(id(d), -1)

    for g, (bare, calls, qual) in info.items():
        # Inner names (bare inside the struct scope).
        for n in sorted(bare):
            if n in inner_by:
                d = inner_by[n]
                if loc(d) == g:
                    continue
                need_container[g] = True
                inner_alias[g].append(n)
                if loc(d) == -1:
                    inner_pub.add(n)
                else:
                    alias_needed.add(n)
                    alias_pub.add(n)
            elif n == cname:
                need_container[g] = True
        # Outer names.
        pending = sorted(n for n in bare if n in outer_by and n not in inner_by and n != cname)
        seen = set()
        while pending:
            n = pending.pop()
            if n in seen:
                continue
            seen.add(n)
            d = outer_by[n]
            text = '\n'.join(lines[d.decl_line:d.end])
            if is_copyable(d, text):
                copies[g].append(d)
                for ident in rich_tokens(text.split('=', 1)[1])[0]:
                    if ident in outer_by and ident not in seen and ident != cname:
                        pending.append(ident)
                continue
            if d.kind == 'var':
                raise SystemExit(f'group {g} uses outer var {n}; handle by hand')
            outer_alias[g].append(n)
            outer_pub.add(n)
        # Methods called on the container from a group file.
        for n in set(calls) | {q for (p, q) in qual if p == cname}:
            d = inner_by.get(n)
            if d is None:
                continue
            if loc(d) == -1:
                inner_pub.add(n)
            elif loc(d) != g:
                alias_needed.add(n)
                alias_pub.add(n)
            else:
                # own group: still reached through the container alias by self.n()
                alias_needed.add(n)
                alias_pub.add(n)
    # Remaining container/outer code reaching moved decls.
    for bare, calls, qual in (info_c, info_o):
        for n in set(bare) | set(calls) | {q for (p, q) in qual if p == cname}:
            d = inner_by.get(n)
            if d is not None and loc(d) != -1:
                if n in bare and (bare is info_o[0]):
                    continue  # outer bare names don't see container members
                alias_needed.add(n)
    for d in moved:
        if d.pub:
            alias_needed.add(d.name)
            alias_pub.add(d.name)

    # Members of structs reached across the boundary.
    all_texts = {('g', g): info[g] for g in info}
    all_texts[('c',)] = info_c
    all_texts[('o',)] = info_o
    for d in outer:
        if d is C or d.kind not in ('const', 'var'):
            continue
        for idx, n, pub in nested_decls(lines, d):
            if pub:
                continue
            if any(n in calls or (d.name, n) in qual for key, (b, calls, qual) in all_texts.items() if key[0] == 'g'):
                nested_pub_lines.add(idx)
    for d in inner:
        if d.kind not in ('const', 'var'):
            continue
        here = loc(d)
        for idx, n, pub in nested_decls(ded, d):
            if pub:
                continue
            for key, (b, calls, qual) in all_texts.items():
                where = key[1] if key[0] == 'g' else -1
                if where == here:
                    continue
                if n in calls or (d.name, n) in qual:
                    if here == -1:
                        nested_pub_lines.add(idx + off)
                    else:
                        group_nested_pub[(here, idx)] = True

    # Import identifiers.
    taken = set(outer_by) | set(inner_by)
    for g in info:
        taken |= info[g][0]
    idents = []
    for g in groups:
        if ':' in g[0]:
            g[0], ident = g[0].split(':', 1)
        else:
            ident = os.path.splitext(os.path.basename(g[0]))[0]
        if ident in taken:
            raise SystemExit(f'group ident {ident} collides')
        idents.append(ident)
    mod_ident = parent_stem + '_mod'

    for g, (gpath, gdoc, _) in enumerate(groups):
        gdir = os.path.dirname(gpath)
        out = []
        for dl in gdoc.split('\\n') if gdoc else []:
            out.append('//! ' + dl)
        if out:
            out.append('')
        for d in sorted(copies[g], key=lambda d: d.decl_line):
            out.append(rewrite_import_paths(re.sub(r'^pub\s+', '', '\n'.join(lines[d.decl_line:d.end])), parent_dir, gdir))
        rel = os.path.relpath(parent, gdir)
        if outer_alias[g]:
            out.append(f'const {mod_ident} = @import("{rel}");')
            out.append(f'const {cname} = {mod_ident}.{cname};')
            for n in sorted(outer_alias[g], key=lambda n: outer_by[n].decl_line):
                out.append(f'const {n} = {mod_ident}.{n};')
        elif need_container[g]:
            out.append(f'const {cname} = @import("{rel}").{cname};')
        for n in sorted(set(inner_alias[g]), key=lambda n: inner_by[n].decl_line):
            out.append(f'const {n} = {cname}.{n};')
        out.append('')
        mine = [d for d in moved if owner[id(d)] == g]
        for i, d in enumerate(mine):
            tl = list(ded[d.start:d.end])
            r = d.decl_line - d.start
            if not d.pub:
                tl[r] = PUB(tl[r])
            for k in range(len(tl)):
                if group_nested_pub.get((g, d.start + k)):
                    tl[k] = PUB(tl[k])
            out.append(rewrite_import_paths('\n'.join(tl), parent_dir, gdir))
            if i + 1 < len(mine):
                out.append('')
        if os.path.exists(gpath):
            raise SystemExit(f'{gpath} exists')
        os.makedirs(gdir or '.', exist_ok=True)
        open(gpath, 'w').write('\n'.join(out).rstrip('\n') + '\n')

    new = list(lines)
    for n in outer_pub:
        d = outer_by[n]
        if not d.pub:
            new[d.decl_line] = PUB(new[d.decl_line])
    for n in inner_pub:
        d = inner_by[n]
        if not d.pub:
            new[d.decl_line + off] = PUB(new[d.decl_line + off])
    for idx in nested_pub_lines:
        new[idx] = PUB(new[idx])
    remove = [False] * len(new)
    insert = {}
    first = {}
    for d in moved:
        first.setdefault(owner[id(d)], d)
    for g, d in first.items():
        block = []
        for m in moved:
            if owner[id(m)] == g and m.name in alias_needed:
                pub = 'pub ' if (m.pub or m.name in alias_pub) else ''
                block.append(f'    {pub}const {m.name} = {idents[g]}.{m.name};')
        insert[d.start + off] = block
    for d in moved:
        for k in range(d.start, d.end):
            remove[k + off] = True
        nxt = d.end + off
        if nxt < body_end and new[nxt].strip() == '' and (d.start + off) not in insert:
            remove[nxt] = True
    result = []
    for k, line in enumerate(new):
        if k in insert:
            if insert[k]:
                if result and result[-1].strip() != '':
                    result.append('')
                result.extend(insert[k])
        if not remove[k]:
            result.append(line)
    # Group imports after the last top-level @import before the container.
    cpos = next(i for i, l in enumerate(result) if re.match(r'^(pub\s+)?const\s+' + cname + r'\s*=\s*struct', l))
    last = max(i for i in range(cpos) if re.match(r'^(pub )?const \w+ = @import\(', result[i]))
    imports = [f'const {idents[g]} = @import("{os.path.relpath(groups[g][0], parent_dir)}");' for g in range(len(groups))]
    result[last + 1:last + 1] = imports
    text = '\n'.join(result)
    text = re.sub(r'\n{3,}', '\n\n', text)
    open(parent, 'w').write(text.rstrip('\n') + '\n')
    for g in range(len(groups)):
        print(f'{groups[g][0]}: {len([d for d in moved if owner[id(d)] == g])} decls as {idents[g]}')


if __name__ == '__main__':
    main()
