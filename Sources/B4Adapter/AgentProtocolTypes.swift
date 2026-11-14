import Foundation

/// DTOs for the pinned Agent Protocol wire contract and its negotiated B4 v1 extensions.
/// These values decode data only: they do not execute pending work or authorize an action.
public enum AgentProtocol {
  public typealias Object = [String: Value]

  /// Opaque JSON preserves integer precision instead of converting every number to Double.
  /// Decimal retains Foundation's finite decimal precision; this is not a lexical JSON archive.
  public indirect enum Value: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case decimal(Decimal)
    case real(Double)
    case string(String)
    case array([Value])
    case object(Object)

    public subscript(key: String) -> Value? {
      get {
        guard case .object(let members) = self else { return nil }
        return members[key]
      }
      set {
        guard case .object(var members) = self else { return }
        members[key] = newValue
        self = .object(members)
      }
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self = .null
      } else if let value = try? container.decode(Bool.self) {
        self = .bool(value)
      } else if let value = try? container.decode(Int64.self) {
        self = .integer(value)
      } else if let value = try? container.decode(UInt64.self) {
        self = .unsignedInteger(value)
      } else if let value = try? container.decode(Decimal.self) {
        self = .decimal(value)
      } else if let value = try? container.decode(Double.self), value.isFinite {
        self = .real(value)
      } else if let value = try? container.decode(String.self) {
        self = .string(value)
      } else if let value = try? container.decode([Value].self) {
        self = .array(value)
      } else if let value = try? container.decode(Object.self) {
        self = .object(value)
      } else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
      }
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .null: try container.encodeNil()
      case .bool(let value): try container.encode(value)
      case .integer(let value): try container.encode(value)
      case .unsignedInteger(let value): try container.encode(value)
      case .decimal(let value): try container.encode(value)
      case .real(let value): try container.encode(value)
      case .string(let value): try container.encode(value)
      case .array(let value): try container.encode(value)
      case .object(let value): try container.encode(value)
      }
    }
  }

  /// Records retain all fields, including optional extensions unknown to this client.
  public protocol Record: Codable, Sendable {
    var raw: Object { get }
  }

  /// B4 canonical identifiers are lowercase UUID strings. Native AG-UI tokens are separate.
  public struct CanonicalID: Codable, Sendable, Equatable, Hashable {
    public let rawValue: UUID

    public init(_ value: UUID) { rawValue = value }

    public init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let value = UUID(uuidString: text), value.uuidString.lowercased() == text else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Expected a lowercase canonical UUID")
      }
      rawValue = value
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue.uuidString.lowercased())
    }
  }

  /// CDDL js_uint, used for command correlation and stream sequence positions.
  public struct JSUInt: Codable, Sendable, Equatable, Hashable {
    public static let maximum: UInt64 = 9_007_199_254_740_991
    public let rawValue: UInt64

    public init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let value: UInt64
      do {
        value = try container.decode(UInt64.self)
      } catch DecodingError.dataCorrupted(let context) {
        throw DecodingError.dataCorrupted(
          .init(
            codingPath: decoder.codingPath, debugDescription: context.debugDescription,
            underlyingError: context.underlyingError))
      } catch let error as DecodingError {
        throw error
      } catch {
        // Foundation's private numeric-conversion errors otherwise lose their field path
        // when JSONDecoder wraps them at the document boundary.
        throw DecodingError.dataCorrupted(
          .init(
            codingPath: decoder.codingPath,
            debugDescription: "Expected a nonnegative JavaScript-safe integer",
            underlyingError: error))
      }
      guard value <= Self.maximum else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Integer exceeds the protocol's JavaScript-safe range")
      }
      rawValue = value
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }
  }

  /// An RFC 3339 timestamp retains its wire spelling; Date's default Codable format is unused.
  public struct Timestamp: Codable, Sendable, Equatable {
    public let rawValue: String
    public let date: Date

    public init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let fractional = formatter.date(from: text)
      formatter.formatOptions = [.withInternetDateTime]
      guard
        text.range(
          of: #"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$"#,
          options: .regularExpression) != nil,
        let date = fractional ?? formatter.date(from: text)
      else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Expected an RFC 3339 timestamp")
      }
      rawValue = text
      self.date = date
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }
  }

  public enum RunStatus: String, Codable, Sendable { case pending, error, success, timeout, interrupted }
  public enum ThreadStatus: String, Codable, Sendable { case idle, busy, interrupted, error }
  public enum PublicRole: String, Codable, Sendable { case user, assistant, system, tool }
  public enum ASPRole: String, Codable, Sendable { case ai, human, system }
  public enum InputRole: String, Codable, Sendable { case user, system }
  public enum Phase: String, Codable, Sendable { case accepted, running, settled }
  public enum Continuation: String, Codable, Sendable { case none, waiting, closed }
  public enum Reason: String, Codable, Sendable {
    case completed, permission, deadline
    case userStop = "user_stop"
    case serverShutdown = "server_shutdown"
    case executionError = "execution_error"
    case executionLost = "execution_lost"
    case clientDisconnect = "client_disconnect"
  }
  public enum TurnState: String, Codable, Sendable {
    case running, waiting, completed, stopped, error, timeout
  }
  public enum Disposition: String, Codable, Sendable {
    case accepted, applied
    case notApplied = "not_applied"
  }
  public enum SubmissionKind: String, Codable, Sendable { case b4, agui }
  public enum Submission: Sendable, Equatable { case b4(CanonicalID), agui(String) }
  public enum AgentKind: String, Codable, Sendable { case agent, chain, graph, workflow }
  public enum ActivityState: String, Codable, Sendable {
    case open, completed, interrupted, failed, denied, cancelled, historical
  }
  public enum PendingStatus: String, Codable, Sendable {
    case waiting, expired, resolved, denied, abandoned, stopped
  }
  public enum MaintenanceKind: String, Codable, Sendable { case rollback, delete }
  public enum MaintenanceState: String, Codable, Sendable { case requested, draining, cleaning, failed }
  public enum LookupState: String, Codable, Sendable { case accepted, expired }

  public struct Message: Record {
    public let raw: Object
    /// OpenAPI Message roles are open strings; B4Message applies the public role restriction.
    public let role: String
    public let content: Content
    public let id: String?
    public let metadata: Object?

    public enum Content: Codable, Sendable, Equatable {
      case text(String)
      case blocks([Object])

      public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
          self = .text(text)
        } else {
          self = .blocks(try container.decode([APContentBlock].self).map(\.raw))
        }
      }

      public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .blocks(let blocks): try container.encode(blocks)
        }
      }
    }

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      role = try object.decode("role")
      content = try object.decode("content")
      id = try object.optional("id")
      metadata = try object.optional("metadata")
    }
  }

  public struct B4Message: Record {
    public let raw: Object
    public let role: PublicRole
    public let message: Message

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      role = try object.decode("role")
      message = try Message(from: decoder)
    }
  }

  public struct Agent: Record {
    public let raw: Object
    public let agentID: String
    public let name: String
    public let description: String?
    public let metadata: Object?
    public let capabilities: Object

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      agentID = try object.decode("agent_id")
      name = try object.decode("name")
      description = try object.optional("description")
      metadata = try object.optional("metadata")
      capabilities = try object.decode("capabilities")
      let flags = try object.nested("capabilities")
      for key in ["ap.io.messages", "ap.io.streaming"] {
        let _: Bool? = try flags.optional(key)
      }
    }
  }

  /// A persisted caller UUID and original metadata are replayed with no merge semantics.
  public struct ThreadCreateRequest: Sendable {
    public let threadID: UUID
    public let metadata: Object

    public init(threadID: UUID, metadata: Object = [:]) {
      self.threadID = threadID
      self.metadata = metadata
    }

    public var body: Value {
      .object([
        "thread_id": .string(threadID.uuidString.lowercased()),
        "metadata": .object(metadata), "if_exists": .string("do_nothing"),
      ])
    }
  }

  /// Literal reserved selectors identify the original operation, including a fork's source Thread.
  /// They are not nested annotation filters or the standard destination thread_id filter.
  public struct OperationLookupRequest: Sendable {
    public let submissionID: CanonicalID
    public let operationThreadID: CanonicalID
    public let targetRunID: CanonicalID?

    public init(
      submissionID: CanonicalID, operationThreadID: CanonicalID, targetRunID: CanonicalID? = nil
    ) {
      self.submissionID = submissionID
      self.operationThreadID = operationThreadID
      self.targetRunID = targetRunID
    }

    public var body: Value {
      var metadata: Object = [
        "b4.submissionId": .string(submissionID.rawValue.uuidString.lowercased()),
        "b4.submissionKind": .string("b4"),
        "b4.operationThreadId": .string(operationThreadID.rawValue.uuidString.lowercased()),
      ]
      if let targetRunID {
        metadata["b4.targetRunId"] = .string(targetRunID.rawValue.uuidString.lowercased())
      }
      return .object(["metadata": .object(metadata), "limit": .integer(1), "offset": .integer(0)])
    }
  }

  /// Standard run.start parameters. Submission metadata is supplied by durable intent ownership;
  /// constructing a transport request never mints a token or changes its expectations.
  public struct RunStartRequest: Sendable {
    public let assistantID: String
    public let input: Value
    public let config: Object?
    public let metadata: Object?

    public init(assistantID: String, input: Value, config: Object? = nil, metadata: Object? = nil) {
      self.assistantID = assistantID
      self.input = input
      self.config = config
      self.metadata = metadata
    }

    public var params: Object {
      var result: Object = ["assistantId": .string(assistantID), "input": input]
      if let config { result["config"] = .object(config) }
      if let metadata { result["metadata"] = .object(metadata) }
      return result
    }
  }

  public struct Thread: Record {
    public let raw: Object
    public let threadID: UUID
    public let createdAt: Timestamp
    public let updatedAt: Timestamp
    public let metadata: Object
    public let status: ThreadStatus
    public let values: Object?
    public let messages: [Message]?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      threadID = try object.decode("thread_id")
      createdAt = try object.decode("created_at")
      updatedAt = try object.decode("updated_at")
      metadata = try object.decode("metadata")
      status = try object.decode("status")
      values = try object.optional("values")
      messages = try object.optional("messages")
    }
  }

  public struct Run: Record {
    public let raw: Object
    public let runID: UUID
    public let threadID: UUID?
    public let createdAt: Timestamp
    public let updatedAt: Timestamp
    public let status: RunStatus
    public let metadata: Object
    public let messages: [Message]?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      runID = try object.decode("run_id")
      threadID = try object.optional("thread_id")
      createdAt = try object.decode("created_at")
      updatedAt = try object.decode("updated_at")
      status = try object.decode("status")
      metadata = try object.decode("metadata")
      messages = try object.optional("messages")
    }
  }

  public struct ThreadState: Record {
    public let raw: Object
    public let checkpoint: ThreadCheckpoint
    public let values: Object
    public let messages: [Message]?
    public let metadata: Object?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      checkpoint = try object.decode("checkpoint")
      values = try object.decode("values")
      messages = try object.optional("messages")
      metadata = try object.optional("metadata")
    }
  }

  public struct ThreadCheckpoint: Record {
    public let raw: Object
    public let checkpointID: UUID

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      checkpointID = try object.decode("checkpoint_id")
    }
  }

  public struct B4Agent: Record {
    public let raw: Object
    public let agent: Agent
    public let metadata: AgentMetadata

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      agent = try Agent(from: decoder)
      metadata = try object.decode(APB4Envelope<AgentMetadata>.self, "metadata").b4
      try APB4AgentContract.agent(object)
    }
  }

  public struct B4Thread: Record {
    public let raw: Object
    public let thread: Thread
    public let recovery: Recovery

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      thread = try Thread(from: decoder)
      let _: CanonicalID = try object.decode("thread_id")
      _ = try object.utc("created_at")
      _ = try object.utc("updated_at")
      let _: [B4Message]? = try object.optional("messages")
      recovery = try object.decode(APB4Envelope<Recovery>.self, "metadata").b4
    }
  }

  public struct B4Run: Record {
    public let raw: Object
    public let run: Run
    public let metadata: RunMetadata

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      run = try Run(from: decoder)
      let _: CanonicalID = try object.decode("run_id")
      let _: CanonicalID? = try object.optional("thread_id")
      _ = try object.utc("created_at")
      _ = try object.utc("updated_at")
      let _: [B4Message]? = try object.optional("messages")
      metadata = try object.decode(APB4Envelope<RunMetadata>.self, "metadata").b4
    }
  }

  public struct B4ThreadState: Record {
    public let raw: Object
    public let state: ThreadState
    public let history: HistoryMetadata

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      state = try ThreadState(from: decoder)
      let _: CanonicalID = try object.nested("checkpoint").decode("checkpoint_id")
      let _: [B4Message]? = try object.optional("messages")
      history = try object.decode(APB4Envelope<HistoryMetadata>.self, "metadata").b4
    }
  }

  public struct Receipt: Record {
    public let raw: Object
    public let submission: Submission
    public let runID: CanonicalID
    public let turnID: CanonicalID
    public let acceptedAt: Timestamp
    public let replayed: Bool
    public let disposition: Disposition
    public let inputID: CanonicalID?
    public let reason: String?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      submission = try object.requiredSubmission()
      runID = try object.decode("runId")
      turnID = try object.decode("turnId")
      acceptedAt = try object.utc("acceptedAt")
      replayed = try object.decode("replayed")
      disposition = try object.decode("disposition")
      inputID = try object.optional("inputId")
      reason = try object.optional("reason")
    }
  }

  public struct OperationLookup: Record {
    public let raw: Object
    public let submission: Submission
    public let state: LookupState
    public let receipt: Receipt?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      submission = try object.requiredSubmission()
      state = try object.decode("state")
      if state == .accepted {
        receipt = try object.decode("receipt")
      } else {
        try object.forbid("receipt")
        receipt = nil
      }
    }
  }

  public struct RequestMetadata: Record {
    public let raw: Object
    public let submissionID: CanonicalID?
    public let expected: Expected?

    public struct Expected: Record {
      public let raw: Object
      public let generation: CanonicalID?
      public let runID: CanonicalID?
      public let pausedGeneration: CanonicalID?

      public init(from decoder: Decoder) throws {
        let object = try APObject(decoder)
        try object.closed(["generation", "runId", "pausedGeneration"])
        raw = object.raw
        generation = try object.optional("generation")
        runID = try object.optional("runId")
        pausedGeneration = try object.optional("pausedGeneration")
      }
    }

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.version()
      try object.closed(["v", "submissionId", "expected"])
      raw = object.raw
      submissionID = try object.optional("submissionId")
      expected = try object.optional("expected")
    }
  }

  public struct RunSummary: Record {
    public let raw: Object
    public let runID: CanonicalID
    public let turnID: CanonicalID
    public let agentID: String
    public let status: RunStatus
    public let phase: Phase
    public let continuation: Continuation
    public let effectsUncertain: Bool
    public let previousRunID: CanonicalID?
    public let reason: Reason?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      runID = try object.decode("runId")
      turnID = try object.decode("turnId")
      agentID = try object.decode("agentId")
      status = try object.decode("status")
      phase = try object.decode("phase")
      continuation = try object.decode("continuation")
      effectsUncertain = try object.decode("effectsUncertain")
      previousRunID = try object.optional("previousRunId")
      reason = try object.optional("reason")
    }
  }

  public struct TurnSummary: Record {
    public let raw: Object
    public let turnID: CanonicalID
    public let currentRunID: CanonicalID
    public let state: TurnState
    public let continuation: Continuation
    public let reason: Reason?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      turnID = try object.decode("turnId")
      currentRunID = try object.decode("currentRunId")
      state = try object.decode("state")
      continuation = try object.decode("continuation")
      reason = try object.optional("reason")
    }
  }

  public struct RunMetadata: Record {
    public let raw: Object
    public let generation: CanonicalID
    public let turnID: CanonicalID
    public let previousRunID: CanonicalID?
    public let phase: Phase
    public let reason: Reason?
    public let continuation: Continuation
    public let submission: Submission?
    public let acceptedAt: Timestamp
    public let startedAt: Timestamp?
    public let settledAt: Timestamp?
    public let effectsUncertain: Bool
    public let lookup: OperationLookup?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.version()
      raw = object.raw
      generation = try object.decode("generation")
      turnID = try object.decode("turnId")
      previousRunID = try object.optional("previousRunId")
      phase = try object.decode("phase")
      reason = try object.optional("reason")
      continuation = try object.decode("continuation")
      submission = try object.submission(required: false)
      acceptedAt = try object.utc("acceptedAt")
      startedAt = try object.optionalUTC("startedAt")
      settledAt = try object.optionalUTC("settledAt")
      effectsUncertain = try object.decode("effectsUncertain")
      lookup = try object.optional("lookup")
    }
  }

  public struct Activity: Record {
    public let raw: Object
    public let id: String
    public let namespace: [String]
    public let runID: CanonicalID?
    public let turnID: CanonicalID
    public let type: String
    public let payload: Value
    public let state: ActivityState
    public let sourceSeq: JSUInt
    public let effectsUncertain: Bool

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      id = try object.decode("id")
      namespace = try object.decode("namespace")
      state = try object.decode("state")
      if state == .historical {
        runID = try object.optional("runId")
      } else {
        runID = try object.decode(CanonicalID.self, "runId")
      }
      turnID = try object.decode("turnId")
      type = try object.decode("type")
      payload = try object.decode("payload")
      sourceSeq = try object.decode("sourceSeq")
      effectsUncertain = try object.decode("effectsUncertain")
    }
  }

  public struct InputRequested: Record {
    public let raw: Object
    public let interruptID: String
    public let payload: Value

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      interruptID = try object.decode("interruptId")
      payload = try object.decode("payload")
    }
  }

  public struct PendingMetadata: Record {
    public let raw: Object
    public let pausedGeneration: CanonicalID
    public let proposalHash: String
    public let status: PendingStatus
    public let expiresAt: Timestamp?
    /// Owner-private authority; this DTO is never itself a viewer/sync payload.
    public let grant: String?
    public let responseSchema: Object?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.version()
      raw = object.raw
      pausedGeneration = try object.decode("pausedGeneration")
      proposalHash = try object.decode("proposalHash")
      status = try object.decode("status")
      expiresAt = try object.optionalUTC("expiresAt")
      grant = try object.optional("grant")
      responseSchema = try object.optional("responseSchema")
    }
  }

  public struct PendingInput: Record {
    public let raw: Object
    public let namespace: [String]
    public let runID: CanonicalID
    public let turnID: CanonicalID
    public let data: InputRequested
    public let metadata: PendingMetadata

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      namespace = try object.decode("namespace")
      runID = try object.decode("runId")
      turnID = try object.decode("turnId")
      data = try object.decode("data")
      metadata = try object.decode(APB4Envelope<PendingMetadata>.self, "data").b4
    }
  }

  public struct HistoryCoverage: Record {
    public let raw: Object
    public let anchor: String
    public let nextBefore: String?
    public let complete: Bool

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      anchor = try object.decode("anchor")
      guard !anchor.isEmpty else { throw object.invalid("anchor", "History anchor must be nonempty") }
      nextBefore = try object.nullable("nextBefore")
      complete = try object.decode("complete")
    }
  }

  public struct HistoryLineage: Record {
    public let raw: Object
    public let checkpointID: CanonicalID
    public let namespace: [String]
    public let fragmentIndex: JSUInt
    public let parentCheckpointID: CanonicalID?
    public let sourceThreadID: CanonicalID?
    public let sourceCheckpointID: CanonicalID?
    public let originRunID: CanonicalID?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      checkpointID = try object.decode("checkpointId")
      namespace = try object.decode("namespace")
      fragmentIndex = try object.decode("fragmentIndex")
      parentCheckpointID = try object.optional("parentCheckpointId")
      sourceThreadID = try object.optional("sourceThreadId")
      sourceCheckpointID = try object.optional("sourceCheckpointId")
      originRunID = try object.optional("originRunId")
    }
  }

  public struct HistoryMetadata: Record {
    public let raw: Object
    public let generation: CanonicalID
    public let revision: String
    public let namespace: [String]
    public let lineage: HistoryLineage
    public let throughSeq: JSUInt
    public let history: HistoryCoverage
    public let activity: [Activity]

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.version()
      raw = object.raw
      generation = try object.decode("generation")
      revision = try object.decode("revision")
      namespace = try object.decode("namespace")
      lineage = try object.decode("lineage")
      throughSeq = try object.decode("throughSeq")
      history = try object.decode("history")
      activity = try object.decode("activity")
    }
  }

  public struct Maintenance: Record {
    public let raw: Object
    public let operationID: CanonicalID
    public let type: MaintenanceKind
    public let state: MaintenanceState
    public let targetRunID: CanonicalID?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      operationID = try object.decode("operationId")
      type = try object.decode("type")
      state = try object.decode("state")
      targetRunID = try object.optional("targetRunId")
    }
  }

  public struct Retention: Record {
    public let raw: Object
    public let replaySeconds: JSUInt
    public let replayBytes: JSUInt
    public let oldestSeq: JSUInt
    public let latestSeq: JSUInt
    public let receiptSecondsAfterSettlement: JSUInt
    public let resultExpiresAt: Timestamp?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      replaySeconds = try object.decode("replaySeconds")
      replayBytes = try object.decode("replayBytes")
      oldestSeq = try object.decode("oldestSeq")
      latestSeq = try object.decode("latestSeq")
      receiptSecondsAfterSettlement = try object.decode("receiptSecondsAfterSettlement")
      resultExpiresAt = try object.optionalUTC("resultExpiresAt")
    }
  }

  public struct RecoveryCheckpoint: Record {
    public let raw: Object
    public let checkpointID: CanonicalID
    public let namespace: [String]
    public let parentCheckpointID: CanonicalID?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      checkpointID = try object.decode("checkpoint_id")
      namespace = try object.decode("namespace")
      parentCheckpointID = try object.optional("parent_checkpoint_id")
    }
  }

  public struct Recovery: Record {
    public let raw: Object
    public let generation: CanonicalID
    public let throughSeq: JSUInt
    public let eventID: String?
    public let revision: String
    public let checkpoint: RecoveryCheckpoint?
    public let history: HistoryCoverage
    public let turn: TurnSummary?
    public let run: RunSummary?
    public let pending: [PendingInput]
    public let activity: [Activity]
    public let maintenance: Maintenance?
    public let retention: Retention

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.version()
      raw = object.raw
      generation = try object.decode("generation")
      throughSeq = try object.decode("throughSeq")
      eventID = try object.nullable("eventId")
      if throughSeq.rawValue == 0 {
        guard eventID == nil else {
          throw object.invalid("eventId", "Zero recovery boundary requires null eventId")
        }
      } else {
        guard let eventID else {
          throw object.invalid("eventId", "Positive recovery boundary requires eventId")
        }
        try object.eventID(eventID, key: "eventId")
      }
      revision = try object.decode("revision")
      checkpoint = try object.optional("checkpoint")
      history = try object.decode("history")
      turn = try object.nullable("turn")
      run = try object.nullable("run")
      pending = try object.decode("pending")
      activity = try object.decode("activity")
      maintenance = try object.nullable("maintenance")
      retention = try object.decode("retention")
    }
  }

  public struct AgentMetadata: Record {
    public let raw: Object
    public let kind: AgentKind
    public let isDefault: Bool
    public let schemas: Object
    public let limits: Object

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.version()
      raw = object.raw
      kind = try object.decode("kind")
      isDefault = try object.decode("isDefault")
      schemas = try object.decode("schemas")
      limits = try object.decode("limits")
      try APB4AgentContract.schemas(object.nested("schemas"))
      try APB4AgentContract.limits(object.nested("limits"))
    }
  }

  public enum CommandMethod: String, Codable, Sendable {
    case runStart = "run.start"
    case subscriptionSubscribe = "subscription.subscribe"
    case subscriptionUnsubscribe = "subscription.unsubscribe"
    case subscriptionReconnect = "subscription.reconnect"
    case agentGetTree = "agent.getTree"
    case inputRespond = "input.respond"
    case inputInject = "input.inject"
    case stateGet = "state.get"
    case stateListCheckpoints = "state.listCheckpoints"
    case stateFork = "state.fork"
  }

  /// Correlation id is a js_uint, not the operation's metadata.b4.submissionId.
  public struct Command: Record {
    public let raw: Object
    public let id: JSUInt
    public let method: CommandMethod
    public let params: Object

    public init(id: JSUInt, start: RunStartRequest) {
      let parameters = start.params
      self.id = id
      method = .runStart
      params = parameters
      raw = [
        "id": .unsignedInteger(id.rawValue), "method": .string(CommandMethod.runStart.rawValue),
        "params": .object(parameters),
      ]
    }

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      id = try object.decode("id")
      method = try object.decode("method")
      params = try object.decode("params")
    }
  }

  /// The CDDL run.start result is closed and its runId is optional for generic peers.
  public struct RunStartResult: Record {
    public let raw: Object
    public let runID: String?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.closed(["runId"])
      raw = object.raw
      runID = try object.optional("runId")
    }
  }

  public struct ForkResult: Record {
    public let raw: Object
    public let runID: String
    public let threadID: String

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.closed(["runId", "threadId"])
      raw = object.raw
      runID = try object.decode("runId")
      threadID = try object.decode("threadId")
    }
  }

  public struct B4RunStartResult: Record {
    public let raw: Object
    public let runID: CanonicalID

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.closed(["runId"])
      raw = object.raw
      runID = try object.decode("runId")
    }
  }

  public struct ResponseMeta: Record {
    public let raw: Object
    public let appliedThroughSeq: JSUInt?
    public let receipt: Receipt?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      appliedThroughSeq = try object.optional("appliedThroughSeq")
      receipt = try object.optional(APResponseB4.self, "b4")?.receipt
    }
  }

  public struct Success<Result: Codable & Sendable>: Record {
    public let raw: Object
    public let id: JSUInt
    public let result: Result
    public let meta: ResponseMeta?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.constant("type", "success")
      raw = object.raw
      id = try object.decode("id")
      result = try object.decode("result")
      meta = try object.optional("meta")
    }
  }

  public enum ASPErrorCode: String, Codable, Sendable {
    case invalidArgument = "invalid_argument"
    case unknownCommand = "unknown_command"
    case unknownError = "unknown_error"
    case noSuchRun = "no_such_run"
    case noSuchSubscription = "no_such_subscription"
    case noSuchNamespace = "no_such_namespace"
    case noSuchInterrupt = "no_such_interrupt"
    case noSuchCheckpoint = "no_such_checkpoint"
    case permissionDenied = "permission_denied"
    case notSupported = "not_supported"
  }

  public struct ASPError: Record {
    public let raw: Object
    public let id: JSUInt?
    public let error: ASPErrorCode
    public let message: String
    public let stacktrace: String?
    public let meta: ResponseMeta?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.constant("type", "error")
      raw = object.raw
      id = try object.nullable("id")
      error = try object.decode("error")
      message = try object.decode("message")
      stacktrace = try object.optional("stacktrace")
      meta = try object.optional("meta")
    }
  }

  /// OpenAPI's generic error fields are optional. HTTP status remains a transport concern.
  public struct HTTPError: Record {
    public let raw: Object
    public let code: String?
    public let message: String?
    public let metadata: Object?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      raw = object.raw
      code = try object.optional("code")
      message = try object.optional("message")
      metadata = try object.optional("metadata")
    }
  }

  public struct EventCorrelation: Record {
    public let raw: Object
    public let generation: CanonicalID
    public let runID: CanonicalID?
    public let turnID: CanonicalID?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.version()
      raw = object.raw
      generation = try object.decode("generation")
      runID = try object.optional("runId")
      turnID = try object.optional("turnId")
      if runID == nil, turnID != nil {
        throw object.invalid("runId", "Run and turn correlation must appear together")
      }
      if runID != nil, turnID == nil {
        throw object.invalid("turnId", "Run and turn correlation must appear together")
      }
    }
  }

  public struct SnapshotDelivery: Record {
    public let raw: Object
    public let generation: CanonicalID
    public let throughSeq: JSUInt

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.version()
      try object.constant("delivery", "snapshot")
      raw = object.raw
      generation = try object.decode("generation")
      throughSeq = try object.decode("throughSeq")
    }
  }

  /// Generic events may omit journal identity. SnapshotEvent never invents one.
  public struct Event: Record {
    public let raw: Object
    public let method: String
    public let params: Object
    public let eventID: String?
    public let seq: JSUInt?
    public let correlation: EventCorrelation?

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.constant("type", "event")
      raw = object.raw
      method = try object.decode("method")
      params = try object.decode("params")
      eventID = try object.optional("eventId")
      seq = try object.optional("seq")
      // The snapshot carrier shares only version/generation with journal correlation.
      if let b4 = try object.optional(APEventB4.self, "b4") {
        correlation = b4.correlation
      } else {
        correlation = nil
      }
    }
  }

  public struct SnapshotEvent: Record {
    public let raw: Object
    public let event: Event
    public let delivery: SnapshotDelivery

    public init(from decoder: Decoder) throws {
      let object = try APObject(decoder)
      try object.forbid("seq")
      try object.forbid("eventId")
      try object.constant("method", "values")
      let params = try object.nested("params")
      try params.closed(["namespace", "timestamp", "data"])
      let _: [String] = try params.decode("namespace")
      try params.nonnegativeInteger("timestamp")
      let _: Value = try params.decode("data")
      raw = object.raw
      event = try Event(from: decoder)
      delivery = try object.decode("b4")
    }
  }
}

