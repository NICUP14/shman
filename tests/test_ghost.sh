#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="ghost"

# Store present but database missing: ghost errors out.
sandbox
run init
rm -f "$HOME/.shman/db.txt"
run ghost
assert_rc 1 "ghost without a db exits 1"
assert_match "$OUT" "no database" "names the missing db"

# A store with nothing unreferenced: warns, but succeeds.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc
run ghost
assert_rc 0 "ghost with no orphans exits 0"
assert_match "$OUT" "no ghost files" "reports a clean store"

# A file dropped into the store that no db entry covers is a ghost.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc
printf 'junk\n' >"$HOME/.shman/store/orphan"
run ghost
assert_rc 0 "ghost still exits 0 when orphans exist"
assert_match "$OUT" "orphan" "lists the unreferenced store file"
case "$OUT" in
*.bashrc*) _fail "ghost lists tracked file" "did not expect .bashrc in output" ;;
*) _pass ;;
esac

# A file beneath a tracked directory entry is covered, not a ghost; only a
# store file outside any entry is flagged.
sandbox
run init
mkdir d
printf 'x\n' >d/f
run link d
printf 'stray\n' >"$HOME/.shman/store/loose"
run ghost
assert_match "$OUT" "loose" "flags the loose store file"
case "$OUT" in
*d/f*) _fail "ghost flags file under tracked dir" "d/f should be covered" ;;
*) _pass ;;
esac

report
