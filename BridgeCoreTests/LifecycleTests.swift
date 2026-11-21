//
//  LifecycleTests.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation
import Testing

@testable import BridgeCore

@MainActor private final class TestClock: @unchecked Sendable {
  var value = Date(timeIntervalSince1970: 1_900_000_000)
  nonisolated func now() -> Date { MainActor.assumeIsolated { value } }
}

@MainActor private final class UncertainStore: ReminderStore {
  let fixture = FixtureStore()
  var authorized: Bool { fixture.authorized }
  func lists() throws -> [ReminderList] { try fixture.lists() }
  func reminderIDs(in list: String) async throws -> [String] {
    try await fixture.reminderIDs(in: list)
  }
  func current(_ id: String) throws -> SharedReminder { try fixture.current(id) }
  func create(in list: String, fields: ReminderFields) throws -> SharedReminder {
    _ = try fixture.create(in: list, fields: fields)
    throw BridgeFailure.ambiguous
  }
  func save(_ item: SharedReminder, replacing base: SharedReminder) throws -> SharedReminder {
    try fixture.save(item, replacing: base)
  }
  func remove(_ item: SharedReminder) throws { try fixture.remove(item) }
}

@MainActor struct LifecycleTests {
  private func grant(_ controller: SharingController) throws -> String {
    var rights = ClientRights()
    rights.lists = ["inbox"]
    rights.read = true
    rights.manage = true
    return try controller.pairClient(label: "Clock fixture", rights: rights).1
  }
  @Test func pairingExpires() throws {
    let clock = TestClock()
    let controller = SharingController(store: FixtureStore(), clock: clock.now)
    try controller.start()
    let secret = try grant(controller)
    clock.value.addTimeInterval(120)
    #expect(throws: BridgeFailure.denied) { try controller.exchange(secret) }
  }
  @Test func idleSessionExpires() throws {
    let clock = TestClock()
    let controller = SharingController(store: FixtureStore(), clock: clock.now)
    try controller.start()
    let token = try controller.exchange(grant(controller)).token
    clock.value.addTimeInterval(1800)
    #expect(throws: BridgeFailure.denied) { try controller.sessionState(token) }
  }
  @Test func absoluteSessionExpiryDespiteActivity() throws {
    let clock = TestClock()
    let controller = SharingController(store: FixtureStore(), clock: clock.now)
    try controller.start()
    let token = try controller.exchange(grant(controller)).token
    for _ in 0..<86 {
      clock.value.addTimeInterval(1000)
      _ = try controller.sessionState(token)
    }
    clock.value.addTimeInterval(400)
    #expect(throws: BridgeFailure.denied) { try controller.sessionState(token) }
  }
  @Test func uncertainCreateNeverAutomaticallyRepeats() throws {
    let store = UncertainStore()
    let controller = SharingController(store: store)
    try controller.start()
    let state = try controller.exchange(grant(controller))
    let command = Mutation(
      action: .create, listID: "inbox", fields: .init(title: "Uncertain fixture"))
    let before = store.fixture.rows.count
    #expect(throws: WriteFailure(.ambiguous, outcome: .unknown)) {
      try controller.mutate(state.token, csrf: state.csrf, command: command)
    }
    #expect(store.fixture.rows.count == before + 1)
    #expect(throws: WriteFailure(.ambiguous, outcome: .unknown)) {
      try controller.mutate(state.token, csrf: state.csrf, command: command)
    }
    #expect(store.fixture.rows.count == before + 1)
  }
  @Test func stopInvalidatesInFlightFetchAndAllClients() async throws {
    let store = FixtureStore()
    let controller = SharingController(store: store)
    try controller.start()
    let token = try controller.exchange(grant(controller)).token
    store.beforeFetch = { controller.stop() }
    await #expect(throws: BridgeFailure.denied) { try await controller.read(token, list: "inbox") }
    #expect(controller.clientInfo.isEmpty)
    #expect(!controller.running)
    try controller.start()
    #expect(throws: BridgeFailure.denied) { try controller.sessionState(token) }
  }
  @Test func uncertainAndSuccessfulOperationsShareOneBound() throws {
    let store = UncertainStore()
    let controller = SharingController(store: store)
    try controller.start()
    let state = try controller.exchange(grant(controller))
    for index in 0..<510 {
      #expect(
        throws: WriteFailure(
          index < 500 ? .ambiguous : .sessionFull, outcome: index < 500 ? .unknown : .refused)
      ) {
        try controller.mutate(
          state.token, csrf: state.csrf,
          command: .init(
            action: .create, listID: "inbox", fields: .init(title: "Uncertain fixture")))
      }
    }
    #expect(store.fixture.rows.count == 502)
  }

}
