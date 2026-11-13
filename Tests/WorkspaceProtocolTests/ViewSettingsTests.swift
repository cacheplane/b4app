import Foundation
import Testing
import WorkspaceProtocol

@Suite struct ViewSettingsTests {
  private func decode(_ json: String) throws -> ViewSettings {
    try JSONCoding.decoder.decode(ViewSettings.self, from: Data(json.utf8))
  }

  @Test func defaultsWhenEverythingIsMissing() throws {
    let defaults = ViewSettings()
    #expect(defaults.arrangement == .needsYouFirst)
    #expect(defaults.quietThreads == .shown)
    #expect(defaults.density == .normal)
    #expect(defaults.showArchived == false)
    #expect(try decode("{}") == defaults)
    #expect(
      try decode(#"{"arrangement":null,"quietThreads":null,"showArchived":null,"density":null}"#) == defaults)
    #expect(ViewSettings.rowId == "view")
  }

  @Test func anUnknownValueReadsAsTheDefault() throws {
    #expect(try decode(#"{"quietThreads":"micro"}"#) == ViewSettings())
    // One unknown field does not cost the others their values.
    let mixed = try decode(#"{"arrangement":"byEnvironment","quietThreads":7,"showArchived":"yes"}"#)
    #expect(mixed == ViewSettings(arrangement: .byEnvironment))
    // And a known value round-trips.
    let set = ViewSettings(arrangement: .byEnvironment, quietThreads: .hidden, showArchived: true)
    #expect(try decode(String(decoding: try JSONCoding.encoder.encode(set), as: UTF8.self)) == set)
  }

  @Test func oldValuesReadAsDensityAndTheSidebarSetting() {
    func read(_ quiet: String?, _ density: String? = nil) -> ViewSettings {
      ViewSettings(arrangement: nil, quietThreads: quiet, showArchived: nil, density: density)
    }
    #expect(read("small") == ViewSettings())
    #expect(read("tiny") == ViewSettings(density: .dense))
    #expect(read("collapsed") == ViewSettings(quietThreads: .collapsed))
    #expect(read("hidden") == ViewSettings(quietThreads: .hidden))
    #expect(read("shown", "dense") == ViewSettings(density: .dense))
    // A stored density wins over what an old value implies.
    #expect(read("tiny", "normal") == ViewSettings())
    #expect(read(nil) == ViewSettings())
    #expect(read("nonsense", "nonsense") == ViewSettings())
  }

  @Test func onlyAnUnconvertedTinyImpliesDense() {
    #expect(ViewSettings.impliedDensity(storedQuietThreads: "tiny", storedDensity: nil) == .dense)
    #expect(ViewSettings.impliedDensity(storedQuietThreads: "tiny", storedDensity: "normal") == nil)
    #expect(ViewSettings.impliedDensity(storedQuietThreads: "small", storedDensity: nil) == nil)
    #expect(ViewSettings.impliedDensity(storedQuietThreads: "collapsed", storedDensity: nil) == nil)
    #expect(ViewSettings.impliedDensity(storedQuietThreads: nil, storedDensity: nil) == nil)
  }

  @Test func densityRoundTripsThroughJSON() throws {
    let settings = ViewSettings(quietThreads: .hidden, density: .dense)
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(ViewSettings.self, from: data) == settings)
    let old = Data(#"{"arrangement":"needsYouFirst","quietThreads":"tiny","showArchived":false}"#.utf8)
    #expect(try JSONDecoder().decode(ViewSettings.self, from: old) == ViewSettings(density: .dense))
  }
}
