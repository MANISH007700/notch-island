import Foundation

// Shared by the app and the hook: where the app listens.
// $HOME like any Unix tool (NSHomeDirectory() ignores it); the demo and tests point it at a scratch folder.
let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let islandDir = home + "/.notch-island"
let socketPath = ProcessInfo.processInfo.environment["NOTCH_ISLAND_SOCKET"] ?? islandDir + "/run/island.sock"  // override: tests only
let statuslinePath = islandDir + "/run/statusline.json"

func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: Array(path.utf8.prefix(buf.count - 1)))
    }
    return addr
}

func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return }
            offset += n
        }
    }
}
