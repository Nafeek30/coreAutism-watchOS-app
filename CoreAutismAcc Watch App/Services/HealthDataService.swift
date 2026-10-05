import Foundation
import HealthKit
import WatchKit

struct HeartRateRecord: Codable {
  let timestamp: Int64
  let datetime: String
  let heart_rate: Double
}
struct BatteryRecord: Codable {
  let ts: Int64
  let read_time: String
  let capacity_pct: Int?
}
final class HealthDataService: NSObject {
  private let healthStore = HKHealthStore()
  private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
  private var heartRateQuery: HKAnchoredObjectQuery?
  private var workoutSession: HKWorkoutSession?
  private var workoutBuilder: HKLiveWorkoutBuilder?
  private var workoutIsEnding = false
  private var batteryTimer: Timer?
  private var captureID: UUID?
  private var nextHeartRateFlushCount = 600
  private var recordingTimestamp = ""
  private var username = ""

  private var heartRateRecords: [HeartRateRecord] = []
  private var batteryRecords: [BatteryRecord] = []

  var onCriticalBattery: (() -> Void)?
  func requestAuthorization(completion: @escaping (Bool) -> Void) {
    let readTypes: Set<HKObjectType> = [
      heartRateType,
      HKObjectType.workoutType(),
    ]

    let shareTypes: Set<HKSampleType> = [
      HKObjectType.workoutType()
    ]

    healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { success, _ in

      DispatchQueue.main.async {
        completion(success)
      }
    }
  }
  func start(username: String, recordingTimestamp: String, startDate: Date) {
    stopHeartRateQuery()
    self.username = username
    self.recordingTimestamp = recordingTimestamp
    heartRateRecords = []
    batteryRecords = []
    nextHeartRateFlushCount = 600
    let captureID = UUID()
    self.captureID = captureID
    startWorkoutIfNeeded(at: startDate)
    recordBatterySnapshot()
    startHeartRateQuery(startDate: startDate, captureID: captureID)
    startBatteryTimer()
  }
  func stop(endWorkout: Bool) -> [URL] {
    stopHeartRateQuery()
    captureID = nil
    batteryTimer?.invalidate()
    batteryTimer = nil
    recordBatterySnapshot()
    let urls = writeFiles()
    if endWorkout {
      self.endWorkout()
    }
    return urls
  }
  private func startHeartRateQuery(startDate: Date, captureID: UUID) {
    let predicate = HKQuery.predicateForSamples(
      withStart: startDate, end: nil, options: .strictStartDate)
    let query = HKAnchoredObjectQuery(
      type: heartRateType,
      predicate: predicate,
      anchor: nil,
      limit: HKObjectQueryNoLimit
    ) { [weak self] _, samples, _, _, _ in

      self?.handleHeartRateSamples(samples, captureID: captureID)
    }

    query.updateHandler = { [weak self] _, samples, _, _, _ in

      self?.handleHeartRateSamples(samples, captureID: captureID)
    }

    heartRateQuery = query
    healthStore.execute(query)
  }
  private func handleHeartRateSamples(_ samples: [HKSample]?, captureID: UUID) {
    guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else {
      return
    }
    let unit = HKUnit.count().unitDivided(by: HKUnit.minute())

    let records = quantitySamples.map { sample in
      HeartRateRecord(
        timestamp: Int64(sample.startDate.timeIntervalSince1970 * 1000),
        datetime: RecordingDateFormats.androidDateTime(from: sample.startDate),
        heart_rate: sample.quantity.doubleValue(for: unit)
      )
    }

    DispatchQueue.main.async {
      guard self.captureID == captureID else { return }
      self.heartRateRecords.append(contentsOf: records)
      if self.heartRateRecords.count >= self.nextHeartRateFlushCount {
        _ = self.writeHeartRateFile()
        while self.nextHeartRateFlushCount <= self.heartRateRecords.count {
          self.nextHeartRateFlushCount += 600
        }
      }
    }
  }
  private func stopHeartRateQuery() {
    if let heartRateQuery {
      healthStore.stop(heartRateQuery)
    }
    heartRateQuery = nil
  }
  private func startWorkoutIfNeeded(at startDate: Date) {
    guard workoutSession == nil else { return }

    let configuration = HKWorkoutConfiguration()
    configuration.activityType = .other
    configuration.locationType = .indoor

    do {
      let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
      let builder = session.associatedWorkoutBuilder()
      builder.dataSource = HKLiveWorkoutDataSource(
        healthStore: healthStore,
        workoutConfiguration: configuration
      )
      session.delegate = self
      builder.delegate = self
      workoutSession = session
      workoutBuilder = builder
      workoutIsEnding = false

      session.startActivity(with: startDate)
      builder.beginCollection(withStart: startDate) { [weak self, weak session] success, _ in

        guard !success else { return }
        session?.end()
        DispatchQueue.main.async {
          self?.clearWorkout(session: session)
        }
      }
    } catch {
      workoutSession = nil
      workoutBuilder = nil
    }
  }
  func endWorkout() {
    guard let session = workoutSession, let builder = workoutBuilder else {
      workoutSession = nil
      workoutBuilder = nil
      return
    }

    let endDate = Date()
    workoutIsEnding = true
    session.end()
    builder.endCollection(withEnd: endDate) { [weak self, weak session] success, _ in

      guard success else {
        DispatchQueue.main.async {
          self?.clearWorkout(session: session)
        }
        return
      }

      builder.finishWorkout { [weak self] _, _ in

        DispatchQueue.main.async {
          self?.clearWorkout(session: session)
        }
      }
    }
  }
  private func clearWorkout(session: HKWorkoutSession?) {
    guard workoutSession === session else { return }
    workoutSession = nil
    workoutBuilder = nil
    workoutIsEnding = false
  }
  private func startBatteryTimer() {
    WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      self?.recordBatterySnapshot()
    }
  }
  private func recordBatterySnapshot() {
    WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    let level = WKInterfaceDevice.current().batteryLevel
    let percentage = level >= 0 ? Int((level * 100).rounded()) : nil
    let now = Date()

    batteryRecords.append(
      BatteryRecord(
        ts: Int64(now.timeIntervalSince1970 * 1000),
        read_time: RecordingDateFormats.androidDateTime(from: now),
        capacity_pct: percentage
      )
    )

    if let percentage, percentage < 5 {
      onCriticalBattery?()
    }
  }
  private func writeFiles() -> [URL] {
    var urls: [URL] = []
    if let hrURL = writeHeartRateFile() {
      urls.append(hrURL)
    }
    if let batteryURL = writeBatteryFile() {
      urls.append(batteryURL)
    }
    return urls
  }
  private func writeHeartRateFile() -> URL? {
    guard !username.isEmpty else { return nil }
    AppDirectories.ensureAll()
    let url = AppDirectories.hrDirectory.appendingPathComponent(
      "\(username)_hr_\(recordingTimestamp).json")
    return writeJSON(heartRateRecords, to: url)
  }
  private func writeBatteryFile() -> URL? {
    guard !username.isEmpty else { return nil }
    AppDirectories.ensureAll()
    let url = AppDirectories.batteryDirectory.appendingPathComponent(
      "\(username)_battery_\(recordingTimestamp).json")
    return writeJSON(batteryRecords, to: url)
  }
  private func writeJSON<T: Encodable>(_ value: T, to url: URL) -> URL? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }
}

extension HealthDataService: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
  func workoutSession(
    _ workoutSession: HKWorkoutSession,
    didChangeTo toState: HKWorkoutSessionState,
    from fromState: HKWorkoutSessionState,
    date: Date
  ) {
    if toState == .ended, !workoutIsEnding {
      clearWorkout(session: workoutSession)
    }
  }
  func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
    clearWorkout(session: workoutSession)
  }
  func workoutBuilder(
    _ workoutBuilder: HKLiveWorkoutBuilder,
    didCollectDataOf collectedTypes: Set<HKSampleType>
  ) {
  }
  func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
  }
}
