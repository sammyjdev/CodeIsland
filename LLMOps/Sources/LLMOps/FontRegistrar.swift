import CoreText
import Foundation

/// Registers the bundled OFL fonts (Space Grotesk, IBM Plex Sans, JetBrains Mono)
/// for this process so `Font.custom` resolves them under both `swift run` and the
/// packaged .app, without an Info.plist ATSApplicationFontsPath entry.
enum FontRegistrar {
    static func registerBundledFonts() {
        guard let fontsDir = Bundle.module.url(forResource: "Fonts", withExtension: nil, subdirectory: "Resources"),
              let urls = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
