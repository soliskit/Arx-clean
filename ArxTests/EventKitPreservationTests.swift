//
//  EventKitPreservationTests.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import BridgeCore
import EventKit
import Foundation
import Testing

@testable import Arx

@MainActor struct EventKitPreservationTests {
  @Test func preparationRefusalIsExplicitAndDoesNotRunLaterWriteStep() throws {
    var commits = 0
    do {
      let _: Int = try EventKitStore.precommit { throw BridgeFailure.conflict }
      commits += 1
      Issue.record("Preparation unexpectedly succeeded")
    } catch let refusal as PrecommitRefusal {
      #expect(refusal.failure == .conflict)
    }
    #expect(commits == 0)
    let prepared = try EventKitStore.precommit { 7 }
    #expect(prepared == 7)
  }
  @Test func notesEditPreservesNativeDateComponents() throws {
    let adapter = EventKitStore()
    // Detached, unsaved object only. No request for access or store fetch.
    let reminder = EKReminder(eventStore: EKEventStore())
    var native = DateComponents()
    native.calendar = Calendar(identifier: .gregorian)
    native.year = 2030
    native.month = 2
    native.day = 3
    native.hour = 10
    native.minute = 20
    native.second = 37
    reminder.startDateComponents = native
    reminder.dueDateComponents = native
    let savedStart = reminder.startDateComponents
    let savedDue = reminder.dueDateComponents
    try #require(savedStart?.second == 37)
    try #require(savedDue?.second == 37)
    var fields = ReminderFields(title: "Fixture")
    fields.start = .init(year: 2030, month: 2, day: 3, hour: 10, minute: 20)
    fields.due = fields.start
    let base = SharedReminder(id: "fixture", listID: "fixture", fields: fields)
    fields.notes = "Only notes changed"
    try adapter.apply(fields, to: reminder, preserving: base)
    #expect(reminder.notes == "Only notes changed")
    #expect(reminder.startDateComponents == savedStart)
    #expect(reminder.dueDateComponents == savedDue)
  }

  @Test func invalidRepeatDoesNotDirtyAnEarlierAlarmChange() throws {
    let adapter = EventKitStore()
    let reminder = EKReminder(eventStore: EKEventStore())
    reminder.title = "Fixture"
    reminder.alarms = [EKAlarm(relativeOffset: -900)]
    var fields = ReminderFields(title: "Fixture")
    fields.alarms = [.init(relativeOffset: -900)]
    let base = SharedReminder(id: "fixture", listID: "fixture", fields: fields)
    fields.alarms = [.init(relativeOffset: -3600)]
    fields.repeats = [.init(frequency: "invalid", interval: 1)]
    #expect(throws: BridgeFailure.invalid) {
      try adapter.apply(fields, to: reminder, preserving: base)
    }
    #expect(reminder.alarms?.first?.relativeOffset == -900)
    fields = base.fields
    fields.notes = "Later valid notes"
    try adapter.apply(fields, to: reminder, preserving: base)
    #expect(reminder.alarms?.first?.relativeOffset == -900)
  }

  @Test func notesEditPreservesExistingCompletionDate() throws {
    let adapter = EventKitStore()
    let reminder = EKReminder(eventStore: EKEventStore())
    reminder.title = "Completed fixture"
    let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
    reminder.completionDate = completedAt
    try #require(reminder.isCompleted)
    try #require(reminder.completionDate == completedAt)
    var fields = ReminderFields(title: "Completed fixture")
    fields.completed = true
    let base = SharedReminder(id: "fixture", listID: "fixture", fields: fields)
    fields.notes = "Only notes changed"
    try adapter.apply(fields, to: reminder, preserving: base)
    #expect(reminder.notes == "Only notes changed")
    #expect(reminder.isCompleted)
    #expect(reminder.completionDate == completedAt)
  }

  @Test func invalidStoredURLRejectsCompletionBeforeChangingObject() throws {
    let adapter = EventKitStore()
    let reminder = EKReminder(eventStore: EKEventStore())
    reminder.title = "URL fixture"
    reminder.url = URL(string: "mailto:fixture@example.com")
    var fields = ReminderFields(title: "URL fixture")
    fields.url = reminder.url?.absoluteString
    let base = SharedReminder(id: "fixture", listID: "fixture", fields: fields)
    fields.completed = true
    #expect(throws: BridgeFailure.invalid) {
      try adapter.apply(fields, to: reminder, preserving: base)
    }
    #expect(!reminder.isCompleted)
    #expect(reminder.completionDate == nil)
    #expect(reminder.url?.absoluteString == "mailto:fixture@example.com")
  }

  @Test func advancedCountRefusalDoesNotDirtyDetachedReminder() throws {
    let adapter = EventKitStore()
    for alarms in [true, false] {
      let reminder = EKReminder(eventStore: EKEventStore())
      reminder.title = "Count fixture"
      reminder.alarms = [EKAlarm(relativeOffset: -900)]
      var fields = ReminderFields(title: "Count fixture")
      fields.alarms = [.init(relativeOffset: -900)]
      let base = SharedReminder(id: "fixture", listID: "fixture", fields: fields)
      fields.notes = "Must not be assigned"
      if alarms {
        fields.alarms = Array(repeating: .init(relativeOffset: -60), count: 11)
      } else {
        fields.alarms = [.init(relativeOffset: -120)]
        fields.repeats = Array(repeating: .init(frequency: "daily", interval: 1), count: 11)
      }
      // New-object and edit paths both reject before assigning any fields.
      for prior in [nil, Optional(base)] {
        #expect(throws: BridgeFailure.invalid) {
          try adapter.apply(fields, to: reminder, preserving: prior)
        }
        #expect(reminder.title == "Count fixture")
        #expect(reminder.notes == nil)
        #expect(reminder.alarms?.count == 1)
        #expect(reminder.alarms?.first?.relativeOffset == -900)
      }
    }
  }

}

