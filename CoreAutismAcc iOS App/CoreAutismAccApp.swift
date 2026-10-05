import SwiftUI
import UIKit

@MainActor
final class PhoneApplicationDelegate: NSObject, UIApplicationDelegate {
  let controller = PhonePPGCoordinator()

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    true
  }
}

@main
struct CoreAutismAccPhoneApp: App {
  @UIApplicationDelegateAdaptor(PhoneApplicationDelegate.self) private var applicationDelegate

  var body: some Scene {
    WindowGroup {
      PPGCollectionView(
        controller: applicationDelegate.controller, service: applicationDelegate.controller.sensor)
    }
  }
}
