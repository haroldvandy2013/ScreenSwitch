#if DEBUG
import AppKit

private final class SimulatedDisplay: DisplayBackend {
    var apiAvailable = true
    var recoveryPending = false
    var builtinActive = true
    var externalCount = 1
    var builtinKnown = true
    var delayDisable = false
    var rejectRestore = false
    var rejectDisable = false
    var calls: [Bool] = []

    func snapshot() throws -> DisplaySnapshot {
        DisplaySnapshot(
            onlineIDs: builtinActive ? [1] : [],
            builtinID: builtinKnown ? 1 : nil,
            builtinActive: builtinActive,
            usableExternalIDs: Array(10..<(10 + UInt32(externalCount)))
        )
    }

    func markRecoveryPending() -> Bool {
        recoveryPending = true
        return true
    }

    func markRecovered() { recoveryPending = false }

    func setBuiltinEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if enabled && rejectRestore { throw DisplayFailure.transaction("模拟恢复", 1000) }
        if !enabled {
            recoveryPending = true
            if rejectDisable { throw DisplayFailure.noExternal }
            if delayDisable { return }
        }
        builtinActive = enabled
    }
}

@MainActor
func runControllerChecks() {
    var count = 0
    func expect(_ condition: Bool, _ message: String) {
        count += 1
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    do {
        let backend = SimulatedDisplay()
        backend.externalCount = 0
        let control = DisplayController(driver: backend)
        control.refresh()
        expect(!control.canDisable, "No external disables menu action")
        control.disable()
        expect(backend.calls.isEmpty, "No external never issues disable")
        backend.externalCount = 1
        control.refresh()
        expect(control.canDisable && backend.calls.isEmpty, "Connection only enables manual action")
        control.disable()
        expect(backend.calls == [false] && control.recoveryPending, "Manual request disables and tracks recovery")
        backend.externalCount = 0
        control.refresh()
        control.refresh()
        expect(backend.calls == [false, true] && !control.recoveryPending, "Last external removal restores")
        backend.externalCount = 1
        control.refresh()
        expect(backend.calls == [false, true], "Reconnection never disables automatically")
    }
    do {
        let backend = SimulatedDisplay()
        backend.externalCount = 2
        let control = DisplayController(driver: backend)
        control.disable()
        backend.externalCount = 1
        control.refresh()
        expect(backend.calls == [false], "One remaining external does not restore")
        control.handleSleep()
        expect(backend.calls == [false, true], "Sleep sends restore")
        expect(!control.canDisable, "Sleep blocks manual disable")
        control.handleWake()
        expect(backend.calls == [false, true], "Wake never reapplies disable")
        expect(!control.recoveryPending, "Restoration clears recovery record")
    }
    do {
        let backend = SimulatedDisplay()
        backend.delayDisable = true
        let control = DisplayController(driver: backend)
        control.disable()
        expect(control.busy, "Disable is not reported successful before inactive verification")
        backend.externalCount = 0
        control.refresh()
        expect(backend.calls == [false, true], "Unplug sends enable even while panel still looks active")
        control.refresh()
        expect(!control.recoveryPending, "Pending disable race settles restored")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        backend.delayDisable = true
        let control = DisplayController(driver: backend, now: { clock })
        var errors: [String] = []
        control.onError = { errors.append($0) }
        control.disable()
        clock.addTimeInterval(4)
        control.refresh()
        control.refresh()
        expect(errors.count == 1, "A no-op private API reports failure")
        expect(backend.calls == [false, true], "A no-op disable rolls back via enable")
        expect(!control.recoveryPending, "Failed disable can settle restored")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend, now: { clock })
        var errors: [String] = []
        control.onError = { errors.append($0) }
        control.disable()
        backend.rejectRestore = true
        backend.externalCount = 0
        control.refresh()
        clock.addTimeInterval(6)
        control.refresh()
        clock.addTimeInterval(6)
        control.refresh()
        expect(errors.count == 1, "Restore failure presents one warning, not an alert loop")
        expect(control.recoveryPending && !control.canDisable, "Failed restore keeps durable recovery intent")
        backend.rejectRestore = false
        clock.addTimeInterval(1)
        control.refresh()
        control.refresh()
        expect(!control.recoveryPending, "Watchdog retries eventually restore")
    }
    do {
        let backend = SimulatedDisplay()
        backend.recoveryPending = true
        backend.builtinActive = false
        let control = DisplayController(driver: backend)
        control.refresh()
        control.refresh()
        expect(backend.calls == [true] && !control.recoveryPending, "Crash marker restores on next launch")
    }
    do {
        let backend = SimulatedDisplay()
        backend.apiAvailable = false
        let control = DisplayController(driver: backend)
        control.disable()
        expect(backend.calls.isEmpty, "Unavailable API blocks disable")
    }
    do {
        let backend = SimulatedDisplay()
        backend.rejectDisable = true
        let control = DisplayController(driver: backend)
        control.disable()
        expect(backend.calls == [false, true], "Rejected disable attempts safe recovery")
        expect(!control.recoveryPending, "Rejected transaction does not leave stale intent")
    }
    do {
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend)
        control.disable()
        backend.builtinActive = true
        control.refresh()
        expect(!control.recoveryPending, "OS-driven restoration clears manual off state")
        expect(backend.calls == [false], "OS restoration is not fought by re-disabling")
    }
    print("PASS: \(count) controller lifecycle checks with simulated displays; no real driver instantiated.")
}
#endif
