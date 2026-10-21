# Plan: shipping UI languages

Status: implementation and draft catalogs, 2026-10-20. L0 and the i18n
prerequisites are implemented; all five catalogs are machine drafts. Native
review and approval of the screenshot findings remain release gates. See
[po/README.md](../../po/README.md) for the glossary and review status.

Scope: ship real translations of RediWM's own UI for the common languages,
for now Spanish, Brazilian Portuguese, German, French and Russian. It builds on [i18n.md](i18n.md), which provides the
machinery (`i18n` module, `tr`/`trc`/`trn`/`fmt`, `.po` catalogs, `qps`
pseudo-locale, extraction and checks) and ends where this plan starts: "adding
actual languages". This plan covers what a language needs beyond a `.po`
file, the order to ship them in, and how a translation is judged ready.

## Where we are

* `src/i18n`, `tools/i18n.zig`, the PO template and five catalogs now exist.
  The shell, Control Center and app clients use the compiled lookup API.
  Draft entries remain fuzzy and fall back to English until reviewed.
* The original survey estimated about 1,000 strings. The implemented
  template contains 1,879 messages, including app clients, keybinding
  descriptions and Control Center search keywords; `i18n-check` reports
  current coverage.
* Dead keys and compose work in every text field since 2026-10-08
  (`ui/compose.zig`, `tests/dead_keys.py`).
* **Fonts are not a blocker for the first languages.** Bundled Manrope
  (`assets/fonts/Manrope-VariableFont_wght.ttf`) has every letter of German,
  French, Spanish, Portuguese, Italian, Polish, Czech, Turkish, Romanian,
  Russian, Ukrainian, Greek and Vietnamese, plus `…`, `–`, `—`, curly quotes,
  U+00A0 and U+2011. It lacks **U+202F** (narrow no-break space, which French
  typesetting puts before `;:!?` and inside `« »`). This machine has no CJK
  font installed (`fc-list :lang=ja` is empty).

The following pre-implementation findings motivated L0. Their code excerpts
and line references describe the original state; the implementation record
below records the fixes and remaining review gates:

* **Case-insensitive matching is ASCII-only.** Start menu search lowercases
  with `std.ascii.lowerString` (`start_menu/search.zig:91,143`), Control
  Center search uses `std.ascii.eqlIgnoreCase` (`control_center/search_index.zig:147,164`),
  and the Files filter uses `std.ascii.indexOfIgnoreCase`
  (`files/app_listing.zig:280`). Typing `терм` does not find `Терминал`, and
  `camara` does not find `Cámara`.
* **Files sorts names by raw bytes.** `lessThan` ends in
  `std.mem.order(u8, a.text(), b.text())` (`files/app_listing.zig:306`), so it
  is case-sensitive (`Zebra` before `apple`), and `Äpfel`, `Élan` and every
  Cyrillic name sort after `z`. `files/worker.zig:627` and
  `files/associations.zig:169` use `std.ascii.lessThanIgnoreCase`, which
  only folds ASCII.
* **The calendar is English regardless of locale.** Month names are a
  literal array (`calendar.zig:192`), and the date heading is
  `strftime("%A, %B %-d, %Y")` in the compositor's C locale
  (`calendar.zig:148`). The taskbar clock already formats with a private
  `locale_t` for `[region] formats` (`taskbar/clock.zig:42`).
* **Two more places read the process locale, not `[region] language`:**
  besides the start menu's `Locale.fromEnv` (i18n.md Phase 0), the polkit
  agent registers with `LC_ALL`/`LC_MESSAGES`/`LANG` from its own
  environment (`polkit/agent.zig:83`). polkitd localises the action
  message from that, so a German UI would still show the English polkit
  message.
* **The language picker lists only installed glibc locales** (`locale -a`,
  filtered through `newlocale`, `control_center/sections/region.zig:116`),
  labelled with glibc's English language name (`localeLabel`). On Arch-family
  systems a language nobody uncommented in `/etc/locale.gen` cannot be
  chosen, and nothing shows which languages RediWM itself is translated
  into.
