import SwiftUI

struct RecordingHomeView: View {
  @ObservedObject var appState: AppState
  @ObservedObject private var recordingService: RecordingService
  @ObservedObject private var preferences: PreferencesStore
  @State private var accessMessage = ""
  init(appState: AppState) {
    self.appState = appState
    recordingService = appState.recordingService
    preferences = appState.preferences
  }

  var body: some View {
    ScrollView {
      VStack {
        if recordingService.autoSessionActive {
          Text(
            recordingService.isRecording ? "Auto recording in progress" : "Auto recording paused"
          )
          .font(.caption2)
          .foregroundStyle(.green)
        }

        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(timerText(at: context.date))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }

        if recordingService.isRecording || recordingService.autoSessionActive {
          Button(action: {
            recordingService.stopRecording()
          }) {
            VStack {
              Image(systemName: "stop.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .foregroundColor(.red)

              Text("Stop ACC")
                .font(.caption2)
                .foregroundColor(.red)
            }
            .padding()
          }
          .buttonStyle(PlainButtonStyle())
          if recordingService.isRecording {
            Text("Audio Recording...")
              .foregroundStyle(.red)
          }
        } else {
          Button(action: {
            recordingService.startManualRecording()
          }) {
            VStack {
              Image(systemName: "waveform.path.ecg")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .foregroundColor(.green)

              Text("Start ACC")
                .font(.caption2)
                .foregroundColor(.green)
            }
            .padding()
          }
          .buttonStyle(PlainButtonStyle())
        }

        if !recordingService.userMessage.isEmpty {
          Text(recordingService.userMessage)
            .font(.caption2)
            .foregroundStyle(.gray)
            .multilineTextAlignment(.center)
        }

        Text("Total Recorded Time\n\(totalTimeText)")
          .font(.caption2)
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)

        HStack(spacing: 4) {
          Circle()
            .fill(recordingService.ppgNeedsAttention ? Color.orange : Color.green)
            .frame(width: 6, height: 6)
          Text(recordingService.ppgStatus)
            .font(.caption2)
            .foregroundStyle(recordingService.ppgNeedsAttention ? .orange : .green)
        }
        .multilineTextAlignment(.center)

        if recordingService.isRecording || recordingService.autoSessionActive {
          Button {
            accessMessage = "Stop the automatic recording run to access the list"
          } label: {
            Image(systemName: "person.crop.circle")
          }
          .buttonStyle(.bordered)
        } else {
          NavigationLink {
            PasswordView(appState: appState)
          } label: {
            Image(systemName: "person.crop.circle")
          }
          .buttonStyle(.bordered)
        }

        if !accessMessage.isEmpty {
          Text(accessMessage)
            .font(.caption2)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
        }
      }
      .padding()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
  private func timerText(at date: Date) -> String {
    let elapsed =
      recordingService.activeRecordingStartDate.map {
        max(date.timeIntervalSince($0), 0)
      } ?? 0
    let hours = Int(elapsed) / 3600
    let minutes = (Int(elapsed) % 3600) / 60
    let seconds = Int(elapsed) % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
  }
  private var totalTimeText: String {
    let hours = Int(preferences.totalRecordingTime) / 3600
    let minutes = (Int(preferences.totalRecordingTime) % 3600) / 60
    return "\(hours)H:\(minutes)M"
  }
}
