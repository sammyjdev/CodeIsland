import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import CodeIslandCore
import LLMOpsCore

public enum IslandVisibility: String, CaseIterable, Sendable { case whileLive, onlyPending }

public struct IslandModel: Equatable {
    public struct Slot: Equatable {
        public let sessionId: String
        public let project: String
        public let status: AgentStatus
        public let tool: String?
        public let elapsed: TimeInterval

        public init(sessionId: String, project: String, status: AgentStatus, tool: String?, elapsed: TimeInterval) {
            self.sessionId = sessionId
            self.project = project
            self.status = status
            self.tool = tool
            self.elapsed = elapsed
        }
    }

    public let slots: [Slot]                 // live sessions, most recent activity first, max 4
    public let hiddenCount: Int              // live sessions beyond 4
    public let pending: [PendingPermission]  // oldest first
    public let expanded: Bool

    public init(slots: [Slot], hiddenCount: Int, pending: [PendingPermission], expanded: Bool) {
        self.slots = slots
        self.hiddenCount = hiddenCount
        self.pending = pending
        self.expanded = expanded
    }

    public static func == (lhs: IslandModel, rhs: IslandModel) -> Bool {
        guard lhs.slots == rhs.slots,
              lhs.hiddenCount == rhs.hiddenCount,
              lhs.expanded == rhs.expanded,
              lhs.pending.count == rhs.pending.count else {
            return false
        }
        for (p1, p2) in zip(lhs.pending, rhs.pending) {
            if p1.id != p2.id ||
                p1.sessionId != p2.sessionId ||
                p1.kind != p2.kind ||
                p1.toolName != p2.toolName ||
                p1.description != p2.description ||
                p1.options != p2.options ||
                p1.receivedAt != p2.receivedAt {
                return false
            }
        }
        return true
    }

    /// Pure builder. live = model.visibleLive (already filtered by profile), pending = model.live.pending.
    /// Slot.project = last path component of cwd or "unknown". Slot.elapsed = now - startTime.
    /// expanded = !pending.isEmpty || hoverExpanded || pinnedExpanded.
    public static func build(live: [SessionSnapshot], pending: [PendingPermission], hoverExpanded: Bool, pinnedExpanded: Bool, now: Date) -> IslandModel {
        let sorted = live.sorted { $0.lastActivity > $1.lastActivity }
        let top4 = sorted.prefix(4)
        let hiddenCount = max(0, sorted.count - 4)

        let slots = top4.map { session -> Slot in
            let project: String
            if let cwd = session.cwd {
                let name = (cwd as NSString).lastPathComponent
                project = (name.isEmpty || name == "/") ? "unknown" : name
            } else {
                project = "unknown"
            }
            let elapsed = now.timeIntervalSince(session.startTime)
            return Slot(
                sessionId: session.providerSessionId ?? "",
                project: project,
                status: session.status,
                tool: session.currentTool,
                elapsed: elapsed
            )
        }

        let expanded = !pending.isEmpty || hoverExpanded || pinnedExpanded

        return IslandModel(
            slots: slots,
            hiddenCount: hiddenCount,
            pending: pending,
            expanded: expanded
        )
    }

    /// Visible when: presentation == .notch AND (
    ///   visibility == .whileLive AND (!slots.isEmpty || !pending.isEmpty)
    ///   OR visibility == .onlyPending AND !pending.isEmpty )
    public static func isVisible(_ model: IslandModel, presentation: LLMOpsSettings.RequestPresentation, visibility: IslandVisibility) -> Bool {
        guard presentation == .notch else { return false }
        switch visibility {
        case .whileLive:
            return !model.slots.isEmpty || !model.pending.isEmpty
        case .onlyPending:
            return !model.pending.isEmpty
        }
    }

