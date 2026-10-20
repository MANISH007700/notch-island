import Foundation

// Claude Code and Codex send the event shape the app understands (session_id, hook_event_name, prompt,
// tool_name, tool_input, ...). Gemini CLI, Copilot CLI and Cursor speak their own dialects; the hook turns
// their events into that shape. nil means the app has no use for the event.
// These agents never wait on the notch: their approvals stay in their own prompts, which the app only flags.
func normalize(_ event: [String: Any], agent: String?) -> [String: Any]? {
    switch agent {
    case "gemini": return geminiEvent(event)
    case "copilot": return copilotEvent(event)
    case "cursor": return cursorEvent(event)
    default:
        // Cursor also runs Claude Code's hooks, but with its own payload; its own hooks already report that turn.
        return event["cursor_version"] == nil ? event : nil
    }
}

// Gemini CLI tool names, as the cards know them from Claude Code.
private let geminiTools = ["run_shell_command": "Bash", "write_file": "Write", "replace": "Edit", "read_file": "Read",
                           "read_many_files": "Read", "glob": "Glob", "search_file_content": "Grep", "grep": "Grep",
                           "list_directory": "LS", "web_fetch": "WebFetch", "google_web_search": "WebSearch"]

private func geminiEvent(_ e: [String: Any]) -> [String: Any]? {
    let names = ["SessionStart": "SessionStart", "SessionEnd": "SessionEnd", "BeforeAgent": "UserPromptSubmit",
                 "BeforeTool": "PreToolUse", "AfterTool": "PostToolUse", "AfterAgent": "Stop", "Notification": "Notification"]
    guard let name = e["hook_event_name"] as? String, let mapped = names[name] else { return nil }
    var out = e
    out["hook_event_name"] = mapped
    if let tool = e["tool_name"] as? String { out["tool_name"] = geminiTools[tool] ?? tool }
    if name == "AfterAgent" { out["last_assistant_message"] = e["prompt_response"] }
    if name == "Notification" {
        // Sent as Gemini's own approval prompt opens, e.g. "Confirm Write: hello.txt".
        guard e["notification_type"] as? String == "ToolPermission" else { return nil }
        out["notification_type"] = "permission_prompt"
        out["message"] = (e["details"] as? [String: Any])?["title"] as? String ?? e["message"]
    }
    return out
}

// Registered under Copilot's PascalCase event names, which already use Claude Code's fields and tool names;
// its notification event still says sessionId.
private func copilotEvent(_ e: [String: Any]) -> [String: Any]? {
    guard let name = e["hook_event_name"] as? String else { return nil }
    var out = e
    if out["session_id"] == nil { out["session_id"] = e["sessionId"] }
    switch name {
    case "Notification":
        guard e["notification_type"] as? String == "permission_prompt" else { return nil }
    case "Stop":
        out["last_assistant_message"] = copilotReply(e["transcript_path"] as? String)
    default:
        break
    }
    return out
}

// Copilot's and Cursor's Stop carry no reply text, but their session logs end with it. Copilot fires Stop a moment
// before it writes that reply, so this waits up to 2 s for one newer than the turn's prompt (never an older turn's).
// `role` says what a log line is: "user" for a prompt, "reply" (with its text) for an answer, nil otherwise.
private func latestReply(_ path: String?, _ role: ([String: Any]) -> (kind: String, text: String?)?) -> String? {
    guard let path else { return nil }
    for attempt in 0..<20 {
        if attempt > 0 { usleep(100_000) }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)  // the tail is enough
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        try? handle.close()
        for line in tail.split(separator: "\n").reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let (kind, text) = role(json) else { continue }
            if kind == "user" { break }  // reached this turn's prompt: no reply yet
            if let text, !text.isEmpty { return text }
        }
    }
    return nil
}

// Copilot: {"type": "user.message", ...} and {"type": "assistant.message", "data": {"content": "..."}}
func copilotReply(_ path: String?) -> String? {
    latestReply(path) { json in
        switch json["type"] as? String {
        case "user.message": ("user", nil)
        case "assistant.message": ("reply", (json["data"] as? [String: Any])?["content"] as? String)
        default: nil
        }
    }
}

// Cursor: {"role": "user", ...} and {"role": "assistant", "message": {"content": [{"type": "text", "text": "..."}, ...]}}
func cursorReply(_ path: String?) -> String? {
    latestReply(path) { json in
        switch json["role"] as? String {
        case "user": ("user", nil)
        case "assistant":
            ("reply", ((json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [])
                .last { $0["type"] as? String == "text" }?["text"] as? String)
        default: nil
        }
    }
}

private func cursorEvent(_ e: [String: Any]) -> [String: Any]? {
    guard let name = e["hook_event_name"] as? String,
          let id = (e["conversation_id"] ?? e["session_id"]) as? String else { return nil }
    // cwd is often sent empty; the workspace is the project.
    let cwd = (e["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (e["workspace_roots"] as? [String])?.first ?? ""
    var out: [String: Any] = ["session_id": id, "cwd": cwd]
    switch name {
    case "sessionStart":
        out["hook_event_name"] = "SessionStart"
    case "sessionEnd":
        out["hook_event_name"] = "SessionEnd"
    case "beforeSubmitPrompt":
        out["hook_event_name"] = "UserPromptSubmit"
        out["prompt"] = e["prompt"]
    case "postToolUse":
        // Cursor only reports a tool once it ran, so this is what it is working on now.
        out["hook_event_name"] = "PreToolUse"
        out["tool_name"] = e["tool_name"] as? String == "Shell" ? "Bash" : e["tool_name"]
        out["tool_input"] = e["tool_input"]
    case "afterAgentResponse":
        // The Cursor app sends its reply here; the CLI does not, so stop reads it from the transcript as well.
        out["hook_event_name"] = "AssistantMessage"
        out["last_assistant_message"] = e["text"]
    case "stop":
        let status = e["status"] as? String
        out["hook_event_name"] = status == "error" ? "StopFailure" : "Stop"
        if status == "error" { out["error"] = "agent_error" }
        out["last_assistant_message"] = cursorReply(e["transcript_path"] as? String)
    default:
        return nil
    }
    return out
}
