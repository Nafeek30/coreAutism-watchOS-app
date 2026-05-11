//
//  RecordingListView.swift
//  CoreAutismAcc Watch App
//
//  Created by vijay on 2/9/26.
//

import SwiftUI

struct RecordingListView: View {
    @ObservedObject var audioRecorder: AudioRecorder
    
    var body: some View {
        List {
            ForEach(audioRecorder.recordings, id: \.self) { recording in
                Text(recording.lastPathComponent)
                    .font(.caption)
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Recordings")
    }
    
    func delete(at offsets: IndexSet) {
        audioRecorder.deleteRecording(at: offsets)
    }
}

#Preview {
    RecordingListView(audioRecorder: AudioRecorder())
}
