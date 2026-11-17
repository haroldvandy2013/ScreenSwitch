#if DEBUG
import AppKit

final class SimulatedDisplay: DisplayBackend {
    var apiAvailable = true
    var recoveryPending = false
    var builtinActive = true
    var externalCount = 1
    var builtinKnown = true
    var delayDisable = false
    var rejectRestore = false
    var delayRestore = false
    var rejectDisable = false
    var externalAsleep = false
    var savedRestoreCalls = 0
    var savedRestoreSucceeds = false
    var rejectSnapshot = false
    var snapshotCalls = 0
    var calls: [Bool] = []

    func snapshot() throws -> DisplaySnapshot {
        snapshotCalls += 1
        if rejectSnapshot { throw DisplayFailure.enumeration(1001) }
        return DisplaySnapshot(
            onlineIDs: (builtinActive ? [1] : []) + Array(10..<(10 + UInt32(externalCount))),
            builtinID: builtinKnown ? 1 : nil,
            builtinActive: builtinActive,
            availableExternalIDs: Array(10..<(10 + UInt32(externalCount))),
            usableExternalIDs: externalAsleep ? [] : Array(10..<(10 + UInt32(externalCount))),
            externalDisplaysAsleep: externalAsleep && externalCount > 0
        )
    }

    func markRecoveryPending() -> Bool {
        recoveryPending = true
        return true
    }

    func markRecovered() { recoveryPending = false }

    func diagnosticText() throws -> String { "Simulated displays — no hardware operations" }

    func restoreSavedConfiguration() {
        savedRestoreCalls += 1
        if savedRestoreSucceeds { builtinActive = true }
    }

