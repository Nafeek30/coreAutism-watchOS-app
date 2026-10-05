import SwiftUI

struct OptionsView: View {
  @ObservedObject var appState: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var confirmSignOut = false
  @State private var message = ""

  var body: some View {
    VStack(spacing: 8) {
      Button {
        dismiss()
      } label: {
        Label("Back", systemImage: "chevron.left")
      }
      .tint(.gray)

      NavigationLink("Audio Files") {
        AudioFilesView()
      }
      .tint(.green)

      NavigationLink("Settings") {
        SettingsView(appState: appState)
      }
      .tint(.green)

      Button("Sign Out") {
        // Prevent sign-out while files are actively being recorded.
        if appState.recordingService.isRecording || appState.recordingService.autoSessionActive {
          message = "Please stop the recording before signing out."
        } else {
          confirmSignOut = true
        }
      }
      .tint(.orange)
      .confirmationDialog("Are you sure you want to sign out?", isPresented: $confirmSignOut) {
        Button("Sign Out", role: .destructive) {
          appState.signOut()
        }
        Button("Cancel", role: .cancel) {}
      }

      if !message.isEmpty {
        Text(message)
          .font(.caption2)
          .foregroundStyle(.orange)
          .multilineTextAlignment(.center)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
}
