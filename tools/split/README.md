# Splitting large files

Scripts that split a big source file by concern while moving its code verbatim,
and check afterwards that nothing was lost. The conventions they follow are in
the root `AGENTS.md` ("Split files"). Run everything from the repository root,
on a clean tree, one file per commit, so `git diff` and `git checkout` undo a
bad run.

| Script | Does |
|---|---|
| `zoutline.py FILE [--in NAME] [--min N]` | lists a Zig file's declarations (or a container's members) with line ranges and sizes |
| `zsplit.py SPEC` | moves top-level declarations into group files; the parent keeps one alias per method |
| `znested.py SPEC` | the same for the methods of a nested `pub const Name = struct { ... }` |
| `zarms.py SPEC` | moves arms of a function's top-level `switch` into sub-handlers in group files |
| `zhoist.py PARENT NAME NEWFILE` | turns a nested struct into its own file-struct |
| `zverify.py REV PARENT GROUP...` | checks a Zig split against the parent at `REV` |
| `coutline.py FILE` | lists a C/C++ file's definitions with the file's own functions each calls |
| `csplit.py` | helpers for the short per-file script that splits a C or C++ file |
| `cverify.py ORIGINAL NEW...` | checks a C/C++ split line by line (`ORIGINAL` may be `REV:path`) |

## Zig

1. `python3 tools/split/zoutline.py src/Dock.zig --min 20` and read the file's
   own comments to find groups of declarations that belong together: what one
   concern needs, what only tests use. Aim for files of a few hundred lines.
2. Write a spec: the parent, then per group its path, a one-line `//!` doc and
   selectors (names, regexes or line ranges of the original). The script's
   docstring has the format; `examples/` holds specs used on this tree (their
   line numbers fit the files as they were before those splits).
3. Run the script. It prints how the parent imports each group. Group files
   import what they use; `var`s stay in the parent and are referenced as
   `parent.name`; private declarations used across files become `pub`.
4. `zig fmt` the new files, then `zverify.py HEAD PARENT GROUP...`: it should
   report nothing missing and add only imports and aliases.
5. Build Debug and `-Doptimize=ReleaseSafe` and run `zig build test`. If moved
   code holds translated strings, run `zig build i18n-extract` (the catalogs'
   source references move with it); if the parent is in `po/lint-files`, list
   the new files there too. Update the file lists in `AGENTS.md` and
   `docs/agent-notes/map.md` when a new host or prefix appears.

Things the scripts leave to you: a moved declaration that uses `@This()` (it
warns), comments between declarations that describe a whole section (they go
with the declaration below them), and anything outside `src/` that names a
moved function by file.

## C and C++

There is no spec: a C split is a short script that reads the original,
`expect`s the lines it cuts at, and writes the private header and the parts
from line ranges, renaming what the parts now share
(`examples/scene_output_split.py`, built on `csplit.py`).

1. `python3 tools/split/coutline.py src/scene_output.c` shows each function,
   whether it is static, and what it calls. Cut where few calls cross.
2. Structs and small helpers called per item go to `NAME_internal.h` (helpers
   as `static inline`); larger functions called across parts lose `static` and
   take the file's prefix; state stays `static` in the one part that uses it.
   C++ shares state as `inline` variables in a namespace instead.
3. Run the script, then `cverify.py REV:src/scene_output.c src/scene_output*.c
   src/scene_output_internal.h`: only the edits you meant should remain.
4. List the parts in the build (`build/support.zig`, `build/tests.zig`), make
   fixtures that `#include` the .c include every part, and build with the
   file's usual flags (most use `-Werror`), Debug and ReleaseSafe, and with
   `-Ddamage-audit=true` for the rendering core.
