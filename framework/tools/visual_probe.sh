#!/usr/bin/env bash
# Visual probe — runs the REAL game under Xvfb (software GL) and saves a
# viewport screenshot of the requested screen/dialog. This is the visual
# iteration loop: pure --headless uses Godot's dummy renderer (no pixels),
# but Xvfb gives the real mobile renderer + mesa software GL a display.
#
# Usage: tools/visual_probe.sh <target> [WIDTHxHEIGHT]
#   targets: home | social | profile | settings | shop | banner_create | text_dialog | banner_debug
#            zone_daily_gift | zone_piggy | zone_streak | zone_claim | zone_tournament
#            gift_pile | gift_pile_danger
#   optional resolution simulates a device aspect (stretch mode is canvas_items+expand),
#   e.g. 720x1560 for a tall phone. Prints PROBE_SAVED <path to PNG> + any DBG lines.
set -e
cd "$(dirname "$0")/.."
TARGET="${1:?usage: visual_probe.sh <target> [WIDTHxHEIGHT]}"
RESOLUTION="${2:-}"
if ! command -v xvfb-run >/dev/null 2>&1; then
	echo "xvfb-run not found — install once with: sudo apt-get install -y xvfb" >&2
	exit 1
fi
EXTRA=()
XVFB_ARGS=()
if [ -n "$RESOLUTION" ]; then
	H="${RESOLUTION#*x}"
	EXTRA+=(--resolution "$RESOLUTION")
	# Xvfb's default screen is too small for tall device simulations.
	XVFB_ARGS=(-s "-screen 0 800x${H}x24")
fi
xvfb-run -a "${XVFB_ARGS[@]}" ~/tools/godot --path . --rendering-driver opengl3 "${EXTRA[@]}" -- "probe=$TARGET" 2>&1 | grep -E "PROBE_SAVED|DBG|ERROR|Script error" || true
