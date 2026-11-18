import Foundation
import Testing

@testable import WorkspaceUI

/// Which links in a reply open, and what a filtered reply keeps.
@Suite struct LinkPolicyTests {
  @Test func onlyWebAndMailLinksOpen() {
    for good in ["https://example.com", "HTTP://example.com", "mailto:a@example.com"] {
      #expect(LinkPolicy.opens(URL(string: good)!))
    }
    for bad in ["javascript:alert(1)", "file:///etc/passwd", "b4app://x", "tel:123", "data:text/html,x"] {
      #expect(!LinkPolicy.opens(URL(string: bad)!))
    }
  }

  @Test func aLinkThatDoesNotOpenKeepsItsTextAndLosesItsLink() {
    let parsed = try! AttributedString(markdown: "[a](file:///x) [b](https://example.com)")
    let filtered = LinkPolicy.filtered(parsed)
    #expect(String(filtered.characters) == "a b")
    #expect(filtered.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com"])
  }

  /// Foundation reads `![alt](url)` as the alt text carrying an image URL; the filter drops the URL,
  /// so nothing is fetched or drawn but the words.
  @Test func anImageIsItsAltTextAndNothingIsLoaded() throws {
    let parsed = try AttributedString(
      markdown: "See ![a chart](https://example.com/chart.png) here.",
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    #expect(parsed.runs.contains { $0.imageURL != nil }, "Foundation's reading changed; revisit the filter")
    let filtered = LinkPolicy.filtered(parsed)
    #expect(String(filtered.characters) == "See a chart here.")
    #expect(filtered.runs.allSatisfy { $0.imageURL == nil && $0.link == nil })
  }
}
