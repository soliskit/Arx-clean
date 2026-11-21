import Foundation
import Testing

@testable import BridgeCore

@MainActor struct CredentialHashTests {
  @Test func pairingHashesOnceWithTwentyClientsAndPreservesRateLimit() throws {
    var hashes = 0
    let c = SharingController(store: FixtureStore()) { value in
      hashes += 1
      return SharingController.digest(value)
    }
    try c.start()
    var secrets: [String] = []
    for index in 0..<20 {
      secrets.append(try c.pairClient(label: "Client \(index)", rights: ClientRights()).1)
    }
    #expect(hashes == 0)
    // Oversized guesses still consume the existing ten-attempt allowance, but never hash.
    for _ in 0..<10 {
      #expect(throws: BridgeFailure.denied) {
        try c.exchange(String(repeating: "x", count: 129))
      }
    }
    #expect(hashes == 0)
    #expect(throws: BridgeFailure.rateLimited) {
      try c.exchange(String(repeating: "界", count: 43))
    }
    #expect(hashes == 0)
    for invalid in ["wrong", String(repeating: "x", count: 128), String(repeating: "界", count: 42)]
    {
      let before = hashes
      #expect(throws: BridgeFailure.rateLimited) { try c.exchange(invalid) }
      #expect(hashes == before + 1)
    }
    // A valid secret remains usable even after strangers exhaust failed guesses.
    for secret in secrets {
      let before = hashes
      _ = try c.exchange(secret)
      #expect(hashes == before + 1)
    }
  }

  @Test func sessionsHashOnceWithTwentyClientsAndRejectOversizedBeforeHashing() throws {
    var hashes = 0
    let c = SharingController(store: FixtureStore()) { value in
      hashes += 1
      return SharingController.digest(value)
    }
    try c.start()
    var tokens: [String] = []
    for index in 0..<20 {
      let (_, secret) = try c.pairClient(label: "Client \(index)", rights: ClientRights())
      tokens.append(try c.exchange(secret).token)
    }
    hashes = 0
    for token in tokens {
      let before = hashes
      _ = try c.sessionState(token)
      #expect(hashes == before + 1)
    }
    for invalid in ["wrong", String(repeating: "x", count: 128), String(repeating: "界", count: 42)]
    {
      let before = hashes
      #expect(throws: BridgeFailure.denied) { try c.sessionState(invalid) }
      #expect(hashes == before + 1)
    }
    for oversized in [String(repeating: "x", count: 129), String(repeating: "界", count: 43)] {
      let before = hashes
      #expect(throws: BridgeFailure.denied) { try c.sessionState(oversized) }
      #expect(hashes == before)
    }
  }
  @Test func mutationIdentityAndEnvelopeEachHashOnceWithTwentyClients() throws {
    var hashes = 0
    let c = SharingController(store: FixtureStore()) { value in
      hashes += 1
      return SharingController.digest(value)
    }
    try c.start()
    var states: [(token: String, csrf: String)] = []
    var rights = ClientRights()
    rights.lists = ["inbox"]
    rights.read = true
    rights.manage = true
    for index in 0..<20 {
      states.append(try c.exchange(c.pairClient(label: "Client \(index)", rights: rights).1))
    }
    for state in states {
      var before = hashes
      try c.authorizeMutationEnvelope(state.token, csrf: state.csrf)
      #expect(hashes == before + 1)
      before = hashes
      _ = try c.mutate(
        state.token, csrf: state.csrf,
        command: .init(action: .create, listID: "inbox", fields: .init(title: "Hash fixture")))
      #expect(hashes == before + 1)
    }
  }

}
