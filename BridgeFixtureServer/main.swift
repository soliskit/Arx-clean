//
//  main.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import BridgeCore
import Foundation

@main struct FixtureServer {
  @MainActor static func main() async throws {
    // This executable never constructs EventKitStore or requests Apple access.
    guard CommandLine.arguments.count == 4 else { throw BridgeFailure.invalid }
    let origin = CommandLine.arguments[1]
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let port = Int(CommandLine.arguments[3]) ?? 0
    let store = FixtureStore()
    // A separate selected fixture list exercises browser pagination without
    // changing the small CRUD examples or touching real EventKit data.
    store.collections.append(.init(id: "pages", title: "Paged fixture"))
    for index in 0..<105 {
      let id = String(format: "page-%03d", index)
      store.rows[id] = SharedReminder(
        id: id, listID: "pages", fields: .init(title: "Page fixture \(index)"))
    }
    let controller = SharingController(store: store)
    try controller.start()
    var rights = ClientRights()
    rights.read = true
    rights.manage = true
    rights.delete = true
    rights.lists = ["inbox", "weekend", "pages"]
    let (_, secret) = try controller.pairClient(label: "Browser fixture", rights: rights)
    let (_, noneSecret) = try controller.pairClient(
      label: "No-access browser fixture", rights: ClientRights())
    try Data(noneSecret.utf8).write(
      to: directory.appendingPathComponent("pairing-none"), options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: directory.appendingPathComponent("pairing-none").path)
    let server = BridgeServer(
      sharing: controller, configuration: try .init(origin: origin, port: port))
    try Data(secret.utf8).write(to: directory.appendingPathComponent("pairing"), options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("pairing").path)
    try await server.run {
      try? Data().write(to: directory.appendingPathComponent("ready"), options: .atomic)
    }
  }
}
