#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="permissions"

# link captures the source mode; the store file ends up with it.
sandbox
run init
printf 'KEY\n' >key
chmod 600 key
run link key key
assert_match "$(cat "$HOME/.shman/db.txt")" "f:l:600:key" "mode recorded in db"
assert_mode "$HOME/.shman/store/key" 600 "store file keeps mode 600"

# copy captures the mode on both the store and the deployed home copy.
sandbox
run init
printf '#!/bin/sh\n' >deploy.sh
chmod 755 deploy.sh
run copy deploy.sh bin/deploy.sh
assert_match "$(cat "$HOME/.shman/db.txt")" "f:c:755:bin/deploy.sh" "mode recorded in db"
assert_mode "$HOME/.shman/store/bin/deploy.sh" 755 "store copy is 755"
assert_mode "$HOME/bin/deploy.sh" 755 "home copy is 755"

# sync resets every kind of permission drift, content preserved.
sandbox
run init
printf 'KEY\n' >key
chmod 600 key
run link key key
printf 'data\n' >cfg
chmod 644 cfg
run copy cfg cfg
mkdir -p d/sub
printf 'x\n' >d/sub/f
chmod 700 d
run copy d d -r
chmod 777 "$HOME/cfg"            # home copy mode drift (readable)
chmod 000 "$HOME/.shman/store/cfg"     # store copy unreadable
chmod 000 "$HOME/.shman/store/key"     # symlinked store file unreadable
chmod 777 "$HOME/d"              # tracked dir top mode drift
run sync
assert_rc 0 "sync returns 0"
assert_mode "$HOME/cfg" 644 "home copy mode restored"
assert_mode "$HOME/.shman/store/cfg" 644 "unreadable store copy restored"
assert_mode "$HOME/.shman/store/key" 600 "unreadable symlinked store file restored"
assert_mode "$HOME/d" 700 "tracked directory top mode restored"
assert_file_is "$HOME/cfg" "data" "content preserved through mode repair"

# repair resets the same drift (including the unreadable store copy) without
# losing the deployed copy.
sandbox
run init
printf 'KEY\n' >key
chmod 600 key
run link key key
printf 'data\n' >cfg
chmod 644 cfg
run copy cfg cfg
chmod 000 "$HOME/.shman/store/cfg"
chmod 000 "$HOME/.shman/store/key"
chmod 777 "$HOME/cfg"
run repair
assert_rc 0 "repair returns 0"
assert_mode "$HOME/.shman/store/cfg" 644 "unreadable store copy restored by repair"
assert_mode "$HOME/.shman/store/key" 600 "symlinked store file restored by repair"
assert_mode "$HOME/cfg" 644 "home copy mode restored by repair"
assert_file_is "$HOME/cfg" "data" "deployed copy not lost during repair"

# Mode enforcement is idempotent.
sandbox
run init
printf 'a\n' >f
chmod 640 f
run copy f f
run sync
assert_match "$OUT" "0 files updated" "clean sync changes nothing"

report
