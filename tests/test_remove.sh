#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="remove"

# Missing argument.
sandbox
run init
run remove
assert_rc 1 "remove without a target exits 1"
assert_match "$OUT" "missing" "asks for a target"

# A traversal target is rejected before anything is touched.
sandbox
run init
run remove ../escape
assert_rc 1 "remove rejects a .. target"
assert_match "$OUT" "unsafe target" "explains the rejection"

# Removing a path that isn't tracked is an error.
sandbox
run init
run remove .bashrc
assert_rc 1 "remove of an untracked path exits 1"
assert_match "$OUT" "not tracked" "says it isn't tracked"

# Remove a linked file: the symlink becomes a real file again (moved back out
# of the store), the store copy is gone, and the db entry is dropped.
sandbox
run init
printf 'A=1\n' >.bashrc
run link .bashrc
assert_symlink "$HOME/.bashrc" "linked first"
run remove .bashrc
assert_rc 0 "remove of a link exits 0"
assert_match "$OUT" "Removed" "reports removal"
assert_exists "$HOME/.bashrc" "home file still present"
assert_eq "" "$(readlink "$HOME/.bashrc" 2>/dev/null)" "home file is no longer a symlink"
assert_file_is "$HOME/.bashrc" "A=1" "original content restored"
assert_missing "$HOME/.shman/store/.bashrc" "store copy removed"
assert_eq 0 "$(grep -c . "$HOME/.shman/db.txt")" "db entry dropped"

# Remove a linked directory: the tree is moved back to home intact.
sandbox
run init
mkdir d
printf 'x\n' >d/f
run link d
run remove d
assert_rc 0 "remove of a linked dir exits 0"
assert_eq "" "$(readlink "$HOME/d" 2>/dev/null)" "home dir is no longer a symlink"
assert_file_is "$HOME/d/f" "x" "directory contents preserved"
assert_missing "$HOME/.shman/store/d" "store dir removed"

# Remove a copy whose home file has diverged: home is overwritten with the
# store version and the prior home content is backed up.
sandbox
run init
printf 'store-version\n' >cfg
run copy cfg
printf 'local-edit\n' >cfg
run remove cfg
assert_rc 0 "remove of a copy exits 0"
assert_file_is "$HOME/cfg" "store-version" "home updated to the store version"
assert_missing "$HOME/.shman/store/cfg" "store copy removed"
assert_eq 0 "$(grep -c . "$HOME/.shman/db.txt")" "db entry dropped"
bk=$(cat "$HOME"/.shman/backups/cfg.home.* 2>/dev/null)
assert_eq "local-edit" "$bk" "prior home content saved as a backup"

# Remove a copy whose home matches the store: still works, leaving a plain file.
sandbox
run init
printf 'same\n' >cfg
run copy cfg
run remove cfg
assert_rc 0 "remove of an unmodified copy exits 0"
assert_file_is "$HOME/cfg" "same" "home content intact"
assert_missing "$HOME/.shman/store/cfg" "store copy removed"

# remove accepts a relative filesystem path run from a subdirectory.
sandbox
run init
mkdir -p projects/app
printf 'cfg\n' >projects/app/conf
cd projects/app || exit 1
run link ./conf
run remove ./conf
cd "$HOME" || exit 1
assert_rc 0 "remove ./conf from a subdir returns 0"
assert_exists "$HOME/projects/app/conf" "file left in place"
assert_eq "" "$(readlink "$HOME/projects/app/conf" 2>/dev/null)" "no longer a symlink"
assert_eq 0 "$(grep -c . "$HOME/.shman/db.txt")" "db entry dropped"

# Corruption: the store source is gone, so remove refuses rather than guessing.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc
rm -f "$HOME/.shman/store/.bashrc"
run remove .bashrc
assert_rc 1 "remove with a missing store source exits 1"
assert_match "$OUT" "corruption" "flags the missing source"

# After removal the path is no longer tracked and re-running fails cleanly.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc
run remove .bashrc
run remove .bashrc
assert_rc 1 "second remove of the same path exits 1"
assert_match "$OUT" "not tracked" "path is gone from the db"

report
