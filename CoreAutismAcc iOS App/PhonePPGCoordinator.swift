import Combine
import Foundation
import UIKit
import WatchConnectivity

private struct PPGPhoneState: Codable {
  var recordings: [PPGPhoneRecording] = []
  var desired: PPGWatchCommand?
  var activeSessionID: UUID?
}

struct PPGPhoneRecording: Codable, Identifiable {
  var session: PPGRecordingSession
  var startConfirmedAt: Date?
  var stopConfirmedAt: Date?
  var issue: String?
  var files: [String] = []
  var opticalSampleCount = 0
  var downloadMessage: String?
  var id: UUID { session.id }
}
@MainActor
final class PhonePPGCoordinator: NSObject, ObservableObject, WCSessionDelegate {
  let sensor = PPGSensorService()
  @Published private(set) var recordings: [PPGPhoneRecording] = []
  @Published private(set) var connectionStatus = "Record using Start ACC on your Watch."
  @Published private(set) var downloadStatus =
    "Completed recordings become available after 24 hours."
  @Published private(set) var isDownloading = false
  private let connectivity = WCSession.default
  private let stateURL = URL.applicationSupportDirectory.appendingPathComponent(
    "PPGController/state.json")
  private var desired: PPGWatchCommand?
  private var activeSessionID: UUID?
  private var applying = false
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var downloadQueue: [PPGRecordingSession] = []
  private var autoDownloadAttempted = Set<UUID>()
  private var downloadFailures = 0
  private var downloadedOpticalSamples = 0

  override init() {
    super.init()
    if let data = try? Data(contentsOf: stateURL),
      let state = try? JSONDecoder().decode(PPGPhoneState.self, from: data)
    {
      recordings = state.recordings
      desired = state.desired
      activeSessionID = state.activeSessionID
    }
    sensor.onAuthorizationRevoked = { [weak self] in
      guard let self else { return }
      self.activeSessionID = nil
      if let desired = self.desired {
        self.setIssue(
          "PPG permission was revoked. Open the iPhone app to authorize it.",
          sessionID: desired.session.id)
        self.publish(desired, state: .unavailable, message: "PPG unavailable—authorize on iPhone")
      }
      self.persist()
    }
    if WCSession.isSupported() {
      connectivity.delegate = self
      connectivity.activate()
    }
  }

  func refresh() {
    sensor.refreshAuthorization()
    sensor.refreshExports()
    // Replay only an unfinished STOP after process restart. A fresh live
    // Watch request is required to initiate a new recording.
    if desired?.action == .stop { reconcile() }
    downloadAvailable(automatically: true)
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(
        at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let state = PPGPhoneState(
        recordings: recordings, desired: desired, activeSessionID: activeSessionID)
      try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    } catch {
      connectionStatus = "Could not save session history: \(error.localizedDescription)"
    }
  }

  private func remember(_ session: PPGRecordingSession) {
    if let index = recordings.firstIndex(where: { $0.id == session.id }) {
      recordings[index].session = recordings[index].session.merging(session)
    } else {
      recordings.append(PPGPhoneRecording(session: session))
      recordings.sort { $0.session.startedAt > $1.session.startedAt }
    }
    persist()
  }

  private func receive(_ command: PPGWatchCommand, live: Bool, reply: ((Data) -> Void)? = nil) {
    remember(command.session)
    guard PPGCommandGate.shouldApply(command, after: desired, live: live, now: Date()) else {
      let response = PPGControlReply(
        command: command, state: .unavailable,
        message: "PPG request expired or was superseded; use the current Watch session.")
      if let data = try? JSONEncoder().encode(response) { reply?(data) }
      return
    }
    desired = command
    persist()
    let response = PPGControlReply(
      command: command, state: .pending,
      message: command.action == .start ? "PPG: waiting for confirmation" : "PPG: stopping")
    if let data = try? JSONEncoder().encode(response) { reply?(data) }
    reconcile()
  }
  private func reconcile() {
    guard !applying, let command = desired else { return }
    switch PPGControlDecision.next(
      command: command, activeSessionID: activeSessionID,
      sensorRequested: sensor.collectionRequested, operationPending: applying)
    {
    case .wait: return
    case .recording:
      publish(command, state: .recording, message: "PPG recording active")
    case .stopped:
      publish(
        command, state: .stopped, message: "PPG saved — keep Watch on charger unlocked to sync")
    case .stop:
      applyStop(
        command,
        stoppingSession: activeSessionID ?? (command.action == .stop ? command.session.id : nil))
    case .start:
      applying = true
      beginControlBackgroundTask()
      sensor.startCollection { [weak self] result in
        guard let self else { return }
        self.applying = false
        self.endControlBackgroundTask()
        switch result {
        case .success(let date):
          self.activeSessionID = command.session.id
          if let index = self.recordings.firstIndex(where: { $0.id == command.session.id }) {
            if self.recordings[index].startConfirmedAt == nil {
              self.recordings[index].startConfirmedAt = date
            }
            self.recordings[index].issue = nil
          }
          self.persist()
          self.reconcile()
        case .failure(let error):
          self.setIssue(error.localizedDescription, sessionID: command.session.id)
          self.publishIfCurrent(
            command, state: .unavailable, message: "PPG unavailable—check iPhone")
          if self.desired?.sequence != command.sequence { self.reconcile() }
        }
      }
    }
  }

