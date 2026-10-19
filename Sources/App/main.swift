import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Lets the first click on a button work even though the panel never activates the app.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchGeometry {
    let width: CGFloat
    let height: CGFloat
}

// Where the island currently is, in the panel's top-left coordinates. Not published: it changes every animation frame.
final class HitArea {
    var rect = CGRect.zero
}

// The panel is a fixed transparent canvas so the island can animate freely inside it.
let canvasSize = CGSize(width: 1200, height: 900)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let hit = HitArea()
    var panel: IslandPanel!
    var hosting: ClickThroughHostingView<IslandView>!
    var screen: NSScreen!
    var observers: [AnyCancellable] = []

    // App Nap would otherwise throttle this background app and delay hook events and answers by seconds.
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "Answers Claude Code permission requests")

    func applicationDidFinishLaunching(_ note: Notification) {
        screen = notchScreen()
        hosting = ClickThroughHostingView(rootView: rootView())
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        place()
        panel.orderFrontRegardless()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screenChanged() }
            .store(in: &observers)
        store.$expanded.sink { [weak self] open in if !open { self?.openedByHover = false } }.store(in: &observers)
        installHotKeyHandler()
        store.$sessions.sink { [weak self] _ in DispatchQueue.main.async { self?.updateHotKeys() } }.store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateHotKeys() } }.store(in: &observers)
        // Only the island itself takes the mouse; everywhere else clicks go to the apps underneath.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.updateMousePassThrough() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateMousePassThrough()
            return event
        }
        // A drag may end outside the island; hand the mouse back once the button is up.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            DispatchQueue.main.async { self?.updateMousePassThrough() }
            return event
        }
        // Clicks anywhere else close the island.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.store.expanded = false }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.readUsage()
                self?.store.pruneDead()
                self?.store.discover()
            }
        }
        store.readUsage()
        startServer(store)
        store.discover()
        if ProcessInfo.processInfo.environment["NOTCH_ISLAND_DEBUG"] != nil { installDebugSignals() }
    }

    func rootView() -> IslandView {
        IslandView(store: store, notch: notchGeometry(), hit: hit) { [weak self] in self?.updateMousePassThrough() }
    }

    func updateMousePassThrough() {
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        // While a button is held (dragging an edge to resize), keep the mouse even outside the island.
        let dragging = NSEvent.pressedMouseButtons != 0 && !panel.ignoresMouseEvents
        let inside = dragging || hit.rect.insetBy(dx: -2, dy: -2).contains(point)
        if dragging { openedByHover = false }  // resizing a hover-opened island keeps it open
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside != pointerInside {
            pointerInside = inside
            hoverChanged(inside)
        }
    }

    // Open on hover after a short rest; close on leaving, but only if hover opened it and nothing waits for an answer.
    var pointerInside = false
    var openedByHover = false
    var hoverWork: DispatchWorkItem?
    func hoverChanged(_ inside: Bool) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let store = self.store
                if inside, !store.expanded, Pref.on(Pref.openOnHover) {
                    store.expanded = true
                    self.openedByHover = true
                } else if !inside, store.expanded, self.openedByHover, !store.sessions.values.contains(where: { $0.pending != nil }) {
                    store.expanded = false
                }
            }
        }
        hoverWork = work
        // Short enough to feel instant, long enough that sweeping past the notch does not open it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.06 : 0.12), execute: work)
    }

    // ⌘Y allows and ⌘N denies the newest approval, ⌘1-⌘4 pick an answer to a single question.
    // Registered only while such a request waits, so the keys work as usual everywhere else.
    var hotKeys: [EventHotKeyRef] = []
    var hotKeySet = ""

    func installHotKeyHandler() {
        hotKeyTarget = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { hotKeyTarget?.hotKeyPressed(key) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    var newestPending: Session? { store.ordered.first { $0.pending != nil } }

    func updateHotKeys() {
        var keys: [(id: UInt32, code: Int)] = []
        if Pref.on(Pref.shortcuts), let p = newestPending?.pending {
            if p.questions.isEmpty {
                keys = [(1, kVK_ANSI_Y), (2, kVK_ANSI_N)]
            } else if p.questions.count == 1 && !p.questions[0].multi {
                keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].prefix(p.questions[0].options.count).enumerated().map { (UInt32(10 + $0.offset), $0.element) }
            }
        }
        let set = keys.map { "\($0.id)" }.joined(separator: ",")
        guard set != hotKeySet else { return }
        hotKeySet = set
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = keys.compactMap { key in
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key.code), UInt32(cmdKey), EventHotKeyID(signature: OSType(0x4E49534C), id: key.id),  // 'NISL'
                                GetApplicationEventTarget(), 0, &ref)
            return ref
        }
    }

    func hotKeyPressed(_ key: UInt32) {
        guard let s = newestPending, let p = s.pending else { return }
        switch key {
        case 1: store.respond(s.id, "allow")
        case 2: store.respond(s.id, "deny")
        case 10...13 where p.questions.count == 1 && Int(key - 10) < p.questions[0].options.count:
            store.respond(s.id, "answer", answers: [p.questions[0].text: p.questions[0].options[Int(key - 10)].label])
        default: break
        }
    }

    // Test seam (no clicks or screen recording needed): USR1 toggles the island,
    // USR2 allows the newest pending request of a "debug-*" session (never a real one); both then save ~/.notch-island/run/snapshot.png.
    var debugSources: [DispatchSourceSignal] = []
    func installDebugSignals() {
        for sig in [SIGUSR1, SIGUSR2] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if sig == SIGUSR1 {
                    store.expanded.toggle()
                } else if let s = store.ordered.first(where: { $0.pending != nil && $0.id.hasPrefix("debug-") }) {
                    store.respond(s.id, "allow")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.snapshot() }
            }
            source.resume()
            debugSources.append(source)
        }
    }

    // Saves the island cropped out of the transparent canvas, with a margin so its shadow fades out instead of being cut off.
    func snapshot() {
        let rect = hit.rect.insetBy(dx: -40, dy: -40).intersection(hosting.bounds)
        guard !rect.isEmpty, let rep = hosting.bitmapImageRepForCachingDisplay(in: rect) else { return }
        hosting.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: islandDir + "/run/snapshot.png"))
    }

    func notchScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
    }

    func notchGeometry() -> NotchGeometry {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return NotchGeometry(width: 180, height: max(menuBar, 28))  // no notch: a small bar
        }
        return NotchGeometry(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }

    func screenChanged() {
        screen = notchScreen()
        hosting.rootView = rootView()
        place()
    }

    func place() {
        let frame = screen.frame
        panel.setFrame(NSRect(x: frame.midX - canvasSize.width / 2, y: frame.maxY - canvasSize.height,
                              width: canvasSize.width, height: canvasSize.height), display: true)
    }
}

