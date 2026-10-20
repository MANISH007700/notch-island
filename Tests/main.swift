import AppKit

// Logic checks for the app's store and helpers. Run through ./check.sh.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok    \(name)" : "  FAIL  \(name)")
    if !ok { failures += 1 }
}

print("helpers")
check(cleanPrompt("  Fix the build\nsecond line ") == "Fix the build", "prompt keeps the first line")
check(cleanPrompt("<task-notification><task-id>x</task-id></task-notification>") == nil, "injected task notification is not a prompt")
check(cleanPrompt("<command-name>/compact</command-name> <command-args></command-args>") == "/compact", "slash command shows as its name")
check(cleanPrompt("   ") == nil, "blank prompt ignored")
check(cleanPrompt("[Image #9] get some inspiration") == "get some inspiration", "attachment placeholders are dropped")
check(cleanPrompt("[Pasted text #2 +40 lines]") == "Sent an attachment", "a prompt that is only an attachment says so")
check(describeError("rate_limit") == "Rate limit reached" && describeError("weird_thing") == "Weird Thing" && describeError(nil) == "Turn failed",
      "error codes read as words")
let qs = parseQuestions(["questions": [["question": "Which db?", "header": "DB", "multiSelect": true,
                                         "options": [["label": "Postgres", "description": "Server"], ["label": "SQLite"]]]]])
check(qs.count == 1 && qs[0].options.map(\.label) == ["Postgres", "SQLite"] && qs[0].options[0].detail == "Server" && qs[0].multi,
      "question options are read from AskUserQuestion")
let d = diffLines("Edit", ["old_string": "a\nb\nc", "new_string": "a\nB\nc"])
check(d.map(\.text) == ["b", "B"] && d.map(\.added) == [false, true], "an edit shows only the changed lines")
let codexLine = #"{"type":"event_msg","payload":{"info":{},"rate_limits":{"primary":{"used_percent":25.0,"window_minutes":43200,"resets_at":1794941575},"secondary":{"used_percent":4.5,"window_minutes":300,"resets_at":1794941000}}}}"#
check(codexLimits(codexLine) == [Limit(label: "30d", percent: 25, resetsAt: 1794941575), Limit(label: "5h", percent: 4.5, resetsAt: 1794941000)],
      "Codex usage windows are read from its log line and labelled by length")
check(shortPath(home + "/Desktop/x.txt") == "~/Desktop/x.txt", "home shortened to ~")
check(shortPath("/private/tmp/a/b/c/d.output") == "…/b/c/d.output", "long path keeps the last 3 parts")

