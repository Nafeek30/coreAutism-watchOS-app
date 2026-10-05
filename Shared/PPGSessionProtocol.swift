import Foundation

nonisolated struct PPGRecordingSession: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let participant: String
  let recordingTimestamp: String
  let watchName: String
  let startedAt: Date
  var endedAt: Date?
  var interrupted = false

  func contains(sessionStart: Double, offsetNanoseconds: Int64) -> Bool {
    guard let endedAt else { return false }
    let timestamp = sessionStart + Double(offsetNanoseconds) / 1_000_000_000
    return timestamp >= startedAt.timeIntervalSince1970 && timestamp < endedAt.timeIntervalSince1970
  }
  func merging(_ other: Self) -> Self {
    guard id == other.id else { return self }
    var result = self
    if result.endedAt == nil { result.endedAt = other.endedAt }
    result.interrupted = result.interrupted || other.interrupted
    return result
  }
}

nonisolated struct PPGWatchCommand: Codable, Sendable {
  enum Action: String, Codable, Sendable { case start, stop }
  let controllerID: UUID
  let sequence: Int
  let action: Action
  var sentAt: Date
  var session: PPGRecordingSession
}

nonisolated struct PPGControlReply: Codable, Sendable {
  enum State: String, Codable, Sendable { case pending, recording, stopped, unavailable }
  let controllerID: UUID
  let sequence: Int
  let sessionID: UUID
  let state: State
  let message: String
  let reportedAt: Date

  init(command: PPGWatchCommand, state: State, message: String) {
    controllerID = command.controllerID
    sequence = command.sequence
    sessionID = command.session.id
    self.state = state
    self.message = message
    reportedAt = Date()
  }

  func matches(_ command: PPGWatchCommand) -> Bool {
    controllerID == command.controllerID && sequence == command.sequence
      && sessionID == command.session.id
  }
}
nonisolated enum PPGCommandGate {
  static func shouldApply(
    _ command: PPGWatchCommand, after previous: PPGWatchCommand?, live: Bool, now: Date
  ) -> Bool {
    guard command.sequence >= 0 else { return false }
    if command.action == .start {
      guard live, command.session.endedAt == nil, !command.session.interrupted,
        abs(now.timeIntervalSince(command.sentAt)) <= 60
      else { return false }
    }
    if let previous {
      if command.controllerID == previous.controllerID {
        guard command.sequence >= previous.sequence else { return false }
        if command.sequence == previous.sequence {
          return command.action == previous.action && command.session.id == previous.session.id
        }
      } else if command.action == .stop && command.session.id != previous.session.id {
        return false
      }
    }
    return true
  }
}

nonisolated enum PPGControlDecision: Equatable {
  case wait, start, stop, recording, stopped

  static func next(
    command: PPGWatchCommand, activeSessionID: UUID?, sensorRequested: Bool, operationPending: Bool
  ) -> Self {
    guard !operationPending else { return .wait }
    if command.action == .stop {
      return activeSessionID != nil ? .stop : .stopped
    }
    if activeSessionID == command.session.id { return .recording }
    if let active = activeSessionID, active != command.session.id {
      return .stop
    }
    return .start
  }
}