@MainActor var hotKeyTarget: AppDelegate?

func startServer(_ store: Store) {
    try? FileManager.default.createDirectory(atPath: islandDir + "/run", withIntermediateDirectories: true)
    unlink(socketPath)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = unixAddress(socketPath)
    guard withSockaddr(&addr, { bind(server, $0, $1) }) == 0, listen(server, 64) == 0 else {
        fatalError("Notch Island: cannot listen on \(socketPath)")
    }
    chmod(socketPath, 0o600)
    Thread.detachNewThread {
        while true {
            let client = accept(server, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global().async {
                // The hook sends one JSON line; a permission request then waits on the same connection.
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 65536)
                while data.last != 0x0A {
                    let n = read(client, &buf, buf.count)
                    if n <= 0 { break }
                    data.append(contentsOf: buf[0..<n])
                }
                guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    close(client)
                    return
                }
                nonisolated(unsafe) let e = event
                DispatchQueue.main.async { MainActor.assumeIsolated { store.apply(e, fd: client) } }
            }
        }
    }
}

// Bring the session's terminal forward, down to the pane where WezTerm or tmux tell us.
@MainActor
func jump(_ s: Session) {
    let t = s.terminal
    let appPath = t["app_path"] as? String
    if let pane = t["WEZTERM_PANE"] as? String, let appPath {
        run(appPath + "/Contents/MacOS/wezterm", ["cli", "activate-pane", "--pane-id", pane],
            env: ["WEZTERM_UNIX_SOCKET": t["WEZTERM_UNIX_SOCKET"] as? String])
    }
    if let tmux = t["TMUX"] as? String, let pane = t["TMUX_PANE"] as? String {
        let socket = String(tmux.split(separator: ",").first ?? "")
        run("/usr/bin/env", ["tmux", "-S", socket, "select-window", "-t", pane, ";", "select-pane", "-t", pane])
    }
    if let appPath {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: NSWorkspace.OpenConfiguration())
    }
}

func run(_ path: String, _ args: [String], env extra: [String: String?] = [:]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.homebrew/bin:/usr/bin:/bin"
    for (key, value) in extra { env[key] = value }
    p.environment = env
    try? p.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

