import Darwin
import Foundation
import Synchronization
import WorkspaceProtocol

/// The handful of libpq entry points the store uses, bound at runtime from the bundled library so
/// the package links against nothing outside the SDK and the client always matches the server
/// (decision D-041). Calls are synchronous by design: the coordinator's actors rely on atomic
/// sequences of store operations.
final class LibPQ: @unchecked Sendable {
  typealias Conn = OpaquePointer
  typealias Result = OpaquePointer

  let connectdb: @convention(c) (UnsafePointer<CChar>) -> Conn?
  let status: @convention(c) (Conn?) -> Int32
  let finish: @convention(c) (Conn?) -> Void
  let errorMessage: @convention(c) (Conn?) -> UnsafePointer<CChar>?
  let exec: @convention(c) (Conn?, UnsafePointer<CChar>) -> Result?
  let execParams:
    @convention(c) (
      Conn?, UnsafePointer<CChar>, Int32, UnsafePointer<UInt32>?, UnsafePointer<UnsafePointer<CChar>?>?,
      UnsafePointer<Int32>?, UnsafePointer<Int32>?, Int32
    ) -> Result?
  let resultStatus: @convention(c) (Result?) -> Int32
  let resultErrorMessage: @convention(c) (Result?) -> UnsafePointer<CChar>?
  let resultErrorField: @convention(c) (Result?, Int32) -> UnsafePointer<CChar>?
  let ntuples: @convention(c) (Result?) -> Int32
  let nfields: @convention(c) (Result?) -> Int32
  let fname: @convention(c) (Result?, Int32) -> UnsafePointer<CChar>?
  let ftype: @convention(c) (Result?, Int32) -> UInt32
  let getvalue: @convention(c) (Result?, Int32, Int32) -> UnsafePointer<CChar>?
  let getisnull: @convention(c) (Result?, Int32, Int32) -> Int32
  let cmdTuples: @convention(c) (Result?) -> UnsafePointer<CChar>?
  let clear: @convention(c) (Result?) -> Void

  static let connectionOK: Int32 = 0
  static let commandOK: Int32 = 1
  static let tuplesOK: Int32 = 2
  /// `PG_DIAG_SQLSTATE` for `PQresultErrorField`.
  static let sqlStateField: Int32 = 67

  private static let cache = Mutex<[String: LibPQ]>([:])

