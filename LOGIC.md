# shman — Logic Walkthrough

A complete walkthrough of [`shman.sh`](shman.sh) — the data model, the shared
helpers, then each command's exact flow and every check it performs.

## The data model

Four globals set the whole layout:

- `SHMAN_DIR` = `~/.shman/` — the top-level directory.
- `STORE` = `~/.shman/store/` — the canonical copies (your git-able repo of
  dotfiles, and *only* those).
- `BACKUPS` = `~/.shman/backups/` — prior versions, saved automatically before
  anything is overwritten.
- `DB` = `~/.shman/db.txt` — the flat-file index (kept beside the store, not
  inside it, so the store stays a clean repo of just dotfiles).

Each DB line is `field_type:track_type:mode:path`:

- **field_type** — `f` (file) or `d` (directory)
- **track_type** — `l` (deployed as a symlink) or `c` (deployed as a plain copy)
- **mode** — octal permission bits to enforce (e.g. `600`); may be empty
- **path** — relative, and identical under both the store and `~/`

So `f:l:600:.ssh/config` means "a file, symlinked, kept at mode 600, living at
`~/.shman/store/.ssh/config` ↔ `~/.ssh/config`". The `track_type` field lets
`sync`/`repair` know *how* to deploy each entry; the `mode` field lets them
*enforce* permissions (see below). **`mode` is placed before `path`** so a path
that itself contains a `:` still parses correctly (path = everything after the
third colon).

Why a mode field when `cp -p` already preserves permissions on copy? Because the
store is meant to be a git repo, and git only records the executable bit — a
`git clone`/`checkout` normalizes a `600` key to `644`. Recording the intended
mode lets `sync`/`repair` restore it. For symlink (`l`) entries the mode is
enforced on the **store file**, which is what tools like `ssh` actually check
when following the symlink.

