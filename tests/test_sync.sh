#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="sync"

# A deleted symlink is recreated.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
rm -f "$HOME/bashrc"
run sync
assert_rc 0 "sync returns 0"
assert_symlink "$HOME/bashrc" "broken symlink restored"

# A tampered copy is restored from the store.
sandbox
run init
mkdir -p c/n
printf 'orig\n' >c/n/i
run copy c/n nv -r
printf 'bad\n' >"$HOME/nv/i"
run sync
assert_file_is "$HOME/nv/i" "orig" "tampered copy restored"

# A real directory where a link belongs is never deleted by sync.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
rm -f "$HOME/bashrc"
mkdir "$HOME/bashrc"
printf 'precious\n' >"$HOME/bashrc/d"
run sync
assert_rc 1 "sync reports an error when a real dir blocks a link"
assert_file_is "$HOME/bashrc/d" "precious" "real directory not deleted"
assert_match "$OUT" "repair" "points the user at repair"

# A clean tree is a no-op.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
run sync
assert_match "$OUT" "0 files updated" "clean sync changes nothing"

# A missing store source is a non-fatal corruption error.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
printf 'f:l:644:ghost\n' >>"$HOME/.shman/db.txt"
run sync
assert_rc 1 "missing source is a non-fatal error"
assert_match "$OUT" "source missing" "reports the corruption"

report
