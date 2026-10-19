import SwiftUI

let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
let mono = Font.system(size: 11.5, design: .monospaced)
let expandedWidth: CGFloat = 640
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
                .frame(height: min(listHeight, firstCardsHeight, canvasSize.height - notch.height - 120))
                if store.ordered.count > visibleCards {
                    Text("+\(store.ordered.count - visibleCards) more · scroll").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 2)
                }
            }
        }
        .padding(.bottom, 14)
        .frame(width: expandedWidth)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: layoutKey)
        .animation(.easeOut(duration: 0.18), value: showingSettings)
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
        HStack(spacing: 4) {
            if showingSettings {
                Text("Settings").font(.system(size: 13, weight: .semibold))
            } else if showUsage {
                HStack(spacing: 22) {
                    if let w = store.usage.fiveHour { UsageMeter(label: "5h", percent: w.percent, resetsAt: w.resetsAt) }
                    if let w = store.usage.sevenDay { UsageMeter(label: "7d", percent: w.percent, resetsAt: w.resetsAt) }
                }
            }
            Spacer(minLength: notch.width + 16)
            IconButton(symbol: store.muted ? "speaker.slash" : "speaker.wave.2",
                       help: store.muted ? "Unmute sounds" : "Mute sounds") { store.muted.toggle() }
            IconButton(symbol: "gearshape", help: showingSettings ? "Back to sessions" : "Settings", active: showingSettings) {
                showingSettings.toggle()
            }
            IconButton(symbol: "power", help: "Quit Notch Island") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 20)
        .frame(height: notch.height)
        .contentShape(Rectangle())
        .onTapGesture { store.expanded = false }
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                StatusIcon(status: session.status, size: 16)
                Text("\(Text(session.project).foregroundStyle(.white.opacity(0.45)))\(Text("  /  ").foregroundStyle(.white.opacity(0.22)))\(Text(title).fontWeight(.semibold))")
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if hovering {
                    IconButton(symbol: "xmark", help: "Hide this session") { store.archive(session.id) }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(ago(session.updated)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                }
                AgentLabel(agent: session.agent)
            }

            // Left out when empty, or its spacing pads a title-only card.
            if hasDetails { VStack(alignment: .leading, spacing: 9) {
                if session.title != nil, let prompt = session.lastPrompt {
                    Text("\(Text("You").foregroundStyle(.white.opacity(0.8)))\(Text(" · ").foregroundStyle(.white.opacity(0.3)))\(Text(prompt).foregroundStyle(.white.opacity(0.5)))")
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                }
                if let tool = session.tool, session.status == .working || session.status == .waiting {
                    ToolRow(tool: tool, text: session.activity, color: session.status.color)
                } else if let activity = session.activity {
                    Text(activity).font(.system(size: 12, weight: .medium)).foregroundStyle(session.status.color).lineLimit(2)
                } else if let message = session.lastMessage {
                    Text(markdown(message)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3).lineSpacing(2)
                }
                if let pending = session.pending {
                    PermissionBox(pending: pending) { store.respond(session.id, $0) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.leading, 29) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(session.status == .waiting ? Status.waiting.color.opacity(0.45) : Color.white.opacity(hovering ? 0.16 : 0.04)))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .help(session.terminalName.map { "Click to jump to \($0)" } ?? "Click to jump to the terminal")
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture {
            jump(session)
            store.expanded = false
        }
    }

    var title: String {
        session.title ?? session.lastPrompt ?? "New session"
    }

    var hasDetails: Bool {
        (session.title != nil && session.lastPrompt != nil) || session.tool != nil || session.activity != nil
            || session.lastMessage != nil || session.pending != nil
    }
}

struct ToolRow: View {
    let tool: String
    let text: String?
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toolIcon(tool)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            Text(toolLabel(tool)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(color)
            if let text {
                Text(text).font(mono).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

// MARK: - Permission

struct PermissionBox: View {
    let pending: Pending
    let answer: (String) -> Void

    var isPlan: Bool { pending.tool == "ExitPlanMode" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(pending.tool)).font(.system(size: 11, weight: .bold))
                Text(isPlan ? "Review the plan" : "Allow \(toolLabel(pending.tool))?").font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Status.waiting.color)

            Group {
                if isPlan {
                    ScrollView { Text(markdown(pending.detail)).font(.system(size: 12)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 170)
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
                PillButton(title: "Deny", kind: .destructive) { answer("deny") }
                if pending.canAlways {
                    PillButton(title: "Always allow", kind: .secondary) { answer("always") }
                        .help("Allow and stop asking for this, like Claude's \"don't ask again\"")
                }
                PillButton(title: isPlan ? "Approve" : "Allow", symbol: "checkmark", kind: .primary) { answer("allow") }
            }
        }
        .padding(.top, 2)
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
    let label: String
    let percent: Double
    let resetsAt: Double

    var color: Color {
        percent < 50 ? Status.done.color : percent < 80 ? Color(red: 0.95, green: 0.55, blue: 0.4) : Status.failed.color
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color).frame(width: max(4, 64 * min(1, percent / 100)))
            }
            .frame(width: 64, height: 4)
            Text("\(Int(percent.rounded()))%").font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .help("\(label == "5h" ? "5-hour" : "7-day") Claude usage, resets in \(remaining(resetsAt))")
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(.white.opacity(hovering || active ? 1 : 0.6))
                .background(Circle().fill(Color.white.opacity(active ? 0.16 : hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(help)
    }
}

struct PillButton: View {
    enum Kind { case primary, secondary, destructive, ghost }
    let title: String
    var symbol: String?
    let kind: Kind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)) }
                Text(title)
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

struct AgentLabel: View {
    let agent: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(agentColor(agent)).frame(width: 6, height: 6)
            Text(agentName(agent)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Agents") {
                ForEach(Pref.agents, id: \.self) { AgentRow(agent: $0, store: store) }
            }
            SettingsGroup(title: "Island") {
                SettingRow(title: "Open on hover", detail: "Rest the pointer on the notch to open it", isOn: $openOnHover)
                SettingRow(title: "Open when an agent needs you", detail: "Pop open for approvals", isOn: $openForApprovals)
                SettingRow(title: "Approve from the notch", detail: "Off: approvals stay in the terminal", isOn: $approveInNotch)
                SettingRow(title: "Plan usage", detail: "Claude's 5-hour and 7-day limits in the header", isOn: $showUsage)
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
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.04)))
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
        SettingRow(title: sound.title, detail: "\(sound.detail) · \(sound.file)", isOn: $on)
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
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } }
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}

// Drawn by hand: a system switch looks greyed out in a panel that never becomes key.
struct Switch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Status.done.color : Color.white.opacity(0.16))
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
        case .waiting: Color(red: 1, green: 0.76, blue: 0.3)
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