extension AgentProtocol.Record {
  public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
}

private struct APKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init(_ value: String) { stringValue = value }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { return nil }
}

/// Shared keyed decoding keeps field failures at their original wire coding paths.
private struct APObject {
  let raw: AgentProtocol.Object
  let container: KeyedDecodingContainer<APKey>

  init(_ decoder: Decoder) throws {
    container = try decoder.container(keyedBy: APKey.self)
    raw = try AgentProtocol.Object(from: decoder)
  }

  func decode<T: Decodable>(_ key: String) throws -> T {
    try container.decode(T.self, forKey: APKey(key))
  }

  func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T { try decode(key) }

  func optional<T: Decodable>(_ key: String) throws -> T? {
    guard container.contains(APKey(key)) else { return nil }
    return try decode(key)
  }

  func optional<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? { try optional(key) }

  /// Required key whose schema explicitly permits null, distinct from an omitted optional key.
  func nullable<T: Decodable>(_ key: String) throws -> T? {
    guard container.contains(APKey(key)) else {
      throw DecodingError.keyNotFound(
        APKey(key),
        .init(codingPath: container.codingPath, debugDescription: "Missing required nullable field"))
    }
    return try container.decodeIfPresent(T.self, forKey: APKey(key))
  }

  func nested(_ key: String) throws -> APObject { try APObject(container.superDecoder(forKey: APKey(key))) }

