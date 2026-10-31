import Foundation
import os

public enum CoordinatorVersion {
  public static let current = "0.0.0"
}

/// One logging subsystem for every process; categories per component.
public enum Log {
  public static let subsystem = "com.cacheplane.b4app"
  public static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }
}