* **Widget text is single-line and ellipsized** (`ui/text.zig`
  `fitWithEllipsis`); the few hand-wrapped paragraphs break at ASCII spaces
  only (`control_center/sections/printers.zig` `wrapLabels`). That is fine
  for every language in this plan, but German compounds have no space to
  break at, so long ones will ellipsize where English wrapped.
* **Keyboard shortcuts with a Cyrillic layout.** `config/keymap.zig`
  `bindingSyms` falls back to layout 0's keysyms when the active layout
  matches no binding, so the usual `us,ru` setup keeps Super+letter
  shortcuts. A keymap with only `ru` (or `ua`) has no Latin layout to fall
  back to, so letter bindings never match. Needs checking in a nested session
  before Russian ships.

## Goals and non-goals

Goals:

* Five languages that read as written by a native speaker, not as a word
  substitution, on every surface RediWM draws: shell, Control Center, lock
  screen, polkit dialog, greeter, Files, Images, PDF, Editor, share picker.
* Search, sorting and dates behave correctly in those languages.
* A repeatable per-language process, so the ninth language costs only
  translation and review.
* No cost for English and no per-frame cost (i18n.md goals stand).

Non-goals:

* **CJK (Chinese, Japanese, Korean).** Displaying them needs a fallback font
  dependency (none is bundled) and line breaking without spaces; using them
  needs an input method in the shell's own fields, which does not exist
  (i18n.md Phase 0). A separate plan if wanted.
* **Right-to-left languages**, as in i18n.md.
* Translating the wiki, `README.md`, man pages, IPC, logs or `rediwm-msg`
  output.
* Translating text from other programs (NetworkManager, bluez, logind
  errors, notification bodies).

## Languages

| Language | Catalog | Resolves from | Plural family | Length vs English |
|---|---|---|---|---|
| Spanish | `es` | `es_*` | one (n=1) / other | +15–30% |
| Brazilian Portuguese | `pt_BR` | `pt_BR`, `pt` | one (0, 1) / other | +15–30% |
| German | `de` | `de_*` | one (n=1) / other | +30–35% |
| French | `fr` | `fr_*` | one (0, 1) / other | +15–25% |
| Russian | `ru` | `ru_*` | one / few / many | +20–30% |

Later, only on request or when a contributor offers: Italian (`it`),
Ukrainian (`uk`), Polish (`pl`), Dutch (`nl`), Turkish (`tr`), Czech (`cs`),
Swedish (`sv`), Romanian (`ro`). The fonts already cover them.

Plural rules needed in the i18n.md rule table (CLDR, integer counts only):

* **one/other, n = 1**: `es`, `de`. CLDR's `many` for exact millions in
  `es` is ignored, as i18n.md decided.
* **one/other, n = 0 or 1**: `fr`, `pt_BR`.
* **East Slavic** (`ru`): one if `n%10 == 1 and n%100 != 11`; few if
  `n%10` is 2–4 and `n%100` is not 12–14; else many.

Later languages reuse these (`it`, `nl`, `sv`, `tr` are n = 1; `uk` is East
Slavic) or add one function each (Polish: few as East Slavic but 21 is
"many"; Czech: one/few/other).

Notes per language, for the glossary and review:

* **German.** Long compounds ("Bildschirmsperre", "Tastenkombinationen")
  stress fixed widths more than the `qps` expansion does, because they
  ellipsize as one unit. Formal "Sie" or informal "du" is a decision (D3).
* **French.** Space before `:;!?` and inside `« »`. Catalogs use U+00A0
  (Manrope has it); `i18n-check` rewrites or rejects U+202F, which would fall
  back to another font. Infinitive for buttons ("Annuler", "Enregistrer").
* **Spanish, Portuguese.** As in i18n.md: neutral `es` (no voseo), `pt_BR`
  serves `pt` until a `pt_PT` catalog exists.
