#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="safety"

# Neither link nor copy will clobber an unmanaged file already at the target.
sandbox
run init
printf 'NEW\n' >src
printf 'KEEP\n' >existing
run link src existing
assert_rc 1 "link refuses an unmanaged existing target"
assert_file_is "$HOME/existing" "KEEP" "data intact after link refusal"
run copy src existing
assert_rc 1 "copy refuses an unmanaged existing target"
assert_file_is "$HOME/existing" "KEEP" "data intact after copy refusal"

# A tracked path whose on-disk file diverged (real content swapped in) is safe.
sandbox
run init
printf 'orig\n' >a.txt
run link a.txt cfg
rm -f "$HOME/cfg"
printf 'PRECIOUS\n' >"$HOME/cfg"
printf 'b\n' >b.txt
run link b.txt cfg
assert_rc 1 "refuse to clobber diverged content at a tracked path"
assert_file_is "$HOME/cfg" "PRECIOUS" "diverged content preserved"

# Re-copying a managed, unmodified target is allowed (an in-place update).
sandbox
run init
printf 'v1\n' >s
run copy s cfg
printf 'v2\n' >s
run copy s cfg
assert_rc 0 "re-copy of a managed target is allowed"
assert_file_is "$HOME/cfg" "v2" "home copy updated in place"

# A broken symlink at the target may be overwritten (no data behind it).
sandbox
run init
printf 'n\n' >n
ln -s /nonexistent "$HOME/brk"
run copy n brk
assert_rc 0 "overwriting a broken symlink is allowed"
assert_file_is "$HOME/brk" "n" "deployed over the broken link"

# Symlink sources are rejected up front (file, dangling, and directory).
sandbox
run init
printf 'r\n' >real
ln -s real sl
run link sl x
assert_rc 1 "symlink-to-file source rejected"
assert_match "$OUT" "is a symlink" "clear message for symlink source"
ln -s /nope dang
run copy dang y
assert_rc 1 "dangling symlink source rejected"
mkdir realdir
printf 'q\n' >realdir/f
ln -s realdir dl
run copy dl z -r
assert_rc 1 "symlink-to-directory source rejected"

# Directory-traversal targets are rejected.
sandbox
run init
printf 'a\n' >a
run link a ../escape
assert_rc 1 "traversal target rejected"
assert_match "$OUT" "unsafe target" "clear message for traversal"

report
