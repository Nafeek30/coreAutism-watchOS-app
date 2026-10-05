import Combine
import Foundation
import SensorKit

@MainActor
final class PPGSensorService: NSObject, ObservableObject {
  @Published private(set) var authorizationStatus: SRAuthorizationStatus = .notDetermined
  @Published private(set) var collectionRequested: Bool
  @Published private(set) var isAuthorizing = false
  @Published private(set) var isChangingCollection = false
  @Published private(set) var isFetching = false
  @Published private(set) var fetchedSampleCount = 0
  @Published private(set) var status =
    "Authorize PPG once, then record using Start ACC on your Watch."

  private var reader: SRSensorReader?
  private var pendingFetch: (from: Date, to: Date, label: String, session: PPGRecordingSession)?
  private var controlCompletion: ((Result<Date, Error>) -> Void)?
  private var controlTimeout: DispatchWorkItem?
  static let controlTimeoutSeconds: TimeInterval = 20
  private var fetchCompletion: ((Result<PPGFetchOutcome, Error>) -> Void)?
  private var fetchedFiles: [URL] = []
  private var opticalCount = 0
  private var collectionConfirmation: PPGCollectionConfirmation?
  var onAuthorizationRevoked: (() -> Void)?
  private var remainingDevices: [SRDevice] = []
  private var activeRequest: SRFetchRequest?
  private var writer: PPGExportWriter?
  private var completedDeviceCount = 0
  private let defaults: UserDefaults
  private let directory = URL.documentsDirectory.appendingPathComponent("PPG", isDirectory: true)

  var configurationIssue: String? {
    guard
      let value = Bundle.main.object(forInfoDictionaryKey: "NSSensorKitPrivacyPolicyURL")
        as? String,
      let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
      !host.hasSuffix(".invalid"), host != "example.com"
    else {
      return
        "The study privacy-policy URL has not been configured. Set NSSensorKitPrivacyPolicyURL in the iPhone app’s Info.plist before requesting access."
    }
    return nil
  }

  var authorizationDescription: String {
    switch authorizationStatus {
    case .notDetermined: return "Not requested"
    case .authorized: return "Authorized"
    case .denied: return "Not authorized"
    @unknown default: return "Unknown"
    }
  }

  var isAuthorized: Bool { authorizationStatus == .authorized }

  var isSimulator: Bool {
    #if targetEnvironment(simulator)
      true
    #else
      false
    #endif
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    collectionRequested = defaults.bool(forKey: "ppg.collectionRequested")
    super.init()
    refreshExports()
  }

  func refreshAuthorization() {
    guard let reader = configuredReader() else { return }
    authorizationStatus = reader.authorizationStatus
    if authorizationStatus == .denied {
      setCollectionRequested(false)
    } else if authorizationStatus == .authorized {
      ensureRecording()
    }
  }
  func ensureRecording() {
    guard authorizationStatus == .authorized else { return }
    guard !isChangingCollection else { return }
    guard let reader = authorizedReader() else { return }
    isChangingCollection = true
    status = "Ensuring SensorKit PPG collection is active…"
    armControlTimeout(action: "startRecording")
    reader.startRecording()
  }

  func requestAuthorization() {
    guard !isAuthorizing else { return }
    if let issue = configurationIssue {
      status = issue
      return
    }
    guard configuredReader() != nil else { return }
    isAuthorizing = true
    status = "Waiting for your SensorKit permission choice…"
    SRSensorReader.requestAuthorization(sensors: [.photoplethysmogram]) { [weak self] error in
      guard let self else { return }
      self.onMain {
        self.isAuthorizing = false
        self.authorizationStatus = self.reader?.authorizationStatus ?? .notDetermined
        if self.authorizationStatus == .authorized {
          self.status = "PPG is ready. Use Start ACC on your Watch to record."
          self.ensureRecording()
        } else if let error {
          self.status = "Authorization failed: \(self.describe(error))"
        } else {
          self.status =
            "PPG access was not granted. You can change it in Settings → Privacy & Security → Research Sensor & Usage Data."
        }
      }
    }
  }

  func startCollection(completion: @escaping (Result<Date, Error>) -> Void) {
    guard !isChangingCollection else {
      completion(.failure(PPGServiceError("PPG is handling another request.")))
      return
    }
    guard let reader = authorizedReader() else {
      completion(.failure(PPGServiceError(status)))
      return
    }
    // Always ask SensorKit, even when a previous start was cached, so every
    // Watch session gets a live confirmation instead of a remembered one.
    controlCompletion = completion
    isChangingCollection = true
    status = "Starting PPG for the Watch recording…"
    armControlTimeout(action: "startRecording")
    reader.startRecording()
  }

