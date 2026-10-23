#!/usr/bin/env python3
"""Move top-level declarations of a Zig file into sibling "group" files.

    zsplit.py SPEC

Spec file format (see examples/dock.spec):

    parent src/Dock.zig
    group src/dock/paint.zig Painting the dock: rasters, icons and badges.
      paint paintItem 120-340
    group src/dock/hover.zig Hover and tooltip tracking.
      hover.*            # regex over decl names
      test:"dock hover"  # a test block by name prefix

Names select top-level decls; N-M selects every top-level decl starting in that
line range (1-based, of the original parent). The text after a group's path
becomes its `//!` doc (a literal `\\n` starts a new line); `path:ident` forces
the name the parent imports the group as. The parent keeps one alias line per
moved declaration (pub when the original was pub or another file needs it),
right where the group's first declaration was. Group files import the parent
for the non-copyable names they use; `var`s stay in the parent and are
referenced as `parent.name`. A group of tests only is reached through a
`test { _ = @import(...); }` block.
"""
import os
import re
import sys

IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
DECL_RE = re.compile(
    r'^(?P<pub>pub\s+)?(?:(?:export|extern)(?:\s+"[^"]*")?\s+)?(?:(?:inline|noinline)\s+)?'
    r'(?:threadlocal\s+)?(?P<kind>fn|const|var)\s+(?P<name>@"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)')
TEST_RE = re.compile(r'^test\b\s*(?P<name>"[^"]*"|[A-Za-z_][A-Za-z0-9_]*)?')
COMPTIME_RE = re.compile(r'^comptime\s*\{')


def strip_code(line):
    """Returns the line with comments removed and string/char contents blanked."""
    out = []
    j = 0
    n = len(line)
    s = line.lstrip()
    if s.startswith('\\\\'):
        return ''
    while j < n:
        c = line[j]
        if line.startswith('//', j):
            break
        if c == '"':
            out.append('"')
            j += 1
            while j < n:
                if line[j] == '\\':
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
            out.append('"')
            j += 1
            continue
        if c == "'":
            out.append("'")
            j += 1
            while j < n:
                if line[j] == '\\':
                    j += 2
                    continue
                if line[j] == "'":
                    break
                j += 1
            out.append("'")
            j += 1
            continue
        out.append(c)
        j += 1
    return ''.join(out)


class Decl:
    def __init__(self, start, decl_line, end, kind, name, pub, header):
        self.start = start          # index of first line incl. doc comments
        self.decl_line = decl_line  # index of the declaration line
        self.end = end              # exclusive
        self.kind = kind            # fn const var test comptime field
        self.name = name
        self.pub = pub
        self.header = header

    def __repr__(self):
        return f'Decl({self.kind} {self.name} {self.start + 1}-{self.end})'


def parse(lines):
    decls = []
    depth = 0
    cur = None
    doc_start = None
    for idx, line in enumerate(lines):
        stripped = line.strip()
        code = strip_code(line)
        if depth == 0 and cur is None:
            if stripped.startswith('//!'):
                doc_start = None
            elif stripped.startswith('//'):
                if doc_start is None:
                    doc_start = idx
            elif stripped == '':
                doc_start = None
            else:
                m = DECL_RE.match(stripped)
                start = doc_start if doc_start is not None else idx
                doc_start = None
                if m:
                    cur = [start, idx, m.group('kind'), m.group('name'), bool(m.group('pub')), stripped]
                elif TEST_RE.match(stripped):
                    tm = TEST_RE.match(stripped)
                    cur = [start, idx, 'test', 'test:' + (tm.group('name') or ''), False, stripped]
                elif COMPTIME_RE.match(stripped):
                    cur = [start, idx, 'comptime', 'comptime@%d' % idx, False, stripped]
                else:
                    cur = [start, idx, 'field', 'field@%d' % idx, False, stripped]
        for c in code:
            if c in '{([':
                depth += 1
            elif c in '})]':
                depth -= 1
        if cur is not None and depth == 0:
            t = code.rstrip()
            ends = t.endswith(';') or t.endswith('}')
            if cur[2] == 'field':
                ends = ends or t.endswith(',')
            if ends:
                decls.append(Decl(cur[0], cur[1], idx + 1, cur[2], cur[3], cur[4], cur[5]))
                cur = None
    if cur is not None:
        raise SystemExit(f'unterminated declaration at line {cur[1] + 1}: {cur[5]}')
    return decls


