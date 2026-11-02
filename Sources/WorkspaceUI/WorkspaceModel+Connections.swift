import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// A connection check that has said which try it is on ("try 2 of 3").
public struct ConnectionCheck: Sendable, Equatable {
  public var attempt: Int
  public var attempts: Int

  public init(attempt: Int, attempts: Int) {
    self.attempt = attempt
    self.attempts = attempts
  }
}

/// Usage, checks, and adding or editing connections (settings connections design).
extension WorkspaceModel {
  /// Every connection's usage from the coordinator. The phone's mirror has none: usage stays on the
  /// Mac, so a refused or failed read leaves the dictionary as it was.
  public func refreshUsage() async {
    guard let client, let result = try? await client.request(UsageRead.self, EmptyParams()) else { return }
    usage = Dictionary(result.usage.map { ($0.connectionId, $0) }, uniquingKeysWith: { _, new in new })
  }

  /// Attach a B4 endpoint. A key is stored first with `credential.add`, so only its `secret:` reference
  /// reaches the connection; the caller clears its field when this returns.
  @discardableResult
  public func addB4Connection(
    label: String?, url: String, route: String, apiKey: String?
  ) async -> Connection? {
    let name = label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    var reference: String?
    if let apiKey, !apiKey.isEmpty {
      reference = await storeKey(apiKey, label: name ?? URL(string: url)?.host ?? "B4 endpoint")
      guard reference != nil else { return nil }
    }
    let added = await addConnection(kind: .b4, label: name, url: url, route: route, authReference: reference)
    if added == nil, let reference { await takeBackKey(reference) }
    return added
  }

  /// Rename a connection and, for B4, replace or remove its key. Returns whether the change was made.
  @discardableResult
  public func updateConnection(id: String, label: String?, apiKey: String?, clearKey: Bool) async -> Bool {
    var reference: String?
    if let apiKey, !apiKey.isEmpty {
      let name = connections.first { $0.id == id }?.label ?? "B4 endpoint"
      reference = await storeKey(apiKey, label: name)
      guard reference != nil else { return false }
    }
    let updated = await perform {
      try await $0.request(
        ConnectionUpdate.self,
        ConnectionUpdate.Params(
          connectionId: id, label: label, authReference: reference, clearAuth: clearKey ? true : nil),
        options: Self.mutation(timeout: .seconds(60))
      ).connection
    }
    guard let updated else {
      if let reference { await takeBackKey(reference) }
      return false
    }
    merge(updated)
    return true
  }

  /// A check nobody waits for (the Connections page opening): the coordinator answers at once and
  /// reports through events, and the model is never marked busy, so sending and approvals stay free.
  /// A connection checked in the last two minutes is left alone. Returns whether a check was asked for.
  @discardableResult
  public func checkInBackground(id: String) async -> Bool {
    guard let client else { return false }
    if let last = lastChecked[id], Date().timeIntervalSince(last) < 120 { return false }
    lastChecked[id] = Date()
    _ = try? await client.request(
      ConnectionInspect.self, ConnectionInspect.Params(connectionId: id, background: true),
      options: Self.mutation())
    return true
  }

  /// Check a connection again; progress arrives as `checks`, the result as the connection's status.
  public func checkConnection(id: String) async {
    await inspectConnection(id: id)
    await refreshUsage()
  }

  /// Delete a key stored for an add or edit that then failed, so no Keychain item is left with no
  /// connection. Quiet: the failure the person sees is the add's or the edit's.
  private func takeBackKey(_ reference: String) async {
    _ = try? await client?.request(
      CredentialRemove.self, CredentialRemove.Params(reference: reference), options: Self.mutation())
  }

  private func storeKey(_ value: String, label: String) async -> String? {
    await perform {
      try await $0.request(
        CredentialAdd.self, CredentialAdd.Params(label: label, value: value), options: Self.mutation()
      ).reference
    }
  }

  func noteCheck(_ event: AdapterEvent) {
    if let attempt = event.payload["attempt"]?.numberValue,
      let attempts = event.payload["attempts"]?.numberValue
    {
      checks[event.connectionId] = ConnectionCheck(attempt: Int(attempt), attempts: Int(attempts))
    } else {
      checks[event.connectionId] = nil
    }
  }

  func applyUsage(_ event: AdapterEvent) {
    guard let reading = try? event.payload["reading"]?.decode(UsageReading.self) else { return }
    var entry = usage[event.connectionId] ?? ConnectionUsage(connectionId: event.connectionId)
    entry.reading = reading
    usage[event.connectionId] = entry
  }
}
