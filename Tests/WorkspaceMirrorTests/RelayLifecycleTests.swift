import Foundation
import Testing
import WorkspaceMirror
import WorkspaceProtocol

/// The phone holds its hub link only while the app is active and enrolled; `MirrorHost` turns each
/// decision into `MirrorRelay.start()` or `stop()`.
@Suite struct RelayLifecycleTests {
  @Test func startsOnActiveStopsOnBackground() {
    var lifecycle = RelayLifecycle(enrolled: true)
    #expect(!lifecycle.running)
    // Launch passes through inactive; nothing opens until the app is active.
    #expect(lifecycle.enter(.inactive) == nil)
    #expect(lifecycle.enter(.active) == .start)
    #expect(lifecycle.running)
    #expect(lifecycle.enter(.active) == nil)
    // Inactive (the app switcher, a system sheet) keeps the link as it is.
    #expect(lifecycle.enter(.inactive) == nil)
    #expect(lifecycle.running)
    #expect(lifecycle.enter(.background) == .stop)
    #expect(!lifecycle.running)
    #expect(lifecycle.enter(.background) == nil)
    // Back through inactive: still closed until active.
    #expect(lifecycle.enter(.inactive) == nil)
    #expect(!lifecycle.running)
    #expect(lifecycle.enter(.active) == .start)
  }

  @Test func enrollingAndLeavingFollowThePhase() {
    var lifecycle = RelayLifecycle(enrolled: false)
    // Not enrolled: there is no link to hold.
    #expect(lifecycle.enter(.active) == nil)
    #expect(!lifecycle.running)
    // Pairing while active opens it at once.
    #expect(lifecycle.setEnrolled(true) == .start)
    #expect(lifecycle.setEnrolled(true) == nil)
    // Logging out closes it.
    #expect(lifecycle.setEnrolled(false) == .stop)
    #expect(!lifecycle.running)
    // Pairing while in the background waits for the next active.
    #expect(lifecycle.enter(.background) == nil)
    #expect(lifecycle.setEnrolled(true) == nil)
    #expect(lifecycle.enter(.active) == .start)
  }

  @Test func alreadyEnrolledIgnoresPairLink() throws {
    let url = PairLink.make(url: "https://hub.example.com", code: "BCDFGHJK")
    // Enrolled: whatever the link holds, nothing is offered.
    #expect(RelayLifecycle(enrolled: true).pairLink(url) == .alreadyPaired)
    let hostile = try #require(URL(string: "b4app://pair?hub=http%3A%2F%2Fevil.test&code=BCDFGHJK"))
    #expect(RelayLifecycle(enrolled: true).pairLink(hostile) == .alreadyPaired)
    // Not enrolled: a valid link is offered for confirmation, never enrolled here.
    let offered = try #require(PairLink.parse(url))
    #expect(RelayLifecycle(enrolled: false).pairLink(url) == .confirm(offered))
    #expect(RelayLifecycle(enrolled: false).pairLink(hostile) == .invalid)
    // Not a pairing link at all (a later `b4app://thread/<id>`): not this decision's.
    let thread = try #require(URL(string: "b4app://thread/abc"))
    #expect(RelayLifecycle(enrolled: false).pairLink(thread) == .ignored)
    #expect(RelayLifecycle(enrolled: true).pairLink(thread) == .ignored)
  }
}