  func invalid(_ key: String, _ reason: String) -> DecodingError {
    .dataCorrupted(.init(codingPath: container.codingPath + [APKey(key)], debugDescription: reason))
  }

  func version() throws {
    let version: Int = try decode("v")
    guard version == 1 else { throw invalid("v", "Unsupported B4 major version \(version)") }
  }

  func constant(_ key: String, _ expected: String) throws {
    let value: String = try decode(key)
    guard value == expected else { throw invalid(key, "Expected \(expected)") }
  }

  func forbid(_ key: String) throws {
    guard !container.contains(APKey(key)) else { throw invalid(key, "Field is forbidden in this wire shape") }
  }

  func closed(_ keys: Set<String>) throws {
    for key in raw.keys.sorted() where !keys.contains(key) {
      throw invalid(key, "Unexpected field in a closed protocol object")
    }
  }

  func utc(_ key: String) throws -> AgentProtocol.Timestamp {
    let value: AgentProtocol.Timestamp = try decode(key)
    guard value.rawValue.range(of: #"(?:[Zz]|[+]00:00)$"#, options: .regularExpression) != nil else {
      throw invalid(key, "B4 timestamps require UTC")
    }
    return value
  }

  func optionalUTC(_ key: String) throws -> AgentProtocol.Timestamp? {
    guard container.contains(APKey(key)) else { return nil }
    return try utc(key)
  }

