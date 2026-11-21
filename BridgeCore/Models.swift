//
//  Models.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation

public enum BridgeFailure: Error, Equatable, Sendable {
  case denied, invalid, conflict, unavailable, ambiguous, rateLimited, sessionFull, tooLarge
}

/// Only a store path proved to run before any persistent write may throw this.
public struct PrecommitRefusal: Error, Sendable {
  public let failure: BridgeFailure
  public init(_ failure: BridgeFailure) { self.failure = failure }
}
public enum WriteOutcome: String, Codable, Sendable { case refused, unknown, committed }
public struct WriteFailure: Error, Equatable, Sendable {
  public let failure: BridgeFailure
  public let outcome: WriteOutcome
  public init(_ failure: BridgeFailure, outcome: WriteOutcome) {
    self.failure = failure
    self.outcome = outcome
  }
}

public struct ReminderList: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var source: String
  public var writable: Bool
  public init(id: String, title: String, source: String = "", writable: Bool = true) {
    self.id = id
    self.title = title
    self.source = source
    self.writable = writable
  }
}

public struct ReminderDate: Codable, Equatable, Sendable {
  public var year: Int
  public var month: Int
  public var day: Int
  public var hour: Int?
  public var minute: Int?
  public var timeZone: String?
  public init(
    year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil, timeZone: String? = nil
  ) {
    self.year = year
    self.month = month
    self.day = day
    self.hour = hour
    self.minute = minute
    self.timeZone = timeZone
  }
  public func validate() throws {
    guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
      (hour == nil) == (minute == nil), hour.map({ (0...23).contains($0) }) ?? true,
      minute.map({ (0...59).contains($0) }) ?? true,
      timeZone.map({ TimeZone(identifier: $0) != nil }) ?? true
    else { throw BridgeFailure.invalid }
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = DateComponents(year: year, month: month, day: day)
    guard let date = c.date(from: parts),
      c.dateComponents([.year, .month, .day], from: date) == parts
    else { throw BridgeFailure.invalid }
  }
}

public struct ReminderAlarm: Codable, Equatable, Sendable {
  public var absoluteDate: Date?
  public var relativeOffset: Double?
  public var latitude: Double?
  public var longitude: Double?
  public var radius: Double?
  public var proximity: String?
  public var label: String?
  public init(
    absoluteDate: Date? = nil, relativeOffset: Double? = nil, latitude: Double? = nil,
    longitude: Double? = nil, radius: Double? = nil, proximity: String? = nil, label: String? = nil
  ) {
    self.absoluteDate = absoluteDate
    self.relativeOffset = relativeOffset
    self.latitude = latitude
    self.longitude = longitude
    self.radius = radius
    self.proximity = proximity
    self.label = label
  }
  public func validate() throws {
    let geo = latitude != nil || longitude != nil || proximity != nil || radius != nil
    guard [absoluteDate != nil, relativeOffset != nil, geo].filter({ $0 }).count == 1 else {
      throw BridgeFailure.invalid
    }
    if let offset = relativeOffset {
      guard offset.isFinite, (-31_536_000...0).contains(offset) else { throw BridgeFailure.invalid }
    }
    if geo {
      guard let lat = latitude, let lon = longitude, let r = radius, let p = proximity,
        lat.isFinite, lon.isFinite, r.isFinite, (-90...90).contains(lat),
        (-180...180).contains(lon), (0...100_000).contains(r), ["enter", "leave"].contains(p)
      else { throw BridgeFailure.invalid }
    }
    guard (label?.count ?? 0) <= 256 else { throw BridgeFailure.invalid }
  }
}

