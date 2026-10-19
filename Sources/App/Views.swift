import AppKit
import SwiftUI

let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
let mono = Font.system(size: 11.5, design: .monospaced)
let frost = Color(red: 0.78, green: 0.84, blue: 1)  // cool white for glass surfaces and edges
let defaultWidth: Double = 720
let widthRange: ClosedRange<Double> = 560...Double(canvasSize.width - 60)
let visibleCards = 5  // more than this scroll

// MARK: - Island

struct IslandView: View {
    @ObservedObject var store: Store
    let notch: NotchGeometry
    let hit: HitArea
    let onHitChange: () -> Void
    @State private var hovering = false
    @State private var listHeight: CGFloat = 0
    @State private var cardHeights: [String: CGFloat] = [:]
    @State private var settingsHeight: CGFloat = 0
    // Drag the sides to resize the island, the bottom to resize the list; double-click an edge to reset.
    @AppStorage("islandWidth") private var islandWidth = defaultWidth
    @AppStorage("listHeight") private var listCap = 0.0  // 0: fit five cards
    @State private var dragStart: CGFloat?
    @State private var showingSettings = false
    @AppStorage(Pref.showUsage) private var showUsage = true

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    var island: some View {
        let expanded = store.expanded
        let ear: CGFloat = expanded ? 14 : 6
        return ZStack(alignment: .top) {
            if expanded {
                expandedContent
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).animation(spring.delay(0.04)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            } else {
                collapsedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }
        }
        .padding(.horizontal, ear)
        .background(Color.black)
        .clipShape(NotchShape(ear: ear, radius: expanded ? 26 : 11))
        // A hairline around the open island; masked off along the top so it never draws across the menu bar.
        .overlay(NotchShape(ear: ear, radius: expanded ? 26 : 11).stroke(Color.white.opacity(expanded ? 0.09 : 0), lineWidth: 1)
            .mask(VStack(spacing: 0) { Color.clear.frame(height: notch.height); Color.black }))
        .onChange(of: expanded) { if !expanded { showingSettings = false } }
        .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 22, y: 12)
        .scaleEffect(hovering && !expanded ? CGSize(width: 1.04, height: 1.1) : CGSize(width: 1, height: 1), anchor: .top)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            hit.rect = $0
            onHitChange()
        }
        .animation(spring, value: expanded)
    }

    // MARK: Collapsed: wings either side of the notch

    var collapsedContent: some View {
        let sessions = store.ordered
        let wing: CGFloat = sessions.isEmpty ? 0 : 38
        let top = sessions.max { $0.status.rank < $1.status.rank }
        let waiting = sessions.filter { $0.status == .waiting }.count
        return HStack(spacing: 0) {
            if let top {
                StatusIcon(status: top.status, size: 15).frame(width: wing)
            }
            Color.clear.frame(width: notch.width)
            if !sessions.isEmpty {
                Text("\(waiting > 0 ? waiting : sessions.count)")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(waiting > 0 ? Status.waiting.color : Color.white.opacity(0.85))
                    .contentTransition(.numericText())
                    .frame(width: wing)
            }
        }
        .frame(height: notch.height)
        .contentShape(Rectangle())
        .pointer()
        .onTapGesture { store.expanded = true }
    }

    // MARK: Expanded

    var expandedContent: some View {
        VStack(spacing: 6) {
            header
            if showingSettings {
                ScrollView(.vertical) {
                    SettingsView(store: store)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { settingsHeight = $0 }
                }
                .frame(height: min(settingsHeight, canvasSize.height - notch.height - 120))
                .transition(.opacity)
            } else if store.sessions.isEmpty {
                EmptyState()
            } else {
                ScrollView(.vertical, showsIndicators: store.ordered.count > visibleCards) {
                    VStack(spacing: 10) {
                        ForEach(store.ordered) { session in
                            SessionCard(session: session, store: store)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeights[session.id] = $0 }
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        }
                    }
                    .padding(.horizontal, 14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: shownListHeight)
                if listHeight > shownListHeight + 1 {
                    Text("Scroll for more").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 2)
                }
            }
        }
        .padding(.bottom, 14)
        .frame(width: islandWidth)
        .overlay(alignment: .leading) { sideHandle(sign: -1) }
        .overlay(alignment: .trailing) { sideHandle(sign: 1) }
        .overlay(alignment: .bottom) {
            if !showingSettings && !store.sessions.isEmpty { bottomHandle }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: layoutKey)
        .animation(.easeOut(duration: 0.18), value: showingSettings)
    }

    var maxListHeight: CGFloat { canvasSize.height - notch.height - 120 }

    var shownListHeight: CGFloat {
        min(listHeight, listCap > 0 ? CGFloat(listCap) : firstCardsHeight, maxListHeight)
    }

    // The island grows from its centre, so a side moves by half the width change: width follows the pointer at 2x.
    func sideHandle(sign: CGFloat) -> some View {
        ResizeEdge(axis: .horizontal)
            .frame(width: 10)
            .padding(.top, notch.height)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? CGFloat(islandWidth)
                    dragStart = start
                    islandWidth = Double(start + sign * 2 * drag.translation.width).clamped(to: widthRange)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { withAnimation(spring) { islandWidth = defaultWidth } }
    }

    var bottomHandle: some View {
        ResizeEdge(axis: .vertical)
            .frame(height: 12)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? shownListHeight
                    dragStart = start
                    listCap = Double(min(max(start + drag.translation.height, 90), maxListHeight))
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { withAnimation(spring) { listCap = 0 } }
    }

    // Room for the first few cards; the rest scroll.
    var firstCardsHeight: CGFloat {
        let shown = store.ordered.prefix(visibleCards)
        guard store.ordered.count > visibleCards else { return .infinity }
        return shown.reduce(0) { $0 + (cardHeights[$1.id] ?? 0) } + CGFloat(shown.count - 1) * 10
    }

    // Anything that changes a card's size or order animates.
    var layoutKey: [String] {
        store.ordered.map { "\($0.id)|\($0.status)|\($0.pending != nil)|\($0.activity ?? "")|\($0.title ?? "")" }
    }

    var header: some View {
        HStack(spacing: 0) {
            Group {
                if showingSettings {
                    Text("Settings").font(.system(size: 13, weight: .semibold)).padding(.leading, 12)
                } else if showUsage, !shownLimits.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        LimitsGroup(rows: shownLimits, bar: 40, height: notch.height - 6)
                        LimitsGroup(rows: shownLimits, bar: 26, height: notch.height - 6)
                        LimitsGroup(rows: shownLimits, bar: 0, height: notch.height - 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notch.width + 16)
            HStack(spacing: 2) {
                IconButton(symbol: store.muted ? "speaker.slash" : "speaker.wave.2",
                           help: store.muted ? "Unmute sounds" : "Mute sounds",
                           tint: store.muted ? .white.opacity(0.7) : Status.working.color) { store.muted.toggle() }
                IconButton(symbol: "gearshape", help: showingSettings ? "Back to sessions" : "Settings",
                           tint: Color(red: 0.72, green: 0.62, blue: 1), active: showingSettings) { showingSettings.toggle() }
                IconButton(symbol: "power", help: "Quit Notch Island", tint: Status.failed.color) { NSApp.terminate(nil) }
            }
            .padding(3)
            .background(HeaderGroup())
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: notch.height)
        .contentShape(Rectangle())
        .onTapGesture { store.expanded = false }
    }

    // Limits of the agents in use right now (all known ones when nothing is running), in agent order.
    var shownLimits: [(agent: String, limits: [Limit])] {
        let inUse = Set(store.sessions.values.map(\.agent))
        return Pref.agents.compactMap { agent in
            guard let limits = store.limits[agent], Pref.on(Pref.agent(agent)), inUse.isEmpty || inUse.contains(agent) else { return nil }
            return (agent, limits)
        }
    }
}

