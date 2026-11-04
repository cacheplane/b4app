import Foundation
import Testing

@testable import WorkspaceUI

@Suite struct LocalPreferencesTests {
  @Test func inMemoryKeepsAndRemovesValues() {
    let prefs = InMemoryPreferences()
    #expect(prefs.data(forKey: "model") == nil)
    prefs.set(Data("opus".utf8), forKey: "model")
    #expect(prefs.data(forKey: "model") == Data("opus".utf8))
    prefs.set(nil, forKey: "model")
    #expect(prefs.data(forKey: "model") == nil)
  }

  @Test func userDefaultsStoresDataAndNilRemovesIt() throws {
    let suite = "LocalPreferencesTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs: any LocalPreferences = defaults
    prefs.set(Data("plan".utf8), forKey: "permission")
    #expect(prefs.data(forKey: "permission") == Data("plan".utf8))
    prefs.set(nil, forKey: "permission")
    #expect(prefs.data(forKey: "permission") == nil)
  }

  @Test func theModelDefaultsToTheAppDefaults() {
    let model = WorkspaceModel(transportProvider: { throw CancellationError() })
    #expect(model.preferences === UserDefaults.standard)
    let prefs = InMemoryPreferences()
    model.preferences = prefs
    #expect(model.preferences === prefs)
  }
}
