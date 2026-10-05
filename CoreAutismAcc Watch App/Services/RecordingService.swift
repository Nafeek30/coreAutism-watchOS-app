import Combine
import Foundation
import UserNotifications
import WatchKit

final class RecordingService: ObservableObject {
  private enum AutoPhase {
    case recording
    case resting
  }

  private let audioRecorder: AudioRecorder
  private let automaticAudioRecorder: AutomaticAudioEngineRecorder
  private let healthDataService: HealthDataService
  private let preferences: PreferencesStore
  private let uploadService: UploadService
  private let ppg: WatchPPGCoordinator
  private var recordingStartDate: Date?
  private var reminderTimer: Timer?
  private var autoTransitionTimer: DispatchSourceTimer?
  private var autoRunEndDate: Date?
  private var autoRecordingMinutes = 0
  private var autoRestMinutes = 0
  private var autoPhase: AutoPhase?

  @Published private(set) var isRecording = false
  @Published private(set) var autoSessionActive = false
  @Published private(set) var userMessage = ""
  @Published private(set) var ppgStatus = "PPG Ready"
  @Published private(set) var ppgNeedsAttention = false
  var onAutoRunFinished: (() -> Void)?
  init(
    preferences: PreferencesStore,
    uploadService: UploadService
  ) {
    self.preferences = preferences
    self.uploadService = uploadService
    self.ppg = WatchPPGCoordinator()
    self.audioRecorder = AudioRecorder()
    self.automaticAudioRecorder = AutomaticAudioEngineRecorder()
    self.healthDataService = HealthDataService()
    ppg.onStatus = { [weak self] message, needsAttention in
      self?.ppgStatus = message
      self?.ppgNeedsAttention = needsAttention
    }
    ppg.activate()
    healthDataService.onCriticalBattery = { [weak self] in
      DispatchQueue.main.async {
        self?.stopRecording(message: "Battery too low. Stopped recording.")
      }
    }
    audioRecorder.onRecordingFailure = { [weak self] errorMessage in
      DispatchQueue.main.async {
        guard let self, !self.autoSessionActive else { return }
        self.stopRecording(message: "Audio failed: \(errorMessage)")
      }
    }
    automaticAudioRecorder.onRecordingFailure = { [weak self] errorMessage in
      DispatchQueue.main.async {
        guard let self, self.autoSessionActive else { return }
        self.stopRecording(message: "Audio failed: \(errorMessage)")
      }
    }
  }
  func requestPermissions() {
    healthDataService.requestAuthorization { _ in }
    audioRecorder.requestPermission { _ in }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }
  @discardableResult
  func startManualRecording() -> Bool {
    guard !autoSessionActive, !isRecording else {
      return false
    }
    guard validateRecordingStart() else {
      return false
    }

    let startDate = Date()
    do {
      _ = try audioRecorder.startRecording(
        username: preferences.userName,
        startTime: startDate
      )
      startHealthCapture(at: startDate)
      recordingStartDate = startDate
      isRecording = true
      userMessage = ""
      scheduleRecordingReminders()
      return true
    } catch {
      userMessage = "Audio failed: \(error.localizedDescription)"
      return false
    }
  }
  @discardableResult
  func startAutoRecording(plan: AutoRecordingPlan) -> Bool {
    guard !autoSessionActive, !isRecording else {
      return false
    }
    guard plan.recordingMinutes > 0, plan.endDate > Date() else {
      return false
    }
    guard validateRecordingStart() else {
      return false
    }

    autoRunEndDate = plan.endDate
    autoRecordingMinutes = plan.recordingMinutes
    autoRestMinutes = plan.restMinutes
    autoSessionActive = true

    let startDate = Date()
    do {
      try automaticAudioRecorder.startRun(
        username: preferences.userName,
        startTime: startDate
      )
      startHealthCapture(at: startDate)
      recordingStartDate = startDate
      autoPhase = .recording
      isRecording = true
      userMessage = ""
      scheduleRecordingReminders()
      scheduleCurrentAutoRecordingInterval()
      return true
    } catch {
      _ = automaticAudioRecorder.stopRun()
      resetAutoRunState()
      userMessage = "Audio failed: \(error.localizedDescription)"
      return false
    }
  }
  func stopRecording() {
    stopRecording(message: autoSessionActive ? "Auto recording stopped" : "Recording saved")
  }