print("transcript summary")
let transcript = NSTemporaryDirectory() + "notch-island-check-\(getpid()).jsonl"
let lines: [[String: Any]] = [
    ["type": "ai-title", "aiTitle": "Old title"],
    ["type": "user", "message": ["content": "Build the island"]],
    ["type": "assistant", "message": ["content": [["type": "text", "text": "First reply"]]]],
    ["type": "user", "message": ["content": [["type": "tool_result", "content": "ok"]]]],
    ["type": "user", "isMeta": true, "message": ["content": "meta, not yours"]],
    ["type": "user", "message": ["content": "<task-notification>done</task-notification>"]],
    ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash"], ["type": "text", "text": "Final **reply**"]]]],
    ["type": "ai-title", "aiTitle": "New title"],
]
let body = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
try! (body + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
let summary = transcriptSummary(transcript)
check(summary.title == "New title", "latest ai-title wins")
check(summary.prompt == "Build the island", "skips tool results, meta and injected prompts")
check(summary.reply == "Final **reply**", "last assistant text")
check(transcriptSummary("/nonexistent").title == nil, "missing transcript is harmless")
try? FileManager.default.removeItem(atPath: transcript)

print("agent adapters (payloads captured from real Gemini CLI 0.64 and Copilot CLI 1.0.100 runs)")
let gSession: [String: Any] = ["session_id": "g-1", "cwd": "/tmp/play"]
func gemini(_ extra: [String: Any]) -> [String: Any]? { normalize(gSession.merging(extra) { $1 }, agent: "gemini") }
check(gemini(["hook_event_name": "BeforeAgent", "prompt": "create hello.txt"])?["hook_event_name"] as? String == "UserPromptSubmit",
      "Gemini: BeforeAgent is the prompt")
let gTool = gemini(["hook_event_name": "BeforeTool", "tool_name": "write_file", "tool_input": ["file_path": "/tmp/play/hello.txt", "content": "hi"]])
check(gTool?["hook_event_name"] as? String == "PreToolUse" && gTool?["tool_name"] as? String == "Write", "Gemini: tools get Claude's names")
let gAsk = gemini(["hook_event_name": "Notification", "notification_type": "ToolPermission", "message": "Tool Confirm Write: hello.txt requires editing",
                   "details": ["type": "edit", "title": "Confirm Write: hello.txt"]])
check(gAsk?["notification_type"] as? String == "permission_prompt" && gAsk?["message"] as? String == "Confirm Write: hello.txt",
      "Gemini: its approval prompt flags the card with the prompt's title")
check(gemini(["hook_event_name": "Notification", "notification_type": "Other"]) == nil, "Gemini: other notifications are ignored")
let gStop = gemini(["hook_event_name": "AfterAgent", "prompt": "x", "prompt_response": "Done: hello.txt now contains hi."])
check(gStop?["hook_event_name"] as? String == "Stop" && gStop?["last_assistant_message"] as? String == "Done: hello.txt now contains hi.",
      "Gemini: AfterAgent finishes the turn with its reply")
check(gemini(["hook_event_name": "BeforeModel"]) == nil, "Gemini: model events are ignored")

let copilotLog = NSTemporaryDirectory() + "notch-island-copilot-\(getpid()).jsonl"
try! """
{"type":"assistant.message","data":{"content":"Created `bye.txt` containing `bye`."}}
{"type":"assistant.message","data":{"content":"","toolRequests":[]}}
{"type":"assistant.turn_end","data":{"turnId":"2"}}

""".write(toFile: copilotLog, atomically: true, encoding: .utf8)
let cStop = normalize(["hook_event_name": "Stop", "session_id": "c-1", "cwd": "/tmp/play", "stop_reason": "end_turn", "transcript_path": copilotLog], agent: "copilot")
check(cStop?["last_assistant_message"] as? String == "Created `bye.txt` containing `bye`.", "Copilot: the reply is read from its session log")
// Copilot fires Stop before its reply reaches the log: never show the previous turn's reply, wait for this one.
try! """
{"type":"user.message","data":{"content":"first"}}
{"type":"assistant.message","data":{"content":"Old reply"}}
{"type":"user.message","data":{"content":"second"}}

""".write(toFile: copilotLog, atomically: true, encoding: .utf8)
DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
    let h = FileHandle(forWritingAtPath: copilotLog)!
    h.seekToEndOfFile(); h.write(Data(#"{"type":"assistant.message","data":{"content":"New reply"}}"#.utf8 + [0x0A])); h.closeFile()
}
check(copilotReply(copilotLog) == "New reply", "Copilot: a reply written just after Stop is waited for, an older turn's is never used")
try? FileManager.default.removeItem(atPath: copilotLog)
let cAsk = normalize(["sessionId": "c-1", "cwd": "/tmp/play", "message": "Run command: ls", "title": "Permission needed",
                      "hook_event_name": "Notification", "notification_type": "permission_prompt"], agent: "copilot")
check(cAsk?["session_id"] as? String == "c-1" && cAsk?["notification_type"] as? String == "permission_prompt",
      "Copilot: its permission prompt flags the card (sessionId becomes session_id)")
check(normalize(["sessionId": "c-1", "hook_event_name": "Notification", "notification_type": "agent_idle"], agent: "copilot") == nil,
      "Copilot: other notifications are ignored")

print("agent adapters (payloads captured from a real cursor-agent run)")
let uPrompt = normalize(["hook_event_name": "beforeSubmitPrompt", "conversation_id": "u-1", "session_id": "u-1", "workspace_roots": ["/tmp/play"],
                         "prompt": "create a file cursor.txt", "attachments": []], agent: "cursor")
check(uPrompt?["hook_event_name"] as? String == "UserPromptSubmit" && uPrompt?["session_id"] as? String == "u-1" && uPrompt?["cwd"] as? String == "/tmp/play",
      "Cursor: the conversation is the session, its workspace the folder")
let uShell = normalize(["hook_event_name": "postToolUse", "conversation_id": "u-1", "tool_name": "Shell", "cwd": "", "workspace_roots": ["/tmp/play"],
                        "tool_input": ["command": "ls", "cwd": "", "timeout": 30000]], agent: "cursor")
check(uShell?["tool_name"] as? String == "Bash" && uShell?["cwd"] as? String == "/tmp/play", "Cursor: Shell reads as Bash, and an empty cwd falls back to the workspace")
let cursorLog = NSTemporaryDirectory() + "notch-island-cursor-\(getpid()).jsonl"
try! """
{"role":"user","message":{"content":[{"type":"text","text":"create a file cursor.txt"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"Creating it."},{"type":"tool_use","name":"Write","input":{}}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"Created `cursor.txt` with `hey`."}]}}
{"type":"turn_ended","status":"success"}

""".write(toFile: cursorLog, atomically: true, encoding: .utf8)
let uStop = normalize(["hook_event_name": "stop", "conversation_id": "u-1", "status": "completed", "transcript_path": cursorLog], agent: "cursor")
check(uStop?["hook_event_name"] as? String == "Stop" && uStop?["last_assistant_message"] as? String == "Created `cursor.txt` with `hey`.",
      "Cursor: the reply is read from its transcript (the CLI sends no afterAgentResponse)")
try? FileManager.default.removeItem(atPath: cursorLog)
check(normalize(["hook_event_name": "stop", "conversation_id": "u-1", "status": "error"], agent: "cursor")?["hook_event_name"] as? String == "StopFailure",
      "Cursor: a turn that errors is a failure")
check(normalize(["hook_event_name": "beforeReadFile", "conversation_id": "u-1"], agent: "cursor") == nil, "Cursor: unused events are ignored")
check(normalize(["hook_event_name": "PreToolUse", "session_id": "x"], agent: nil)?["hook_event_name"] as? String == "PreToolUse",
      "Claude Code and Codex events pass through unchanged")
check(normalize(["hook_event_name": "beforeSubmitPrompt", "conversation_id": "u-1", "session_id": "u-1", "cursor_version": "2026.10.19-6bbf2c4",
                 "prompt": "hey"], agent: nil) == nil,
      "Cursor running Claude Code's hooks is ignored there (its own hooks report it, so the card stays Cursor's)")

print("live process check")
let me = getpid()
let myStartMs = (processStart(me) ?? 0) * 1000
check(isLiveClaude(me, startedAt: myStartMs), "live process with matching start time")
check(!isLiveClaude(me, startedAt: myStartMs - 3_600_000), "reused PID (start time an hour off) is stale")
check(!isLiveClaude(99_999, startedAt: nil), "dead PID is stale")

MainActor.assumeIsolated {
    print("store events")
    let store = Store()
    store.muted = true
    let base: [String: Any] = ["session_id": "check-1", "cwd": "/tmp/project"]
    @MainActor func send(_ extra: [String: Any], fd: Int32 = -1) { store.apply(base.merging(extra) { $1 }, fd: fd) }

    send(["hook_event_name": "UserPromptSubmit", "prompt": "Add tests"])
    check(store.sessions["check-1"]?.status == .working && store.sessions["check-1"]?.lastPrompt == "Add tests", "prompt marks the session working")
    send(["hook_event_name": "UserPromptSubmit", "prompt": "<task-notification>x</task-notification>"])
    check(store.sessions["check-1"]?.lastPrompt == "Add tests", "injected prompt does not replace yours")
    send(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "swift test\n--verbose"]])
    check(store.sessions["check-1"]?.activity == "swift test", "tool activity shows the first command line")

    var fds: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    send(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "rm -rf build"],
          "permission_suggestions": [["type": "addRules"]]], fd: fds[0])
    let pending = store.sessions["check-1"]?.pending
    check(store.sessions["check-1"]?.status == .waiting && store.expanded, "permission request waits and opens the island")
    check(pending?.detail == "rm -rf build" && pending?.canAlways == true, "card shows the command and offers Always allow")
    store.respond("check-1", "always")
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fds[1], &buf, buf.count)
    check(String(decoding: buf[0..<max(0, n)], as: UTF8.self) == "{\"behavior\":\"always\"}\n", "answer goes back to the hook as one line")
    check(store.sessions["check-1"]?.pending == nil && !store.expanded, "answered card clears and the island closes")

    send(["hook_event_name": "Stop", "last_assistant_message": "All done"])
    check(store.sessions["check-1"]?.status == .done && store.sessions["check-1"]?.lastMessage == "All done", "Stop marks done with the reply")
    send(["hook_event_name": "SessionEnd"])
    check(store.sessions["check-1"] == nil, "SessionEnd removes the session")
    send(["hook_event_name": "SessionEnd"])
    check(store.sessions["check-1"] == nil, "a second SessionEnd (Gemini sends two) does not bring it back")
    send(["session_id": "check-6", "hook_event_name": "UserPromptSubmit", "prompt": "Hi", "_agent": "cursor"])
    send(["session_id": "check-6", "hook_event_name": "AssistantMessage", "last_assistant_message": "Hello"])
    send(["session_id": "check-6", "hook_event_name": "Stop"])
    check(store.sessions["check-6"]?.status == .done && store.sessions["check-6"]?.lastMessage == "Hello",
          "a reply sent on its own (Cursor) shows when the turn stops")
    store.archive("check-6")

    // An agent that quits without SessionEnd (closing the Codex app) disappears at once, not on the next 5 s sweep.
    let agent = Process()
    agent.executableURL = URL(fileURLWithPath: "/bin/sleep")
    agent.arguments = ["30"]
    try! agent.run()
    send(["session_id": "check-2", "hook_event_name": "SessionStart", "_agent_pid": Int(agent.processIdentifier)])
    kill(agent.processIdentifier, SIGKILL)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check(store.sessions["check-2"] == nil, "agent quitting removes its session within 0.5 s")

    print("settings")
    check(Sound.allCases.allSatisfy { NSSound(named: NSSound.Name($0.file)) != nil } && Set(Sound.allCases.map(\.file)).count == Sound.allCases.count,
          "every event has its own system sound")
    let prefs = UserDefaults.standard
    send(["session_id": "check-3", "hook_event_name": "UserPromptSubmit", "prompt": "Hi", "_agent": "codex"])
    prefs.set(false, forKey: Pref.agent("codex"))
    store.dropAgent("codex")
    check(store.sessions["check-3"] == nil, "switching an agent off drops its cards")
    var off: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &off)
    send(["session_id": "check-3", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "_agent": "codex"], fd: off[0])
    check(store.sessions["check-3"] == nil && read(off[1], &buf, 1) == 0, "a switched-off agent is ignored and asks in its terminal")
    prefs.removeObject(forKey: Pref.agent("codex"))

    prefs.set(false, forKey: Pref.approveInNotch)
    store.expanded = false
    var ask: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &ask)
    send(["session_id": "check-4", "hook_event_name": "PermissionRequest", "tool_name": "Bash"], fd: ask[0])
    check(store.sessions["check-4"]?.status == .waiting && store.sessions["check-4"]?.pending == nil && read(ask[1], &buf, 1) == 0,
          "approvals off: card waits, the terminal shows its own prompt")
    prefs.removeObject(forKey: Pref.approveInNotch)

    prefs.set(false, forKey: Pref.openForApprovals)
    var quiet: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &quiet)
    send(["session_id": "check-5", "hook_event_name": "PermissionRequest", "tool_name": "Bash"], fd: quiet[0])
    check(store.sessions["check-5"]?.pending != nil && !store.expanded, "auto-open off: approval waits without opening the island")
    prefs.removeObject(forKey: Pref.openForApprovals)
    store.archive("check-4")
    store.archive("check-5")

    print("restart recovery")
    store.discover()
    let records = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.claude/sessions"))?.filter { $0.hasSuffix(".json") } ?? []
    if let found = store.sessions.values.first {
        check(true, "discovered \(store.sessions.count) running Claude session(s) from \(records.count) record(s)")
        // A session with no message yet has no transcript file, so only some need one.
        check(store.sessions.values.allSatisfy { $0.agentPID != nil } && store.sessions.values.contains { $0.transcriptPath != nil },
              "discovered sessions have their process, and transcripts where one exists")
        store.archive(found.id)
        store.discover()
        check(store.sessions[found.id] == nil, "hidden session stays hidden after discovery")
        store.apply(["session_id": found.id, "hook_event_name": "PostToolUse"], fd: -1)
        check(store.sessions[found.id] != nil, "hidden session comes back on new activity")
    } else {
        print("  skip  no Claude session running, restart recovery not exercised")
    }
}

print(failures == 0 ? "store checks passed" : "\(failures) store check(s) FAILED")
exit(failures == 0 ? 0 : 1)