    /// Pose for a mascot. Mapping: .idle -> the sleeping pose, .processing and .running -> working,
    /// .waitingApproval and .waitingQuestion -> alert. If AgentStatus has other cases map them to working.
    public static func isAlert(_ status: AgentStatus) -> Bool {
        switch status {
        case .waitingApproval, .waitingQuestion:
            return true
        default:
            return false
        }
    }
}

@MainActor
public final class IslandInteraction: ObservableObject {
    @Published public var hoverExpanded = false
    @Published public var pinnedExpanded = false
    public var hoverTask: Task<Void, Never>?

    public init() {}
}

/// Bounces forever while attached. Attach only to alert mascots so the
/// animation (re)starts whenever a slot turns alert, not once on panel appear.
/// HoverFlag instead of @State: SwiftUI macros do not build on this toolchain.
private struct AlertBounce: ViewModifier {
    @StateObject private var up = HoverFlag()
    func body(content: Content) -> some View {
        content
            .offset(y: up.isOn ? -4 : 0)
            .onAppear {
                withAnimation(NotchAnimation.pop.repeatForever(autoreverses: true)) { up.isOn = true }
            }
    }
}

struct IslandView: View {
    var model: AppModel
    @ObservedObject var interaction: IslandInteraction

    var body: some View {
        let now = Date()
        let islandModel = IslandModel.build(
            live: model.visibleLive,
            pending: model.live.pending,
            hoverExpanded: interaction.hoverExpanded,
            pinnedExpanded: interaction.pinnedExpanded,
            now: now
        )

        VStack(spacing: 0) {
            // Row 1 (always)
            HStack(spacing: 18) {
                if islandModel.slots.isEmpty && !islandModel.pending.isEmpty {
                    VStack(spacing: 2) {
                        MascotView(status: .waitingApproval, size: 27, speed: Double(model.settings.mascotSpeed) / 100.0)
                            .modifier(AlertBounce())
                        Text("pending")
                            .font(Theme.Fonts.mono(9))
                            .foregroundStyle(Theme.Colors.textDim)
                            .lineLimit(1)
                            .frame(maxWidth: 72)
                    }
                } else {
                    ForEach(islandModel.slots.indices, id: \.self) { idx in
                        let slot = islandModel.slots[idx]
                        let alert = IslandModel.isAlert(slot.status)
                        VStack(spacing: 2) {
                            if alert {
                                MascotView(status: slot.status, size: 27, speed: Double(model.settings.mascotSpeed) / 100.0)
                                    .modifier(AlertBounce())
                            } else {
                                MascotView(status: slot.status, size: 27, speed: Double(model.settings.mascotSpeed) / 100.0)
                            }
                            Text(slot.project)
                                .font(Theme.Fonts.mono(9))
                                .foregroundStyle(Theme.Colors.textDim)
                                .lineLimit(1)
                                .frame(maxWidth: 72)
                        }
                    }
                    if islandModel.hiddenCount > 0 {
                        Text("+\(islandModel.hiddenCount)")
                            .font(Theme.Fonts.mono(9))
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                }
            }
            .frame(height: 44)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(interaction.pinnedExpanded ? NotchAnimation.close : NotchAnimation.open) {
                    interaction.pinnedExpanded.toggle()
                }
            }

            // Row 2 (only when expanded)
            if islandModel.expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(islandModel.slots.indices, id: \.self) { idx in
                        let slot = islandModel.slots[idx]
                        Text("\(slot.project)  \(slot.tool ?? "idle")  \(HistoryFormat.duration(ms: Int(slot.elapsed * 1000)))")
                            .font(Theme.Fonts.mono(10))
                            .foregroundStyle(Theme.Colors.textDim)
                    }

                    let prefix = Array(islandModel.pending.prefix(3))
                    let extra = islandModel.pending.count - prefix.count
                    ForEach(prefix) { item in
                        PermissionCard(item: item, now: now) { decision in
                            model.live.resolve(id: item.id, decision: decision)
                        }
                    }
                    if extra > 0 {
                        Text("+\(extra) more in live")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                }
                .padding(12)
                .transition(.blurFade)
            }
        }
        .frame(width: NotchPanelController.width)
        .background(Color.black)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 0
            )
        )
        .animation(islandModel.expanded ? NotchAnimation.open : NotchAnimation.close, value: islandModel.expanded)
        .onHover { inside in
            interaction.hoverTask?.cancel()
            if inside {
                interaction.hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(NotchHoverInteraction.hoverDelay))
                    guard !Task.isCancelled else { return }
                    withAnimation(NotchAnimation.open) {
                        interaction.hoverExpanded = true
                    }
                }
            } else {
                interaction.hoverTask = nil
                withAnimation(NotchAnimation.close) {
                    interaction.hoverExpanded = false
                }
            }
        }
    }
}

