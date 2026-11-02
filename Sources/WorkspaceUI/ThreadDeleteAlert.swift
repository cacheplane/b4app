import SwiftUI
import WorkspaceProtocol

extension View {
  /// The delete confirmation (deleting threads), shown while `thread` is set: the thread's title, what
  /// is removed and from where, and no undo. Delete is the destructive button; Cancel keeps it.
  func deleteThreadAlert(model: WorkspaceModel, thread: Binding<ConversationThread?>) -> some View {
    let copy = thread.wrappedValue.map { model.deleteConfirmation(for: $0) }
    return alert(
      copy?.title ?? "",
      isPresented: Binding(
        get: { thread.wrappedValue != nil }, set: { if !$0 { thread.wrappedValue = nil } }),
      presenting: thread.wrappedValue
    ) { target in
      Button("Delete", role: .destructive) { Task { await model.deleteThread(id: target.id) } }
        .accessibilityIdentifier("confirm-delete")
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(copy?.message ?? "")
    }
  }
}
