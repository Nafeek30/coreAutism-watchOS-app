import SwiftUI

struct LoginView: View {
  @ObservedObject var appState: AppState
  @State private var username = ""
  @State private var message = "Please record your voice for 30 seconds"

  var body: some View {
    VStack(spacing: 10) {
      Text("Welcome")
        .font(.headline)
        .foregroundStyle(.white)
      Text("Please Enter Your Name")
        .font(.caption)
        .foregroundStyle(.white)

      TextField("Name", text: $username)
        .textInputAutocapitalization(.never)

      Button("Submit") {
        if PreferencesStore.isValidUsername(username) {
          appState.logIn(username: username)
          message = "Please record your voice for 30 seconds"
        } else {
          message = "Name cannot contain whitespace, underscores, or slashes"
        }
      }
      .tint(.green)

      Text(message)
        .font(.caption2)
        .foregroundStyle(.gray)
        .multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
}
