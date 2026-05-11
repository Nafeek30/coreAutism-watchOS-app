import Foundation
import CoreMotion
import HealthKit
import os
import SwiftUI
import Combine

class MotionRecorder: NSObject, ObservableObject {
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let motionManager = CMBatchedSensorManager()
    
    @Published var isRecording = false
    @Published var statusMessage = "Ready"
    
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    
    // Buffer for writing data
    private var csvString = ""
    
    override init() {
        super.init()
    }
    
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        let typesToShare: Set = [
            HKQuantityType.workoutType()
        ]
        
        let typesToRead: Set = [
            HKQuantityType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!
        ]
        
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { (success, error) in
            DispatchQueue.main.async {
                if success {
                    self.statusMessage = "HealthKit Authorized"
                } else {
                    self.statusMessage = "HealthKit Auth Failed: \(String(describing: error))"
                }
                completion(success)
            }
        }
    }
    
    func startRecording(completion: @escaping (Date?) -> Void) {
        guard CMBatchedSensorManager.isAccelerometerSupported else {
            statusMessage = "High-freq accel not supported"
            completion(nil)
            return
        }
        
        startWorkout { [weak self] startDate in
            guard let startDate = startDate else {
                completion(nil)
                return
            }
            if let freq = self?.motionManager.accelerometerDataFrequency {
                print("Reported Accel Freq: \(freq)")
            }
            self?.startMotionUpdates()
            completion(startDate)
        }
    }
    
    func stopRecording() {
        stopMotionUpdates()
        endWorkout()
    }
    
    private func startWorkout(completion: @escaping (Date?) -> Void) {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .indoor
        
        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            builder = workoutSession?.associatedWorkoutBuilder()
            
            builder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            
            workoutSession?.delegate = self
            builder?.delegate = self
            
            let startDate = Date()
            workoutSession?.startActivity(with: startDate)
            builder?.beginCollection(withStart: startDate) { (success, error) in
                DispatchQueue.main.async {
                    if success {
                        self.isRecording = true
                        self.statusMessage = "Workout Started"
                        self.createNewFile(startTime: startDate)
                        completion(startDate)
                    } else {
                        self.statusMessage = "Workout Start Failed: \(String(describing: error))"
                        completion(nil)
                    }
                }
            }
        } catch {
            statusMessage = "Workout Session Error: \(error.localizedDescription)"
            completion(nil)
        }
    }
    
    private func endWorkout() {
        workoutSession?.end()
        builder?.endCollection(withEnd: Date()) { (success, error) in
            self.builder?.finishWorkout { (workout, error) in
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.statusMessage = "Recording Stopped"
                    self.closeFile()
                }
            }
        }
    }
    
    private func startMotionUpdates() {
        Task {
            do {
                for try await batch in motionManager.accelerometerUpdates() {
                    if !self.isRecording { break }
                    self.processBatch(batch)
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Motion Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func stopMotionUpdates() {
        // Breaking the loop in startMotionUpdates handles the stop
    }
    
    private func processBatch(_ batch: [CMAccelerometerData]) {
        var newCSVData = ""
        // Batch might contain many samples. Iterate and format.
        // Assuming 800Hz, this is a lot of data.
        
        // Calculate and log frequency
        if let first = batch.first, let last = batch.last, batch.count > 1 {
            let duration = last.timestamp - first.timestamp
            if duration > 0 {
                let frequency = Double(batch.count) / duration
                print("Accel Batch: \(batch.count) samples, Duration: \(String(format: "%.3f", duration))s, Freq: \(String(format: "%.1f", frequency))Hz")
            }
        }
        
        for sample in batch {
            // Format: Timestamp, x, y, z
            // Use specific formatting for precision/perf trade-off
            
            // sample.timestamp is time since boot (TimeInterval).
            // sample.acceleration is CMAcceleration (x, y, z).
            
            newCSVData += String(format: "%.6f,%.6f,%.6f,%.6f\n", 
                                 sample.timestamp, sample.acceleration.x, sample.acceleration.y, sample.acceleration.z)
        }
        
        if !newCSVData.isEmpty {
            self.write(data: newCSVData)
        }
    }
    
    private func createNewFile(startTime: Date) {
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM-YY_'at'_HH-mm-ss"
        let fileName = "ACC_\(dateFormatter.string(from: startTime)).csv"
        fileURL = documentDirectory.appendingPathComponent(fileName)
        
        guard let url = fileURL else { return }
        
        fileManager.createFile(atPath: url.path, contents: "Timestamp,X,Y,Z\n".data(using: .utf8), attributes: nil)
        
        do {
            fileHandle = try FileHandle(forWritingTo: url)
            fileHandle?.seekToEndOfFile()
            print("Accel file created at: \(url.path)") // Log for debugging
        } catch {
            print("Error creating file handle: \(error)")
        }
    }
    
    private func write(data: String) {
        guard let handle = fileHandle, let dataBytes = data.data(using: .utf8) else { return }
        
        do {
            try handle.write(contentsOf: dataBytes)
        } catch {
            print("Error writing to file: \(error)")
        }
    }
    
    private func closeFile() {
        do {
            try fileHandle?.close()
        } catch {
            print("Error closing file: \(error)")
        }
        fileHandle = nil
        fileURL = nil
    }
}

extension MotionRecorder: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        // Handle state changes if needed
    }
    
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.statusMessage = "Workout Session Failed: \(error.localizedDescription)"
            self.isRecording = false
        }
    }
    
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // We really only care about maintaining the session
    }
    
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        
    }
}
