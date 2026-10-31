import ArgumentParser
import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// `db status | migrate | backup | restore | import-sqlite` (M7, D-041). The CLI never opens the
/// store; every command goes through the coordinator, which is the only process that does.
struct DatabaseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "db", abstract: "Inspect, back up, restore, or import the coordinator's store.",
    subcommands: [Status.self, Migrate.self, Backup.self, Restore.self, ImportSQLite.self])

  static func describe(_ status: DatabaseStatus.Result) -> String {
    var lines = ["store      \(status.endpoint)"]
    if let dataDir = status.dataDir { lines.append("cluster    \(dataDir)") }
    lines.append("schema     \(status.migrations.joined(separator: ", "))")
    let rows = status.rows.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    lines.append("rows       \(rows)")
    lines.append("unsynced   \(status.unsyncedChanges) change(s)")
    lines.append("backups    \(status.backupsDir)")
    return lines.joined(separator: "\n")
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the store's location, schema, and row counts.")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
      do {
        let client = try await Link.open()
        let status = try await client.request(DatabaseStatus.self, EmptyParams())
        await client.close()
        print(global.json ? try Format.jsonOk(status) : DatabaseCommand.describe(status))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Migrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Confirm the schema is current. Migrations run when the coordinator starts; this reports them.")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
      do {
        let client = try await Link.open()
        let status = try await client.request(DatabaseStatus.self, EmptyParams())
        await client.close()
        if global.json {
          print(try Format.jsonOk(["migrations": status.migrations]))
        } else {
          print("schema is current: \(status.migrations.joined(separator: ", "))")
        }
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Write every table to a JSON-lines archive (default: the data directory's backups folder).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Where to write the archive.") var path: String?
    func run() async throws {
      do {
        let client = try await Link.open()
        let result = try await client.request(
          DatabaseBackup.self, DatabaseBackup.Params(path: path),
          options: Link.mutation(timeout: .seconds(300)))
        await client.close()
        print(global.json ? try Format.jsonOk(result) : "wrote \(result.rows) row(s) to \(result.path)")
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Load an archive into an empty store; --replace overwrites the current contents.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The archive written by `db backup`.") var path: String
    @Flag(name: .long, help: "Clear every table first.") var replace = false
    func run() async throws {
      do {
        let client = try await Link.open()
        let result = try await client.request(
          DatabaseRestore.self, DatabaseRestore.Params(path: path, replace: replace),
          options: Link.mutation(timeout: .seconds(300)))
        await client.close()
        print(global.json ? try Format.jsonOk(result) : "restored \(result.rows) row(s) from \(result.path)")
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct ImportSQLite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "import-sqlite", abstract: "Import a pre-0.2 workspace.sqlite into an empty store.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The SQLite file.") var path: String
    func run() async throws {
      do {
        let client = try await Link.open()
        let result = try await client.request(
          DatabaseImportSQLite.self, DatabaseImportSQLite.Params(path: path),
          options: Link.mutation(timeout: .seconds(300)))
        await client.close()
        if global.json {
          print(try Format.jsonOk(result))
        } else {
          let rows = result.rows.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
            separator: " ")
          print(rows.isEmpty ? "nothing imported (the store already holds data)" : "imported \(rows)")
        }
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }
}