@MainActor struct BasicFieldPreservationTests {
  @Test func unchangedWireValuesDoNotAssignNativeBasicFields() throws {
    let adapter = EventKitStore()
    let reminder = EKReminder(eventStore: EKEventStore())
    reminder.title = "Native title"
    reminder.notes = "Native notes"
    reminder.url = URL(string: "https://native.example.com")
    reminder.location = "Native location"
    reminder.priority = 3
    var fields = ReminderFields(title: "Wire base title")
    fields.notes = "Wire base notes"
    fields.url = "https://base.example.com"
    fields.location = "Wire base location"
    fields.priority = 5
    let base = SharedReminder(id: "fixture", listID: "fixture", fields: fields)
    // Deliberately distinct native sentinels prove setters are skipped. In a real
    // save, the fresh-snapshot conflict guard runs before this adapter step.
    fields.completed = true
    try adapter.apply(fields, to: reminder, preserving: base)
    #expect(reminder.title == "Native title")
    #expect(reminder.notes == "Native notes")
    #expect(reminder.url?.absoluteString == "https://native.example.com")
    #expect(reminder.location == "Native location")
    #expect(reminder.priority == 3)
    #expect(reminder.isCompleted)
  }
  @Test func creationAndDeliberateBasicEditsStillAssignAndClear() throws {
    let adapter = EventKitStore()
    let reminder = EKReminder(eventStore: EKEventStore())
    var fields = ReminderFields(title: "Created")
    fields.notes = "Notes"
    fields.url = "https://fixture.example.com"
    fields.location = "Location"
    fields.priority = 5
    try adapter.apply(fields, to: reminder, preserving: nil)
    #expect(reminder.title == fields.title)
    #expect(reminder.notes == fields.notes)
    #expect(reminder.url?.absoluteString == fields.url)
    #expect(reminder.location == fields.location)
    #expect(reminder.priority == fields.priority)
    let base = SharedReminder(id: "fixture", listID: "fixture", fields: fields)
    fields.title = "Edited"
    fields.notes = nil
    fields.url = nil
    fields.location = nil
    fields.priority = 0
    try adapter.apply(fields, to: reminder, preserving: base)
    #expect(reminder.title == "Edited")
    #expect(reminder.notes == nil && reminder.url == nil && reminder.location == nil)
    #expect(reminder.priority == 0)
  }
}
