import Foundation

struct PPGSampleRecord: Encodable {
  let kind = "ppg_sample"
  let fetchTimestampSR: Double
  let fetchTimestampUnixSeconds: Double
  let sessionStartUnixSeconds: Double
  let nanosecondsSinceStart: Int64
  let usage: [String]
  let temperatureCelsius: Double?
  let opticalSamples: [PPGOpticalRecord]
  let accelerometerSamples: [PPGAccelerationRecord]

  func cropped(to recording: PPGRecordingSession) -> Self? {
    let optical = opticalSamples.filter {
      recording.contains(
        sessionStart: sessionStartUnixSeconds, offsetNanoseconds: $0.nanosecondsSinceStart)
    }
    let motion = accelerometerSamples.filter {
      recording.contains(
        sessionStart: sessionStartUnixSeconds, offsetNanoseconds: $0.nanosecondsSinceStart)
    }
    guard !optical.isEmpty || !motion.isEmpty else { return nil }
    return Self(
      fetchTimestampSR: fetchTimestampSR, fetchTimestampUnixSeconds: fetchTimestampUnixSeconds,
      sessionStartUnixSeconds: sessionStartUnixSeconds,
      nanosecondsSinceStart: nanosecondsSinceStart,
      usage: usage, temperatureCelsius: temperatureCelsius, opticalSamples: optical,
      accelerometerSamples: motion)
  }
}

struct PPGOpticalRecord: Encodable {
  let nanosecondsSinceStart: Int64
  let emitter: Int
  let activePhotodiodeIndexes: [Int]
  let signalIdentifier: Int
  let nominalWavelengthNanometers: Double
  let effectiveWavelengthNanometers: Double
  let samplingFrequencyHz: Double
  let normalizedReflectance: Double?
  let conditions: [String]
  let noiseTerms: PPGNoiseRecord?
}

struct PPGNoiseRecord: Encodable {
  let whiteNoise: Double
  let pinkNoise: Double
  let backgroundNoise: Double
  let backgroundNoiseOffset: Double
}

struct PPGAccelerationRecord: Encodable {
  let nanosecondsSinceStart: Int64
  let samplingFrequencyHz: Double
  let xMetersPerSecondSquared: Double
  let yMetersPerSecondSquared: Double
  let zMetersPerSecondSquared: Double
}

struct PPGDeviceRecord: Encodable {
  let name: String
  let model: String
  let productType: String
  let systemName: String
  let systemVersion: String
  static func sourceIndex(in devices: [Self], watchName: String) -> Int? {
    let watches = devices.indices.filter {
      devices[$0].productType.hasPrefix("Watch") || devices[$0].model.lowercased().contains("watch")
        || devices[$0].systemName.lowercased().replacingOccurrences(of: " ", with: "") == "watchos"
    }
    let matches = watches.filter { devices[$0].name == watchName }
    if matches.count == 1 { return matches[0] }
    return watches.count == 1 ? watches[0] : nil
  }
}

struct PPGExportMetadata: Encodable {
  let kind = "export_metadata"
  let schemaVersion = 2
  let exportID: UUID
  let exportLabel: String
  let exportedAtUnixSeconds: Double
  let fromExclusiveUnixSeconds: Double
  let toInclusiveUnixSeconds: Double
  let device: PPGDeviceRecord
  var recordingSession: PPGRecordingSession? = nil
  var collectionConfirmation: PPGCollectionConfirmation? = nil
  let timestampNotes =
    "Optical and accelerometer offsets are nanoseconds relative to session_start_unix_seconds. Fetch timestamps identify the SensorKit datastore record."
  let missingValueNotes =
    "Absent optional values mean unavailable, not zero. Non-finite numeric values are encoded as NaN, Infinity, or -Infinity strings."
}

struct PPGCollectionConfirmation: Encodable {
  let startConfirmedAtUnixSeconds: Double?
  let stopConfirmedAtUnixSeconds: Double?
  let issue: String?
}

struct PPGExportSummary: Encodable {
  let kind = "export_summary"
  let complete: Bool
  let sampleCount: Int
  let opticalSampleCount: Int
  let accelerometerSampleCount: Int
}

enum PPGFetchWindow {
  static let holdingPeriod: TimeInterval = 24 * 60 * 60
  static let holdingMargin: TimeInterval = 60 * 60
  static func eligibleThrough(now: Date = Date()) -> Date {
    now.addingTimeInterval(-holdingPeriod - holdingMargin)
  }
}
final class PPGExportWriter {
  let partialURL: URL
  let finalURL: URL
  private let handle: FileHandle
  private let encoder: JSONEncoder
  private var closed = false
  private(set) var sampleCount = 0
  private(set) var opticalSampleCount = 0
  private(set) var accelerometerSampleCount = 0

  init(directory: URL, metadata: PPGExportMetadata) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let filename = "ppg_\(Int(metadata.exportedAtUnixSeconds))_\(metadata.exportID.uuidString)"
    finalURL = directory.appendingPathComponent(filename).appendingPathExtension("jsonl")
    partialURL = directory.appendingPathComponent(filename).appendingPathExtension("partial")
    encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
    )
    guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    handle = try FileHandle(forWritingTo: partialURL)
    do {
      try write(metadata)
    } catch {
      try? handle.close()
      closed = true
      throw error
    }
  }

  func append(_ record: PPGSampleRecord) throws {
    try write(record)
    sampleCount += 1
    opticalSampleCount += record.opticalSamples.count
    accelerometerSampleCount += record.accelerometerSamples.count
  }

  func finish() throws -> URL {
    try write(
      PPGExportSummary(
        complete: true, sampleCount: sampleCount,
        opticalSampleCount: opticalSampleCount, accelerometerSampleCount: accelerometerSampleCount
      ))
    try handle.synchronize()
    try handle.close()
    closed = true
    try FileManager.default.moveItem(at: partialURL, to: finalURL)
    return finalURL
  }
  func abandon() {
    guard !closed else { return }
    try? handle.close()
    closed = true
  }
  func discard() {
    abandon()
    try? FileManager.default.removeItem(at: partialURL)
  }
  static func removeEmptyPartials(in directory: URL, excluding active: URL? = nil) {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
      )) ?? []
    for url in urls where url.pathExtension == "partial" && url != active {
      guard let data = try? Data(contentsOf: url) else { continue }
      let newlineCount = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
      if newlineCount <= 1 {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  private func write<T: Encodable>(_ record: T) throws {
    guard !closed else { throw CocoaError(.fileWriteUnknown) }
    var data = try encoder.encode(record)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }

  deinit { abandon() }
}
