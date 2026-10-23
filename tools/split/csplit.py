"""Helpers for the short script that splits one C or C++ file.

A C split is a script per file (examples/scene_output_split.py) rather than a
spec: it reads the original, asserts the lines it cuts at, and writes the
private header and the parts from line ranges of the original, copied verbatim
except where it drops `static` or renames what the parts now share. Plan it
with coutline.py, check it with cverify.py, then build with -Werror.

The convention (AGENTS.md, "Split files"): the public header stays as it was;
`NAME_internal.h` holds the structs and the small per-item helpers as
`static inline` (release builds have no LTO, so a file boundary must not cost
them inlining); other functions shared between the parts lose `static` and
gain the file's prefix; a test fixture that `#include`s the .c includes every
part; the build lists the parts.
"""
import re
import subprocess


class Source:
    """The original file, read from a path or REV:path; line numbers are 1-based."""

    def __init__(self, path, renames=None):
        if ':' in path and not path.startswith('/'):
            text = subprocess.run(['git', 'show', path], capture_output=True, text=True, check=True).stdout
        else:
            text = open(path).read()
        self.lines = text.split('\n')
        self.renames = renames or {}

    def R(self, a, b):
        """Lines a..b, inclusive."""
        return self.lines[a - 1:b]

    def expect(self, n, prefix):
        """Stops the split unless line n starts with `prefix`: the file changed."""
        assert self.lines[n - 1].startswith(prefix), (n, self.lines[n - 1])

    def rename(self, block):
        """Applies the renames to identifiers in code, never in `//` comments;
        `.name` and `->name` (fields) are left alone."""
        out = []
        for line in block:
            code, sep, comment = line.partition('//')
            for old, new in self.renames.items():
                code = re.sub(r'(?<![\w.>])' + old + r'\b', new, code)
            out.append(code + sep + comment)
        return out


def unstatic(block, inline=False):
    """Drops `static` from the block's first definition line (or makes it
    `static inline`, for a helper moving into the private header)."""
    block = list(block)
    i = next(k for k, l in enumerate(block) if l.startswith('static '))
    block[i] = re.sub(r'^static ', 'static inline ' if inline else '', block[i])
    return block


def write(path, lines):
    """Writes the lines with one trailing newline and no runs of blank lines."""
    text = '\n'.join(lines).rstrip('\n') + '\n'
    open(path, 'w').write(re.sub(r'\n{3,}', '\n\n', text))
