import Foundation
import Testing

@testable import WorkspaceProtocol

/// `<scheme>://thread/<id>` links and the hub's push payload (`Tests/Fixtures/sync/push.json`, read in
/// place as `AttentionTests` reads `attention.json`; the hub's Rust tests build the same payloads).
struct ThreadLinkTests {
  private func link(_ text: String) throws -> URL { try #require(URL(string: text)) }

  @Test func buildsAThreadLinkWithTheIdAsOneEncodedSegment() {
    #expect(ThreadLink.url(threadId: "thread-1", scheme: "b4app").absoluteString == "b4app://thread/thread-1")
    #expect(
      ThreadLink.url(threadId: "a/b c?d#e%f", scheme: "b4app-dev").absoluteString
        == "b4app-dev://thread/a%2Fb%20c%3Fd%23e%25f")
  }

  @Test func roundTripsIdsThatNeedEscaping() {
    for id in [
      "thread-1", "a/b", "with space", "q?x=1", "frag#ment", "100%", "é ü/日本", "~._-", "%2F", "a%20b",
    ] {
      let url = ThreadLink.url(threadId: id, scheme: "b4app")
      #expect(ThreadLink.threadId(from: url, scheme: "b4app") == id, "\(id)")
    }
  }

  @Test func schemeAndHostAreCaseInsensitive() throws {
    #expect(ThreadLink.threadId(from: try link("B4APP://THREAD/abc"), scheme: "b4app") == "abc")
    #expect(ThreadLink.threadId(from: try link("b4app://thread/abc"), scheme: "B4App") == "abc")
  }

  @Test func refusesAnotherSchemeOrHost() throws {
    #expect(ThreadLink.threadId(from: try link("other://thread/abc"), scheme: "b4app") == nil)
    #expect(ThreadLink.threadId(from: try link("b4app://threads/abc"), scheme: "b4app") == nil)
    #expect(ThreadLink.threadId(from: try link("b4app://pair/abc"), scheme: "b4app") == nil)
    #expect(ThreadLink.threadId(from: try link("https://thread/abc"), scheme: "b4app") == nil)
  }

  @Test func refusesAnEmptyOrMultiSegmentPath() throws {
    for text in [
      "b4app://thread", "b4app://thread/", "b4app://thread//", "b4app://thread/a/b", "b4app://thread/abc/",
    ] {
      #expect(ThreadLink.threadId(from: try link(text), scheme: "b4app") == nil, "\(text)")
    }
  }

  @Test func refusesAQueryUserPortOrFragment() throws {
    for text in [
      "b4app://thread/abc?x=1", "b4app://thread/abc?", "b4app://user@thread/abc",
      "b4app://user:pw@thread/abc", "b4app://thread:80/abc", "b4app://thread/abc#frag", "b4app://thread/abc#",
    ] {
      #expect(ThreadLink.threadId(from: try link(text), scheme: "b4app") == nil, "\(text)")
    }
  }

  @Test func aPairLinkIsNotAThreadLink() throws {
    let pair = try link("b4app://pair?hub=https%3A%2F%2Fhub.example&code=ABCDEFGH")
    #expect(ThreadLink.threadId(from: pair, scheme: "b4app") == nil)
    #expect(!PairLink.isPairLink(ThreadLink.url(threadId: "abc", scheme: "b4app")))
  }

  @Test func readsTheThreadIdFromANotificationAndNothingElse() {
    #expect(ThreadLink.threadId(fromNotification: ["threadId": "t-1"]) == "t-1")
    #expect(ThreadLink.threadId(fromNotification: [:]) == nil)
    #expect(ThreadLink.threadId(fromNotification: ["threadId": ""]) == nil)
    #expect(ThreadLink.threadId(fromNotification: ["threadId": 7]) == nil)
    #expect(ThreadLink.threadId(fromNotification: ["aps": ["thread-id": "t-1"]]) == nil)
  }

  @Test func readsTheReasonFromANotification() {
    #expect(ThreadLink.reason(fromNotification: ["reason": "approval"]) == .approval)
    #expect(ThreadLink.reason(fromNotification: ["reason": "question"]) == .question)
    #expect(ThreadLink.reason(fromNotification: ["reason": "replied"]) == .replied)
    #expect(ThreadLink.reason(fromNotification: ["reason": "failed"]) == .failed)
    #expect(ThreadLink.reason(fromNotification: ["reason": "other"]) == nil)
    #expect(ThreadLink.reason(fromNotification: ["reason": 1]) == nil)
    #expect(ThreadLink.reason(fromNotification: [:]) == nil)
  }

  @Test func everyPayloadInTheFixtureYieldsItsThreadIdAndReason() throws {
    let url = URL(fileURLWithPath: "\(#filePath)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/push.json")
    let document = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let payloads = try #require(document["payloads"] as? [[String: Any]])
    #expect(!payloads.isEmpty)
    for entry in payloads {
      // What iOS hands a notification delegate: the payload as an untyped dictionary.
      let userInfo = try #require(entry["expected"] as? [AnyHashable: Any])
      #expect(ThreadLink.threadId(fromNotification: userInfo) == entry["threadId"] as? String)
      #expect(ThreadLink.reason(fromNotification: userInfo)?.rawValue == entry["reason"] as? String)
    }
  }

  @Test func readsTheKeyFromANotification() {
    #expect(ThreadLink.key(fromNotification: ["key": "request:r-1"]) == "request:r-1")
    #expect(ThreadLink.key(fromNotification: ["key": "turn:u-1"]) == "turn:u-1")
    #expect(ThreadLink.key(fromNotification: [:]) == nil)
    #expect(ThreadLink.key(fromNotification: ["key": ""]) == nil)
    #expect(ThreadLink.key(fromNotification: ["key": 3]) == nil)
  }

  @Test func readsTheWithdrawnKeysFromANotification() {
    #expect(
      ThreadLink.withdrawKeys(fromNotification: ["withdraw": ["request:a", "turn:b"]]) == [
        "request:a", "turn:b",
      ])
    #expect(
      ThreadLink.withdrawKeys(fromNotification: ["withdraw": ["request:a", 4, "turn:b"] as [Any]]) == [
        "request:a", "turn:b",
      ])
    #expect(ThreadLink.withdrawKeys(fromNotification: [:]).isEmpty)
    #expect(ThreadLink.withdrawKeys(fromNotification: ["withdraw": "request:a"]).isEmpty)
  }

  @Test func everyFixtureEntryYieldsItsKeysInOrder() throws {
    let url = URL(fileURLWithPath: "\(#filePath)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/push.json")
    let document = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let payloads = try #require(document["payloads"] as? [[String: Any]])
    for entry in payloads {
      let userInfo = try #require(entry["expected"] as? [AnyHashable: Any])
      #expect(ThreadLink.key(fromNotification: userInfo) == entry["key"] as? String)
      #expect(ThreadLink.key(fromNotification: userInfo) != nil)
      #expect(ThreadLink.withdrawKeys(fromNotification: userInfo).isEmpty)
    }
    let withdrawals = try #require(document["withdrawals"] as? [[String: Any]])
    #expect(!withdrawals.isEmpty)
    for entry in withdrawals {
      let userInfo = try #require(entry["expected"] as? [AnyHashable: Any])
      #expect(ThreadLink.withdrawKeys(fromNotification: userInfo) == entry["keys"] as? [String])
      #expect(ThreadLink.key(fromNotification: userInfo) == nil)
    }
  }
}
