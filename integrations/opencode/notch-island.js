// Notch Island plugin for OpenCode: turns OpenCode's session events into Notch Island hook events.
// Installed by ./install.sh to ~/.config/opencode/plugins/notch-island.js. Does nothing if the app is not installed.
import { spawn } from "node:child_process"
import { homedir } from "node:os"

const HOOK = `${homedir()}/.notch-island/bin/notch-island-hook`

// OpenCode tool ids -> the names Notch Island shows icons for.
const TOOLS = { bash: "Bash", read: "Read", edit: "Edit", write: "Write", grep: "Grep", glob: "Glob", webfetch: "WebFetch", task: "Task", todowrite: "TodoWrite" }

export const NotchIsland = async ({ directory }) => {
  const roles = new Map()    // messageID -> "user" | "assistant"
  const replies = new Map()  // sessionID -> latest assistant text
  const dirs = new Map()     // sessionID -> working directory

  // Fire and forget: the hook forwards to the app and exits; errors (app not installed) are ignored.
  const send = (sessionID, event) => {
    const child = spawn(HOOK, ["--agent", "opencode"], { stdio: ["pipe", "ignore", "ignore"] })
    child.on("error", () => {})
    child.stdin.on("error", () => {})
    child.stdin.end(JSON.stringify({ session_id: sessionID, cwd: dirs.get(sessionID) ?? directory, ...event }))
  }

  return {
    event: async ({ event }) => {
      const p = event.properties ?? {}
      switch (event.type) {
        case "session.created":
          dirs.set(p.info.id, p.info.directory)
          send(p.info.id, { hook_event_name: "SessionStart" })
          break
        case "session.updated":
          // OpenCode names sessions "New session - <date>" until it generates a real title.
          if (p.info?.title && !p.info.title.startsWith("New session")) send(p.info.id, { hook_event_name: "TitleChanged", _title: p.info.title })
          break
        case "message.updated":
          roles.set(p.info.id, p.info.role)
          break
        case "message.part.updated": {
          const part = p.part
          if (part?.type !== "text" || !part.text) break
          if (roles.get(part.messageID) === "user") send(part.sessionID, { hook_event_name: "UserPromptSubmit", prompt: part.text.replace(/^"|"$/g, "") })
          else replies.set(part.sessionID, part.text)
          break
        }
        case "permission.asked":
          send(p.sessionID, { hook_event_name: "Notification", notification_type: "permission_prompt", message: "Needs your permission in OpenCode" })
          break
        case "permission.replied":
          send(p.sessionID, { hook_event_name: "PostToolUse" })
          break
        case "session.idle":
          send(p.sessionID, { hook_event_name: "Stop", last_assistant_message: replies.get(p.sessionID) })
          break
        case "session.error":
          send(p.sessionID, { hook_event_name: "StopFailure", error: p.error?.data?.message ?? p.error?.name ?? "Turn failed" })
          break
        case "session.deleted":
          send(p.info?.id ?? p.sessionID, { hook_event_name: "SessionEnd" })
          break
      }
    },
    "tool.execute.before": async (input, output) => {
      const args = output.args ?? {}
      send(input.sessionID, {
        hook_event_name: "PreToolUse",
        tool_name: TOOLS[input.tool] ?? input.tool,
        tool_input: { command: args.command, file_path: args.filePath, pattern: args.pattern, url: args.url, description: args.description },
      })
    },
  }
}
