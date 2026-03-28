# Knowledge Bank Index Format

## Overview

The `.knowledge-bank/INDEX.md` file is the master index for all knowledge entries.
It uses a grep-friendly single-line comment format that scales to thousands of entries
with O(1) lookup time (using `grep`).

## Entry Format

Each entry is exactly one line:

```
<!-- KB: id=<NNNN> date=<YYYY-MM-DD> category=<category> tags=<tag1,tag2> title=<Title Text> file=<relative/path.md> -->
```

### Field Specifications

| Field      | Type   | Format                              | Example                              |
|------------|--------|-------------------------------------|--------------------------------------|
| `id`       | string | 4-digit zero-padded number          | `0042`                               |
| `date`     | string | ISO date YYYY-MM-DD                 | `2026-03-28`                         |
| `category` | string | One of the valid categories         | `learnings`                          |
| `tags`     | string | Comma-separated, no spaces          | `auth,jwt,security`                  |
| `title`    | string | Plain text, no quotes needed        | `JWT Token Expiry Handling`          |
| `file`     | string | Path relative to `.knowledge-bank/` | `learnings/2026-03/2026-03-28-*.md` |

### Valid Categories

- `adr` — Architecture Decision Records
- `learnings` — Lessons learned, discoveries, gotchas
- `decisions` — Technical decisions (lighter-weight than ADRs)
- `context` — Background info, domain knowledge
- `sessions` — End-of-session summaries

## Search Patterns

```bash
# All entries for a category
grep 'category=adr' .knowledge-bank/INDEX.md

# Find by tag
grep 'tags=.*auth' .knowledge-bank/INDEX.md

# Case-insensitive title search
grep -i 'title=.*cache' .knowledge-bank/INDEX.md

# Entries from a specific month
grep 'date=2026-03' .knowledge-bank/INDEX.md

# Most recent 20 entries
tail -20 .knowledge-bank/INDEX.md | grep '^<!-- KB:'

# Combined: learnings tagged with "database"
grep 'category=learnings' .knowledge-bank/INDEX.md | grep 'tags=.*database'
```

## Reading a Specific Entry

After finding an entry in the index, extract the `file=` field and read it:

```
file=learnings/2026-03/2026-03-28-jwt-token-expiry.md
→ Read: .knowledge-bank/learnings/2026-03/2026-03-28-jwt-token-expiry.md
```

## Category INDEX.md Files

Each category directory also has its own `INDEX.md` with entries scoped to that category.
This allows targeted searches without parsing the master index:

```bash
grep 'title=.*postgres' .knowledge-bank/adr/INDEX.md
```

## Adding an Entry

When appending to INDEX.md, always use `>>` (append) not `>` (overwrite):

```bash
echo '<!-- KB: id=0043 date=2026-03-28 category=learnings tags=perf,db title=Query Caching Pattern file=learnings/2026-03/2026-03-28-query-caching-pattern.md -->' >> .knowledge-bank/INDEX.md
echo '<!-- KB: id=0043 date=2026-03-28 category=learnings tags=perf,db title=Query Caching Pattern file=learnings/2026-03/2026-03-28-query-caching-pattern.md -->' >> .knowledge-bank/learnings/INDEX.md
```

## Scalability Notes

- The index format is designed so that `grep` runs in O(n) over the index file,
  not O(n) over the file tree. With 10,000 entries the INDEX.md will be ~1–2 MB —
  grep runs in milliseconds.
- Individual files are never scanned unless explicitly requested.
- Category sub-indexes reduce the grep set further for category-filtered queries.
- Yearly archiving is not needed — the flat append-only format handles large volumes well.
