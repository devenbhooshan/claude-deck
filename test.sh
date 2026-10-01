#!/bin/bash
# Runs the Core tests with coverage and fails unless every line of Sources/ClaudeDeck/Core is covered.
# Needs only the Command Line Tools (no Xcode): tests are compiled straight into a runner with swiftc.
set -euo pipefail
cd "$(dirname "$0")"
OUT=.build/tests
mkdir -p "$OUT"
rm -f "$OUT"/*.profraw

swiftc -swift-version 5 -Onone -profile-generate -profile-coverage-mapping \
  -o "$OUT/runner" Sources/ClaudeDeck/Core/*.swift Tests/*.swift

LLVM_PROFILE_FILE="$OUT/tests.profraw" "$OUT/runner"

xcrun llvm-profdata merge -sparse "$OUT/tests.profraw" -o "$OUT/tests.profdata"
echo
xcrun llvm-cov report "$OUT/runner" -instr-profile="$OUT/tests.profdata" Sources/ClaudeDeck/Core \
  | sed -e "s|$PWD/||" | awk '$1 ~ /\.swift$|^TOTAL$/ { printf "%-48s lines %6s/%-6s %s\n", $1, $8-$9, $8, $10 }'

MISSED=$(xcrun llvm-cov report "$OUT/runner" -instr-profile="$OUT/tests.profdata" Sources/ClaudeDeck/Core \
  | awk '/^TOTAL/ { print $9 }')
if [[ "$MISSED" != "0" ]]; then
  echo
  echo "Never executed:"
  xcrun llvm-cov export -format=text "$OUT/runner" -instr-profile="$OUT/tests.profdata" Sources/ClaudeDeck/Core \
    | scripts/uncovered.py | head -${UNCOVERED_LIMIT:-80}
  echo
  echo "FAIL: $MISSED line(s) of Core are not covered by tests"
  exit 1
fi
echo
echo "OK: 100% line coverage of Core"