def nested_decls(lines, d):
    """(line_idx, name, pub) for declarations directly inside a container decl."""
    out = []
    depth = 0
    for idx in range(d.decl_line, d.end):
        code = strip_code(lines[idx])
        if depth == 1:
            m = DECL_RE.match(lines[idx].strip())
            if m:
                out.append((idx, m.group('name'), bool(m.group('pub'))))
        for c in code:
            if c in '{([':
                depth += 1
            elif c in '})]':
                depth -= 1
    return out


def rich_tokens(text):
    """(bare identifiers, identifiers called as `.name(`, (qualifier, name) pairs)."""
    bare, calls, qualified = set(), set(), set()
    for line in text.split('\n'):
        code = strip_code(line)
        for m in IDENT.finditer(code):
            s, e = m.start(), m.end()
            prev = code[s - 1] if s > 0 else ''
            if prev == '@' or (prev and (prev.isalnum() or prev == '_')):
                continue
            name = m.group(0)
            if prev == '.' and s >= 2 and code[s - 2] == '.':
                prev = ''  # range `a..b`
            if prev != '.':
                bare.add(name)
                continue
            rest = code[e:].lstrip()
            if rest.startswith('('):
                calls.add(name)
            q = re.search(r'([A-Za-z_][A-Za-z0-9_]*)\s*\.$', code[:s])
            if q:
                qualified.add((q.group(1), name))
    return bare, calls, qualified


def import_target(text):
    m = re.search(r'@import\("([^"]+)"\)', text)
    return m.group(1) if m else None


def rewrite_import_paths(text, from_dir, to_dir):
    if os.path.normpath(from_dir) == os.path.normpath(to_dir):
        return text

    def fix(m):
        builtin, p = m.group(1), m.group(2)
        # Module imports ("std", "ui") have no extension; files do.
        if p.startswith('/') or '.' not in os.path.basename(p):
            return m.group(0)
        absp = os.path.normpath(os.path.join(from_dir, p))
        rel = os.path.relpath(absp, to_dir)
        return '@%s("%s")' % (builtin, rel)
    return re.sub(r'@(import|embedFile)\("([^"]+)"\)', fix, text)


