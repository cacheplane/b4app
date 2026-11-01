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
