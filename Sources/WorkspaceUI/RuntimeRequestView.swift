import SwiftUI
import WorkspaceProtocol

struct RuntimeRequestList: View {
  @Bindable var model: WorkspaceModel
  let requests: [RuntimeRequest]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(requests) { request in
        RuntimeRequestCard(model: model, request: request)
      }
    }
    .padding()
    .background(Color.orange.opacity(0.08))
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
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: "hand.raised").font(.headline)
      if let toolName = details?["toolName"]?.stringValue {
        Text(toolName).font(.caption.bold()).foregroundStyle(.secondary)
      }
      if let command = details?["command"]?.stringValue {
        Text(command).font(.callout.monospaced()).textSelection(.enabled)
      } else if let path = details?["path"]?.stringValue {
        Text(path).font(.callout.monospaced()).textSelection(.enabled)
      }
      if let cwd = details?["cwd"]?.stringValue {
        Text("in \(cwd)").font(.caption).foregroundStyle(.secondary)
      }
      if let reason = details?["reason"]?.stringValue {
        Text(reason).font(.callout)
      }
      if request.kind == .userQuestion {
        questions
      } else if answerable {
        HStack {
          Button("Allow once") { Task { await model.respond(requestId: request.id, decision: .allowOnce) } }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("allow-once")
          Button("Allow for session") {
            Task { await model.respond(requestId: request.id, decision: .allowAlways) }
          }
          Button("Deny", role: .destructive) {
            Task { await model.respond(requestId: request.id, decision: .deny) }
          }
          .accessibilityIdentifier("deny")
        }
        .disabled(model.busy)
      } else {
        Text("This request type cannot be answered here and was declined automatically.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.5)))
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
      VStack(alignment: .leading, spacing: 4) {
        Text(question["header"]?.stringValue ?? id).font(.subheadline.bold())
        Text(question["question"]?.stringValue ?? "")
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
        }
        if options.isEmpty || question["isOther"]?.boolValue == true {
          if question["isSecret"]?.boolValue == true {
            SecureField("Answer", text: binding(for: id))
          } else {
            TextField("Answer", text: binding(for: id))
          }
        }
      }
    }
    Button("Submit answers") {
      let payload = answers.filter { !$0.value.isEmpty }.mapValues { [$0] }
      Task { await model.answer(requestId: request.id, answers: payload) }
    }
    .buttonStyle(.borderedProminent)
    .disabled(model.busy || answers.values.allSatisfy(\.isEmpty))
  }

  private func binding(for id: String) -> Binding<String> {
    Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
  }
}
