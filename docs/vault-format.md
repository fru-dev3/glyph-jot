# Vault format (from Memosa, now shared by Jot)

The on-disk truth. Every other module reads/writes these exact shapes. No DB.

## Directory layout
```
~/Documents/Memosa Vault/
├─ <Domain>/                         # any directory = a domain/folder; nests arbitrarily
│  └─ <Folder>/                      #   e.g. Work/Northwind/Weekly sync/
│     └─ <conversation-slug>/        #   a dir containing meta.json == a conversation
│        ├─ meta.json                #   conversation metadata
│        ├─ transcript.json          #   segments (timestamps + speakers)
│        ├─ transcript.txt           #   derived plaintext (for grep / dumb AI ingestion)
│        ├─ notes.md                 #   summary + decisions + action items (Markdown)
│        └─ audio.m4a                #   original recording (NEVER synced to Drive)
├─ People/<Name>.md                  # one note per person (not a domain)
├─ Accounts/<Name>.md                # one note per account: a company, client (not a domain)
└─ .memosa/                          # app-managed, hidden; fully rebuildable
   ├─ config.json                    # app settings (theme, model policy, vault prefs)
   ├─ index/
   │  ├─ embeddings.jsonl            # one JSON per chunk
   │  ├─ tasks.jsonl                 # derived action-item index (from notes.md)
   │  └─ manifest.json               # path → {hash,mtime} for change detection
   └─ speakers.json                  # cross-meeting voice fingerprints (future)
```

## Identity rules
- A directory is a **conversation** iff it contains `meta.json`. Otherwise it's a **folder**.
- A conversation's canonical id = its vault-relative path, e.g. `Work/Northwind/2026-06-17-acme-insurance-review`.
- Slug = `YYYY-MM-DD-kebab-title`, deduped with `-2`, `-3` on collision.
- `.memosa/` and dotfiles are ignored when walking the tree.
- Top-level `People/` and `Accounts/` hold notes, not conversations, and are not domains.

## meta.json  (schema v1)
```json
{
  "schema": 1,
  "id": "Work/Northwind/2026-06-17-acme-insurance-review",
  "title": "Acme Insurance review",
  "created": "2026-06-17T11:02:00Z",
  "duration_sec": 2520,
  "people": ["Sarah Chen", "Mike Reyes", "Fru"],
  "accounts": ["Northwind"],
  "tags": ["insurance", "home"],
  "suggested": { "people": [], "accounts": [], "tags": ["renewal"], "dismissed": [] },
  "source": "recording",                 // recording | import | calendar
  "device": "laptop",                    // the machine it was captured on (since GlyphCore 0.1.2; missing in older files)
  "calendar_event_id": null,
  "audio": "audio.m4a",
  "updated": "2026-06-17T11:46:00Z"
}
```

## transcript.json  (schema v1)
```json
{
  "schema": 1,
  "language": "en",
  "model": "whisper-large-v3",
  "speakers": { "S1": "Sarah Chen", "S2": "Mike Reyes" },
  "segments": [
    { "start": 12.0, "end": 18.6, "speaker": "S1", "text": "So the water-damage rider…" }
  ]
}
```
`speaker` is a voice id, `S1`, `S2`... in the order they first speak (an on-device diarizer
finds them; empty when none ran). `speakers` holds the names given to them; a voice with no
name reads as "Speaker 2". Voices under 2% of the talking are folded away.
`transcript.txt` = derived: `[mm:ss] Speaker: text` lines. Always regenerated from json.

## notes.md  (Markdown is source of truth for summary + tasks)
```markdown
---
title: Acme Insurance review
date: 2026-06-17
people: [Sarah Chen, Mike Reyes, Fru]
tags: [insurance, home]
---

## Summary
Compared three renter's policies…

## Decisions
- Proceed with Acme including the water-damage rider.

## Action items
- [ ] Send Acme the signed W-9  <!-- owner: Fru; due: 2026-06-19 -->
- [x] Request itemized estate inventory  <!-- owner: Fru -->
```
Action items are GFM checkboxes; optional HTML-comment metadata (`owner`, `due`, `source`).
The trailing comment is the machine channel; the visible text stays clean.

## .memosa/index/embeddings.jsonl  (one object per line)
```json
{"conv":"Work/Northwind/2026-06-17-acme-insurance-review","chunk":3,"start":58.0,"text":"…","vector":[0.0123, …]}
```

## .memosa/index/tasks.jsonl  (derived from every notes.md)
```json
{"conv":"…acme-insurance-review","text":"Send Acme the signed W-9","done":false,"owner":"Fru","due":"2026-06-19"}
```

## Write discipline (all modules MUST follow)
- **Atomic writes:** write `*.tmp` in the same dir, `fsync`, then `rename` over the target.
- **UTF-8**, `\n` line endings, 2-space JSON indentation (jsonl = compact, one line each).
- **Never** hold a long-lived lock; the vault must stay externally editable.
- All timestamps **UTC ISO-8601**. All paths vault-relative with `/` separators.

## Acceptance
A hand-authored conversation folder (no app) is fully readable by the app; an app-authored
one is human-readable and round-trips through git diff cleanly.


