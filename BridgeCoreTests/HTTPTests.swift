//
//  HTTPTests.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import BridgeCore

struct HTTPTests {
  @Test @MainActor func realListenerAndRoutes() async throws {
    let sharing = SharingController(store: FixtureStore())
    try sharing.start()
    var rights = ClientRights()
    rights.lists = ["inbox"]
    rights.read = true
    rights.manage = true
    let (_, secret) = try sharing.pairClient(label: "HTTP fixture", rights: rights)
    let server = BridgeServer(
      sharing: sharing, configuration: try .init(origin: "https://bridge.example.com", port: 18765))
    let app = server.application()
    // .live actually binds and sends HTTP, not just a direct router dispatch.
    try await app.test(.live) { live in
      guard let port = live.port else { throw BridgeFailure.unavailable }
      try await TestClient.withClient(host: "localhost", port: port) { connection in
        let client = WireFixture(connection: connection)
        var headers = HTTPFields()
        headers[HTTPField.Name("Host")!] = "bridge.example.com"
        headers[HTTPField.Name("X-Forwarded-Proto")!] = "https"
        headers[.origin] = "https://bridge.example.com"
        headers[.contentType] = "application/json"
        try await client.execute(uri: "/", method: .get, headers: headers) { response in
          #expect(response.status == .ok)
          #expect(String(buffer: response.body ?? .init()).contains("Pair this browser"))
          #expect(!String(buffer: response.body ?? .init()).contains("Return the library book"))
          #expect(response.headers[.cacheControl] == "no-store")
          #expect(
            response.headers[HTTPField.Name("Content-Security-Policy")!]?.contains(
              "frame-ancestors 'none'") == true)
        }
        try await client.execute(uri: "/api/lists", method: .get, headers: headers) { response in
          #expect(response.status == .forbidden)
        }
        var wrongOrigin = headers
        wrongOrigin[.origin] = "https://attacker.example"
        try await client.execute(
          uri: "/api/pair", method: .post, headers: wrongOrigin,
          body: "{\"secret\":\"\(secret)\"}"
        ) { response in #expect(response.status == .forbidden) }
        var pairHeaders = headers
        var cookie: String = ""
        var csrf = ""
        try await client.execute(
          uri: "/api/pair", method: .post, headers: headers,
          body: "{\"secret\":\"\(secret)\"}"
        ) { response in
          #expect(response.status == .ok)
          cookie = response.headers[.setCookie] ?? ""
          let data = Data((response.body ?? .init()).readableBytesView)
          csrf = try JSONDecoder().decode(WireSession.self, from: data).csrf
          #expect(cookie.contains("Secure; HttpOnly; SameSite=Strict"))
          #expect(!String(buffer: response.body ?? .init()).contains(secret))
        }
        pairHeaders[.cookie] = String(cookie.split(separator: ";").first ?? "")
        try await client.execute(uri: "/api/lists", method: .get, headers: pairHeaders) {
          response in
          #expect(response.status == .ok)
          #expect(String(buffer: response.body ?? .init()).contains("Inbox"))
          #expect(!String(buffer: response.body ?? .init()).contains("Fixture account"))
          #expect(!String(buffer: response.body ?? .init()).contains("Weekend"))
        }
        try await client.execute(
          uri: "/api/read", method: .post, headers: pairHeaders,
          body: "{\"listID\":\"inbox\"}"
        ) { response in #expect(response.status == .forbidden) }
        try await client.execute(
          uri: "/api/session?token=forbidden", method: .get, headers: pairHeaders
        ) { response in #expect(response.status == .forbidden) }
        var wrongHost = headers
        wrongHost[HTTPField.Name("Host")!] = "attacker.example"
        try await client.execute(uri: "/", method: .get, headers: wrongHost) { response in
          #expect(response.status == .forbidden)
        }
        var readHeaders = pairHeaders
        readHeaders[HTTPField.Name("X-CSRF-Token")!] = csrf
        try await client.execute(
          uri: "/api/read", method: .post, headers: readHeaders,
          body: "{\"listID\":\"inbox\"}"
        ) { response in
          #expect(response.status == .ok)
          let data = Data((response.body ?? .init()).readableBytesView)
          let page = try JSONDecoder().decode(ReminderPage.self, from: data)
          #expect(page.items.map(\.id) == ["book"])
          #expect(page.next == nil)
        }
        try await client.execute(
          uri: "/", method: .get, headers: headers, duplicateHost: "attacker.example"
        ) { response in
          #expect(response.status == .forbidden || response.status == .badRequest)
        }
      }
    }
    sharing.stop()
  }
}

// Hummingbird's live convenience client fixes authority to localhost. Use its
// bound port with a separate real connection so the test sends exactly the
// remote Host authority, not a second raw Host beside localhost.
private struct WireFixture {
  let connection: TestClient
  func execute(
    uri: String, method: HTTPRequest.Method, headers: HTTPFields,
    body: String? = nil, duplicateHost: String? = nil,
    testCallback: (TestClient.Response) async throws -> Void
  ) async throws {
    var fields = headers
    let host = HTTPField.Name("Host")!
    let authority = fields[host]
    fields[host] = duplicateHost
    let request = TestClient.Request(
      uri, method: method, authority: authority,
      headers: fields, body: body.map { .init(string: $0) })
    let response = try await connection.execute(request)
    try await testCallback(response)
  }
}

private struct WireSession: Decodable { var csrf: String }
