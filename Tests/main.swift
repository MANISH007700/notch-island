import Foundation

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

    print("restart recovery")
    store.discover()
    let records = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.claude/sessions"))?.filter { $0.hasSuffix(".json") } ?? []
    if let found = store.sessions.values.first {
        check(true, "discovered \(store.sessions.count) running Claude session(s) from \(records.count) record(s)")
        check(found.agentPID != nil && found.transcriptPath != nil, "discovered session has its process and transcript")
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
