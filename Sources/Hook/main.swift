import Foundation

// Claude Code hook. Forwards the event JSON to Notch Island over a Unix socket.
// Fails open: if the app is not running, it prints nothing and Claude carries on as normal.

signal(SIGPIPE, SIG_IGN)

let input = FileHandle.standardInput.readDataToEndOfFile()
guard var event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

// Terminal info, so the app can jump back to the right window and pane.
let (terminal, agentPID) = terminalInfo(from: getppid(), env: ProcessInfo.processInfo.environment)
event["_terminal"] = terminal
event["_agent_pid"] = agentPID
// Which agent sent this: --agent codex, --agent opencode, ... (Claude Code when absent).
if let i = CommandLine.arguments.firstIndex(of: "--agent"), i + 1 < CommandLine.arguments.count {
    event["_agent"] = CommandLine.arguments[i + 1]
}

var line = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
line.append(0x0A)

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = unixAddress(socketPath)
guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else { exit(0) }
writeAll(fd, line)

guard event["hook_event_name"] as? String == "PermissionRequest" else { exit(0) }

// Block until the notch sends its one-line answer (not until the socket closes, which can lag behind the click).
// Anything but allow/always/deny means "ask in the terminal".
var reply = Data()
var byte: UInt8 = 0
while reply.last != 0x0A && read(fd, &byte, 1) == 1 { reply.append(byte) }
let answer = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
let decision: [String: Any]
switch answer?["behavior"] as? String {
case "allow": decision = ["behavior": "allow"]
case "always":
    // Same as Claude's "Yes, and don't ask again": apply the rules it suggested.
    decision = ["behavior": "allow", "updatedPermissions": event["permission_suggestions"] ?? []]
case "deny": decision = ["behavior": "deny", "message": "Denied from Notch Island"]
default: exit(0)
}
let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: output))
