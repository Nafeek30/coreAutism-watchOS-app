import Foundation
import SwiftUI
import Combine
import AVFoundation

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordings: [URL] = []
    
    var audioRecorder: AVAudioRecorder?
    
    override init() {
        super.init()
        fetchRecordings()
    }
    
    func startRecording(startTime: Date) {
        let recordingSession = AVAudioSession.sharedInstance()
        
        do {
            try recordingSession.setCategory(.playAndRecord, mode: .default)
            try recordingSession.setActive(true)
        } catch {
            print("Failed to set up recording session")
        }
        
        let documentPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM-YY_'at'_HH-mm-ss"
        let audioFilename = documentPath.appendingPathComponent("\(dateFormatter.string(from: startTime)).m4a")
        
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.record()
            print("Recording started at: \(audioFilename.path)")
            
            DispatchQueue.main.async {
                self.isRecording = true
            }
        } catch {
            print("Could not start recording")
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.fetchRecordings()
        }
    }
    
    func fetchRecordings() {
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directoryContents = try! fileManager.contentsOfDirectory(at: documentDirectory, includingPropertiesForKeys: nil)
        
        DispatchQueue.main.async {
            self.recordings = directoryContents.filter { $0.pathExtension == "m4a" }.sorted(by: { $0.creationDate > $1.creationDate })
        }
    }
    
    func deleteRecording(at offsets: IndexSet) {
        var filesToDelete: [URL] = []
        
        for index in offsets {
            let audioURL = recordings[index]
            filesToDelete.append(audioURL)
            
            // Construct corresponding CSV filename
            // Audio: .../dd-MM-YY_'at'_HH-mm-ss.m4a
            // CSV: .../ACC_dd-MM-YY_'at'_HH-mm-ss.csv
            
            let filename = audioURL.deletingPathExtension().lastPathComponent
            let csvFilename = "ACC_\(filename).csv"
            let csvURL = audioURL.deletingLastPathComponent().appendingPathComponent(csvFilename)
            filesToDelete.append(csvURL)
        }
        
        let fileManager = FileManager.default
        for url in filesToDelete {
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    print("Deleted file: \(url.lastPathComponent)")
                }
            } catch {
                print("Could not delete file: \(error)")
            }
        }
        
        // Update the list
        fetchRecordings()
    }
}

extension URL {
    var creationDate: Date {
        (try? resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
    }
}
