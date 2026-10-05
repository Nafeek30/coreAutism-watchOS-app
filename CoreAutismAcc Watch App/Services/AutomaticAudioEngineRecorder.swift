import AVFoundation
import Foundation

struct AutomaticAudioSegment {
  let url: URL
  let duration: TimeInterval
}

private enum AutomaticAudioEngineError: LocalizedError {
  case alreadyRunning
  case notRunning
  case segmentAlreadyOpen
  case invalidInputFormat
  case fileAlreadyExists

  var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      return "The automatic audio engine is already running."
    case .notRunning:
      return "The automatic audio engine is not running."
    case .segmentAlreadyOpen:
      return "An automatic audio segment is already open."
    case .invalidInputFormat:
      return "The watch microphone returned an invalid audio format."
    case .fileAlreadyExists:
      return "An audio file already exists for this timestamp."
    }
  }
}
final class AutomaticAudioEngineRecorder: NSObject {
  private(set) var isSessionActive = false

  private let engine = AVAudioEngine()
  private let writerLock = NSLock()
  private var segmentFile: AVAudioFile?
  private var segmentURL: URL?
  private var segmentFrameCount: AVAudioFramePosition = 0
  private var inputSampleRate: Double = 0
  private var writeFailureReported = false
  private var notificationObservers: [NSObjectProtocol] = []
  var onRecordingFailure: ((String) -> Void)?
  override init() {
    super.init()
    observeAudioSession()
  }

  deinit {
    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  @discardableResult
  func startRun(username: String, startTime: Date) throws -> URL {
    guard !isSessionActive else {
      throw AutomaticAudioEngineError.alreadyRunning
    }

    AppDirectories.ensureAll()
    try configureAudioSession()

    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      deactivateAudioSession()
      throw AutomaticAudioEngineError.invalidInputFormat
    }

    inputSampleRate = inputFormat.sampleRate
    writeFailureReported = false

    let fileURL: URL
    var tapInstalled = false
    do {
      fileURL = try openSegmentFile(
        username: username,
        startTime: startTime,
        inputFormat: inputFormat
      )
      inputNode.installTap(
        onBus: 0,
        bufferSize: 4_096,
        format: inputFormat
      ) { [weak self] buffer, _ in
        self?.receive(buffer)
      }
      tapInstalled = true
      engine.prepare()
      try engine.start()
    } catch {
      if tapInstalled {
        inputNode.removeTap(onBus: 0)
      }
      closeAndDeleteOpenSegment()
      restoreAudioSessionPreferences()
      deactivateAudioSession()
      throw error
    }

    isSessionActive = true
    return fileURL
  }
  @discardableResult
  func beginSegment(username: String, startTime: Date) throws -> URL {
    guard isSessionActive, engine.isRunning else {
      throw AutomaticAudioEngineError.notRunning
    }

    let inputFormat = engine.inputNode.outputFormat(forBus: 0)
    let fileURL = try openSegmentFile(
      username: username,
      startTime: startTime,
      inputFormat: inputFormat
    )
    return fileURL
  }
  func endSegment() -> AutomaticAudioSegment? {
    writerLock.lock()
    guard segmentFile != nil,
      let url = segmentURL
    else {
      writerLock.unlock()
      return nil
    }

    let frameCount = segmentFrameCount
    let sampleRate = inputSampleRate
    segmentFile = nil
    segmentURL = nil
    segmentFrameCount = 0
    writerLock.unlock()

    guard frameCount > 0 else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }

    let duration = sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    let segment = AutomaticAudioSegment(url: url, duration: duration)
    return segment
  }
  func stopRun() -> AutomaticAudioSegment? {
    guard isSessionActive else { return nil }

    let finalSegment = endSegment()
    isSessionActive = false
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    restoreAudioSessionPreferences()
    deactivateAudioSession()
    return finalSegment
  }
  private func openSegmentFile(
    username: String,
    startTime: Date,
    inputFormat: AVAudioFormat
  ) throws -> URL {
    let timestamp = RecordingDateFormats.fileTimestamp(from: startTime)
    let url = AppDirectories.audioDirectory
      .appendingPathComponent("\(username)_\(timestamp).m4a")
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw AutomaticAudioEngineError.fileAlreadyExists
    }

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: inputFormat.sampleRate,
      AVEncoderBitRateKey: 128_000,
      AVNumberOfChannelsKey: Int(inputFormat.channelCount),
    ]
    let file: AVAudioFile
    do {
      file = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: inputFormat.commonFormat,
        interleaved: inputFormat.isInterleaved
      )
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }

    writerLock.lock()
    defer { writerLock.unlock() }
    guard segmentFile == nil else {
      try? FileManager.default.removeItem(at: url)
      throw AutomaticAudioEngineError.segmentAlreadyOpen
    }
    segmentFile = file
    segmentURL = url
    segmentFrameCount = 0
    writeFailureReported = false
    return url
  }
  private func receive(_ buffer: AVAudioPCMBuffer) {
    var failure: (message: String, url: URL?)?

    writerLock.lock()
    if let segmentFile {
      do {
        try segmentFile.write(from: buffer)
        segmentFrameCount += AVAudioFramePosition(buffer.frameLength)
      } catch  where !writeFailureReported {
        writeFailureReported = true
        failure = (error.localizedDescription, segmentURL)
        self.segmentFile = nil
        segmentURL = nil
        segmentFrameCount = 0
      } catch {
        // The first failure already schedules run cleanup.
      }
    }
    writerLock.unlock()

    guard let failure else { return }
    if let url = failure.url {
      try? FileManager.default.removeItem(at: url)
    }
    DispatchQueue.main.async {
      self.onRecordingFailure?(failure.message)
    }
  }
  private func closeAndDeleteOpenSegment() {
    writerLock.lock()
    let url = segmentURL
    segmentFile = nil
    segmentURL = nil
    segmentFrameCount = 0
    writerLock.unlock()
    if let url {
      try? FileManager.default.removeItem(at: url)
    }
  }
  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
    try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    try session.setActive(true)
  }
  private func restoreAudioSessionPreferences() {
    try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(false)
  }
  private func deactivateAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(false)
  }
  private func observeAudioSession() {
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()

    notificationObservers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        guard let self, self.isSessionActive else { return }
        let values = notification.userInfo ?? [:]
        let rawType = (values[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        let rawOptions = (values[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0

        guard rawType == AVAudioSession.InterruptionType.ended.rawValue else { return }
        let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        guard options.contains(.shouldResume), !self.engine.isRunning else { return }

        do {
          try session.setActive(true)
          try self.engine.start()
        } catch {
          self.onRecordingFailure?(error.localizedDescription)
        }
      })

    notificationObservers.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        guard let self, self.isSessionActive else { return }
      })

    notificationObservers.append(
      center.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: engine,
        queue: .main
      ) { [weak self] _ in
        guard let self, self.isSessionActive else { return }
      })

    notificationObservers.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereLostNotification,
        object: session,
        queue: .main
      ) { [weak self] _ in
        guard let self, self.isSessionActive else { return }
      })

    notificationObservers.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification,
        object: session,
        queue: .main
      ) { [weak self] _ in
        guard let self, self.isSessionActive else { return }
      })
  }

}