// The rounded glass behind each header group.
struct HeaderGroup: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(frost.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(frost.opacity(0.1)))
    }
}

// One row per agent: its icon, then each of its usage windows. Two agents stack in the notch height.
struct LimitsGroup: View {
    let rows: [(agent: String, limits: [Limit])]
    let bar: CGFloat
    let height: CGFloat

    var body: some View {
        let compact = rows.count > 1
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.agent) { row in
                HStack(spacing: compact ? 7 : 9) {
                    AgentGlyph(agent: row.agent, size: compact ? 12 : 16)
                    ForEach(row.limits, id: \.label) {
                        UsageMeter(agent: row.agent, limit: $0, bar: bar, compact: compact)
                    }
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 11)
        .frame(height: height)
        .background(HeaderGroup())
    }
}

// A resize edge: a faint grab line that brightens, with the resize pointer, while hovered.
struct ResizeEdge: View {
    let axis: Axis
    @State private var hovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                Capsule().fill(Color.white.opacity(hovering ? 0.45 : 0.14))
                    .frame(width: axis == .vertical ? 44 : 4, height: axis == .vertical ? 4 : 44)
            }
            .pointer(axis == .vertical ? .resizeUpDown : .resizeLeftRight)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
            .help("Drag to resize · double-click to reset")
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

