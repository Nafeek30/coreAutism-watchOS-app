import Foundation
import UserNotifications

struct AutoRecordingPlan {
  let recordingMinutes: Int
  let restMinutes: Int
  let endDate: Date
}
final class AutoRecordingScheduler {
  static let startRequestIdentifier = "auto-recording-start"
  static let startCategoryIdentifier = "AUTO_RECORDING_START"
  static let startActionIdentifier = "START_AUTO_RECORDING"

  private let preferences: PreferencesStore
  init(preferences: PreferencesStore) {
    self.preferences = preferences
  }
  func registerNotificationCategories() {
    let startAction = UNNotificationAction(
      identifier: Self.startActionIdentifier,
      title: "Start Recording",
      options: [.foreground]
    )
    let category = UNNotificationCategory(
      identifier: Self.startCategoryIdentifier,
      actions: [startAction],
      intentIdentifiers: [],
      options: []
    )
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }
  func saveAndSchedule() {
    if preferences.dataCollectionFrequency == .off {
      preferences.autoEnabled = false
      cancel()
      return
    }

    preferences.autoEnabled = true
    cancel()
    scheduleNextStartNotification()
  }
  func cancel() {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
      Self.startRequestIdentifier
    ])
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
      Self.startRequestIdentifier
    ])
  }
  func dismissDeliveredStartNotification() {
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: [Self.startRequestIdentifier]
    )
  }
  func scheduleNextStartNotification(from date: Date = Date()) {
    guard preferences.autoEnabled else { return }
    guard let nextDate = nextStartDate(after: date) else { return }

    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: [Self.startRequestIdentifier]
    )

    let content = UNMutableNotificationContent()
    content.title = "Ready to record?"
    content.body = "Tap to start today's scheduled voice collection."
    content.sound = .default
    content.categoryIdentifier = Self.startCategoryIdentifier

    let components = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute], from: nextDate)
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    let request = UNNotificationRequest(
      identifier: Self.startRequestIdentifier, content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(request)
  }
  func recordingPlan(startingAt startDate: Date = Date()) -> AutoRecordingPlan? {
    let (_, end) = recordingWindow(containing: startDate)
    guard startDate < end, preferences.autoOnMin > 0 else { return nil }

    return AutoRecordingPlan(
      recordingMinutes: preferences.autoOnMin,
      restMinutes: max(preferences.autoOffMin, 0),
      endDate: end
    )
  }
  func nextStartDate(after now: Date) -> Date? {
    let calendar = Calendar.current
    let start = date(
      onSameDayAs: now,
      hour: preferences.autoStartHour,
      minute: preferences.autoStartMinute
    )

    if now < start {
      return start
    }
    return calendar.date(byAdding: .day, value: 1, to: start)
  }
  private func recordingWindow(containing date: Date) -> (start: Date, end: Date) {
    let calendar = Calendar.current
    var start = self.date(
      onSameDayAs: date, hour: preferences.autoStartHour, minute: preferences.autoStartMinute)
    var end = self.date(
      onSameDayAs: date, hour: preferences.autoEndHour, minute: preferences.autoEndMinute)

    if end <= start {
      end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
      if date < start, let previousStart = calendar.date(byAdding: .day, value: -1, to: start),
        let previousEnd = calendar.date(byAdding: .day, value: -1, to: end),
        date < previousEnd
      {
        start = previousStart
        end = previousEnd
      }
    }

    return (start, end)
  }
  private func date(onSameDayAs date: Date, hour: Int, minute: Int) -> Date {
    var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    components.hour = hour
    components.minute = minute
    components.second = 0
    return Calendar.current.date(from: components) ?? date
  }
}
