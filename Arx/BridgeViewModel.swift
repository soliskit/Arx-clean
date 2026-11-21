//
//  BridgeViewModel.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import BridgeCore
import EventKit
import Foundation
import Observation

@MainActor @Observable final class BridgeViewModel {
  let store: any ReminderStore
  let sharing: SharingController
  var lists: [ReminderList] = []
  var clients: [ClientInfo] = []
  var rights = ClientRights()
  var label = "Browser client"
  var origin = ""
  var port = "8765"
  var pairingSecret = ""
  var message = "Connect Reminders to choose what you share."
  var connected = false
  var running = false
  var starting = false
  var stopping = false
  let fixture: Bool
  private var generation = UUID()
  private var serverTask: Task<Void, Never>?
  private var observer: NSObjectProtocol?
  init(fixture: Bool = ProcessInfo.processInfo.arguments.contains("--bridge-fixtures")) {
    self.fixture = fixture
    let store: any ReminderStore = fixture ? FixtureStore() : EventKitStore()
    self.store = store
    self.sharing = SharingController(store: store)
    if fixture {
      connected = true
      refresh()
      if ProcessInfo.processInfo.arguments.contains("--fixture-stopping") {
        stopping = true
        message = "Access revoked. Waiting for the local listener to stop."
      }
    }
    observer = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  func connect() async {
    do {
      if let real = store as? EventKitStore { try await real.connect() }
      connected = true
      refresh()
    } catch {
      message = "Reminders access was denied or could not be granted. Check System Settings."
    }
  }
  func refresh() {
    do {
      lists = try sharing.inventory()
      rights.lists.formIntersection(Set(lists.map(\.id)))
      clients = sharing.clientInfo
      if connected {
        message =
          "Choose lists and actions for a new client. Highlighting a list does not share it."
      }
    } catch {
      connected = false
      lists = []
      rights = ClientRights()
      stop()
      message = "Reminders access is unavailable. Connect again after checking System Settings."
    }
  }
  func start() {
    guard !running, !starting, !stopping, serverTask == nil else { return }
    do {
      let config = try BridgeConfiguration(origin: origin, port: Int(port) ?? 0)
      try sharing.start()
      starting = true
      let server = BridgeServer(sharing: sharing, configuration: config)
      let identity = UUID()
      generation = identity
      serverTask = Task { [self] in
        do {
          try await server.run { [weak self] in
            await self?.listenerStarted(port: config.port, identity: identity)
          }
        } catch is CancellationError {} catch {
          if generation == identity, !Task.isCancelled {
            message =
              "The local listener stopped or could not bind. Check the port and refresh. No wider network bind was attempted."
          }
        }
        guard generation == identity else { return }
        let wasStopping = stopping
        sharing.stop()
        serverTask = nil
        running = false
        starting = false
        stopping = false
        if wasStopping { message = "Sharing stopped. Start the bridge to pair new clients." }
        clients = []
        pairingSecret = ""
      }

    } catch {
      message =
        "Enter an exact HTTPS origin without a path, and a local port from 1024 to 65535."
    }
  }
  private func listenerStarted(port: Int, identity: UUID) {
    guard starting, generation == identity else { return }
    running = true
    starting = false
    message = "Listening on 127.0.0.1:\(port). Remote HTTPS connectivity is not yet verified."
  }
  func stop() {
    sharing.stop()
    running = false
    starting = false
    // Cancellation begins teardown; only the listener task can finish it.
    // Keeping the task blocks a replacement from racing its still-bound socket.
    stopping = serverTask != nil
    message =
      stopping
      ? "Access revoked. Waiting for the local listener to stop."
      : "Sharing stopped. Start the bridge to pair new clients."
    serverTask?.cancel()
    clients = []
    pairingSecret = ""
  }
  func pair() {
    do {
      let (_, secret) = try sharing.pairClient(label: label, rights: rights)
      pairingSecret = secret
      clients = sharing.clientInfo
      message =
        "Single-use pairing secret expires in two minutes. Enter it privately on the HTTPS browser page. Never put it in chat."
    } catch { message = "Could not prepare pairing. Start the service and check selected lists." }
  }
  func revoke(_ client: ClientInfo) {
    sharing.revoke(client.id)
    pairingSecret = ""
    clients = sharing.clientInfo
  }
}