* **Russian.** Three plural forms, so every count string must be `trn`
  (i18n.md Phase 3/4 converts the `if (n == 1) "" else "s"` sites). Search
  folds `ё` to `е`.
* **Turkish** (later). Dotted/dotless i: case folding must map `I`↔`ı` and
  `İ`↔`i` when the UI language is Turkish, and the ASCII mapping otherwise.

## Design

### Search folding: `ui/fold.zig`

A small allocation-free fold for matching, used by the start menu, Control
Center search, the Files filter and any other substring search:

* Simple Unicode case folding plus diacritic removal for Latin (Latin-1
  Supplement, Extended-A/B), Greek and Cyrillic, writing into a caller
  buffer. Extras that decomposition misses: `ł`→`l`, `ø`→`o`, `ß`→`ss`,
  `ё`→`е`, `æ`→`ae`, `œ`→`oe`. Other scripts pass through unchanged.
* Tables generated at build time from the Unicode data files by a
  `tools/` program, checked in (a few KiB), so the build needs no network.
* Turkish rules only when the resolved UI language is `tr`.
* The query and every candidate go through the same fold, so `camara`,
  `Cámara` and `CÁMARA` all match `Cámara`, and highlighting maps folded
  offsets back to the original text.

Control Center search entries get translated titles and keywords through
`tr`. The English keywords stay searchable as well, because users copy
setting names from English guides.

### Sorting names in Files

Names sort by the collation of `[region] formats` (`LC_COLLATE`), with a
`newlocale(LC_COLLATE_MASK, ...)` owned by the worker, never `setlocale`
(as `region.zig` already does for numbers). glibc then gets `Äpfel` beside
`Apfel` in German and `ё` after `е` in Russian. Keep the folders-first rule
and the existing size and date orders. Measure a 100,000-entry folder
before and after; if `strcoll_l` is too slow, precompute `strxfrm_l` keys
once per listing. Natural number order ("file2" before "file10") is a
separate question and not part of this.

### Dates and calendar

The calendar takes month and weekday names from the `[region] formats`
locale (`nl_langinfo_l(MON_1…, ABDAY_1…)`) through the same private
`locale_t` pattern as `taskbar/clock.zig`, and drops the `months` array. The
long heading pattern (`"%A, %B %-d, %Y"`) becomes a `trc("date", ...)` string,
so each catalog supplies its word order ("%A, %-d de %B de %Y") while the
names follow `formats`. Files' modified column already uses a fixed ISO date
and `prefs.timeFormat()`; leave it.

### One resolver for every locale consumer

The shared resolver from i18n.md replaces the polkit agent's environment
lookup and the start menu's `Locale.fromEnv`, so the polkit action message,
desktop-entry `Name[xx]` and RediWM's own text all follow
`[region] language`. A language change re-registers the polkit agent.

### Language picker

The Region section's Language list:

* Shows each language in its own name ("Deutsch", "Русский", "Español"),
  from a small table compiled with the catalogs, with the glibc name as a
  subtitle.
* Lists languages RediWM is translated into first, then the other installed
  locales with "RediWM stays in English" next to them.
* Offers a translated language even when its glibc locale is not generated,
  with a hint on how to enable it (D4). The UI catalog does not need the glibc
  locale, but apps launched with that `LANG` and the calendar names do.

### Our own data files

* `data/*.desktop` (Files, Editor, Images, PDF, Monitor, Theme, Transfers
  and the session entries): `Name[xx]`, `GenericName[xx]`, `Comment[xx]`,
  `Keywords[xx]` generated from the same `.po` files at build time by
  `tools/i18n.zig`, so translators touch one file.
* `data/org.rediwm.accounts.policy`: `<message xml:lang="xx">` entries
  generated the same way; polkitd picks them using the locale the agent
  registered.

### Translation workflow

* **Glossary.** `po/README.md` holds the contributor guide and, per
  language, about 60 fixed terms (window, workspace, dock, taskbar, tile,
  lock screen, Control Center, Files, …) plus tone (formal or informal
  address, button mood). Product names ("RediWM") are never translated; the
  app names "Files", "Images", "Editor" are translated as ordinary words
  (D5).
