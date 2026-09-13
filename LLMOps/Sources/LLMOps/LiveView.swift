import SwiftUI

struct LiveView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "live")
            Text("// nothing here yet")
                .font(Theme.Fonts.mono(12))
                .foregroundStyle(Theme.Colors.textDim)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.bg)
    }
}
