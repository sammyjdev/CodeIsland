import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LLMOps

@Suite struct ThemeTests {
    @Test func paletteHexExactKeysAndValues() {
        let expected: [String: String] = [
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
        #expect(Theme.paletteHex == expected)
    }

    @Test func colorHexComponents() {
        let color = Color(hex: 0x9D7AE8)
        let nsColor = NSColor(color).usingColorSpace(.sRGB)
        #expect(nsColor != nil)
        if let nsColor {
            #expect(abs(nsColor.redComponent - Double(0x9D) / 255.0) < 0.002)
            #expect(abs(nsColor.greenComponent - Double(0x7A) / 255.0) < 0.002)
            #expect(abs(nsColor.blueComponent - Double(0xE8) / 255.0) < 0.002)
        }
    }

    @Test func sourceScanForForbiddenTokens() throws {
        let testFilePath = #filePath
        let testDir = URL(fileURLWithPath: testFilePath).deletingLastPathComponent()
        let packageRoot = testDir.deletingLastPathComponent().deletingLastPathComponent()
        let sourcesDir = packageRoot.appendingPathComponent("Sources/LLMOps")

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else {
            Issue.record("Failed to enumerate Sources/LLMOps at \(sourcesDir.path)")
            return
        }

        let forbiddenStrings = [
            ".shadow(",
            "LinearGradient",
            "AngularGradient",
            "RadialGradient",
            ".blur(",
            "\u{2014}",
            "\u{2013}",
        ]

        var scannedCount = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            scannedCount += 1
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenStrings {
                let containsToken = content.contains(token)
                #expect(!containsToken, "File \(fileURL.lastPathComponent) contains forbidden token: \(token)")
            }
        }
        #expect(scannedCount > 0, "Expected to scan at least one Swift file in Sources/LLMOps")
    }
}