  /// AspTimestamp has no JS-safe or UInt64 ceiling; validate the represented number itself.
  func nonnegativeInteger(_ key: String) throws {
    let number: AgentProtocol.Value = try decode(key)
    let valid: Bool
    switch number {
    case .integer(let value): valid = value >= 0
    case .unsignedInteger: valid = true
    case .decimal(var value):
      var rounded = Decimal()
      NSDecimalRound(&rounded, &value, 0, .down)
      valid = value >= 0 && rounded == value
    case .real(let value):
      valid = value.isFinite && value >= 0 && value.rounded(.towardZero) == value
    default: valid = false
    }
    guard valid else { throw invalid(key, "Expected a nonnegative integer") }
  }

  func submission(required: Bool) throws -> AgentProtocol.Submission? {
    let kind: AgentProtocol.SubmissionKind
    if required { kind = try decode("submissionKind") } else { kind = try optional("submissionKind") ?? .b4 }
    if !required, !container.contains(APKey("submissionId")) { return nil }
    switch kind {
    case .b4: return .b4(try decode("submissionId"))
    case .agui: return .agui(try decode("submissionId"))
    }
  }

  func requiredSubmission() throws -> AgentProtocol.Submission {
    guard let submission = try submission(required: true) else {
      throw invalid("submissionId", "Missing required submission identity")
    }
    return submission
  }

