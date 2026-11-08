import AppKit
import OSLog
import ScreenSwitchCore

private let displayChanged = Notification.Name("ScreenSwitch.displayChanged")
private let displayCallback: CGDisplayReconfigurationCallBack = { display, flags, _ in
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: displayChanged, object: nil,
            userInfo: ["display": display, "flags": flags.rawValue]
        )
    }
}

@MainActor
final class DisplayController {
    enum Operation {
        case disabling(Date)
        case restoring(Date)
    }

    private let driver: DisplayBackend
    private let now: () -> Date
    private let settings: AppSettings
    private let logger = Logger(subsystem: "local.ScreenSwitch", category: "Display")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var callbackRegistered = false
    private var operation: Operation?
    private var sleeping = false
    private var displaysSleeping = false
    private var recoveryWanted = false
    private var restoreCommandSucceeded = false
    private var restoreFailureAlerted = false
    private var nextRestoreAttempt = Date.distantPast
    private var nextSavedRestoreAttempt = Date.distantPast
    private var savedRestoreRequested = false
    private var disableSettlingUntil: Date?
    private var disableRollbackNeeded = false
    private var removedDisplays: Set<CGDirectDisplayID> = []
    private var lastError: Error?
    private var lastLoggedMessage: String?
    private(set) var snapshot: DisplaySnapshot?
    var message: String { statusMessage() }
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onRestored: (() -> Void)?

    init(driver: DisplayBackend, settings: AppSettings = .shared, now: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.settings = settings
        self.now = now
        recoveryWanted = driver.recoveryPending
    }

    var apiAvailable: Bool { driver.apiAvailable }
    var recoveryPending: Bool { driver.recoveryPending || recoveryWanted }
    var busy: Bool { operation != nil }

    var canDisable: Bool {
        guard let snapshot else { return false }
        return SafetyPolicy(
            apiAvailable: apiAvailable, builtinKnown: snapshot.builtinID != nil,
            builtinActive: snapshot.builtinActive,
            usableExternalCount: snapshot.usableExternalIDs.count,
            availableExternalCount: snapshot.availableExternalIDs.count,
            recoveryPending: recoveryPending, operationPending: busy, sleeping: sleeping,
            displaySleeping: displaysSleeping || snapshot.externalDisplaysAsleep,
            restoreOnDisplaySleep: settings.restoreOnDisplaySleep
        ).canDisable
    }

