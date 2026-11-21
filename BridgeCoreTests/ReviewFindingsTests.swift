import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import BridgeCore

@MainActor private final class ReviewClock: @unchecked Sendable {
  var value = Date(timeIntervalSince1970: 1_900_000_000)
  nonisolated func now() -> Date { MainActor.assumeIsolated { value } }
}

@MainActor struct ReviewFindingsTests {
  @Test func validSecretIsNotBlockedByStrangersWrongGuesses() throws {
    let c = SharingController(store: FixtureStore())
    try c.start()
    let (_, secret) = try c.pairClient(label: "Owner", rights: ClientRights())
    for _ in 0..<10 { #expect(throws: BridgeFailure.denied) { try c.exchange("wrong") } }
    #expect(throws: BridgeFailure.rateLimited) { try c.exchange("wrong") }
    _ = try c.exchange(secret)
  }
  @Test func expiredUnusedPairingsDoNotConsumeClientSlots() throws {
    let clock = ReviewClock()
    let c = SharingController(store: FixtureStore(), clock: clock.now)
    try c.start()
    for index in 0..<20 { _ = try c.pairClient(label: "Old \(index)", rights: ClientRights()) }
    clock.value.addTimeInterval(121)
    _ = try c.pairClient(label: "New", rights: ClientRights())
    #expect(c.clientInfo.map(\.label) == ["New"])
  }
  @Test func idleExpiredSessionsAreRemovedOnStatusRefresh() throws {
    let clock = ReviewClock()
    let c = SharingController(store: FixtureStore(), clock: clock.now)
    try c.start()
    var tokens: [String] = []
    for index in 0..<20 {
      let (_, secret) = try c.pairClient(label: "Old \(index)", rights: ClientRights())
      tokens.append(try c.exchange(secret).token)
    }
    clock.value.addTimeInterval(1800)
    #expect(c.clientInfo.isEmpty)
    _ = try c.pairClient(label: "New", rights: ClientRights())
    for token in tokens {
      #expect(throws: BridgeFailure.denied) { try c.sessionState(token) }
    }
  }
  @Test func absoluteExpiredActiveSessionIsRemoved() throws {
    let clock = ReviewClock()
    let c = SharingController(store: FixtureStore(), clock: clock.now)
    try c.start()
    let (_, secret) = try c.pairClient(label: "Active", rights: ClientRights())
    let token = try c.exchange(secret).token
    for _ in 0..<86 {
      clock.value.addTimeInterval(1000)
      _ = try c.sessionState(token)
    }
    clock.value.addTimeInterval(400)
    #expect(c.clientInfo.isEmpty)
    #expect(throws: BridgeFailure.denied) { try c.sessionState(token) }
  }
  @Test func validSessionSurvivesExpiredPairingCleanup() throws {
    let clock = ReviewClock()
    let c = SharingController(store: FixtureStore(), clock: clock.now)
    try c.start()
    let (_, secret) = try c.pairClient(label: "Valid", rights: ClientRights())
    let token = try c.exchange(secret).token
    _ = try c.pairClient(label: "Unused", rights: ClientRights())
    clock.value.addTimeInterval(121)
    #expect(c.clientInfo.map(\.label) == ["Valid"])
    _ = try c.sessionState(token)
    _ = try c.pairClient(label: "New", rights: ClientRights())
    #expect(c.clientInfo.map(\.label) == ["New", "Valid"])
    _ = try c.sessionState(token)
  }
  @Test func malformedBodyIsBadRequestWithoutLosingSession() async throws {
    let sharing = SharingController(store: FixtureStore())
    try sharing.start()
    var rights = ClientRights()
    rights.lists = ["inbox"]
    rights.read = true
    rights.manage = true
    let (_, secret) = try sharing.pairClient(label: "HTTP review", rights: rights)
    let state = try sharing.exchange(secret)
    let server = BridgeServer(
      sharing: sharing, configuration: try .init(origin: "https://bridge.example.com", port: 18767))
    try await server.application().test(.live) { live in
      guard let port = live.port else { throw BridgeFailure.unavailable }
      try await TestClient.withClient(host: "localhost", port: port) { connection in
        var headers = HTTPFields()
        headers[HTTPField.Name("X-Forwarded-Proto")!] = "https"
        headers[.origin] = "https://bridge.example.com"
        headers[.contentType] = "application/json"
        let page = try await connection.execute(
          .init("/", method: .get, authority: "bridge.example.com", headers: headers, body: nil))
        #expect(page.status == .ok)
        headers[.cookie] = "__Host-arx=\(state.token)"
        headers[HTTPField.Name("X-CSRF-Token")!] = state.csrf
        let base = try await MainActor.run { try sharing.store.current("book") }
        var stale = base
        stale.fields.title = "Stale fixture snapshot"
        let conflictCommand = Mutation(
          action: .edit, listID: "inbox", itemID: base.id,
          base: stale, fields: base.fields)
        let conflict = try await connection.execute(
          .init(
            "/api/mutate", method: .post, authority: "bridge.example.com", headers: headers,
            body: .init(bytes: try JSONEncoder().encode(conflictCommand))))
        #expect(conflict.status == .conflict)
        let payload = try JSONDecoder().decode(
          [String: String].self, from: Data(try #require(conflict.body).readableBytesView))
        #expect(payload["writeOutcome"] == "refused")
        #expect(payload["code"] == "conflict")
        let bad = try await connection.execute(
          .init(
            "/api/read", method: .post, authority: "bridge.example.com", headers: headers,
            body: .init(string: "{not json")))
        #expect(bad.status == .badRequest)
        let session = try await connection.execute(
          .init(
            "/api/session", method: .get, authority: "bridge.example.com", headers: headers,
            body: nil))
        #expect(session.status == .ok)
        let replayCommand = Mutation(
          action: .create, listID: "inbox", fields: .init(title: "Private replay"))
        let replayData = try JSONEncoder().encode(replayCommand)
        let saved = try await connection.execute(
          .init(
            "/api/mutate", method: .post, authority: "bridge.example.com", headers: headers,
            body: .init(bytes: replayData)))
        #expect(saved.status == .ok)
        await MainActor.run { (sharing.store as! FixtureStore).authorized = false }
        let replay = try await connection.execute(
          .init(
            "/api/mutate", method: .post, authority: "bridge.example.com", headers: headers,
            body: .init(bytes: replayData)))
        #expect(replay.status == .forbidden)
        let replayPayload = try JSONDecoder().decode(
          [String: String].self,
          from: Data(try #require(replay.body).readableBytesView))
        #expect(replayPayload["writeOutcome"] == "committed")
        #expect(!replayPayload.values.contains { $0.contains("Private replay") })

      }
    }
    sharing.stop()
  }
}
