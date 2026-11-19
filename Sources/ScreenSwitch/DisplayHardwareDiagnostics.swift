import Foundation
import IOKit

final class DisplayHardwareDiagnostics {
    static let shared = DisplayHardwareDiagnostics()

    private let queue = DispatchQueue(label: "local.ScreenSwitch.hardware-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var lastRequest = -Double.infinity
    private let capture: () -> [String]
    private let write: (String) -> Void

    init(capture: @escaping () -> [String] = DisplayHardwareDiagnostics.capture,
         write: @escaping (String) -> Void = { DiagnosticLog.shared.write($0) }) {
        self.capture = capture
        self.write = write
    }

    @discardableResult
    func request(reason: String, context: String) -> Bool {
        lock.lock()
        let uptime = ProcessInfo.processInfo.systemUptime
        guard !running, uptime - lastRequest >= 5 else {
            lock.unlock()
            return false
        }
        running = true
        lastRequest = uptime
        lock.unlock()
        let captureID = UUID().uuidString
        write("hardware_snapshot requested id=\(captureID) reason=\(reason) context=\(context)")
        queue.async {
            let started = ProcessInfo.processInfo.systemUptime
            self.write("hardware_snapshot begin id=\(captureID); asynchronous observation, not atomic with CoreGraphics")
            for line in self.capture() {
                self.write("hardware_snapshot id=\(captureID) \(line)")
            }
            self.write("hardware_snapshot end id=\(captureID) duration=\(ProcessInfo.processInfo.systemUptime - started)s")
            self.lock.lock()
            self.running = false
            self.lock.unlock()
        }
        return true
    }

    static func capture() -> [String] {
        var iterator: io_iterator_t = 0
        let result = IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
        guard result == KERN_SUCCESS else {
            return ["ERROR registry_iterator result=\(result)"]
        }
        defer { IOObjectRelease(iterator) }
        var lines: [String] = []
        var visited = 0
        var selected = 0
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            visited += 1
            let serviceClass = className(entry)
            if isRelevantClass(serviceClass) {
                selected += 1
                var registryID: UInt64 = 0
                let idResult = IORegistryEntryGetRegistryEntryID(entry, &registryID)
                lines.append("service class=\(serviceClass) registryID=\(registryID) idResult=\(idResult) ancestors=\(ancestors(entry))")
                for key in propertyKeys {
                    if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                       let formatted = scalar(value) {
                        lines.append("registryID=\(registryID) \(key)=\(formatted)")
                    }
                }
                if let power = IORegistryEntryCreateCFProperty(entry, "IOPowerManagement" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                    for key in ["CurrentPowerState", "DevicePowerState", "DriverPowerState", "MaxPowerState"] {
                        if let value = power[key], let formatted = scalar(value) {
                            lines.append("registryID=\(registryID) IOPowerManagement.\(key)=\(formatted)")
                        }
                    }
                }
            }
            if visited >= 8192 || selected >= 128 {
                lines.append("WARNING registry_snapshot_truncated visited=\(visited) selected=\(selected)")
                break
            }
        }
        if IOIteratorIsValid(iterator) == 0 {
            lines.append("WARNING registry_changed_during_capture; snapshot may be incomplete")
        }
        lines.append("registry_summary visited=\(visited) selected=\(selected)")
        if selected == 0 { lines.append("WARNING no_matching_display_or_power_services") }
        return lines
    }

    static func isRelevantClass(_ name: String) -> Bool {
        guard !name.contains("UserClient"), !name.contains("HDCP"),
              !name.contains("Audio"), !name.contains("SAC"), !name.hasPrefix("DCPEndpoint") else { return false }
        return name.contains("DCP") || name.contains("Framebuffer") || name.contains("CLCD")
            || name.hasPrefix("IODisplay") || name.hasPrefix("AppleDisplay")
            || name.hasPrefix("AppleBacklightDisplay") || name.hasPrefix("IOAVService")
            || name == "IOPMrootDomain"
    }

    static func scalar(_ value: Any) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        if let data = value as? Data, data.count <= 8 {
            return "0x" + data.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }

    private static let propertyKeys = [
        "built-in", "DisplayVendorID", "DisplayProductID", "DisplayID", "CGDirectDisplayID",
        "IOFBOnline", "IOFBActive", "IOFBConnectIndex", "IOFBConnectFlags",
        "IOFBDependentID", "IOFBDependentIndex", "IOFBTransform",
        "DisplayWidth", "DisplayHeight", "primary", "NormalModeActive",
        "IOMFBIntDcpUsedForExtWhenLidClose", "IOMFBIsMainDisplay", "IOMFBIsActive",
        "IOMFBIsPowered", "IOMFBOnline", "displayOnContinuousTimestamp",
        "AppleClamshellState", "AppleClamshellCausesSleep", "SleepDisabled"
    ]

    private static func className(_ entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        let result = IOObjectGetClass(entry, &name)
        return result == KERN_SUCCESS ? String(cString: name) : "unknown(result=\(result))"
    }

    private static func ancestors(_ entry: io_registry_entry_t) -> String {
        var child = entry
        var owned = false
        defer { if owned { IOObjectRelease(child) } }
        var classes: [String] = []
        for _ in 0..<6 {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(child, kIOServicePlane, &parent)
            if owned { IOObjectRelease(child); owned = false }
            guard result == KERN_SUCCESS else { break }
            child = parent
            owned = true
            var id: UInt64 = 0
            let idResult = IORegistryEntryGetRegistryEntryID(parent, &id)
            classes.append("\(className(parent))#\(id)(result=\(idResult))")
        }
        return classes.joined(separator: "/")
    }
}
