import Foundation
import HTTPTypes
import HummingbirdTesting
import Testing

@testable import BridgeCore

@MainActor struct EditBoundaryTests {
  private func setup() throws -> (FixtureStore, SharingController, String, String) {
    let store = FixtureStore()
    let c = SharingController(store: store)
    try c.start()
    var rights = ClientRights()
    rights.lists = ["inbox"]
    rights.read = true
    rights.manage = true
    let state = try c.exchange(c.pairClient(label: "Boundary fixture", rights: rights).1)
    return (store, c, state.token, state.csrf)
  }
  @Test func changedAdvancedCountsAreRefusedBeforeStore() throws {
    let (store, c, token, csrf) = try setup()
    for count in [11, 5000] {
      let base = try store.current("book")
      for alarms in [true, false] {
        var fields = base.fields
        if alarms {
          fields.alarms = Array(repeating: .init(relativeOffset: -60), count: count)
        } else {
          fields.repeats = Array(repeating: .init(frequency: "daily", interval: 1), count: count)
        }
        #expect(throws: WriteFailure(.invalid, outcome: .refused)) {
          try c.mutate(
            token, csrf: csrf,
            command: .init(
              action: .edit, listID: "inbox", itemID: "book", base: base, fields: fields))
        }
        #expect(try store.current("book") == base)
        #expect(throws: WriteFailure(.invalid, outcome: .refused)) {
          try c.mutate(
            token, csrf: csrf, command: .init(action: .create, listID: "inbox", fields: fields))
        }
        #expect(store.rows.count == 2)
      }
    }
  }
  @Test func unchangedLargeNativeArraysArePreservedButChangesAreBounded() throws {
    let (store, c, token, csrf) = try setup()
    store.rows["book"]!.fields.alarms = Array(repeating: .init(relativeOffset: -60), count: 11)
    store.rows["book"]!.fields.repeats = Array(
      repeating: .init(frequency: "monthly", interval: 1, calendarIdentifier: "hebrew"), count: 11)
    let base = try store.current("book")
    var fields = base.fields
    fields.notes = "Only notes changed"
    let saved = try #require(
      try c.mutate(
        token, csrf: csrf,
        command: .init(action: .edit, listID: "inbox", itemID: "book", base: base, fields: fields)))
    #expect(saved.fields.alarms == base.fields.alarms)
    #expect(saved.fields.repeats == base.fields.repeats)
    fields.alarms = Array(repeating: .init(relativeOffset: -120), count: 10)
    fields.repeats = Array(repeating: .init(frequency: "daily", interval: 1), count: 10)
    let bounded = try #require(
      try c.mutate(
        token, csrf: csrf,
        command: .init(action: .edit, listID: "inbox", itemID: "book", base: saved, fields: fields))
    )
    #expect(bounded.fields.alarms.count == 10 && bounded.fields.repeats.count == 10)
  }
  @Test func removedTailAndHeadRecoverCurrentPage() async throws {
    for forward in [true, false] {
      let (store, c, token, _) = try setup()
      store.rows.removeAll()
      for index in 0..<105 {
        let id = String(format: "row-%03d", index)
        store.rows[id] = SharedReminder(id: id, listID: "inbox", fields: .init(title: id))
      }
      let first = try await c.read(token, list: "inbox")
      let second = try await c.read(token, list: "inbox", after: first.next)
      let removed = forward ? 100..<105 : 0..<100
      for index in removed { store.rows.removeValue(forKey: String(format: "row-%03d", index)) }
      let recovered = try await c.read(
        token, list: "inbox", after: forward ? first.next : nil,
        before: forward ? nil : second.previous)
      #expect(recovered.items.count == (forward ? 100 : 5))
      #expect(Set(recovered.items.map(\.id)) == Set(store.rows.keys))
      #expect(recovered.next == nil && recovered.previous == nil)
    }
  }
  @Test func defaultHTTPSPortNormalizesButOtherPortsStayExplicit() throws {
    let plain = try BridgeConfiguration(origin: "https://bridge.example.com")
    let explicit = try BridgeConfiguration(origin: "https://BRIDGE.example.com:443/")
    #expect(explicit.host == plain.host)
    #expect(explicit.origin == plain.origin)
    let other = try BridgeConfiguration(origin: "https://bridge.example.com:8443")
    #expect(other.host == "bridge.example.com:8443")
    #expect(other.origin == "https://bridge.example.com:8443")
  }
  @Test func normalizedDefaultPortAcceptsBrowserAuthorityButRejectsOtherAuthority() async throws {
    let (_, sharing, _, _) = try setup()
    let server = BridgeServer(
      sharing: sharing,
      configuration: try .init(origin: "https://bridge.example.com:443", port: 18801))
    try await server.application().test(.live) { live in
      let port = try #require(live.port)
      try await TestClient.withClient(host: "localhost", port: port) { client in
        var headers = HTTPFields()
        headers[HTTPField.Name("X-Forwarded-Proto")!] = "https"
        headers[.origin] = "https://bridge.example.com"
        let good = try await client.execute(
          .init("/", method: .get, authority: "bridge.example.com", headers: headers, body: nil))
        #expect(good.status == .ok)
        let wrongPort = try await client.execute(
          .init(
            "/", method: .get, authority: "bridge.example.com:8443", headers: headers, body: nil))
        #expect(wrongPort.status == .forbidden)
        headers[.origin] = "https://elsewhere.example"
        let wrongOrigin = try await client.execute(
          .init("/", method: .get, authority: "bridge.example.com", headers: headers, body: nil))
        #expect(wrongOrigin.status == .forbidden)
      }
    }
    sharing.stop()
  }

}
