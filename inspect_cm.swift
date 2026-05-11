import CoreMotion
import Foundation

print("Inspecting CMBatchedSensorManager...")
let manager = CMBatchedSensorManager()
print("Manager created")
// Mirroring to see properties
let mirror = Mirror(reflecting: manager)
for child in mirror.children {
    print("Property: \(child.label ?? "nil")")
}
print("Done")
