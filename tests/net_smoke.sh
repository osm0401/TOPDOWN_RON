#!/usr/bin/env bash
# Two-process online smoke test on one machine (localhost), Linux / CI version of net_smoke.ps1.
# Usage: tests/net_smoke.sh [godot binary] [scenario ...]
#   no scenario: the full play script plus the briefing, loadout, doors, shots, cover, result and
#   vote (retry) scenarios. Each run starts a scripted host and client and checks both print identical FINAL
#   states (positions, doors, players, weapons, NPCs, mission, score, loadouts).
# SHOTS=dir: run both with a display (xvfb-run) and save each side's screenshot there.
set -u
GODOT="${1:-godot}"
shift || true
SCENARIOS=("$@")
[ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=("" briefing loadout doors shots cover result vote)
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/topdownron_net"
mkdir -p "$OUT"
failed=0
for scn in "${SCENARIOS[@]}"; do
	name="${scn:-play}"
	args=()
	[ -n "$scn" ] && args+=("--scenario=$scn")
	if [ -n "${SHOTS:-}" ]; then
		mkdir -p "$SHOTS"
		run=(xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path "$PROJECT" --audio-driver Dummy --)
		hshot=("--shot=$SHOTS/${name}_host.png"); cshot=("--shot=$SHOTS/${name}_client.png")
	else
		run=("$GODOT" --headless --path "$PROJECT" --)
		hshot=(); cshot=()
	fi
	"${run[@]}" --auto-host "${args[@]}" "${hshot[@]}" > "$OUT/${name}_host.txt" 2>&1 &
	hp=$!
	if [ -n "${SHOTS:-}" ]; then  # drawing (slow without a GPU): wait until the host's world is built
		for i in $(seq 1 240); do grep -q "\[characters\]" "$OUT/${name}_host.txt" 2>/dev/null && break; sleep 1; done
		sleep 5
		limit=600
	else
		sleep 3
		limit=90
	fi
	"${run[@]}" --auto-join "${args[@]}" "${cshot[@]}" > "$OUT/${name}_client.txt" 2>&1 &
	cp=$!
	( sleep $limit; pkill -P $hp; pkill -P $cp; kill $hp $cp 2>/dev/null ) &
	watchdog=$!
	wait $hp; wait $cp
	kill $watchdog 2>/dev/null
	hf=$(grep -a "FINAL" "$OUT/${name}_host.txt" | tail -1 | sed -E 's/^\[[0-9]+\] //')
	cf=$(grep -a "FINAL" "$OUT/${name}_client.txt" | tail -1 | sed -E 's/^\[[0-9]+\] //')
	if [ -n "$hf" ] && [ "$hf" = "$cf" ]; then
		echo "$name PASS  $hf"
	else
		echo "$name FAIL"
		echo "  host:   $hf"
		echo "  client: $cf"
		failed=$((failed + 1))
	fi
done
echo "logs: $OUT"
exit $failed
