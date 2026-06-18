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
is overwritten. The timestamp has one-second resolution, so two overwrites of
the same path within the same second would otherwise collide and the later
backup would clobber the earlier one — the opposite of the guarantee. It never
overwrites an existing backup: if the timestamped name is taken it keeps the
timestamp and appends `.1`, `.2`, … until the name is free.

**`strip_slash`** (`:34`) — removes trailing slashes (keeping bare `/`). This is
why `copy config/nvim/` and `copy config/nvim` behave identically, and why
`${source##*/}` reliably yields the basename.

**`valid_target`** — the *string-level* directory-traversal guard. Rejects empty
paths, absolute paths (`/*`), and anything with a `..` component (`../*`,
`*/../*`, `*/..`, `..`). This blocks a target from escaping the store/home — both
for user input and for paths read back out of `db.txt`.

**`within_tree`** / **`guard_path`** — the *filesystem-level* companion to
`valid_target`. A purely textual check can't catch a path that escapes through a
**symlinked parent directory**: if `~/.config` is a symlink to `/mnt/elsewhere`,
the string `.config/foo` looks innocent but `~/.config/foo` resolves outside
`~/`, so a deploy (`mkdir`/`cp`/`ln`/`rm`) would write into `/mnt/elsewhere`.
`within_tree base rel` walks the existing parent components of `base/rel` and
returns false if any is a symlink (the **leaf is not checked** — a tracked
entry's own deployed file is legitimately a symlink). `guard_path rel` runs that
check against **both** the store and `~/` and is the single chokepoint, called
from `prepare_source` (so `link` and `copy` are covered), from the `apply_db`
loop (both `sync` and `repair`, counted as a non-fatal per-entry error), and from
`cmd_remove`. Because it gates DB-read paths too, a hand-edited `db.txt` can't use
a symlinked ancestor to escape either.

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

## Argument parsing for `link`/`copy` — `parse_add_args`

Both add-commands share this. It walks the args:

- `-r` → sets `recursive=1`
- any other `-*` → "unknown flag" error (commands parse their own options — the
  top level deliberately doesn't)
- first bare word → `source`, second → `target`, a third → "too many arguments"

Then: source is required and run through `strip_slash`; the target is validated
against traversal.

**Default target — track in place.** When no explicit target is given, it is
**not** the source basename. It is the source's location *relative to `$HOME`*,
computed by **`home_relative`** (`cd -P`/`pwd -P` on the source's parent, then
strip the `$HOME/` prefix — both POSIX, no `realpath`). So `link ./LOGIC.md` run
from `~/Projects/x` records `Projects/x/LOGIC.md` and replaces *that* file in
place, instead of flattening to `~/LOGIC.md`. This works from any directory and
for nested paths. A source that resolves **outside `$HOME`** has no home-relative
path, so it falls back to the basename — the one case that still produces the
orphaned-source behaviour described in the header. An explicit `[target]` is
taken verbatim (still just `strip_slash` + traversal check), which is how you
deliberately rename or relocate.

---

## `link`/`copy` shared steps — `prepare_source`, `store_first`

`link` and `copy` share almost everything, so two helpers carry the common work:

- **`prepare_source`** — validates the source and sets the globals both commands
  need. It **rejects a symlink source** (the `-L` check first, so a *dangling*
  symlink still gets the clear "is a symlink" message and not "does not exist"):
  its intent is ambiguous (track the link, or its target?) and dereferencing it
  would store a surprise copy and orphan the link. It then requires the source to
  **exist**, computes `dst` and `home_tgt`, picks `f_type` (directory → `d` with
  `cp -Rp`, else `f` with `cp -p`), and **captures the source's mode** with
  `file_mode` for enforcement.
- **`store_first`** — lands the canonical copy in the store before the original is
  touched. It runs the **overwrite guard** (`safe_to_place`; refuse if the home
  target is unmanaged, unrelated data), makes the store parent dir, then — unless
  source already *is* the store file (`-ef`) — backs up any existing `dst` to
  `backups/` (kind `store`), wipes it, and copies the source in. So the canonical
  copy always exists before anything else changes; nothing is ever only-in-home.

## `link <source> [target]` — `cmd_link`

Goal: move a file/dir into the store and replace the original with a symlink.

1. `ensure_store`, parse args, `prepare_source`, `store_first`.
2. **Replace home target**: remove whatever's there (we already proved it's safe)
   and create the symlink `home_tgt → dst`.
3. **Record** `f:l:<mode>:target`, then print `Linked: …`. (`cp -p` already gave
   the store file the source's mode; recording it lets `sync`/`repair` re-enforce
   it later.)

---

## `copy <source> [target] [-r]` — `cmd_copy`

Goal: keep a plain copy in the store *and* in home (no symlink) — for things
that shouldn't be symlinked.

Same skeleton as `link` (`prepare_source` then `store_first`), with two
differences:

- **Directory handling** (after `prepare_source` sets `f_type=d`): a directory
  source requires `-r`, otherwise it's rejected; and an **empty** directory is
  refused (`ls -A` is empty) — only non-empty structures are tracked.
- After `store_first`, it **deploys to home as a real copy** via `deploy_copy`
  instead of symlinking — skipped when source already *is* the home target.
- It **records** `f:c:<mode>:` or `d:c:<mode>:`, then prints `Copied: …`.

Two deploy helpers it relies on: **`content_matches`** compares target vs. store
(`cmp -s` for files, `diff -r` for dirs); **`deploy_copy`** backs up the target
(kind `home`), makes the parent dir, clears the target, and copies store→target.

---

## `sync` / `repair` — one DB walk: `apply_db`

`sync` and `repair` are 95% the same walk over `db.txt`, so they're a single
function — `apply_db <op>`, where `<op>` is `sync` or `repair`. **Non-fatal by
design**: it fixes what it can, counts `errors`, and only returns nonzero at the
end. Goal: make `~/` match `db.txt`. They diverge in exactly two places (a
blocked link target, and the summary line), called out below.

For each DB line:

1. Skip blank lines; parse; re-validate the path for traversal.
2. **Source-missing check**: if `$STORE/path` is gone, that's corruption —
   log, count, `continue`.
3. **Mode enforcement on the store file first** (`apply_mode "$t_mode" "$src"`),
   so a source whose own permissions were stripped (e.g. `000`) becomes readable
   before we compare or copy it.
4. **Link entries (`l`)** → `deploy_link`:
   - Already a correct symlink → leave it.
   - A *wrong* symlink → `rm -f` it (safe — only the link is removed) and relink.
   - Nothing there → create the symlink.
   - A **real file/dir** sitting where a link belongs → **this is the one
     behavioural split.** Under `sync` it **refuses to delete it**, emits an
     error pointing at `repair`, and counts it (the key safety rule: `sync` never
     destroys unmanaged data non-interactively). Under `repair` it **prompts**
     `Overwrite? [y/N]`; `y` removes and relinks, anything else leaves it
     untouched. The read is from `/dev/tty`, not stdin, because the loop is
     `while read ... done <"$DB"` — stdin is the database file, so a plain `read`
     would consume the next DB line instead of the keystroke. The redirections
     are ordered `2>/dev/null </dev/tty` so that with no terminal at all the
     failed open is silent and `|| ans=n` defaults to leaving the file untouched
     — never a silent destroy.
5. **Copy entries (`c`)**: if content matches, leave it; otherwise re-deploy from
   the store. Then `apply_mode "$t_mode" "$tgt"` enforces the recorded mode on
   the deployed home copy too (the store copy was already done in step 3).
6. Unknown `track_type` → counted as an error.

Two small helpers keep the loop tight: **`apply_mode`** runs `sync_mode` and
folds the 0/1/2 result into the run state (a `chmod` marks the entry changed, a
failed `chmod` bumps `errors`); **`relink`** creates the `src → tgt` symlink and
marks the entry changed. Counting is **per entry, not per fix**: a `changed` flag
is reset at the top of each iteration, set by any helper that actually altered
something, and folded into `n` once at the end. So a single copy entry that needs
a relink/redeploy *and* a mode `chmod` counts as **one** file updated, not two or
three — the summary reports files touched, not individual operations.

**The other split is the summary line.** `sync` prints `Sync complete. N files
updated.` and, if any entries failed, the count to stderr + return 1. `repair`
prints `Repair complete. N links restored. M errors found.` and returns nonzero
if `M > 0`.

---

## `list` — `cmd_list, :636`

Goal: print the database as a human-readable table.

1. Require the DB to exist, then make a first pass just to **count** non-blank
   lines. Zero → print `No files tracked.` and return 0 (so an empty store reads
   as a clean state, not an error).
2. Otherwise print a header row (`TYPE TRACK MODE PATH`) and a second pass that,
   per entry, **expands the single-letter codes into words** — `f`→`file`,
   `d`→`dir`, `l`→`symlink`, `c`→`copy` — and prints the mode, substituting `-`
   for an empty mode (`${t_mode:--}`) so the columns still line up.
3. Close with a blank line and `N file(s) tracked.`

It's read-only: it never touches the store, home, or the DB.

---

## `ghost` — `cmd_ghost, :694`

Goal: surface **ghosts** — canonical files sitting in the store that no DB entry
references. These are the residue of a hand-edited `db.txt` or a half-finished
removal: `sync`/`repair` never deploy them because nothing points at them, so
they'd otherwise rot invisibly.

It walks `find "$STORE" ! -type d` (every store file, not directories) fed in via
a **heredoc rather than a pipe** — that keeps the loop in the current shell so the
`found` counter survives (a piped `while` runs in a subshell and the count would
be lost). For each store file it strips the `$STORE/` prefix to a relpath and
asks **`path_tracked`** (`:679`) whether the DB accounts for it.

`path_tracked` returns true when the relpath either **equals** a tracked
`t_path` (a file entry) **or lives beneath one** (`"$t_path"/*` — a directory
entry covers everything under it). So a file inside a tracked directory is *not*
a ghost, while a stray dropped anywhere else in the store is. Anything untracked
is printed; if nothing is found it warns `no ghost files in store`. Always
returns 0 — it's a diagnostic, not a check that can fail.

---

## `remove <target>` — `cmd_remove`

Goal: stop tracking a path and leave a plain, untracked file at home in its
place. The inverse of `link`/`copy`, and just as careful never to lose data.

1. `ensure_store`, require the DB, then `strip_slash` the target. To mirror how
   `link`/`copy` derive their target, it then runs the same **`home_relative`**
   resolution: a filesystem path like `./LOGIC.md` (or an absolute path under
   `~/`) is turned into its home-relative db form, so you can `remove` with the
   exact relative path you linked with. If that resolution fails (the path is
   outside `~/`, or its parent doesn't exist from the current directory), it
   falls back to the literal string minus a leading `./`, so passing the exact db
   path still works from anywhere. The result is then `valid_target`-checked
   (same traversal guard as the add-commands).
2. **Locate the entry**: scan the DB for a line whose `t_path` equals the target;
   the matching `parse_line` leaves `t_type` set for the dispatch below. Not
   found → `not tracked` error, exit 1.
3. **Source-missing check**: if `$STORE/target` is gone, refuse with `corruption`
   rather than guess — there's no canonical content to restore.
4. Branch on `t_type`:
   - **link (`l`)** — the data lives *only* in the store (the symlink just points
     at it), so **move it back out**: if something is at the home target, back it
     up first **only when it's a real file** (drift — a stale symlink loses
     nothing and is just removed), remove it, then `mv` the store file to the
     home location. The symlink is replaced by the real file.
   - **copy (`c`)** — home may have diverged, so reuse **`deploy_copy`** to
     overwrite home with the store version (which backs up the current home
     content, kind `home`, first), then **`rm -rf` the store copy**. What's left
     at home is a plain file holding the store version; the prior home content is
     in `backups/`.
5. **`db_remove target`** drops the entry (atomic temp-file rewrite), then print
   `Removed: …`.

The result in both cases: the path is gone from the DB and the store, an ordinary
file remains at home, and nothing the user had was destroyed without a backup.

---

## Dispatch — `:841-865`

`cmd` is the first arg; it's `shift`ed off so `"$@"` is the command's own args.
The `case` routes only on the **command word** — `init/link/copy/remove/list/
ghost/sync/repair/help`. `help` prints usage; empty prints usage to stderr and
exits 1; anything else (including `-h`/`--help`) is "unknown command". Option
parsing is intentionally left entirely to the individual commands.

---

## The safety guarantees, in one place

- **Store-first**: canonical copy lands in `~/.shman/store` before the home
  original is touched.
- **Nothing overwritten is lost**: before replacing the store copy (re-add) or a
  home copy (`sync`/`repair`), `backup_path` saves the current content to
  `backups/`.
- **No unrecoverable deletes**: `safe_to_place` blocks `link`/`copy` from
  clobbering unmanaged data; `sync` refuses to delete a real file at a link
  target; `repair` only overwrites a real file after an explicit `y`; `remove`
  always leaves a real file at home and backs up a diverged copy before
  restoring the store version.
- **Atomic DB**: every write goes through a temp file + `mv`.
- **Traversal-proof**: `valid_target` rejects absolute/`..` paths and
  `guard_path` rejects any target with a symlinked parent directory, so a deploy
  can never escape the store or `~/` — for both user input and DB-read paths.
- **No ambiguous sources**: a symlink source is rejected up front rather than
  silently dereferenced.
- **Permission-aware**: the intended octal mode is recorded per entry and
  re-enforced by `sync`/`repair` (on the store file for symlinks), so a `git`
  round-trip or stray `chmod` can't silently weaken e.g. a `600` key.
- **Resilient**: `init`, `sync`, and `repair` accumulate problems and report at
  the end rather than aborting on the first.