  private func applyStop(_ command: PPGWatchCommand, stoppingSession: UUID?) {
    applying = true
    beginControlBackgroundTask()
    sensor.stopCollection { [weak self] result in
      guard let self else { return }
      self.applying = false
      self.endControlBackgroundTask()
      switch result {
      case .success(let date):
        if let index = self.recordings.firstIndex(where: { $0.id == stoppingSession }) {
          self.recordings[index].stopConfirmedAt = date
        }
        self.activeSessionID = nil
        self.persist()
        self.reconcile()
      case .failure(let error):
        self.setIssue(error.localizedDescription, sessionID: stoppingSession ?? command.session.id)
        self.publishIfCurrent(
          command, state: .unavailable, message: "PPG stop not confirmed—check iPhone")
      }
    }
  }

  private func beginControlBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Confirm Watch PPG request")
    { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        if let command = self.desired {
          self.publish(command, state: .unavailable, message: "PPG not confirmed—open iPhone app")
        }
        self.endControlBackgroundTask()
      }
    }
  }

  private func endControlBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  private func setIssue(_ message: String, sessionID: UUID) {
    if let index = recordings.firstIndex(where: { $0.id == sessionID }) {
      recordings[index].issue = message
    }
    connectionStatus = message
    persist()
  }

  private func publishIfCurrent(
    _ command: PPGWatchCommand, state: PPGControlReply.State, message: String
  ) {
    guard desired?.session.id == command.session.id, desired?.sequence == command.sequence else {
      return
    }
    publish(command, state: state, message: message)
  }

  private func publish(_ command: PPGWatchCommand, state: PPGControlReply.State, message: String) {
    connectionStatus = message
    let response = PPGControlReply(command: command, state: state, message: message)
    guard connectivity.activationState == .activated, let data = try? JSONEncoder().encode(response)
    else { return }
    try? connectivity.updateApplicationContext(["ppgStatus": data])
    if connectivity.isReachable {
      connectivity.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    }
  }

  func downloadAvailable(automatically: Bool = false) {
    guard !isDownloading, !sensor.isFetching, !applying, sensor.isAuthorized else { return }
    downloadQueue = recordings.filter {
      guard let end = $0.session.endedAt, !($0.session.interrupted),
        end <= PPGFetchWindow.eligibleThrough()
      else { return false }
      return !automatically
        || ($0.opticalSampleCount == 0 && !autoDownloadAttempted.contains($0.id))
    }.map(\.session)
    guard !downloadQueue.isEmpty else {
      if !automatically {
        downloadStatus = "No completed recordings are past the 24-hour holding period yet."
      }
      return
    }
    isDownloading = true
    downloadFailures = 0
    downloadedOpticalSamples = 0
    downloadNext()
  }

  private func downloadNext() {
    guard !downloadQueue.isEmpty else {
      isDownloading = false
      downloadStatus =
        "Downloaded \(downloadedOpticalSamples) optical samples. \(downloadFailures) recording download(s) failed. Expand each recording for files and details."
      return
    }
    let recording = downloadQueue.removeFirst()
    autoDownloadAttempted.insert(recording.id)
    downloadStatus =
      "Downloading PPG for \(recording.participant), \(recording.recordingTimestamp)…"
    let entry = recordings.first { $0.id == recording.id }
    let confirmation = PPGCollectionConfirmation(
      startConfirmedAtUnixSeconds: entry?.startConfirmedAt?.timeIntervalSince1970,
      stopConfirmedAtUnixSeconds: entry?.stopConfirmedAt?.timeIntervalSince1970, issue: entry?.issue
    )
    sensor.fetch(session: recording, confirmation: confirmation) { [weak self] result in
      guard let self else { return }
      if let index = self.recordings.firstIndex(where: { $0.id == recording.id }) {
        switch result {
        case .success(let outcome):
          self.downloadedOpticalSamples += outcome.opticalSampleCount
          if outcome.opticalSampleCount > 0 {
            self.recordings[index].files = outcome.files.map(\.lastPathComponent)
          }
          self.recordings[index].opticalSampleCount = max(
            self.recordings[index].opticalSampleCount, outcome.opticalSampleCount)
          self.recordings[index].downloadMessage =
            outcome.opticalSampleCount == 0
            ? "SensorKit has no optical samples for this session yet. Ensure Watch was charged unlocked."
            : "\(outcome.opticalSampleCount) optical samples in export."
        case .failure(let error):
          self.downloadFailures += 1
          self.recordings[index].downloadMessage = error.localizedDescription
        }
      }
      self.persist()
      self.downloadNext()
    }
  }

  func exportURL(_ filename: String) -> URL {
    URL.documentsDirectory.appendingPathComponent("PPG").appendingPathComponent(filename)
  }

  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    Task { @MainActor in
      if let error { self.connectionStatus = "Watch connection: \(error.localizedDescription)" }
      if activationState == .activated, self.desired?.action == .stop { self.reconcile() }
    }
  }

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

  nonisolated func session(
    _ session: WCSession, didReceiveMessageData messageData: Data,
    replyHandler: @escaping (Data) -> Void
  ) {
    guard let command = try? JSONDecoder().decode(PPGWatchCommand.self, from: messageData) else {
      replyHandler(Data())
      return
    }
    Task { @MainActor in self.receive(command, live: true, reply: replyHandler) }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard let data = userInfo["ppgCommand"] as? Data,
      let command = try? JSONDecoder().decode(PPGWatchCommand.self, from: data)
    else { return }
    Task { @MainActor in self.receive(command, live: false) }
  }

  nonisolated func session(
    _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    guard let data = applicationContext["ppgCommand"] as? Data,
      let command = try? JSONDecoder().decode(PPGWatchCommand.self, from: data)
    else { return }
    Task { @MainActor in self.receive(command, live: false) }
  }
}
