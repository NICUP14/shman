#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="repair"

# A missing link is recreated.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
rm -f "$HOME/bashrc"
run repair
assert_rc 0 "repair returns 0"
assert_symlink "$HOME/bashrc" "missing link recreated"

# A missing store source is a non-fatal corruption error.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
printf 'f:l:644:ghost\n' >>"$HOME/.shman/db.txt"
run repair
assert_rc 1 "missing source is a non-fatal error"
assert_match "$OUT" "Manual intervention" "reports the corruption"

# Headless: a real file blocking a link is left untouched, no crash.
sandbox
run init
printf 'a\n' >a.txt
run link a.txt cfg
rm -f "$HOME/cfg"
printf 'PRECIOUS\n' >"$HOME/cfg"
OUT=$(sh "$SHMAN" repair </dev/null 2>&1)
RC=$?
assert_rc 0 "headless repair with a blocker exits cleanly"
assert_file_is "$HOME/cfg" "PRECIOUS" "blocker left untouched without a tty"
assert_match "$OUT" "untouched" "warns that it left the file"

# Interactive prompt (needs a pty): y overwrites, n keeps.
if have_pty; then
	sandbox
	run init
	printf 'a\n' >a.txt
	run link a.txt cfg
	rm -f "$HOME/cfg"
	printf 'PRECIOUS\n' >"$HOME/cfg"
	pty_repair y
	assert_symlink "$HOME/cfg" "interactive 'y' relinks over the blocker"

	sandbox
	run init
	printf 'a\n' >a.txt
	run link a.txt cfg
	rm -f "$HOME/cfg"
	printf 'PRECIOUS\n' >"$HOME/cfg"
	pty_repair n
	assert_file_is "$HOME/cfg" "PRECIOUS" "interactive 'n' leaves the file"
else
	skip "interactive prompt tests (no usable pty tool)"
fi

report
