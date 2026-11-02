import Foundation
import NIOTransport
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator

private let fakeCodex =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("CodexAdapterTests/Fixtures/fake-codex.py").path

/// A coordinator over a scratch store with the fake Codex runtime, and scratch folders to work in.
private struct ProjectHarness {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let events: EventCollector
  let base: String
  var db: WorkspaceDatabase { coordinator.database }

  static func start(paths existing: PlatformPaths? = nil) async throws -> ProjectHarness {
    let base: String
    let paths: PlatformPaths
    if let existing {
      paths = existing
      base = (existing.runtimeDir as NSString).deletingLastPathComponent
    } else {
      base = NSTemporaryDirectory() + "b4p-\(UUID().uuidString.prefix(8))"
      try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
      paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    }
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    env["ANTHROPIC_API_KEY"] = nil
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(paths: paths, environment: env, secretStore: MemorySecretStore()))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    return ProjectHarness(
      coordinator: coordinator, client: client, events: EventCollector(await client.events()), base: base)
  }

  func mutation() -> RequestOptions { RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)) }

  /// A scratch folder; returns its path as written (not canonical: temp dirs live behind a symlink).
  func folder(_ name: String) throws -> String {
    let path = base + "/" + name
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  func addCodex() async throws -> Connection {
    try await client.request(
      ConnectionAdd.self, ConnectionAdd.Params(kind: .codex, label: "Fake Codex", executablePath: fakeCodex),
      options: mutation()
    ).connection
  }

  func newThread(_ connection: Connection, in directory: String) async throws -> ConversationThread {
    try await client.request(
      ThreadCreate.self, ThreadCreate.Params(connectionId: connection.id, workingDirectory: directory),
      options: mutation()
    ).thread
  }

  func projects() async throws -> [Project] {
    try await client.request(ProjectList.self, EmptyParams()).projects
  }

  func create(_ name: String, _ folders: [String]) async throws -> Project {
    try await client.request(
      ProjectCreate.self, ProjectCreate.Params(name: name, folders: folders), options: mutation()
    ).project
  }

  func failure(_ body: () async throws -> some Sendable) async -> WorkspaceError? {
    do {
      _ = try await body()
      return nil
    } catch { return WorkspaceError.from(error) }
  }

  /// Every `project.changed` published so far, as project ids.
  func projectEvents() async -> [String] { Self.projectIds(await events.events.map(\.event)) }

  /// Waits, event by event, until `condition` holds of `projectEvents()` (events reach the client after
  /// the request returns), then returns them; fails the test at the deadline with what arrived.
  func projectEvents(
    until condition: @Sendable ([String]) -> Bool, sourceLocation: SourceLocation = #_sourceLocation
  ) async -> [String] {
    _ = await events.until { condition(Self.projectIds($0)) }
    let seen = await projectEvents()
    #expect(condition(seen), "project.changed events seen: \(seen)", sourceLocation: sourceLocation)
    return seen
  }

  /// This thread's `thread.updated` events so far, in the order they were published.
  func threadUpdates(_ threadId: String) async -> [AdapterEvent] {
    Self.threadUpdates(threadId, in: await events.events.map(\.event))
  }

  /// Waits, event by event, until `condition` holds of `threadUpdates(_:)`, then returns them; fails
  /// the test at the deadline with how many arrived.
  func threadUpdates(
    _ threadId: String, until condition: @Sendable ([AdapterEvent]) -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> [AdapterEvent] {
    _ = await events.until { condition(Self.threadUpdates(threadId, in: $0)) }
    let seen = await threadUpdates(threadId)
    #expect(condition(seen), "thread.updated events seen: \(seen.count)", sourceLocation: sourceLocation)
    return seen
  }

  private static func projectIds(_ events: [AdapterEvent]) -> [String] {
    events.filter { $0.kind == .projectChanged }.compactMap { $0.payload["projectId"]?.stringValue }
  }

  private static func threadUpdates(_ threadId: String, in events: [AdapterEvent]) -> [AdapterEvent] {
    events.filter { $0.kind == .threadUpdated && $0.threadId == threadId }
  }

  func close() async {
    await client.close()
    await coordinator.close()
  }
}

@Suite(.serialized) struct ProjectServiceTests {
  @Test func newThreadsShareAProjectAcrossSpellings() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    _ = try h.folder("x")
    try FileManager.default.createSymbolicLink(atPath: h.base + "/link", withDestinationPath: app)

    let spellings = [app, app + "/", h.base + "/link", h.base + "/x/../app"]
    var threads: [ConversationThread] = []
    for spelling in spellings { threads.append(try await h.newThread(connection, in: spelling)) }

    let projects = try await h.projects()
    #expect(projects.count == 1)
    let project = try #require(projects.first)
    #expect(project.displayName == "app")
    #expect(!project.manual && project.name.isEmpty)
    #expect(project.folders.map(\.path) == [SessionService.canonicalDirectory(app)])
    for (thread, spelling) in zip(threads, spellings) {
      #expect(thread.projectId == project.id)
      // The raw spelling is stored as given (tilde expanded); only the lookup is canonical.
      let stored = try #require(try h.db.thread(id: thread.id))
      #expect(stored.context == (spelling as NSString).expandingTildeInPath)
      #expect(stored.projectId == project.id)
    }
    // Only the first thread created a project, so viewers heard of it once. The last thread's event
    // comes after every project event, so waiting for it settles the count.
    let last = threads[3].id
    try await h.events.waitFor { $0.kind == .threadUpdated && $0.threadId == last }
    #expect(await h.projectEvents(until: { !$0.isEmpty }) == [project.id])
  }

  @Test func backfillHandlesAMissingFolder() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let codex = try await h.db.insertConnection(
      Connection(id: "c-codex", kind: .codex, label: "Codex", target: fakeCodex))
    let remote = try h.db.insertConnection(
      Connection(
        id: "c-remote", kind: .b4, label: "Remote", target: "https://b4.example.com", routeKey: "/chat#agent",
        b4Mode: .remote))
    let gone = h.base + "/deleted/gone"  // never created
    let here = try h.folder("here")
    func thread(_ id: String, _ connection: Connection, _ context: String?) throws {
      _ = try h.db.insertThread(
        ConversationThread(
          id: id, connectionId: connection.id, nativeThreadId: "n-\(id)", title: id, context: context))
    }
    try thread("t-gone", codex, gone)
    try thread("t-gone2", codex, gone + "/")
    try thread("t-here", codex, here)
    try thread("t-remote", remote, "/chat#agent")
    try thread("t-nofolder", codex, nil)

    let assigned = try await h.coordinator.projects.backfill()
    #expect(assigned == 3)
    let projects = try h.db.listProjects()
    #expect(projects.map(\.displayName).sorted() == ["gone", "here"])
    let goneProject = try #require(projects.first { $0.displayName == "gone" })
    #expect(try h.db.thread(id: "t-gone")?.projectId == goneProject.id)
    #expect(try h.db.thread(id: "t-gone2")?.projectId == goneProject.id)
    #expect(try h.db.thread(id: "t-here")?.projectId != nil)
    // Remote B4 and folderless threads stay unassigned.
    #expect(try h.db.thread(id: "t-remote")?.projectId == nil)
    #expect(try h.db.thread(id: "t-nofolder")?.projectId == nil)
    // `context` is never rewritten.
    #expect(try h.db.thread(id: "t-gone2")?.context == gone + "/")
    // Idempotent: nothing left to assign, and no second project for the same folder.
    #expect(try await h.coordinator.projects.backfill() == 0)
    #expect(try h.db.listProjects().count == 2)
  }

  @Test func backfillRunsOnceAtStartAfterMigrations() async throws {
    let first = try await ProjectHarness.start()
    let base = first.base
    let connection = try first.db.insertConnection(
      Connection(id: "c1", kind: .codex, label: "Codex", target: fakeCodex))
    let app = try first.folder("legacy")
    _ = try first.db.insertThread(
      ConversationThread(id: "old", connectionId: connection.id, nativeThreadId: "n", context: app))
    let paths = first.coordinator.paths
    await first.close()

    let second = try await ProjectHarness.start(paths: paths)
    defer { Task { await second.close() } }
    #expect(second.base == base)
    let project = try #require(try second.db.listProjects().first)
    #expect(project.displayName == "legacy")
    #expect(try second.db.thread(id: "old")?.projectId == project.id)
  }

  @Test func movingAFolderIntoAManualProjectMovesItsThreads() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let thread = try await h.newThread(connection, in: app)
    let automatic = try #require(thread.projectId)

    let manual = try await h.create("Site", [app + "/"])
    #expect(manual.manual && manual.name == "Site")
    #expect(manual.folders.map(\.path) == [SessionService.canonicalDirectory(app)])
    #expect(try h.db.thread(id: thread.id)?.projectId == manual.id)
    // The automatic project was left empty and is gone.
    #expect(try await h.projects().map(\.id) == [manual.id])
    // The automatic project is announced when created and again when it is emptied and deleted.
    let changed = await h.projectEvents(until: {
      $0.contains(manual.id) && $0.filter { $0 == automatic }.count == 2
    })
    #expect(changed.filter { $0 == automatic }.count == 2)
    let updated = try await h.events.waitFor {
      $0.kind == .threadUpdated && $0.threadId == thread.id
        && $0.payload["thread"]?["projectId"]?.stringValue == manual.id
    }
    #expect(updated.threadId == thread.id)

    // A new thread in the same folder joins the manual project instead of making an automatic one.
    let later = try await h.newThread(connection, in: app)
    #expect(later.projectId == manual.id)
    #expect(try await h.projects().count == 1)
  }

  @Test func updateValidatesEveryFolderBeforeChangingAnything() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let a = try h.folder("a")
    let b = try h.folder("b")
    let project = try await h.create("Mine", [a])
    let other = try await h.create("Other", [b])
    let missing = h.base + "/nowhere"

    // Adding a folder that does not exist names it and changes nothing, even the rename.
    let notThere = await h.failure {
      try await h.client.request(
        ProjectUpdate.self,
        ProjectUpdate.Params(projectId: project.id, name: "Renamed", addFolders: [a, missing]),
        options: h.mutation())
    }
    #expect(notThere?.code == .protocolInvalid)
    #expect(notThere?.message.contains(missing) == true)
    // Another manual project's folder is refused too.
    let owned = await h.failure {
      try await h.client.request(
        ProjectUpdate.self, ProjectUpdate.Params(projectId: project.id, addFolders: [b]),
        options: h.mutation())
    }
    #expect(owned?.code == .protocolInvalid)
    #expect(owned?.message.contains(b) == true)
    // Removing a folder the project does not have names it.
    let notInProject = await h.failure {
      try await h.client.request(
        ProjectUpdate.self, ProjectUpdate.Params(projectId: project.id, removeFolders: [missing]),
        options: h.mutation())
    }
    #expect(notInProject?.code == .protocolInvalid)
    #expect(notInProject?.message.contains(missing) == true)
    let unknown = await h.failure {
      try await h.client.request(
        ProjectUpdate.self, ProjectUpdate.Params(projectId: "nope", name: "x"), options: h.mutation())
    }
    #expect(unknown?.code == .notFound)
    let now = try await h.projects()
    #expect(now.first { $0.id == project.id }?.name == "Mine")
    #expect(now.first { $0.id == project.id }?.folders.count == 1)
    #expect(now.first { $0.id == other.id }?.folders.count == 1)
  }

  @Test func addingAFolderToAnAutomaticProjectMakesItManualAndMovesTheThreads() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let a = try h.folder("a")
    let b = try h.folder("b")
    let inA = try await h.newThread(connection, in: a)
    let inB = try await h.newThread(connection, in: b)
    let projectA = try #require(inA.projectId)
    let projectB = try #require(inB.projectId)

    let result = try await h.client.request(
      ProjectUpdate.self, ProjectUpdate.Params(projectId: projectA, name: "Both", addFolders: [b]),
      options: h.mutation()
    ).project
    #expect(result.manual && result.name == "Both")
    #expect(
      result.folders.map(\.path) == [
        SessionService.canonicalDirectory(a), SessionService.canonicalDirectory(b),
      ])
    #expect(try h.db.thread(id: inB.id)?.projectId == projectA)
    #expect(try await h.projects().map(\.id) == [projectA])
    _ = await h.projectEvents(until: { $0.contains(projectB) })
    try await h.events.waitFor {
      $0.kind == .threadUpdated && $0.threadId == inB.id
        && $0.payload["thread"]?["projectId"]?.stringValue == projectA
    }
  }

  @Test func removingAFolderGivesItsThreadsAnAutomaticProject() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let a = try h.folder("a")
    let b = try h.folder("b")
    let unused = try h.folder("unused")
    let thread = try await h.newThread(connection, in: a)
    let manual = try await h.create("Site", [a, b, unused])
    #expect(try h.db.thread(id: thread.id)?.projectId == manual.id)

    let updated = try await h.client.request(
      ProjectUpdate.self, ProjectUpdate.Params(projectId: manual.id, removeFolders: [a + "/", unused]),
      options: h.mutation()
    ).project
    #expect(updated.folders.map(\.path) == [SessionService.canonicalDirectory(b)])
    // `a` has a thread, so it gets an automatic project at once; `unused` waits for its next thread.
    let moved = try #require(try h.db.thread(id: thread.id)?.projectId)
    #expect(moved != manual.id)
    let replacement = try #require(try h.db.project(id: moved))
    #expect(!replacement.manual && replacement.displayName == "a")
    #expect(try h.db.project(folderPath: SessionService.canonicalDirectory(unused)) == nil)
    _ = await h.projectEvents(until: { $0.contains(replacement.id) })
    try await h.events.waitFor {
      $0.kind == .threadUpdated && $0.threadId == thread.id
        && $0.payload["thread"]?["projectId"]?.stringValue == moved
    }

    // An automatic project has nothing to remove without first adding.
    let refused = await h.failure {
      try await h.client.request(
        ProjectUpdate.self, ProjectUpdate.Params(projectId: replacement.id, removeFolders: [a]),
        options: h.mutation())
    }
    #expect(refused?.code == .protocolInvalid)
  }

  @Test func deletingAManualProjectReturnsItsFoldersToAutomaticProjects() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let a = try h.folder("a")
    let b = try h.folder("b")
    let thread = try await h.newThread(connection, in: a)
    let manual = try await h.create("Site", [a, b])

    let deleted = try await h.client.request(
      ProjectDelete.self, ProjectDelete.Params(projectId: manual.id), options: h.mutation())
    #expect(deleted.projectId == manual.id)
    let projects = try await h.projects()
    #expect(projects.count == 1)
    #expect(projects[0].displayName == "a" && !projects[0].manual)
    #expect(try h.db.thread(id: thread.id)?.projectId == projects[0].id)
    _ = await h.projectEvents(until: { $0.filter { $0 == manual.id }.count >= 2 })
    #expect(
      await h.failure {
        try await h.client.request(
          ProjectDelete.self, ProjectDelete.Params(projectId: "nope"), options: h.mutation())
      }?.code == .notFound)
  }

  @Test func anAutomaticProjectCannotBeDeleted() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("a"))
    let projectId = try #require(thread.projectId)
    let error = await h.failure {
      try await h.client.request(
        ProjectDelete.self, ProjectDelete.Params(projectId: projectId), options: h.mutation())
    }
    #expect(error?.code == .protocolInvalid)
    #expect(try h.db.project(id: projectId) != nil)
  }

  @Test func createRefusesNoFoldersAndMissingFolders() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let none = await h.failure { try await h.create("Empty", []) }
    #expect(none?.code == .protocolInvalid)
    let missing = h.base + "/nowhere"
    let bad = await h.failure { try await h.create("Bad", [try h.folder("real"), missing]) }
    #expect(bad?.code == .protocolInvalid && bad?.message.contains(missing) == true)
    #expect(try await h.projects().isEmpty)
  }

  @Test func renameToEmptyRestoresTheFolderName() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("app"))
    let projectId = try #require(thread.projectId)

    func rename(_ name: String) async throws -> Project {
      try await h.client.request(
        ProjectRename.self, ProjectRename.Params(projectId: projectId, name: name), options: h.mutation()
      ).project
    }
    #expect(try await rename("Site").displayName == "Site")
    #expect(try await h.projects().first?.displayName == "Site")
    #expect(try await rename("").displayName == "app")
    #expect(try await h.projects().first?.displayName == "app")
    #expect(try await rename("   ").displayName == "app")
    let missing = await h.failure {
      try await h.client.request(
        ProjectRename.self, ProjectRename.Params(projectId: "nope", name: "x"), options: h.mutation())
    }
    #expect(missing?.code == .notFound)
    try await h.events.waitFor {
      $0.kind == .projectChanged && $0.payload["projectId"]?.stringValue == projectId
    }
  }

  @Test func localB4ThreadsUseTheServerProjectAndRemoteHaveNone() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project("research-agent")
    let server = try await h.add(path)
    let projects = h.coordinator.projects

    let local = try h.coordinator.database.insertConnection(
      Connection(
        id: "c-local", kind: .b4, label: "Local", target: "http://127.0.0.1:1", routeKey: "/chat#agent",
        b4Mode: .managedLocal, localServerId: server.id))
    let remote = try h.coordinator.database.insertConnection(
      Connection(
        id: "c-remote", kind: .b4, label: "Remote", target: "https://b4.example.com",
        routeKey: "/chat#agent", b4Mode: .remote))
    // A B4 thread's context is a route key, never a folder.
    let thread = ConversationThread(
      id: "t", connectionId: local.id, nativeThreadId: "n", context: "/chat#agent")

    let localId = try #require(try await projects.projectId(forThread: thread, connection: local))
    let project = try #require(try h.coordinator.database.project(id: localId))
    #expect(project.folders.map(\.path) == [SessionService.canonicalDirectory(path)])
    #expect(project.displayName == "research-agent")
    // The same server again finds the same project; the remote connection has none.
    #expect(try await projects.projectId(forThread: thread, connection: local) == localId)
    #expect(try await projects.projectId(forThread: thread, connection: remote) == nil)
    #expect(try h.coordinator.database.listProjects().count == 1)
  }

  @Test func markReadAndClearedDraftThroughTheRouter() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    #expect(thread.readTurnId == nil)

    // A draft, then a send: the draft row stays, with empty text.
    _ = try await h.client.request(
      DraftSave.self, DraftSave.Params(threadId: thread.id, text: "typing"), options: h.mutation())
    let turn = try await h.client.request(
      TurnSend.self, TurnSend.Params(threadId: thread.id, text: "hello"), options: h.mutation()
    ).turn
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    let draft = try await h.client.request(DraftRead.self, DraftRead.Params(threadId: thread.id)).draft
    #expect(draft?.text == "")

    // Events arrive over the socket after the call that caused them returns, so every count below is
    // taken after waiting. Two are due before marking: the thread's creation, and the touch that
    // records the finished turn (published around `turn.finished`, so it can land after it).
    let base = await h.threadUpdates(thread.id) { $0.count >= 2 }.count
    #expect(base == 2)

    let marked = try await h.client.request(
      ThreadMarkRead.self, ThreadMarkRead.Params(threadId: thread.id, turnId: turn.id),
      options: h.mutation()
    ).thread
    #expect(marked.readTurnId == turn.id)
    #expect(marked.activity?.latestTurnId == turn.id)
    _ = await h.threadUpdates(thread.id) { $0.count > base }

    // Marking the same turn again changes nothing, so it says nothing; neither does a turn that is not
    // this thread's. Nil marks it unread again, which does say so.
    let again = try await h.client.request(
      ThreadMarkRead.self, ThreadMarkRead.Params(threadId: thread.id, turnId: turn.id),
      options: h.mutation()
    ).thread
    #expect(again.readTurnId == turn.id)
    let stale = try await h.client.request(
      ThreadMarkRead.self, ThreadMarkRead.Params(threadId: thread.id, turnId: "not-a-turn"),
      options: h.mutation()
    ).thread
    #expect(stale.readTurnId == turn.id)
    let unread = try await h.client.request(
      ThreadMarkRead.self, ThreadMarkRead.Params(threadId: thread.id), options: h.mutation()
    ).thread
    #expect(unread.readTurnId == nil)
    // Events are published in order, so once the unread one has landed anything the two silent calls
    // had said would have landed before it: exactly two events since `base`, read then unread.
    let since = Array(await h.threadUpdates(thread.id) { $0.count > base + 1 }.dropFirst(base))
    #expect(since.count == 2)
    #expect(since.first?.payload["thread"]?["readTurnId"]?.stringValue == turn.id)
    #expect(since.last?.payload["thread"]?["readTurnId"]?.stringValue == nil)

    let missing = await h.failure {
      try await h.client.request(
        ThreadMarkRead.self, ThreadMarkRead.Params(threadId: "nope", turnId: nil), options: h.mutation())
    }
    #expect(missing?.code == .notFound)
  }

  @Test func insertThreadIsAtomicAgainstProjectEdits() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let connection = try h.db.insertConnection(
      Connection(id: "c1", kind: .codex, label: "Codex", target: fakeCodex))
    let projects = h.coordinator.projects

    // Deterministic part: the thread comes back with its project, a new project is announced once, and
    // the row is stored with that project.
    let first = try h.folder("first")
    let inserted = try await projects.insertThread(
      ConversationThread(id: "t0", connectionId: connection.id, nativeThreadId: "n0", context: first),
      connection: connection)
    let projectId = try #require(inserted.projectId)
    #expect(try h.db.thread(id: "t0")?.projectId == projectId)
    _ = await h.projectEvents(until: { $0 == [projectId] })

    // A project command racing a thread create can no longer interleave with it: resolving the project
    // and inserting the row are one actor section with no suspension point. Whichever runs first, the
    // thread ends in the project that owns its folder (before the fix, create-first deleted the empty
    // automatic project under the insert, and update-first left the thread in a project that no longer
    // owned its folder). Scheduling cannot be forced, so this repeats the race and checks the invariant.
    for round in 0..<30 {
      let folder = try h.folder("race-\(round)")
      let canonical = SessionService.canonicalDirectory(folder)
      let id = "race-\(round)"
      async let created: ConversationThread = projects.insertThread(
        ConversationThread(id: id, connectionId: connection.id, nativeThreadId: "n\(id)", context: folder),
        connection: connection)
      async let edited: ProjectCreate.Result = projects.create(
        ProjectCreate.Params(name: "Manual \(round)", folders: [folder]))
      let (thread, project) = try await (created, edited)
      let stored = try #require(try h.db.thread(id: thread.id))
      #expect(stored.projectId == project.project.id, "round \(round)")
      #expect(try h.db.project(folderPath: canonical)?.id == stored.projectId, "round \(round)")
      #expect(try h.db.project(id: stored.projectId ?? "") != nil, "round \(round)")
    }
  }
}

