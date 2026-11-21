import Foundation
import Testing

@testable import BridgeCore

@MainActor private final class OutcomeStore: ReminderStore {
  let fixture = FixtureStore()
  var mode = "normal"
  var writes = 0
  var authorized: Bool { fixture.authorized }
  func lists() throws -> [ReminderList] { try fixture.lists() }
  func reminderIDs(in list: String) async throws -> [String] {
    try await fixture.reminderIDs(in: list)
  }
  func current(_ id: String) throws -> SharedReminder { try fixture.current(id) }
  func create(in list: String, fields: ReminderFields) throws -> SharedReminder {
    if mode == "refuse" { throw PrecommitRefusal(.denied) }
    writes += 1
    let item = try fixture.create(in: list, fields: fields)
    if mode == "throw-after-write" { throw BridgeFailure.denied }
    return item
  }
  func save(_ item: SharedReminder, replacing base: SharedReminder) throws -> SharedReminder {
    try fixture.save(item, replacing: base)
  }
  func remove(_ item: SharedReminder) throws { try fixture.remove(item) }
}

@MainActor struct WriteOutcomeTests {
  private func setup() throws -> (OutcomeStore, SharingController, String, String) {
    let store = OutcomeStore()
    let c = SharingController(store: store)
    try c.start()
    var rights = ClientRights()
    rights.lists = ["inbox"]
    rights.read = true
    rights.manage = true
    let state = try c.exchange(c.pairClient(label: "Outcome fixture", rights: rights).1)
    return (store, c, state.token, state.csrf)
  }
  @Test func provedStoreRefusalsDoNotConsumeUncertainAllowance() throws {
    let (store, c, token, csrf) = try setup()
    store.mode = "refuse"
    for _ in 0..<600 {
      #expect(throws: WriteFailure(.denied, outcome: .refused)) {
        try c.mutate(
          token, csrf: csrf,
          command: .init(action: .create, listID: "inbox", fields: .init(title: "Refused")))
      }
    }
    #expect(store.writes == 0)
    store.mode = "normal"
    #expect(
      try c.mutate(
        token, csrf: csrf,
        command: .init(action: .create, listID: "inbox", fields: .init(title: "Allowed"))) != nil)
  }
  @Test func unknownReplayStaysUnknownAfterPayloadAndRightsChangeAndAtCap() throws {
    let (store, c, token, csrf) = try setup()
    store.mode = "throw-after-write"
    let command = Mutation(action: .create, listID: "inbox", fields: .init(title: "Uncertain"))
    #expect(throws: WriteFailure(.denied, outcome: .unknown)) {
      try c.mutate(token, csrf: csrf, command: command)
    }
    for _ in 1..<500 {
      #expect(throws: WriteFailure(.denied, outcome: .unknown)) {
        try c.mutate(
          token, csrf: csrf,
          command: .init(action: .create, listID: "inbox", fields: .init(title: "Fill cap")))
      }
    }
    #expect(throws: WriteFailure(.sessionFull, outcome: .refused)) {
      try c.mutate(
        token, csrf: csrf,
        command: .init(action: .create, listID: "inbox", fields: .init(title: "Over cap")))
    }
    var changed = command
    changed.fields?.title = "Changed retry"
    store.fixture.collections.removeAll()
    #expect(throws: WriteFailure(.ambiguous, outcome: .unknown)) {
      try c.mutate(token, csrf: csrf, command: changed)
    }
    #expect(store.writes == 500)
  }
  @Test func committedReplayNeverBecomesRefusedOrDisclosesLostAccess() throws {
    let (store, c, token, csrf) = try setup()
    let command = Mutation(action: .create, listID: "inbox", fields: .init(title: "Private"))
    let item = try #require(try c.mutate(token, csrf: csrf, command: command))
    var changed = command
    changed.fields?.title = "Changed retry"
    #expect(throws: WriteFailure(.conflict, outcome: .committed)) {
      try c.mutate(token, csrf: csrf, command: changed)
    }
    store.fixture.collections.removeAll()
    #expect(throws: WriteFailure(.denied, outcome: .committed)) {
      try c.mutate(token, csrf: csrf, command: command)
    }
    #expect(try store.fixture.current(item.id).fields.title == "Private")
    #expect(store.writes == 1)
  }
  @Test func committedCertaintySurvivesProviderPermissionLossWithoutCachedData() throws {
    let (store, c, token, csrf) = try setup()
    let command = Mutation(action: .create, listID: "inbox", fields: .init(title: "Private"))
    _ = try c.mutate(token, csrf: csrf, command: command)
    store.fixture.authorized = false
    #expect(throws: WriteFailure(.denied, outcome: .committed)) {
      try c.mutate(token, csrf: csrf, command: command)
    }
    #expect(!c.running)
    #expect(c.clientInfo.isEmpty)
  }

}
