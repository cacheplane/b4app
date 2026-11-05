import SwiftUI

/// The bottom of the iPhone's list (new-thread composer spec, "The iPhone"; mockup screen 1): the
/// account's notices, then a "New thread" field in the composer's line shape. The field is a doorway,
/// not an editor: a tap opens the new-thread screen, whose composer takes the text. Off while no
/// project's Mac can take a thread, with the reason in a line above it and as its hint: on a compact
/// width the new-thread screen, which would say why, cannot be reached.
struct NewThreadDock: View {
  @Bindable var model: WorkspaceModel

  static let placeholder = "New thread"

  var body: some View {
    let reason = model.newThreadEntryReason
    VStack(spacing: 0) {
      AccountNotices(model: model)
      if let reason { NoticeLine(reason, id: "new-thread-dock-reason") }
      Button {
        Task { await model.openNewThread() }
      } label: {
        DockField()
      }
      .buttonStyle(.plain)
      .disabled(reason != nil)
      .accessibilityLabel(Self.placeholder)
      .accessibilityHint(reason ?? "Opens a new thread")
      .accessibilityIdentifier("new-thread-dock")
      .padding(.horizontal, LLA.Space.m)
      .padding(.vertical, LLA.Space.s)
    }
    .background(LLA.Color.surface)
  }
}

/// `ComposerField`'s line, empty: the placeholder where the text starts, and the send circle, off.
/// Faded while the dock is off, as a sidebar row is.
private struct DockField: View {
  @Environment(\.isEnabled) private var isEnabled
  /// How far Dynamic Type has grown the composer's text; the line and the circle follow it, as in
  /// `ComposerField`.
  @ScaledMetric(relativeTo: .callout) private var growth: CGFloat = 1

  var body: some View {
    let scale = ComposerField<EmptyView>.scale(growth)
    let line = ComposerField<EmptyView>.line * scale
    let shape = RoundedRectangle(cornerRadius: line / 2, style: .circular)
    HStack(spacing: LLA.Space.s) {
      Text(NewThreadDock.placeholder)
        .font(LLAFont.composer)
        .foregroundStyle(LLA.Color.muted)
        .lineLimit(1)
      Spacer(minLength: 0)
      ComposerCircleStyle.face(
        Image(systemName: "arrow.up"), diameter: ComposerField<EmptyView>.control * scale,
        glyph: 15 * scale, enabled: false)
    }
    .opacity(isEnabled ? 1 : 0.45)
    .padding(.leading, ComposerField<EmptyView>.textLeading)
    .padding(.trailing, ComposerField<EmptyView>.inset * scale)
    .frame(minHeight: line)
    .background(shape.fill(LLA.Color.surface))
    .overlay(shape.strokeBorder(LLA.Color.rule))
    .contentShape(shape)
  }
}