public struct RepeatDay: Codable, Equatable, Sendable {
  public var day: Int
  public var week: Int
  public init(day: Int, week: Int) {
    self.day = day
    self.week = week
  }
}
public struct ReminderRepeat: Codable, Equatable, Sendable {
  public var frequency: String
  public var interval: Int
  public var daysOfWeek: [RepeatDay]?
  public var daysOfMonth: [Int]?
  public var monthsOfYear: [Int]?
  public var weeksOfYear: [Int]?
  public var daysOfYear: [Int]?
  public var positions: [Int]?
  public var endDate: Date?
  public var count: Int?
  public var calendarIdentifier: String?
  public var firstDayOfWeek: Int?
  public init(
    frequency: String, interval: Int, daysOfWeek: [RepeatDay]? = nil, daysOfMonth: [Int]? = nil,
    monthsOfYear: [Int]? = nil, weeksOfYear: [Int]? = nil, daysOfYear: [Int]? = nil,
    positions: [Int]? = nil, endDate: Date? = nil, count: Int? = nil,
    calendarIdentifier: String? = nil, firstDayOfWeek: Int? = nil
  ) {
    self.frequency = frequency
    self.interval = interval
    self.daysOfWeek = daysOfWeek
    self.daysOfMonth = daysOfMonth
    self.monthsOfYear = monthsOfYear
    self.weeksOfYear = weeksOfYear
    self.daysOfYear = daysOfYear
    self.positions = positions
    self.endDate = endDate
    self.count = count
    self.calendarIdentifier = calendarIdentifier
    self.firstDayOfWeek = firstDayOfWeek
  }
  public func validate() throws {
    guard ["daily", "weekly", "monthly", "yearly"].contains(frequency),
      (1...999).contains(interval),
      !(count != nil && endDate != nil), count.map({ (1...100_000).contains($0) }) ?? true,
      calendarIdentifier == nil || calendarIdentifier == "gregorian",
      firstDayOfWeek == nil || firstDayOfWeek == 0, (daysOfWeek?.count ?? 0) <= 100,
      daysOfWeek?.allSatisfy({ (1...7).contains($0.day) && (-53...53).contains($0.week) }) ?? true
    else { throw BridgeFailure.invalid }
    for (values, limit) in [
      (daysOfMonth, 31), (monthsOfYear, 12), (weeksOfYear, 53), (daysOfYear, 366), (positions, 366),
    ] {
      guard (values?.count ?? 0) <= 366,
        values?.allSatisfy({ $0 != 0 && (-limit...limit).contains($0) }) ?? true
      else { throw BridgeFailure.invalid }
    }
    guard monthsOfYear?.allSatisfy({ $0 > 0 }) ?? true else { throw BridgeFailure.invalid }
  }
}

public struct ReminderFields: Codable, Equatable, Sendable {
  public var title: String = ""
  public var notes: String? = nil
  public var url: String? = nil
  public var location: String? = nil
  public var priority: Int = 0
  public var start: ReminderDate? = nil
  public var due: ReminderDate? = nil
  public var completed: Bool = false
  public var alarms: [ReminderAlarm] = []
  public var repeats: [ReminderRepeat] = []
  public init(title: String = "") { self.title = title }
  public func validate() throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 1024,
      (notes?.count ?? 0) <= 32_768, (location?.count ?? 0) <= 1024,
      (url?.count ?? 0) <= 2048, (0...9).contains(priority), alarms.count <= 10, repeats.count <= 10
    else { throw BridgeFailure.invalid }
    if let url {
      guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
        u.host != nil, u.user == nil, u.password == nil
      else { throw BridgeFailure.invalid }
    }
    try start?.validate()
    try due?.validate()
    for a in alarms { try a.validate() }
    for r in repeats { try r.validate() }
  }
}

public struct SharedReminder: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var listID: String
  public var fields: ReminderFields
  public var unsupportedAlarms: Bool = false
  public init(id: String, listID: String, fields: ReminderFields, unsupportedAlarms: Bool = false) {
    self.id = id
    self.listID = listID
    self.fields = fields
    self.unsupportedAlarms = unsupportedAlarms
  }
}

public struct ClientRights: Codable, Equatable, Sendable {
  public var lists: Set<String> = []
  public var read = false
  public var manage = false
  public var delete = false
  public init() {}
}

public struct ClientInfo: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var label: String
  public var rights: ClientRights
  public var paired: Bool
}

public struct Mutation: Codable, Sendable {
  public enum Action: String, Codable, Sendable {
    case create, edit, move, complete, reopen, delete
  }
  public var operationID: UUID
  public var action: Action
  public var listID: String
  public var itemID: String?
  public var base: SharedReminder?
  public var fields: ReminderFields?
  public var destination: String?
  public var confirmation: String?
  public init(
    operationID: UUID = UUID(), action: Action, listID: String, itemID: String? = nil,
    base: SharedReminder? = nil, fields: ReminderFields? = nil, destination: String? = nil,
    confirmation: String? = nil
  ) {
    self.operationID = operationID
    self.action = action
    self.listID = listID
    self.itemID = itemID
    self.base = base
    self.fields = fields
    self.destination = destination
    self.confirmation = confirmation
  }
}

public struct ReminderPage: Codable, Sendable {
  public var items: [SharedReminder]
  public var next: String?
  public var previous: String?
}

@MainActor public protocol ReminderStore: AnyObject {
  var authorized: Bool { get }
  func lists() throws -> [ReminderList]
  func reminderIDs(in list: String) async throws -> [String]
  func current(_ id: String) throws -> SharedReminder
  func create(in list: String, fields: ReminderFields) throws -> SharedReminder
  func save(_ item: SharedReminder, replacing base: SharedReminder) throws -> SharedReminder
  func remove(_ item: SharedReminder) throws
}
