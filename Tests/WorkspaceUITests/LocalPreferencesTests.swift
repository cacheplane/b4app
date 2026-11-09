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

  /// A model keeps its choices in memory unless it is given somewhere to keep them, so no test
  /// reads or writes the test runner's `UserDefaults`; the apps pass `UserDefaults.standard`.
  @Test @MainActor func theModelKeepsPreferencesInMemoryUnlessGivenSome() {
    let model = WorkspaceModel(transportProvider: { throw CancellationError() })
    #expect(model.preferences is InMemoryPreferences)
    let other = WorkspaceModel(transportProvider: { throw CancellationError() })
    #expect(model.preferences !== other.preferences)

    let app = WorkspaceModel(
      transportProvider: { throw CancellationError() }, preferences: UserDefaults.standard)
    #expect(app.preferences === UserDefaults.standard)
  }
}
