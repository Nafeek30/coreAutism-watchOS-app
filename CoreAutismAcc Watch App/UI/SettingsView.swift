import SwiftUI

struct SettingsView: View {
  @ObservedObject var appState: AppState
  @ObservedObject private var preferences: PreferencesStore
  @State private var frequency: DataCollectionFrequency
  @State private var startHour: Int
  @State private var startMinute: Int
  @State private var endHour: Int
  @State private var endMinute: Int
  init(appState: AppState) {
    self.appState = appState
    preferences = appState.preferences
    _frequency = State(initialValue: appState.preferences.dataCollectionFrequency)
    _startHour = State(initialValue: appState.preferences.autoStartHour)
    _startMinute = State(initialValue: appState.preferences.autoStartMinute)
    _endHour = State(initialValue: appState.preferences.autoEndHour)
    _endMinute = State(initialValue: appState.preferences.autoEndMinute)
  }

  var body: some View {
    Form {
      Picker("Data Collection Frequency", selection: $frequency) {
        ForEach(DataCollectionFrequency.allCases) { frequency in
          Text(frequency.rawValue).tag(frequency)
        }
      }

      Section("Auto Recording") {
        CompactTimeEditor(
          title: "Auto Start",
          hour: $startHour,
          minute: $startMinute
        )

        CompactTimeEditor(
          title: "Auto Stop",
          hour: $endHour,
          minute: $endMinute
        )
      }

      Button("Save") {
        preferences.dataCollectionFrequency = frequency
        preferences.autoStartHour = startHour
        preferences.autoStartMinute = startMinute
        preferences.autoEndHour = endHour
        preferences.autoEndMinute = endMinute
        appState.saveSettings()
      }
      .tint(.green)

      if !appState.message.isEmpty {
        Text(appState.message)
          .font(.caption2)
          .foregroundStyle(.green)
      }
    }
    .navigationTitle("Settings")
    .onAppear {
      appState.message = ""
    }
  }
}
private struct CompactTimeEditor: View {
  let title: String
  @Binding var hour: Int
  @Binding var minute: Int

  var body: some View {
    VStack(spacing: 6) {
      HStack {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.white)
        Spacer()
        Text(String(format: "%02d:%02d", hour, minute))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.green)
      }

      VStack(spacing: 4) {
        CompactValueControl(label: "Hr", value: $hour, range: 0...23)
        CompactValueControl(label: "Min", value: $minute, range: 0...59)
      }
    }
    .padding(8)
    .background(Color.gray.opacity(0.18))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}
private struct CompactValueControl: View {
  let label: String
  @Binding var value: Int
  let range: ClosedRange<Int>

  var body: some View {
    HStack(spacing: 6) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.gray)
        .frame(width: 28, alignment: .leading)

      Spacer(minLength: 0)

      Button {
        value = value == range.lowerBound ? range.upperBound : value - 1
      } label: {
        Image(systemName: "minus")
          .font(.caption2.weight(.bold))
          .frame(width: 36, height: 36)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .background(Color.gray.opacity(0.35))
      .clipShape(Circle())

      Text(String(format: "%02d", value))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: 24)

      Button {
        value = value == range.upperBound ? range.lowerBound : value + 1
      } label: {
        Image(systemName: "plus")
          .font(.caption2.weight(.bold))
          .frame(width: 36, height: 36)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .background(Color.gray.opacity(0.35))
      .clipShape(Circle())
    }
    .frame(maxWidth: .infinity, minHeight: 36)
  }
}
