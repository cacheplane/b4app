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
          HStack(spacing: LLA.Space.s) {
            Button("Allow once") { Task { await model.respond(requestId: request.id, decision: .allowOnce) } }
              .buttonStyle(.llaPrimary).accessibilityIdentifier("allow-once")
            Button("Allow for session") {
              Task { await model.respond(requestId: request.id, decision: .allowAlways) }
            }
            .buttonStyle(.llaSecondary)
            Button("Deny", role: .destructive) {
              Task { await model.respond(requestId: request.id, decision: .deny) }
            }
            .buttonStyle(.llaDanger)
            .accessibilityIdentifier("deny")
          }
          .padding(.top, LLA.Space.xs)
          .disabled(model.busy)
        } else {
          Text("This request type cannot be answered here and was declined automatically.").llaCaption()
        }
      }
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
        if !options.isEmpty {
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
      let payload = answers.filter { !$0.value.isEmpty }.mapValues { [$0] }
      Task { await model.answer(requestId: request.id, answers: payload) }
    }
    .buttonStyle(.llaPrimary)
    .disabled(model.busy || answers.values.allSatisfy(\.isEmpty))
  }

  private func binding(for id: String) -> Binding<String> {
    Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
  }
}
