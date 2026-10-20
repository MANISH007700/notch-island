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
GEMINI="$HOME/.gemini/settings.json"
COPILOT_HOOKS="${COPILOT_HOME:-$HOME/.copilot}/hooks/notch-island.json"
CURSOR="$HOME/.cursor/hooks.json"

# Green check marks when printing to a terminal, plain text otherwise.
if [ -t 1 ]; then GREEN=$(printf '\033[32m'); DIM=$(printf '\033[2m'); BOLD=$(printf '\033[1m'); RESET=$(printf '\033[0m')
else GREEN=; DIM=; BOLD=; RESET=; fi
ok() { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }

# edit_hooks <file> <install|uninstall> <claude|codex|gemini|cursor>
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
    "gemini": ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool", "Notification"],
    "cursor": ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "postToolUse", "afterAgentResponse", "stop"],
}[agent]

with open(path) as f:
    settings = json.load(f)

if agent == "cursor":
    # Cursor's hooks.json: {"version": 1, "hooks": {"event": [{"command": ...}]}}, no groups.
    hooks = settings.setdefault("hooks", {})
    for event in list(hooks):
        hooks[event] = [h for h in hooks[event] if "notch-island-hook" not in h.get("command", "")]
        if not hooks[event]:
            del hooks[event]
    if mode == "install":
        settings.setdefault("version", 1)
        for event in EVENTS:
            hooks.setdefault(event, []).append({"command": HOOK})
    if not hooks:
        del settings["hooks"]
    if settings == {"version": 1}:
        settings = {}
    with open(path, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    sys.exit(0)

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
        group = {"hooks": [hook]}
        if agent == "claude" and event != "PermissionRequest":
            hook["async"] = True  # never slow Claude down; only approvals wait for the notch
        if agent == "gemini":
            hook.update({"name": "notch-island", "timeout": 5000})
            if event in ("BeforeTool", "AfterTool"):
                group = {"matcher": ".*", "hooks": [hook]}
        hooks.setdefault(event, []).append(group)
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

# Copilot CLI loads every file in ~/.copilot/hooks; ours is its own file. PascalCase events send Claude Code's fields.
copilot_hooks() {
  mkdir -p "$(dirname "$COPILOT_HOOKS")"
  /usr/bin/python3 - "$COPILOT_HOOKS" <<'PY'
import json, sys
HOOK = '/bin/sh -c \'[ -x "$HOME/.notch-island/bin/notch-island-hook" ] && "$HOME/.notch-island/bin/notch-island-hook" --agent copilot; exit 0\''
events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "notification"]
config = {"version": 1, "hooks": {e: [{"type": "command", "bash": HOOK, "timeoutSec": 10}] for e in events}}
with open(sys.argv[1], "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY
}

# found <dir> <command> [<app>]: is this agent on this Mac?
found() {
  [ -d "$1" ] || command -v "$2" >/dev/null 2>&1 || { [ -n "${3:-}" ] && [ -d "$3" ]; }
}

# want <id> <name> <found? yes|no>: connect this agent?
# NOTCH_ISLAND_AGENTS="claude gemini" picks agents explicitly. Otherwise each agent found is offered: asked in a
# terminal (Enter means yes), connected without asking when the installer is not interactive.
want() {
  if [ -n "${NOTCH_ISLAND_AGENTS:-}" ]; then
    case " $NOTCH_ISLAND_AGENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
  fi
  [ "$3" = yes ] || return 1
  [ -t 0 ] || return 0
  printf '  Connect %s? [Y/n] ' "$2"
  read -r reply || reply=
  case "$reply" in [nN]*) return 1 ;; *) return 0 ;; esac
}

yes_if() { if "$@"; then echo yes; else echo no; fi; }

stop_app() {
  launchctl bootout "gui/$(id -u)/local.notch-island" 2>/dev/null || true
  pkill -x NotchIsland 2>/dev/null || true
}

