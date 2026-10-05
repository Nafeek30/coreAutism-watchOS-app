import Combine
import Foundation
import UserNotifications
import WatchKit

final class AppState: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  let preferences: PreferencesStore
  let recordingService: RecordingService

  private let uploadService: UploadService
  private let autoScheduler: AutoRecordingScheduler
  private var cancellables: Set<AnyCancellable> = []
  private var didBootstrap = false

  @Published var message = ""
  override init() {
    AppDirectories.ensureAll()
    let preferences = PreferencesStore()
    let retryQueue = RetryQueue()
    let uploadService = UploadService(retryQueue: retryQueue, preferences: preferences)

    self.preferences = preferences
    self.uploadService = uploadService
    self.recordingService = RecordingService(
      preferences: preferences,
      uploadService: uploadService
    )
    self.autoScheduler = AutoRecordingScheduler(
      preferences: preferences
    )

    super.init()

    UNUserNotificationCenter.current().delegate = self
    self.recordingService.onAutoRunFinished = { [weak self] in
      guard let self, self.preferences.isLoggedIn else { return }
      self.autoScheduler.scheduleNextStartNotification()
    }

    preferences.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

    recordingService.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
  func bootstrap() {
    guard !didBootstrap else {
      return
    }
    didBootstrap = true

    autoScheduler.registerNotificationCategories()
    recordingService.requestPermissions()
    uploadService.retryQueuedUploads()
    if preferences.isLoggedIn, preferences.autoEnabled, !recordingService.autoSessionActive {
      autoScheduler.scheduleNextStartNotification()
    }
  }
  func logIn(username: String) {
    preferences.save(username: username)
    if preferences.autoEnabled {
      autoScheduler.scheduleNextStartNotification()
    }
  }
  func signOut() {
    guard !recordingService.isRecording, !recordingService.autoSessionActive else { return }
    autoScheduler.cancel()
    preferences.signOut()
  }
  func saveSettings() {
    autoScheduler.saveAndSchedule()
    message = "Setting saved!"
  }
  private func startAutoRecordingFromNotification() {
    guard preferences.autoEnabled, preferences.isLoggedIn else {
      return
    }
    guard !recordingService.autoSessionActive else {
      return
    }
    guard !recordingService.isRecording else {
      autoScheduler.scheduleNextStartNotification()
      return
    }
    guard let plan = autoScheduler.recordingPlan() else {
      autoScheduler.scheduleNextStartNotification()
      return
    }

    // Queue the next daily alert now so a later crash cannot lose tomorrow's run.
    autoScheduler.dismissDeliveredStartNotification()
    autoScheduler.scheduleNextStartNotification()
    recordingService.startAutoRecording(plan: plan)
  }
  private func startAutoRecordingWhenActive(attempt: Int = 0) {
    guard WKApplication.shared().applicationState == .active else {
      guard attempt < 20 else {
        autoScheduler.scheduleNextStartNotification()
        return
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.startAutoRecordingWhenActive(attempt: attempt + 1)
      }
      return
    }

    startAutoRecordingFromNotification()
  }
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let requestIdentifier = response.notification.request.identifier
    let actionIdentifier = response.actionIdentifier
    let isStartAction =
      actionIdentifier == UNNotificationDefaultActionIdentifier
      || actionIdentifier == AutoRecordingScheduler.startActionIdentifier

    if requestIdentifier == AutoRecordingScheduler.startRequestIdentifier, isStartAction {
      completionHandler()
      startAutoRecordingWhenActive()
      return
    }

    completionHandler()
  }

}
