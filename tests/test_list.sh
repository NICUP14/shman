#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="list"

# No database at all (init never run): list errors out.
sandbox
run list
assert_rc 1 "list without a db exits 1"
assert_match "$OUT" "no database" "names the missing db"

# A fresh, empty database reports nothing tracked.
sandbox
run init
run list
assert_rc 0 "list on empty db exits 0"
assert_match "$OUT" "No files tracked" "empty db says so"

# Entries are shown with the single-letter codes expanded into words, plus a
# header row and a trailing count.
sandbox
run init
printf 'A\n' >.bashrc
chmod 640 .bashrc
run link .bashrc
printf 'B\n' >cfg
run copy cfg
run list
assert_rc 0 "list with entries exits 0"
assert_match "$OUT" "TYPE" "prints the header row"
assert_match "$OUT" "file" "expands f -> file"
assert_match "$OUT" "symlink" "expands l -> symlink"
assert_match "$OUT" "copy" "expands c -> copy"
assert_match "$OUT" "640" "shows the recorded mode"
assert_match "$OUT" ".bashrc" "lists the linked path"
assert_match "$OUT" "2 file(s) tracked" "counts the entries"

# A directory entry is labelled dir.
sandbox
run init
mkdir d
printf 'x\n' >d/f
run link d
run list
assert_match "$OUT" "dir" "expands d -> dir"

report