extension View {
    // Sets the pointer while it moves over this view; a non-activating panel gets no cursor rects of its own.
    func pointer(_ cursor: NSCursor = .pointingHand) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: cursor.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

// The notch silhouette: concave "ears" where it meets the menu bar, rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { (ear, radius) = (newValue.first, newValue.second) }
    }

    func path(in r: CGRect) -> Path {
        let radius = max(0, min(radius, r.height / 2, (r.width - 2 * ear) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear, y: r.minY + ear), control: CGPoint(x: r.minX + ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + ear, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear + radius, y: r.maxY), control: CGPoint(x: r.minX + ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.maxY - radius), control: CGPoint(x: r.maxX - ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - ear, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Session card

struct SessionCard: View {
    let session: Session
    @ObservedObject var store: Store
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AgentAvatar(session: session)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Text(title).font(.system(size: 13.5, weight: .semibold)))   \(Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.42)))")
                        .lineLimit(1)
                    activityLine
                }
                Spacer(minLength: 8)
                // One tight group on the right: hide, time, status, jump.
                HStack(spacing: 8) {
                    if hovering {
                        IconButton(symbol: "xmark", help: "Hide this session") { store.archive(session.id) }
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(ago(session.updated)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                    }
                    StatusPill(session: session)
                    JumpButton(help: session.terminalName.map { "Jump to \($0)" } ?? "Jump to the terminal") {
                        jump(session)
                        store.expanded = false
                    }
                }
            }

            // The reply of a finished turn, under the text column.
            if session.status != .working, session.activity == nil, session.pending == nil, let message = session.lastMessage {
                Text(markdown(message)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2).lineSpacing(2)
                    .padding(.leading, 46)
            }
            if let pending = session.pending {
                PermissionBox(pending: pending, answer: { store.respond(session.id, $0) },
                              submit: { store.respond(session.id, "answer", answers: $0) })
                    .padding(.leading, 46)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(CardSurface(status: session.status, hovering: hovering))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .pointer()
        .onTapGesture {
            jump(session)
            store.expanded = false
        }
    }

    var title: String {
        session.title ?? session.lastPrompt ?? "New session"
    }

    var subtitle: String {
        [session.project, session.terminalName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // What the agent is doing right now, in monospace; otherwise your last prompt.
    @ViewBuilder var activityLine: some View {
        if let tool = session.tool, session.status == .working || session.status == .waiting {
            Text("\(Text(toolLabel(tool)).fontWeight(.semibold).foregroundStyle(.white.opacity(0.85)))  \(Text(session.activity ?? "").foregroundStyle(.white.opacity(0.5)))")
                .font(mono).lineLimit(1).truncationMode(.middle)
                .shimmer(session.status == .working)
        } else if let activity = session.activity {
            Text(activity).font(mono).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        } else if session.title != nil, let prompt = session.lastPrompt {
            Text("\(Text("You").foregroundStyle(.white.opacity(0.75)))\(Text(" · ").foregroundStyle(.white.opacity(0.3)))\(Text(prompt).foregroundStyle(.white.opacity(0.5)))")
                .font(.system(size: 12.5)).lineLimit(1)
        }
    }
}

// The agent's own app icon, with the icon of the terminal it runs in tucked into the corner.
struct AgentAvatar: View {
    let session: Session

    var body: some View {
        AgentGlyph(agent: session.agent, size: 36)
            .overlay(alignment: .bottomTrailing) {
                // Left out when the agent runs in its own app (Codex in the Codex app).
                if let path = session.terminal["app_path"] as? String, path != agentIcon(session.agent)?.app {
                    Image(nsImage: appIcon(path)).resizable().frame(width: 18, height: 18).offset(x: 5, y: 5)
                }
            }
            .help([agentName(session.agent), session.terminalName].compactMap { $0 }.joined(separator: " in "))
    }
}

// The agent's real icon when its app is installed, else its initials on its colour.
struct AgentGlyph: View {
    let agent: String
    let size: CGFloat

    var body: some View {
        if let icon = agentIcon(agent) {
            let image = Image(nsImage: icon.image).resizable().interpolation(.high)
            if icon.raw {
                // A bare .icns is a full square: give it the app-icon shape and margin, like the system does.
                image.clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                    .padding(size * 0.09).frame(width: size, height: size)
            } else {
                image.frame(width: size, height: size)
            }
        } else {
            let color = agentColor(agent)
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.9, height: size * 0.9)
                .overlay(Text(["claude": "CC", "codex": "CX", "opencode": "OC"][agent] ?? String(agent.prefix(2)).uppercased())
                    .font(.system(size: size * 0.33, weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.7)))
                .frame(width: size, height: size)
        }
    }
}

