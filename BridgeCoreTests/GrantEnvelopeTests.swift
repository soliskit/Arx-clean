import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import BridgeCore

@MainActor struct GrantEnvelopeTests {
  @Test func writeGrantsRequireReadButNoAccessStaysValid() throws {
    let sharing = SharingController(store: FixtureStore())
    try sharing.start()
    defer { sharing.stop() }
    for read in [false, true] {
      for manage in [false, true] {
        for delete in [false, true] {
          var rights = ClientRights()
          rights.read = read
          rights.manage = manage
          rights.delete = delete
          rights.lists = ["inbox"]
          if !read && (manage || delete) {
            #expect(throws: BridgeFailure.invalid) {
              try sharing.pairClient(label: "Fixture", rights: rights)
            }
          } else {
            let state = try sharing.exchange(sharing.pairClient(label: "Fixture", rights: rights).1)
            #expect(try sharing.sessionState(state.token).rights == rights)
          }
        }
      }
    }
    let none = try sharing.exchange(sharing.pairClient(label: "None", rights: ClientRights()).1)
    #expect(try sharing.sessionState(none.token).rights == ClientRights())
  }
  @Test func fallbackGuardsAndReadBodyBoundaries() async throws {
    let sharing = SharingController(store: FixtureStore())
    try sharing.start()
    defer { sharing.stop() }
    var rights = ClientRights()
    rights.read = true
    rights.lists = ["inbox"]
    let state = try sharing.exchange(
      sharing.pairClient(label: "Envelope fixture", rights: rights).1)
    let server = BridgeServer(
      sharing: sharing, configuration: try .init(origin: "https://bridge.example.com", port: 18772))
    try await server.application().test(.live) { live in
      let port = try #require(live.port)
      try await TestClient.withClient(host: "localhost", port: port) { client in
        var headers = HTTPFields()
        headers[HTTPField.Name("X-Forwarded-Proto")!] = "https"
        headers[.origin] = "https://bridge.example.com"
        headers[.contentType] = "application/json"
        headers[.cookie] = "__Host-arx=\(state.token)"
        headers[HTTPField.Name("X-CSRF-Token")!] = state.csrf
        for (path, method) in [("/unknown", HTTPRequest.Method.get), ("/api/read", .put)] {
          let fallback = try await client.execute(
            .init(
              path, method: method, authority: "bridge.example.com", headers: headers, body: nil))
          #expect(fallback.status == .notFound)
          #expect(fallback.headers[.cacheControl] == "no-store")
          #expect(fallback.headers[HTTPField.Name("X-Frame-Options")!] == "DENY")
          #expect(fallback.headers[HTTPField.Name("Content-Security-Policy")!] != nil)
          let wrongHost = try await client.execute(
            .init(path, method: method, authority: "wrong.example.com", headers: headers, body: nil)
          )
          #expect(wrongHost.status == .forbidden)
          let query = try await client.execute(
            .init(
              path + "?x=1", method: method, authority: "bridge.example.com", headers: headers,
              body: nil))
          #expect(query.status == .forbidden)
          var wrongOrigin = headers
          wrongOrigin[.origin] = "https://wrong.example.com"
          let denied = try await client.execute(
            .init(
              path, method: method, authority: "bridge.example.com", headers: wrongOrigin, body: nil
            ))
          #expect(denied.status == .forbidden)
        }
        let valid = "{\"listID\":\"inbox\"}"
        for (body, expected) in [
          (
            String(repeating: " ", count: 65_536 - valid.utf8.count) + valid, HTTPResponse.Status.ok
          ),
          (String(repeating: "x", count: 65_537), .contentTooLarge),
          ("not-json", .badRequest),
        ] {
          let response = try await client.execute(
            .init(
              "/api/read", method: .post, authority: "bridge.example.com", headers: headers,
              body: .init(string: body)))
          #expect(response.status == expected)
          let session = try await client.execute(
            .init(
              "/api/session", method: .get, authority: "bridge.example.com", headers: headers,
              body: nil))
          #expect(session.status == .ok)
        }
        // Malformed JSON with bad credentials must fail authentication, not decoding.
        for badCookie in [false, true] {
          var invalid = headers
          if badCookie {
            invalid[.cookie] = "__Host-arx=wrong"
          } else {
            invalid[HTTPField.Name("X-CSRF-Token")!] = "wrong"
          }
          let denied = try await client.execute(
            .init(
              "/api/read", method: .post, authority: "bridge.example.com", headers: invalid,
              body: .init(string: "not-json")))
          #expect(denied.status == .forbidden)
        }
        let pair = "{\"secret\":\"wrong\"}"
        for (body, expected) in [
          (
            String(repeating: " ", count: 65_536 - pair.utf8.count) + pair,
            HTTPResponse.Status.forbidden
          ),
          (String(repeating: "x", count: 65_537), .contentTooLarge),
        ] {
          let response = try await client.execute(
            .init(
              "/api/pair", method: .post, authority: "bridge.example.com", headers: headers,
              body: .init(string: body)))
          #expect(response.status == expected)
        }
      }
    }
  }
}
