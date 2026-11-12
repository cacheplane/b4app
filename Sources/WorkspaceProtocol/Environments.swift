import Foundation

/// A folder that belongs to exactly one environment. `path` is a `SessionService.canonicalDirectory` form.
public struct EnvironmentFolder: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var environmentId: String
  public var path: String
  public var createdAt: String

  public init(id: String, environmentId: String, path: String, createdAt: String = Timestamp.now()) {
    self.id = id
    self.environmentId = environmentId
    self.path = path
    self.createdAt = createdAt
  }
}

/// A named group of threads. An empty `name` displays as the last component of its oldest folder.
public struct WorkEnvironment: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  /// True when a person created the environment; false when the backfill derived it from a folder.
  public var manual: Bool
  public var createdAt: String
  public var updatedAt: String
  /// Filled on read, oldest first; never a column of `environments`.
  public var folders: [EnvironmentFolder]
  /// The device id of the Mac that owns the environment (the one whose folders it lists), from the phone's
  /// mirror; nil on the Mac. A new thread from the phone goes to this Mac (M8c).
  public var ownerDeviceId: String?

  public init(
    id: String, name: String = "", manual: Bool = false, createdAt: String = Timestamp.now(),
    updatedAt: String = Timestamp.now(), folders: [EnvironmentFolder] = [], ownerDeviceId: String? = nil
  ) {
    self.id = id
    self.name = name
    self.manual = manual
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.folders = folders
    self.ownerDeviceId = ownerDeviceId
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    manual = try c.decode(Bool.self, forKey: .manual)
    createdAt = try c.decode(String.self, forKey: .createdAt)
    updatedAt = try c.decode(String.self, forKey: .updatedAt)
    folders = try c.decodeIfPresent([EnvironmentFolder].self, forKey: .folders) ?? []
    ownerDeviceId = try c.decodeIfPresent(String.self, forKey: .ownerDeviceId)
  }

  /// `name` when it is not empty, else the last path component of the oldest folder, else
  /// "Untitled environment". Computed on read; never stored or encoded.
  public var displayName: String {
    if !name.isEmpty { return name }
    let oldest = folders.min { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    if let path = oldest?.path {
      let last = URL(fileURLWithPath: path).lastPathComponent
      if !last.isEmpty, last != "/" { return last }
    }
    return "Untitled environment"
  }
}

// MARK: - Commands

/// Every environment with its folders and `displayName` resolved, oldest first.
public enum EnvironmentList: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var environments: [WorkEnvironment]
    public init(environments: [WorkEnvironment]) { self.environments = environments }
  }
  public static let method = Method.environmentList
}

/// Create a manual environment over one or more existing folders. A folder that belongs to another
/// environment moves out of it (its threads follow, and an environment left empty is deleted; D-212).
///
/// The phone sends it over the relay: `deviceId` names the Mac the folders are on (the hub routes by
/// it; the Mac ignores it), and `environmentId` is a lowercase UUID the phone mints, so a resend of the
/// same create finds the environment the first one made instead of making another. Without `environmentId`
/// the coordinator mints one.
public enum EnvironmentCreate: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var name: String
    public var folders: [String]
    public var environmentId: String?
    public var deviceId: String?
    public init(name: String, folders: [String], environmentId: String? = nil, deviceId: String? = nil) {
      self.name = name
      self.folders = folders
      self.environmentId = environmentId
      self.deviceId = deviceId
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var environment: WorkEnvironment
    public init(environment: WorkEnvironment) { self.environment = environment }
  }
  public static let method = Method.environmentCreate
}

/// Rename an environment and add or remove folders in one call. A folder another environment owns moves here
/// with its threads, and an environment that leaves empty is deleted; a removed folder's threads get an
/// automatic environment of their own; the environment keeps at least one folder. Adding a folder makes the
/// environment manual. Every folder is validated before anything changes (D-212).
public enum EnvironmentUpdate: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var environmentId: String
    public var name: String?
    public var addFolders: [String]?
    public var removeFolders: [String]?
    public init(
      environmentId: String, name: String? = nil, addFolders: [String]? = nil, removeFolders: [String]? = nil
    ) {
      self.environmentId = environmentId
      self.name = name
      self.addFolders = addFolders
      self.removeFolders = removeFolders
    }
  }
  public typealias Result = EnvironmentCreate.Result
  public static let method = Method.environmentUpdate
}

/// The rename both devices can do. The empty string restores the folder-name display.
public enum EnvironmentRename: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var environmentId: String
    public var name: String
    public init(environmentId: String, name: String) {
      self.environmentId = environmentId
      self.name = name
    }
  }
  public typealias Result = EnvironmentCreate.Result
  public static let method = Method.environmentRename
}

/// Delete an environment, automatic or manual. Its threads move to "No folder" and stay there; nothing on
/// disk is touched (D-212).
public enum EnvironmentDelete: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var environmentId: String
    public init(environmentId: String) { self.environmentId = environmentId }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var environmentId: String
    public init(environmentId: String) { self.environmentId = environmentId }
  }
  public static let method = Method.environmentDelete
}

/// Mark a thread read up to `turnId`, or unread again with nil. The write happens only when `turnId`
/// is a terminal turn of the thread no older than the one already marked.
public enum ThreadMarkRead: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public var turnId: String?
    public init(threadId: String, turnId: String? = nil) {
      self.threadId = threadId
      self.turnId = turnId
    }
  }
  public typealias Result = ThreadCreate.Result
  public static let method = Method.threadMarkRead
}
