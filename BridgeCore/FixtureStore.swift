//
//  FixtureStore.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation

@MainActor public final class FixtureStore: ReminderStore {
  public var authorized = true
  public var collections: [ReminderList] = [
    .init(id: "inbox", title: "Inbox", source: "Fixture account"),
    .init(id: "weekend", title: "Weekend", source: "Fixture account"),
    .init(id: "later", title: "Later", source: "Fixture account"),
    .init(id: "readonly", title: "Read-only list", writable: false),
  ]
  public var rows: [String: SharedReminder] = [
    "book": .init(id: "book", listID: "inbox", fields: .init(title: "Return the library book")),
    "walk": .init(id: "walk", listID: "weekend", fields: .init(title: "Plan a walk")),
  ]
  public var beforeFetch: (@MainActor () async -> Void)?
  public init() {}
  public func lists() throws -> [ReminderList] {
    guard authorized else { throw BridgeFailure.unavailable }
    return collections
  }
  public func reminderIDs(in list: String) async throws -> [String] {
    let snapshot = rows.values.filter { $0.listID == list }.map(\.id)
    await beforeFetch?()
    return snapshot
  }
  public func current(_ id: String) throws -> SharedReminder {
    guard authorized, let item = rows[id] else { throw BridgeFailure.denied }
    return item
  }
  public func create(in list: String, fields: ReminderFields) throws -> SharedReminder {
    do {
      try writable(list)
      try fields.validate()
    } catch { throw PrecommitRefusal(error as? BridgeFailure ?? .unavailable) }
    let item = SharedReminder(id: UUID().uuidString, listID: list, fields: fields)
    rows[item.id] = item
    return item
  }
  public func save(_ item: SharedReminder, replacing base: SharedReminder) throws -> SharedReminder
  {
    do {
      guard try current(base.id) == base else { throw BridgeFailure.conflict }
      try writable(base.listID)
      try writable(item.listID)
    } catch { throw PrecommitRefusal(error as? BridgeFailure ?? .unavailable) }
    rows[item.id] = item
    return item
  }
  public func remove(_ item: SharedReminder) throws {
    do {
      guard try current(item.id) == item else { throw BridgeFailure.conflict }
      try writable(item.listID)
    } catch { throw PrecommitRefusal(error as? BridgeFailure ?? .unavailable) }
    rows.removeValue(forKey: item.id)
  }
  private func writable(_ id: String) throws {
    guard authorized, collections.contains(where: { $0.id == id && $0.writable }) else {
      throw BridgeFailure.denied
    }
  }
}
