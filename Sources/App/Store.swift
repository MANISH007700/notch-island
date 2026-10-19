import AppKit
import Foundation

enum Status { case idle, working, waiting, done, failed }

struct Pending {
    let tool: String
    let detail: String
    let canAlways: Bool
    let fd: Int32
    let watcher: DispatchSourceRead
    var questions: [Question] = []  // AskUserQuestion, answered from the notch
    var diff: [DiffLine] = []       // Edit, MultiEdit, Write
}

struct Question {
    let text: String
    let header: String
    let options: [(label: String, detail: String)]
    let multi: Bool
}

struct DiffLine {
    let added: Bool
    let text: String
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

// One plan-usage window of one agent, like Claude's "5h" or Codex's "30d".
struct Limit: Equatable {
    let label: String
    let percent: Double
    let resetsAt: Double
}

// Settings, kept in UserDefaults. The views bind to the same keys with @AppStorage.
enum Pref {
    static let openOnHover = "openOnHover"
    static let openForApprovals = "openForApprovals"
    static let approveInNotch = "approveInNotch"
    static let showUsage = "showUsage"
    static let shortcuts = "shortcuts"
    static let agents = ["claude", "codex", "opencode"]
    static func agent(_ name: String) -> String { "agent." + name }
    static let defaults: [String: Any] = [openOnHover: true, openForApprovals: true, approveInNotch: true, showUsage: true, shortcuts: true]

    static func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? defaults[key] as? Bool ?? true }
}

// One sound per kind of event, each with its own switch in Settings.
enum Sound: String, CaseIterable {
    case start, needsYou, done, failed, limit, end

    var file: String {
        switch self {
        case .start: "Pop"
        case .needsYou: "Funk"
        case .done: "Glass"
        case .failed: "Basso"
        case .limit: "Sosumi"
        case .end: "Bottle"
        }
    }

    var title: String {
        switch self {
        case .start: "New session"
        case .needsYou: "Needs you"
        case .done: "Finished"
        case .failed: "Failed"
        case .limit: "Rate limit"
        case .end: "Session ended"
        }
    }

    var detail: String {
        switch self {
        case .start: "An agent starts a session"
        case .needsYou: "A permission request or question"
        case .done: "An agent finishes its turn"
        case .failed: "A turn stops on an error"
        case .limit: "Hit a rate limit, or plan usage passes 90%"
        case .end: "A session closes or its agent quits"
        }
    }

