import Testing

@testable import WorkspaceProtocol

@Suite struct ThreadTitleTests {
  @Test func cutsOnAWordBoundary() {
    #expect(
      ThreadTitle.fromFirstMessage(
        "Why does the relay drop after the Mac sleeps for more than an hour at night")
        == "Why does the relay drop after the Mac sleeps for more than…")
    #expect(ThreadTitle.fromFirstMessage("\n\n  hi  \nthere") == "hi")
  }

  @Test func keepsAShortLineAndCutsAnUnbrokenOne() {
    #expect(ThreadTitle.fromFirstMessage("Fix the login bug") == "Fix the login bug")
    let sixty = String(repeating: "a", count: 60)
    #expect(ThreadTitle.fromFirstMessage(sixty) == sixty)
    #expect(ThreadTitle.fromFirstMessage(sixty + "bc") == sixty + "…")
    // A space just past the limit is a word boundary at the limit.
    #expect(ThreadTitle.fromFirstMessage(sixty + " more") == sixty + "…")
  }
}
