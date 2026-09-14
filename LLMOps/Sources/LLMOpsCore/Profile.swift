import Foundation

public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public var id: String          // stable slug, e.g. "pessoal", "afya"
    public var name: String        // display name
    public var configDir: String   // may contain a leading "~"
    public var pathPrefixes: [String] // each may contain a leading "~"

    public init(id: String, name: String, configDir: String, pathPrefixes: [String]) {
        self.id = id
        self.name = name
        self.configDir = configDir
        self.pathPrefixes = pathPrefixes
    }

    /// configDir with "~" expanded to the home directory and no trailing slash.
    public var expandedConfigDir: String {
        Self.normalizePath(configDir)
    }

    /// pathPrefixes with "~" expanded, no trailing slashes.
    public var expandedPathPrefixes: [String] {
        pathPrefixes.map { Self.normalizePath($0) }
    }

    /// `<expandedConfigDir>/projects`
    public var projectsDir: String {
        expandedConfigDir + "/projects"
    }

    static func normalizePath(_ path: String) -> String {
        let expanded: String
        if path == "~" {
            expanded = NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            expanded = NSHomeDirectory() + path.dropFirst(1)
        } else {
            expanded = path
        }

        var result = expanded
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

public enum ProfileDefaults {
    /// Two profiles: id "pessoal" (name "pessoal", configDir "~/.claude", no
    /// prefixes) and id "afya" (name "afya", configDir "~/.claude-zed",
    /// pathPrefixes ["~/dev/afya"]). Order matters: "pessoal" first.
    public static func defaults() -> [Profile] {
        [
            Profile(
                id: "pessoal",
                name: "pessoal",
                configDir: "~/.claude",
                pathPrefixes: []
            ),
            Profile(
                id: "afya",
                name: "afya",
                configDir: "~/.claude-zed",
                pathPrefixes: ["~/dev/afya"]
            ),
        ]
    }
}

public final class ProfileStore {
    public static let defaultsKey = "llmops.profiles.v1"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Returns saved profiles, or `ProfileDefaults.defaults()` when nothing is
    /// saved or the saved JSON fails to decode.
    public func load() -> [Profile] {
        guard let data = userDefaults.data(forKey: Self.defaultsKey) else {
            return ProfileDefaults.defaults()
        }
        do {
            return try JSONDecoder().decode([Profile].self, from: data)
        } catch {
            return ProfileDefaults.defaults()
        }
    }

    /// Encodes as JSON under `defaultsKey`.
    public func save(_ profiles: [Profile]) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}

public enum ProfileResolver {
    /// Picks the profile whose expanded prefix is the LONGEST prefix of `cwd`
    /// (prefix match is on path components: "~/dev/afya" matches
    /// "~/dev/afya/x" and "~/dev/afya" itself but NOT "~/dev/afyaX").
    /// Returns `profiles.first` when nothing matches. Returns nil only when
    /// `profiles` is empty.
    public static func resolve(cwd: String, profiles: [Profile]) -> Profile? {
        guard !profiles.isEmpty else { return nil }

        let normalizedCwd = Profile.normalizePath(cwd)
        let cwdComponents = (normalizedCwd as NSString).pathComponents

        var bestProfile: Profile?
        var bestComponentCount = -1

        for profile in profiles {
            for prefix in profile.expandedPathPrefixes {
                let normalizedPrefix = Profile.normalizePath(prefix)
                let prefixComponents = (normalizedPrefix as NSString).pathComponents

                if isComponentPrefix(prefixComponents, of: cwdComponents) {
                    if prefixComponents.count > bestComponentCount {
                        bestComponentCount = prefixComponents.count
                        bestProfile = profile
                    }
                }
            }
        }

        return bestProfile ?? profiles.first
    }

    private static func isComponentPrefix(_ prefix: [String], of path: [String]) -> Bool {
        guard !prefix.isEmpty else { return false }
        guard prefix.count <= path.count else { return false }
        return Array(path.prefix(prefix.count)) == prefix
    }
}