// Where each agent's icon lives on a Mac that has its app. Read at runtime: no logos ship with Notch Island.
let agentIconSources: [String: [(app: String, file: String?)]] = [
    "claude": [("/Applications/Claude.app", nil), (home + "/Applications/Claude.app", nil)],
    "codex": [("/Applications/Codex.app", nil), ("/Applications/ChatGPT.app", "/Applications/ChatGPT.app/Contents/Resources/app.icns")],
    "opencode": [("/Applications/OpenCode.app", nil), (home + "/Applications/OpenCode.app", nil)],
]

typealias AgentIcon = (image: NSImage, app: String, raw: Bool)

@MainActor private var agentIconCache: [String: AgentIcon?] = [:]
@MainActor func agentIcon(_ agent: String) -> AgentIcon? {
    if let cached = agentIconCache[agent] { return cached }
    let found = (agentIconSources[agent] ?? []).lazy.compactMap { source -> AgentIcon? in
        guard FileManager.default.fileExists(atPath: source.app) else { return nil }
        if let file = source.file { return NSImage(contentsOfFile: file).map { ($0, source.app, true) } }
        return (NSWorkspace.shared.icon(forFile: source.app), source.app, false)
    }.first
    agentIconCache[agent] = .some(found)
    return found
}

@MainActor private var iconCache: [String: NSImage] = [:]
@MainActor func appIcon(_ path: String) -> NSImage {
    if let icon = iconCache[path] { return icon }
    let icon = NSWorkspace.shared.icon(forFile: path)
    iconCache[path] = icon
    return icon
}

struct StatusPill: View {
    let session: Session

    var body: some View {
        let color = session.status == .idle ? Color.white.opacity(0.55) : session.status.color
        HStack(spacing: 6) {
            StatusIcon(status: session.status, size: 12)
            Text(label)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(color)
        .padding(.leading, 8)
        .padding(.trailing, 11)
        .frame(height: 26)
        .background(Capsule().fill(color.opacity(0.13)))
    }

    var label: String {
        switch session.status {
        case .working: return "Working"
        case .waiting:
            if let pending = session.pending {
                return pending.tool == "ExitPlanMode" ? "Review plan" : pending.questions.isEmpty ? "Needs approval" : "Question"
            }
            return session.tool == "AskUserQuestion" ? "Question" : "Needs you"
        case .done: return "Done"
        case .failed: return (session.activity ?? "").lowercased().contains("rate") ? "Limit reached" : "Failed"
        case .idle: return "Idle"
        }
    }
}

struct JumpButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.6))
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .pointer()
        .help(help)
    }
}