  func eventID(_ value: String, key: String) throws {
    guard
      value.range(
        of: #"^b4e1\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[1-9][0-9]*$"#,
        options: .regularExpression) != nil
    else { throw invalid(key, "Expected a B4 journal event identifier") }
  }
}

private struct APContentBlock: Decodable {
  let raw: AgentProtocol.Object
  init(from decoder: Decoder) throws {
    let object = try APObject(decoder)
    let _: String = try object.decode("type")
    let _: AgentProtocol.Object? = try object.optional("metadata")
    raw = object.raw
  }
}

private struct APB4Envelope<Payload: Decodable>: Decodable { let b4: Payload }

private struct APResponseB4: Decodable {
  let receipt: AgentProtocol.Receipt?
  init(from decoder: Decoder) throws {
    let object = try APObject(decoder)
    try object.version()
    receipt = try object.optional("receipt")
    if receipt == nil {
      let _: String = try object.decode("code")
    }
  }
}

private struct APEventB4: Decodable {
  let correlation: AgentProtocol.EventCorrelation?
  init(from decoder: Decoder) throws {
    let object = try APObject(decoder)
    if object.raw["delivery"] == .string("snapshot") {
      _ = try AgentProtocol.SnapshotDelivery(from: decoder)
      correlation = nil
    } else {
      correlation = try AgentProtocol.EventCorrelation(from: decoder)
    }
  }
}

