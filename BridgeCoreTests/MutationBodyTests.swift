import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import BridgeCore

@MainActor struct MutationBodyTests {
  @Test func largeNotesAndEditBaseFitAndOversizeKeepsSession() async throws {
    let store = FixtureStore()
    let sharing = SharingController(store: store)
    try sharing.start()
    var rights = ClientRights()
    rights.lists = ["inbox"]
    rights.read = true
    rights.manage = true
    let state = try sharing.exchange(sharing.pairClient(label: "Body fixture", rights: rights).1)
    let server = BridgeServer(
      sharing: sharing, configuration: try .init(origin: "https://bridge.example.com", port: 18768))
    try await server.application().test(.live) { live in
      guard let port = live.port else { throw BridgeFailure.unavailable }
      try await TestClient.withClient(host: "localhost", port: port) { connection in
        var headers = HTTPFields()
        headers[HTTPField.Name("X-Forwarded-Proto")!] = "https"
        headers[.origin] = "https://bridge.example.com"
        headers[.contentType] = "application/json"
        headers[.cookie] = "__Host-arx=\(state.token)"
        headers[HTTPField.Name("X-CSRF-Token")!] = state.csrf
        // Full character-limit notes, both one-byte and multibyte, including original edit copy.
        for character in ["a", "界"] {
          var fields = ReminderFields(title: "Large notes")
          fields.notes = String(repeating: character, count: 32_768)
          let create = try JSONEncoder().encode(
            Mutation(action: .create, listID: "inbox", fields: fields))
          let creation = try await connection.execute(
            .init(
              "/api/mutate", method: .post, authority: "bridge.example.com", headers: headers,
              body: .init(bytes: create)))
          #expect(creation.status == .ok)
          let created = await store.rows.values.first { $0.fields.notes == fields.notes }!
          fields.title = "Edited large notes"
          let command = Mutation(
            action: .edit, listID: "inbox", itemID: created.id, base: created, fields: fields)
          let data = try JSONEncoder().encode(command)
          #expect(data.count < 1_048_576)
          let edited = try await connection.execute(
            .init(
              "/api/mutate", method: .post, authority: "bridge.example.com", headers: headers,
              body: .init(bytes: data)))
          #expect(edited.status == .ok)
          let saved = try await store.current(created.id)
          #expect(saved.fields == fields)
        }
        let before = await store.rows.count
        let oversized = String(repeating: "x", count: 1_048_577)
        let rejected = try await connection.execute(
          .init(
            "/api/mutate", method: .post, authority: "bridge.example.com", headers: headers,
            body: .init(string: oversized)))
        #expect(rejected.status == .contentTooLarge)
        let after = await store.rows.count
        #expect(after == before)
        let session = try await connection.execute(
          .init(
            "/api/session", method: .get, authority: "bridge.example.com", headers: headers,
            body: nil))
        #expect(session.status == .ok)
        let small = try JSONEncoder().encode(
          Mutation(action: .create, listID: "inbox", fields: ReminderFields(title: "Boundary")))
        let exact = Data(repeating: 32, count: 1_048_576 - small.count) + small
        let boundary = try await connection.execute(
          .init(
            "/api/mutate", method: .post, authority: "bridge.example.com", headers: headers,
            body: .init(bytes: exact)))
        #expect(boundary.status == .ok)
        headers[HTTPField.Name("X-CSRF-Token")!] = "wrong"
        let unauthorized = try await connection.execute(
          .init(
            "/api/mutate", method: .post, authority: "bridge.example.com", headers: headers,
            body: .init(string: oversized)))
        #expect(unauthorized.status == .forbidden)
      }
    }
    sharing.stop()
  }
}
