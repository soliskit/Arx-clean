//
//  ArxApp.swift
//  Arx
//
//  Created by David Solis on 11/14/26.
//

import SwiftUI

@main
struct ArxApp: App {
  @State private var model = BridgeViewModel()
  var body: some Scene {
    Window("Arx", id: "main") {
      #if os(macOS)
        ContentView(model: model)
          .frame(minWidth: 680, minHeight: 420)
      #else
        ContentView(model: model)
      #endif
    }
    #if os(macOS)
      .windowResizability(.contentMinSize)
    #endif
  }
}
