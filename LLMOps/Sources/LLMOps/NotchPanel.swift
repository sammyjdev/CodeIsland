import AppKit
import Foundation
import Observation
import SwiftUI
import CodeIslandCore
import LLMOpsCore

extension Theme.Radius {
    static let md: CGFloat = 10
}

struct NotchPanelView: View {
    var model: AppModel

    var body: some View {
        let pending = model.live.pending
        let prefix = Array(pending.prefix(3))
        let extra = pending.count - prefix.count

        VStack(alignment: .leading, spacing: 8) {
            ForEach(prefix) { item in
                PermissionCard(item: item, now: Date()) { decision in
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
        .frame(width: NotchPanelController.width)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.line, lineWidth: 1)
        )
    }
}

@MainActor
final class NotchPanelController {
    static let width: CGFloat = 420
    let model: AppModel
    private(set) var panel: NSPanel?
    var screenProvider: () -> NSScreen? = { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    private var isObservationArmed = false
    private var screenObserver: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
    }

    /// Builds the panel once (lazily), then observes model.live.pending and model.settings.requestPresentation.
    func start() {
        ensurePanel()
        setupScreenObserver()
        refresh()
        arm()
    }

    /// True when the panel exists and isVisible.
    var isShowing: Bool {
        panel?.isVisible ?? false
    }

    /// Called by start and on every observed change: shows when pending is non empty and presentation == .notch,
    /// hides otherwise. Repositions before showing.
    func refresh() {
        ensurePanel()
        guard let panel else { return }
        let shouldShow = !model.live.pending.isEmpty && model.settings.requestPresentation == .notch
        if shouldShow {
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Frame for a panel of `height` on `screen`: x centered, top edge at screen.frame.maxY - topInset, where
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
        p.contentView = NSHostingView(rootView: NotchPanelView(model: model))
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
            _ = model.live.pending
            _ = model.settings.requestPresentation
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObservationArmed = false
                self.refresh()
                self.arm()
            }
        }
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