    func setBuiltinEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if enabled && rejectRestore { throw DisplayFailure.transaction(.restore, 1000) }
        if enabled && delayRestore { return }
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
    func confirmRecovery(_ control: DisplayController) {
        control.refresh(readOnly: true)
        Thread.sleep(forTimeInterval: 2.05)
        control.refresh(readOnly: true)
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
        confirmRecovery(control)
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
        confirmRecovery(control)
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
        confirmRecovery(control)
        expect(!control.recoveryPending, "Pending disable race settles restored")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        backend.delayDisable = true
        let control = DisplayController(driver: backend, now: { clock })
        var errors: [Error] = []
        control.onError = { errors.append($0) }
        control.disable()
        clock.addTimeInterval(4)
        control.refresh()
        control.refresh()
        clock.addTimeInterval(2)
        control.refresh(readOnly: true)
        expect(errors.count == 1, "A no-op private API reports failure")
        expect(backend.calls == [false, true], "A no-op disable rolls back via enable")
        expect(!control.recoveryPending, "Failed disable can settle restored")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend, now: { clock })
        var errors: [Error] = []
        control.onError = { errors.append($0) }
        control.disable()
        backend.rejectRestore = true
        backend.externalCount = 0
        control.refresh()
        clock.addTimeInterval(6)
        control.refresh()
        clock.addTimeInterval(6)
        control.refresh()
        expect(errors.isEmpty, "Recovery warning must wait until all scheduled retries are exhausted")
        expect(control.recoveryPending && !control.canDisable, "Failed restore keeps durable recovery intent")
        backend.rejectRestore = false
        clock.addTimeInterval(5)
        control.refresh()
        control.refresh()
        clock.addTimeInterval(2)
        control.refresh(readOnly: true)
        expect(!control.recoveryPending, "Watchdog retries eventually restore")
    }
    do {
        let backend = SimulatedDisplay()
        backend.recoveryPending = true
        backend.builtinActive = false
        let control = DisplayController(driver: backend)
        control.refresh()
        control.refresh()
        confirmRecovery(control)
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
        confirmRecovery(control)
        expect(!control.recoveryPending, "Rejected transaction does not leave stale intent")
    }
    do {
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend)
        control.disable()
        backend.builtinActive = true
        control.refresh()
        expect(control.recoveryPending, "One active observation must retain recovery intent")
        confirmRecovery(control)
        expect(!control.recoveryPending, "OS-driven restoration clears manual off state")
        expect(backend.calls == [false], "OS restoration is not fought by re-disabling")
    }
    do {
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend)
        control.disable()
        control.refreshOnReopen()
        expect(backend.calls == [false] && !backend.builtinActive && control.recoveryPending, "Reopening preserves an intentionally disabled panel and recovery intent")
        backend.externalCount = 0
        control.refreshOnReopen()
        expect(backend.calls == [false], "Reopen remains read-only even with no external monitor")
        control.refresh()
        expect(backend.calls == [false, true], "Watchdog retains mandatory unplug recovery after reopening")
        confirmRecovery(control)
        expect(!control.recoveryPending, "Unplug recovery can still finish after a read-only reopen")
    }
    do {
        let backend = SimulatedDisplay()
        backend.externalCount = 2
        let control = DisplayController(driver: backend)
        control.disable()
        control.handleDisplayChange(10, flags: .removeFlag)
        expect(backend.calls == [false], "Removal of one external preserves off state while another remains")
        expect(control.snapshot?.availableExternalIDs == [11], "Remaining external stays available")
        control.handleDisplayChange(11, flags: .removeFlag)
        control.refresh()
        expect(backend.calls == [false, true], "Removal of the last external requests restoration")
    }
    do {
        let backend = SimulatedDisplay()
        backend.builtinActive = false
        let control = DisplayController(driver: backend)
        control.refreshOnReopen()
        expect(backend.calls.isEmpty && !control.recoveryPending, "Reopening an unmarked inactive panel must not infer a disable")
        control.restore()
        expect(backend.calls == [true], "Explicit manual recovery remains available without a saved marker")
        confirmRecovery(control)
        expect(!control.recoveryPending, "Manual recovery of an unmarked panel is confirmed")
        control.refreshOnReopen()
        expect(backend.calls == [true], "Reopening with an active panel does not change display configuration")
    }
    do {
        let suite = "local.ScreenSwitch.checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        expect(settings.language == .chinese, "Fresh installation defaults to Chinese")
        settings.language = .english
        expect(AppSettings(defaults: defaults).language == .english, "English preference survives settings recreation")
        expect(!settings.restoreOnDisplaySleep, "Display-sleep recovery defaults to off")
        settings.restoreOnDisplaySleep = true
        expect(AppSettings(defaults: defaults).restoreOnDisplaySleep, "Optional recovery persists when enabled")
        settings.restoreOnDisplaySleep = false
        expect(!AppSettings(defaults: defaults).restoreOnDisplaySleep, "Optional recovery persists when disabled again")
        defaults.set("unsupported", forKey: "language")
        expect(settings.language == .chinese, "Invalid stored language uses Chinese")
    }
    for enabled in [false, true] {
        for pollFirst in [false, true] {
            let suite = "local.ScreenSwitch.sleepChecks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            settings.restoreOnDisplaySleep = enabled
            let backend = SimulatedDisplay()
            let control = DisplayController(driver: backend, settings: settings)
            control.start()
            defer { control.stop() }
            control.disable()
            if pollFirst {
                backend.externalAsleep = true
                control.refresh()
                expect(
                    backend.calls == (enabled ? [false, true] : [false]),
                    "Polling before screen notification must obey the saved opt-in"
                )
            }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            backend.externalAsleep = true
            control.refresh()
            expect(
                backend.calls == (enabled ? [false, true] : [false]),
                "Actual screen-sleep observer must obey the opt-in for either event order"
            )
            expect(!control.canDisable, "Screen sleep blocks further manual disabling")
            backend.externalAsleep = false
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            control.refresh()
            expect(
                backend.calls == (enabled ? [false, true] : [false]),
                "Screen wake does not re-disable or restore when the option is off"
            )
            if !enabled {
                backend.externalAsleep = true
                control.handleDisplaysSleep()
                backend.externalCount = 0
                control.refresh()
                control.refresh()
                expect(backend.calls == [false, true], "Unplug recovery remains active with the option off and displays asleep")
            }
        }
    }
    do {
        let suite = "local.ScreenSwitch.sleepChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.restoreOnDisplaySleep = true
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend, settings: settings)
        control.handleDisplaysSleep()
        control.handleDisplaysWake()
        expect(backend.calls.isEmpty, "Opt-in does not reconfigure a panel that the app has not disabled")
        control.disable()
        settings.restoreOnDisplaySleep = false
        backend.externalAsleep = true
        control.handleDisplaysSleep()
        expect(backend.calls == [false], "Unchecking the option prevents the next display-sleep restoration")
        control.handleSleep()
        expect(backend.calls == [false, true], "System-sleep recovery is independent of the display-sleep option")
    }
    do {
        let suite = "local.ScreenSwitch.sleepChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.restoreOnDisplaySleep = true
        let backend = SimulatedDisplay()
        backend.delayDisable = true
        let control = DisplayController(driver: backend, settings: settings)
        control.disable()
        control.handleDisplaysSleep()
        control.refresh()
        expect(backend.calls == [false, true], "Opted-in screen sleep cancels a disable still settling")
        confirmRecovery(control)
        expect(!control.recoveryPending, "Settling-disable race finishes safely restored")
        control.handleDisplaysSleep()
        expect(backend.calls == [false, true], "Repeated screen-sleep notifications do not repeat confirmed restoration")
    }
    do {
        let original = AppSettings.shared.language
        defer { AppSettings.shared.language = original }
        let backend = SimulatedDisplay()
        backend.recoveryPending = true
        backend.builtinActive = false
        backend.rejectRestore = true
        let control = DisplayController(driver: backend)
        AppSettings.shared.language = .chinese
        control.refresh()
        expect(control.message.contains("恢复内置屏幕"), "Recovery error is Chinese")
        AppSettings.shared.language = .english
        expect(control.message.contains("Restore built-in display failed"), "Stored errors translate without retrying an operation")
        let failures: [DisplayFailure] = [
            .apiUnavailable, .enumeration(1), .noBuiltin, .noExternal,
            .transaction(.begin, 1), .transaction(.restore, 1),
            .transaction(.disable, 1), .transaction(.commit, 1),
            .notRestored, .recoveryRecord, .callback(1), .disableUnavailable,
            .disableNotApplied, .quitCancelled
        ]
        for error in failures {
            let english = error.localizedDescription
            expect(!english.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "English error must not contain untranslated Chinese")
            AppSettings.shared.language = .chinese
            expect(error.localizedDescription != english, "Every display error has both translations")
            AppSettings.shared.language = .english
        }
    }
    do {
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend)
        control.disable()
        control.handleDisplayChange(10, flags: .removeFlag)
        control.refresh()
        expect(backend.calls == [false, true], "Removal callback overrides stale online display enumeration")
        expect(control.snapshot?.availableExternalIDs.isEmpty == true, "Removed external does not count as available")
        control.handleDisplayChange(10, flags: .addFlag)
        expect(control.snapshot?.availableExternalIDs == [10], "Reconnection clears the removal override")
        expect(backend.calls == [false, true], "Reconnection does not re-disable the panel")
    }
    do {
        let backend = SimulatedDisplay()
        backend.builtinActive = false
        backend.externalCount = 0
        let control = DisplayController(driver: backend)
        control.refresh()
        control.refresh()
        expect(backend.calls.isEmpty && backend.savedRestoreCalls == 0, "No external and inactive internal without a marker must not initiate recovery")
        expect(!control.recoveryPending, "Inactivity alone must not create recovery intent")
    }
    do {
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend)
        control.disable()
        backend.rejectRestore = true
        backend.savedRestoreSucceeds = true
        backend.externalCount = 0
        control.refresh()
        expect(backend.savedRestoreCalls == 1, "Failed enable with no external requests saved configuration recovery")
        expect(control.recoveryPending, "Void fallback is not success until active state is re-read")
        control.refresh()
        confirmRecovery(control)
        expect(!control.recoveryPending && backend.builtinActive, "Fallback success verified through built-in active state")
        control.restore()
        expect(!control.recoveryPending && !control.busy, "Restoring an already active panel does not start another recovery")
    }
    do {
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend)
        control.disable()
        backend.rejectRestore = true
        control.restore()
        expect(backend.savedRestoreCalls == 0, "Failed manual restore while external remains does not reset display layout")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend, now: { clock })
        control.disable()
        backend.rejectRestore = true
        backend.externalCount = 0
        control.refresh()
        expect(control.recoveryPending && backend.savedRestoreCalls == 1, "No-op fallback preserves recovery intent")
        clock.addTimeInterval(1)
        control.refresh()
        expect(backend.savedRestoreCalls == 1, "Saved-configuration fallback is rate limited")
        clock.addTimeInterval(5)
        control.refresh()
        expect(backend.savedRestoreCalls == 2 && control.recoveryPending, "Unconfirmed fallback keeps retrying without false success")
    }
    do {
        let backend = SimulatedDisplay()
        backend.rejectRestore = true
        let control = DisplayController(driver: backend)
        control.restore()
        expect(backend.calls.isEmpty, "Restore on an active panel must not call the private API")
        expect(!control.recoveryPending && !control.busy && control.canDisable, "No-op restore leaves the app usable")
        backend.recoveryPending = true
        control.refresh(readOnly: true)
        expect(backend.recoveryPending, "A marker survives the first active observation")
        confirmRecovery(control)
        expect(!backend.recoveryPending && !control.busy, "Refresh clears a stale recovery marker when the internal panel is active")
        expect(backend.calls.isEmpty, "Clearing stale intent does not require a successful enable transaction")
    }
    do {
        let backend = SimulatedDisplay()
        backend.builtinActive = false
        backend.recoveryPending = true
        backend.rejectRestore = true
        let control = DisplayController(driver: backend)
        var restored = 0
        control.onRestored = { restored += 1 }
        control.refresh()
        expect(control.busy && control.recoveryPending, "Failed genuine restore keeps recovery running")
        let calls = backend.calls
        backend.builtinActive = true
        control.refresh(readOnly: true)
        expect(control.recoveryPending, "OS restoration must be stable before clearing recovery")
        confirmRecovery(control)
        expect(!control.busy && !control.recoveryPending && control.canDisable, "OS-restored active state ends failed recovery and releases controls")
        expect(backend.calls == calls && restored == 1, "Refresh confirms actual recovery without issuing or requiring another transaction")
        control.refresh()
        expect(backend.calls == calls && restored == 1, "Confirmed recovery does not loop")
    }
    do {
        let backend = SimulatedDisplay()
        backend.builtinActive = false
        backend.externalCount = 0
        let control = DisplayController(driver: backend)
        control.refresh(readOnly: true)
        expect(backend.snapshotCalls == 1 && control.snapshot?.builtinActive == false, "Read-only refresh obtains a new snapshot")
        expect(backend.calls.isEmpty && backend.savedRestoreCalls == 0, "Manual refresh must not call either display-configuration API")
        backend.recoveryPending = true
        let recoveryControl = DisplayController(driver: backend)
        recoveryControl.refresh()
        recoveryControl.refresh()
        confirmRecovery(recoveryControl)
        expect(backend.calls == [true] && !recoveryControl.recoveryPending, "A recorded disable still receives mandatory last-display recovery")
    }
    do {
        let backend = SimulatedDisplay()
        backend.builtinActive = false
        backend.recoveryPending = true
        backend.rejectSnapshot = true
        let control = DisplayController(driver: backend)
        control.refresh(readOnly: true)
        expect(control.snapshot == nil && control.recoveryPending, "Failed refresh does not invent display state or clear recovery")
        expect(backend.calls.isEmpty, "Failed read-only enumeration does not initiate transactions")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        backend.delayDisable = true
        backend.rejectRestore = true
        let control = DisplayController(driver: backend, now: { clock })
        control.disable()
        control.refresh(readOnly: true)
        expect(control.busy && control.recoveryPending, "Refresh must not clear a disable that may still settle")
        control.restore()
        expect(backend.calls == [false, true] && control.recoveryPending, "An active but unsettled disable still receives rollback")
        clock.addTimeInterval(1)
        backend.builtinActive = false
        control.refresh(readOnly: true)
        expect(control.recoveryPending, "Late disable after failed rollback is not mistaken for recovery")
        clock.addTimeInterval(3)
        backend.builtinActive = true
        control.refresh(readOnly: true)
        clock.addTimeInterval(2)
        control.refresh(readOnly: true)
        expect(!control.recoveryPending && !control.busy, "Observed active state after the settling deadline clears a failed rollback")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend, now: { clock })
        control.disable()
        backend.builtinActive = true
        control.refresh()
        control.refresh()
        expect(control.recoveryPending, "Repeated reads at the same instant cannot clear a disable record")
        clock.addTimeInterval(1)
        control.refresh()
        expect(control.recoveryPending, "A one-second active transient is not confirmed recovery")
        backend.builtinActive = false
        control.refresh()
        backend.externalCount = 0
        control.refresh()
        expect(backend.calls == [false, true], "Unplug after a transient active state still restores the internal panel")
        control.refresh()
        clock.addTimeInterval(1.9)
        control.refresh()
        expect(control.recoveryPending, "Recovery remains pending below the two-second threshold")
        clock.addTimeInterval(0.1)
        control.refresh()
        expect(!control.recoveryPending, "Stable recovery clears the record at the two-second threshold")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend, now: { clock })
        control.disable()
        backend.recoveryPending = false
        backend.externalCount = 0
        control.refresh()
        expect(backend.calls == [false, true] && control.recoveryPending, "Runtime disable intent preserves unplug safety even if the stored marker disappears")
        control.refresh()
        clock.addTimeInterval(2)
        control.refresh()
        expect(!control.recoveryPending, "Stable recovery also clears the runtime intent")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend, now: { clock })
        control.disable()
        backend.builtinActive = true
        control.refresh()
        clock.addTimeInterval(1)
        control.handleDisplayChange(10, flags: .setModeFlag)
        clock.addTimeInterval(1)
        control.refresh()
        expect(control.recoveryPending, "A reconfiguration callback restarts active-state confirmation")
        clock.addTimeInterval(1)
        control.refresh()
        expect(!control.recoveryPending, "Stable activity after reconfiguration completes recovery")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        backend.recoveryPending = true
        let control = DisplayController(driver: backend, now: { clock })
        control.refresh(readOnly: true)
        clock.addTimeInterval(1)
        backend.rejectSnapshot = true
        control.refresh(readOnly: true)
        backend.rejectSnapshot = false
        control.refresh(readOnly: true)
        clock.addTimeInterval(1)
        control.refresh(readOnly: true)
        expect(control.recoveryPending, "Failed enumeration invalidates an active-state confirmation")
        clock.addTimeInterval(1)
        control.refresh(readOnly: true)
        expect(!control.recoveryPending && backend.calls.isEmpty, "A persisted record can be cleared after stable observation without display transactions")
    }
    for noOpSuccess in [false, true] {
        var clock = Date()
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend, now: { clock })
        var errors: [Error] = []
        control.onError = { errors.append($0) }
        control.disable()
        backend.rejectRestore = !noOpSuccess
        backend.delayRestore = noOpSuccess
        backend.externalCount = 0
        control.refresh()
        expect(backend.calls == [false, true], "Unplug performs one immediate recovery attempt")
        for (index, interval) in [1.0, 3.0, 5.0, 10.0, 15.0].enumerated() {
            clock.addTimeInterval(interval - 0.01)
            control.refresh()
            expect(backend.calls.count == index + 2, "Retry must not occur before its specified interval")
            clock.addTimeInterval(0.01)
            control.refresh()
            expect(backend.calls.count == index + 3, "Retry must occur at each specified interval, even after a success-shaped no-op")
            expect(errors.isEmpty, "A pending retry schedule must not show a premature exhaustion alert")
        }
        expect(backend.calls == [false, true, true, true, true, true, true], "Schedule contains exactly one initial attempt and five retries")
        clock.addTimeInterval(4.99)
        control.refresh()
        expect(errors.isEmpty && control.busy, "Final attempt receives its full five-second confirmation window")
        clock.addTimeInterval(0.01)
        control.refresh()
        expect(errors.count == 1 && !control.busy && control.recoveryPending, "Exhaustion warns once, retains intent and releases the manual restore button")
        let savedCalls = backend.savedRestoreCalls
        clock.addTimeInterval(100)
        control.refresh()
        control.handleSleep()
        control.handleWake()
        control.handleDisplaysSleep()
        control.handleDisplaysWake()
        control.handleDisplayChange(10, flags: .removeFlag)
        control.refreshOnReopen()
        expect(backend.calls.count == 7 && backend.savedRestoreCalls == savedCalls, "Watchdog and automatic notifications cannot restart an exhausted schedule")
        expect(errors.count == 1, "Exhausted watchdog must not repeat warnings")
        backend.rejectRestore = false
        backend.delayRestore = false
        control.restore()
        control.refresh(readOnly: true)
        clock.addTimeInterval(2)
        control.refresh()
        expect(backend.calls.count == 8 && !control.recoveryPending, "Explicit manual restore starts a fresh schedule and can finish recovery")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend, now: { clock })
        control.disable()
        backend.rejectRestore = true
        backend.externalCount = 0
        control.refresh()
        clock.addTimeInterval(0.5)
        control.handleWake()
        control.refreshOnReopen()
        expect(backend.calls.count == 2, "Wake must not bypass the retry deadline")
        clock.addTimeInterval(0.5)
        control.refresh()
        backend.rejectRestore = false
        clock.addTimeInterval(3)
        control.refresh()
        control.refresh()
        clock.addTimeInterval(2)
        control.refresh()
        expect(!control.recoveryPending, "An intermediate retry can be stably confirmed")
        clock.addTimeInterval(100)
        control.refresh()
        expect(backend.calls == [false, true, true, true], "Stable success cancels all remaining retries")
    }
    do {
        var clock = Date()
        let backend = SimulatedDisplay()
        backend.builtinActive = false
        backend.recoveryPending = true
        backend.rejectRestore = true
        backend.rejectSnapshot = true
        let control = DisplayController(driver: backend, now: { clock })
        var errors: [Error] = []
        control.onError = { errors.append($0) }
        control.restore()
        for interval in [1.0, 3.0, 5.0, 10.0, 15.0] {
            clock.addTimeInterval(interval)
            control.refresh()
        }
        clock.addTimeInterval(5)
        control.refresh()
        expect(backend.calls.count == 6 && errors.count == 1, "Enumeration failures obey the same retry limit and final warning")
        expect(!control.busy && control.recoveryPending, "Enumeration failures cannot leave the retry UI busy forever")
        clock.addTimeInterval(100)
        control.refresh()
        expect(backend.calls.count == 6 && errors.count == 1, "Failed enumeration after exhaustion does not restart recovery")
    }
    for optIn in [false, true] {
        for builtinKnown in [false, true] {
            let suite = "local.ScreenSwitch.idleSleepChecks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            settings.restoreOnDisplaySleep = optIn
            let backend = SimulatedDisplay()
            backend.externalCount = 0
            backend.builtinActive = false
            backend.builtinKnown = builtinKnown
            backend.rejectRestore = true
            var clock = Date()
            let control = DisplayController(driver: backend, settings: settings, now: { clock })
            var errors: [Error] = []
            control.onError = { errors.append($0) }
            control.start()
            defer { control.stop() }
            expect(backend.calls.isEmpty && !control.recoveryPending, "Starting during normal sleep must not fabricate a disable record")
            for _ in 0..<3 {
                control.handleDisplaysSleep()
                control.handleSleep()
                clock.addTimeInterval(8 * 60 * 60)
                control.refresh()
                control.handleWake()
                control.handleDisplaysWake()
                control.handleDisplayChange(1, flags: .setModeFlag)
                control.refreshOnReopen()
                control.refresh()
            }
            expect(backend.calls.isEmpty && backend.savedRestoreCalls == 0, "Unmarked sleep, wake, callbacks and reopen must never submit recovery transactions, regardless of opt-in")
            expect(errors.isEmpty && !control.busy && !control.recoveryPending, "Ordinary overnight sleep must not produce recovery alerts or markers")
            backend.builtinKnown = true
            backend.builtinActive = true
            control.refresh()
            expect(backend.calls.isEmpty && !control.canDisable, "Waking without an external monitor stays idle and cannot disable")
            backend.externalCount = 1
            control.refresh()
            expect(control.canDisable && backend.calls.isEmpty, "A later external connection still enables only manual disabling")
        }
    }
    print("PASS: \(count) controller lifecycle checks with simulated displays; no real driver instantiated.")
}
#endif
