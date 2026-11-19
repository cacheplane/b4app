import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// What a request card offers, decided without SwiftUI: the allow buttons a request's runtime will
/// apply, and a question's answer.
@Suite struct RequestChoicesTests {
  private func labels(_ payload: JSONValue) -> [String] {
    RequestChoices(payload: payload).choices.map(\.label)
  }

  @Test func aRequestWithNoWiderAllowOffersOnceAndDeny() {
    let choices = RequestChoices(payload: ["request": ["toolName": "Bash"]]).choices
    #expect(choices.map(\.label) == ["Allow once", "Deny"])
    #expect(choices.map(\.decision) == [.allowOnce, .deny])
    #expect(choices.map(\.identifier) == ["allow-once", "deny"])
  }

  @Test func aSessionScopeAddsAllowForSession() {
    let choices = RequestChoices(payload: ["request": ["allowScope": "session"]]).choices
    #expect(choices.map(\.label) == ["Allow once", "Allow for session", "Deny"])
    #expect(choices.map(\.decision) == [.allowOnce, .allowAlways, .deny])
    #expect(choices.map(\.identifier) == ["allow-once", "allow-wider", "deny"])
  }

  /// B4 keeps the grant past the session, and the button says so.
  @Test func anAlwaysScopeAddsAlwaysAllow() {
    #expect(labels(["request": ["allowScope": "always"]]) == ["Allow once", "Always allow", "Deny"])
  }

  /// Claude Code's session allow covers one rule, and the card says which.
  @Test func aSessionAllowWithARuleSaysWhatItCovers() {
    let rule = RequestChoices(payload: [
      "request": ["allowScope": "session", "allowRule": "Bash(touch one.txt)"]
    ])
    #expect(rule.reach == "Allow for session covers Bash(touch one.txt)")
    #expect(RequestChoices(payload: ["request": ["allowScope": "session"]]).reach == nil)
    #expect(RequestChoices(payload: ["request": ["allowRule": "Bash(ls)"]]).reach == nil)
  }

  @Test func aScopeThisBuildDoesNotKnowOffersNothingWider() {
    #expect(labels(["request": ["allowScope": "forever"]]) == ["Allow once", "Deny"])
  }

  @Test func aQuestionTakesSeveralAnswersOnlyWhenItSaysSoAndHasOptions() {
    let options: JSONValue = [["label": "red"], ["label": "blue"]]
    #expect(RequestChoices.isMultiSelect(["multiSelect": true, "options": options]))
    #expect(!RequestChoices.isMultiSelect(["multiSelect": false, "options": options]))
    #expect(!RequestChoices.isMultiSelect(["options": options]))
    // Nothing to tick: a text field, as any question with no options.
    #expect(!RequestChoices.isMultiSelect(["multiSelect": true, "options": []]))
  }

  @Test func severalAnswersGoInTheOrderTheQuestionListsThem() {
    let options = ["red", "green", "blue"]
    #expect(RequestChoices.answer(options: options, chosen: ["blue", "red"], other: "") == ["red", "blue"])
    #expect(
      RequestChoices.answer(options: options, chosen: ["green"], other: "  teal ") == ["green", "teal"])
    #expect(RequestChoices.answer(options: options, chosen: [], other: " ") == [])
    // A label the question does not list is not an answer to it.
    #expect(RequestChoices.answer(options: options, chosen: ["pink"], other: "") == [])
  }
}
