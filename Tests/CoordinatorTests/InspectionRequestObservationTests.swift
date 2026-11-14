import Synchronization
import Testing

/// Mechanical request-envelope controls only; no coordinator, adapter, or native runtime.
struct InspectionRequestObservationTests {
  @Test func requestEnvelopeReturnsOriginalResultOnceAndReportsAtReturn() async throws {
    let envelope = InspectionRequestObservation(caseID: .expiredLogin)
    let sentinel = RequestEnvelopeResult(rawValue: "result-must-not-be-reported")
    let facts = Mutex(RequestEnvelopeFacts())

    let result = try await envelope.perform(
      kind: .codex,
      operation: {
        facts.withLock {
          $0.operationInvocations += 1
          $0.operationFinished = true
        }
        return sentinel
      },
      report: { report in
        let state = facts.withLock {
          $0.reports.append(report)
          return ($0.operationFinished, $0.outerCatchReached)
        }
        #expect(state.0)
        #expect(!state.1)
        // Re-enter the existing try-lock allocator at the actual reporting boundary.
        // No test mutex is held here; this checks unlock, not forced contention or coverage.
        #expect(envelope.collector.nextAdapterOrdinal() == 1)
      })

    #expect(result === sentinel)
    let recorded = facts.withLock { $0 }
    #expect(recorded.operationInvocations == 1)
    try #require(recorded.reports.count == 1)
    let report = recorded.reports[0]
    #expect(report.contains("connectionInspection"))
    #expect(report.contains("caseOrdinal=1"))
    #expect(report.contains("requestScope=connectionAdd"))
    #expect(report.contains("requestOutcome=returned"))
    #expect(report.contains("partial=true joined=false"))
    #expect(!report.contains(sentinel.rawValue))
    let lines = report.split(separator: "\n").filter { $0.hasPrefix("phase=") }
    try #require(lines.count == 2)
    let issued = lines[0].split(separator: " ")
    let returned = lines[1].split(separator: " ")
    #expect(issued.contains("phase=requestIssued"))
    #expect(returned.contains("phase=requestReturned"))
    #expect(issued.contains("kind=codex") && returned.contains("kind=codex"))
    #expect(issued.contains("harness=1") && returned.contains("harness=1"))
    #expect(issued.contains("adapter=unavailable") && returned.contains("adapter=unavailable"))
    let call = try #require(issued.first { $0.hasPrefix("call=") })
    #expect(call != "call=unavailable")
    #expect(returned.contains(call))
    #expect(issued.contains("threw=false") && returned.contains("threw=false"))
    #expect(envelope.collector.snapshot().availability == .alreadyAttempted)
  }

  @Test func requestEnvelopeRethrowsOriginalErrorOnceAndReportsBeforeCatch() async throws {
    let envelope = InspectionRequestObservation(caseID: .claudeFolders)
    let sentinel = RequestEnvelopeError(rawValue: "error-must-not-be-reported")
    let facts = Mutex(RequestEnvelopeFacts())

    do {
      let _: RequestEnvelopeResult = try await envelope.perform(
        kind: .claude,
        operation: {
          facts.withLock {
            $0.operationInvocations += 1
            $0.operationFinished = true
          }
          throw sentinel
        },
        report: { report in
          let state = facts.withLock {
            $0.reports.append(report)
            return ($0.operationFinished, $0.outerCatchReached)
          }
          #expect(state.0)
          #expect(!state.1)
          // The reporter must run after unlocking, outside the collector's record callbacks.
          #expect(envelope.collector.nextAdapterOrdinal() == 1)
        })
      Issue.record("The original operation threw; returning a result is forbidden")
    } catch {
      #expect((error as? RequestEnvelopeError) === sentinel)
      let reportCountAtCatch = facts.withLock {
        $0.outerCatchReached = true
        return $0.reports.count
      }
      #expect(reportCountAtCatch == 1)
    }

    let recorded = facts.withLock { $0 }
    #expect(recorded.operationInvocations == 1)
    #expect(recorded.outerCatchReached)
    try #require(recorded.reports.count == 1)
    let report = recorded.reports[0]
    #expect(report.contains("connectionInspection"))
    #expect(report.contains("caseOrdinal=5"))
    #expect(report.contains("requestOutcome=threw"))
    #expect(report.contains("partial=true joined=false"))
    #expect(!report.contains(sentinel.rawValue))
    let lines = report.split(separator: "\n").filter { $0.hasPrefix("phase=") }
    try #require(lines.count == 2)
    let issued = lines[0].split(separator: " ")
    let returned = lines[1].split(separator: " ")
    #expect(issued.contains("phase=requestIssued"))
    #expect(returned.contains("phase=requestReturned"))
    #expect(issued.contains("kind=claude") && returned.contains("kind=claude"))
    let call = try #require(issued.first { $0.hasPrefix("call=") })
    #expect(call != "call=unavailable")
    #expect(returned.contains(call))
    #expect(issued.contains("threw=false"))
    #expect(returned.contains("threw=true"))
    // perform consumed the one snapshot attempt; this explicit second attempt gets no records.
    let second = envelope.collector.snapshot()
    #expect(second.availability == .alreadyAttempted)
    #expect(second.records.isEmpty)
  }
}

private struct RequestEnvelopeFacts: Sendable {
  var operationInvocations = 0
  var operationFinished = false
  var outerCatchReached = false
  var reports: [String] = []
}

private final class RequestEnvelopeResult: Sendable, CustomStringConvertible {
  let rawValue: String
  init(rawValue: String) { self.rawValue = rawValue }
  var description: String { rawValue }
}

private final class RequestEnvelopeError: Error, CustomStringConvertible {
  let rawValue: String
  init(rawValue: String) { self.rawValue = rawValue }
  var description: String { rawValue }
}