@MainActor
final class NotchPanelController {
    static let width: CGFloat = 420
    let model: AppModel
    let interaction = IslandInteraction()
    private(set) var panel: NSPanel?
    var screenProvider: () -> NSScreen? = { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    private var isObservationArmed = false
    private var screenObserver: (any NSObjectProtocol)?
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
    }

    /// Builds the panel once (lazily), then observes model.live.pending, live sessions, settings, and interaction.
    func start() {
        MascotAnimationGate.shared.start()
        ensurePanel()
        setupScreenObserver()
        setupInteractionObservers()
        refresh()
        arm()
    }

    /// True when the panel exists and isVisible.
    var isShowing: Bool {
        panel?.isVisible ?? false
    }

    /// Called by start and on every observed change: shows when visible according to IslandModel.
    func refresh() {
        ensurePanel()
        guard let panel else { return }
        let islandModel = IslandModel.build(
            live: model.visibleLive,
            pending: model.live.pending,
            hoverExpanded: interaction.hoverExpanded,
            pinnedExpanded: interaction.pinnedExpanded,
            now: Date()
        )
        let shouldShow = IslandModel.isVisible(
            islandModel,
            presentation: model.settings.requestPresentation,
            visibility: model.settings.islandVisibility
        )
        // A collapsed strip of sleeping mascots must not keep TimelineView ticking.
        MascotAnimationGate.shared.setIdleSettled(
            !islandModel.expanded && islandModel.slots.allSatisfy { $0.status == .idle }
        )
        if shouldShow {
            reposition()
            panel.orderFrontRegardless()
            MascotAnimationGate.shared.setPanelVisible(true)
        } else {
            panel.orderOut(nil)
            MascotAnimationGate.shared.setPanelVisible(false)
        }
    }

    /// Frame for a panel of height on screen: x centered, top edge at screen.frame.maxY - topInset, where
    /// topInset = screen.safeAreaInsets.top when > 0, else screen.frame.maxY - screen.visibleFrame.maxY.
    static func frame(height: CGFloat, screen: NSScreen) -> NSRect {
        let topInset: CGFloat = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : (screen.frame.maxY - screen.visibleFrame.maxY)
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - topInset - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: IslandView(model: model, interaction: interaction))
        self.panel = p
    }

    private func reposition() {
        guard let panel, let screen = screenProvider() else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let measuredHeight = panel.contentView?.fittingSize.height ?? 0
        let height = min(600, max(1, measuredHeight))
        let newFrame = Self.frame(height: height, screen: screen)
        panel.setFrame(newFrame, display: true)
    }

    private func arm() {
        guard !isObservationArmed else { return }
        isObservationArmed = true
        withObservationTracking {
            _ = model.visibleLive
            _ = model.live.pending
            _ = model.live.sessions
            _ = model.settings.requestPresentation
            _ = model.settings.islandVisibility
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObservationArmed = false
                self.refresh()
                self.arm()
            }
        }
    }

    private func setupInteractionObservers() {
        interaction.$hoverExpanded
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        interaction.$pinnedExpanded
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func setupScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
            }
        }
    }
}
