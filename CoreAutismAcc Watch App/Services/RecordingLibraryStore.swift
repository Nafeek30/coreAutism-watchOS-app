import AVFoundation
import Combine
import Foundation

struct AudioRecordingFile: Identifiable {
  var id: URL { url }
  let url: URL
  let modifiedDate: Date
  var displayName: String {
    let stem = url.deletingPathExtension().lastPathComponent
    let timestamp = String(stem.suffix(19))
    let date = Self.fileTimestampFormatter.date(from: timestamp) ?? modifiedDate
    return Self.displayTimestampFormatter.string(from: date)
  }

  private static let fileTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH_mm_ss"
    return formatter
  }()

  private static let displayTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "M/d HH:mm:ss"
    return formatter
  }()
}
final class RecordingLibraryStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
  @Published private(set) var files: [AudioRecordingFile] = []
  @Published private(set) var playingURL: URL?

  private var player: AVAudioPlayer?
  func reload() {
    AppDirectories.ensureAll()
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: AppDirectories.audioDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    files =
      urls
      .filter { $0.pathExtension.lowercased() == "m4a" }
      .map { url in
        let modified =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        return AudioRecordingFile(url: url, modifiedDate: modified)
      }
      .sorted { $0.modifiedDate > $1.modifiedDate }
  }
  func togglePlayback(for file: AudioRecordingFile) {
    if playingURL == file.url {
      stopPlayback()
      return
    }

    stopPlayback()
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
      player = try AVAudioPlayer(contentsOf: file.url)
      player?.delegate = self
      if player?.play() == true {
        playingURL = file.url
      } else {
        stopPlayback()
      }
    } catch {
      stopPlayback()
    }
  }
  func delete(_ file: AudioRecordingFile) {
    if playingURL == file.url {
      stopPlayback()
    }
    try? FileManager.default.removeItem(at: file.url)
    reload()
  }
  func stopPlayback() {
    player?.stop()
    player = nil
    playingURL = nil
    try? AVAudioSession.sharedInstance().setActive(false)
  }
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    stopPlayback()
  }
}
