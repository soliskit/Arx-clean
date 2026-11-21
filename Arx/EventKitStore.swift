//
//  EventKitStore.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import BridgeCore
import CoreLocation
@preconcurrency import EventKit
import Foundation

@MainActor final class EventKitStore: ReminderStore {
  private let store = EKEventStore()
  var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
  func connect() async throws {
    guard try await store.requestFullAccessToReminders() else { throw BridgeFailure.denied }
  }
  func lists() throws -> [ReminderList] {
    try access()
    return store.calendars(for: .reminder).map {
      ReminderList(
        id: $0.calendarIdentifier, title: $0.title, source: $0.source.title,
        writable: $0.allowsContentModifications)
    }
  }
  func reminderIDs(in list: String) async throws -> [String] {
    let calendar = try calendar(list)
    let predicate = store.predicateForReminders(in: [calendar])
    let identifiers: [String] = try await withCheckedThrowingContinuation { continuation in
      store.fetchReminders(matching: predicate) { rows in
        guard let rows else {
          continuation.resume(throwing: BridgeFailure.unavailable)
          return
        }
        continuation.resume(returning: rows.map(\.calendarItemIdentifier))
      }
    }
    try access()
    return identifiers
  }
  func current(_ id: String) throws -> SharedReminder { snapshot(try object(id)) }
  func create(in list: String, fields: ReminderFields) throws -> SharedReminder {
    let item = try Self.precommit {
      let destination = try writable(list)
      let item = EKReminder(eventStore: store)
      item.calendar = destination
      try apply(fields, to: item, preserving: nil)
      return item
    }
    do {
      try store.save(item, commit: true)
    } catch {
      item.reset()
      throw BridgeFailure.ambiguous
    }
    return snapshot(item)
  }
  func save(_ updated: SharedReminder, replacing base: SharedReminder) throws -> SharedReminder {
    let (item, destination) = try Self.precommit {
      let item = try object(base.id)
      do {
        guard snapshot(item) == base else { throw BridgeFailure.conflict }
        _ = try writable(base.listID)
        let destination = try writable(updated.listID)
        try apply(updated.fields, to: item, preserving: base)
        return (item, destination)
      } catch {
        item.reset()
        throw error
      }
    }
    do {
      if updated.listID != base.listID { item.calendar = destination }
      try store.save(item, commit: true)
    } catch {
      item.reset()
      throw BridgeFailure.ambiguous
    }
    return snapshot(item)
  }
  func remove(_ reminder: SharedReminder) throws {
    let item = try Self.precommit {
      let item = try object(reminder.id)
      guard snapshot(item) == reminder else { throw BridgeFailure.conflict }
      _ = try writable(reminder.listID)
      return item
    }
    do { try store.remove(item, commit: true) } catch { throw BridgeFailure.ambiguous }
    guard store.calendarItem(withIdentifier: reminder.id) == nil else {
      throw BridgeFailure.ambiguous
    }
  }
  /// The supplied closure must contain preparation only, never save/remove/commit.
  static func precommit<T>(_ prepare: () throws -> T) throws -> T {
    do { return try prepare() } catch {
      throw PrecommitRefusal(error as? BridgeFailure ?? .unavailable)
    }
  }
  private func access() throws { guard authorized else { throw BridgeFailure.unavailable } }
  private func calendar(_ id: String) throws -> EKCalendar {
    try access()
    guard let c = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == id })
    else { throw BridgeFailure.denied }
    return c
  }
  private func writable(_ id: String) throws -> EKCalendar {
    let c = try calendar(id)
    guard c.allowsContentModifications else { throw BridgeFailure.denied }
    return c
  }
  private func object(_ id: String) throws -> EKReminder {
    try access()
    guard let r = store.calendarItem(withIdentifier: id) as? EKReminder, r.refresh() else {
      throw BridgeFailure.denied
    }
    return r
  }
  private func dateValue(_ c: DateComponents?) -> ReminderDate? {
    guard let c, let year = c.year, let month = c.month, let day = c.day else { return nil }
    return ReminderDate(
      year: year, month: month, day: day, hour: c.hour, minute: c.minute,
      timeZone: c.timeZone?.identifier)
  }
  private func components(_ value: ReminderDate?) -> DateComponents? {
    guard let value else { return nil }
    return DateComponents(
      calendar: Calendar(identifier: .gregorian),
      timeZone: value.timeZone.flatMap(TimeZone.init(identifier:)), year: value.year,
      month: value.month, day: value.day, hour: value.hour, minute: value.minute)
  }
  // The wire format exposes second-resolution ISO dates. Compare at the same
  // resolution while leaving unchanged native alarms/rules untouched.
  private func canonicalDate(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
  }
  private func snapshot(_ r: EKReminder) -> SharedReminder {
    var f = ReminderFields(title: r.title ?? "")
    f.notes = r.notes
    f.url = r.url?.absoluteString
    f.location = r.location
    f.priority = r.priority
    f.start = dateValue(r.startDateComponents)
    f.due = dateValue(r.dueDateComponents)
    f.completed = r.isCompleted
    var unsupported = false
    f.alarms = (r.alarms ?? []).compactMap { alarm in
      guard alarm.type == .display || alarm.type == .audio else {
        unsupported = true
        return nil
      }
      if let geo = alarm.structuredLocation?.geoLocation {
        return ReminderAlarm(
          absoluteDate: nil, relativeOffset: nil, latitude: geo.coordinate.latitude,
          longitude: geo.coordinate.longitude, radius: alarm.structuredLocation?.radius ?? 0,
          proximity: alarm.proximity == .enter ? "enter" : "leave",
          label: alarm.structuredLocation?.title)
      }
      return ReminderAlarm(
        absoluteDate: alarm.absoluteDate.map(canonicalDate),
        relativeOffset: alarm.absoluteDate == nil ? alarm.relativeOffset : nil, latitude: nil,
        longitude: nil, radius: nil, proximity: nil, label: nil)
    }
    f.repeats = (r.recurrenceRules ?? []).map { rule in
      ReminderRepeat(
        frequency: ["daily", "weekly", "monthly", "yearly"][rule.frequency.rawValue],
        interval: rule.interval,
        daysOfWeek: rule.daysOfTheWeek?.map {
          RepeatDay(day: $0.dayOfTheWeek.rawValue, week: $0.weekNumber)
        },
        daysOfMonth: rule.daysOfTheMonth?.map(\.intValue),
        monthsOfYear: rule.monthsOfTheYear?.map(\.intValue),
        weeksOfYear: rule.weeksOfTheYear?.map(\.intValue),
        daysOfYear: rule.daysOfTheYear?.map(\.intValue),
        positions: rule.setPositions?.map(\.intValue),
        endDate: rule.recurrenceEnd?.endDate.map(canonicalDate),
        count: (rule.recurrenceEnd?.occurrenceCount ?? 0) > 0
          ? rule.recurrenceEnd!.occurrenceCount : nil,
        calendarIdentifier: rule.calendarIdentifier, firstDayOfWeek: rule.firstDayOfTheWeek)
    }
    return SharedReminder(
      id: r.calendarItemIdentifier, listID: r.calendar.calendarIdentifier, fields: f,
      unsupportedAlarms: unsupported)
  }
  func apply(_ f: ReminderFields, to r: EKReminder, preserving base: SharedReminder?) throws {
    // Unchanged advanced fields are not reconstructed, preserving unsupported patterns.
    var basic = f
    basic.repeats = []
    basic.alarms = []
    try basic.validate()
    // Validate every changed advanced field before touching the EventKit object.
    if f.alarms != base?.fields.alarms {
      guard f.alarms.count <= 10 else { throw BridgeFailure.invalid }
      guard base?.unsupportedAlarms != true else { throw BridgeFailure.invalid }
      for value in f.alarms { try value.validate() }
    }
    if f.repeats != base?.fields.repeats {
      guard f.repeats.count <= 10 else { throw BridgeFailure.invalid }
      for value in f.repeats { try value.validate() }
    }
    if f.alarms != base?.fields.alarms {
      r.alarms = f.alarms.map { value in
        let a: EKAlarm
        if let absolute = value.absoluteDate {
          a = EKAlarm(absoluteDate: absolute)
        } else {
          a = EKAlarm(relativeOffset: value.relativeOffset ?? 0)
        }
        if let lat = value.latitude, let lon = value.longitude {
          let location = EKStructuredLocation(title: value.label ?? "Location")
          location.geoLocation = CLLocation(latitude: lat, longitude: lon)
          location.radius = value.radius ?? 0
          a.structuredLocation = location
          a.proximity = value.proximity == "enter" ? .enter : .leave
        }
        return a
      }
    }
    if f.repeats != base?.fields.repeats {
      for value in f.repeats { try value.validate() }
      r.recurrenceRules = f.repeats.map { value in
        let frequency: EKRecurrenceFrequency = [
          "daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly,
        ][value.frequency]!
        let end =
          value.endDate.map(EKRecurrenceEnd.init(end:))
          ?? value.count.map(EKRecurrenceEnd.init(occurrenceCount:))
        return EKRecurrenceRule(
          recurrenceWith: frequency, interval: value.interval,
          daysOfTheWeek: value.daysOfWeek?.map {
            EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0.day)!, weekNumber: $0.week)
          },
          daysOfTheMonth: value.daysOfMonth?.map(NSNumber.init(value:)),
          monthsOfTheYear: value.monthsOfYear?.map(NSNumber.init(value:)),
          weeksOfTheYear: value.weeksOfYear?.map(NSNumber.init(value:)),
          daysOfTheYear: value.daysOfYear?.map(NSNumber.init(value:)),
          setPositions: value.positions?.map(NSNumber.init(value:)), end: end)
      }
    }
    if base == nil || f.title != base?.fields.title { r.title = f.title }
    if base == nil || f.notes != base?.fields.notes { r.notes = f.notes }
    if base == nil || f.url != base?.fields.url { r.url = f.url.flatMap(URL.init(string:)) }
    if base == nil || f.location != base?.fields.location { r.location = f.location }
    if base == nil || f.priority != base?.fields.priority { r.priority = f.priority }
    if f.start != base?.fields.start { r.startDateComponents = components(f.start) }
    if f.due != base?.fields.due { r.dueDateComponents = components(f.due) }
    if r.isCompleted != f.completed { r.isCompleted = f.completed }
  }
}