// Cool-tinted glass with a gradient edge; every card but an idle one glows from the corner in its status colour:
// blue working, yellow waiting for you, green done, red failed.
struct CardSurface: View {
    let status: Status
    let hovering: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let lively = status != .idle
        ZStack {
            shape.fill(LinearGradient(colors: [frost.opacity(hovering ? 0.13 : 0.08), frost.opacity(hovering ? 0.08 : 0.035)],
                                      startPoint: .top, endPoint: .bottom))
            if lively {
                shape.fill(RadialGradient(colors: [status.color.opacity(0.08), .clear], center: .topLeading, startRadius: 0, endRadius: 220))
            }
            shape.strokeBorder(LinearGradient(
                colors: lively ? [status.color.opacity(0.32), status.color.opacity(0.04)]
                               : [frost.opacity(hovering ? 0.28 : 0.13), frost.opacity(hovering ? 0.1 : 0.02)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
    }
}

// MARK: - Permission

struct PermissionBox: View {
    let pending: Pending
    let answer: (String) -> Void
    let submit: ([String: String]) -> Void
    @AppStorage(Pref.shortcuts) private var shortcuts = true

    var isPlan: Bool { pending.tool == "ExitPlanMode" }

    var body: some View {
        if !pending.questions.isEmpty {
            QuestionBox(questions: pending.questions, shortcuts: shortcuts, submit: submit) { answer("ask") }
        } else {
            approval
        }
    }

    var approval: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(pending.tool)).font(.system(size: 11, weight: .bold))
                Text(isPlan ? "Review the plan" : "Allow \(toolLabel(pending.tool))?").font(.system(size: 12.5, weight: .semibold))
                if !pending.diff.isEmpty {
                    let added = pending.diff.filter(\.added).count
                    Text("+\(added)").foregroundStyle(Status.done.color)
                    Text("−\(pending.diff.count - added)").foregroundStyle(Status.failed.color)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Status.waiting.color)

            Group {
                if isPlan {
                    ScrollView { Text(markdown(pending.detail)).font(.system(size: 12)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 170)
                } else if !pending.diff.isEmpty {
                    DiffView(path: pending.detail, lines: pending.diff)
                } else {
                    Text(pending.detail).font(mono).lineLimit(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07)))

            HStack(spacing: 8) {
                PillButton(title: "Terminal", symbol: "terminal", kind: .ghost) { answer("ask") }
                    .help("Answer this one in the terminal instead")
                Spacer()
                PillButton(title: "Deny", shortcut: shortcuts ? "⌘N" : nil, kind: .destructive) { answer("deny") }
                if pending.canAlways {
                    PillButton(title: "Always allow", kind: .secondary) { answer("always") }
                        .help("Allow and stop asking for this, like Claude's \"don't ask again\"")
                }
                PillButton(title: isPlan ? "Approve" : "Allow", symbol: "checkmark", shortcut: shortcuts ? "⌘Y" : nil, kind: .primary) { answer("allow") }
            }
        }
        .padding(.top, 2)
    }
}

// The changed lines of a file edit, red for removed and green for added, under the file's path.
struct DiffView: View {
    let path: String
    let lines: [DiffLine]
    let shown = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(path).font(mono).foregroundStyle(.white.opacity(0.5)).padding(.bottom, 5)
            ForEach(Array(lines.prefix(shown).enumerated()), id: \.offset) { _, line in
                Text((line.added ? "+ " : "- ") + line.text)
                    .font(mono).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(line.added ? Status.done.color : Status.failed.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background((line.added ? Status.done.color : Status.failed.color).opacity(0.1))
            }
            if lines.count > shown {
                Text("… \(lines.count - shown) more lines").font(mono).foregroundStyle(.white.opacity(0.4)).padding(.top, 3)
            }
        }
    }
}

// AskUserQuestion: click an option to answer. One single-choice question sends at once (⌘1-⌘4 too);
// several questions, or multiple choice, send with the button once each has an answer.
struct QuestionBox: View {
    let questions: [Question]
    let shortcuts: Bool
    let submit: ([String: String]) -> Void
    let terminal: () -> Void
    @State private var picked: [Int: Set<Int>] = [:]

