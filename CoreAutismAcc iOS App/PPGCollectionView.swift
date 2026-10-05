import SwiftUI

struct PPGCollectionView: View {
  @ObservedObject var controller: PhonePPGCoordinator
  @ObservedObject var service: PPGSensorService
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label("Record from your Watch", systemImage: "applewatch")
            .font(.headline)
          Text("Use Start ACC and Stop ACC on your Watch.")
            .foregroundStyle(.secondary)
        }
        Section("PPG access") {
          LabeledContent("Permission", value: service.authorizationDescription)
          if !service.isAuthorized {
            Button(action: service.requestAuthorization) {
              Label(
                service.isAuthorizing ? "Requesting access…" : "Authorize PPG Access",
                systemImage: "hand.raised.fill"
              )
              .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
              service.isAuthorizing || service.configurationIssue != nil || service.isSimulator)
          }
        }
        Section("Watch connection") {
          Label {
            Text(controller.connectionStatus).textSelection(.enabled)
          } icon: {
            Image(systemName: "applewatch.radiowaves.left.and.right")
              .foregroundStyle(.secondary)
          }
          .font(.callout)
        }
        Section("Important: Syncing Watch PPG") {
          VStack(alignment: .leading, spacing: 6) {
            Label("How PPG transfers to iPhone", systemImage: "bolt.badge.clock.fill")
              .font(.subheadline.bold())
              .foregroundStyle(.primary)
            Text(
              "Apple Watch stores raw optical data in encrypted hardware storage. For it to transfer to this iPhone:"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("1. Unlock Apple Watch with your passcode.")
              .font(.caption)
            Text("2. Place Apple Watch on its charger next to this iPhone.")
              .font(.caption)
            Text("3. SensorKit data becomes available 24 hours after recording.")
              .font(.caption)
          }
          .padding(.vertical, 2)
        }
        Section("PPG downloads") {
          Button {
            controller.downloadAvailable()
          } label: {
            Label(
              controller.isDownloading ? "Downloading…" : "Refresh Available PPG",
              systemImage: "arrow.down.doc.fill"
            )
            .frame(maxWidth: .infinity, minHeight: 32)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!service.isAuthorized || controller.isDownloading)
          if controller.isDownloading { ProgressView() }
          Text(controller.downloadStatus)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("Watch recordings") {
          if controller.recordings.isEmpty {
            VStack(spacing: 8) {
              Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
              Text("No recordings yet").font(.headline)
              Text("Start a recording on your Watch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
          }
          ForEach(controller.recordings) { entry in
            DisclosureGroup {
              LabeledContent("Started") {
                Text(entry.session.startedAt, format: .dateTime.hour().minute().second())
              }
              if let end = entry.session.endedAt {
                LabeledContent("Ended") {
                  Text(end, format: .dateTime.hour().minute().second())
                }
              }
              if entry.files.isEmpty {
                Text("No files available")
                  .foregroundStyle(.secondary)
              }
              ForEach(entry.files, id: \.self) { filename in
                VStack(alignment: .leading, spacing: 6) {
                  Text(filename).font(.caption).foregroundStyle(.secondary)
                  ShareLink(item: controller.exportURL(filename)) {
                    Label("Share file", systemImage: "square.and.arrow.up")
                      .frame(maxWidth: .infinity, minHeight: 28)
                  }
                  .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
              }
              if service.isAuthorized {
                if let message = entry.downloadMessage {
                  Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if let issue = entry.issue {
                  Text(issue).font(.footnote).foregroundStyle(.orange)
                }
              }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "waveform")
                  .font(.title2)
                  .foregroundStyle(.tint)
                  .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                  Text(entry.session.participant)
                    .font(.headline)
                    .foregroundStyle(.primary)
                  Text(entry.session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  let status = holdingPeriodStatus(for: entry.session)
                  Text(status.text)
                    .font(.caption2)
                    .foregroundStyle(status.isReady ? .green : .orange)
                }
                Spacer()
                Text(
                  entry.session.interrupted
                    ? "Interrupted" : entry.session.endedAt == nil ? "Recording" : "Ended"
                )
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.primary)
              }
              .padding(.vertical, 6)
            }
          }
        }

      }
      .navigationTitle("CoreAutism")
      .task { controller.refresh() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { controller.refresh() }
      }
      .onChange(of: service.isAuthorized) { _, authorized in
        if authorized { controller.refresh() }
      }
    }
  }

  private func holdingPeriodStatus(for session: PPGRecordingSession) -> (
    text: String, isReady: Bool
  ) {
    guard let end = session.endedAt else { return ("Recording in progress", false) }
    let eligible = end.addingTimeInterval(
      PPGFetchWindow.holdingPeriod + PPGFetchWindow.holdingMargin)
    let remaining = eligible.timeIntervalSinceNow
    if remaining <= 0 {
      return ("Ready to download (holding period passed)", true)
    }
    let hours = Int(remaining) / 3600
    let minutes = (Int(remaining) % 3600) / 60
    if hours > 0 {
      return ("Available in \(hours)h \(minutes)m", false)
    } else {
      return ("Available in \(max(minutes, 1))m", false)
    }
  }
}
