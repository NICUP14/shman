#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="copy"

# Copy a file: a plain copy lives in both the store and home (no symlink).
sandbox
run init
printf 'data\n' >cfg
run copy cfg cfg
assert_rc 0 "copy returns 0"
assert_exists "$HOME/.shman/store/cfg" "store has the copy"
assert_file_is "$HOME/cfg" "data" "home has a real copy"
assert_eq "" "$(readlink "$HOME/cfg" 2>/dev/null)" "home copy is not a symlink"
assert_match "$(cat "$HOME/.shman/db.txt")" "f:c:" "recorded as a file copy"

# A directory source requires -r.
sandbox
run init
mkdir -p d/n
printf 'x\n' >d/n/i
run copy d nv
assert_rc 1 "directory without -r is rejected"
assert_match "$OUT" "Use -r" "explains the -r flag"

# With -r the directory is copied recursively and deployed to home.
run copy d nv -r
assert_rc 0 "directory with -r returns 0"
assert_file_is "$HOME/nv/n/i" "x" "directory deployed to home"
assert_match "$(cat "$HOME/.shman/db.txt")" "d:c:" "recorded as a directory copy"

# Empty directories are not tracked.
sandbox
run init
mkdir empty
run copy empty ed -r
assert_rc 1 "empty directory is refused"
assert_match "$OUT" "empty directory" "explains why"

# Trailing slash on the source + default target -> basename.
sandbox
run init
mkdir -p config/nvim
printf 'set nu\n' >config/nvim/init.vim
run copy config/nvim/ -r
assert_rc 0 "trailing slash source returns 0"
assert_file_is "$HOME/nvim/init.vim" "set nu" "deployed under basename target"

# A path containing a colon survives the field parsing.
sandbox
run init
printf 'Z\n' >'wei:rd'
run copy 'wei:rd' 'a:b'
assert_rc 0 "colon path returns 0"
assert_match "$(tail -1 "$HOME/.shman/db.txt")" ":a:b" "colon path stored intact"
run sync
assert_file_is "$HOME/a:b" "Z" "colon path deploys correctly"

report
