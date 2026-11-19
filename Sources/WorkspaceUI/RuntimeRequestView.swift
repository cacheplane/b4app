import SwiftUI
import WorkspaceProtocol

/// The pending requests between the transcript and the composer. The list sizes to its cards up
/// to `LLA.Metrics.requestsMaxHeight` and scrolls past that: a card's texts wrap with
/// `fixedSize(vertical:)`, and outside a scroll view that made the detail's minimum height grow
/// with the command's length, which on macOS 26 blanked the whole `NavigationSplitView` once it
/// exceeded the window (D-047). Inside the scroll view the measurement stays bounded.
struct RuntimeRequestList: View {
  @Bindable var model: WorkspaceModel
  let requests: [RuntimeRequest]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        ForEach(requests) { request in
          RuntimeRequestCard(model: model, request: request)
        }
      }
      .padding(.horizontal, LLA.Metrics.margin)
      .padding(.vertical, LLA.Space.l)
      .frame(maxWidth: LLA.Metrics.column)
      .frame(maxWidth: .infinity)
    }
    .frame(maxHeight: LLA.Metrics.requestsMaxHeight)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier("runtime-requests")
  }
}

/// One pending request. Only the current pending request can be answered; the coordinator races
/// duplicate clicks through a single transition.
struct RuntimeRequestCard: View {
  @Bindable var model: WorkspaceModel
  let request: RuntimeRequest
  @State private var answers: [String: String] = [:]
  /// The options ticked in each question that takes several, by question id.
  @State private var chosen: [String: Set<String>] = [:]

  private var details: JSONValue? { request.payload["request"] }
  private var answerable: Bool { request.payload["answerable"]?.boolValue ?? false }

  var body: some View {
    LLACard(fill: .surface) {
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        HStack(spacing: LLA.Space.s) {
          LLAStateDot(state: .waiting)
          Text(title).font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
        }
        if let toolName = details?["toolName"]?.stringValue {
          Text(toolName).llaCaption()
        }
        if let command = details?["command"]?.stringValue {
          Text(command).llaCode().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else if let path = details?["path"]?.stringValue {
          Text(path).llaCode().textSelection(.enabled)
        }
        if let cwd = details?["cwd"]?.stringValue {
          Text("in \(cwd)").llaCaption()
        }
        if let reason = details?["reason"]?.stringValue {
          Text(reason).llaSmall().fixedSize(horizontal: false, vertical: true)
        }
        if request.kind == .userQuestion {
          questions
        } else if answerable {
          if let reach = RequestChoices(payload: request.payload).reach {
            Text(reach).llaCaption().fixedSize(horizontal: false, vertical: true)
          }
          HStack(spacing: LLA.Space.s) {
            ForEach(RequestChoices(payload: request.payload).choices) { choice in
              choiceButton(choice)
            }
          }
          .padding(.top, LLA.Space.xs)
          .disabled(!model.canAnswer(request))
          answerState
        } else {
          Text("This request type cannot be answered here and was declined automatically.").llaCaption()
        }
      }
    }
  }

  /// One of the request's choices: only those its runtime applies are drawn (`RequestChoices`).
  @ViewBuilder private func choiceButton(_ choice: RequestChoices.Choice) -> some View {
    let send = { Task { await model.respond(requestId: request.id, decision: choice.decision) } }
    switch choice.decision {
    case .allowOnce:
      Button(choice.label) { _ = send() }
        .buttonStyle(.llaPrimary).accessibilityIdentifier(choice.identifier)
    case .allowAlways:
      Button(choice.label) { _ = send() }
        .buttonStyle(.llaSecondary).accessibilityIdentifier(choice.identifier)
    case .deny:
      Button(choice.label, role: .destructive) { _ = send() }
        .buttonStyle(.llaDanger).accessibilityIdentifier(choice.identifier)
    }
  }

  private var title: String {
    switch request.kind {
    case .commandApproval: return "The agent wants to run a command"
    case .fileChangeApproval: return "The agent wants to change files"
    case .userQuestion: return "The agent has a question"
    case .toolPermission: return "The agent wants to use a tool"
    case .elicitation: return "An MCP server asked for input"
    case .unknown: return "Unsupported runtime request"
    }
  }

  @ViewBuilder private var questions: some View {
    let list = details?["questions"]?.arrayValue ?? []
    ForEach(Array(list.enumerated()), id: \.offset) { _, question in
      let id = question["id"]?.stringValue ?? ""
      VStack(alignment: .leading, spacing: LLA.Space.xs) {
        Text(question["header"]?.stringValue ?? id).font(LLAFont.smallStrong).foregroundStyle(LLA.Color.ink)
        Text(question["question"]?.stringValue ?? "").llaSmall().fixedSize(horizontal: false, vertical: true)
        let options = question["options"]?.arrayValue ?? []
        if RequestChoices.isMultiSelect(question) {
          ForEach(Array(options.enumerated()), id: \.offset) { _, option in
            let label = option["label"]?.stringValue ?? ""
            Toggle(label, isOn: ticked(label, in: id))
              .font(LLAFont.small)
              #if os(macOS)
                .toggleStyle(.checkbox)
              #endif
          }
        } else if !options.isEmpty {
          Picker("Answer", selection: binding(for: id)) {
            Text("Choose…").tag("")
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
              let label = option["label"]?.stringValue ?? ""
              Text(label).tag(label)
            }
          }
          .labelsHidden()
          .font(LLAFont.small)
        }
        if options.isEmpty || question["isOther"]?.boolValue == true {
          LLAField("Answer", text: binding(for: id), secure: question["isSecret"]?.boolValue == true)
        }
      }
    }
    Button("Submit answers") {
      let payload = answerPayload(list)
      Task { await model.answer(requestId: request.id, answers: payload) }
    }
    .buttonStyle(.llaPrimary)
    .disabled(!model.canAnswer(request) || answerPayload(list).isEmpty)
    answerState
  }

  /// The phone's answer: "Waiting for your Mac…", then "Not confirmed: …" or the reason. The buttons
  /// stay while the request is still pending; sync resolves the card.
  @ViewBuilder private var answerState: some View {
    if let state = model.answerStates[request.id] {
      HStack(spacing: LLA.Space.xs) {
        if state == .waiting { ProgressView().controlSize(.mini).accessibilityHidden(true) }
        Text(state.label)
          .font(LLAFont.caption)
          .foregroundStyle(
            state == .waiting ? LLA.Color.muted : LLA.Color.danger
          )
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("answer-state")
    }
  }

  /// Each answered question's answers: one for a question that takes one, the ticked options (and
  /// anything typed) for a question that takes several.
  private func answerPayload(_ questions: [JSONValue]) -> [String: [String]] {
    var payload = answers.filter { !$0.value.isEmpty }.mapValues { [$0] }
    for question in questions where RequestChoices.isMultiSelect(question) {
      let id = question["id"]?.stringValue ?? ""
      let options = (question["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }
      let answer = RequestChoices.answer(options: options, chosen: chosen[id] ?? [], other: answers[id] ?? "")
      payload[id] = answer.isEmpty ? nil : answer
    }
    return payload
  }

  private func ticked(_ label: String, in id: String) -> Binding<Bool> {
    Binding(
      get: { chosen[id]?.contains(label) ?? false },
      set: { on in
        if on { chosen[id, default: []].insert(label) } else { chosen[id]?.remove(label) }
      })
  }

  private func binding(for id: String) -> Binding<String> {
    Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
  }
}
