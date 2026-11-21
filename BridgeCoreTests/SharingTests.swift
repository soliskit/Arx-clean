//
//  SharingTests.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation
import Testing

@testable import BridgeCore

@MainActor struct SharingTests {
  func setup(
    read: Bool = true, manage: Bool = true, delete: Bool = true,
    lists: Set<String> = ["inbox", "weekend"]
  ) throws -> (FixtureStore, SharingController, String, String) {
    let store = FixtureStore()
    let sharing = SharingController(store: FixtureStore())
    let controller = SharingController(store: store)
    // Separate, unused controller proves grants are instance-local.
    #expect(sharing.clientInfo.isEmpty)
    try controller.start()
    var rights = ClientRights()
    rights.lists = lists
    rights.read = read
    rights.manage = manage
    rights.delete = delete
    let (_, secret) = try controller.pairClient(label: "Test client", rights: rights)
    let session = try controller.exchange(secret)
    return (store, controller, session.token, session.csrf)
  }
  @Test func defaultNone() throws {
    let store = FixtureStore()
    let sharing = SharingController(store: FixtureStore())
    #expect(store.authorized)
    try sharing.start()
    let (_, secret) = try sharing.pairClient(label: "Untrusted label", rights: ClientRights())
    let s = try sharing.exchange(secret)
    #expect(throws: BridgeFailure.denied) { try sharing.sharedLists(s.token) }
  }
  @Test func selectedListsAndSourcePrivacy() throws {
    let (_, c, token, _) = try setup(lists: ["inbox"])
    let lists = try c.sharedLists(token)
    #expect(lists.map(\.id) == ["inbox"])
    #expect(lists[0].source.isEmpty)
  }
  @Test func unsharedAndMissingFailSame() async throws {
    let (_, c, token, _) = try setup(lists: ["inbox"])
    await #expect(throws: BridgeFailure.denied) { try await c.read(token, list: "weekend") }
    await #expect(throws: BridgeFailure.denied) { try await c.read(token, list: "missing") }
  }
  @Test func independentClients() throws {
    let (_, c, token, _) = try setup(lists: ["inbox"])
    var rights = ClientRights()
    rights.read = true
    rights.lists = ["weekend"]
    let (_, secret) = try c.pairClient(label: "Second", rights: rights)
    let other = try c.exchange(secret)
    #expect(try c.sharedLists(other.token).map(\.id) == ["weekend"])
    #expect(try c.sharedLists(token).map(\.id) == ["inbox"])
  }
  @Test func pairingSingleUseAndThrottle() throws {
    let c = SharingController(store: FixtureStore())
    try c.start()
    let (_, secret) = try c.pairClient(label: "Client", rights: ClientRights())
    _ = try c.exchange(secret)
    #expect(throws: BridgeFailure.denied) { try c.exchange(secret) }
    for _ in 0..<9 { #expect(throws: BridgeFailure.denied) { try c.exchange("wrong") } }
    #expect(throws: BridgeFailure.rateLimited) { try c.exchange("wrong") }
  }
  @Test func revocationAndRestart() throws {
    let (_, c, token, _) = try setup()
    c.revoke(c.clientInfo[0].id)
    #expect(throws: BridgeFailure.denied) { try c.sharedLists(token) }
    c.stop()
    try c.start()
    #expect(throws: BridgeFailure.denied) { try c.sharedLists(token) }
  }
  @Test func noReadWithoutReadGrant() async throws {
    let (_, c, token, _) = try setup(read: false, manage: false, delete: false)
    await #expect(throws: BridgeFailure.denied) { try await c.read(token, list: "inbox") }
  }
  @Test func revokeDuringFetch() async throws {
    let (store, c, token, _) = try setup()
    store.beforeFetch = { c.revoke(c.clientInfo[0].id) }
    await #expect(throws: BridgeFailure.denied) { try await c.read(token, list: "inbox") }
  }
  @Test func permissionLossDuringFetch() async throws {
    let (store, c, token, _) = try setup()
    store.beforeFetch = { store.authorized = false }
    await #expect(throws: BridgeFailure.denied) { try await c.read(token, list: "inbox") }
    #expect(c.clientInfo.isEmpty)
  }
  @Test func moveOutDuringFetch() async throws {
    let (store, c, token, _) = try setup(lists: ["inbox"])
    store.beforeFetch = { store.rows["book"]!.listID = "weekend" }
    #expect(try await c.read(token, list: "inbox").items.isEmpty)
  }
  @Test func removedListFailsClosed() async throws {
    let (store, c, token, _) = try setup()
    store.collections.removeAll { $0.id == "inbox" }
    store.collections.append(.init(id: "replacement", title: "Inbox"))
    await #expect(throws: BridgeFailure.denied) { try await c.read(token, list: "inbox") }
    await #expect(throws: BridgeFailure.denied) { try await c.read(token, list: "replacement") }
  }
  @Test func pagesTraverseMoreThan5000WithoutLossOrDuplicates() async throws {
    let (store, c, token, _) = try setup(lists: ["inbox"])
    store.rows.removeAll()
    for index in 0..<5107 {
      let id = String(format: "%06d", index)
      store.rows[id] = SharedReminder(id: id, listID: "inbox", fields: .init(title: id))
    }
    var after: String?
    var seen: [String] = []
    repeat {
      let page = try await c.read(token, list: "inbox", after: after)
      #expect(page.items.count <= 100)
      seen += page.items.map(\.id)
      after = page.next
    } while after != nil
    #expect(seen.count == 5107)
    #expect(Set(seen).count == 5107)
    #expect(seen == seen.sorted())
    let first = try await c.read(token, list: "inbox")
    let second = try await c.read(token, list: "inbox", after: first.next)
    let previous = try await c.read(token, list: "inbox", before: second.previous)
    #expect(previous.items == first.items)
    #expect(previous.previous == nil)
    await #expect(throws: BridgeFailure.denied) {
      try await c.read(token, list: "weekend", after: first.next)
    }
    await #expect(throws: BridgeFailure.invalid) {
      try await c.read(token, list: "inbox", after: "a", before: "z")
    }
    await #expect(throws: BridgeFailure.invalid) {
      try await c.read(token, list: "inbox", after: String(repeating: "a", count: 8193))
    }
    store.beforeFetch = { c.revoke(c.clientInfo[0].id) }
    await #expect(throws: BridgeFailure.denied) {
      try await c.read(token, list: "inbox", after: first.next)
    }
  }
  @Test func movedBoundaryDoesNotLeakThroughCursor() async throws {
    let (store, c, token, _) = try setup(lists: ["inbox"])
    store.rows.removeAll()
    for index in 0..<105 {
      let id = String(format: "private-boundary-%06d", index)
      store.rows[id] = SharedReminder(id: id, listID: "inbox", fields: .init(title: id))
    }
    store.beforeFetch = {
      for index in 0..<100 {
        store.rows[String(format: "private-boundary-%06d", index)]!.listID = "weekend"
      }
    }
    let first = try await c.read(token, list: "inbox")
    #expect(first.items.isEmpty)
    #expect(first.next != nil)
    let serialized = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
    #expect(!serialized.contains("private-boundary"))
    store.beforeFetch = nil
    let next = try await c.read(token, list: "inbox", after: first.next)
    #expect(next.items.count == 5)
    #expect(next.next == nil)
    await #expect(throws: BridgeFailure.invalid) {
      try await c.read(token, list: "inbox", after: "forged")
    }
    var rights = ClientRights()
    rights.read = true
    rights.lists = ["inbox"]
    let (_, secret) = try c.pairClient(label: "Other client", rights: rights)
    let other = try c.exchange(secret)
    await #expect(throws: BridgeFailure.invalid) {
      try await c.read(other.token, list: "inbox", after: first.next)
    }
  }
  @Test func overlappingReadsAreBounded() async throws {
    let (store, c, token, _) = try setup()
    store.beforeFetch = {
      await #expect(throws: BridgeFailure.rateLimited) {
        try await c.read(token, list: "inbox")
      }
    }
    #expect(try await c.read(token, list: "inbox").items.count == 1)
    store.beforeFetch = nil
    #expect(try await c.read(token, list: "inbox").items.count == 1)
  }
  @Test func createAndReplayNoDuplicate() throws {
    let (store, c, token, csrf) = try setup()
    let command = Mutation(action: .create, listID: "inbox", fields: .init(title: "New"))
    let first = try c.mutate(token, csrf: csrf, command: command)
    #expect(try c.mutate(token, csrf: csrf, command: command) == first)
    #expect(store.rows.count == 3)
    var changed = command
    changed.fields = .init(title: "Different")
    #expect(throws: WriteFailure(.conflict, outcome: .committed)) {
      try c.mutate(token, csrf: csrf, command: changed)
    }
  }
  @Test func allBasicMutations() throws {
    let (store, c, token, csrf) = try setup()
    var item = try store.current("book")
    var fields = item.fields
    fields.title = "Edited"
    fields.notes = "Notes"
    fields.priority = 5
    fields.location = "Place"
    fields.url = "https://example.com"
    fields.start = .init(year: 2030, month: 1, day: 1)
    fields.due = .init(
      year: 2030, month: 1, day: 2, hour: 10, minute: 30, timeZone: "America/Los_Angeles")
    fields.alarms = [
      .init(relativeOffset: -900),
      .init(latitude: 37, longitude: -122, radius: 100, proximity: "enter"),
    ]
    fields.repeats = [
      .init(frequency: "weekly", interval: 2, daysOfWeek: [.init(day: 2, week: 0)], count: 4)
    ]
    item = try #require(
      try c.mutate(
        token, csrf: csrf,
        command: .init(
          action: .edit, listID: item.listID, itemID: item.id, base: item, fields: fields)))
    #expect(item.fields == fields)
    fields.start = nil
    fields.due = nil
    fields.alarms = []
    fields.repeats = []
    item = try #require(
      try c.mutate(
        token, csrf: csrf,
        command: .init(
          action: .edit, listID: item.listID, itemID: item.id, base: item, fields: fields)))
    #expect(item.fields == fields)
    for action in [Mutation.Action.complete, .reopen] {
      item = try #require(
        try c.mutate(
          token, csrf: csrf,
          command: .init(action: action, listID: item.listID, itemID: item.id, base: item)))
      #expect(item.fields.completed == (action == .complete))
    }
    item = try #require(
      try c.mutate(
        token, csrf: csrf,
        command: .init(
          action: .move, listID: item.listID, itemID: item.id, base: item, destination: "weekend")))
    #expect(item.listID == "weekend")
    let command = Mutation(
      action: .delete, listID: item.listID, itemID: item.id, base: item,
      confirmation: item.fields.title)
    #expect(try c.mutate(token, csrf: csrf, command: command) == nil)
    #expect(store.rows["book"] == nil)
  }
  @Test func unchangedUnsupportedRecurrenceIsPreserved() throws {
    let (store, c, token, csrf) = try setup()
    store.rows["book"]!.fields.repeats = [
      .init(frequency: "monthly", interval: 1, calendarIdentifier: "hebrew", firstDayOfWeek: 2)
    ]
    let base = try store.current("book")
    var fields = base.fields
    fields.notes = "Only notes changed"
    let result = try #require(
      try c.mutate(
        token, csrf: csrf,
        command: .init(action: .edit, listID: "inbox", itemID: "book", base: base, fields: fields)))
    #expect(result.fields.repeats == base.fields.repeats)
    fields.repeats[0].interval = 2
    #expect(throws: WriteFailure(.invalid, outcome: .refused)) {
      try c.mutate(
        token, csrf: csrf,
        command: .init(action: .edit, listID: "inbox", itemID: "book", base: result, fields: fields)
      )
    }
  }
  @Test func csrfAndDeleteSeparate() throws {
    let (store, c, token, csrf) = try setup(delete: false)
    let item = try store.current("book")
    let command = Mutation(
      action: .delete, listID: "inbox", itemID: "book", base: item, confirmation: item.fields.title)
    #expect(throws: WriteFailure(.denied, outcome: .refused)) {
      try c.mutate(token, csrf: csrf, command: command)
    }
    #expect(throws: WriteFailure(.denied, outcome: .unknown)) {
      try c.mutate(
        token, csrf: "wrong",
        command: .init(action: .create, listID: "inbox", fields: .init(title: "Bad")))
    }
    #expect(store.rows.count == 2)
  }
  @Test func deleteConfirmationRequired() throws {
    let (store, c, token, csrf) = try setup()
    let item = try store.current("book")
    #expect(throws: WriteFailure(.invalid, outcome: .refused)) {
      try c.mutate(
        token, csrf: csrf,
        command: .init(
          action: .delete, listID: "inbox", itemID: "book", base: item, confirmation: "wrong"))
    }
    #expect(store.rows.count == 2)
  }
  @Test func writableBothEndsAndNoManage() throws {
    let (store, c, token, csrf) = try setup(lists: ["inbox", "readonly"])
    let item = try store.current("book")
    #expect(throws: WriteFailure(.denied, outcome: .refused)) {
      try c.mutate(
        token, csrf: csrf,
        command: .init(
          action: .move, listID: "inbox", itemID: "book", base: item, destination: "readonly"))
    }
    let (_, readonly, t, s) = try setup(manage: false)
    #expect(throws: WriteFailure(.denied, outcome: .refused)) {
      try readonly.mutate(
        t, csrf: s, command: .init(action: .create, listID: "inbox", fields: .init(title: "No")))
    }
  }
  @Test func staleEditsAndIDsFailClosed() throws {
    let (store, c, token, csrf) = try setup()
    let base = try store.current("book")
    store.rows["book"]!.fields.notes = "External edit"
    #expect(throws: WriteFailure(.conflict, outcome: .refused)) {
      try c.mutate(
        token, csrf: csrf,
        command: .init(
          action: .edit, listID: "inbox", itemID: "book", base: base,
          fields: .init(title: "Overwrite")))
    }
    store.rows.removeValue(forKey: "book")
    store.rows["new-id"] = .init(id: "new-id", listID: "inbox", fields: base.fields)
    #expect(throws: WriteFailure(.denied, outcome: .refused)) {
      try c.mutate(
        token, csrf: csrf,
        command: .init(
          action: .delete, listID: "inbox", itemID: "book", base: base,
          confirmation: base.fields.title))
    }
  }
  @Test func emptyAndStoreDeniedAreDifferent() async throws {
    let (store, c, token, _) = try setup(lists: ["later"])
    #expect(try await c.read(token, list: "later").items.isEmpty)
    store.authorized = false
    await #expect(throws: BridgeFailure.denied) { try await c.read(token, list: "later") }
  }
  @Test func originValidation() throws {
    _ = try BridgeConfiguration(origin: "https://bridge.example.com")
    for origin in [
      "http://example.com", "https://example.com/path", "https://a:b@example.com",
      "https://example.com?secret=a", "https://localhost",
    ] {
      #expect(throws: BridgeFailure.invalid) { try BridgeConfiguration(origin: origin) }
    }
  }
  @Test func replayAfterExternalMoveDoesNotDiscloseUnsharedContent() throws {
    let (store, c, token, csrf) = try setup(lists: ["inbox"])
    let command = Mutation(action: .create, listID: "inbox", fields: .init(title: "Replay fixture"))
    let created = try #require(try c.mutate(token, csrf: csrf, command: command))
    store.rows[created.id]!.listID = "weekend"
    #expect(throws: WriteFailure(.denied, outcome: .committed)) {
      try c.mutate(token, csrf: csrf, command: command)
    }
  }
  @Test func rejectedCommandsDoNotConsumeUncertainStorage() throws {
    let (_, c, token, csrf) = try setup()
    for _ in 0..<600 {
      #expect(throws: WriteFailure(.denied, outcome: .refused)) {
        try c.mutate(token, csrf: csrf, command: .init(action: .edit, listID: "inbox"))
      }
    }
    #expect(
      try c.mutate(
        token, csrf: csrf,
        command: .init(action: .create, listID: "inbox", fields: .init(title: "Still usable")))
        != nil)
  }

}
