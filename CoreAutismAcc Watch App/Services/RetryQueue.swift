import Combine
import Foundation

struct UploadQueueRecord: Codable, Identifiable, Equatable {
  var id: String { filePath }
  let fileName: String
  let filePath: String
  var status: String
  var attempts: Int
}
final class RetryQueue: ObservableObject {
  private let queueURL: URL

  @Published private(set) var records: [UploadQueueRecord] = []
  init() {
    AppDirectories.ensureAll()
    queueURL = AppDirectories.queueDirectory.appendingPathComponent("upload_retry_queue.json")
    load()
  }
  func load() {
    guard let data = try? Data(contentsOf: queueURL) else {
      records = []
      return
    }
    records = (try? JSONDecoder().decode([UploadQueueRecord].self, from: data)) ?? []
  }
  func addFailedFile(_ url: URL) {
    let path = url.path
    if let index = records.firstIndex(where: { $0.filePath == path }) {
      records[index].status = "FAILED"
      save()
      return
    }

    records.append(
      UploadQueueRecord(
        fileName: url.lastPathComponent,
        filePath: path,
        status: "FAILED",
        attempts: 0
      )
    )
    save()
  }
  func incrementAttempts(for record: UploadQueueRecord) {
    guard let index = records.firstIndex(where: { $0.filePath == record.filePath }) else { return }
    records[index].attempts += 1
    save()
  }
  func remove(_ record: UploadQueueRecord) {
    records.removeAll { $0.filePath == record.filePath }
    save()
  }
  private func save() {
    guard let data = try? JSONEncoder().encode(records) else { return }
    try? data.write(to: queueURL, options: .atomic)
  }
}
