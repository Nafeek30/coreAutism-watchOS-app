import SwiftUI

struct PasswordView: View {
  @ObservedObject var appState: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var password = ""
  @State private var message = ""
  @State private var unlocked = false

  var body: some View {
    VStack(spacing: 8) {
      if unlocked {
        OptionsView(appState: appState)
      } else {
        Text("Enter password to access local audio files or to log out.")
          .font(.caption2)
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)

        SecureField("Password", text: $password)

        Button("Submit") {
          if password == "autism" || password == "Autism" {
            unlocked = true
          } else {
            message = "Incorrect Password"
          }
        }
        .tint(.green)

        Button("Cancel") {
          dismiss()
        }
        .tint(.gray)

        if !message.isEmpty {
          Text(message)
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
}
