#!/bin/sh
# Run the whole shman test suite. Each test_*.sh is independent and is also
# runnable on its own (e.g. `sh tests/test_link.sh`).

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SHMAN=${SHMAN:-"$here/../shman.sh"}
export SHMAN

failed=0
for t in "$here"/test_*.sh; do
	[ "$t" = "$here/test_lib.sh" ] && continue
	sh "$t" || failed=$((failed + 1))
done

echo "------------------------------------------"
if [ "$failed" -eq 0 ]; then
	echo "ALL SUITES PASSED"
else
	echo "$failed SUITE(S) FAILED"
fi
[ "$failed" -eq 0 ]