/// Frozen B4Agent wire constraints, separate from the open generic Agent DTO.
/// Validation never turns an absent or unknown optional capability into an advertised value.
private enum APB4AgentContract {
  static func agent(_ object: APObject) throws {
    let capabilities = try object.nested("capabilities")
    for name in ["protocol", "recovery", "permissions", "controls", "agui", "workspace", "store"] {
      let key = "run.b4." + name
      guard capabilities.raw[key] != nil else { continue }
      let capability = try capabilities.nested(key)
      try capability.version()
      switch name {
      case "protocol":
        try capability.constant("openapi", "0.1.6")
        try capability.constant("cddl", "0.0.20")
        try choice(capability, "profile", ["node-sqlite", "node-postgres", "host-reduced"])
        try fields(
          Bool.self, capability, required: ["backgroundRuns", "continueAfterDisconnect", "webhooks"])
        try fields(Bool.self, capability.nested("transports"), required: ["sse", "commands", "websocket"])
      case "recovery":
        for key in ["threadMetadata", "historyMetadata", "eventEnvelope"] {
          try capability.constant(key, "b4")
        }
        try fields(
          AgentProtocol.JSUInt.self, capability,
          required: [
            "replaySeconds", "replayBytes", "resultSecondsAfterTemporaryCleanup",
            "receiptSecondsAfterSettlement",
          ])
      case "permissions":
        try trueFlag(capability, "completeSet")
        let decisions: [String] = try capability.decode("decisions")
        guard decisions == ["once", "always", "deny"] else {
          throw capability.invalid("decisions", "Expected the B4 v1 permission decisions")
        }
        try choice(capability, "grants", ["off", "optional", "required"])
        let _: Bool = try capability.decode("allowAlways")
        let _: AgentProtocol.Object = try capability.decode("responseSchema")
      case "controls":
        try fields(
          Bool.self, capability,
          required: ["injection", "rollback", "stateEdit", "copy", "fork", "systemInjection"])
        try choice(capability, "forkNamespaces", ["root", "declared"])
        try fields(Bool.self, capability.nested("resume"), required: ["update", "goto", "config"])
      case "agui":
        let _: String = try capability.decode("path")
        try native(capability.nested("capabilities"))
      case "workspace":
        try fields(Bool.self, capability, required: ["inspect", "staging"])
      case "store":
        try fields(Bool.self, capability, required: ["generic", "managedMemory", "approval"])
        try trueFlag(capability, "conditionalWrites")
      default: break
      }
    }

    let metadata = try object.nested("metadata").nested("b4")
    let schemas = try metadata.nested("schemas")
    let limits = try metadata.nested("limits")
    let controls = capabilities.raw["run.b4.controls"]
    if controls?["injection"] == .bool(true) {
      let _: AgentProtocol.Object = try schemas.decode("injectionInput")
      let _: AgentProtocol.Object = try limits.decode("inbox")
    }
    if controls?["stateEdit"] == .bool(true) {
      let _: AgentProtocol.Object = try schemas.decode("stateEdit")
    }
    for (flag, schema) in [("update", "resumeUpdate"), ("goto", "resumeGoto"), ("config", "resumeConfig")] {
      if controls?["resume"]?[flag] == .bool(true) {
        let _: AgentProtocol.Object = try schemas.decode(schema)
      }
    }
    let transports = capabilities.raw["run.b4.protocol"]?["transports"]
    if transports?["sse"] == .bool(true) || transports?["websocket"] == .bool(true) {
      let _: AgentProtocol.Object = try limits.decode("viewer")
    }
    let workspace = capabilities.raw["run.b4.workspace"]
    if workspace?["inspect"] == .bool(true) {
      let _: AgentProtocol.Object = try limits.decode("inspection")
    }
    if workspace?["staging"] == .bool(true) {
      let _: AgentProtocol.Object = try limits.decode("staging")
    }
    if capabilities.raw["run.b4.recovery"] != nil {
      let _: AgentProtocol.Object = try schemas.decode("recovery")
    }
  }

