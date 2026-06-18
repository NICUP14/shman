#!/bin/sh
# Shared helpers for the shman test suite (POSIX sh).
#
# A test file sources this, sets SUITE, then runs assertions. Call sandbox()
# to start each independent scenario in a fresh, isolated HOME. End with
# report(), whose return status becomes the script's exit code.

# Resolve shman.sh relative to this file unless the runner already exported it.
_lib_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SHMAN=${SHMAN:-"$_lib_dir/../shman.sh"}

PASS=0
FAIL=0
SBX=""

# Fresh, isolated HOME for the next block of assertions.
sandbox() {
	[ -n "$SBX" ] && rm -rf "$SBX" >/dev/null 2>&1
	SBX=$(mktemp -d)
	HOME=$SBX
	export HOME
	cd "$SBX" || exit 1
}

# run <shman-args...>  ->  sets RC (exit code) and OUT (combined stdout+stderr).
run() {
	OUT=$(sh "$SHMAN" "$@" 2>&1)
	RC=$?
}

# Is a usable pseudo-terminal tool available (for the interactive repair prompt)?
have_pty() {
	command -v script >/dev/null 2>&1 || return 1
	script -qec true /dev/null >/dev/null 2>&1
}

# pty_repair <answer>  ->  run `shman repair` under a pty, feeding <answer> to
# the prompt. Sets RC and OUT.
pty_repair() {
	OUT=$(printf '%s\n' "$1" | script -qec "sh '$SHMAN' repair" /dev/null 2>&1)
	RC=$?
}

_pass() { PASS=$((PASS + 1)); }
_fail() {
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s\n' "$1" >&2
	[ -n "$2" ] && printf '      %s\n' "$2" >&2
}

skip() { printf 'SKIP: %s\n' "$1"; }

assert_rc() { # expected label  (compares against global RC set by run/pty_repair)
	if [ "$1" = "$RC" ]; then _pass; else _fail "$2" "expected rc=$1, got $RC"; fi
}
assert_eq() { # expected actual label
	if [ "$1" = "$2" ]; then _pass; else _fail "$3" "expected [$1], got [$2]"; fi
}
assert_mode() { # path expected label
	m=$(stat -c '%a' "$1" 2>/dev/null)
	if [ "$m" = "$2" ]; then _pass; else _fail "$3" "mode of $1: expected $2, got ${m:-<none>}"; fi
}
assert_symlink() { # path label
	if [ -L "$1" ]; then _pass; else _fail "$2" "$1 is not a symlink"; fi
}
assert_link_to() { # path target label
	t=$(readlink "$1" 2>/dev/null)
	if [ "$t" = "$2" ]; then _pass; else _fail "$3" "$1 -> ${t:-<none>}, expected $2"; fi
}
assert_exists() {
	if [ -e "$1" ] || [ -L "$1" ]; then _pass; else _fail "$2" "$1 does not exist"; fi
}
assert_missing() {
	if [ -e "$1" ] || [ -L "$1" ]; then _fail "$2" "$1 exists but should not"; else _pass; fi
}
assert_file_is() { # path expected-content label
	c=$(cat "$1" 2>/dev/null)
	if [ "$c" = "$2" ]; then _pass; else _fail "$3" "content of $1: expected [$2], got [$c]"; fi
}
assert_match() { # haystack needle label
	case "$1" in
	*"$2"*) _pass ;;
	*) _fail "$3" "expected to contain [$2], got [$1]" ;;
	esac
}

report() {
	printf '%-14s %d passed, %d failed\n' "${SUITE:-tests}:" "$PASS" "$FAIL"
	[ -n "$SBX" ] && rm -rf "$SBX" >/dev/null 2>&1
	[ "$FAIL" -eq 0 ]
}
