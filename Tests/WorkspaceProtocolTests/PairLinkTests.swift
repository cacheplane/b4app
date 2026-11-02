import Foundation
import Testing
import WorkspaceProtocol

/// A pairing link comes from a QR code or from anywhere a link can be opened, so a hostile or
/// malformed one must never become a `PairLink` (Review Focus 4): nothing is offered, so nothing enrolls
/// and no request is sent.
@Suite struct PairLinkTests {
  private func link(_ text: String) throws -> URL { try #require(URL(string: text)) }

  private func parse(hub: String?, code: String?) throws -> PairLink? {
    var parts = URLComponents()
    parts.scheme = "b4app"
    parts.host = "pair"
    parts.queryItems = [
      hub.map { URLQueryItem(name: "hub", value: $0) }, code.map { URLQueryItem(name: "code", value: $0) },
    ].compactMap { $0 }
    return PairLink.parse(try #require(parts.url))
  }

  @Test func parsesAValidLink() throws {
    let parsed = try #require(
      PairLink.parse(try link("b4app://pair?hub=https%3A%2F%2FHub.Example.com%3A8443%2Fbase&code=K7M2Q9XP")))
    #expect(parsed.hub == URL(string: "https://hub.example.com:8443/base"))
    #expect(parsed.code == "K7M2Q9XP")
    #expect(parsed.host == "hub.example.com")
    // The code is case-insensitive; it is kept upper case, as the hub minted it.
    #expect(try parse(hub: "https://hub.example.com", code: "k7m2q9xp")?.code == "K7M2Q9XP")
    // The scheme and host of the link itself are case-insensitive too.
    #expect(PairLink.parse(try link("B4APP://PAIR?hub=https%3A%2F%2Fhub.example.com&code=BCDFGHJK")) != nil)
    #expect(PairLink.parse(try link("b4app://pair/?hub=https%3A%2F%2Fhub.example.com&code=BCDFGHJK")) != nil)
  }

  @Test func refusesMissingOrBadCode() throws {
    let hub = "https://hub.example.com"
    #expect(try parse(hub: hub, code: nil) == nil)
    #expect(try parse(hub: hub, code: "") == nil)
    #expect(try parse(hub: hub, code: "BCDFGHJ") == nil)  // 7
    #expect(try parse(hub: hub, code: "BCDFGHJKL") == nil)  // 9
    #expect(try parse(hub: hub, code: "BCDFGHJA") == nil)  // a vowel is not in the alphabet
    #expect(try parse(hub: hub, code: "BCDFGHJ0") == nil)  // nor 0 or 1
    #expect(try parse(hub: hub, code: "BCDFGHJ1") == nil)
    #expect(try parse(hub: hub, code: " BCDFGHJ") == nil)
    #expect(try parse(hub: hub, code: "BCDFGHJÉ") == nil)
    // Upper-casing can lengthen a string ("ß" → "SS", "ﬀ" → "FF"): seven characters must not pass as eight.
    #expect(try parse(hub: hub, code: "BCDFGHß") == nil)
    #expect(try parse(hub: hub, code: "BCDFGHﬀ") == nil)
    #expect(try parse(hub: hub, code: "bcdfghß") == nil)
    // Two codes are ambiguous, so neither is taken.
    #expect(
      PairLink.parse(try link("b4app://pair?hub=https%3A%2F%2Fhub.example.com&code=BCDFGHJK&code=MNPQRSTV"))
        == nil)
  }

  @Test func refusesInsecureRemoteHub() throws {
    let code = "BCDFGHJK"
    #expect(try parse(hub: nil, code: code) == nil)
    #expect(try parse(hub: "", code: code) == nil)
    #expect(try parse(hub: "not a url", code: code) == nil)
    #expect(try parse(hub: "http://hub.example.com", code: code) == nil)
    #expect(try parse(hub: "http://192.168.1.10:8080", code: code) == nil)
    #expect(try parse(hub: "http://localhost.evil.test", code: code) == nil)
    #expect(try parse(hub: "ftp://hub.example.com", code: code) == nil)
    #expect(try parse(hub: "javascript:alert(1)", code: code) == nil)
    // Credentials in the hub would go to it unseen behind the host the prompt names.
    #expect(try parse(hub: "https://user:secret@hub.example.com", code: code) == nil)
    // Two hubs are ambiguous, so neither is taken.
    #expect(
      PairLink.parse(
        try link("b4app://pair?hub=https%3A%2F%2Fa.example.com&hub=https%3A%2F%2Fb.example.com&code=BCDFGHJK")
      )
        == nil)
  }

  @Test func allowsLocalhostHttp() throws {
    let code = "BCDFGHJK"
    #expect(try parse(hub: "http://localhost:8080", code: code)?.hub == URL(string: "http://localhost:8080"))
    #expect(try parse(hub: "http://127.0.0.1:9", code: code)?.host == "127.0.0.1")
    #expect(try parse(hub: "http://[::1]:8080", code: code)?.host == "::1")
    #expect(try parse(hub: "HTTP://LOCALHOST:8080", code: code)?.hub == URL(string: "http://localhost:8080"))
  }

  @Test func refusesOtherHosts() throws {
    let query = "?hub=https%3A%2F%2Fhub.example.com&code=BCDFGHJK"
    for text in [
      "b4app://thread/abc\(query)", "b4app://pairing\(query)", "b4app://pair.evil.test\(query)",
      "https://pair\(query)", "b4apps://pair\(query)", "b4app://user@pair\(query)", "b4app://pair:80\(query)",
      "b4app://pair/extra\(query)", "b4app:pair\(query)",
    ] {
      #expect(PairLink.parse(try link(text)) == nil, "\(text)")
    }
    #expect(PairLink.isPairLink(try link("b4app://pair\(query)")))
    #expect(PairLink.isPairLink(try link("B4App://Pair")))
    #expect(!PairLink.isPairLink(try link("b4app://thread/abc")))
    #expect(!PairLink.isPairLink(try link("https://pair\(query)")))
  }

  @Test func roundTripsWithMake() throws {
    for (url, code) in [
      ("https://hub.example.com:8443/base?x=1&y=2#frag", "K7M2Q9XP"), ("http://localhost:8080", "BCDFGHJK"),
      ("https://hub.example.com", "ZXWV9876"),
    ] {
      let parsed = try #require(PairLink.parse(PairLink.make(url: url, code: code)))
      #expect(parsed == PairLink(hub: try HubURL.validate(url), code: code))
    }
  }
}
