import Foundation

final class UploadService {
  private let retryQueue: RetryQueue
  private let preferences: PreferencesStore
  init(retryQueue: RetryQueue, preferences: PreferencesStore) {
    self.retryQueue = retryQueue
    self.preferences = preferences
  }
  func uploadFiles(_ urls: [URL]) {
    for url in urls {
      upload(url)
    }
  }
  func retryQueuedUploads() {
    retryQueue.load()
    guard preferences.uploadBaseURL != nil else { return }
    for record in retryQueue.records {
      retryQueue.incrementAttempts(for: record)
      upload(URL(fileURLWithPath: record.filePath), queuedRecord: record)
    }
  }
  private func upload(_ fileURL: URL, queuedRecord: UploadQueueRecord? = nil) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      if let queuedRecord {
        retryQueue.remove(queuedRecord)
      }
      return
    }

    guard let baseURL = preferences.uploadBaseURL else {
      retryQueue.addFailedFile(fileURL)
      return
    }

    let uploadURL = baseURL.appendingPathComponent(fileURL.lastPathComponent)
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

    URLSession.shared.uploadTask(with: request, fromFile: fileURL) {
      [weak retryQueue] _, response, error in
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      DispatchQueue.main.async {
        if error == nil && (200..<300).contains(statusCode) {
          if let queuedRecord {
            retryQueue?.remove(queuedRecord)
          }
        } else {
          retryQueue?.addFailedFile(fileURL)
        }
      }
    }.resume()
  }
}
