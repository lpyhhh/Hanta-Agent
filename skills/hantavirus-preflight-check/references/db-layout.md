# DB layout

The preflight step only ensures that `<WORKDIR>/DB/` exists.

It does not:
- download any database
- validate database completeness
- inspect Kraken2 or Bowtie index contents

Expected top-level layout:

```text
<WORKDIR>/DB/
  kraken2/
  bowtie/
```

If `DB/` is missing, preflight creates an empty `DB/` directory and returns
status `db_missing` so the user can populate it manually.
