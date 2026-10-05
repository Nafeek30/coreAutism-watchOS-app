import SwiftUI

struct ContentView: View {
  @ObservedObject var appState: AppState

  var body: some View {
    NavigationStack {
      Group {
        if appState.preferences.isLoggedIn {
          RecordingHomeView(appState: appState)
        } else {
          LoginView(appState: appState)
        }
      }
    }
    .onAppear {
      appState.bootstrap()
    }
  }
}
