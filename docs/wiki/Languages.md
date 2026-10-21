# Languages

Set `[region] language` for RediWM and newly launched apps, and `[region]
formats` for dates and filename collation. Settings → Region & Language lists
catalog languages in their own names, including languages whose system locale
has not yet been generated. Its hint explains which locale to enable for other
apps. Existing app windows use their launch language until reopened.

Spanish, Brazilian Portuguese, German, French and Russian currently have
complete machine drafts. All entries are fuzzy and fall back to English until
native review; the picker marks these catalogs incomplete. This does not mark
those languages as released or reviewed.

To contribute a new language, copy `po/rediwm.pot` to `po/<tag>.po`, add its
Language/native-name/locale headers, and translate with a PO editor. Preserve
contexts, named placeholders and plural forms. Run:

```sh
zig build i18n-extract
zig build i18n-check i18n-lint
zig build
python3 scripts/i18n-screens.py qps --out /tmp/rediwm-qps-review
```

The build discovers PO files automatically and generates both UI catalogs and
localized desktop/polkit metadata. Use `qps` to stress expanded labels; review
actual translations and security screens before removing fuzzy flags. The
[translation guide](../../po/README.md) contains the glossary, plural examples,
review process and current status. Tests and screenshot options are described
in [TESTING.md](../../TESTING.md#languages-and-locale-correctness).
