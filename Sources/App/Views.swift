import SwiftUI

let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)
let mono = Font.system(size: 11.5, design: .monospaced)
let expandedWidth: CGFloat = 640

// MARK: - Island

struct IslandView: View {
    @ObservedObject var store: Store
    let notch: NotchGeometry
    let hit: HitArea
    let onHitChange: () -> Void
    @State private var hovering = false
    @State private var listHeight: CGFloat = 0

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
                StatusIcon(status: top.status, size: 13).frame(width: wing)
            }
            Color.clear.frame(width: notch.width)
            if !sessions.isEmpty {
                Text("\(waiting > 0 ? waiting : sessions.count)")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(waiting > 0 ? Color.orange : Color.white.opacity(0.85))
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
            if store.sessions.isEmpty {
                EmptyState()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(store.ordered) { session in
                            SessionCard(session: session, store: store)
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        }
                    }
                    .padding(.horizontal, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, canvasSize.height - notch.height - 120))
            }
        }
        .padding(.bottom, 12)
        .frame(width: expandedWidth)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: layoutKey)
    }

    // Anything that changes a card's size or order animates.
    var layoutKey: [String] {
        store.ordered.map { "\($0.id)|\($0.status)|\($0.pending != nil)|\($0.activity ?? "")|\($0.title ?? "")" }
    }

    var header: some View {
        HStack(spacing: 4) {
            HStack(spacing: 14) {
                if let w = store.usage.fiveHour { UsageMeter(label: "5h", percent: w.percent, resetsAt: w.resetsAt) }
                if let w = store.usage.sevenDay { UsageMeter(label: "7d", percent: w.percent, resetsAt: w.resetsAt) }
            }
            Spacer(minLength: notch.width + 16)
            IconButton(symbol: store.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       help: store.muted ? "Unmute sounds" : "Mute sounds") { store.muted.toggle() }
            IconButton(symbol: "power", help: "Quit Notch Island") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                StatusIcon(status: session.status, size: 14)
                Text("\(Text(session.project).foregroundStyle(.white.opacity(0.5)))  \(title)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if hovering {
                    IconButton(symbol: "xmark", help: "Hide this session") { store.archive(session.id) }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(ago(session.updated)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                }
                Tag(text: agentName(session.agent), color: agentColor(session.agent))
                if let name = session.terminalName { Tag(text: name) }
                IconButton(symbol: "arrow.up.forward", help: "Jump to the terminal") {
                    jump(session)
                    store.expanded = false
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                if session.title != nil, let prompt = session.lastPrompt {
                    Text("\(Text("You").bold().foregroundStyle(.white.opacity(0.5)))  \(Text(prompt).foregroundStyle(.white.opacity(0.6)))")
                        .font(.system(size: 12))
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
            .padding(.leading, 25)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(hovering ? 0.085 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(session.status == .waiting ? Color.orange.opacity(0.45) : Color.white.opacity(0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture {
            jump(session)
            store.expanded = false
        }
    }

    var title: String {
        session.title ?? session.lastPrompt ?? "New session"
    }
}

struct ToolRow: View {
    let tool: String
    let text: String?
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: toolIcon(tool)).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text(toolLabel(tool)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color)
            if let text {
                Text(text).font(mono).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.1)))
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
            .foregroundStyle(.orange)

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
                    Spinner(color: status.color, size: size)
                case .waiting:
                    Pulse { Image(systemName: "exclamationmark.circle.fill") }
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                case .idle:
                    Image(systemName: "circle.dashed")
                }
            }
            .id(status)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(status.color)
        .frame(width: size + 2, height: size + 2)
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
            content.opacity(0.55 + 0.45 * cos(phase * 2 * .pi))
        }
    }
}

// Driven by the clock rather than a repeating animation, so it never drifts while the island resizes.
struct Spinner: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 2)
                Circle().trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .frame(width: size - 2, height: size - 2)
        }
    }
}

struct UsageMeter: View {
    let label: String
    let percent: Double
    let resetsAt: Double

    var color: Color { percent < 50 ? .green : percent < 80 ? .orange : .red }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(color).frame(width: max(4, 28 * min(1, percent / 100)))
            }
            .frame(width: 28, height: 5)
            Text("\(Int(percent.rounded()))%").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
        }
        .help("\(label == "5h" ? "5-hour" : "7-day") Claude usage, resets in \(remaining(resetsAt))")
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.6))
                .background(Circle().fill(Color.white.opacity(hovering ? 0.15 : 0)))
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

struct Tag: View {
    let text: String
    var color = Color.white

    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color == .white ? Color.white.opacity(0.55) : color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(color == .white ? 0.08 : 0.14)))
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(.white.opacity(0.4))
            Text("No active sessions").font(.system(size: 13, weight: .semibold))
            Text("Start claude in any terminal and it shows up here.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
        }
        .padding(.vertical, 22)
    }
}

// MARK: - Helpers

extension Status {
    var color: Color {
        switch self {
        case .idle: .gray
        case .working: Color(red: 0.35, green: 0.78, blue: 1)
        case .waiting: .orange
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
