//
//  ModelTests.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation
import Testing

@testable import BridgeCore

struct ModelTests {
  @Test func validDatesAndAlarmsRoundTrip() throws {
    var fields = ReminderFields(title: "Test")
    fields.start = .init(year: 2030, month: 1, day: 1)
    fields.due = .init(
      year: 2030, month: 1, day: 2, hour: 10, minute: 30, timeZone: "America/Los_Angeles")
    fields.alarms = [
      .init(relativeOffset: -900),
      .init(latitude: 37, longitude: -122, radius: 100, proximity: "enter"),
    ]
    fields.repeats = [
      .init(frequency: "weekly", interval: 2, daysOfWeek: [.init(day: 2, week: 0)], count: 3)
    ]
    try fields.validate()
    #expect(
      try JSONDecoder().decode(ReminderFields.self, from: JSONEncoder().encode(fields)) == fields)
  }
  @Test func badDatesRejected() throws {
    for date in [
      ReminderDate(year: 2030, month: 2, day: 30), .init(year: 2030, month: 1, day: 1, hour: 12),
      .init(year: 2030, month: 1, day: 1, hour: 25, minute: 0),
      .init(year: 2030, month: 1, day: 1, timeZone: "Nope/Zone"),
    ] {
      #expect(throws: BridgeFailure.invalid) { try date.validate() }
    }
  }
  @Test func invalidTextURLAlarmAndRecurrence() throws {
    var fields = ReminderFields(title: " ")
    #expect(throws: BridgeFailure.invalid) { try fields.validate() }
    fields.title = "Test"
    fields.url = "file:///secret"
    #expect(throws: BridgeFailure.invalid) { try fields.validate() }
    for alarm in [
      ReminderAlarm(relativeOffset: 1),
      .init(latitude: 99, longitude: 0, radius: 100, proximity: "enter"),
      .init(absoluteDate: Date(), relativeOffset: -1),
    ] {
      #expect(throws: BridgeFailure.invalid) { try alarm.validate() }
    }
    for rule in [
      ReminderRepeat(frequency: "weekly", interval: 0),
      .init(frequency: "monthly", interval: 1, daysOfMonth: [Int.min]),
      .init(frequency: "daily", interval: 1, endDate: Date(), count: 3),
    ] {
      #expect(throws: BridgeFailure.invalid) { try rule.validate() }
    }
  }
}
