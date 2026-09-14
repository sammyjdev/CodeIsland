import Foundation
import Testing
@testable import LLMOps

/// The three DESIGN.md families must ship inside the LLMOps resource bundle.
@Test func bundledFontFamiliesPresent() throws {
    let dir = try #require(Bundle.module.url(forResource: "Fonts", withExtension: nil, subdirectory: "Resources"))
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    for family in ["JetBrainsMono", "SpaceGrotesk", "IBMPlexSans"] {
        #expect(names.contains { $0.hasPrefix(family) && $0.hasSuffix(".ttf") }, "missing \(family)")
    }
}