  static func schemas(_ object: APObject) throws {
    try fields(
      AgentProtocol.Object.self, object,
      optional: ["injectionInput", "stateEdit", "resumeUpdate", "resumeGoto", "resumeConfig", "recovery"])
    if object.raw["custom"] != nil {
      let custom = try object.nested("custom")
      try fields(AgentProtocol.Object.self, custom, required: custom.raw.keys.sorted())
    }
  }

  static func limits(_ object: APObject) throws {
    try fields(
      AgentProtocol.JSUInt.self, object, required: ["requestBytes", "pendingPrompts"],
      optional: ["snapshotBytes", "eventBytes"])
    for (key, keys) in [
      ("inbox", ["entries", "bytes", "textBytes"]),
      ("viewer", ["events", "bytes"]),
      ("staging", ["uploadBytes", "quotaBytes", "deadlineMs"]),
    ] where object.raw[key] != nil {
      try fields(AgentProtocol.JSUInt.self, object.nested(key), required: keys)
    }
    if object.raw["inspection"] != nil {
      let inspection = try object.nested("inspection")
      try fields(AgentProtocol.JSUInt.self, inspection, required: ["requestBytes", "responseBytes"])
      for key in ["defaults", "caps"] {
        try fields(
          AgentProtocol.JSUInt.self, inspection.nested(key),
          required: ["maxEntries", "maxFileBytes", "maxTotalBytes"])
      }
    }
  }

