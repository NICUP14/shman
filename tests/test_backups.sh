#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="backups"

# Helper: most recent backup file whose name starts with <relpath>.<kind>.
latest_backup() {
	ls -1 "$HOME/.shman/backups/$1.$2."* 2>/dev/null | sort | tail -1
}

# Re-adding a changed file backs up the old store version before replacing it.
sandbox
run init
printf 'v1\n' >cfg
run copy cfg cfg
printf 'v2\n' >cfg
run copy cfg cfg
assert_rc 0 "re-copy succeeds"
assert_file_is "$HOME/.shman/store/cfg" "v2" "store updated to the new version"
b=$(latest_backup cfg store)
assert_eq "1" "$([ -n "$b" ] && echo 1)" "a store backup was created"
assert_file_is "$b" "v1" "store backup holds the previous version"

# The store backup also applies to link re-adds.
sandbox
run init
printf 'one\n' >f
run link f cfg
printf 'two\n' >f
run link f cfg
b=$(latest_backup cfg store)
assert_file_is "$b" "one" "re-link backs up the previous store version"

# sync overwriting an edited home copy backs up the edit first (recoverable).
sandbox
run init
printf 'orig\n' >doc
run copy doc doc
printf 'my local edit\n' >"$HOME/doc"   # edit the deployed copy, do not re-add
run sync                                # store wins, but the edit is saved
assert_file_is "$HOME/doc" "orig" "sync restores the store version"
b=$(latest_backup doc home)
assert_file_is "$b" "my local edit" "the overwritten home edit was backed up"

# A first-time add has nothing to back up (no spurious backup files).
sandbox
run init
printf 'x\n' >new
run copy new new
n=$(ls -1 "$HOME/.shman/backups" 2>/dev/null | wc -l)
assert_eq "0" "$n" "no backups created on a first add"

# Two overwrites within the same second must not clobber each other's backup.
# `date` is pinned to a constant so every backup gets an identical timestamp,
# forcing the collision the suffixing is meant to survive.
sandbox
run init
fakebin=$SBX/fakebin
mkdir -p "$fakebin"
printf '#!/bin/sh\necho 20200101000000\n' >"$fakebin/date"
chmod +x "$fakebin/date"
PATH="$fakebin:$PATH"; export PATH
printf 'v1\n' >cfg
run copy cfg cfg          # first add: nothing to back up
printf 'v2\n' >cfg
run copy cfg cfg          # backs up store v1
printf 'v3\n' >cfg
run copy cfg cfg          # backs up store v2 (same timestamp -> collision)
PATH=${PATH#"$fakebin:"}; export PATH
n=$(ls -1 "$HOME/.shman/backups/cfg.store."* 2>/dev/null | wc -l)
assert_eq "2" "$(echo "$n")" "both same-second store backups are kept"
got=$(cat "$HOME/.shman/backups/cfg.store."* 2>/dev/null | tr -d '[:space:]')
assert_eq "v1v2" "$got" "both prior versions survive the collision"

report