    var instant: Bool { questions.count == 1 && !questions[0].multi }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.bubble.fill").font(.system(size: 11, weight: .bold))
                        if !q.header.isEmpty { Text(q.header.uppercased()).font(.system(size: 10.5, weight: .bold)).kerning(0.5) }
                    }
                    .foregroundStyle(Status.waiting.color)
                    Text(q.text).font(.system(size: 13, weight: .semibold))
                    ForEach(Array(q.options.enumerated()), id: \.offset) { oi, option in
                        OptionRow(label: option.label, detail: option.detail, selected: picked[qi]?.contains(oi) ?? false,
                                  shortcut: instant && shortcuts && oi < 4 ? "⌘\(oi + 1)" : nil) { pick(qi, oi) }
                    }
                }
            }
            HStack(spacing: 8) {
                PillButton(title: "Terminal", symbol: "terminal", kind: .ghost, action: terminal)
                    .help("Answer in the terminal instead")
                Spacer()
                if !instant {
                    PillButton(title: "Send", symbol: "paperplane.fill", kind: .primary) { send() }
                        .disabled(picked.filter { !$0.value.isEmpty }.count < questions.count)
                        .opacity(picked.filter { !$0.value.isEmpty }.count < questions.count ? 0.4 : 1)
                }
            }
        }
        .padding(.top, 2)
    }

    func pick(_ qi: Int, _ oi: Int) {
        if instant { return submit([questions[0].text: questions[0].options[oi].label]) }
        var set = picked[qi] ?? []
        if questions[qi].multi { if set.contains(oi) { set.remove(oi) } else { set.insert(oi) } } else { set = [oi] }
        picked[qi] = set
    }

    func send() {
        var answers: [String: String] = [:]
        for (qi, q) in questions.enumerated() {
            answers[q.text] = (picked[qi] ?? []).sorted().map { q.options[$0].label }.joined(separator: ", ")
        }
        submit(answers)
    }
}

struct OptionRow: View {
    let label: String
    let detail: String
    let selected: Bool
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 12.5, weight: .semibold))
                    if !detail.isEmpty { Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(2) }
                }
                Spacer(minLength: 8)
                if let shortcut { Text(shortcut).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.4)) }
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Status.waiting.color) }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Status.waiting.color.opacity(0.14) : Color.white.opacity(hovering ? 0.09 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Status.waiting.color.opacity(0.5) : Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .pointer()
    }
}

// MARK: - Building blocks

struct StatusIcon: View {
    let status: Status
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Group {
                switch status {
                case .working:
                    ZStack {
                        Circle().strokeBorder(status.color.opacity(0.4), lineWidth: 1.5)
                        Pulse { Circle().fill(status.color).padding(size * 0.26) }
                    }
                case .waiting:
                    Badge(symbol: "exclamationmark", color: status.color, size: size, pulsing: true)
                case .done:
                    Badge(symbol: "checkmark", color: status.color, size: size)
                case .failed:
                    Badge(symbol: "xmark", color: status.color, size: size)
                case .idle:
                    Circle().strokeBorder(status.color.opacity(0.7), lineWidth: 1.2).padding(size * 0.22)
                }
            }
            .id(status)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: status)
    }
}

// A highlight sweeping across text while it is live, like a loading shimmer. Clock-driven, like Pulse.
extension View {
    @ViewBuilder func shimmer(_ on: Bool) -> some View {
        if on {
            overlay {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let x = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8 * 1.8 - 0.4
                    LinearGradient(colors: [.clear, .white.opacity(0.75), .clear],
                                   startPoint: UnitPoint(x: x - 0.25, y: 0.5), endPoint: UnitPoint(x: x + 0.25, y: 0.5))
                }
                .mask(self)
                .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}

// A clock-driven pulse. SwiftUI's own .symbolEffect(.pulse, options: .repeating) stalls the main thread on
// macOS 26 (it waits on the window server for frames), which froze the island while a card waited for you.
struct Pulse<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            content.opacity(0.7 + 0.3 * cos(phase * 2 * .pi))  // never below 40%, so a paused frame still reads
        }
    }
}

// Status glyph on a disc: done, failed, waiting.
struct Badge: View {
    let symbol: String
    let color: Color
    let size: CGFloat
    var pulsing = false

    var body: some View {
        // Waiting is solid so it stands out even in the closed notch; the rest are a glyph on a tinted disc.
        let badge = ZStack {
            Circle().fill(pulsing ? color : color.opacity(0.18))
            Image(systemName: symbol).font(.system(size: size * 0.55, weight: .heavy)).foregroundStyle(pulsing ? Color.black : color)
        }
        if pulsing { Pulse { badge } } else { badge }
    }
}

struct UsageMeter: View {
    let agent: String
    let limit: Limit
    let bar: CGFloat
    let compact: Bool

