import Foundation
import WatchConnectivity
import WatchKit

@MainActor
final class WatchPPGCoordinator: NSObject, WCSessionDelegate {
  var onStatus: ((String, Bool) -> Void)?
  private let connectivity = WCSession.default
  private let directory = AppDirectories.documents.appendingPathComponent(
    "PPGSessions", isDirectory: true)
  private var latest: PPGWatchCommand?
  private var retryTimer: Timer?
  private var confirmed = false
  private var sending = false
  private var lastReply: PPGControlReply?
  private let controllerID: UUID
  private var sequence: Int

  override init() {
    let defaults = UserDefaults.standard
    controllerID =
      defaults.string(forKey: "ppg.controllerID").flatMap(UUID.init(uuidString:)) ?? UUID()
    defaults.set(controllerID.uuidString, forKey: "ppg.controllerID")
    sequence = defaults.integer(forKey: "ppg.sequence")
    super.init()
    latest = (try? Data(contentsOf: directory.appendingPathComponent("latest.json")))
      .flatMap { try? JSONDecoder().decode(PPGWatchCommand.self, from: $0) }
    if let latest { sequence = max(sequence, latest.sequence) }
    // Audio does not survive process termination. Stop an orphaned PPG
    // request on relaunch without inventing an exact audio end timestamp.
    if var previous = latest, previous.action == .start {
      previous.session.interrupted = true
      makeCommand(.stop, session: previous.session)
    }
  }

  func activate() {
    guard WCSession.isSupported() else {
      onStatus?("PPG unavailable on this device", true)
      return
    }
    connectivity.delegate = self
    connectivity.activate()
    if latest != nil { startRetrying() }
  }

  func begin(participant: String, recordingTimestamp: String, at date: Date) {
    let session = PPGRecordingSession(
      id: UUID(), participant: participant,
      recordingTimestamp: recordingTimestamp, watchName: WKInterfaceDevice.current().name,
      startedAt: date)
    makeCommand(.start, session: session)
    onStatus?("PPG: waiting for iPhone", true)
    startRetrying()
    sendLatest()
  }

  func end(at date: Date) {
    guard var session = latest?.session, latest?.action == .start else { return }
    session.endedAt = max(date, session.startedAt)
    makeCommand(.stop, session: session)
    onStatus?("PPG: stop awaiting iPhone", true)
    startRetrying()
    sendLatest()
  }

  private func makeCommand(_ action: PPGWatchCommand.Action, session: PPGRecordingSession) {
    sequence += 1
    UserDefaults.standard.set(sequence, forKey: "ppg.sequence")
    latest = PPGWatchCommand(
      controllerID: controllerID, sequence: sequence, action: action, sentAt: Date(),
      session: session)
    confirmed = false
    sending = false
    lastReply = nil
    persist()
    if connectivity.activationState == .activated { queueHistoryAndStop() }
  }

