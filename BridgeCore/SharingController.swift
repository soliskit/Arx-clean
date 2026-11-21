//
//  SharingController.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

@MainActor public final class SharingController {
  struct Client {
    var info: ClientInfo
    var pairingHash: String?
    var pairingExpiry: Date
    var sessionHash: String?
    var csrf: String?
    var issued: Date?
    var lastSeen: Date?
    var revision: UInt64 = 0
    var operations: [UUID: (Data, SharedReminder?)] = [:]
    var uncertain: Set<UUID> = []
  }
  public let store: any ReminderStore
  public private(set) var running = false
  private var clients: [UUID: Client] = [:]
  private var failedPairings: [Date] = []
  private let clock: @Sendable () -> Date
  private let credentialDigest: (String) -> String
  public convenience init(
    store: any ReminderStore, clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(store: store, clock: clock, credentialDigest: Self.digest)
  }
  init(
    store: any ReminderStore, clock: @escaping @Sendable () -> Date = { Date() },
    credentialDigest: @escaping (String) -> String
  ) {
    self.store = store
    self.clock = clock
    self.credentialDigest = credentialDigest
  }
  public var clientInfo: [ClientInfo] {
    prune()
    return clients.values.map(\.info).sorted { $0.label < $1.label }
  }
  public func start() throws {
    guard !running, store.authorized else { throw BridgeFailure.unavailable }
    running = true
  }
  public func stop() {
    running = false
    clients.removeAll()
    failedPairings.removeAll()
  }
  public func revoke(_ id: UUID) { clients.removeValue(forKey: id) }
  public func inventory() throws -> [ReminderList] {
    guard store.authorized else {
      stop()
      throw BridgeFailure.unavailable
    }
    return try store.lists()
  }
  public func pairClient(label: String, rights: ClientRights) throws -> (UUID, String) {
    prune()
    guard running, clients.count < 20, !label.isEmpty, label.count <= 80,
      rights.read || (!rights.manage && !rights.delete),
      rights.lists.isSubset(of: Set(try inventory().map(\.id)))
    else { throw BridgeFailure.invalid }
    let id = UUID()
    let secret = Self.secret(bytes: 16)
    clients[id] = Client(
      info: ClientInfo(id: id, label: label, rights: rights, paired: false),
      pairingHash: Self.digest(secret), pairingExpiry: clock().addingTimeInterval(120))
    return (id, secret)
  }
  public func exchange(_ secret: String) throws -> (token: String, csrf: String) {
    guard running, store.authorized else {
      stop()
      throw BridgeFailure.denied
    }
    let now = clock()
    failedPairings.removeAll { now.timeIntervalSince($0) > 60 }
    // A correct secret is never refused because strangers guessed wrongly first.
    let presented = secret.utf8.count <= 128 ? credentialDigest(secret) : nil
    guard let presented,
      let id = clients.first(where: {
        $0.value.pairingHash == presented && $0.value.pairingExpiry > now
      })?.key, var client = clients[id]
    else {
      guard failedPairings.count < 10 else { throw BridgeFailure.rateLimited }
      failedPairings.append(now)
      throw BridgeFailure.denied
    }
    let token = Self.secret(bytes: 32)
    let csrf = Self.secret(bytes: 32)
    client.pairingHash = nil
    client.sessionHash = Self.digest(token)
    client.csrf = csrf
    client.issued = now
    client.lastSeen = now
    client.info.paired = true
    clients[id] = client
    return (token, csrf)
  }
  /// Drops pairings that expired unused and sessions past their idle or absolute limit.
  private func prune() {
    let now = clock()
    clients = clients.filter { _, client in
      guard client.info.paired else { return client.pairingExpiry > now }
      guard let issued = client.issued, let seen = client.lastSeen else { return false }
      return now.timeIntervalSince(issued) < 86_400 && now.timeIntervalSince(seen) < 1800
    }
  }
  /// Validates client identity without opening or authorizing provider data.
  /// Mutation envelopes use this before collecting a potentially large body.
  public func authorizeMutationEnvelope(_ token: String, csrf: String) throws {
    _ = try identity(token, csrf: csrf)
  }
  private func identity(_ token: String, csrf: String? = nil) throws -> UUID {
    guard running, token.utf8.count <= 128 else { throw BridgeFailure.denied }
    let presented = credentialDigest(token)
    let now = clock()
    guard let id = clients.first(where: { $0.value.sessionHash == presented })?.key,
      let client = clients[id], let issued = client.issued, let seen = client.lastSeen,
      now.timeIntervalSince(issued) < 86_400, now.timeIntervalSince(seen) < 1800,
      csrf == nil || csrf == client.csrf
    else { throw BridgeFailure.denied }
    return id
  }
  private func session(_ token: String, csrf: String? = nil) throws -> UUID {
    guard running, store.authorized else {
      stop()
      throw BridgeFailure.denied
    }
    let id = try identity(token, csrf: csrf)
    clients[id]!.lastSeen = clock()
    return id
  }
  public func sessionState(_ token: String) throws -> (rights: ClientRights, csrf: String) {
    let id = try session(token)
    return (clients[id]!.info.rights, clients[id]!.csrf!)
  }
  public func sharedLists(_ token: String) throws -> [ReminderList] {
    let id = try session(token)
    let rights = clients[id]!.info.rights
    guard rights.read else { throw BridgeFailure.denied }
    // Never return source/account inventory to a client.
    return try inventory().filter { rights.lists.contains($0.id) }.map {
      ReminderList(id: $0.id, title: $0.title, writable: $0.writable)
    }
  }
  private func require(_ id: UUID, list: String, action: Mutation.Action? = nil) throws -> UInt64 {
    guard running, store.authorized, let c = clients[id], c.info.rights.lists.contains(list),
      try store.lists().contains(where: { $0.id == list })
    else { throw BridgeFailure.denied }
    if let action {
      guard action == .delete ? c.info.rights.delete : c.info.rights.manage,
        try store.lists().contains(where: { $0.id == list && $0.writable })
      else { throw BridgeFailure.denied }
    } else if !c.info.rights.read {
      throw BridgeFailure.denied
    }
    return c.revision
  }
  private var activeReads: Set<UUID> = []
  private let cursorKey = SymmetricKey(size: .bits256)
  private struct Cursor: Codable {
    var client: UUID
    var list: String
    var boundary: String
  }
  private func openCursor(_ value: String?, client: UUID, list: String) throws -> String? {
    guard let value else { return nil }
    guard value.utf8.count <= 8192, let data = Data(base64Encoded: value) else {
      throw BridgeFailure.invalid
    }
    do {
      let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: cursorKey)
      let cursor = try JSONDecoder().decode(Cursor.self, from: bytes)
      guard cursor.client == client, cursor.list == list else { throw BridgeFailure.invalid }
      return cursor.boundary
    } catch { throw BridgeFailure.invalid }
  }
  private func sealCursor(_ boundary: String?, client: UUID, list: String) throws -> String? {
    guard let boundary else { return nil }
    let bytes = try JSONEncoder().encode(Cursor(client: client, list: list, boundary: boundary))
    guard let sealed = try AES.GCM.seal(bytes, using: cursorKey).combined else {
      throw BridgeFailure.unavailable
    }
    return sealed.base64EncodedString()
  }
  public func read(_ token: String, list: String, after: String? = nil, before: String? = nil)
    async throws -> ReminderPage
  {
    let id = try session(token)
    let revision = try require(id, list: list)
    guard after == nil || before == nil else { throw BridgeFailure.invalid }
    let afterID = try openCursor(after, client: id, list: list)
    let beforeID = try openCursor(before, client: id, list: list)
    guard activeReads.count < 4, !activeReads.contains(id) else { throw BridgeFailure.rateLimited }
    activeReads.insert(id)
    defer { activeReads.remove(id) }
    let identifiers = try await store.reminderIDs(in: list)
    _ = try session(token)
    guard try require(id, list: list) == revision else { throw BridgeFailure.denied }
    // EventKit has no paged fetch API. Only identifiers survive its fetch; at
    // most one page is converted to wire snapshots. Cursors are not grants.
    let sorted = Set(identifiers).sorted()
    let candidates = sorted.filter { key in
      (afterID == nil || key > afterID!) && (beforeID == nil || key < beforeID!)
    }
    // A concurrent deletion may remove everything beyond a valid boundary.
    // Recover the nearest remaining page rather than claiming the whole list is empty.
    let page: [String]
    if candidates.isEmpty, afterID != nil || beforeID != nil {
      page = before == nil ? Array(sorted.suffix(100)) : Array(sorted.prefix(100))
    } else {
      page = before == nil ? Array(candidates.prefix(100)) : Array(candidates.suffix(100))
    }
    // Current store membership, not the asynchronous snapshot, is authoritative.
    let items = page.compactMap { key -> SharedReminder? in
      guard let item = try? store.current(key), item.listID == list else { return nil }
      return item
    }
    return ReminderPage(
      items: items,
      next: try sealCursor(
        page.last.flatMap { last in sorted.last.map { $0 > last } == true ? last : nil },
        client: id, list: list),
      previous: try sealCursor(
        page.first.flatMap { first in sorted.first.map { $0 < first } == true ? first : nil },
        client: id, list: list))
  }
  public func mutate(_ token: String, csrf: String, command: Mutation) throws -> SharedReminder? {
    var outcome = WriteOutcome.unknown
    do {
      let id = try identity(token, csrf: csrf)
      // Preserve certainty before provider loss can invalidate all clients.
      if clients[id]!.operations[command.operationID] != nil { outcome = .committed }
      guard store.authorized else {
        stop()
        throw BridgeFailure.denied
      }
      clients[id]!.lastSeen = clock()
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      let encoded = try encoder.encode(command)
      if let previous = clients[id]!.operations[command.operationID] {
        outcome = .committed
        guard previous.0 == encoded else { throw BridgeFailure.conflict }
        _ = try require(id, list: command.listID, action: command.action)
        guard let prior = previous.1 else { return nil }
        // Certainty survives access changes, but cached contents do not cross them.
        let current = try store.current(prior.id)
        _ = try require(id, list: current.listID)
        return current
      }
      guard !clients[id]!.uncertain.contains(command.operationID) else {
        throw BridgeFailure.ambiguous
      }
      outcome = .refused
      _ = try require(id, list: command.listID, action: command.action)
      // The replay record is never evicted: a session past the cap must pair again.
      guard clients[id]!.operations.count + clients[id]!.uncertain.count < 500 else {
        throw BridgeFailure.sessionFull
      }
      if let fields = command.fields {
        var basic = fields
        basic.alarms = []
        basic.repeats = []
        try basic.validate()
        if fields.alarms != command.base?.fields.alarms {
          guard fields.alarms.count <= 10 else { throw BridgeFailure.invalid }
          for alarm in fields.alarms { try alarm.validate() }
        }
        if fields.repeats != command.base?.fields.repeats {
          guard fields.repeats.count <= 10 else { throw BridgeFailure.invalid }
          for rule in fields.repeats { try rule.validate() }
        }
      }
      let result: SharedReminder?
      // Mark before entering store: a throwing save may already have committed.
      do {
        if command.action == .create {
          guard let fields = command.fields, command.itemID == nil, command.base == nil else {
            throw BridgeFailure.invalid
          }
          outcome = .unknown
          clients[id]!.uncertain.insert(command.operationID)
          result = try store.create(in: command.listID, fields: fields)
        } else {
          guard let itemID = command.itemID, let base = command.base,
            base.id == itemID, base.listID == command.listID
          else { throw BridgeFailure.denied }
          var current: SharedReminder
          do { current = try store.current(itemID) } catch { throw BridgeFailure.denied }
          guard current.listID == command.listID else { throw BridgeFailure.denied }
          guard current == base else { throw BridgeFailure.conflict }
          switch command.action {
          case .create: throw BridgeFailure.invalid
          case .edit:
            guard let fields = command.fields, fields.completed == current.fields.completed else {
              throw BridgeFailure.invalid
            }
            current.fields = fields
            outcome = .unknown
            clients[id]!.uncertain.insert(command.operationID)
            result = try store.save(current, replacing: base)
          case .move:
            guard let destination = command.destination else { throw BridgeFailure.invalid }
            _ = try require(id, list: destination, action: .move)
            current.listID = destination
            outcome = .unknown
            clients[id]!.uncertain.insert(command.operationID)
            result = try store.save(current, replacing: base)
          case .complete, .reopen:
            current.fields.completed = command.action == .complete
            outcome = .unknown
            clients[id]!.uncertain.insert(command.operationID)
            result = try store.save(current, replacing: base)
          case .delete:
            guard command.confirmation == current.fields.title else { throw BridgeFailure.invalid }
            outcome = .unknown
            clients[id]!.uncertain.insert(command.operationID)
            try store.remove(current)
            result = nil
          }
        }
      } catch let refusal as PrecommitRefusal {
        clients[id]!.uncertain.remove(command.operationID)
        throw WriteFailure(refusal.failure, outcome: .refused)
      }
      clients[id]!.operations[command.operationID] = (encoded, result)
      clients[id]!.uncertain.remove(command.operationID)
      return result
    } catch let failure as WriteFailure {
      throw failure
    } catch {
      throw WriteFailure(error as? BridgeFailure ?? .ambiguous, outcome: outcome)
    }
  }
  private static func secret(bytes: Int) -> String {
    var random = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in
      String(format: "%02x", UInt8.random(in: .min ... .max, using: &random))
    }.joined()
  }
  static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