  static func native(_ object: APObject) throws {
    try object.closed([
      "identity", "transport", "tools", "output", "state", "multiAgent", "reasoning",
      "multimodal", "execution", "humanInTheLoop", "custom",
    ])
    let _: AgentProtocol.Object? = try object.optional("custom")
    if object.raw["identity"] != nil {
      let identity = try object.nested("identity")
      try identity.closed([
        "name", "description", "type", "version", "provider", "documentationUrl", "metadata",
      ])
      try fields(
        String.self, identity,
        optional: ["name", "description", "type", "version", "provider", "documentationUrl"])
      let _: AgentProtocol.Object? = try identity.optional("metadata")
    }
    for (key, flags) in [
      ("transport", ["streaming", "websocket", "httpBinary", "pushNotifications", "resumable"]),
      ("state", ["snapshots", "deltas", "memory", "persistentState"]),
      ("reasoning", ["supported", "streaming", "encrypted"]),
      (
        "humanInTheLoop",
        ["supported", "approvals", "interventions", "feedback", "interrupts", "approveWithEdits"]
      ),
    ] where object.raw[key] != nil {
      let group = try object.nested(key)
      try group.closed(Set(flags))
      try fields(Bool.self, group, optional: flags)
    }
    if object.raw["tools"] != nil {
      let tools = try object.nested("tools")
      try tools.closed(["supported", "items", "parallelCalls", "clientProvided"])
      try fields(Bool.self, tools, optional: ["supported", "parallelCalls", "clientProvided"])
      let _: [APNativeTool]? = try tools.optional("items")
    }
    if object.raw["output"] != nil {
      let output = try object.nested("output")
      try output.closed(["structuredOutput", "supportedMimeTypes"])
      let _: Bool? = try output.optional("structuredOutput")
      let _: [String]? = try output.optional("supportedMimeTypes")
    }
    if object.raw["multiAgent"] != nil {
      let multi = try object.nested("multiAgent")
      try multi.closed(["supported", "delegation", "handoffs", "subagents"])
      try fields(Bool.self, multi, optional: ["supported", "delegation", "handoffs"])
      let _: [APNativeSubagent]? = try multi.optional("subagents")
    }
    if object.raw["multimodal"] != nil {
      let multimodal = try object.nested("multimodal")
      try multimodal.closed(["input", "output"])
      for (key, flags) in [
        ("input", ["image", "audio", "video", "pdf", "file"]), ("output", ["image", "audio"]),
      ]
      where multimodal.raw[key] != nil {
        let group = try multimodal.nested(key)
        try group.closed(Set(flags))
        try fields(Bool.self, group, optional: flags)
      }
    }
    if object.raw["execution"] != nil {
      let execution = try object.nested("execution")
      try execution.closed(["codeExecution", "sandboxed", "maxIterations", "maxExecutionTime"])
      try fields(Bool.self, execution, optional: ["codeExecution", "sandboxed"])
      try fields(AgentProtocol.JSUInt.self, execution, optional: ["maxIterations", "maxExecutionTime"])
    }
  }

  static func nativeTool(_ object: APObject) throws {
    try object.closed(["name", "description", "parameters", "metadata"])
    try fields(String.self, object, required: ["name", "description"])
    let _: AgentProtocol.Object? = try object.optional("metadata")
    if object.raw["parameters"] == .null {
      throw object.invalid("parameters", "Native tool parameters cannot be null")
    }
  }

  static func nativeSubagent(_ object: APObject) throws {
    try object.closed(["name", "description"])
    try fields(String.self, object, required: ["name"], optional: ["description"])
  }

  private static func fields<T: Decodable>(
    _ type: T.Type, _ object: APObject, required: [String] = [], optional: [String] = []
  ) throws {
    for key in required { let _: T = try object.decode(key) }
    for key in optional { let _: T? = try object.optional(key) }
  }

  private static func choice(_ object: APObject, _ key: String, _ allowed: Set<String>) throws {
    let value: String = try object.decode(key)
    guard allowed.contains(value) else { throw object.invalid(key, "Unknown value in the B4 v1 contract") }
  }

  private static func trueFlag(_ object: APObject, _ key: String) throws {
    let value: Bool = try object.decode(key)
    guard value else { throw object.invalid(key, "Expected true in the B4 v1 contract") }
  }
}

private struct APNativeTool: Decodable {
  init(from decoder: Decoder) throws { try APB4AgentContract.nativeTool(APObject(decoder)) }
}

private struct APNativeSubagent: Decodable {
  init(from decoder: Decoder) throws { try APB4AgentContract.nativeSubagent(APObject(decoder)) }
}
