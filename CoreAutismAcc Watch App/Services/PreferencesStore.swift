import Combine
import Foundation

enum DataCollectionFrequency: String, CaseIterable, Identifiable {
  case continuous15 = "Continuous (default 15 minutes)"
  case hourly = "Every hour"
  case every30 = "Every 30 minutes"
  case off = "Off"

  var id: String { rawValue }
  var onOffMinutes: (on: Int, off: Int) {
    switch self {
    case .continuous15:
      return (15, 15)
    case .hourly:
      return (60, 60)
    case .every30:
      return (30, 30)
    case .off:
      return (0, 0)
    }
  }
}
final class PreferencesStore: ObservableObject {
  private enum Key {
    static let userName = "user_name"
    static let firstTime = "first_time"
    static let recordingMade = "recording_made"
    static let totalRecordingTime = "total_recording_time"
    static let dataCollectionFrequency = "dataCollectionFrequency"
    static let autoEnabled = "auto_enabled"
    static let autoStartHour = "auto_start_hour"
    static let autoStartMinute = "auto_start_minute"
    static let autoEndHour = "auto_end_hour"
    static let autoEndMinute = "auto_end_minute"
    static let autoOnMin = "auto_on_min"
    static let autoOffMin = "auto_off_min"
    static let uploadBaseURL = "upload_base_url"
  }

  private let defaults: UserDefaults
  @Published var userName: String {
    didSet { defaults.set(userName, forKey: Key.userName) }
  }
  @Published var firstTime: Bool {
    didSet { defaults.set(firstTime, forKey: Key.firstTime) }
  }
  @Published var recordingMade: Bool {
    didSet { defaults.set(recordingMade, forKey: Key.recordingMade) }
  }
  @Published var totalRecordingTime: TimeInterval {
    didSet { defaults.set(totalRecordingTime, forKey: Key.totalRecordingTime) }
  }
  @Published var dataCollectionFrequency: DataCollectionFrequency {
    didSet {
      defaults.set(dataCollectionFrequency.rawValue, forKey: Key.dataCollectionFrequency)
      let minutes = dataCollectionFrequency.onOffMinutes
      if dataCollectionFrequency != .off {
        autoOnMin = minutes.on
        autoOffMin = minutes.off
      }
    }
  }
  @Published var autoEnabled: Bool {
    didSet { defaults.set(autoEnabled, forKey: Key.autoEnabled) }
  }
  @Published var autoStartHour: Int {
    didSet { defaults.set(autoStartHour, forKey: Key.autoStartHour) }
  }
  @Published var autoStartMinute: Int {
    didSet { defaults.set(autoStartMinute, forKey: Key.autoStartMinute) }
  }
  @Published var autoEndHour: Int {
    didSet { defaults.set(autoEndHour, forKey: Key.autoEndHour) }
  }
  @Published var autoEndMinute: Int {
    didSet { defaults.set(autoEndMinute, forKey: Key.autoEndMinute) }
  }
  @Published var autoOnMin: Int {
    didSet { defaults.set(autoOnMin, forKey: Key.autoOnMin) }
  }
  @Published var autoOffMin: Int {
    didSet { defaults.set(autoOffMin, forKey: Key.autoOffMin) }
  }
  var uploadBaseURL: URL? {
    guard let value = defaults.string(forKey: Key.uploadBaseURL), !value.isEmpty else {
      return nil
    }
    return URL(string: value)
  }
  var isLoggedIn: Bool {
    !userName.isEmpty && !firstTime
  }
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    if defaults.object(forKey: Key.firstTime) == nil {
      defaults.set(true, forKey: Key.firstTime)
      defaults.set(false, forKey: Key.recordingMade)
      defaults.set(0.0, forKey: Key.totalRecordingTime)
      defaults.set(
        DataCollectionFrequency.continuous15.rawValue, forKey: Key.dataCollectionFrequency)
      defaults.set(true, forKey: Key.autoEnabled)
      defaults.set(9, forKey: Key.autoStartHour)
      defaults.set(0, forKey: Key.autoStartMinute)
      defaults.set(22, forKey: Key.autoEndHour)
      defaults.set(0, forKey: Key.autoEndMinute)
      defaults.set(15, forKey: Key.autoOnMin)
      defaults.set(15, forKey: Key.autoOffMin)
    }

    userName = defaults.string(forKey: Key.userName) ?? ""
    firstTime = defaults.bool(forKey: Key.firstTime)
    recordingMade = defaults.bool(forKey: Key.recordingMade)
    totalRecordingTime = defaults.double(forKey: Key.totalRecordingTime)
    dataCollectionFrequency =
      DataCollectionFrequency(
        rawValue: defaults.string(forKey: Key.dataCollectionFrequency) ?? ""
      ) ?? .continuous15
    autoEnabled = defaults.bool(forKey: Key.autoEnabled)
    autoStartHour = defaults.integer(forKey: Key.autoStartHour)
    autoStartMinute = defaults.integer(forKey: Key.autoStartMinute)
    autoEndHour = defaults.integer(forKey: Key.autoEndHour)
    autoEndMinute = defaults.integer(forKey: Key.autoEndMinute)
    autoOnMin = defaults.integer(forKey: Key.autoOnMin)
    autoOffMin = defaults.integer(forKey: Key.autoOffMin)
  }
  static func isValidUsername(_ username: String) -> Bool {
    let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && !trimmed.contains(where: { $0.isWhitespace })
      && !trimmed.contains("_")
      && !trimmed.contains("/")
      && !trimmed.contains("\\")
  }
  func save(username: String) {
    userName = username.trimmingCharacters(in: .whitespacesAndNewlines)
    firstTime = false
    recordingMade = false
    totalRecordingTime = 0
  }
  func markRecordingMade(duration: TimeInterval) {
    recordingMade = true
    firstTime = false
    totalRecordingTime += duration
  }
  func signOut() {
    userName = ""
    firstTime = true
    recordingMade = false
    totalRecordingTime = 0
  }
}
