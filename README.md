# shman

A small POSIX-sh dotfile manager. It keeps your dotfiles in one directory (`~/.shman`) and puts them where they belong in `$HOME`, either as symlinks or as plain copies. That's the whole job.

It is a single script, `shman.sh`. There is no daemon, no config file, and no dependency beyond a normal Unix userland (`sh`, `cp`, `ln`, `rm`, `stat`, `readlink`, `cmp`, `diff`). It targets `sh`/`dash`/BusyBox, not just Bash.

## Status

Young and personal. It is tested (see `tests/`) and deliberately careful about not destroying data, but it has not seen wide real-world use. Read the limitations below before trusting it with anything you can't reproduce.

## Install

```sh
cp shman.sh ~/.local/bin/shman
chmod +x ~/.local/bin/shman
```

## Use

```sh
shman init                       # create ~/.shman and its database
shman link ~/.bashrc bashrc      # move into the store, leave a symlink behind
shman copy ~/.ssh/config sshcfg  # store + keep a plain copy (no symlink)
shman copy ~/.config/nvim nvim -r  # directories need -r
shman sync                       # make $HOME match the database
shman repair                     # verify the store and restore what's missing
```

- `link` replaces the original with a symlink into `~/.shman/store`.
- `copy` keeps an independent copy in `$HOME` (useful for files that must not be symlinks, e.g. some service/config files).
- `sync` re-creates broken links and re-deploys changed copies.
- `repair` is like `sync` but prompts before touching an unmanaged file that is sitting where a managed link should be.

Copies flow one way, store → home. After editing a copied file in `$HOME`, run `copy` again to push the new version into the store — `sync` would instead overwrite your edit with the stored version. Either way the overwritten content is saved to `backups/` first, so nothing is lost.

## Layout and database

```
~/.shman/store/      your dotfiles (put this under git if you like)
~/.shman/backups/    prior versions, saved automatically before any overwrite
~/.shman/db.txt      the index
```

`db.txt` is a flat text file, one entry per line:

```
field_type:track_type:mode:path
#  f|d        l|c       644   relative/path
```

`mode` is the octal permission the file should have; `sync`/`repair` re-apply it (handy because `git` only preserves the executable bit, so a cloned `600` key would otherwise come back as `644`).

## What it tries hard not to do

- It never deletes a file in `$HOME` or `~/.shman` that it doesn't manage.
- Before overwriting a tracked file — the store copy when you re-add, or the home copy on `sync`/`repair` — it saves the current content to `~/.shman/backups/<path>.<store|home>.<timestamp>`.
- `link`/`copy` refuse to overwrite an existing target unless it's a symlink, the source itself, or an unmodified copy shman already deploys.
- `sync` won't delete a real file/directory sitting where a link belongs; it reports it and leaves it for `repair` to handle interactively.
- Database writes are atomic (temp file + rename).
- Targets containing `..` are rejected.

## Limitations

- **Add-only.** There is currently no `untrack`/`remove` or `list`/`status` command. You can stop a path from being managed only by editing `db.txt`.
- **No git integration.** The store is git-friendly, but committing/pushing is your job.
- **Backups are never pruned.** Each overwrite adds a timestamped copy under `~/.shman/backups/`; prune it yourself when it gets large.
- **Directories track only the top-level mode.** Permissions of files *inside* a tracked directory are preserved on copy but not individually re-enforced.
- **Symlink sources are rejected** — point shman at the real file or directory.
- The line-based database does not handle paths containing newlines (colons are fine).

## Tests

```sh
sh tests/run_tests.sh
```

See `tests/README.md`. Every suite runs in a throwaway `$HOME`, so the tests never touch your real dotfiles.

## A note on AI use

This project was written with substantial help from an AI assistant (Anthropic's Claude). The design, code, tests, and docs were produced through an iterative back-and-forth: a human directed the requirements and reviewed each change, and the assistant did most of the drafting and edge-case hunting. Several of the safety fixes came directly out of that review loop. Treat the code as you would any AI-assisted work — it has been tested, but review it yourself before relying on it.