    var key: String { "sound." + rawValue }
}

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [String: Session] = [:]
    @Published var expanded = false
    @Published var limits: [String: [Limit]] = [:]  // by agent
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    // Sessions you hid with ✕; discovery leaves them out until they show new activity.
    private var hidden: Set<String> = []
    // One exit watcher per agent process, so its sessions go the moment it quits (agents rarely send SessionEnd on quit).
    private var exitWatchers: [Int32: DispatchSourceProcess] = [:]

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
        // A switched-off agent is ignored; closing the connection makes it ask in its own terminal.
        guard Pref.on(Pref.agent(e["_agent"] as? String ?? sessions[id]?.agent ?? "claude")) else {
            if fd >= 0 { close(fd) }
            return
        }
        // Only a permission request keeps its connection open, waiting for the answer.
        if name != "PermissionRequest" && fd >= 0 { close(fd) }
        hidden.remove(id)
        let isNew = sessions[id] == nil
        var s = sessions[id] ?? Session(id: id)
        s.cwd = e["cwd"] as? String ?? s.cwd
        s.transcriptPath = e["transcript_path"] as? String ?? s.transcriptPath
        if let t = e["_terminal"] as? [String: Any], !t.isEmpty { s.terminal = t }
        if let pid = e["_agent_pid"] as? Int { s.agentPID = Int32(pid); watchExit(Int32(pid)) }
        if let agent = e["_agent"] as? String { s.agent = agent }
        if let title = e["_title"] as? String { s.title = title }  // agents without a transcript title (OpenCode)
        s.updated = Date()

        switch name {
        case "SessionStart":
            s.status = .idle
            if isNew { play(.start) }  // not on resume or compact of a session already shown
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
            let input = e["tool_input"] as? [String: Any] ?? [:]
            let questions = tool == "AskUserQuestion" ? parseQuestions(input) : []
            if !Pref.on(Pref.approveInNotch) || (tool == "AskUserQuestion" && questions.isEmpty) {
                // Left to the terminal's own prompt; just flag the session.
                close(fd)
                s.status = .waiting
                s.tool = tool
                s.activity = tool == "AskUserQuestion" ? "Has a question for you" : "Needs your approval in the terminal"
            } else {
                let always = !((e["permission_suggestions"] as? [Any]) ?? []).isEmpty
                s.pending = watch(fd, tool: tool, detail: detail(e), canAlways: always, session: id)
                s.pending?.questions = questions
                s.pending?.diff = diffLines(tool, input)
                s.status = .waiting
                if Pref.on(Pref.openForApprovals) { expanded = true }
            }
            play(.needsYou)
        case "Notification":
            if s.pending == nil {
                s.activity = e["message"] as? String ?? s.activity
                s.status = e["notification_type"] as? String == "idle_prompt" ? .done : .waiting
            }
            // The idle reminder follows a finished turn that already chimed.
            if e["notification_type"] as? String != "idle_prompt" { play(.needsYou) }
        case "Stop":
            dropPending(&s)
            s.status = .done
            s.lastMessage = e["last_assistant_message"] as? String ?? s.lastMessage
            s.tool = nil
            s.activity = nil
            play(.done)
        case "StopFailure":
            dropPending(&s)
            s.status = .failed
            s.tool = nil
            s.activity = describeError(e["error"] as? String)
            play((e["error"] as? String ?? "").contains("rate_limit") ? .limit : .failed)
        case "SessionEnd":
            dropPending(&s)
            sessions[id] = nil
            play(.end)
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
    // behavior "answer" carries the picked option per question (AskUserQuestion).
    func respond(_ id: String, _ behavior: String, answers: [String: String] = [:]) {
        guard var s = sessions[id], let p = s.pending else { return }
        var reply: [String: Any] = ["behavior": behavior]
        if behavior == "answer" { reply["answers"] = answers }
        var line = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        line.append(0x0A)
        writeAll(p.fd, line)
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

    // Switching an agent off drops its cards (pending approvals go back to its terminal); not hidden, so they return when switched on.
    func dropAgent(_ agent: String) {
        for var s in sessions.values where s.agent == agent {
            dropPending(&s)
            sessions[s.id] = nil
        }
    }

    private func watchExit(_ pid: Int32) {
        guard exitWatchers[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.exitWatchers.removeValue(forKey: pid)?.cancel()
                // Archive directly: a not-yet-reaped zombie still passes pruneDead's kill(pid, 0).
                let gone = self.sessions.values.filter { $0.agentPID == pid }
                for s in gone { self.archive(s.id) }
                if !gone.isEmpty { self.play(.end) }
            }
        }
        source.resume()
        exitWatchers[pid] = source
    }

    // Fallback for a process that died before its watcher started.
    func pruneDead() {
        for s in sessions.values {
            if let pid = s.agentPID, kill(pid, 0) != 0, errno == ESRCH { archive(s.id) }
        }
        // Drop watchers that never fired, so a reused PID gets a fresh one.
        for pid in exitWatchers.keys where kill(pid, 0) != 0 && errno == ESRCH { exitWatchers.removeValue(forKey: pid)?.cancel() }
    }

    // Rebuild state from Claude Code's own records (~/.claude/sessions/<pid>.json), so sessions that
    // started, or kept running, while this app was closed show up without waiting for their next hook event.
    func discover() {
        guard Pref.on(Pref.agent("claude")) else { return }
        let dir = home + "/.claude/sessions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = record["sessionId"] as? String, let pid = record["pid"] as? Int,
                  !hidden.contains(id), isLiveClaude(pid_t(pid), startedAt: record["startedAt"] as? Double) else { continue }
            let known = sessions[id] != nil
            var s = sessions[id] ?? Session(id: id)
            if s.agentPID == nil { s.agentPID = Int32(pid); watchExit(Int32(pid)) }
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

    // Claude's limits come from the status line copy, Codex's from its own session logs.
    func readUsage() {
        var next: [String: [Limit]] = [:]
        if let data = FileManager.default.contents(atPath: statuslinePath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let windows = json["rate_limits"] as? [String: Any] {
            next["claude"] = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label in
                guard let w = windows[key] as? [String: Any], let p = w["used_percentage"] as? Double else { return nil }
                return Limit(label: label, percent: p, resetsAt: w["resets_at"] as? Double ?? 0)
            }
        }
        next["codex"] = latestCodexLimits()
        let now = Date().timeIntervalSince1970
        next = next.mapValues { $0.filter { $0.resetsAt > now } }.filter { !$0.value.isEmpty }
        // Chime once as a window crosses 90%; not on launch, when there is nothing to compare with.
        let crossed = next.contains { agent, windows in
            windows.contains { new in
                (limits[agent]?.first { $0.label == new.label }).map { $0.percent < 90 && new.percent >= 90 } ?? false
            }
        }
        if crossed { play(.limit) }
        if next != limits { limits = next }
    }

    // A file named after the event in ~/.notch-island/sounds (done.wav, needsYou.aiff, ...) replaces the system sound.
    func play(_ sound: Sound) {
        guard !muted && Pref.on(sound.key) else { return }
        (customSound(sound) ?? NSSound(named: NSSound.Name(sound.file)))?.play()
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
    if p.hasPrefix("<") { return nil }
    // Attachment placeholders like "[Image #9]" or "[Pasted text #2 +40 lines]" are noise on a card.
    let text = firstLine(p.replacing(#/\[(Image|Pasted text) #\d+[^\]]*\]\s*/#, with: "")).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? "Sent an attachment" : text
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

// Codex logs its plan usage into every session file (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl);
// the newest file's last "rate_limits" entry is the current state.
func latestCodexLimits() -> [Limit] {
    let fm = FileManager.default
    var dir = home + "/.codex/sessions"
    for _ in 0..<3 {  // year, month, day: the newest of each sorts last
        guard let newest = (try? fm.contentsOfDirectory(atPath: dir))?.filter({ !$0.hasPrefix(".") }).max() else { return [] }
        dir += "/" + newest
    }
    let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }.map { dir + "/" + $0 }
    let modified = { (path: String) in (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast }
    guard let file = files.max(by: { modified($0) < modified($1) }), let handle = FileHandle(forReadingAtPath: file) else { return [] }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)  // the tail is enough
    let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    for line in tail.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
        if let limits = codexLimits(String(line)) { return limits }
    }
    return []
}

// One Codex log line -> its usage windows: primary and secondary, labelled by their length.
func codexLimits(_ line: String) -> [Limit]? {
    func find(_ any: Any) -> [String: Any]? {
        if let d = any as? [String: Any] {
            if let r = d["rate_limits"] as? [String: Any] { return r }
            for v in d.values { if let r = find(v) { return r } }
        }
        return nil
    }
    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)), let r = find(json) else { return nil }
    return ["primary", "secondary"].compactMap { key in
        guard let w = r[key] as? [String: Any], let p = w["used_percent"] as? Double,
              let minutes = w["window_minutes"] as? Int, let reset = w["resets_at"] as? Double else { return nil }
        return Limit(label: minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d", percent: p, resetsAt: reset)
    }
}

// Claude Code's StopFailure error codes, in words.
func describeError(_ code: String?) -> String {
    guard let code, !code.isEmpty else { return "Turn failed" }
    let known = ["rate_limit": "Rate limit reached", "authentication_failed": "Not signed in", "billing_error": "Billing problem",
                 "invalid_request": "Invalid request", "server_error": "Server error", "max_output_tokens": "Reply hit the output limit"]
    return known[code] ?? code.replacingOccurrences(of: "_", with: " ").capitalized(with: nil)
}

func customSound(_ sound: Sound) -> NSSound? {
    for ext in ["aiff", "wav", "mp3", "m4a", "caf"] {
        let path = islandDir + "/sounds/" + sound.rawValue + "." + ext
        if FileManager.default.fileExists(atPath: path) { return NSSound(contentsOfFile: path, byReference: true) }
    }
    return nil
}

// AskUserQuestion's input: {"questions": [{"question", "header", "options": [{"label", "description"}], "multiSelect"}]}.
func parseQuestions(_ input: [String: Any]) -> [Question] {
    ((input["questions"] as? [[String: Any]]) ?? []).compactMap { q in
        guard let text = q["question"] as? String else { return nil }
        let options = ((q["options"] as? [[String: Any]]) ?? []).compactMap { o in
            (o["label"] as? String).map { ($0, o["description"] as? String ?? "") }
        }
        return options.isEmpty ? nil : Question(text: text, header: q["header"] as? String ?? "", options: options, multi: q["multiSelect"] as? Bool ?? false)
    }
}

// The lines a file edit removes and adds; lines both sides share at the start and end are left out.
func diffLines(_ tool: String, _ input: [String: Any]) -> [DiffLine] {
    func lines(_ s: String?) -> [String] { s.map { $0.components(separatedBy: "\n") } ?? [] }
    func edit(_ old: String?, _ new: String?) -> [DiffLine] {
        var a = lines(old), b = lines(new)
        while let x = a.first, let y = b.first, x == y { a.removeFirst(); b.removeFirst() }
        while let x = a.last, let y = b.last, x == y { a.removeLast(); b.removeLast() }
        return a.map { DiffLine(added: false, text: $0) } + b.map { DiffLine(added: true, text: $0) }
    }
    switch tool {
    case "Edit": return edit(input["old_string"] as? String, input["new_string"] as? String)
    case "MultiEdit": return ((input["edits"] as? [[String: Any]]) ?? []).flatMap { edit($0["old_string"] as? String, $0["new_string"] as? String) }
    case "Write": return lines(input["content"] as? String).map { DiffLine(added: true, text: $0) }
    default: return []
    }
}
