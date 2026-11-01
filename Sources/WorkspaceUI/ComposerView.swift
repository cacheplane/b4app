import SwiftUI
import WorkspaceProtocol

/// Draft text, Send, and Stop. One active turn per thread; the draft is kept locally, never queued
/// into the provider (spec 3.3).
struct ComposerView: View {
  @Bindable var model: WorkspaceModel
  let detail: ThreadDetail
  @State private var editorHeight: CGFloat = 24

  private var activeTurn: Turn? { detail.activeTurn }
  private var canSend: Bool {
    activeTurn == nil && !model.busy && detail.thread.continuity == .available
      && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.s) {
      if let error = model.lastError {
        let remedy = model.remediation
        LLACard(fill: .surface, padding: LLA.Space.m) {
          HStack(alignment: .top, spacing: LLA.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
              Text(remedy?.message ?? error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
              if remedy != nil, let code = model.lastFailure?.code {
                Text(code.rawValue).llaCodeMuted()
              }
            }
            Spacer()
            if let remedy, let title = remedy.actionTitle, remedy.action != .none {
              Button(title) { Task { await model.perform(remedy.action) } }
                .buttonStyle(.llaSecondary)
                .accessibilityIdentifier("remediation")
            }
            Button("Dismiss") { model.lastError = nil }.buttonStyle(.llaLink)
          }
        }
        .accessibilityIdentifier("error-banner")
      }
      VStack(alignment: .leading, spacing: 0) {
        // The editor grows with the draft: a hidden copy of the text sets the height, clamped.
        ZStack(alignment: .topLeading) {
          Text(model.composerText.isEmpty ? " " : model.composerText + " ")
            .font(LLAFont.body)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { editorHeight = $0 }
          TextEditor(text: $model.composerText)
            .font(LLAFont.body)
            .foregroundStyle(LLA.Color.ink)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("composer")
        }
        .frame(height: min(max(editorHeight + 6, 24), 160))
        .padding(.horizontal, LLA.Space.m)
        .padding(.top, LLA.Space.m)
        HStack(spacing: LLA.Space.s) {
          Text(
            activeTurn == nil
              ? "Enter sends; Shift-Enter for a new line."
              : "A turn is \(activeTurn!.status.rawValue). Your draft stays here until it finishes."
          )
          .llaCaption().lineLimit(2)
          Spacer()
          if let turn = activeTurn, turn.status == .reconciling {
            Button("Check again") { Task { await model.reconcileThread(id: detail.thread.id) } }
              .buttonStyle(.llaSecondary)
              .disabled(model.busy)
              .accessibilityIdentifier("check-again")
            Button("Abandon turn", role: .destructive) {
              Task { await model.abandonTurn(threadId: detail.thread.id) }
            }
            .buttonStyle(.llaDanger)
            .disabled(model.busy)
            .help(
              "Give up on this turn's unknown outcome so the thread can take a new message. Nothing is re-sent."
            )
            .accessibilityIdentifier("abandon")
          } else if let turn = activeTurn {
            Button("Stop") { Task { await model.stop() } }
              .buttonStyle(.llaSecondary)
              .disabled(turn.nativeTurnId == nil || turn.status == .stopping)
              .accessibilityIdentifier("stop")
          }
          Button("Send") { Task { await model.send() } }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.llaPrimary)
            .disabled(!canSend)
            .accessibilityIdentifier("send")
        }
        .padding(.horizontal, LLA.Space.m)
        .padding(.vertical, LLA.Space.s)
      }
      .background(RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).fill(LLA.Color.surface))
      .overlay(
        RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).stroke(
          LLA.Color.rule, lineWidth: 1))
    }
    .padding(.horizontal, LLA.Space.xl)
    .padding(.vertical, LLA.Space.l)
    .frame(maxWidth: LLA.Metrics.column)
    .frame(maxWidth: .infinity)
  }
}
