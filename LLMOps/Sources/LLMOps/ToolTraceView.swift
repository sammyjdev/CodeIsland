import SwiftUI
import LLMOpsCore

struct ToolTraceView: View {
    let calls: [ToolCall]

    private var maxDuration: Int {
        calls.compactMap(\.durationMs).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(calls) { call in
                HStack(spacing: 8) {
                    Text(call.name)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.text)
                        .frame(minWidth: 90, alignment: .leading)

                    Text(call.inputSummary)
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)

                    barView(for: call)

                    Text(HistoryFormat.duration(ms: call.durationMs))
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.textDim)
                        .frame(minWidth: 45, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func barView(for call: ToolCall) -> some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            if let duration = call.durationMs {
                let ratio = maxDuration > 0 ? CGFloat(duration) / CGFloat(maxDuration) : 1.0
                let barWidth = max(2.0, totalWidth * min(1.0, max(0.0, ratio)))
                RoundedRectangle(cornerRadius: 2)
                    .fill(call.isError ? Theme.Colors.magentaDeep : Theme.Colors.magenta)
                    .frame(width: barWidth, height: 6)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.Colors.line, lineWidth: 1)
                    .frame(width: totalWidth, height: 6)
            }
        }
        .frame(minWidth: 40, idealWidth: 80, maxHeight: 6)
    }
}
