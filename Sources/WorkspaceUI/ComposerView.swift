import SwiftUI
import WorkspaceProtocol

/// Draft text, Send, and Stop. One active turn per thread; the draft is kept locally, never queued
/// into the provider (spec 3.3).
struct ComposerView: View {
  @Bindable var model: WorkspaceModel
  let detail: ThreadDetail

  private var activeTurn: Turn? { detail.activeTurn }
  private var canSend: Bool {
    activeTurn == nil && !model.busy
      && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error = model.lastError {
        HStack {
          Text(error).font(.callout).foregroundStyle(.red).lineLimit(3)
          Spacer()
          Button("Dismiss") { model.lastError = nil }.buttonStyle(.borderless).font(.caption)
        }
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
        if let turn = activeTurn, turn.status != .reconciling {
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
