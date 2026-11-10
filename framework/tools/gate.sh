#!/usr/bin/env bash
# One-command verification gate for the Game Stage Prototype framework.
# Exit 0 = green: import clean (no errors, no warnings — warnings are errors),
# boot shows only the two documented headless audio-teardown lines, the full
# GUT suite passes, and a debug Android APK exports with zero errors.
# See documentation/TDD.md §Verification.
set -u

GODOT="${GODOT_BIN:-$HOME/tools/godot}"
ANDROID_SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

fail() { echo "GATE FAIL: $1"; exit 1; }

echo "== [1/4] Import (parse check) =="
import_log=$(mktemp)
if ! timeout 300 "$GODOT" --headless --path . --import >"$import_log" 2>&1; then
	tail -20 "$import_log"
	fail "godot --import exited nonzero"
fi
if grep -qE "SCRIPT ERROR" "$import_log"; then
	grep -nE "SCRIPT ERROR" "$import_log" | head -20
	fail "SCRIPT ERROR in import output"
fi
if grep -qE "WARNING:" "$import_log"; then
	grep -nE "WARNING:" "$import_log" | head -20
	fail "warnings in import output (warnings are treated as errors)"
fi
echo "   OK"

echo "== [2/4] Boot (60 frames) =="
boot_log=$(mktemp)
if ! timeout 120 "$GODOT" --headless --path . --quit-after 60 >"$boot_log" 2>&1; then
	tail -20 "$boot_log"
	fail "boot exited nonzero"
fi
# Only the two documented headless audio-teardown lines are allowed (NOTES.md).
unexpected=$(grep -E "SCRIPT ERROR|ERROR:|WARNING:" "$boot_log" | grep -vE "WARNING: 2 ObjectDB instances were leaked at exit|ERROR: 1 resources still in use at exit")
if [ -n "$unexpected" ]; then
	echo "$unexpected" | head -20
	fail "unexpected errors/warnings during boot"
fi
echo "   OK"

echo "== [3/4] GUT suite =="
gut_log=$(mktemp)
timeout 300 "$GODOT" --headless --path . -s res://addons/gut/gut_cmdln.gd -gdir=res://tests -gexit >"$gut_log" 2>&1
rc=$?
tail -25 "$gut_log"
[ "$rc" -eq 0 ] || fail "GUT suite exited $rc"
grep -q "All tests passed!" "$gut_log" || fail "GUT did not report all-pass"
echo "   OK"

echo "== [4/4] Android debug export =="
export_log=$(mktemp)
if ! timeout 600 env ANDROID_HOME="$ANDROID_SDK" "$GODOT" --headless --path . \
	--export-debug "Android" build/android/game.apk >"$export_log" 2>&1; then
	tail -20 "$export_log"
	fail "android export exited nonzero"
fi
if grep -qE "ERROR:" "$export_log"; then
	grep -nE "ERROR:" "$export_log" | head -20
	fail "errors in android export output"
fi
[ -s build/android/game.apk ] || fail "APK was not produced"
echo "   OK ($(du -h build/android/game.apk | cut -f1))"

rm -f "$import_log" "$boot_log" "$gut_log" "$export_log"
echo "GATE GREEN: import clean, boot clean, GUT all-pass, Android APK built."