  private func persist() {
    guard let latest else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(latest).write(
        to: directory.appendingPathComponent("latest.json"), options: .atomic)
      try JSONEncoder().encode(latest).write(
        to: directory.appendingPathComponent("\(latest.session.id.uuidString).json"),
        options: .atomic)
    } catch {
      onStatus?("PPG session details could not be saved", true)
    }
  }

  private func queueHistoryAndStop() {
    guard let latest, let data = try? JSONEncoder().encode(latest) else { return }
    // Durable transfers retain session boundaries if the phone is temporarily
    // unavailable. The receiver never executes background start commands.
    queue(latest)
    // Recover completed sessions made before WCSession finished activation,
    // or whose background history transfer failed on an earlier run.
    let files =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []
    for file in files where file.lastPathComponent != "latest.json" && file.pathExtension == "json"
    {
      guard let saved = try? Data(contentsOf: file),
        let command = try? JSONDecoder().decode(PPGWatchCommand.self, from: saved),
        command.action == .stop
      else { continue }
      queue(command)
    }
    try? connectivity.updateApplicationContext(["ppgCommand": data])
  }

  private func queue(_ command: PPGWatchCommand) {
    let key = "\(command.controllerID.uuidString).\(command.sequence)"
    let delivered = UserDefaults.standard.stringArray(forKey: "ppg.deliveredCommands") ?? []
    guard !delivered.contains(key) else { return }
    let alreadyQueued = connectivity.outstandingUserInfoTransfers.contains {
      $0.userInfo["ppgDeliveryID"] as? String == key
    }
    guard !alreadyQueued, let data = try? JSONEncoder().encode(command) else { return }
    connectivity.transferUserInfo(["ppgCommand": data, "ppgDeliveryID": key])
  }

  private func startRetrying() {
    retryTimer?.invalidate()
    retryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in self.sendLatest() }
    }
  }

  private func sendLatest() {
    guard !confirmed, !sending, var command = latest else { return }
    guard connectivity.activationState == .activated else { return }
    guard connectivity.isCompanionAppInstalled else {
      onStatus?("PPG unavailable: install the iPhone app", true)
      return
    }
    command.sentAt = Date()
    guard let data = try? JSONEncoder().encode(command) else { return }
    sending = true
    // Sending from the active Watch can wake the phone companion. Do not
    // gate this on a possibly stale isReachable value; handle the error.
    connectivity.sendMessageData(
      data,
      replyHandler: { [weak self] data in
        Task { @MainActor in
          guard let self, self.latest?.sequence == command.sequence else { return }
          self.sending = false
          if let reply = try? JSONDecoder().decode(PPGControlReply.self, from: data) {
            self.receive(reply)
          }
        }
      },
      errorHandler: { [weak self] error in
        Task { @MainActor in
          guard let self, self.latest?.sequence == command.sequence else { return }
          self.sending = false
          self.onStatus?(
            command.action == .start
              ? "PPG not confirmed—open iPhone app"
              : "PPG stop pending—connect iPhone", true)
        }
      })
  }

  private func receive(_ reply: PPGControlReply) {
    guard let latest, reply.matches(latest) else { return }
    if let lastReply, reply.reportedAt < lastReply.reportedAt { return }
    // A receipt is not a recording confirmation. It can arrive after the
    // separate SensorKit-result message and must not downgrade that result.
    if reply.state == .pending, let lastReply, lastReply.state != .pending { return }
    lastReply = reply
    confirmed = reply.state == .recording || reply.state == .stopped
    onStatus?(reply.message, !confirmed)
    if confirmed {
      retryTimer?.invalidate()
      retryTimer = nil
    } else if reply.state == .unavailable {
      startRetrying()
    }
  }

  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    Task { @MainActor in
      if let error { self.onStatus?("PPG connection: \(error.localizedDescription)", true) }
      guard activationState == .activated else { return }
      self.queueHistoryAndStop()
      self.sendLatest()
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in
      if session.isReachable, self.latest?.action == .start {
        self.confirmed = false
        self.startRetrying()
      }
      self.sendLatest()
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
    guard let reply = try? JSONDecoder().decode(PPGControlReply.self, from: messageData) else {
      return
    }
    Task { @MainActor in self.receive(reply) }
  }

  nonisolated func session(
    _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    guard let data = applicationContext["ppgStatus"] as? Data,
      let reply = try? JSONDecoder().decode(PPGControlReply.self, from: data)
    else { return }
    Task { @MainActor in self.receive(reply) }
  }

  nonisolated func session(
    _ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?
  ) {
    guard error == nil, let key = userInfoTransfer.userInfo["ppgDeliveryID"] as? String else {
      return
    }
    Task { @MainActor in
      var delivered = Set(UserDefaults.standard.stringArray(forKey: "ppg.deliveredCommands") ?? [])
      delivered.insert(key)
      UserDefaults.standard.set(Array(delivered), forKey: "ppg.deliveredCommands")
    }
  }
}
