import AVFoundation
import Foundation

private enum AudioRecorderStartError: LocalizedError {
  case preparationFailed
  case recordingFailed

  var errorDescription: String? {
    switch self {
    case .preparationFailed:
      return "The microphone recorder could not be prepared."
    case .recordingFailed:
      return "The microphone recorder could not be started."
    }
  }
}
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
  private var lastError: String?
  private var recorder: AVAudioRecorder?
  private var recordingFailed = false
  private var currentFileURL: URL?
  var onRecordingFailure: ((String) -> Void)?

  var hasRecordPermission: Bool {
    AVAudioApplication.shared.recordPermission == .granted
  }
  func requestPermission(completion: @escaping (Bool) -> Void) {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      completion(true)
    case .denied:
      lastError = "Microphone permission denied"
      completion(false)
    case .undetermined:
      AVAudioApplication.requestRecordPermission { granted in
        DispatchQueue.main.async {
          self.lastError = granted ? nil : "Microphone permission denied"
          completion(granted)
        }
      }
    @unknown default:
      completion(false)
    }
  }
  func startRecording(username: String, startTime: Date) throws -> URL {
    AppDirectories.ensureAll()
    let fileURL = audioFileURL(username: username, startTime: startTime)
    try activateAudioSession()

    do {
      recorder = try makeRecorder(fileURL: fileURL)
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      deactivateAudioSession()
      throw error
    }

    currentFileURL = fileURL
    recordingFailed = false
    lastError = nil
    return fileURL
  }
  func stopRecording() -> URL? {
    let completedURL = currentFileURL
    recorder?.stop()
    recorder = nil
    currentFileURL = nil
    deactivateAudioSession()
    let result = completedFileURL(completedURL)
    return result
  }
  private func activateAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default)
    try session.setActive(true)
  }
  private func makeRecorder(fileURL: URL) throws -> AVAudioRecorder {
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 44_100,
      AVEncoderBitRateKey: 128_000,
      AVNumberOfChannelsKey: 1,
    ]

    let recorder = try AVAudioRecorder(url: fileURL, settings: settings)

    recorder.delegate = self
    guard recorder.prepareToRecord() else {
      throw AudioRecorderStartError.preparationFailed
    }
    guard recorder.record() else {
      throw AudioRecorderStartError.recordingFailed
    }
    return recorder
  }
  private func deactivateAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(false)
  }
  private func completedFileURL(_ url: URL?) -> URL? {
    defer { recordingFailed = false }
    guard let url else { return nil }

    if recordingFailed {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return url
  }
  private func audioFileURL(username: String, startTime: Date) -> URL {
    let timestamp = RecordingDateFormats.fileTimestamp(from: startTime)
    return AppDirectories.audioDirectory.appendingPathComponent("\(username)_\(timestamp).m4a")
  }
  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    DispatchQueue.main.async {
      let message = error?.localizedDescription ?? "Audio recording failed"
      self.recordingFailed = true
      self.lastError = message
      self.onRecordingFailure?(message)
    }
  }
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    guard !flag, self.recorder === recorder else { return }

    DispatchQueue.main.async {
      let message = self.lastError ?? "Audio recording stopped unexpectedly"
      self.recordingFailed = true
      self.onRecordingFailure?(message)
    }
  }

}