if [ "${1:-}" = "uninstall" ]; then
  stop_app
  [ -f "$CLAUDE" ] && edit_hooks "$CLAUDE" uninstall claude
  [ -f "$CODEX" ] && edit_hooks "$CODEX" uninstall codex
  [ -f "$GEMINI" ] && edit_hooks "$GEMINI" uninstall gemini
  [ -f "$CURSOR" ] && edit_hooks "$CURSOR" uninstall cursor
  rm -rf "$APP" "$BIN" "$AGENT" "$OPENCODE_PLUGIN" "$COPILOT_HOOKS"
  ok "Notch Island removed"
  printf '  %sEach config%ss pre-install copy is next to it, ending in .bak-notch-island.%s\n' "$DIM" "'" "$RESET"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Notch Island is built from source and needs the Xcode Command Line Tools."
  echo "Install them with:  xcode-select --install   then run ./install.sh again."
  exit 1
fi

printf '%sNotch Island%s\n' "$BOLD" "$RESET"
mkdir -p build
swiftc -O Sources/Shared/*.swift Sources/Hook/main.swift -o build/notch-island-hook
swiftc -O Sources/Shared/*.swift Sources/App/*.swift -o build/NotchIsland
ok "Built from source"

stop_app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$BIN" "$HOME/.notch-island/run" "$HOME/Library/LaunchAgents"
cp build/NotchIsland "$APP/Contents/MacOS/"
cp build/notch-island-hook "$APP/Contents/Helpers/"
cp Info.plist "$APP/Contents/"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
ln -sf "$APP/Contents/Helpers/notch-island-hook" "$BIN/notch-island-hook"
ok "Installed to ~/Applications/Notch Island.app"

# Each agent: connect it, or take Notch Island out of it (so re-running the installer can switch one off).
if want claude "Claude Code" yes; then
  mkdir -p "$HOME/.claude"
  edit_hooks "$CLAUDE" install claude
  ok "Claude Code connected"
elif [ -f "$CLAUDE" ]; then edit_hooks "$CLAUDE" uninstall claude; fi

if want codex "Codex" "$(yes_if found "$HOME/.codex" codex)"; then
  mkdir -p "$HOME/.codex"
  edit_hooks "$CODEX" install codex
  ok "Codex connected  ${DIM}(first time: open Codex, run /hooks and approve the Notch Island entries)${RESET}"
elif [ -f "$CODEX" ]; then edit_hooks "$CODEX" uninstall codex; fi

if want opencode "OpenCode" "$(yes_if found "$HOME/.config/opencode" opencode)"; then
  mkdir -p "$(dirname "$OPENCODE_PLUGIN")"
  cp integrations/opencode/notch-island.js "$OPENCODE_PLUGIN"
  ok "OpenCode connected"
else rm -f "$OPENCODE_PLUGIN"; fi

if want gemini "Gemini CLI" "$(yes_if found "$HOME/.gemini" gemini)"; then
  mkdir -p "$HOME/.gemini"
  edit_hooks "$GEMINI" install gemini
  ok "Gemini CLI connected"
elif [ -f "$GEMINI" ]; then edit_hooks "$GEMINI" uninstall gemini; fi

if want copilot "GitHub Copilot CLI" "$(yes_if found "${COPILOT_HOME:-$HOME/.copilot}" copilot)"; then
  copilot_hooks
  ok "GitHub Copilot CLI connected"
else rm -f "$COPILOT_HOOKS"; fi

if want cursor "Cursor" "$(yes_if found "$HOME/.cursor" cursor-agent /Applications/Cursor.app)"; then
  mkdir -p "$HOME/.cursor"
  edit_hooks "$CURSOR" install cursor
  ok "Cursor connected"
elif [ -f "$CURSOR" ]; then edit_hooks "$CURSOR" uninstall cursor; fi

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
ok "Running, and starts at login"
echo
echo "Hover or click the notch to open it. Settings are behind the gear icon."
