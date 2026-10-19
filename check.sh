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
out, _, _, _ = run("deny")
check(json.loads(out)["hookSpecificOutput"]["decision"]["behavior"] == "deny", "deny")
out, code, _, _ = run("ask")
check(out == "" and code == 0, "ask in terminal: no output, Claude shows its own prompt")
out, code, _, _ = run(None)
check(out == "" and code == 0, "app quits while waiting: no output, Claude shows its own prompt")
out, code, _, _ = run(None, {"session_id": "debug-1", "hook_event_name": "PreToolUse"})
check(out == "" and code == 0, "other events never print anything")
start = time.time()
p = subprocess.run([hook], input=json.dumps(req).encode(), capture_output=True, timeout=10)
check(p.stdout == b"" and p.returncode == 0 and time.time() - start < 0.5, "app not running: exits at once with no output")
print("hook checks passed" if not failures else "%d hook check(s) FAILED" % failures)
sys.exit(1 if failures else 0)
PY

echo "settings merge (on copies)"
sed -n "/<<'PY'/,/^PY$/p" install.sh | sed '1d;$d' > "$TMP/merge.py"
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

echo "opencode plugin"
node --check integrations/opencode/notch-island.js && echo "  ok    plugin parses"

echo "all checks passed"