* **Drafting and review** follow D1. A string marked `#, fuzzy` is never
  shown, so an unreviewed draft falls back to English.
* **Screenshots for reviewers.** `scripts/i18n-screens.py <lang>` starts a
  headless session with `[region] language` set (scratch `XDG_STATE_HOME`),
  walks every panel, Control Center section, dialog and app window, and
  writes IPC screenshots to one folder. Reviewers judge text in place
  without building RediWM, and the same walk asserts
  `text_width <= box.w` (the field i18n.md Phase 1 adds) for every labelled
  widget in that language.
* **Context for translators.** `trc` contexts and `// i18n:` comments above
  ambiguous strings are extracted into the `.pot` as `#.` notes ("Open" the
  verb vs. "Open" the state).

### When a language ships

A catalog is listed as translated in the picker only when:

1. `zig build i18n-check` passes (no stale entries, placeholders and plural
   counts match).
2. Every string of the shell, Control Center, lock screen, polkit dialog and
   greeter is translated and not fuzzy. App clients may lag; missing
   strings fall back to English.
3. The screenshot walk passes the overflow assertion, and every ellipsized
   label has been looked at and either shortened in the catalog or given room
   in the layout.
4. A native speaker has reviewed the screenshots (D1). The status table
   in `po/README.md` records each language's coverage and review state.

Below that bar a catalog is still compiled in and can be chosen through the
config key, so contributors can test it, but the picker marks it
"incomplete".

## Phases

**L0: language correctness, independent of catalogs.** Can start now, in
parallel with i18n.md Phase 1, and fixes behaviour English users with
non-English names already hit. `ui/fold.zig` and its use in start menu,
Control Center and Files search; Files collation; calendar names from
`formats`; polkit agent and start menu on the shared resolver (or, before
the resolver exists, on `[region] language` directly). Check Super+letter
bindings with a `ru`-only keymap in a nested session and fix if needed.
Unit tests for folding and collation order (`zig build test`); extend
`tests/calendar_popup.py` with a German `formats`.

**L1: first catalogs, Spanish and Brazilian Portuguese.** Needs i18n.md
Phases 1–3. Plural families for the five languages in the rule table; `po/README.md`
with glossary and status table; `scripts/i18n-screens.py`; desktop file and
polkit policy generation; the language picker. Ship `es` and `pt_BR` through
the bar above. These two come first because they were already the intended
first languages and need the fewest new rules.

**L2: German and French.** Latin script, the longest strings. Expect
layout fixes from German that the `qps` pass missed (single long words);
add a long-unbroken-word variant to the `qps` generator if it finds real
problems. French space handling in `i18n-check`.

**L3: Russian.** The three-form plural family gets its first real use: run `i18n-check` and review every `trn` string with the
reviewer, since a missing `few` form is invisible in English. Cyrillic
search and sorting were fixed in L0; check them again with the real
catalog.

**L4: app clients catch up.** As i18n.md Phase 4 converts Files, Images,
PDF, Editor and the share picker, each catalog gains those strings. A
language is "complete" when the apps are too.

**L5: more languages on request.** Each one is a `.po`, a glossary section, a
review and, for Turkish, the folding special case.

## Testing

* `zig build test`: plural rules for every family above with the CLDR
  example numbers (ru: 1, 2, 5, 11, 12, 21, 22, 25, 111;
  fr/pt_BR: 0, 1, 2); fold tables (case, diacritics, the extra
  letters, Turkish); collation of a mixed name list under `de_DE`,
  `ru_RU` and `C`.
* Integration: the screenshot walk in every shipped language runs the
  overflow assertion; `tests/dead_keys.py` gains a German (`de` nodeadkeys
  vs. deadkeys) and a French layout case; existing English suites stay
  unchanged.
