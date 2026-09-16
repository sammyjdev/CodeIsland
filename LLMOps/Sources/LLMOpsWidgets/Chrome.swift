import SwiftUI
import WidgetKit
import LLMOpsCore

enum WidgetPalette {
    static let bg = Color(hex: 0x0B0A0E)
    static let line = Color(hex: 0x2C2738)
    static let track = Color(hex: 0x2C2738)
    static let text = Color(hex: 0xECE8F2)
    static let dim = Color(hex: 0x9B93AD)
    static let muted = Color(hex: 0x857F99)
    static let accent = Color(hex: 0x9D7AE8)
    static let accentBright = Color(hex: 0xDDA8FF)
    static let cyan = Color(hex: 0x4EC9E8)
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

enum WidgetTimeFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

struct WidgetFrame<Content: View>: View {
    let title: String
    let writtenAt: Date?
    let content: Content

    init(title: String, writtenAt: Date? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.writtenAt = writtenAt
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 9, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundColor(WidgetPalette.dim)
                Spacer()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let writtenAt {
                HStack {
                    Spacer()
                    Text(WidgetTimeFormat.format(writtenAt))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(WidgetPalette.muted)
                }
            }
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(WidgetPalette.line, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(WidgetPalette.bg, for: .widget)
    }
}

struct QuotaBar: View {
    let percent: Double?
    let tint: Color?

    init(percent: Double?, tint: Color? = nil) {
        self.percent = percent
        self.tint = tint
    }

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(percent ?? 0.0, 0.0), 100.0)
            let width = geo.size.width * (clamped / 100.0)
            let fillColor = tint ?? (clamped >= 80.0 ? WidgetPalette.accentBright : WidgetPalette.accent)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WidgetPalette.track)
                    .frame(height: 4)

                if percent != nil && clamped > 0 {
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(width, 4), height: 4)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 4)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("no data")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(WidgetPalette.dim)
            Text("open LLMOps")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(WidgetPalette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
