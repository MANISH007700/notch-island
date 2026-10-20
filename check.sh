#!/bin/sh
# Builds everything and checks the logic end to end, without touching the running app or your settings.
set -eu
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "build (warnings are errors)"
swiftc -O -warnings-as-errors Sources/Shared/*.swift Sources/Hook/main.swift -o "$TMP/hook"
swiftc -O -warnings-as-errors Sources/Shared/*.swift Sources/App/*.swift -o "$TMP/app"
swiftc -O Sources/Shared/*.swift Sources/App/Store.swift Tests/main.swift -o "$TMP/store-checks"
echo "  ok    hook, app and checks compile"

"$TMP/store-checks"

echo "hook round trips (fake app on a private socket)"
export NOTCH_ISLAND_SOCKET="$TMP/island.sock"
/usr/bin/python3 -I - "$TMP/hook" <<'PY'
import json, os, socket, subprocess, sys, threading, time
hook, path = sys.argv[1], os.environ["NOTCH_ISLAND_SOCKET"]
req = {"session_id": "debug-1", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
       "tool_input": {"command": "make"}, "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash"}]}]}
failures = 0

def check(ok, name):
    global failures
    print(("  ok    " if ok else "  FAIL  ") + name)
    failures += not ok

def run(answer, event=req):
    """Fake app: reads the event, sends `answer` (None = just hang up). Returns (stdout, exit code, event seen, seconds)."""
    seen = {}
    server = socket.socket(socket.AF_UNIX)
    server.bind(path); server.listen(1)
    def serve():
        conn, _ = server.accept()
        data = b""
        while not data.endswith(b"\n"):
            data += conn.recv(65536)
        seen.update(json.loads(data))
        if answer is not None:
            conn.sendall((json.dumps({"behavior": answer}) + "\n").encode())
            time.sleep(3)  # keep the socket open: the hook must not wait for it to close
        conn.close()
    t = threading.Thread(target=serve); t.start()
    start = time.time()
    p = subprocess.run([hook], input=json.dumps(event).encode(), capture_output=True, timeout=10)
    took = time.time() - start
    t.join(); server.close(); os.unlink(path)
    return p.stdout.decode(), p.returncode, seen, took

out, code, seen, took = run("allow")
check(json.loads(out)["hookSpecificOutput"]["decision"] == {"behavior": "allow"}, "allow")
check(took < 1.5, "answer is used immediately, not when the socket closes (%.2fs, socket held 3s)" % took)
check("_terminal" in seen and "_agent_pid" in seen, "hook adds terminal and agent info")
out, _, _, _ = run("always")
d = json.loads(out)["hookSpecificOutput"]["decision"]
check(d["behavior"] == "allow" and d["updatedPermissions"] == req["permission_suggestions"], "always allow applies Claude's suggested rules")
ask_q = {"session_id": "debug-1", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
         "tool_input": {"questions": [{"question": "Which db?", "header": "DB", "options": [{"label": "Postgres"}, {"label": "SQLite"}]}]}}
seen = {}
server = socket.socket(socket.AF_UNIX); server.bind(path); server.listen(1)
def answer():
    conn, _ = server.accept()
    while not conn.recv(65536).endswith(b"\n"): pass
    conn.sendall(b'{"answers":{"Which db?":"SQLite"},"behavior":"answer"}\n'); conn.close()
t = threading.Thread(target=answer); t.start()
p = subprocess.run([hook], input=json.dumps(ask_q).encode(), capture_output=True, timeout=10)
t.join(); server.close(); os.unlink(path)
d = json.loads(p.stdout)["hookSpecificOutput"]["decision"]
check(d["behavior"] == "allow" and d["updatedInput"]["answers"] == {"Which db?": "SQLite"}
      and d["updatedInput"]["questions"] == ask_q["tool_input"]["questions"], "answering a question fills in the tool's answers")
out, _, _, _ = run("deny")
check(json.loads(out)["hookSpecificOutput"]["decision"]["behavior"] == "deny", "deny")
out, code, _, _ = run("ask")
check(out == "" and code == 0, "ask in terminal: no output, Claude shows its own prompt")
out, code, _, _ = run(None)
check(out == "" and code == 0, "app quits while waiting: no output, Claude shows its own prompt")
out, code, _, _ = run(None, {"session_id": "debug-1", "hook_event_name": "PreToolUse"})
check(out == "" and code == 0, "other events never print anything")
def relay(args, event):
    """Fake app that only listens: returns (stdout, exit code, event seen) for a hook run with `args`."""
    seen = {}
    server = socket.socket(socket.AF_UNIX); server.bind(path); server.listen(1)
    def serve():
        conn, _ = server.accept()
        data = b""
        while not data.endswith(b"\n"):
            data += conn.recv(65536)
        seen.update(json.loads(data)); conn.close()
    t = threading.Thread(target=serve); t.start()
    p = subprocess.run([hook] + args, input=json.dumps(event).encode(), capture_output=True, timeout=10)
    t.join(); server.close(); os.unlink(path)
    return p.stdout.decode(), p.returncode, seen

out, code, seen = relay(["--agent", "gemini"], {"session_id": "g-1", "cwd": "/tmp", "hook_event_name": "BeforeAgent", "prompt": "hi"})
check(out == "" and code == 0 and seen.get("hook_event_name") == "UserPromptSubmit" and seen.get("_agent") == "gemini",
      "gemini: events arrive translated, and the hook prints nothing")
out, code, seen = relay(["--agent", "cursor"], {"conversation_id": "u-1", "workspace_roots": ["/tmp"], "hook_event_name": "beforeSubmitPrompt", "prompt": "hi"})
check(out == "" and code == 0 and seen.get("session_id") == "u-1" and seen.get("_agent") == "cursor",
      "cursor: events arrive translated, and the hook prints nothing")
start = time.time()
p = subprocess.run([hook, "--agent", "cursor"], input=b'{"hook_event_name":"beforeReadFile","conversation_id":"u-1"}', capture_output=True, timeout=10)
check(p.stdout == b"" and p.returncode == 0 and time.time() - start < 0.5, "unused events exit at once without touching the app")
start = time.time()
p = subprocess.run([hook], input=json.dumps(req).encode(), capture_output=True, timeout=10)
check(p.stdout == b"" and p.returncode == 0 and time.time() - start < 0.5, "app not running: exits at once with no output")
print("hook checks passed" if not failures else "%d hook check(s) FAILED" % failures)
sys.exit(1 if failures else 0)
PY

echo "settings merge (on copies)"
awk "/<<'PY'/ && !n { n = 1; next } n && /^PY$/ { exit } n" install.sh > "$TMP/merge.py"
# merge_check <real config> <agent> <expected number of our hooks>
merge_check() {
  if [ -f "$1" ]; then cp "$1" "$TMP/config.json"; else echo '{}' > "$TMP/config.json"; fi
  /usr/bin/python3 -I "$TMP/merge.py" "$TMP/config.json" uninstall "$2"
  cp "$TMP/config.json" "$TMP/clean.json"
  /usr/bin/python3 -I "$TMP/merge.py" "$TMP/config.json" install "$2"
  /usr/bin/python3 -I "$TMP/merge.py" "$TMP/config.json" install "$2"
  /usr/bin/python3 -I - "$TMP/config.json" "$2" "$3" <<'CHECK'
import json, sys
d, agent, expected = json.load(open(sys.argv[1])), sys.argv[2], int(sys.argv[3])
ours = {k: [h["command"] for g in v for h in g["hooks"] if "notch-island-hook" in h.get("command", "")] for k, v in d["hooks"].items()}
ours = {k: c for k, c in ours.items() if c}
assert len(ours) == expected and all(len(c) == 1 and c[0].endswith("--agent " + agent + "; exit 0'") for c in ours.values()), ours
if agent == "claude":
    assert d["statusLine"]["command"].count("notch-island/run/statusline.json") == 1, d["statusLine"]
else:
    assert "statusLine" not in d or "notch-island" not in json.dumps(d["statusLine"])
print("  ok    %s: installing twice adds each of the %d hooks exactly once" % (agent, expected))
CHECK
  /usr/bin/python3 -I "$TMP/merge.py" "$TMP/config.json" uninstall "$2"
  cmp -s "$TMP/config.json" "$TMP/clean.json" || { echo "  FAIL  $2: uninstall did not restore the config"; exit 1; }
  echo "  ok    $2: uninstall restores the config exactly"
}
merge_check "$HOME/.claude/settings.json" claude 9
merge_check "$HOME/.codex/hooks.json" codex 7
merge_check "$HOME/.gemini/settings.json" gemini 7

# Cursor's hooks.json has no groups: {"version": 1, "hooks": {"event": [{"command": ...}]}}.
if [ -f "$HOME/.cursor/hooks.json" ]; then cp "$HOME/.cursor/hooks.json" "$TMP/cursor.json"; else echo '{}' > "$TMP/cursor.json"; fi
/usr/bin/python3 -I "$TMP/merge.py" "$TMP/cursor.json" uninstall cursor
cp "$TMP/cursor.json" "$TMP/cursor-clean.json"
/usr/bin/python3 -I "$TMP/merge.py" "$TMP/cursor.json" install cursor
/usr/bin/python3 -I "$TMP/merge.py" "$TMP/cursor.json" install cursor
/usr/bin/python3 -I - "$TMP/cursor.json" "$TMP/cursor-clean.json" <<'CHECK'
import json, sys
d, clean = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
ours = {k: [h for h in v if "notch-island-hook" in h["command"]] for k, v in d["hooks"].items()}
ours = {k: v for k, v in ours.items() if v}
assert d["version"] == 1 and len(ours) == 6 and all(len(v) == 1 for v in ours.values()), ours
others = {k: [h for h in v if "notch-island-hook" not in h["command"]] for k, v in d["hooks"].items()}
assert {k: v for k, v in others.items() if v} == clean.get("hooks", {}), "other hooks changed"
print("  ok    cursor: installing twice adds each of the 6 hooks exactly once and keeps other hooks")
CHECK
/usr/bin/python3 -I "$TMP/merge.py" "$TMP/cursor.json" uninstall cursor
cmp -s "$TMP/cursor.json" "$TMP/cursor-clean.json" || { echo "  FAIL  cursor: uninstall did not restore the config"; exit 1; }
echo "  ok    cursor: uninstall restores the config exactly"

echo "installer, in a scratch home (launchctl and pkill stubbed, so the real app and configs are never touched)"
FAKE="$TMP/home"
mkdir -p "$FAKE/.codex" "$FAKE/.config/opencode" "$FAKE/.gemini" "$FAKE/.copilot" "$FAKE/.cursor" "$TMP/shim"
for c in launchctl pkill; do printf '#!/bin/sh\nexit 0\n' > "$TMP/shim/$c"; chmod +x "$TMP/shim/$c"; done
run_install() { HOME="$FAKE" PATH="$TMP/shim:$PATH" COPILOT_HOME= "$@" </dev/null >"$TMP/install.log" 2>&1 || { cat "$TMP/install.log"; exit 1; }; }
# connected <agents...>: exactly these agents carry Notch Island hooks in the scratch home.
connected() {
  /usr/bin/python3 -I - "$FAKE" "$*" <<'CHECK'
import json, os, sys
home, want = sys.argv[1], set(sys.argv[2].split())
def has(path):
    return os.path.exists(path) and "notch-island-hook" in open(path).read()
got = {a for a, ok in {
    "claude": has(home + "/.claude/settings.json"), "codex": has(home + "/.codex/hooks.json"),
    "opencode": os.path.exists(home + "/.config/opencode/plugins/notch-island.js"), "gemini": has(home + "/.gemini/settings.json"),
    "copilot": has(home + "/.copilot/hooks/notch-island.json"), "cursor": has(home + "/.cursor/hooks.json")}.items() if ok}
assert got == want, "connected %s, expected %s" % (sorted(got), sorted(want))
CHECK
}
run_install ./install.sh
connected claude codex opencode gemini copilot cursor
grep -q "Gemini CLI connected" "$TMP/install.log" && grep -q "GitHub Copilot CLI connected" "$TMP/install.log" && grep -q "Cursor connected" "$TMP/install.log"
echo "  ok    not interactive: every agent found is connected"
run_install env NOTCH_ISLAND_AGENTS="claude gemini" ./install.sh
connected claude gemini
echo "  ok    NOTCH_ISLAND_AGENTS picks agents, and running it again disconnects the rest"
run_install ./install.sh uninstall
connected
[ ! -e "$FAKE/Applications/Notch Island.app" ] && [ ! -e "$FAKE/.copilot/hooks/notch-island.json" ]
echo "  ok    uninstall removes the app and every agent's hooks"

echo "opencode plugin"
node --check integrations/opencode/notch-island.js && echo "  ok    plugin parses"

echo "all checks passed"