* Before calling a language done: build Debug and ReleaseSafe, check
  ReleaseSafe binary size against the catalog estimate from i18n.md
  Phase 1, and confirm no test hook leaked (`strings`).

## Risks

* **Translation quality.** A fluent-looking but wrong translation is worse
  than English, especially in the lock screen, polkit and power dialogs,
  where a mistranslated button can mislead the user into the wrong action.
  The review gate and in-place screenshots are the mitigation; security
  dialogs get a second look.
* **Drift.** Every English change marks strings fuzzy in all five
  catalogs. With five languages, a UI-heavy commit can drop several below
  the "translated" bar. The status table makes that visible; i18n-check does
  not fail the build for fuzzy entries, only for structural errors.
* **Reviewer availability.** Native reviewers for five languages may not be
  found at once. Shipping order lets the first languages proceed while
  others wait as "incomplete".
* **Width.** German and Russian strings may need layout changes in places
  the `qps` pass judged fine; L2 budgets time for that.
* **Distribution of locales.** On Arch-family systems the glibc locale must be
  generated; without it apps launched from RediWM stay in English while
  RediWM itself is translated. D4 decides how much RediWM helps.

## Decisions

1. **D1: who translates.** (a) Only native-speaker contributions by pull
   request, as i18n.md decided; slow, possibly years for five languages.
   (b) Machine-drafted catalogs (Claude), committed as `#, fuzzy` and so
   never shown, then reviewed and un-fuzzied by a native speaker using the
   screenshot walk. **Recommended: (b)**: it keeps i18n.md's
   contribution-by-PR model, and reviewers correct a draft in place
   instead of starting from 1,000 empty strings.
2. **D2: first languages.** Decided 2026-10-20: Spanish, Brazilian
   Portuguese, German, French and Russian, in the order L1–L3. Others wait
   for a request or a contributor.
3. **D3: German and other formal/informal address.** Recommended: informal
   "du" for German (confirm with the reviewer), "vous" for
   French, "tú" for Spanish, "você" for Portuguese, "вы" for Russian; recorded in the glossary.
4. **D4: uninstalled locales.** (a) Show translated languages with a
   distro-neutral hint ("Enable `de_DE.UTF-8` in your system's locale
   settings"). (b) Enable the locale through the accounts helper
   (`/etc/locale.gen` + `locale-gen` on Arch, `locale-gen` package on
   Debian, langpacks on Fedora): distro-specific root code. **Recommended:
   (a)** for now; revisit with the printers-style failure ladder if users
   ask.
5. **D5: app names.** Recommended: translate "Files", "Images", "Editor",
   "Control Center" as ordinary words (Dateien, Imágenes, Редактор), keep
   "RediWM" as is. Alternative: keep all as brand names, which reads oddly
   next to translated menus.
6. **D6: search keywords in two languages.** Recommended: translated
   keywords plus the English ones in Control Center search, as above.
   Alternative: translated only, smaller index, but English guides stop
   working as search terms.

## Implementation record (2026-10-20)

L0 uses generated Unicode folding (with original byte ranges for highlights),
worker-owned collation keys, private calendar locales and the shared language
resolver. The start-menu cache rescans on language changes. Polkit registration
changes after outstanding authentication requests finish. Cyrillic-only
keymaps retain modifier-letter shortcuts without changing client text.

L1–L4 have the catalog/compiler/extraction/check/lint infrastructure, named
formatting and plural rules, five complete fuzzy drafts, catalog-aware language
picker, generated desktop/polkit metadata, and the isolated screenshot/review
walk. Layout changes give navigation and buttons room and wrap Region
paragraphs, including long words. No catalog is declared native-reviewed.
The screenshot and manual security-screen review gates still apply; app captures
need visual review because client apps do not expose shell widget measurements.

Implementation uses D1(b), D3's proposed tones, D4(a), D5 translated app names
and D6 bilingual search keywords. D2 is unchanged. These are drafting defaults
for native reviewers, not claims that linguistic review has happened. L5 remains
future work on request. The source of current message counts is `i18n-check`.