Three terms used throughout: **src** = the store copy (`$STORE/path`),
**tgt**/**home_tgt** = the home location (`$HOME/path`), **dst** = where a new
item goes in the store.

**Copies are one-way (store → home).** Editing a `c`-tracked file in `$HOME`
does not update the store; you re-run `copy` to push it. A stray `sync` would
overwrite the edit with the stored version — but because every overwrite is
backed up first (see `backup_path`), the edit is always recoverable from
`backups/`.

---

## Shared helpers

**`link_target`** — `readlink` to read a symlink's destination. Used to decide
whether an existing symlink already points where it should.

**`file_mode`** — prints a path's octal permission bits (`stat -c '%a'`, with a
BSD `stat -f '%Lp'` fallback). Empty on failure, so the whole feature degrades
gracefully to "no mode tracking" if `stat` is unavailable.

**`sync_mode`** — enforces a recorded mode on a path: returns 0 if nothing's
needed (no mode, missing path, or already correct), 1 if it `chmod`-ed a change,
2 if the `chmod` failed. The 0/1/2 split lets `sync`/`repair` count a fixed mode
as an update and a failed `chmod` as an error.

**`backup_path`** — given a path, a relpath, and a kind tag (`store`|`home`),
copies the path's current content to `backups/<relpath>.<kind>.<timestamp>`
before the caller overwrites it. No-op if there's nothing there; returns nonzero
only if a backup was attempted and failed (so callers can refuse to proceed and
avoid a destructive overwrite they couldn't back up). Called before the store
copy is replaced in `link`/`copy`, and inside `deploy_copy` before a home copy
is overwritten.

**`strip_slash`** (`:34`) — removes trailing slashes (keeping bare `/`). This is
why `copy config/nvim/` and `copy config/nvim` behave identically, and why
`${source##*/}` reliably yields the basename.

**`valid_target`** (`:46`) — the directory-traversal guard. Rejects empty paths,
absolute paths (`/*`), and anything with a `..` component (`../*`, `*/../*`,
`*/..`, `..`). This blocks a target from escaping the store/home — both for user
input and for paths read back out of `db.txt`.

**`parse_line`** — splits a line into `f_type`, `t_type`, `t_mode`, `t_path`
using prefix/suffix expansion. The key detail: `t_path` takes *everything* after
the **third** colon, so a path that itself contains a colon survives intact.

**`db_remove`** (`:65`) / **`db_set`** (`:82`) — the DB writer. `db_remove`
rewrites the file into a temp (`$DB.tmp.$$`) keeping every line whose path ≠ the
target, then `mv`s it over — atomic, so a crash can't leave a half-written DB.
`db_set` calls `db_remove` then appends the new line. That remove-then-append is
what makes re-running `link`/`copy` on the same target **not** create duplicate
entries.

**`safe_to_place`** — the data-loss guard, the heart of the safety model. Given
a home target, source, and db path, it returns "safe" only if:

1. the target is a **symlink** — removing a link never destroys the data it
   points at; or
2. the target doesn't exist — nothing to lose; or
3. the target **is the source itself** (`-ef`, inode comparison) — its content
   is about to be preserved in the store anyway; or
4. the target **still matches the store copy** for that path
   (`content_matches "$STORE/$3" "$1"`) — it's the unmodified artifact we
   already deploy, so refreshing it loses nothing.

Otherwise it returns false → the command refuses. `-ef` compares inodes, so a
relative path and an absolute path to the same file are correctly recognized as
identical.

> **Why a content check, not a name check.** An earlier version asked only
> "is this path tracked in `db.txt`?" (`is_tracked`). That was unsafe: a path
> can be tracked while the file *currently on disk* has been replaced by real,
> unmanaged content (e.g. the user deleted the symlink and dropped in a real
> file). The name was tracked, so the guard allowed the clobber and the data was
> lost. The legitimate "re-run `link`/`copy` to update" case is already covered
> by the symlink check (#1) and the matching-copy check (#4), so the name-only
> branch only ever fired in the dangerous case. The content comparison closes
> that hole while still allowing a genuine refresh of an unmodified artifact.

**`ensure_store`** (`:111`) — every command except `init` calls this first;
errors out if `~/.shman` doesn't exist yet.

---

## `init` — `cmd_init, :122`

1. `mkdir -p "$STORE"` (`:123`) — create the store (idempotent; no error if it
   exists).
2. `touch "$DB"` **only if it doesn't already exist** (`:127`) — so re-running
   never blanks an existing database.
3. Verify the store and DB are both readable **and** writable (`:132-139`),
   accumulating into `rc` rather than bailing on the first failure.
4. Print `Initialized …` only if everything checked out; return `rc`.

---

## Argument parsing for `link`/`copy` — `parse_add_args, :149`

Both add-commands share this. It walks the args (`:153`):

- `-r` → sets `recursive=1`
- any other `-*` → "unknown flag" error (commands parse their own options — the
  top level deliberately doesn't)
- first bare word → `source`, second → `target`, a third → "too many arguments"

Then: source is required (`:174`); both source and target are run through
`strip_slash`; if no target was given it defaults to the source's basename
(`:179`); and finally the target is validated against traversal (`:181`).

---

## `link <source> [target]` — `cmd_link, :188`

Goal: move a file/dir into the store and replace the original with a symlink.

1. `ensure_store`, then parse args.
2. **Reject a symlink source**, then require the source to **exist**. A symlink
   source is refused outright: its intent is ambiguous (track the link, or its
   target?) and silently dereferencing it would store a surprise copy and leave
   the original symlink untracked. The `-L` check runs first, so a *dangling*
   symlink also gets the clear "is a symlink" message rather than "does not
   exist". Point shman at the real file/dir instead.
3. Compute `dst` and `home_tgt`.
4. Decide `f_type`: directory → `d` with `cp -Rp`, else `f` with `cp -p`.
   `cp -p` preserves permissions/timestamps. (No `-L` exclusion needed here —
   symlinks were already rejected in step 2.)
5. **Capture the source's mode** with `file_mode` — recorded for enforcement.
6. **Overwrite guard** — `safe_to_place` before touching anything; refuse if the
   home target is unmanaged, unrelated data.
7. **Store-first**: make the parent dir, then — unless source already *is* the
   store file (`-ef`) — back up any existing `dst` to `backups/` (`backup_path`,
   kind `store`), wipe it, and copy the source in. The canonical copy exists
   before the original is disturbed, so nothing is ever only-in-home.
8. **Replace home target**: remove whatever's there (we already proved it's safe)
   and create the symlink `home_tgt → dst`.
9. **Record** `f:l:<mode>:target`, then print `Linked: …`. (`cp -p` already gave
   the store file the source's mode; recording it lets `sync`/`repair` re-enforce
   it later.)

---

## `copy <source> [target] [-r]` — `cmd_copy, :245`

Goal: keep a plain copy in the store *and* in home (no symlink) — for things
that shouldn't be symlinked.

Same skeleton as `link`, with two differences:

- **Directory handling** (`:257-265`): a directory source requires `-r`,
  otherwise it's rejected; and an **empty** directory is refused (`ls -A` is
  empty) — only non-empty structures are tracked.
- After the store copy, it **deploys to home as a real copy** via `deploy_copy`
  instead of symlinking — skipped when source already *is* the home target. The
  overwrite guard and store-first copy (with its `store` backup) are identical to
  `link`.
- It also captures the source mode and **records** `f:c:<mode>:` or
  `d:c:<mode>:`, then prints `Copied: …`.

Two deploy helpers it relies on: **`content_matches`** compares target vs. store
(`cmp -s` for files, `diff -r` for dirs); **`deploy_copy`** backs up the target
(kind `home`), makes the parent dir, clears the target, and copies store→target.

---

## `sync` — `cmd_sync, :337`

Goal: make `~/` match `db.txt`. **Non-fatal by design** — it fixes what it can,
counts `errors`, and only returns nonzero at the very end.

For each DB line (`:346`):

1. Skip blank lines; parse; re-validate the path for traversal (`:349`).
2. **Source-missing check** (`:357`): if `$STORE/path` is gone, that's
   corruption it can't repair — log, count, `continue`.
3. **Link entries (`l`)**:
   - Already a correct symlink → leave it (falls through to the mode step).
   - A *wrong* symlink → `rm -f` it (safe — only the link is removed) and
     relink.
   - A **real file/dir** sitting where a link belongs → **refuse to delete it**,
     emit an error pointing at `repair`, count it, `continue`. This is the key
     safety rule: `sync` never destroys unmanaged data non-interactively.
   - Else create the symlink.
4. **Copy entries (`c`)**: if content already matches, leave it; otherwise
   re-deploy from the store.
5. **Mode enforcement** (after the `case`, for every entry that didn't `continue`
   out): `sync_mode` brings the recorded mode back — on the **store file**
   (`src`) for symlinks, and on **both store and the deployed copy** (`tgt`) for
   `c`-entries. A `chmod` counts as an update; a failed `chmod` as an error. This
   is why the "already correct" branches no longer early-`continue` — a pure mode
   drift still needs fixing even when content/links are fine.
6. Unknown `track_type` → counted as an error.

Finally prints `Sync complete. N files updated.`, and if any entries failed,
prints the count to stderr and returns 1.

---

## `repair` — `cmd_repair, :412`

Goal: verify integrity and restore links — like `sync` but interactive about
ambiguous cases. Same per-entry, non-fatal loop and same source-missing check
(`:432`).

**Link entries** split four ways:

- It's a symlink pointing at the right src **and** not dangling (`-e`) → leave
  it (falls through to the mode step).
- It's a symlink but wrong/broken → `rm -f` and relink.
- Nothing there → just create the link.
- A **real file** is in the way → this is where `repair` differs from `sync`.
  It **prompts** `Overwrite? [y/N]`; `y` removes and relinks, anything else
  leaves it untouched (and `continue`s — we never `chmod` an unmanaged file the
  user chose to keep). The read is from `/dev/tty`, not stdin, because the
  repair loop is `while read ... done <"$DB"` — stdin is the database file, so a
  plain `read` would consume the next DB line instead of the keystroke. The
  redirections are ordered `2>/dev/null </dev/tty` so that if there is no
  terminal at all, the failed open is silent and `|| ans=n` defaults to leaving
  the file untouched — never a silent destroy.

**Copy entries**: if content differs, re-deploy from the store.

**Mode enforcement**: identical to `sync` — after the `case`, `sync_mode`
restores the recorded mode on the store file (and the deployed copy for
`c`-entries), counting fixes and `chmod` failures.

Ends with `Repair complete. N links restored. M errors found.`, returning
nonzero if `M > 0`.

---

## Dispatch — `:518-539`

`cmd` is the first arg; it's `shift`ed off so `"$@"` is the command's own args.
The `case` routes only on the **command word** — `init/link/copy/sync/repair/
help`. `help` prints usage; empty prints usage to stderr and exits 1; anything
else (including `-h`/`--help`) is "unknown command". Option parsing is
intentionally left entirely to the individual commands.

---

## The safety guarantees, in one place

- **Store-first**: canonical copy lands in `~/.shman/store` before the home
  original is touched.
- **Nothing overwritten is lost**: before replacing the store copy (re-add) or a
  home copy (`sync`/`repair`), `backup_path` saves the current content to
  `backups/`.
- **No unrecoverable deletes**: `safe_to_place` blocks `link`/`copy` from
  clobbering unmanaged data; `sync` refuses to delete a real file at a link
  target; `repair` only overwrites a real file after an explicit `y`.
- **Atomic DB**: every write goes through a temp file + `mv`.
- **Traversal-proof**: `valid_target` gates both user input and DB-read paths.
- **No ambiguous sources**: a symlink source is rejected up front rather than
  silently dereferenced.
- **Permission-aware**: the intended octal mode is recorded per entry and
  re-enforced by `sync`/`repair` (on the store file for symlinks), so a `git`
  round-trip or stray `chmod` can't silently weaken e.g. a `600` key.
- **Resilient**: `init`, `sync`, and `repair` accumulate problems and report at
  the end rather than aborting on the first.