  private func stopRecording(message: String) {
    guard isRecording || autoSessionActive else { return }

    if autoSessionActive {
      finishAutoRun(message: message)
    } else {
      let endDate = Date()
      let audioURL = audioRecorder.stopRecording()
      let healthURLs = healthDataService.stop(endWorkout: true)
      cancelRecordingReminders()
      completeSavedSegment(audioURL: audioURL, healthURLs: healthURLs, endDate: endDate)
      userMessage = "Saved! Charge Watch unlocked to sync PPG"
    }
  }
  private func startNextAutoSegment() {
    guard autoSessionActive, let endDate = autoRunEndDate else { return }

    let remainingSeconds = endDate.timeIntervalSinceNow
    guard remainingSeconds > 0 else {
      finishAutoRun(message: "Auto recording finished")
      return
    }

    let startDate = Date()
    do {
      try automaticAudioRecorder.beginSegment(
        username: preferences.userName,
        startTime: startDate
      )
      startHealthCapture(at: startDate)
      recordingStartDate = startDate
      autoPhase = .recording
      isRecording = true
      userMessage = ""
      scheduleRecordingReminders()
      scheduleCurrentAutoRecordingInterval()
    } catch {
      finishAutoRun(message: "Audio failed: \(error.localizedDescription)")
    }
  }
  private func scheduleCurrentAutoRecordingInterval() {
    guard let endDate = autoRunEndDate else { return }
    let segmentDuration = min(
      TimeInterval(autoRecordingMinutes * 60),
      max(0, endDate.timeIntervalSinceNow)
    )
    scheduleAutoTransition(after: segmentDuration)
  }
  private func finishAutoSegmentAndStartRest() {
    guard autoSessionActive, autoPhase == .recording else { return }
    let endDate = Date()
    cancelRecordingReminders()
    let segment = automaticAudioRecorder.endSegment()
    let healthURLs = healthDataService.stop(endWorkout: false)
    completeSavedSegment(
      audioURL: segment?.url,
      healthURLs: healthURLs,
      recordedDuration: segment?.duration,
      endDate: endDate
    )
    autoPhase = nil

    guard segment != nil else {
      finishAutoRun(message: "Audio failed: No microphone audio was captured")
      return
    }
    startAutoRestOrFinish()
  }
  private func startAutoRestOrFinish() {
    guard let endDate = autoRunEndDate, endDate.timeIntervalSinceNow > 0 else {
      finishAutoRun(message: "Auto recording finished")
      return
    }

    guard autoRestMinutes > 0 else {
      startNextAutoSegment()
      return
    }

    autoPhase = .resting
    isRecording = false
    userMessage = "Auto recording paused"
    let restSeconds = min(
      TimeInterval(autoRestMinutes * 60),
      endDate.timeIntervalSinceNow
    )
    scheduleAutoTransition(after: restSeconds)
  }
  private func handleAutoTransition() {
    cancelAutoTransition()

    switch autoPhase {
    case .recording:
      finishAutoSegmentAndStartRest()
    case .resting:
      startNextAutoSegment()
    case nil:
      finishAutoRun(message: "Auto recording stopped")
    }
  }
  private func finishAutoRun(message: String) {
    let endDate = Date()
    cancelAutoTransition()
    cancelRecordingReminders()

    var healthURLs: [URL] = []
    var finalSegment: AutomaticAudioSegment?
    if autoPhase == .recording {
      finalSegment = automaticAudioRecorder.stopRun()
      healthURLs = healthDataService.stop(endWorkout: true)
    } else {
      healthDataService.endWorkout()
      _ = automaticAudioRecorder.stopRun()
    }
    completeSavedSegment(
      audioURL: finalSegment?.url,
      healthURLs: healthURLs,
      recordedDuration: finalSegment?.duration,
      endDate: endDate
    )

    resetAutoRunState()
    userMessage = "Auto run saved! Charge Watch unlocked to sync PPG"
    onAutoRunFinished?()
  }
  private func resetAutoRunState() {
    autoPhase = nil
    autoSessionActive = false
    isRecording = false
    autoRunEndDate = nil
    autoRecordingMinutes = 0
    autoRestMinutes = 0
  }
  private func validateRecordingStart() -> Bool {
    guard preferences.isLoggedIn else {
      userMessage = "Please enter your name first"
      return false
    }
    guard audioRecorder.hasRecordPermission else {
      userMessage = "Microphone permission required"
      return false
    }
    return true
  }
  var activeRecordingStartDate: Date? {
    recordingStartDate
  }
  private func startHealthCapture(at startDate: Date) {
    healthDataService.start(
      username: preferences.userName,
      recordingTimestamp: RecordingDateFormats.fileTimestamp(from: startDate),
      startDate: startDate
    )
    ppg.begin(
      participant: preferences.userName,
      recordingTimestamp: RecordingDateFormats.fileTimestamp(from: startDate), at: startDate)
  }
  private func completeSavedSegment(
    audioURL: URL?,
    healthURLs: [URL],
    recordedDuration: TimeInterval? = nil,
    endDate: Date
  ) {
    // Covers manual Stop, automatic rest/end, audio failures, and low battery.
    ppg.end(at: endDate)
    if audioURL != nil {
      let duration =
        recordedDuration
        ?? recordingStartDate.map { Date().timeIntervalSince($0) }
        ?? 0
      preferences.markRecordingMade(duration: duration)
    }
    recordingStartDate = nil
    isRecording = false

    var uploadURLs = healthURLs
    if let audioURL {
      uploadURLs.append(audioURL)
    }
    uploadService.uploadFiles(uploadURLs)
  }
  private func scheduleAutoTransition(after delay: TimeInterval) {
    cancelAutoTransition()
    let normalizedDelay = max(delay, 0.1)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + normalizedDelay, leeway: .milliseconds(250))
    timer.setEventHandler { [weak self] in
      self?.handleAutoTransition()
    }
    autoTransitionTimer = timer
    timer.resume()
  }

  private func cancelAutoTransition() {
    autoTransitionTimer?.setEventHandler {}
    autoTransitionTimer?.cancel()
    autoTransitionTimer = nil
  }

  private func scheduleRecordingReminders() {
    cancelRecordingReminders()
    reminderTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: false) {
      [weak self] _ in
      self?.postStopReminder()
      self?.scheduleRepeatingStopReminder()
    }
  }
  private func scheduleRepeatingStopReminder() {
    cancelRecordingReminders()
    reminderTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) {
      [weak self] _ in
      self?.postStopReminder()
    }
  }

  private func cancelRecordingReminders() {
    reminderTimer?.invalidate()
    reminderTimer = nil
  }

  private func postStopReminder() {
    let content = UNMutableNotificationContent()
    content.title = "Stop Recording"
    content.body = "Recording has been on for 60 minutes. Do you want to stop?"
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: "stop-recording-\(Date().timeIntervalSince1970)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }
}
