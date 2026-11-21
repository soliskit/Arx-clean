//
//  SampleNavigation.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation

struct SampleReminder: Identifiable, Equatable {
  let id: String
  let title: String
  let notes: String
}

struct SampleList: Identifiable, Equatable {
  let id: String
  let title: String
  let reminders: [SampleReminder]

  static let examples = [
    SampleList(
      id: "inbox", title: "Inbox",
      reminders: [
        SampleReminder(
          id: "book", title: "Return the library book", notes: "Bring it on the next walk."),
        SampleReminder(id: "plants", title: "Water the plants", notes: "Check the soil first."),
      ]),
    SampleList(
      id: "weekend", title: "Weekend",
      reminders: [
        SampleReminder(
          id: "walk", title: "Plan a walk", notes: "Choose a new route through the park.")
      ]),
    SampleList(id: "later", title: "Later", reminders: []),
  ]
}

struct SampleNavigation {
  let lists: [SampleList]
  private(set) var listID: String?
  private(set) var reminderID: String?

  init(lists: [SampleList] = SampleList.examples) {
    self.lists = lists
    listID = lists.first?.id
  }

  var selectedList: SampleList? {
    lists.first { $0.id == listID }
  }

  var selectedReminder: SampleReminder? {
    selectedList?.reminders.first { $0.id == reminderID }
  }

  mutating func selectList(_ id: String?) {
    guard listID != id else { return }
    listID = lists.first { $0.id == id }?.id
    reminderID = nil
  }

  mutating func selectReminder(_ id: String?) {
    reminderID = selectedList?.reminders.first { $0.id == id }?.id
  }
}