    var color: Color {
        limit.percent < 50 ? Color(red: 0.3, green: 0.85, blue: 0.75) : limit.percent < 80 ? Color(red: 1, green: 0.5, blue: 0.45) : Status.failed.color
    }

    var body: some View {
        let size: CGFloat = compact ? 10.5 : 12
        HStack(spacing: compact ? 5 : 7) {
            Text(limit.label).font(.system(size: size)).foregroundStyle(.white.opacity(0.5))
            if bar > 0 {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, bar * min(1, limit.percent / 100)))
                }
                .frame(width: bar, height: compact ? 3.5 : 4)
            }
            Text("\(Int(limit.percent.rounded()))%").font(.system(size: size, weight: .semibold, design: .monospaced))
                .foregroundStyle(bar > 0 ? .white : color)
        }
        .help("\(agentName(agent)) \(limit.label) usage, resets in \(remaining(limit.resetsAt))")
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint = Color.white
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(tint.opacity(hovering || active ? 1 : 0.75))
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(active ? 0.2 : hovering ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .pointer()
        .help(help)
    }
}

struct PillButton: View {
    enum Kind { case primary, secondary, destructive, ghost }
    let title: String
    var symbol: String?
    var shortcut: String?
    let kind: Kind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)) }
                Text(title)
                if let shortcut { Text(shortcut).font(.system(size: 11, weight: .medium, design: .monospaced)).opacity(0.5) }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13)
            .frame(height: 28)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .pointer()
    }

    var foreground: Color {
        switch kind {
        case .primary: .black
        case .secondary: .white
        case .destructive: Color(red: 1, green: 0.48, blue: 0.45)
        case .ghost: .white.opacity(hovering ? 0.9 : 0.55)
        }
    }

    var background: Color {
        switch kind {
        case .primary: .white.opacity(hovering ? 0.88 : 1)
        case .secondary: .white.opacity(hovering ? 0.2 : 0.12)
        case .destructive: Color.red.opacity(hovering ? 0.24 : 0.14)
        case .ghost: .white.opacity(hovering ? 0.08 : 0)
        }
    }
}

struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(.white.opacity(0.4))
            Text("No active sessions").font(.system(size: 13, weight: .semibold))
            Text("Start Claude Code, Codex or OpenCode and it shows up here.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
        }
        .padding(.vertical, 22)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: Store
    @AppStorage(Pref.openOnHover) private var openOnHover = true
    @AppStorage(Pref.openForApprovals) private var openForApprovals = true
    @AppStorage(Pref.approveInNotch) private var approveInNotch = true
    @AppStorage(Pref.showUsage) private var showUsage = true
    @AppStorage(Pref.shortcuts) private var shortcuts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Agents") {
                ForEach(Pref.agents, id: \.self) { AgentRow(agent: $0, store: store) }
            }
            SettingsGroup(title: "Island") {
                SettingRow(title: "Open on hover", detail: "Rest the pointer on the notch to open it", isOn: $openOnHover)
                SettingRow(title: "Open when an agent needs you", detail: "Pop open for approvals", isOn: $openForApprovals)
                SettingRow(title: "Approve from the notch", detail: "Off: approvals stay in the terminal", isOn: $approveInNotch)
                SettingRow(title: "Plan usage", detail: "Claude and Codex limits next to the notch", isOn: $showUsage)
                SettingRow(title: "Keyboard shortcuts", detail: "⌘Y allow, ⌘N deny, ⌘1-⌘4 answer, only while a request waits", isOn: $shortcuts)
            }
            SettingsGroup(title: "Sounds") {
                SettingRow(title: "All sounds", detail: "Same as the speaker button", isOn: Binding(get: { !store.muted }, set: { store.muted = !$0 }))
                ForEach(Sound.allCases, id: \.self) { SoundRow(sound: $0, store: store) }
            }
        }
        .padding(.horizontal, 14)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
                .foregroundStyle(.white.opacity(0.4)).padding(.leading, 16)
            VStack(spacing: 0) { content }
                .padding(.vertical, 4)
                .background(CardSurface(status: .idle, hovering: false))
        }
    }
}

struct AgentRow: View {
    let agent: String
    @ObservedObject var store: Store
    @AppStorage private var on: Bool

    init(agent: String, store: Store) {
        self.agent = agent
        self.store = store
        _on = AppStorage(wrappedValue: true, Pref.agent(agent))
    }

