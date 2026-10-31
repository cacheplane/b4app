import SwiftUI
import WorkspaceProtocol

/// Draft text, Send, and Stop. One active turn per thread; the draft is kept locally, never queued
/// into the provider (spec 3.3).
struct ComposerView: View {
  @Bindable var model: WorkspaceModel
  let detail: ThreadDetail

  private var activeTurn: Turn? { detail.activeTurn }
  private var canSend: Bool {
    activeTurn == nil && !model.busy && detail.thread.continuity == .available
      && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error = model.lastError {
        let remedy = model.remediation
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text(remedy?.message ?? error).font(.callout).foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
            if remedy != nil, let code = model.lastFailure?.code {
              Text(code.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
          }
          Spacer()
          if let remedy, let title = remedy.actionTitle, remedy.action != .none {
            Button(title) { Task { await model.perform(remedy.action) } }
              .buttonStyle(.bordered).font(.caption)
              .accessibilityIdentifier("remediation")
          }
          Button("Dismiss") { model.lastError = nil }.buttonStyle(.borderless).font(.caption)
        }
        .accessibilityIdentifier("error-banner")
      }
      TextEditor(text: $model.composerText)
        .font(.body)
        .frame(minHeight: 60, maxHeight: 160)
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("composer")
      HStack {
        Text(
          activeTurn == nil
            ? "Enter sends; Shift-Enter for a new line."
            : "A turn is \(activeTurn!.status.rawValue). Your draft stays here until it finishes."
        )
        .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if let turn = activeTurn, turn.status == .reconciling {
          Button("Check again", systemImage: "arrow.clockwise") {
            Task { await model.reconcileThread(id: detail.thread.id) }
          }
          .disabled(model.busy)
          .accessibilityIdentifier("check-again")
          Button("Abandon turn", systemImage: "xmark.circle", role: .destructive) {
            Task { await model.abandonTurn(threadId: detail.thread.id) }
          }
          .disabled(model.busy)
          .help(
            "Give up on this turn's unknown outcome so the thread can take a new message. Nothing is re-sent."
          )
          .accessibilityIdentifier("abandon")
        } else if let turn = activeTurn {
          Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
            .disabled(turn.nativeTurnId == nil || turn.status == .stopping)
            .accessibilityIdentifier("stop")
        }
        Button("Send", systemImage: "paperplane.fill") { Task { await model.send() } }
          .keyboardShortcut(.return, modifiers: [])
          .buttonStyle(.borderedProminent)
          .disabled(!canSend)
          .accessibilityIdentifier("send")
      }
    }
    .padding()
  }
}