    func start() {
        let result = CGDisplayRegisterReconfigurationCallback(displayCallback, nil)
        callbackRegistered = result == .success
        if !callbackRegistered {
            report(DisplayFailure.callback(result.rawValue))
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: displayChanged, object: nil, queue: .main) { [weak self] event in
            MainActor.assumeIsolated {
                guard let display = event.userInfo?["display"] as? CGDirectDisplayID,
                      let flags = event.userInfo?["flags"] as? UInt32 else { return }
                self?.handleDisplayChange(display, flags: CGDisplayChangeSummaryFlags(rawValue: flags))
            }
        })
        for name in [NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleSleep()
            }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleWake()
            }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisplaysSleep() }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisplaysWake() }
        })
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
        if !recoveryPending && snapshot?.builtinActive == false { restore() }
    }

    func stop() {
        timer?.invalidate()
        if callbackRegistered { CGDisplayRemoveReconfigurationCallback(displayCallback, nil) }
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func handleSleep() {
        sleeping = true
        if recoveryPending { restore() }
        refresh()
    }

    func handleWake() {
        sleeping = false
        displaysSleeping = false
        // Wake never reapplies a previous disable request.
        if recoveryPending { restore() }
        refresh()
    }

    func handleDisplaysSleep() {
        displaysSleeping = true
        refresh()
    }

    func handleDisplaysWake() {
        displaysSleeping = false
        // A display wake never reapplies a previous disable request.
        refresh()
    }

    func recoverOnReopen() {
        refresh()
        if recoveryPending || snapshot?.builtinActive == false { restore() }
    }

    func handleDisplayChange(_ display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        if flags.contains(.removeFlag) {
            removedDisplays.insert(display)
        }
        if flags.contains(.addFlag) {
            removedDisplays.remove(display)
        }
        refresh()
    }

    func disable() {
        refresh()
        guard canDisable else {
            onError?(DisplayFailure.disableUnavailable)
            return
        }
        do {
            operation = .disabling(now().addingTimeInterval(3))
            disableSettlingUntil = now().addingTimeInterval(3)
            disableRollbackNeeded = true
            try driver.setBuiltinEnabled(false)
            logger.info("Manual disable transaction committed; awaiting active-state verification")
            refresh()
        } catch {
            operation = nil
            recoveryWanted = driver.recoveryPending
            report(error)
            onError?(error)
            if recoveryWanted { restore() }
            refresh()
        }
    }

    func restore() {
        refresh(readOnly: true)
        if snapshot?.builtinID != nil, snapshot?.builtinActive == true, canConfirmActive {
            return
        }
        recoveryWanted = true
        restoreCommandSucceeded = false
        savedRestoreRequested = false
        restoreFailureAlerted = false
        if !driver.markRecoveryPending() { report(DisplayFailure.recoveryRecord) }
        operation = .restoring(now().addingTimeInterval(5))
        nextRestoreAttempt = .distantPast
        attemptRestore()
        refresh()
    }

    private func attemptRestore() {
        guard now() >= nextRestoreAttempt else { return }
        nextRestoreAttempt = now().addingTimeInterval(1)
        defer { disableRollbackNeeded = false }
        do {
            // Re-enable even an apparently active panel if a disable may still settle.
            try driver.setBuiltinEnabled(true)
            restoreCommandSucceeded = true
            logger.info("Restore transaction committed; awaiting active-state verification")
        } catch {
            report(error)
            // Only use the broader public restore as a last-display emergency
            // fallback. It can reset the user's display arrangement.
            if snapshot?.availableExternalIDs.isEmpty == true,
               now() >= nextSavedRestoreAttempt {
                nextSavedRestoreAttempt = now().addingTimeInterval(5)
                savedRestoreRequested = true
                logger.error("Enable transaction failed with no external display; requesting saved display configuration restoration")
                driver.restoreSavedConfiguration()
            }
        }
    }

    private var canConfirmActive: Bool {
        restoreCommandSucceeded || savedRestoreRequested
            || (!disableRollbackNeeded && (disableSettlingUntil.map { now() >= $0 } ?? true))
    }

    private func finishRecovery() {
        driver.markRecovered()
        recoveryWanted = false
        operation = nil
        lastError = nil
        lastLoggedMessage = nil
        restoreCommandSucceeded = false
        savedRestoreRequested = false
        disableSettlingUntil = nil
        disableRollbackNeeded = false
        onRestored?()
    }

    func refresh(readOnly: Bool = false) {
        do {
            let observed = try driver.snapshot()
            // Do not let a stale online list count a display after its removal callback.
            let current = DisplaySnapshot(
                onlineIDs: observed.onlineIDs,
                builtinID: observed.builtinID,
                builtinActive: observed.builtinActive,
                availableExternalIDs: observed.availableExternalIDs.filter { !removedDisplays.contains($0) },
                usableExternalIDs: observed.usableExternalIDs.filter { !removedDisplays.contains($0) },
                externalDisplaysAsleep: observed.externalDisplaysAsleep
            )
            removedDisplays.formIntersection(Set(observed.onlineIDs))
            snapshot = current
            if current.builtinID != nil, current.builtinActive, recoveryPending, canConfirmActive {
                finishRecovery()
            }
            let policy = SafetyPolicy(
                apiAvailable: apiAvailable, builtinKnown: current.builtinID != nil,
                builtinActive: current.builtinActive,
                usableExternalCount: current.usableExternalIDs.count,
                availableExternalCount: current.availableExternalIDs.count,
                recoveryPending: recoveryPending || current.builtinActive == false,
                operationPending: busy, sleeping: sleeping,
                displaySleeping: displaysSleeping || current.externalDisplaysAsleep,
                restoreOnDisplaySleep: settings.restoreOnDisplaySleep
            )
            if !readOnly && policy.mustRestore && !recoveryWanted {
                recoveryWanted = true
                restoreCommandSucceeded = false
                savedRestoreRequested = false
                restoreFailureAlerted = false
                operation = .restoring(now().addingTimeInterval(5))
                if !driver.markRecoveryPending() { report(DisplayFailure.recoveryRecord) }
            }

            if case .disabling(let deadline) = operation {
                if !current.builtinActive, current.builtinID != nil {
                    operation = nil
                    disableSettlingUntil = nil
                    disableRollbackNeeded = false
                } else if !readOnly && now() >= deadline {
                    operation = nil
                    recoveryWanted = true
                    restoreCommandSucceeded = false
                    report(DisplayFailure.disableNotApplied)
                    onError?(DisplayFailure.disableNotApplied)
                }
            }

            if recoveryWanted {
                if current.builtinID != nil, current.builtinActive, canConfirmActive {
                    finishRecovery()
                } else if !readOnly {
                    if operation == nil { operation = .restoring(now().addingTimeInterval(5)) }
                    attemptRestore()
                }
            }

            if case .restoring(let deadline) = operation,
               !readOnly, now() >= deadline, !restoreFailureAlerted {
                restoreFailureAlerted = true
                report(DisplayFailure.notRestored)
                onError?(DisplayFailure.notRestored)
                // Keep retrying, but do not repeatedly present modal alerts.
            }
        } catch {
            snapshot = nil
            report(error)
            // Enumeration failure must not silently leave an intentionally disabled panel.
            if !readOnly && recoveryPending {
                if !recoveryWanted {
                    recoveryWanted = true
                    restoreCommandSucceeded = false
                    restoreFailureAlerted = false
                }
                attemptRestore()
            }
        }
        onChange?()
    }

    private func statusMessage() -> String {
        if snapshot == nil {
            return lastError?.localizedDescription ?? L("正在读取显示器…", "Reading displays…")
        }
        if recoveryWanted {
            return lastError?.localizedDescription ?? L("正在恢复内置屏幕…", "Restoring built-in display…")
        } else if case .disabling = operation {
            return L("正在确认内置屏幕已关闭…", "Confirming built-in display is disabled…")
        } else if recoveryPending {
            if displaysSleeping || snapshot?.externalDisplaysAsleep == true {
                return L("内置屏幕已关闭 · 显示器熄屏中", "Built-in display off · Displays asleep")
            }
            return L("内置屏幕已关闭 · 外屏工作中", "Built-in display off · External display in use")
        } else if !apiAvailable {
            return L("系统接口不可用 · 关屏已禁用", "System API unavailable · Disabling blocked")
        } else if snapshot?.builtinID == nil {
            return L("未识别到内置屏幕", "Built-in display not identified")
        } else if snapshot?.builtinActive == false {
            return L("内置屏幕未启用 · 可尝试恢复", "Built-in display inactive · Try restoring")
        } else if displaysSleeping || snapshot?.externalDisplaysAsleep == true {
            return L("显示器已熄屏 · 等待唤醒", "Displays asleep · Waiting for wake")
        } else if snapshot?.usableExternalIDs.isEmpty != false {
            return L("请先连接并唤醒外接显示器", "Connect and wake an external monitor first")
        } else {
            return L("内置屏幕已开启 · 可以手动关闭", "Built-in display on · Ready for manual disabling")
        }
    }

    private func report(_ error: Error) {
        lastError = error
        let text = error.localizedDescription
        guard text != lastLoggedMessage else { return }
        lastLoggedMessage = text
        logger.error("\(text, privacy: .public)")
    }
}