  private func armControlTimeout(action: String) {
    controlTimeout?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.isChangingCollection else { return }
      self.status = "SensorKit did not respond to \(action). PPG collection state is unknown."
      self.completeControl(
        .failure(
          PPGServiceError(
            "SensorKit did not confirm \(action) within \(Int(Self.controlTimeoutSeconds)) seconds."
          )))
    }
    controlTimeout = item
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlTimeoutSeconds, execute: item)
  }

  func stopCollection(completion: @escaping (Result<Date, Error>) -> Void) {
    // Continuous SensorKit collection is preserved so watchOS and iOS
    // sensor pipelines stay active. The session boundary is recorded.
    completion(.success(Date()))
  }

  private func completeControl(_ result: Result<Date, Error>) {
    controlTimeout?.cancel()
    controlTimeout = nil
    let completion = controlCompletion
    controlCompletion = nil
    isChangingCollection = false
    completion?(result)
  }

  func fetch(
    session: PPGRecordingSession, confirmation: PPGCollectionConfirmation? = nil,
    completion: @escaping (Result<PPGFetchOutcome, Error>) -> Void
  ) {
    guard !isFetching else {
      completion(.failure(PPGServiceError("A download is already in progress.")))
      return
    }
    guard let reader = authorizedReader() else {
      completion(.failure(PPGServiceError(status)))
      return
    }
    guard let end = session.endedAt, !session.interrupted, session.startedAt < end,
      end <= PPGFetchWindow.eligibleThrough()
    else {
      completion(
        .failure(PPGServiceError("This recording has not finished its 24-hour holding period.")))
      return
    }
    pendingFetch = (session.startedAt, end, session.participant, session)
    fetchCompletion = completion
    collectionConfirmation = confirmation
    fetchedFiles = []
    opticalCount = 0
    remainingDevices = []
    fetchedSampleCount = 0
    completedDeviceCount = 0
    isFetching = true
    status = "Finding PPG for \(session.participant)’s Watch recording…"
    reader.fetchDevices()
  }

  func refreshExports() {
    PPGExportWriter.removeEmptyPartials(in: directory, excluding: writer?.partialURL)
  }

  private func configuredReader() -> SRSensorReader? {
    guard !isSimulator else {
      status =
        "PPG collection requires a physical iPhone paired with an Apple Watch. The simulator can display this screen but cannot collect PPG."
      return nil
    }
    if let reader { return reader }
    // Physical builds require the uppercase PPG permission.
    let reader = SRSensorReader(sensor: .photoplethysmogram)
    reader.delegate = self
    self.reader = reader
    authorizationStatus = reader.authorizationStatus
    return reader
  }

  private func authorizedReader() -> SRSensorReader? {
    guard let reader = configuredReader() else { return nil }
    authorizationStatus = reader.authorizationStatus
    guard authorizationStatus == .authorized else {
      status = "Authorize PPG access before starting collection or fetching data."
      return nil
    }
    return reader
  }

  private func fetchNextDevice() {
    guard let reader, let pendingFetch else { return }
    guard !remainingDevices.isEmpty else {
      isFetching = false
      self.pendingFetch = nil
      status =
        fetchedSampleCount == 0
        ? "Fetch completed with no PPG samples. Check that collection was started during the selected period, the Watch was worn, and its data has synced. Recent data is held for 24 hours."
        : "Saved \(fetchedSampleCount) PPG sample groups from \(completedDeviceCount) Watch source(s). Open or share the exports below."
      let completion = fetchCompletion
      fetchCompletion = nil
      completion?(.success(PPGFetchOutcome(files: fetchedFiles, opticalSampleCount: opticalCount)))
      return
    }
    let device = remainingDevices.removeFirst()
    let request = SRFetchRequest()
    request.device = device
    // Query through the current eligible datastore bound, because datastore write
    // timestamps can differ from sample acquisition timestamps. The bound already
    // includes PPGFetchWindow.holdingMargin so the request never touches the holding period.
    let queryFromDate = pendingFetch.from.addingTimeInterval(-86400 * 2)
    let queryToDate = PPGFetchWindow.eligibleThrough()
    request.from = SRAbsoluteTime.fromCFAbsoluteTime(
      _cf: queryFromDate.timeIntervalSinceReferenceDate)
    request.to = SRAbsoluteTime.fromCFAbsoluteTime(_cf: queryToDate.timeIntervalSinceReferenceDate)
    do {
      var metadata = PPGExportMetadata(
        exportID: UUID(), exportLabel: pendingFetch.label,
        exportedAtUnixSeconds: Date().timeIntervalSince1970,
        fromExclusiveUnixSeconds: pendingFetch.from.timeIntervalSince1970,
        toInclusiveUnixSeconds: pendingFetch.to.timeIntervalSince1970,
        device: PPGDeviceRecord(
          name: device.name, model: device.model, productType: device.productType,
          systemName: device.systemName, systemVersion: device.systemVersion)
      )
      metadata.recordingSession = pendingFetch.session
      metadata.collectionConfirmation = collectionConfirmation
      writer = try PPGExportWriter(directory: directory, metadata: metadata)
      activeRequest = request
      status = "Fetching PPG from \(device.name)…"
      reader.fetch(request)
    } catch {
      failFetch("Could not create the export: \(describe(error))")
    }
  }

  private func failFetch(_ message: String) {
    writer?.abandon()
    writer = nil
    activeRequest = nil
    pendingFetch = nil
    remainingDevices = []
    isFetching = false
    status = message + " Any completed exports are preserved. Retry the same time range."
    refreshExports()
    let completion = fetchCompletion
    fetchCompletion = nil
    completion?(.failure(PPGServiceError(status)))
  }

  private func setCollectionRequested(_ requested: Bool) {
    collectionRequested = requested
    defaults.set(requested, forKey: "ppg.collectionRequested")
  }

  private func describe(_ error: Error) -> String {
    let error = error as NSError
    return "\(error.localizedDescription) (\(error.domain), \(error.code))"
  }

  // SensorKit's callback data is valid only until its delegate returns. Work
  // synchronously on our state executor, including copying values to JSON.
  nonisolated private func onMain<T>(_ action: @MainActor () -> T) -> T {
    if Thread.isMainThread {
      return MainActor.assumeIsolated { action() }
    }
    return DispatchQueue.main.sync { action() }
  }
}

