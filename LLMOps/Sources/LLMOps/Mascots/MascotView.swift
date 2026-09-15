import SwiftUI
import CodeIslandCore

typealias MascotAgentStatus = AgentStatus

// MARK: - Mascot Animation Speed Environment

private struct MascotSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var mascotSpeed: Double {
        get { self[MascotSpeedKey.self] }
        set { self[MascotSpeedKey.self] = newValue }
    }
}

/// Routes a CLI source identifier to the pixel mascot view.
struct MascotView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27
    var speed: Double = 1.0
    @ObservedObject private var animationGate = MascotAnimationGate.shared

    init(status: MascotAgentStatus, size: CGFloat = 27, speed: Double = 1.0) {
        self.status = status
        self.size = size
        self.speed = speed
    }

    var body: some View {
        ClawdView(status: status, size: size)
            .environment(\.mascotSpeed, speed)
            .environment(\.mascotAnimationsActive, animationGate.animationsActive)
            .environment(\.mascotAnimationEpoch, animationGate.epoch)
    }
}
