// Fixture-only lifecycle regression. Never constructs an EventKit adapter.
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import BridgeCore

@MainActor private final class ListenerState {
  var ready = false
  var result: String?
}
@MainActor struct ListenerQualificationTests {
  private func launch(_ port: Int) throws -> (Task<Void, Never>, ListenerState, SharingController) {
    let sharing = SharingController(store: FixtureStore())
    try sharing.start()
    let server = BridgeServer(
      sharing: sharing, configuration: try .init(origin: "https://bridge.example.com", port: port))
    let state = ListenerState()
    let task = Task { @MainActor in
      do {
        try await server.run { await MainActor.run { state.ready = true } }
        state.result = "returned"
      } catch { state.result = String(describing: error) }
    }
    return (task, state, sharing)
  }
  private func settle(_ state: ListenerState) async throws {
    for _ in 0..<100 where !state.ready && state.result == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
  }
  private func headers() -> HTTPFields {
    var fields = HTTPFields()
    fields[HTTPField.Name("X-Forwarded-Proto")!] = "https"
    return fields
  }
  @Test(arguments: ["no-client", "closed-client", "open-client"])
  func restartSucceedsAndLivePortStaysExclusive(connection: String) async throws {
    let port = Int.random(in: 20000...60000)
    let (first, firstState, firstSharing) = try launch(port)
    var client: TestClient?
    do {
      try await settle(firstState)
      try #require(firstState.ready, "Fixture listener did not start")
      let (second, secondState, secondSharing) = try launch(port)
      do {
        try await settle(secondState)
        #expect(!secondState.ready)
        #expect(secondState.result?.contains("Address already in use") == true)
      } catch {
        second.cancel()
        await second.value
        secondSharing.stop()
        throw error
      }
      second.cancel()
      await second.value
      secondSharing.stop()
      if connection != "no-client" {
        let opened = TestClient(host: "127.0.0.1", port: port)
        client = opened
        opened.connect()
        let response = try await opened.execute(
          .init(
            "/", method: .get, authority: "bridge.example.com", headers: headers(), body: nil))
        #expect(response.status == .ok)
        if connection == "closed-client" {
          try await opened.shutdown()
          client = nil
        }
      }
      firstSharing.stop()
      first.cancel()
      await first.value
      // For open-client, leave the client object alive through the next bind.
      let (restart, restartState, restartSharing) = try launch(port)
      do {
        try await settle(restartState)
        try #require(
          restartState.ready, "Same-port restart must succeed, not accept address-in-use")
        try await TestClient.withClient(host: "127.0.0.1", port: port) { fresh in
          let response = try await fresh.execute(
            .init(
              "/", method: .get, authority: "bridge.example.com", headers: headers(), body: nil))
          #expect(response.status == .ok)
        }
      } catch {
        restart.cancel()
        await restart.value
        restartSharing.stop()
        throw error
      }
      restartSharing.stop()
      restart.cancel()
      await restart.value
      if let client { try? await client.shutdown() }
      print("LISTENER REGRESSION: \(connection) restart ready; duplicate live listener refused")
    } catch {
      firstSharing.stop()
      first.cancel()
      await first.value
      if let client { try? await client.shutdown() }
      throw error
    }
  }
}