extension PPGSensorService: SRSensorReaderDelegate {
  nonisolated func sensorReader(
    _ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus
  ) {
    onMain {
      self.authorizationStatus = authorizationStatus
      if authorizationStatus == .denied {
        setCollectionRequested(false)
        completeControl(.failure(PPGServiceError("PPG permission was revoked.")))
        onAuthorizationRevoked?()
        if isFetching { failFetch("PPG permission was revoked.") }
        status = "PPG access is not authorized. Review Research Sensor & Usage Data in Settings."
      }
    }
  }

  nonisolated func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
    onMain {
      isChangingCollection = false
      setCollectionRequested(true)
      status = "PPG enabled for the Watch recording. Data is available after the holding period."
      completeControl(.success(Date()))
    }
  }

  nonisolated func sensorReader(
    _ reader: SRSensorReader, startRecordingFailedWithError error: Error
  ) {
    onMain {
      isChangingCollection = false
      status = "Could not start collection: \(describe(error))"
      completeControl(.failure(error))
    }
  }

  nonisolated func sensorReaderDidStopRecording(_ reader: SRSensorReader) {
    onMain {
      isChangingCollection = false
      setCollectionRequested(false)
      status = "The Watch recording has stopped. PPG will download after the holding period."
      completeControl(.success(Date()))
    }
  }

  nonisolated func sensorReader(_ reader: SRSensorReader, stopRecordingFailedWithError error: Error)
  {
    onMain {
      isChangingCollection = false
      status = "Could not stop collection: \(describe(error))"
      completeControl(.failure(error))
    }
  }

  nonisolated func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
    onMain {
      guard isFetching, pendingFetch != nil else { return }
      let watchName = pendingFetch!.session.watchName
      let sourceRecords = devices.map {
        PPGDeviceRecord(
          name: $0.name, model: $0.model, productType: $0.productType,
          systemName: $0.systemName, systemVersion: $0.systemVersion)
      }
      guard let selectedIndex = PPGDeviceRecord.sourceIndex(in: sourceRecords, watchName: watchName)
      else {
        failFetch(
          "SensorKit returned \(devices.count) source(s), but no unique Watch source could be selected for \(watchName)."
        )
        return
      }
      remainingDevices = [devices[selectedIndex]]
      fetchNextDevice()
    }
  }

  nonisolated func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error)
  {
    onMain { failFetch("Could not discover Watch sources: \(describe(error))") }
  }

  nonisolated func sensorReader(
    _ reader: SRSensorReader, fetching fetchRequest: SRFetchRequest,
    didFetchResult result: SRFetchResult<AnyObject>
  ) -> Bool {
    onMain {
      guard activeRequest === fetchRequest, let writer else { return false }
      let samples: [SRPhotoplethysmogramSample]
      if let array = result.sample as? [SRPhotoplethysmogramSample] {
        samples = array
      } else if let single = result.sample as? SRPhotoplethysmogramSample {
        samples = [single]
      } else {
        failFetch(
          "SensorKit returned an unexpected PPG sample type: \(String(describing: type(of: result.sample)))"
        )
        return false
      }
      do {
        for sample in samples {
          let record = PPGSampleRecord(
            fetchTimestampSR: result.timestamp.rawValue,
            fetchTimestampUnixSeconds: Date(
              timeIntervalSinceReferenceDate: result.timestamp.toCFAbsoluteTime()
            ).timeIntervalSince1970,
            sessionStartUnixSeconds: sample.startDate.timeIntervalSince1970,
            nanosecondsSinceStart: sample.nanosecondsSinceStart,
            usage: sample.usage.map(\.rawValue),
            temperatureCelsius: sample.temperature?.converted(to: .celsius).value,
            opticalSamples: sample.opticalSamples.map { optical in
              PPGOpticalRecord(
                nanosecondsSinceStart: optical.nanosecondsSinceStart, emitter: optical.emitter,
                activePhotodiodeIndexes: Array(optical.activePhotodiodeIndexes),
                signalIdentifier: optical.signalIdentifier,
                nominalWavelengthNanometers: optical.nominalWavelength.converted(to: .nanometers)
                  .value,
                effectiveWavelengthNanometers: optical.effectiveWavelength.converted(
                  to: .nanometers
                ).value,
                samplingFrequencyHz: optical.samplingFrequency.converted(to: .hertz).value,
                normalizedReflectance: optical.normalizedReflectance,
                conditions: optical.conditions.map(\.rawValue),
                noiseTerms: optical.noiseTerms.map {
                  PPGNoiseRecord(
                    whiteNoise: $0.whiteNoise, pinkNoise: $0.pinkNoise,
                    backgroundNoise: $0.backgroundNoise,
                    backgroundNoiseOffset: $0.backgroundNoiseOffset)
                }
              )
            },
            accelerometerSamples: sample.accelerometerSamples.map {
              PPGAccelerationRecord(
                nanosecondsSinceStart: $0.nanosecondsSinceStart,
                samplingFrequencyHz: $0.samplingFrequency.converted(to: .hertz).value,
                xMetersPerSecondSquared: $0.x.converted(to: .metersPerSecondSquared).value,
                yMetersPerSecondSquared: $0.y.converted(to: .metersPerSecondSquared).value,
                zMetersPerSecondSquared: $0.z.converted(to: .metersPerSecondSquared).value
              )
            }
          )
          if let session = pendingFetch?.session, let cropped = record.cropped(to: session) {
            try writer.append(cropped)
            fetchedSampleCount += 1
            opticalCount += cropped.opticalSamples.count
          }
        }
        return true
      } catch {
        failFetch("Could not save PPG data: \(describe(error))")
        return false
      }
    }
  }

  nonisolated func sensorReader(
    _ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest
  ) {
    onMain {
      guard activeRequest === fetchRequest, let writer else { return }
      do {
        if opticalCount > 0 {
          fetchedFiles.append(try writer.finish())
        } else {
          // The fetch completed normally with no samples; the file holds only metadata.
          writer.discard()
        }
        self.writer = nil
        activeRequest = nil
        completedDeviceCount += 1
        refreshExports()
        fetchNextDevice()
      } catch {
        failFetch("Could not finalize the export: \(describe(error))")
      }
    }
  }

  nonisolated func sensorReader(
    _ reader: SRSensorReader, fetching fetchRequest: SRFetchRequest,
    failedWithError error: Error
  ) {
    onMain {
      guard activeRequest === fetchRequest else { return }
      failFetch("PPG fetch failed: \(describe(error))")
    }
  }
}

struct PPGServiceError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

struct PPGFetchOutcome {
  let files: [URL]
  let opticalSampleCount: Int
}
