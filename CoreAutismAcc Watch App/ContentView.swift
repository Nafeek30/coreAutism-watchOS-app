//
//  ContentView.swift
//  CoreAutismAcc Watch App
//
//  Created by vijay on 2/9/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject var audioRecorder = AudioRecorder()
    @StateObject var motionRecorder = MotionRecorder()
    
    var body: some View {
        NavigationStack {
            VStack {
                if audioRecorder.isRecording {
                    Button(action: {
                        self.audioRecorder.stopRecording()
                        self.motionRecorder.stopRecording()
                    }) {
                        Image(systemName: "stop.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 50, height: 50)
                            .foregroundColor(.red)
                            .padding()
                    }
                    .buttonStyle(PlainButtonStyle())
                    Text("Recording...")
                        .foregroundStyle(.red)
                } else {
                    Button(action: {
                        self.motionRecorder.startRecording { startDate in
                            if let startDate = startDate {
                                self.audioRecorder.startRecording(startTime: startDate)
                            }
                        }
                    }) {
                        Image(systemName: "mic.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 50, height: 50)
                            .foregroundColor(.green)
                            .padding()
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                Text(motionRecorder.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.gray)
                
                Spacer()
                    .frame(height: 20)
                
                NavigationLink(destination: RecordingListView(audioRecorder: audioRecorder)) {
                    Image(systemName: "list.bullet")
                }
                .fixedSize()
            }
            .padding()
            .onAppear {
                audioRecorder.fetchRecordings()
                motionRecorder.requestAuthorization { success in
                    if !success {
                        print("HealthKit authorization failed")
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
