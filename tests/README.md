# shman test suite

POSIX-sh tests. No framework needed — just `sh`.

## Running

```sh
sh tests/run_tests.sh        # whole suite
sh tests/test_safety.sh      # one suite on its own
```

Each test runs in a throwaway `$HOME` (a `mktemp -d` sandbox), so nothing
touches your real dotfiles. The runner exits non-zero if any suite fails, and
each suite exits non-zero if any assertion fails — usable in CI as-is.

## Layout

- `test_lib.sh` — shared helpers: `sandbox`, `run`, `pty_repair`, and the
  `assert_*` checks. `run` sets `RC`/`OUT`; `assert_rc` compares against `RC`.
- `test_init.sh` — store/db creation, idempotency, no-blanking.
- `test_link.sh` — symlinking, dedup, default/normalized targets, in-place, dirs.
- `test_copy.sh` — copies, `-r` rule, empty-dir refusal, colon-in-path.
- `test_remove.sh` — untracking: link moved back, copy restored + home backed up,
  diverged vs. unmodified, dir trees, corruption, untracked/missing-arg guards.
- `test_list.sh` — empty/no-db states, expanded codes, mode column, count.
- `test_ghost.sh` — unreferenced store files, clean-store warning, dir coverage.
- `test_sync.sh` — relink, recopy, real-dir-not-deleted, idempotency, corruption.
- `test_repair.sh` — missing-link restore, corruption, headless + interactive
  prompt (the interactive cases self-skip if no pty tool is available).
- `test_safety.sh` — overwrite guards, diverged tracked paths, symlink-source
  rejection, traversal guard.
- `test_permissions.sh` — mode capture and enforcement, drift repair (including
  unreadable store files), idempotency.
- `test_dispatch.sh` — usage/help/unknown-command, no top-level option parsing.
