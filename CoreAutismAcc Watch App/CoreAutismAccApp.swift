import SwiftUI

@main
struct CoreAutismAcc_Watch_AppApp: App {
  @StateObject private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      ContentView(appState: appState)
    }
  }
}
