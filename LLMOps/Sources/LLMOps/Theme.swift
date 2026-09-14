import SwiftUI

enum Theme {
    enum Colors {
        static let bg = Color(hex: 0x0B0A0E)
        static let surface = Color(hex: 0x131019)
        static let line = Color(hex: 0x2C2738)
        static let text = Color(hex: 0xECE8F2)
        static let textDim = Color(hex: 0x9B93AD)
        static let textMuted = Color(hex: 0x857F99)
        static let magenta = Color(hex: 0x9D7AE8)
        static let magentaBright = Color(hex: 0xDDA8FF)
        static let magentaDeep = Color(hex: 0x8B45C9)
        static let cyan = Color(hex: 0x4EC9E8)
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let lg: CGFloat = 14
    }

    enum Fonts {
        static func display(_ size: CGFloat = 28) -> Font {
            .custom("SpaceGrotesk-Bold", size: size)
        }

        static func headline(_ size: CGFloat = 18) -> Font {
            .custom("SpaceGrotesk-Bold", size: size)
        }

        static func body(_ size: CGFloat = 14) -> Font {
            .custom("IBMPlexSans-Regular", size: size)
        }

        static func bodyMedium(_ size: CGFloat = 14) -> Font {
            .custom("IBMPlexSans-Medium", size: size)
        }

        static func label(_ size: CGFloat = 12) -> Font {
            .custom("JetBrainsMono-Medium", size: size)
        }

        static func mono(_ size: CGFloat = 13) -> Font {
            .custom("JetBrainsMono-Regular", size: size)
        }

        static func metric(_ size: CGFloat = 32) -> Font {
            .custom("JetBrainsMono-Bold", size: size)
        }
    }

    /// Hex values as strings, for tests: ["bg": "#0B0A0E", ...] all ten keys.
    static let paletteHex: [String: String] = [
        "bg": "#0B0A0E",
        "surface": "#131019",
        "line": "#2C2738",
        "text": "#ECE8F2",
        "textDim": "#9B93AD",
        "textMuted": "#857F99",
        "magenta": "#9D7AE8",
        "magentaBright": "#DDA8FF",
        "magentaDeep": "#8B45C9",
        "cyan": "#4EC9E8",
    ]
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
