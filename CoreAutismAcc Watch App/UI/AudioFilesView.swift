import SwiftUI

struct AudioFilesView: View {
  @StateObject private var library = RecordingLibraryStore()

  var body: some View {
    List {
      ForEach(library.files) { file in
        HStack {
          Text(file.displayName)
            .lineLimit(1)
            .font(.caption2)

          Spacer()

          Button {
            library.togglePlayback(for: file)
          } label: {
            Image(systemName: library.playingURL == file.url ? "pause.fill" : "play.fill")
          }
          .buttonStyle(.borderless)
        }
        .swipeActions {
          Button(role: .destructive) {
            library.delete(file)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
    }
    .navigationTitle("Audio Files")
    .onAppear {
      library.reload()
    }
    .onDisappear {
      library.stopPlayback()
    }
  }
}