    var body: some View {
        SettingRow(title: ["claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode"][agent] ?? agent,
                   detail: on ? (agent == "codex" ? "CLI and the Codex app" : "Terminal sessions") : "Ignored, it asks in its own terminal",
                   dot: agentColor(agent), isOn: $on)
            .onChange(of: on) { if !on { store.dropAgent(agent) } }
    }
}

// Switching one on plays it, so you hear what it sounds like.
struct SoundRow: View {
    let sound: Sound
    @ObservedObject var store: Store
    @AppStorage private var on: Bool

    init(sound: Sound, store: Store) {
        self.sound = sound
        self.store = store
        _on = AppStorage(wrappedValue: true, sound.key)
    }

    var body: some View {
        SettingRow(title: sound.title, detail: "\(sound.detail) · \(customSound(sound) == nil ? sound.file : "custom file")", isOn: $on)
            .opacity(store.muted ? 0.45 : 1)
            .onChange(of: on) { if on { store.play(sound) } }
    }
}

struct SettingRow: View {
    let title: String
    let detail: String
    var dot: Color?
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 12)
            Switch(isOn: isOn)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hovering ? 0.05 : 0)).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .pointer()
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } }
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}

// Drawn by hand: a system switch looks greyed out in a panel that never becomes key.
struct Switch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(LinearGradient(colors: [Status.done.color, Color(red: 0.25, green: 0.8, blue: 0.8)],
                                                       startPoint: .leading, endPoint: .trailing))
                       : AnyShapeStyle(Color.white.opacity(0.16)))
            .frame(width: 32, height: 19)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
    }
}

// MARK: - Helpers

extension Status {
    var color: Color {
        switch self {
        case .idle: .gray
        case .working: Color(red: 0.35, green: 0.7, blue: 1)
        case .waiting: Color(red: 1, green: 0.82, blue: 0.25)
        case .done: Color(red: 0.3, green: 0.85, blue: 0.45)
        case .failed: Color(red: 1, green: 0.4, blue: 0.4)
        }
    }

    var rank: Int {
        switch self {
        case .waiting: 4
        case .working: 3
        case .failed: 2
        case .done: 1
        case .idle: 0
        }
    }
}

func toolIcon(_ tool: String) -> String {
    if tool.hasPrefix("mcp__") { return "puzzlepiece.extension.fill" }
    switch tool {
    case "Bash", "BashOutput", "KillShell": return "terminal.fill"
    case "Read": return "doc.text.fill"
    case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
    case "Glob", "Grep": return "magnifyingglass"
    case "WebFetch", "WebSearch": return "globe"
    case "Task", "Agent": return "person.2.fill"
    case "TodoWrite": return "checklist"
    case "AskUserQuestion": return "questionmark.bubble.fill"
    case "ExitPlanMode": return "list.bullet.clipboard.fill"
    default: return "wrench.and.screwdriver.fill"
    }
}

func agentName(_ agent: String) -> String {
    ["claude": "Claude", "codex": "Codex", "opencode": "OpenCode"][agent] ?? agent.capitalized
}

func agentColor(_ agent: String) -> Color {
    switch agent {
    case "claude": Color(red: 0.92, green: 0.55, blue: 0.38)
    case "codex": Color(red: 0.55, green: 0.8, blue: 1)
    case "opencode": Color(red: 0.75, green: 0.7, blue: 1)
    default: .white
    }
}

// mcp__claude-in-chrome__browser_batch -> "browser batch"
func toolLabel(_ tool: String) -> String {
    guard tool.hasPrefix("mcp__") else { return tool }
    return String(tool.split(separator: "__").last ?? "").replacingOccurrences(of: "_", with: " ")
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

func ago(_ date: Date) -> String {
    let seconds = Int(-date.timeIntervalSinceNow)
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(seconds / 60)m"
    case ..<86400: return "\(seconds / 3600)h"
    default: return "\(seconds / 86400)d"
    }
}

func remaining(_ resetsAt: Double) -> String {
    let minutes = max(0, Int(resetsAt - Date().timeIntervalSince1970) / 60)
    let (d, h, m) = (minutes / 1440, minutes / 60 % 24, minutes % 60)
    return d > 0 ? "\(d)d \(h)h" : "\(h)h \(m)m"
}
