"""One made-up agent session for Notch Island screenshots. Runs until its tab closes.

usage: python3 docs/demo_sessions.py approval|question|working|done   (one per terminal tab)
"""
import json, os, subprocess, sys, time

HOOK = os.path.expanduser("~/.notch-island/bin/notch-island-hook")
role = sys.argv[1]
sid = "demo-" + role


def send(event, agent=None):
    """Hand one event to the app through the real hook; returns the hook's answer (approvals block until answered)."""
    event = {"session_id": sid, **event}
    args = [HOOK] + (["--agent", agent] if agent else [])
    return subprocess.run(args, input=json.dumps(event).encode(), capture_output=True).stdout.decode()


def title(text):
    sys.stdout.write(f"\033]1;{text}\007\033]2;{text}\007")
    sys.stdout.flush()


if role == "approval":
    title("api-server")
    cwd = "/Users/demo/api-server"
    send({"hook_event_name": "UserPromptSubmit", "cwd": cwd, "prompt": "Retry failed payments with backoff"})
    edit = {"file_path": cwd + "/src/payments/retry.ts",
            "old_string": "export async function retry(job) {\n  return run(job)\n}",
            "new_string": "export async function retry(job, attempt = 0) {\n  try {\n    return await run(job)\n  } catch (err) {\n    await sleep(2 ** attempt * 250)\n    return retry(job, attempt + 1)\n  }\n}"}
    while True:  # ask again after each answer, so the card is always there for a screenshot
        print("Waiting for approval in the notch…")
        print("Answer:", send({"hook_event_name": "PermissionRequest", "cwd": cwd, "tool_name": "Edit",
                               "tool_input": edit, "permission_suggestions": [{"type": "addRules"}]}) or "(terminal)")
        time.sleep(3)

elif role == "question":
    title("mobile-app")
    cwd = "/Users/demo/mobile-app"
    send({"hook_event_name": "UserPromptSubmit", "cwd": cwd, "prompt": "Add offline mode to the notes screen"})
    question = {"questions": [{"question": "Where should offline notes be stored?", "header": "Storage", "multiSelect": False,
                               "options": [{"label": "SQLite", "description": "Fast queries, survives app updates"},
                                           {"label": "Local files", "description": "One JSON file per note"},
                                           {"label": "Keychain", "description": "Encrypted, best for small data"}]}]}
    while True:
        print("Waiting for an answer in the notch…")
        print("Answer:", send({"hook_event_name": "PermissionRequest", "cwd": cwd, "tool_name": "AskUserQuestion",
                               "tool_input": question}) or "(terminal)")
        time.sleep(3)

elif role == "working":
    title("design-system")
    cwd = "/Users/demo/design-system"
    send({"hook_event_name": "UserPromptSubmit", "cwd": cwd, "prompt": "Migrate the button styles to design tokens"}, "codex")
    while True:
        send({"hook_event_name": "PreToolUse", "cwd": cwd, "tool_name": "Bash",
              "tool_input": {"command": "pnpm test --filter @ui/button"}}, "codex")
        print("Codex is working… (made-up session)")
        time.sleep(20)

elif role == "done":
    title("landing-page")
    cwd = "/Users/demo/landing-page"
    send({"hook_event_name": "UserPromptSubmit", "cwd": cwd, "prompt": "Redesign the pricing section"}, "opencode")
    send({"hook_event_name": "Stop", "cwd": cwd, "last_assistant_message":
          "Pricing redesigned: three plan cards, a **monthly/yearly** toggle and an FAQ. The build passes."}, "opencode")
    print("OpenCode finished (made-up session). Close this tab to remove it.")
    while True:
        time.sleep(3600)
