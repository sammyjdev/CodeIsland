import Foundation
import Testing
@testable import LLMOpsCore

@Test func expandedConfigDirExpandsTildeAndStripsTrailingSlash() {
    let home = NSHomeDirectory()
    let profileWithSlash = Profile(id: "test", name: "Test", configDir: "~/.claude/", pathPrefixes: [])
    #expect(profileWithSlash.expandedConfigDir == home + "/.claude")

    let profileWithoutSlash = Profile(id: "test", name: "Test", configDir: "~/.claude", pathPrefixes: [])
    #expect(profileWithoutSlash.expandedConfigDir == home + "/.claude")
}

@Test func expandedPathPrefixesExpandsTildeAndLeavesAbsoluteUnchanged() {
    let home = NSHomeDirectory()
    let profile = Profile(
        id: "test",
        name: "Test",
        configDir: "~/.claude",
        pathPrefixes: ["~/dev/afya/", "/var/log/test/"]
    )
    #expect(profile.expandedPathPrefixes == [home + "/dev/afya", "/var/log/test"])
}

@Test func projectsDirAppendsProjectsToExpandedConfigDir() {
    let home = NSHomeDirectory()
    let profile = Profile(id: "test", name: "Test", configDir: "~/.claude", pathPrefixes: [])
    #expect(profile.projectsDir == home + "/.claude/projects")
}

@Test func profileDefaultsReturnsExpectedProfilesInOrder() {
    let defaults = ProfileDefaults.defaults()
    #expect(defaults.count == 2)
    #expect(defaults.map(\.id) == ["pessoal", "afya"])
    #expect(defaults[0].name == "pessoal")
    #expect(defaults[0].configDir == "~/.claude")
    #expect(defaults[0].pathPrefixes == [])
    #expect(defaults[1].name == "afya")
    #expect(defaults[1].configDir == "~/.claude-zed")
    #expect(defaults[1].pathPrefixes == ["~/dev/afya"])
}

@Test func profileStoreRoundTrip() {
    let suiteName = "ProfileTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
    let store = ProfileStore(userDefaults: userDefaults)
    let profiles = [
        Profile(id: "p1", name: "Profile 1", configDir: "~/.c1", pathPrefixes: ["~/p1"]),
        Profile(id: "p2", name: "Profile 2", configDir: "/etc/c2", pathPrefixes: ["/var/p2"])
    ]
    store.save(profiles)
    let loaded = store.load()
    #expect(loaded == profiles)
}

@Test func profileStoreLoadReturnsDefaultsWhenEmptyOrCorrupted() {
    let suiteName = "ProfileTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
    let store = ProfileStore(userDefaults: userDefaults)
    #expect(store.load() == ProfileDefaults.defaults())

    userDefaults.set("not json".data(using: .utf8), forKey: ProfileStore.defaultsKey)
    #expect(store.load() == ProfileDefaults.defaults())
}

@Test func profileResolverPicksLongestMatchingPrefix() {
    let home = NSHomeDirectory()
    let profileA = Profile(id: "a", name: "A", configDir: "~/.a", pathPrefixes: ["~/dev"])
    let profileB = Profile(id: "b", name: "B", configDir: "~/.b", pathPrefixes: ["~/dev/afya"])
    let resolved = ProfileResolver.resolve(cwd: home + "/dev/afya/labs", profiles: [profileA, profileB])
    #expect(resolved == profileB)
}

@Test func profileResolverRespectsComponentBoundary() {
    let home = NSHomeDirectory()
    let profileDefault = Profile(id: "default", name: "Default", configDir: "~/.default", pathPrefixes: [])
    let profileAfya = Profile(id: "afya", name: "Afya", configDir: "~/.afya", pathPrefixes: ["~/dev/afya"])

    let resolvedNonMatch = ProfileResolver.resolve(cwd: home + "/dev/afyaX/foo", profiles: [profileDefault, profileAfya])
    #expect(resolvedNonMatch == profileDefault)

    let resolvedExact = ProfileResolver.resolve(cwd: home + "/dev/afya", profiles: [profileDefault, profileAfya])
    #expect(resolvedExact == profileAfya)
}

@Test func profileResolverFallsBackToFirstOrNilWhenEmpty() {
    let p1 = Profile(id: "p1", name: "P1", configDir: "~/.p1", pathPrefixes: ["~/other"])
    let resolvedFallback = ProfileResolver.resolve(cwd: "/tmp/elsewhere", profiles: [p1])
    #expect(resolvedFallback == p1)

    let resolvedEmpty = ProfileResolver.resolve(cwd: "/tmp/elsewhere", profiles: [])
    #expect(resolvedEmpty == nil)
}