/// `connections.projectId` (migration 0005): a local B4 connection belongs to the project of its managed
/// server's folder, and follows that folder when a project edit moves it.
@Suite(.serialized) struct ConnectionProjectTests {
  private func connect(_ h: ServerHarness, _ server: LocalServer) async throws -> Connection {
    try await h.client.request(
      ConnectionAdd.self, ConnectionAdd.Params(kind: .b4, route: "/chat#agent", serverId: server.id),
      options: h.mutation()
    ).connection
  }

  private func stored(_ h: ServerHarness, _ connection: Connection) throws -> Connection {
    try #require(try h.coordinator.database.connection(id: connection.id))
  }

  @Test func localB4ConnectionGetsItsServersProject() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project("research-agent")
    let server = try await h.add(path)
    let connection = try await connect(h, server)

    let projectId = try #require(try stored(h, connection).projectId)
    #expect(connection.projectId == projectId)
    let project = try #require(try h.coordinator.database.project(id: projectId))
    #expect(project.folders.map(\.path) == [SessionService.canonicalDirectory(path)])
    #expect(project.displayName == "research-agent")
    // The connection's insert already carries the project, in the one change that creates the row.
    let insert = try #require(
      try h.coordinator.database.changes(after: 0).first {
        $0.table == "connections" && $0.op == "insert" && $0.rowId == connection.id
      })
    #expect(insert.value?["projectId"] == .string(projectId))
    // A second connection on the same server finds the same project rather than making another.
    #expect(try h.coordinator.database.listProjects().count == 1)
  }

  @Test func movingTheServerFolderMovesTheConnection() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project("research-agent")
    let server = try await h.add(path)
    let connection = try await connect(h, server)
    let automatic = try #require(try stored(h, connection).projectId)

    // A manual project takes the folder: the connection follows.
    let manual = try await h.client.request(
      ProjectCreate.self, ProjectCreate.Params(name: "Research", folders: [path]), options: h.mutation()
    ).project
    #expect(try stored(h, connection).projectId == manual.id)
    #expect(try h.coordinator.database.project(id: automatic) == nil)

    // The folder leaves it (the manual project is kept, empty): the connection gets an automatic project.
    _ = try await h.client.request(
      ProjectUpdate.self, ProjectUpdate.Params(projectId: manual.id, removeFolders: [path]),
      options: h.mutation())
    let afterRemove = try #require(try stored(h, connection).projectId)
    #expect(afterRemove != manual.id)
    #expect(
      try h.coordinator.database.project(id: afterRemove)?.folders.map(\.path) == [
        SessionService.canonicalDirectory(path)
      ])

    // Another manual project takes it and is then deleted: the connection returns to an automatic one.
    let second = try await h.client.request(
      ProjectCreate.self, ProjectCreate.Params(name: "Second", folders: [path]), options: h.mutation()
    ).project
    #expect(try stored(h, connection).projectId == second.id)
    _ = try await h.client.request(
      ProjectDelete.self, ProjectDelete.Params(projectId: second.id), options: h.mutation())
    let afterDelete = try #require(try stored(h, connection).projectId)
    #expect(afterDelete != second.id)
    #expect(
      try h.coordinator.database.project(id: afterDelete)?.folders.map(\.path) == [
        SessionService.canonicalDirectory(path)
      ])
    // The change log recorded each move as an update of the one column.
    let moves = try h.coordinator.database.changes(after: 0).filter {
      $0.table == "connections" && $0.op == "update" && $0.column == "projectId"
        && $0.rowId == connection.id
    }
    #expect(moves.count >= 3)
  }

  @Test func codexAndRemoteB4ConnectionsHaveNoProject() async throws {
    let h = try await ProjectHarness.start()
    defer { Task { await h.close() } }
    let codex = try await h.addCodex()
    let remote = try h.db.insertConnection(
      Connection(
        id: "c-remote", kind: .b4, label: "Remote", target: "https://b4.example.com",
        routeKey: "/chat#agent", b4Mode: .remote))
    // A managed-mode connection with no server behind it has no folder either.
    let unserved = try h.db.insertConnection(
      Connection(
        id: "c-unserved", kind: .b4, label: "Unserved", target: "http://127.0.0.1:1",
        routeKey: "/chat#agent", b4Mode: .managedLocal))
    let projects = h.coordinator.projects
    for connection in [codex, remote, unserved] {
      #expect(try await projects.projectId(forConnection: connection) == nil, "\(connection.label)")
    }
    #expect(try await projects.backfillConnections() == 0)
    for id in [codex.id, remote.id, unserved.id] {
      #expect(try h.db.connection(id: id)?.projectId == nil)
    }
    #expect(try h.db.listProjects().isEmpty)
  }

  @Test func backfillSetsExistingConnections() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project("research-agent")
    let server = try await h.add(path)
    let db = h.coordinator.database
    // Rows as an older build left them: a local B4 connection with no project, and a remote one.
    let local = try db.insertConnection(
      Connection(
        id: "c-local", kind: .b4, label: "Local", target: "http://127.0.0.1:1", routeKey: "/chat#agent",
        b4Mode: .managedLocal, localServerId: server.id))
    _ = try db.insertConnection(
      Connection(
        id: "c-remote", kind: .b4, label: "Remote", target: "https://b4.example.com",
        routeKey: "/chat#agent", b4Mode: .remote))
    #expect(local.projectId == nil)
    let before = try db.changes(after: 0).last?.seq ?? 0

    #expect(try await h.coordinator.projects.backfillConnections() == 1)
    let projectId = try #require(try db.connection(id: "c-local")?.projectId)
    #expect(try db.project(id: projectId)?.folders.map(\.path) == [SessionService.canonicalDirectory(path)])
    #expect(try db.connection(id: "c-remote")?.projectId == nil)
    // It ran with the change log on, so the hub hears of it as an update of the one column.
    let updates = try db.changes(after: before).filter { $0.table == "connections" && $0.op == "update" }
    #expect(updates.map(\.column) == ["projectId"])
    #expect(updates.first?.value == .string(projectId))
    #expect(updates.first?.rowId == "c-local")
    // Idempotent: nothing left to assign, and no second project for the same folder.
    #expect(try await h.coordinator.projects.backfillConnections() == 0)
    #expect(try db.listProjects().count == 1)
  }
}
