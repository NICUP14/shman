#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="dispatch"

sandbox

# No arguments: usage to stderr, nonzero exit.
run
assert_rc 1 "no args exits 1"
assert_match "$OUT" "Usage" "no args prints usage"

# help is a command; it succeeds.
run help
assert_rc 0 "help exits 0"
assert_match "$OUT" "Usage" "help prints usage"

# Unknown commands are reported.
run frobnicate
assert_rc 1 "unknown command exits 1"
assert_match "$OUT" "unknown command" "names the bad command"

# The top level does not parse options: -h is just an unknown command.
run -h
assert_rc 1 "-h is not parsed as an option"
assert_match "$OUT" "unknown command" "-h treated as a command word"

report
