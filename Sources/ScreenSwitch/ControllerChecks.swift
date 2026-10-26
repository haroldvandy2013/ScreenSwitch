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
    var rejectDisable = false
    var externalAsleep = false
    var calls: [Bool] = []

    func snapshot() throws -> DisplaySnapshot {
        DisplaySnapshot(
            onlineIDs: builtinActive ? [1] : [],
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

    func setBuiltinEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if enabled && rejectRestore { throw DisplayFailure.transaction(.restore, 1000) }
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
        var errors: [Error] = []
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
    do {
        let backend = SimulatedDisplay()
        let control = DisplayController(driver: backend)
        control.disable()
        control.recoverOnReopen()
        expect(backend.calls == [false, true], "Reopening the single app restores an intentionally disabled panel")
        expect(!control.recoveryPending, "Reopen restoration clears recovery intent")
    }
    do {
        let backend = SimulatedDisplay()
        backend.builtinActive = false
        let control = DisplayController(driver: backend)
        control.recoverOnReopen()
        expect(backend.calls == [true], "Opening the app can recover even without a saved marker")
        expect(!control.recoveryPending, "Unmarked inactive panel is confirmed restored")
        control.recoverOnReopen()
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
    print("PASS: \(count) controller lifecycle checks with simulated displays; no real driver instantiated.")
}
#endif
