import Foundation
import WorkspaceProtocol

/// What a request card offers, decided without SwiftUI. A wider allow is drawn only where the
/// request's adapter said the runtime applies one, and it is named for how far it reaches: Codex
/// stops asking for the session, B4 keeps the grant itself (D-248). Both send `allow_always`.
struct RequestChoices: Equatable {
  struct Choice: Equatable, Identifiable {
    let decision: RuntimeDecision
    let label: String
    /// The button's accessibility identifier.
    let identifier: String
    var id: String { identifier }
  }

  let choices: [Choice]

  /// `payload` is a runtime request's payload.
  init(payload: JSONValue) {
    var choices = [Choice(decision: .allowOnce, label: "Allow once", identifier: "allow-once")]
    switch AllowScope(requestPayload: payload) {
    case .session:
      choices.append(Choice(decision: .allowAlways, label: "Allow for session", identifier: "allow-wider"))
    case .always:
      choices.append(Choice(decision: .allowAlways, label: "Always allow", identifier: "allow-wider"))
    case nil: break
    }
    choices.append(Choice(decision: .deny, label: "Deny", identifier: "deny"))
    self.choices = choices
  }

  /// Whether a question takes several of its options. One with no options is a text field either way.
  static func isMultiSelect(_ question: JSONValue) -> Bool {
    question["multiSelect"]?.boolValue == true && !(question["options"]?.arrayValue ?? []).isEmpty
  }

  /// A several-answer question's answer: the chosen labels in the order the question lists them, then
  /// what was typed, when anything was.
  static func answer(options: [String], chosen: Set<String>, other: String) -> [String] {
    let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
    return options.filter(chosen.contains) + (typed.isEmpty ? [] : [typed])
  }
}
