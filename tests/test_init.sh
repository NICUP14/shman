#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="init"

# Creates the store and the database, and announces it.
sandbox
run init
assert_rc 0 "init returns 0"
assert_exists "$HOME/.shman/store" "store directory created"
assert_exists "$HOME/.shman/backups" "backups directory created"
assert_exists "$HOME/.shman/db.txt" "database created"
assert_match "$OUT" "Initialized" "prints Initialized"

# Idempotent, and never blanks an existing database.
sandbox
run init
printf 'f:l:644:bashrc\n' >"$HOME/.shman/db.txt"
run init
assert_rc 0 "second init returns 0"
assert_file_is "$HOME/.shman/db.txt" "f:l:644:bashrc" "existing db left intact"

report