def is_copyable(decl, text):
    """A const whose value is an import or a pure path/scoped-log off one."""
    if decl.kind != 'const':
        return False
    body = text.strip()
    m = re.match(r'^(?:pub\s+)?const\s+\w+\s*(?::\s*[^=]+)?=\s*(.*);$', body, re.S)
    if not m:
        return False
    rhs = m.group(1).strip()
    if '\n' in rhs:
        return False
    if rhs.startswith('@import('):
        return True
    if re.match(r'^@This\(\)$', rhs):
        return False
    if re.match(r'^std\.log\.scoped\(\.\w+\)$', rhs):
        return True
    if re.match(r'^@cImport', rhs):
        return False
    # dotted path off another identifier
    if re.match(r'^[A-Za-z_]\w*(\.[A-Za-z_]\w*|\.@"[^"]+")+$', rhs):
        return True
    if re.match(r'^@import\("[^"]+"\)(\.[A-Za-z_]\w*)+$', rhs):
        return True
    return False


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    spec_path = sys.argv[1]
    spec = open(spec_path).read().split('\n')
    parent = None
    groups = []  # (path, doc, selectors)
    for raw in spec:
        line = raw.split('#', 1)[0].rstrip() if not raw.lstrip().startswith('test:') else raw.rstrip()
        if not line.strip():
            continue
        if line.startswith('parent '):
            parent = line.split(None, 1)[1].strip()
        elif line.startswith('group '):
            parts = line.split(None, 2)
            groups.append([parts[1], parts[2] if len(parts) > 2 else '', []])
        else:
            if line.strip().startswith('test:'):
                groups[-1][2].append(line.strip())
            else:
                groups[-1][2].extend(line.split())
    assert parent and groups

    src = open(parent).read()
    lines = src.split('\n')
    decls = parse(lines)
    by_name = {}
    for d in decls:
        if d.kind in ('fn', 'const', 'var'):
            by_name[d.name] = d
    parent_dir = os.path.dirname(parent)
    parent_stem = os.path.splitext(os.path.basename(parent))[0]

    # The parent's self alias (const Dock = @This();)
    self_alias = None
    for d in decls:
        if d.kind == 'const' and re.search(r'=\s*@This\(\)\s*;', '\n'.join(lines[d.decl_line:d.end])):
            self_alias = d.name

    # Assign decls to groups.
    owner = {}
    for gi, (gpath, gdoc, sels) in enumerate(groups):
        for sel in sels:
            matched = []
            rm = re.match(r'^(\d+)-(\d+)$', sel)
            if rm:
                lo, hi = int(rm.group(1)) - 1, int(rm.group(2)) - 1
                matched = [d for d in decls if lo <= d.decl_line <= hi and d.kind not in ('field',)]
            elif sel.startswith('test:'):
                pref = sel[5:]
                matched = [d for d in decls if d.kind == 'test' and d.name[5:].startswith(pref)]
            elif sel in by_name:
                matched = [by_name[sel]]
            else:
                rx = re.compile('^(?:' + sel + ')$')
                matched = [d for d in decls if d.kind in ('fn', 'const', 'var') and rx.match(d.name)]
            if not matched:
                raise SystemExit(f'selector {sel!r} matched nothing')
            for d in matched:
                if d.kind == 'field':
                    raise SystemExit(f'cannot move field {d}')
                if id(d) in owner and owner[id(d)] != gi:
                    raise SystemExit(f'{d} selected by two groups')
                owner[id(d)] = gi

    moved = [d for d in decls if id(d) in owner]
    for d in moved:
        if d.kind == 'var':
            print(f'warning: moving var {d.name}; check references', file=sys.stderr)

    # Identify the import name each group gets in the parent.
    taken = set(by_name) | rich_tokens(src)[0]
    group_ident = []
    for g in groups:
        if ':' in g[0]:
            g[0], forced = g[0].split(':', 1)
            taken.add(forced)
            group_ident.append(forced)
            continue
        gpath = g[0]
        stem = os.path.splitext(os.path.basename(gpath))[0]
        base = stem if stem not in taken else parent_stem.lower() + '_' + stem
        ident = base
        k = 2
        while ident in taken:
            ident = f'{base}{k}'
            k += 1
        taken.add(ident)
        group_ident.append(ident)

    # Parent import identifier used inside group files.
    parent_ident = self_alias or parent_stem
    if not self_alias:
        used_anywhere = set()
        for d in moved:
            used_anywhere |= rich_tokens('\n'.join(lines[d.start:d.end]))[0]
        if parent_ident in by_name or parent_ident in used_anywhere:
            parent_ident = parent_stem + '_mod'

    has_fields = any(d.kind == 'field' for d in decls)
    is_struct_file = bool(self_alias) or has_fields

    def loc(d):
        return owner.get(id(d), -1)

    texts = {-1: '\n'.join('\n'.join(lines[d.start:d.end]) for d in decls if id(d) not in owner)}
    for gi in range(len(groups)):
        texts[gi] = '\n'.join('\n'.join(lines[d.start:d.end]) for d in moved if owner[id(d)] == gi)
    info = {f: rich_tokens(t) for f, t in texts.items()}

    need_pub = set()       # top-level names in the parent that must become pub
    alias_needed = set()   # moved names the parent must alias
    alias_pub_needed = set()
    nested_pub_lines = set()
    copies = {gi: [] for gi in range(len(groups))}
    aliases = {gi: [] for gi in range(len(groups))}
    var_refs = {gi: [] for gi in range(len(groups))}
    needs_parent = {gi: False for gi in range(len(groups))}

    def through_parent(f, name):
        d = by_name[name]
        if loc(d) == -1:
            need_pub.add(name)
        else:
            alias_needed.add(name)
            alias_pub_needed.add(name)

    for f, (bare, calls, qualified) in info.items():
        pending = sorted(n for n in bare if n in by_name and loc(by_name[n]) != f)
        seen = set()
        while pending:
            name = pending.pop()
            if name in seen:
                continue
            seen.add(name)
            d = by_name[name]
            if f == -1:
                alias_needed.add(name)  # parent code using a moved decl
                continue
            text = '\n'.join(lines[d.decl_line:d.end])
            if name == self_alias:
                needs_parent[f] = True
                continue
            if loc(d) == -1 and is_copyable(d, text):
                copies[f].append(d)
                for ident in rich_tokens(text.split('=', 1)[1])[0]:
                    if ident in by_name and ident not in seen and loc(by_name[ident]) != f:
                        pending.append(ident)
                continue
            needs_parent[f] = True
            if d.kind == 'var':
                var_refs[f].append(name)
            else:
                aliases[f].append(name)
            through_parent(f, name)
        if is_struct_file:
            members = set(calls) | {n for (q, n) in qualified if q == self_alias}
            for name in members:
                d = by_name.get(name)
                if d is None or d.kind not in ('fn', 'const', 'var'):
                    continue
                if loc(d) == -1:
                    if f != -1:
                        need_pub.add(name)
                else:
                    alias_needed.add(name)
                    if f != -1:
                        alias_pub_needed.add(name)

    for d in decls:
        if d.kind not in ('const', 'var'):
            continue
        members = nested_decls(lines, d)
        for idx, name, pub in members:
            if pub:
                continue
            for f, (bare, calls, qualified) in info.items():
                if f == loc(d):
                    continue
                if name in calls or (d.name, name) in qualified:
                    nested_pub_lines.add(idx)

    alias_pub = {}
    for d in moved:
        if d.kind in ('fn', 'const', 'var'):
            if d.pub:
                alias_needed.add(d.name)
            alias_pub[d.name] = d.pub or d.name in alias_pub_needed

    group_outputs = []
    for gi, (gpath, gdoc, _) in enumerate(groups):
        mine = [d for d in moved if owner[id(d)] == gi]
        if '@This()' in texts[gi]:
            print(f'warning: @This() in moved code for {gpath}', file=sys.stderr)
        group_outputs.append((gpath, gdoc, mine, copies[gi], aliases[gi], var_refs[gi], needs_parent[gi]))

    # Write group files.
    for gpath, gdoc, mine, copies, aliases, var_refs, needs_parent in group_outputs:
        gdir = os.path.dirname(gpath)
        out = []
        for dl in gdoc.split('\\n') if gdoc else []:
            out.append('//! ' + dl if dl else '//!')
        if out:
            out.append('')
        copies_sorted = sorted(copies, key=lambda d: d.decl_line)
        for d in copies_sorted:
            text = '\n'.join(lines[d.decl_line:d.end])
            text = re.sub(r'^pub\s+', '', text)
            out.append(rewrite_import_paths(text, parent_dir, gdir))
        if needs_parent:
            rel = os.path.relpath(parent, gdir)
            out.append(f'const {parent_ident} = @import("{rel}");')
        for name in sorted(aliases, key=lambda n: by_name[n].decl_line):
            out.append(f'const {name} = {parent_ident}.{name};')
        out.append('')
        for i, d in enumerate(mine):
            text_lines = lines[d.start:d.end]
            # make the decl pub (unless test/comptime)
            rel = d.decl_line - d.start
            text_lines = list(text_lines)
            if d.kind in ('fn', 'const', 'var') and not d.pub:
                text_lines[rel] = re.sub(r'^(\s*)', r'\1pub ', text_lines[rel], count=1)
            for k in range(len(text_lines)):
                if d.start + k in nested_pub_lines:
                    text_lines[k] = re.sub(r'^(\s*)', r'\1pub ', text_lines[k], count=1)
            text = '\n'.join(text_lines)
            text = rewrite_import_paths(text, parent_dir, gdir)
            if var_refs:
                code_vars = set(var_refs)

                def sub_line(line):
                    code = strip_code(line)
                    res = []
                    last = 0
                    for m in IDENT.finditer(code):
                        nm = m.group(0)
                        s = m.start()
                        prev = code[s - 1] if s > 0 else ''
                        if prev == '.' and s >= 2 and code[s - 2] == '.':
                            prev = ''  # range `a..b`
                        if nm in code_vars and prev not in ('.', '@') and not (prev.isalnum() or prev == '_'):
                            res.append(line[last:s])
                            res.append(f'{parent_ident}.{nm}')
                            last = m.end()
                    res.append(line[last:])
                    return ''.join(res)
                text = '\n'.join(sub_line(l) for l in text.split('\n'))
            out.append(text)
            if i + 1 < len(mine):
                out.append('')
        os.makedirs(gdir or '.', exist_ok=True)
        if os.path.exists(gpath):
            raise SystemExit(f'{gpath} exists')
        open(gpath, 'w').write('\n'.join(out).rstrip('\n') + '\n')

    # Rewrite the parent.
    new = list(lines)
    # Make needed decls pub.
    for name in need_pub:
        d = by_name.get(name)
        if d is None or id(d) in owner or d.pub:
            continue
        new[d.decl_line] = re.sub(r'^(\s*)', r'\1pub ', new[d.decl_line], count=1)
    for idx in nested_pub_lines:
        new[idx] = re.sub(r'^(\s*)', r'\1pub ', new[idx], count=1)
    # Replace moved ranges; first decl of each group gets the alias block.
    first_of_group = {}
    for d in moved:
        gi = owner[id(d)]
        if gi not in first_of_group:
            first_of_group[gi] = d
    remove = [False] * len(new)
    insert_at = {}
    for gi, d in first_of_group.items():
        gpath = groups[gi][0]
        rel = os.path.relpath(gpath, parent_dir)
        members = [m for m in moved if owner[id(m)] == gi]
        if any(m.kind == 'test' for m in members) and not any(m.name in alias_needed for m in members if m.kind in ('fn', 'const', 'var')):
            insert_at[d.start] = ['test {', f'    _ = @import("{rel}");', '}']
            continue
        block = [f'const {group_ident[gi]} = @import("{rel}");']
        for md in [m for m in moved if owner[id(m)] == gi]:
            if md.kind in ('fn', 'const', 'var') and md.name in alias_needed:
                pub = 'pub ' if alias_pub[md.name] else ''
                block.append(f'{pub}const {md.name} = {group_ident[gi]}.{md.name};')
        if any(m.kind == 'test' for m in members):
            block += ['test {', f'    _ = {group_ident[gi]};', '}']
        insert_at[d.start] = block
    for d in moved:
        for i in range(d.start, d.end):
            remove[i] = True
        # swallow one blank line after the decl to avoid double blanks
        if d.end < len(new) and new[d.end].strip() == '' and d.start not in insert_at:
            remove[d.end] = True
    result = []
    for i, line in enumerate(new):
        if i in insert_at:
            if result and result[-1].strip() != '':
                result.append('')
            result.extend(insert_at[i])
            if not remove[i]:
                result.append(line)
            continue
        if not remove[i]:
            result.append(line)
    text = '\n'.join(result)
    text = re.sub(r'\n{3,}', '\n\n', text)
    open(parent, 'w').write(text.rstrip('\n') + '\n')
    for gi, ident in enumerate(group_ident):
        print(f'{groups[gi][0]}: {len([d for d in moved if owner[id(d)] == gi])} decls as {ident}')


if __name__ == '__main__':
    main()
