import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// What the environment form decides (D-212): the name a save sends, and the thread count under the heading.
@Suite struct EnvironmentFormTests {
  static let automatic = WorkEnvironment(
    id: "e1", folders: [EnvironmentFolder(id: "f1", environmentId: "e1", path: "/Users/me/repos/b4app")])
  static let named = WorkEnvironment(
    id: "e2", name: "Work", folders: [EnvironmentFolder(id: "f2", environmentId: "e2", path: "/Users/me/w")])

  @Test func theGeneratedNameLeftAsItIsSavesNothing() {
    #expect(Self.automatic.displayName == "b4app")
    #expect(EnvironmentCopy.nameToSave("b4app", for: Self.automatic) == nil)
    #expect(EnvironmentCopy.nameToSave("  b4app ", for: Self.automatic) == nil)
    #expect(EnvironmentCopy.nameToSave("", for: Self.automatic) == nil)
    #expect(EnvironmentCopy.nameToSave("App", for: Self.automatic) == "App")
  }

  @Test func aNamedEnvironmentSavesAChangeAndAnEmptyFieldRestoresTheFolderName() {
    #expect(EnvironmentCopy.nameToSave("Work", for: Self.named) == nil)
    #expect(EnvironmentCopy.nameToSave(" Work ", for: Self.named) == nil)
    #expect(EnvironmentCopy.nameToSave("Play", for: Self.named) == "Play")
    #expect(EnvironmentCopy.nameToSave("  ", for: Self.named) == "")
    // Typing the folder's own name over a chosen one is a change too.
    #expect(EnvironmentCopy.nameToSave("w", for: Self.named) == "w")
  }

  @Test func theThreadCountReadsAsWords() {
    #expect(EnvironmentCopy.threadCount(0) == "No threads")
    #expect(EnvironmentCopy.threadCount(1) == "1 thread")
    #expect(EnvironmentCopy.threadCount(4) == "4 threads")
    let threads = ["e1", "e1", "e2", nil].enumerated().map { index, environmentId in
      ConversationThread(
        id: "t\(index)", connectionId: "c", nativeThreadId: "n\(index)", environmentId: environmentId)
    }
    #expect(EnvironmentCopy.threadCount(in: "e1", threads: threads) == 2)
    #expect(EnvironmentCopy.threadCount(in: "e3", threads: threads) == 0)
  }
}
