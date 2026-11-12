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
    #expect(defaults.quietThreads == .small)
    #expect(defaults.showArchived == false)
    #expect(try decode("{}") == defaults)
    #expect(try decode(#"{"arrangement":null,"quietThreads":null,"showArchived":null}"#) == defaults)
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

  @Test func tinyShowsAsCollapsedOnThePhoneOnly() {
    let tiny = ViewSettings(quietThreads: .tiny)
    #expect(tiny.shown(on: .phone).quietThreads == .collapsed)
    #expect(tiny.shown(on: .mac).quietThreads == .tiny)
    for quiet in ViewSettings.QuietThreads.allCases where quiet != .tiny {
      #expect(ViewSettings(quietThreads: quiet).shown(on: .phone).quietThreads == quiet)
      #expect(ViewSettings(quietThreads: quiet).shown(on: .mac).quietThreads == quiet)
    }
  }

  @Test func shownNeverChangesTheOtherFields() {
    for arrangement in ViewSettings.Arrangement.allCases {
      for quiet in ViewSettings.QuietThreads.allCases {
        for archived in [false, true] {
          let stored = ViewSettings(arrangement: arrangement, quietThreads: quiet, showArchived: archived)
          for device in [ViewSettings.Device.mac, .phone] {
            let shown = stored.shown(on: device)
            #expect(shown.arrangement == arrangement)
            #expect(shown.showArchived == archived)
          }
        }
      }
    }
  }
}