  /// Loads `libpq.5.dylib` from the bundled `lib` directory beside the server binaries.
  static func load(binDir: String) throws -> LibPQ {
    let libDir = (binDir as NSString).deletingLastPathComponent + "/lib"
    let path = libDir + "/libpq.5.dylib"
    if let cached = cache.withLock({ $0[path] }) { return cached }
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      throw WorkspaceError(.missingExecutable, "Cannot load libpq at \(path): \(String(cString: dlerror()))")
    }
    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
      guard let pointer = dlsym(handle, name) else {
        throw WorkspaceError(.missingExecutable, "libpq at \(path) lacks \(name)")
      }
      return unsafeBitCast(pointer, to: type)
    }
    let lib = LibPQ(
      connectdb: try symbol("PQconnectdb", as: (@convention(c) (UnsafePointer<CChar>) -> Conn?).self),
      status: try symbol("PQstatus", as: (@convention(c) (Conn?) -> Int32).self),
      finish: try symbol("PQfinish", as: (@convention(c) (Conn?) -> Void).self),
      errorMessage: try symbol("PQerrorMessage", as: (@convention(c) (Conn?) -> UnsafePointer<CChar>?).self),
      exec: try symbol("PQexec", as: (@convention(c) (Conn?, UnsafePointer<CChar>) -> Result?).self),
      execParams: try symbol(
        "PQexecParams",
        as: (@convention(c) (
          Conn?, UnsafePointer<CChar>, Int32, UnsafePointer<UInt32>?, UnsafePointer<UnsafePointer<CChar>?>?,
          UnsafePointer<Int32>?, UnsafePointer<Int32>?, Int32
        ) -> Result?).self),
      resultStatus: try symbol("PQresultStatus", as: (@convention(c) (Result?) -> Int32).self),
      resultErrorMessage: try symbol(
        "PQresultErrorMessage", as: (@convention(c) (Result?) -> UnsafePointer<CChar>?).self),
      resultErrorField: try symbol(
        "PQresultErrorField", as: (@convention(c) (Result?, Int32) -> UnsafePointer<CChar>?).self),
      ntuples: try symbol("PQntuples", as: (@convention(c) (Result?) -> Int32).self),
      nfields: try symbol("PQnfields", as: (@convention(c) (Result?) -> Int32).self),
      fname: try symbol("PQfname", as: (@convention(c) (Result?, Int32) -> UnsafePointer<CChar>?).self),
      ftype: try symbol("PQftype", as: (@convention(c) (Result?, Int32) -> UInt32).self),
      getvalue: try symbol(
        "PQgetvalue", as: (@convention(c) (Result?, Int32, Int32) -> UnsafePointer<CChar>?).self),
      getisnull: try symbol("PQgetisnull", as: (@convention(c) (Result?, Int32, Int32) -> Int32).self),
      cmdTuples: try symbol("PQcmdTuples", as: (@convention(c) (Result?) -> UnsafePointer<CChar>?).self),
      clear: try symbol("PQclear", as: (@convention(c) (Result?) -> Void).self))
    cache.withLock { $0[path] = lib }
    return lib
  }

  private init(
    connectdb: @escaping @convention(c) (UnsafePointer<CChar>) -> Conn?,
    status: @escaping @convention(c) (Conn?) -> Int32,
    finish: @escaping @convention(c) (Conn?) -> Void,
    errorMessage: @escaping @convention(c) (Conn?) -> UnsafePointer<CChar>?,
    exec: @escaping @convention(c) (Conn?, UnsafePointer<CChar>) -> Result?,
    execParams:
      @escaping @convention(c) (
        Conn?, UnsafePointer<CChar>, Int32, UnsafePointer<UInt32>?, UnsafePointer<UnsafePointer<CChar>?>?,
        UnsafePointer<Int32>?, UnsafePointer<Int32>?, Int32
      ) -> Result?,
    resultStatus: @escaping @convention(c) (Result?) -> Int32,
    resultErrorMessage: @escaping @convention(c) (Result?) -> UnsafePointer<CChar>?,
    resultErrorField: @escaping @convention(c) (Result?, Int32) -> UnsafePointer<CChar>?,
    ntuples: @escaping @convention(c) (Result?) -> Int32,
    nfields: @escaping @convention(c) (Result?) -> Int32,
    fname: @escaping @convention(c) (Result?, Int32) -> UnsafePointer<CChar>?,
    ftype: @escaping @convention(c) (Result?, Int32) -> UInt32,
    getvalue: @escaping @convention(c) (Result?, Int32, Int32) -> UnsafePointer<CChar>?,
    getisnull: @escaping @convention(c) (Result?, Int32, Int32) -> Int32,
    cmdTuples: @escaping @convention(c) (Result?) -> UnsafePointer<CChar>?,
    clear: @escaping @convention(c) (Result?) -> Void
  ) {
    self.connectdb = connectdb
    self.status = status
    self.finish = finish
    self.errorMessage = errorMessage
    self.exec = exec
    self.execParams = execParams
    self.resultStatus = resultStatus
    self.resultErrorMessage = resultErrorMessage
    self.resultErrorField = resultErrorField
    self.ntuples = ntuples
    self.nfields = nfields
    self.fname = fname
    self.ftype = ftype
    self.getvalue = getvalue
    self.getisnull = getisnull
    self.cmdTuples = cmdTuples
    self.clear = clear
  }
}
