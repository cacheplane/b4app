/// One explicitly selected prerequisite request. Copies retain the same finite collector.
struct InspectionRequestObservation: Sendable {
  enum CaseID: UInt8, Sendable {
    case expiredLogin = 1
    case deleteCodex = 2
    case noFolderCodex = 3
    case organizationRestart = 4
    case claudeFolders = 5
    case environmentSpellings = 6
    case continuityRestart = 7
    case redaction = 8
    case claudeLocalStart = 9
    case socketConversation = 10
    case claudeModels = 11
    case claudeRecovery = 12
    case lifecycle = 13
    case b4BesideCodex = 14
    case codexUsage = 15
    case historicalSocketPeerBeforeAck = 16

    fileprivate var parameter: String {
      switch self {
      case .noFolderCodex: "codex"
      case .historicalSocketPeerBeforeAck: "peerBeforeAck"
      case .expiredLogin, .deleteCodex, .organizationRestart, .claudeFolders,
        .environmentSpellings, .continuityRestart, .redaction, .claudeLocalStart,
        .socketConversation, .claudeModels, .claudeRecovery, .lifecycle, .b4BesideCodex,
        .codexUsage:
        "none"
      }
    }
  }

  let collector: InspectionObservation
  let caseID: CaseID

  init(caseID: CaseID) {
    collector = InspectionObservation()
    self.caseID = caseID
  }

  /// No new task or executor hop: caller inheritance remains a managed compilation condition.
  func perform<Result: Sendable>(
    kind: InspectionObservation.Kind, operation: () async throws -> Result,
    report: (String) -> Void = { print($0) }
  ) async throws -> Result {
    let call = collector.nextCallOrdinal()
    collector.record(.requestIssued, kind: kind, callOrdinal: call)
    do {
      let result = try await operation()
      finish(kind: kind, call: call, threw: false, report: report)
      return result
    } catch {
      finish(kind: kind, call: call, threw: true, report: report)
      throw error
    }
  }

  private func finish(
    kind: InspectionObservation.Kind, call: UInt16?, threw: Bool, report: (String) -> Void
  ) {
    collector.record(.requestReturned, kind: kind, callOrdinal: call, threw: threw)
    let snapshot = collector.snapshot()
    // Snapshot has unlocked. Outcome labels this branch, not the presence of its lossy record.
    // Only that record's elapsedNanoseconds measures the end; a missing end remains unknown.
    let outcome = threw ? "threw" : "returned"
    let header =
      "connectionInspection caseOrdinal=\(caseID.rawValue) parameter=\(caseID.parameter) requestScope=connectionAdd requestOutcome=\(outcome) snapshotTiming=requestReturn"
    report(header + "\n" + snapshot.formatted())
  }
}
