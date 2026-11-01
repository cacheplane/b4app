import Foundation

/// A folder that belongs to exactly one project. `path` is a `SessionService.canonicalDirectory` form.
public struct ProjectFolder: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var projectId: String
  public var path: String
  public var createdAt: String

  public init(id: String, projectId: String, path: String, createdAt: String = Timestamp.now()) {
    self.id = id
    self.projectId = projectId
    self.path = path
    self.createdAt = createdAt
  }
}

/// A named group of threads. An empty `name` displays as the last component of its oldest folder.
public struct Project: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  /// True when a person created the project; false when the backfill derived it from a folder.
  public var manual: Bool
  public var createdAt: String
  public var updatedAt: String
  /// Filled on read, oldest first; never a column of `projects`.
  public var folders: [ProjectFolder]

  public init(
    id: String, name: String = "", manual: Bool = false, createdAt: String = Timestamp.now(),
    updatedAt: String = Timestamp.now(), folders: [ProjectFolder] = []
  ) {
    self.id = id
    self.name = name
    self.manual = manual
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.folders = folders
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    manual = try c.decode(Bool.self, forKey: .manual)
    createdAt = try c.decode(String.self, forKey: .createdAt)
    updatedAt = try c.decode(String.self, forKey: .updatedAt)
    folders = try c.decodeIfPresent([ProjectFolder].self, forKey: .folders) ?? []
  }

  /// `name` when it is not empty, else the last path component of the oldest folder, else
  /// "Untitled project". Computed on read; never stored or encoded.
  public var displayName: String {
    if !name.isEmpty { return name }
    let oldest = folders.min { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    if let path = oldest?.path {
      let last = URL(fileURLWithPath: path).lastPathComponent
      if !last.isEmpty, last != "/" { return last }
    }
    return "Untitled project"
  }
}

// MARK: - Commands

/// Every project with its folders and `displayName` resolved, oldest first.
public enum ProjectList: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var projects: [Project]
    public init(projects: [Project]) { self.projects = projects }
  }
  public static let method = Method.projectList
}

/// Create a manual project over one or more existing folders. A folder that belongs to an automatic
/// project moves out of it (its threads follow, and an automatic project left empty is deleted); a
/// folder of another manual project is refused.
public enum ProjectCreate: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var name: String
    public var folders: [String]
    public init(name: String, folders: [String]) {
      self.name = name
      self.folders = folders
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var project: Project
    public init(project: Project) { self.project = project }
  }
  public static let method = Method.projectCreate
}

/// Rename a project and add or remove folders in one call. Adding a folder to an automatic project
/// makes it manual. Every folder is validated before anything changes.
public enum ProjectUpdate: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var projectId: String
    public var name: String?
    public var addFolders: [String]?
    public var removeFolders: [String]?
    public init(
      projectId: String, name: String? = nil, addFolders: [String]? = nil, removeFolders: [String]? = nil
    ) {
      self.projectId = projectId
      self.name = name
      self.addFolders = addFolders
      self.removeFolders = removeFolders
    }
  }
  public typealias Result = ProjectCreate.Result
  public static let method = Method.projectUpdate
}

/// The rename both devices can do. The empty string restores the folder-name display.
public enum ProjectRename: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var projectId: String
    public var name: String
    public init(projectId: String, name: String) {
      self.projectId = projectId
      self.name = name
    }
  }
  public typealias Result = ProjectCreate.Result
  public static let method = Method.projectRename
}

/// Delete a manual project; its folders return to automatic projects where threads use them.
public enum ProjectDelete: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var projectId: String
    public init(projectId: String) { self.projectId = projectId }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var projectId: String
    public init(projectId: String) { self.projectId = projectId }
  }
  public static let method = Method.projectDelete
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
