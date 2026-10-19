import Foundation

// Process helpers shared by the hook (walks up from itself) and the app (walks up from a Claude process).

func processInfo(_ pid: pid_t) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
}

func parentPID(_ pid: pid_t) -> pid_t? {
    processInfo(pid)?.kp_eproc.e_ppid
}

// Seconds since 1970, used to tell a live Claude process from a reused PID.
func processStart(_ pid: pid_t) -> Double? {
    guard let tv = processInfo(pid)?.kp_proc.p_un.__p_starttime else { return nil }
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
}

func executablePath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

// Another process's environment (same user only), read from KERN_PROCARGS2:
// argc, executable path, padding, argv..., envp...
func processEnvironment(_ pid: pid_t) -> [String: String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [:] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [:] }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    let strings = buf[4..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    var env: [String: String] = [:]
    for pair in strings.dropFirst(argc + 1) {
        if let eq = pair.firstIndex(of: "=") { env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...]) }
    }
    return env
}

// Walk up from `pid`: the first non-shell process is the agent, the first app executable is the terminal.
func terminalInfo(from pid: pid_t, env: [String: String]) -> (terminal: [String: Any], agentPID: Int?) {
    var terminal: [String: Any] = [:]
    for key in ["TERM_PROGRAM", "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET", "TMUX", "TMUX_PANE"] {
        if let value = env[key] { terminal[key] = value }
    }
    let shells: Set = ["sh", "bash", "zsh", "dash", "fish"]
    var agent: Int?
    var pid = pid
    for _ in 0..<64 where pid > 1 {
        guard let path = executablePath(pid) else { break }
        if agent == nil && !shells.contains((path as NSString).lastPathComponent) { agent = Int(pid) }
        // Only an app's own executable (Contents/MacOS) counts: a CLI shipped inside an app's Resources,
        // like Codex inside ChatGPT.app, is the agent, not the terminal.
        if path.contains(".app/Contents/MacOS/"), let range = path.range(of: ".app/") {
            terminal["app_path"] = String(path[..<range.lowerBound]) + ".app"
            terminal["app_pid"] = Int(pid)
            break
        }
        guard let next = parentPID(pid) else { break }
        pid = next
    }
    return (terminal, agent)
}
