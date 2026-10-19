#!/bin/sh
# Build Notch Island, install it to ~/Applications, wire it into your coding agents, start it at login.
# ./install.sh            install or update
# ./install.sh uninstall  remove the app, the hooks and the login item
set -eu
cd "$(dirname "$0")"

APP="$HOME/Applications/Notch Island.app"
BIN="$HOME/.notch-island/bin"
AGENT="$HOME/Library/LaunchAgents/local.notch-island.plist"
CLAUDE="$HOME/.claude/settings.json"
CODEX="$HOME/.codex/hooks.json"
OPENCODE_PLUGIN="$HOME/.config/opencode/plugins/notch-island.js"

# edit_hooks <file> <install|uninstall> <claude|codex>
edit_hooks() {
  [ -f "$1" ] || echo '{}' > "$1"
  # One backup of the file as it was before Notch Island ever touched it.
  [ -f "$1.bak-notch-island" ] || cp -p "$1" "$1.bak-notch-island"
  /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, mode, agent = sys.argv[1], sys.argv[2], sys.argv[3]
HOOK = '/bin/sh -c \'[ -x "$HOME/.notch-island/bin/notch-island-hook" ] && "$HOME/.notch-island/bin/notch-island-hook" --agent ' + agent + '; exit 0\''
TEE = 'tee "$HOME/.notch-island/run/statusline.json"'
EVENTS = {
    "claude": ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
               "PermissionRequest", "Notification", "Stop", "StopFailure"],
    "codex": ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
              "PermissionRequest", "Stop"],
}[agent]

with open(path) as f:
    settings = json.load(f)

# Drop our old entries first, so re-running the installer never duplicates them.
hooks = settings.setdefault("hooks", {})
for event in list(hooks):
    for group in hooks[event]:
        group["hooks"] = [h for h in group.get("hooks", []) if "notch-island-hook" not in h.get("command", "")]
    hooks[event] = [g for g in hooks[event] if g["hooks"]]
    if not hooks[event]:
        del hooks[event]

status = settings.get("statusLine")
if agent == "claude" and status and status.get("command", "").startswith(TEE):
    rest = status["command"][len(TEE):].strip()
    if rest.startswith("|"):
        status["command"] = rest[1:].strip()
    else:
        del settings["statusLine"]

if mode == "install":
    for event in EVENTS:
        hook = {"type": "command", "command": HOOK}
        if agent == "claude" and event != "PermissionRequest":
            hook["async"] = True  # never slow Claude down; only approvals wait for the notch
        hooks.setdefault(event, []).append({"hooks": [hook]})
    if agent == "claude":
        # Plan usage (5h / 7d) only reaches the status line, so copy its input to a file the app reads.
        status = settings.get("statusLine")
        if status:
            status["command"] = TEE + " | " + status["command"]
        else:
            settings["statusLine"] = {"type": "command", "command": TEE + " >/dev/null"}
if not hooks:
    del settings["hooks"]

with open(path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

stop_app() {
  launchctl bootout "gui/$(id -u)/local.notch-island" 2>/dev/null || true
  pkill -x NotchIsland 2>/dev/null || true
}

if [ "${1:-}" = "uninstall" ]; then
  stop_app
  [ -f "$CLAUDE" ] && edit_hooks "$CLAUDE" uninstall claude
  [ -f "$CODEX" ] && edit_hooks "$CODEX" uninstall codex
  rm -rf "$APP" "$BIN" "$AGENT" "$OPENCODE_PLUGIN"
  echo "Notch Island removed. Each config's pre-install copy is next to it, ending in .bak-notch-island."
  exit 0
fi

echo "Building..."
mkdir -p build
swiftc -O Sources/Shared/*.swift Sources/Hook/main.swift -o build/notch-island-hook
swiftc -O Sources/Shared/*.swift Sources/App/*.swift -o build/NotchIsland

stop_app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$BIN" "$HOME/.notch-island/run" "$HOME/Library/LaunchAgents"
cp build/NotchIsland "$APP/Contents/MacOS/"
cp build/notch-island-hook "$APP/Contents/Helpers/"
cp Info.plist "$APP/Contents/"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
ln -sf "$APP/Contents/Helpers/notch-island-hook" "$BIN/notch-island-hook"

mkdir -p "$HOME/.claude"
edit_hooks "$CLAUDE" install claude
echo "Claude Code: hooks added."
if [ -d "$HOME/.codex" ]; then
  edit_hooks "$CODEX" install codex
  echo "Codex: hooks added. Open Codex and approve them once with /hooks."
fi
if [ -d "$HOME/.config/opencode" ]; then
  mkdir -p "$(dirname "$OPENCODE_PLUGIN")"
  cp integrations/opencode/notch-island.js "$OPENCODE_PLUGIN"
  echo "OpenCode: plugin added."
fi

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.notch-island</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/NotchIsland</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Notch Island is running. Click the notch to open it."
