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

# A target whose PARENT is a symlink is refused: deploying through it would write
# outside the managed tree. (link and copy share this guard via prepare_source.)
sandbox
run init
EXT=$(mktemp -d)
ln -s "$EXT" "$HOME/.config"        # ~/.config redirects to an external dir
printf 'data\n' >vimrc
run link vimrc .config/init.vim
assert_rc 1 "link refuses a target with a symlinked parent"
assert_match "$OUT" "symlink" "explains the symlinked parent"
assert_missing "$EXT/init.vim" "nothing written through the symlinked parent"
run copy vimrc .config/foo
assert_rc 1 "copy refuses a target with a symlinked parent"
assert_missing "$EXT/foo" "copy wrote nothing through the symlinked parent"
rm -rf "$EXT"

# sync refuses a db entry whose home parent is a symlink (non-fatal: error + rc 1),
# never deploying through it.
sandbox
run init
printf 'A\n' >f
run link f keep                     # a normal entry so the store exists
EXT=$(mktemp -d)
ln -s "$EXT" "$HOME/sub"            # ~/sub redirects to an external dir
mkdir -p "$HOME/.shman/store/sub"
printf 'x\n' >"$HOME/.shman/store/sub/x"
printf 'f:l:644:sub/x\n' >>"$HOME/.shman/db.txt"
run sync
assert_rc 1 "sync refuses an entry with a symlinked home parent"
assert_missing "$EXT/x" "sync did not deploy through the symlinked parent"
rm -rf "$EXT"

# remove refuses when the home parent has become a symlink.
sandbox
run init
printf 'A\n' >f
run copy f a/b                      # tracked; deploys a real ~/a/b
rm -rf "$HOME/a"
EXT=$(mktemp -d)
ln -s "$EXT" "$HOME/a"             # ~/a now redirects to an external dir
run remove a/b
assert_rc 1 "remove refuses when the home parent is a symlink"
rm -rf "$EXT"

report
