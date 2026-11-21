//
//  ContentView.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import BridgeCore
import SwiftUI

struct ContentView: View {
  let model: BridgeViewModel
  @State private var highlighted: String?
  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 12) {
        if model.fixture {
          Text("Fixture data - no real Reminders access").font(.caption).foregroundStyle(.primary)
        }
        if model.connected {
          List(model.lists, selection: $highlighted) { list in
            Toggle(
              isOn: Binding(
                get: { model.rights.lists.contains(list.id) },
                set: { enabled in
                  if enabled {
                    model.rights.lists.insert(list.id)
                  } else {
                    model.rights.lists.remove(list.id)
                  }
                })
            ) {
              VStack(alignment: .leading) {
                Text(list.title)
                Text(list.source + (list.writable ? "" : " · Read-only")).font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .accessibilityLabel(list.title)
            .accessibilityIdentifier("list-grant-" + list.id)
            .tag(list.id)
          }
          Button("Refresh lists") { model.refresh() }
        } else {
          Text(
            "Apple grants full Reminders access. Arx shares only the lists and actions you select for each paired client."
          )
          Button("Connect Reminders") { Task { await model.connect() } }.buttonStyle(
            .borderedProminent)
        }
      }.padding().navigationTitle("Lists to share")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lists to share")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Arx bridge").font(.largeTitle)
          Text(model.message).accessibilityIdentifier("bridge-status")
          GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 10) {
              TextField("Exact remote HTTPS origin", text: $model.origin).textContentType(.URL)
                .disabled(model.running || model.starting || model.stopping)
              TextField("Local port", text: $model.port).disabled(
                model.running || model.starting || model.stopping)
              Text(
                "Keep the Mac, Arx and your connector running."
              ).font(.caption).foregroundStyle(.primary)
              HStack {
                Button(
                  model.running
                    ? "Listener running"
                    : model.starting
                      ? "Starting listener"
                      : model.stopping ? "Stopping listener" : "Start bridge"
                ) { model.start() }
                .accessibilityIdentifier("bridge-start")
                .disabled(!model.connected || model.running || model.starting || model.stopping)
                Button("Stop all sharing", role: .destructive) { model.stop() }
                  .accessibilityIdentifier("bridge-stop")
                  .disabled(!model.running)
              }
            }.padding(6)
          }
          GroupBox("New client") {
            VStack(alignment: .leading, spacing: 10) {
              TextField("Client label", text: $model.label)
              Toggle("Read selected lists", isOn: $model.rights.read)
              Toggle("Create, edit, move, complete and reopen", isOn: $model.rights.manage)
                .disabled(!model.rights.read)
              Toggle("Delete reminders with confirmation", isOn: $model.rights.delete)
                .disabled(!model.rights.read)
              Text(
                "Select this new client's access. To change an existing client, revoke and pair again."
              ).font(.caption).foregroundStyle(.secondary)
              Button("Create single-use pairing secret") { model.pair() }.disabled(
                !model.running && !model.starting)
              if !model.pairingSecret.isEmpty {
                SecureField("Pairing secret", text: $model.pairingSecret).privacySensitive()
                Button("Copy pairing secret") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(model.pairingSecret, forType: .string)
                }
                Button("Hide secret") { model.pairingSecret = "" }
              }
            }.padding(6)
          }
          GroupBox("Clients") {
            VStack(alignment: .leading, spacing: 8) {
              Button("Refresh client status") { model.clients = model.sharing.clientInfo }
              if model.clients.isEmpty { Text("No client has access.").foregroundStyle(.secondary) }
              ForEach(model.clients) { client in
                HStack {
                  VStack(alignment: .leading) {
                    Text(client.label)
                    Text(
                      "\(client.rights.lists.count) lists · \(client.paired ? "Paired" : "Awaiting pairing")"
                    ).font(.caption)
                  }
                  Spacer()
                  Button("Revoke", role: .destructive) { model.revoke(client) }
                }
              }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
          }
          Text(
            "Revoke stops new requests. Data already viewed and changes already saved remain."
          ).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: 760, alignment: .leading)
      }.navigationTitle("Sharing")
    }
    .onChange(of: model.rights.read) { _, enabled in
      if !enabled {
        model.rights.manage = false
        model.rights.delete = false
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) {
      _ in model.stop()
    }
  }
}

#Preview { ContentView(model: BridgeViewModel(fixture: true)) }