## People and accounts (v2)
Organizing is by links, not folders. A conversation names its `people`, `accounts`
and topic `tags` in meta.json; each person and account also has a note:

```markdown
---
kind: person
account: Northwind
aliases: [Ken, S. Chen]
---

Free notes about Sarah.
```

- Names in meta.json match a note's file name or one of its `aliases`.
- A person's `account` makes every call with that person a call with the account
  too. This is worked out when reading; it is never written into the call.
- Renaming a note rewrites the name in every meta.json (and in people's `account`).
- Naming someone new on a call creates a stub note. Notes can be written by hand.
- `suggested` holds guesses (names said in the call that match notes, names the
  on-device AI heard and the transcript really contains, a person's account, up to
  three topics). They count for nothing until confirmed; `dismissed` keeps every
  "no" so a guess never returns.
- Tags are lower case, words joined with `-`, no `#` on disk.

## Writing (GlyphCore)
`Packages/GlyphCore` (product `GlyphVault`) writes these files for the Glyph apps, the same
way Memosa's `store.rs` does. Its golden files (`Tests/GlyphVaultTests/Golden`) pin every
byte, and Memosa's `vault_report` reads them exactly as `glyphcore-report` does.
- JSON is serde_json's pretty form: `"key": value`, two spaces, keys in the order above,
  whole seconds as `12.0`, `/` and non-ASCII unescaped, no newline at the end.
- `suggested` is left out when all four lists are empty; `calendar_event_id` and `updated`
  when unset. Writing a transcript or notes stamps `updated`.
- notes.md front matter has `date: YYYY-MM-DD` (from `created`); `## Decisions` only when
  there are some; an item's comment only when it has an owner or a due date.
- Renaming a conversation re-slugs its folder (a case-only change keeps it); moving keeps the
  slug and refuses a name already taken. Either way `id` in meta.json follows the path.
- Trash, never delete: a conversation moves to `.memosa/trash/<id with / as __>` (`-2`, `-3`
  when taken). Nothing in GlyphCore removes a conversation, a note or audio, and there is no
  retention policy.

## Glyph CRM links (v4, Glyph Jot 0.7.16; v3 was Studio links, 0.7.12)
Glyph Jot captures context and links it to Glyph CRM's entities. It keeps no people or
companies of its own: a capture names an entity by its permanent id, and the page is the CRM's.
Files only, no database.

```
<vault>/data/
├─ entities/people/<slug>/entity.md    # People     id person/<slug>
├─ entities/places/<slug>/entity.md    # Places     id place/<slug>
├─ entities/orgs/<slug>/entity.md      # Products   id org/<slug>   (every company is a product)
├─ entities/things/<slug>/entity.md    # Things     id thing/<slug>
├─ apps/<id>/manifest.json             # Products   an app: shown on its company's row when its
│                                      #            `company`, id or `title`/`name` slugs to an
│                                      #            org; else its own row, id org/<slug of title>
├─ missions/<slug>/mission.md          # Projects   id mission/<slug> (Glyph Bot's)
└─ domains/<slug>/manifest.json        # Domains    id domain/<slug> (name: identity.label)
```
- Entity pages carry front matter `name:`, `aliases: [a, b]` and, from the CRM, a permanent
  `id: person/ken-lee` that survives a rename; when present it is the id. An older vault's
  flat `<slug>.md` still reads. Folders starting with `_` or `.` are not objects.
- Slug: lower case, anything but a-z and 0-9 becomes `-`, no `-` at the ends.
- A new person, place, product or thing picked in Jot is written as the CRM's own new page
  (`name, kind, aliases: [], saved: true, created, updated, mention_count: 0, id`, then
  `## Your notes` and `## Conversations`), in a free slug (`-2`, `-3`). An entity that already
  answers to the name is used instead. Links between entities are the CRM's, never Jot's.
- Two entities that answer to one name ("Which John?") are shown with their slug; Jot never picks.
- meta.json keeps `"links": ["person/ken-lee", "org/acme", "mission/launch", "domain/career"]`
  after `tags`, and `suggested` gains `"links"` first. Both are left out when empty. Its
  `notes.md` front matter repeats `tags` and `entities: [...]` (kept in step on every change).
- A note (`<vault>/data/domains/notes/source/jot/*.md`) carries `entities: [person/ken-lee]`
  and `tags: [knowledge]` in its own front matter: the key the CRM's timeline reads. Older
  notes said `links:`; it still reads and becomes `entities:` on the next change. Tags a note
  already has stay as written; new ones are tidied (`#Q4 Renewal` is `q4-renewal`).
- A note can be filed to one life domain: `domain: health` in its front matter (a folder name
  under `data/domains/`). Saying it first files it as you jot ("Health: ...", "For career, ...";
  the lead-in is taken off the words), or pick it after from the note's domain chip. The note stays
  in the notes folder.
- Older notes: Link Older Notes proposes the entities each note names (four letters or more),
  in batches of 25 you accept; a no is remembered in `data/apps/jot/link-review.json`.
- Moving a v2 vault: each name in `people` and `accounts` becomes the entity with that name
  or alias, or a new page; the People and Accounts notes move to
  `.memosa/migrated-to-studio/` (never deleted), with a line per run in its `log.jsonl`.
