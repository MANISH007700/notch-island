#!/bin/sh
# Regenerates the README screenshots from made-up sessions, so no real project ever shows up in them.
# Runs a separate demo copy of the app (scratch HOME, private socket) and pauses the installed one meanwhile.
set -eu
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/notch-island.XXXXXX)  # short path: Unix socket paths max out at 104 bytes
FAKE="$TMP/home"
mkdir -p "$FAKE/.notch-island/run" "$FAKE/projects"
OUT=docs/images
mkdir -p "$OUT"

swiftc -O Sources/Shared/*.swift Sources/App/*.swift -o "$TMP/app"
swiftc -O Sources/Shared/*.swift Sources/Hook/main.swift -o "$TMP/hook"
swiftc -O docs/compose.swift -o "$TMP/compose"

# Usage numbers and a Claude transcript with a title.
NOW=$(date +%s)
printf '{"rate_limits":{"five_hour":{"used_percentage":34,"resets_at":%s},"seven_day":{"used_percentage":18,"resets_at":%s}}}' \
  $((NOW + 9000)) $((NOW + 300000)) > "$FAKE/.notch-island/run/statusline.json"
echo '{"type":"ai-title","aiTitle":"Fix the flaky payments test"}' > "$FAKE/projects/claude.jsonl"

launchctl bootout "gui/$(id -u)/local.notch-island" 2>/dev/null || true
cleanup() {
  kill "$APP_PID" 2>/dev/null || true
  pkill -f "$TMP/hook" 2>/dev/null || true
  [ -f "$HOME/Library/LaunchAgents/local.notch-island.plist" ] && launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.notch-island.plist" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
HOME="$FAKE" NOTCH_ISLAND_DEBUG=1 "$TMP/app" >/dev/null 2>&1 &
APP_PID=$!
sleep 2

send() { printf '%s' "$2" | HOME="$FAKE" "$TMP/hook" --agent "$1"; }
send codex '{"session_id":"demo-codex","cwd":"/Users/you/code/my-app","hook_event_name":"UserPromptSubmit","prompt":"Add Google sign-in to the login page"}'
send codex '{"session_id":"demo-codex","cwd":"/Users/you/code/my-app","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/you/code/my-app/src/auth/google.ts"}}'
send opencode '{"session_id":"demo-opencode","cwd":"/Users/you/code/website","hook_event_name":"UserPromptSubmit","prompt":"Redesign the pricing page","_title":"Redesign the pricing page"}'
send opencode '{"session_id":"demo-opencode","cwd":"/Users/you/code/website","hook_event_name":"Stop","last_assistant_message":"Pricing page redesigned: three plan cards, a **monthly/yearly** toggle and an FAQ. The build passes."}'
send claude '{"session_id":"debug-claude","cwd":"/Users/you/code/api-server","transcript_path":"'"$FAKE"'/projects/claude.jsonl","hook_event_name":"UserPromptSubmit","prompt":"The payments test fails about one run in five, find out why"}'
# The approval waits for an answer, so it runs in the background.
send claude '{"session_id":"debug-claude","cwd":"/Users/you/code/api-server","transcript_path":"'"$FAKE"'/projects/claude.jsonl","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test -- payments --runInBand --repeat 20"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"}]}' >/dev/null &
sleep 1.5

# snap <signal> <name> <open|closed>: send the signal, then keep the snapshot only if the island is in the expected state;
# otherwise toggle again (a signal can land while an animation is still running).
snap() {
  sig=$1
  for attempt in 1 2 3 4; do
    kill -"$sig" "$APP_PID"; sleep 1.5
    h=$(sips -g pixelHeight "$FAKE/.notch-island/run/snapshot.png" | tail -1 | tr -dc 0-9)
    state=closed; [ "$h" -gt 400 ] && state=open
    [ -n "${DEBUG_SNAP:-}" ] && echo "  $2 attempt $attempt via $sig: height $h -> $state" >&2
    if [ "$state" = "$3" ]; then cp "$FAKE/.notch-island/run/snapshot.png" "$TMP/$2.png"; return; fi
    sig=USR1
  done
  echo "could not capture the $3 island for $2"; exit 1
}
snap USR1 closed-waiting closed   # the request opened the island; close it
snap USR1 open open               # and open it again
snap USR2 closed-working closed   # allow the request: the island closes, everything is working or done

"$TMP/compose" "$OUT/hero.png" 1800 $(( $(sips -g pixelHeight "$TMP/open.png" | tail -1 | tr -dc 0-9) + 120 )) "$TMP/open.png"
"$TMP/compose" "$OUT/notch.png" 1800 200 "$TMP/closed-working.png" "$TMP/closed-waiting.png"
echo "wrote $OUT/hero.png and $OUT/notch.png"
