import AppKit
import Foundation

enum Status { case idle, working, waiting, done, failed }

struct Pending {
    let tool: String
    let detail: String
    let canAlways: Bool
    let fd: Int32
    let watcher: DispatchSourceRead
}

struct Session: Identifiable {
    let id: String
    var agent = "claude"
    var cwd = ""
    var title: String?
    var transcriptPath: String?
    var status = Status.idle
    var lastPrompt: String?
    var lastMessage: String?
    var tool: String?
    var activity: String?
    var terminal: [String: Any] = [:]
    var agentPID: Int32?
    var updated = Date()
    var pending: Pending?

    var project: String { (cwd as NSString).lastPathComponent }
    var terminalName: String? {
        (terminal["app_path"] as? String).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
    }
}

struct Usage {
    var fiveHour: (percent: Double, resetsAt: Double)?
    var sevenDay: (percent: Double, resetsAt: Double)?
}

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [String: Session] = [:]
    @Published var expanded = false
    @Published var usage = Usage()
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    // Sessions you hid with ✕; discovery leaves them out until they show new activity.
    private var hidden: Set<String> = []

    // Sessions that need you first, then the most recently active.
    var ordered: [Session] {
        sessions.values.sorted {
            ($0.status == .waiting ? 1 : 0, $0.updated) > ($1.status == .waiting ? 1 : 0, $1.updated)
        }
    }

    func apply(_ e: [String: Any], fd: Int32) {
        guard let id = e["session_id"] as? String, let name = e["hook_event_name"] as? String else {
            if fd >= 0 { close(fd) }
            return
        }
        // Only a permission request keeps its connection open, waiting for the answer.
        if name != "PermissionRequest" && fd >= 0 { close(fd) }
        hidden.remove(id)
        var s = sessions[id] ?? Session(id: id)
        s.cwd = e["cwd"] as? String ?? s.cwd
        s.transcriptPath = e["transcript_path"] as? String ?? s.transcriptPath
        if let t = e["_terminal"] as? [String: Any], !t.isEmpty { s.terminal = t }
        if let pid = e["_agent_pid"] as? Int { s.agentPID = Int32(pid) }
        if let agent = e["_agent"] as? String { s.agent = agent }
        if let title = e["_title"] as? String { s.title = title }  // agents without a transcript title (OpenCode)
        s.updated = Date()

        switch name {
        case "SessionStart":
            s.status = .idle
        case "UserPromptSubmit":
            if let prompt = cleanPrompt(e["prompt"] as? String) {
                s.lastPrompt = prompt
                s.status = .working
                s.tool = nil
                s.activity = nil
            }
        case "PreToolUse", "PostToolUse":
            if s.pending == nil { s.status = .working }
            if name == "PreToolUse" { (s.tool, s.activity) = describe(e) }
        case "PermissionRequest":
            dropPending(&s)
            let tool = e["tool_name"] as? String ?? "Tool"
            if tool == "AskUserQuestion" {
                // Questions need the terminal's own picker; just flag the session.
                close(fd)
                s.status = .waiting
                s.tool = tool
                s.activity = "Has a question for you"
            } else {
                let always = !((e["permission_suggestions"] as? [Any]) ?? []).isEmpty
                s.pending = watch(fd, tool: tool, detail: detail(e), canAlways: always, session: id)
                s.status = .waiting
                expanded = true
            }
            play("Funk")
        case "Notification":
            if s.pending == nil {
                s.activity = e["message"] as? String ?? s.activity
                s.status = e["notification_type"] as? String == "idle_prompt" ? .done : .waiting
            }
            play("Funk")
        case "Stop":
            dropPending(&s)
            s.status = .done
            s.lastMessage = e["last_assistant_message"] as? String ?? s.lastMessage
            s.tool = nil
            s.activity = nil
            play("Glass")
        case "StopFailure":
            dropPending(&s)
            s.status = .failed
            s.tool = nil
            s.activity = e["error"] as? String ?? "Turn failed"
            play("Basso")
        case "SessionEnd":
            dropPending(&s)
            sessions[id] = nil
            return
        default:
            break
        }
        if ["SessionStart", "UserPromptSubmit", "Stop"].contains(name) || s.title == nil {
            s.title = transcriptSummary(s.transcriptPath).title ?? s.title
        }
        sessions[id] = s
    }

    // behavior: "allow", "always", "deny" or "ask" (let the terminal show its own prompt).
    func respond(_ id: String, _ behavior: String) {
        guard var s = sessions[id], let p = s.pending else { return }
        writeAll(p.fd, Data("{\"behavior\":\"\(behavior)\"}\n".utf8))
        p.watcher.cancel()
        s.pending = nil
        s.status = behavior == "deny" ? .idle : .working
        if behavior == "ask" { s.activity = "Answer in the terminal" }
        sessions[id] = s
        if !sessions.values.contains(where: { $0.pending != nil }) { expanded = false }
    }

    func archive(_ id: String) {
        guard var s = sessions[id] else { return }
        dropPending(&s)
        sessions[id] = nil
        hidden.insert(id)
    }

    // Sessions whose agent process is gone never sent SessionEnd (crash, kill -9).
    func pruneDead() {
        for s in sessions.values {
            if let pid = s.agentPID, kill(pid, 0) != 0, errno == ESRCH { archive(s.id) }
        }
    }

    // Rebuild state from Claude Code's own records (~/.claude/sessions/<pid>.json), so sessions that
    // started, or kept running, while this app was closed show up without waiting for their next hook event.
    func discover() {
        let dir = home + "/.claude/sessions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = record["sessionId"] as? String, let pid = record["pid"] as? Int,
                  !hidden.contains(id), isLiveClaude(pid_t(pid), startedAt: record["startedAt"] as? Double) else { continue }
            let known = sessions[id] != nil
            var s = sessions[id] ?? Session(id: id)
            if s.agentPID == nil { s.agentPID = Int32(pid) }
            if s.cwd.isEmpty { s.cwd = record["cwd"] as? String ?? "" }
            if s.terminal.isEmpty { s.terminal = terminalInfo(from: pid_t(pid), env: processEnvironment(pid_t(pid))).terminal }
            if s.transcriptPath == nil { s.transcriptPath = findTranscript(id) }
            if !known {
                let summary = transcriptSummary(s.transcriptPath)
                s.title = summary.title
                s.lastPrompt = summary.prompt
                s.lastMessage = summary.reply
                // Idle with a reply means a finished turn; idle without one is a fresh session.
                s.status = record["status"] as? String == "busy" ? .working : summary.reply == nil ? .idle : .done
                s.updated = Date(timeIntervalSince1970: (record["updatedAt"] as? Double ?? 0) / 1000)
            }
            sessions[id] = s
        }
    }

    func readUsage() {
        guard let data = FileManager.default.contents(atPath: statuslinePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any] else { return }
        func window(_ key: String) -> (Double, Double)? {
            guard let w = limits[key] as? [String: Any], let p = w["used_percentage"] as? Double else { return nil }
            let reset = w["resets_at"] as? Double ?? 0
            return reset > Date().timeIntervalSince1970 ? (p, reset) : nil
        }
        usage = Usage(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
    }

    private func play(_ sound: String) {
        if !muted { NSSound(named: NSSound.Name(sound))?.play() }
    }

    private func dropPending(_ s: inout Session) {
        s.pending?.watcher.cancel()
        s.pending = nil
    }

    // The hook closes its end if Claude gives up on it (answered in the terminal, timeout).
    private func watch(_ fd: Int32, tool: String, detail: String, canAlways: Bool, session: String) -> Pending {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) <= 0, let self, var s = self.sessions[session], s.pending?.fd == fd else { return }
            self.dropPending(&s)
            s.status = .working
            self.sessions[session] = s
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return Pending(tool: tool, detail: detail, canAlways: canAlways, fd: fd, watcher: source)
    }

    private func describe(_ e: [String: Any]) -> (String, String?) {
        let tool = e["tool_name"] as? String ?? "Tool"
        let input = e["tool_input"] as? [String: Any] ?? [:]
        if let command = input["command"] as? String { return (tool, firstLine(command)) }
        if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String { return (tool, shortPath(path)) }
        let arg = (input["pattern"] ?? input["url"] ?? input["query"] ?? input["description"] ?? input["prompt"]) as? String
        return (tool, arg.map(firstLine))
    }

    private func detail(_ e: [String: Any]) -> String {
        let input = e["tool_input"] as? [String: Any] ?? [:]
        if let plan = input["plan"] as? String { return plan }
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String { return shortPath(path) }
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// Prompts Claude Code injects itself (<task-notification>, <local-command-stdout>, ...) are not yours.
func cleanPrompt(_ prompt: String?) -> String? {
    guard let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
    if let match = p.firstMatch(of: #/<command-name>(.*?)</command-name>/#) { return String(match.1) }
    return p.hasPrefix("<") ? nil : firstLine(p)
}

func firstLine(_ s: String) -> String {
    String(s.split(separator: "\n", maxSplits: 1).first ?? "")
}

func shortPath(_ path: String) -> String {
    let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    let parts = p.split(separator: "/")
    return parts.count > 4 ? "…/" + parts.suffix(3).joined(separator: "/") : p
}

// A record whose process died (or whose PID now belongs to something else) is stale.
func isLiveClaude(_ pid: pid_t, startedAt: Double?) -> Bool {
    guard kill(pid, 0) == 0, let start = processStart(pid) else { return false }
    guard let startedAt else { return true }
    return abs(start - startedAt / 1000) < 120
}

func findTranscript(_ sessionId: String) -> String? {
    let projects = home + "/.claude/projects"
    for dir in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] {
        let path = "\(projects)/\(dir)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: path) { return path }
    }
    return nil
}

// The latest ai-title, your last real prompt and Claude's last text reply, from the transcript tail.
func transcriptSummary(_ transcript: String?) -> (title: String?, prompt: String?, reply: String?) {
    guard let transcript, let handle = FileHandle(forReadingAtPath: transcript) else { return (nil, nil, nil) }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    // ponytail: only scans the last 2 MB; the title is rewritten every turn, so it is always in there
    try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
    let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    var title: String?, prompt: String?, reply: String?
    for line in tail.split(separator: "\n").reversed() {
        if title != nil && prompt != nil && reply != nil { break }
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        switch json["type"] as? String {
        case "ai-title":
            if title == nil { title = json["aiTitle"] as? String }
        case "assistant" where reply == nil:
            reply = texts(json).last
        case "user" where prompt == nil && json["isMeta"] as? Bool != true:
            prompt = texts(json).compactMap(cleanPrompt).last
        default:
            break
        }
    }
    return (title, prompt, reply)
}

// Text blocks of a transcript message; tool results and images are skipped.
private func texts(_ json: [String: Any]) -> [String] {
    let content = (json["message"] as? [String: Any])?["content"]
    if let text = content as? String { return [text] }
    return (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
}
