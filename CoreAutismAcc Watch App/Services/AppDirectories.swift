import Foundation

enum AppDirectories {
  static var documents: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }
  static var audioDirectory: URL {
    documents.appendingPathComponent("AudioRecorderWear", isDirectory: true)
  }
  static var hrDirectory: URL {
    documents.appendingPathComponent("hrData", isDirectory: true)
  }
  static var batteryDirectory: URL {
    documents.appendingPathComponent("BatteryData", isDirectory: true)
  }
  static var queueDirectory: URL {
    documents.appendingPathComponent("Queue", isDirectory: true)
  }

  static func ensureAll() {
    [audioDirectory, hrDirectory, batteryDirectory, queueDirectory].forEach { url in
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }
}
enum RecordingDateFormats {
  static func fileTimestamp(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd_HH_mm_ss"
    return formatter.string(from: date)
  }
  static func androidDateTime(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
  }
}
