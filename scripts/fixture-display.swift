//
//  fixture-display.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import AppKit
import CoreGraphics
import Foundation

// CI-only: use an advertised mode for the fixture child, then restore it.
@MainActor func withFixtureDisplay() throws -> Int32 {
  guard ProcessInfo.processInfo.environment["CI"] == "true" else {
    throw NSError(
      domain: "FixtureDisplay", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Display setup is restricted to CI."
      ])
  }
  let display = CGMainDisplayID()
  guard let original = CGDisplayCopyDisplayMode(display),
    let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode]
  else {
    throw NSError(
      domain: "FixtureDisplay", code: 2,
      userInfo: [
        NSLocalizedDescriptionKey: "Cannot read the CI display modes."
      ])
  }
  print("CI display \(display): bounds=\(CGDisplayBounds(display))")
  for screen in NSScreen.screens {
    print("Screen frame=\(screen.frame), visible=\(screen.visibleFrame)")
  }
  guard NSScreen.screens.count == 1 else {
    throw NSError(
      domain: "FixtureDisplay", code: 7,
      userInfo: [
        NSLocalizedDescriptionKey: "Fixture display setup requires one CI screen."
      ])
  }
  for mode in modes {
    print("Mode \(mode.ioDisplayModeID): \(mode.width)x\(mode.height)")
  }
  func configure(_ mode: CGDisplayMode) throws {
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success,
      let configuration
    else {
      throw NSError(domain: "FixtureDisplay", code: 3)
    }
    let prepared = CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
    guard prepared == .success else {
      CGCancelDisplayConfiguration(configuration)
      throw NSError(domain: "FixtureDisplay", code: Int(prepared.rawValue))
    }
    let applied = CGCompleteDisplayConfiguration(configuration, .forSession)
    guard applied == .success else {
      throw NSError(domain: "FixtureDisplay", code: Int(applied.rawValue))
    }
  }
  let bounds = CGDisplayBounds(display)
  let needsMode = bounds.width < 1280 || bounds.height < 800
  if needsMode {
    guard
      let selected = modes.filter({ $0.width >= 1280 && $0.height >= 800 })
        .min(by: { $0.width * $0.height < $1.width * $1.height })
    else {
      throw NSError(
        domain: "FixtureDisplay", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey:
            "No advertised CI mode is large enough for the 1200x650 fixture."
        ])
    }
    try configure(selected)
    print("Selected temporary CI mode \(selected.ioDisplayModeID)")
  }
  var result: Int32 = 1
  var childError: (any Error)?
  do {
    for _ in 0..<20 {
      if CGDisplayBounds(display).width >= 1280 && CGDisplayBounds(display).height >= 800 { break }
      Thread.sleep(forTimeInterval: 0.1)
    }
    guard CGDisplayBounds(display).width >= 1280 && CGDisplayBounds(display).height >= 800 else {
      throw NSError(
        domain: "FixtureDisplay", code: 5,
        userInfo: [
          NSLocalizedDescriptionKey: "CI display did not reach the required geometry."
        ])
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/bash")
    child.arguments = [CommandLine.arguments[1]]
    var environment = ProcessInfo.processInfo.environment
    environment["ARX_FIXTURE_DISPLAY_READY"] = "1"
    child.environment = environment
    try child.run()
    child.waitUntilExit()
    result = child.terminationStatus
  } catch {
    childError = error
  }
  if needsMode {
    try configure(original)
    guard CGDisplayCopyDisplayMode(display)?.ioDisplayModeID == original.ioDisplayModeID else {
      throw NSError(
        domain: "FixtureDisplay", code: 6,
        userInfo: [
          NSLocalizedDescriptionKey: "CI display mode restoration did not match."
        ])
    }
    print("Restored CI mode \(original.ioDisplayModeID)")
  }
  if let childError { throw childError }
  return result
}

do {
  exit(try await withFixtureDisplay())
} catch {
  FileHandle.standardError.write(Data("Fixture display error: \(error)\n".utf8))
  exit(1)
}
