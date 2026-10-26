import AppKit
import OSLog
import ScreenSwitchCore

private let displayChanged = Notification.Name("ScreenSwitch.displayChanged")
private let displayCallback: CGDisplayReconfigurationCallBack = { _, _, _ in
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: displayChanged, object: nil)
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
    private let logger = Logger(subsystem: "local.ScreenSwitch", category: "Display")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var callbackRegistered = false
    private var operation: Operation?
    private var sleeping = false
    private var recoveryWanted = false
    private var restoreCommandSucceeded = false
    private var restoreFailureAlerted = false
    private var nextRestoreAttempt = Date.distantPast
    private var lastError: Error?
    private var lastLoggedMessage: String?
    private(set) var snapshot: DisplaySnapshot?
    var message: String { statusMessage() }
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onRestored: (() -> Void)?

    init(driver: DisplayBackend, now: @escaping () -> Date = Date.init) {
        self.driver = driver
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
            recoveryPending: recoveryPending, operationPending: busy, sleeping: sleeping
        ).canDisable
    }

    func start() {
        let result = CGDisplayRegisterReconfigurationCallback(displayCallback, nil)
        callbackRegistered = result == .success
        if !callbackRegistered {
            report(DisplayFailure.callback(result.rawValue))
        }
        let center = NotificationCenter.default
        for name in [displayChanged, NSApplication.didChangeScreenParametersNotification] {
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
        // Wake never reapplies a previous disable request.
        if recoveryPending { restore() }
        refresh()
    }

    func recoverOnReopen() {
        refresh()
        if recoveryPending || snapshot?.builtinActive == false { restore() }
    }

    func disable() {
        refresh()
        guard canDisable else {
            onError?(DisplayFailure.disableUnavailable)
            return
        }
        do {
            operation = .disabling(now().addingTimeInterval(3))
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
        recoveryWanted = true
        restoreCommandSucceeded = false
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
        do {
            // Always send an enable transaction, even if the panel currently
            // looks active: an earlier disable may still be settling.
            try driver.setBuiltinEnabled(true)
            restoreCommandSucceeded = true
            logger.info("Restore transaction committed; awaiting active-state verification")
        } catch {
            report(error)
        }
    }

    func refresh() {
        do {
            let current = try driver.snapshot()
            snapshot = current
            let policy = SafetyPolicy(
                apiAvailable: apiAvailable, builtinKnown: current.builtinID != nil,
                builtinActive: current.builtinActive,
                usableExternalCount: current.usableExternalIDs.count,
                recoveryPending: recoveryPending, operationPending: busy, sleeping: sleeping
            )
            if policy.mustRestore && !recoveryWanted {
                recoveryWanted = true
                restoreCommandSucceeded = false
                restoreFailureAlerted = false
                operation = .restoring(now().addingTimeInterval(5))
            }

            if case .disabling(let deadline) = operation {
                if !current.builtinActive, current.builtinID != nil {
                    operation = nil
                } else if now() >= deadline {
                    operation = nil
                    recoveryWanted = true
                    restoreCommandSucceeded = false
                    report(DisplayFailure.disableNotApplied)
                    onError?(DisplayFailure.disableNotApplied)
                }
            }

            if recoveryWanted {
                if current.builtinActive && restoreCommandSucceeded {
                    driver.markRecovered()
                    recoveryWanted = false
                    operation = nil
                    lastError = nil
                    lastLoggedMessage = nil
                    onRestored?()
                } else {
                    if operation == nil { operation = .restoring(now().addingTimeInterval(5)) }
                    attemptRestore()
                }
            } else if recoveryPending && current.builtinActive && operation == nil {
                // macOS or another utility restored the panel. Never turn it off again.
                driver.markRecovered()
            }

            if case .restoring(let deadline) = operation,
               now() >= deadline, !restoreFailureAlerted {
                restoreFailureAlerted = true
                report(DisplayFailure.notRestored)
                onError?(DisplayFailure.notRestored)
                // Keep retrying, but do not repeatedly present modal alerts.
            }
        } catch {
            snapshot = nil
            report(error)
            // Enumeration failure must not silently leave an intentionally disabled panel.
            if recoveryPending {
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
            return L("内置屏幕已关闭 · 外屏工作中", "Built-in display off · External display in use")
        } else if !apiAvailable {
            return L("系统接口不可用 · 关屏已禁用", "System API unavailable · Disabling blocked")
        } else if snapshot?.builtinID == nil {
            return L("未识别到内置屏幕", "Built-in display not identified")
        } else if snapshot?.builtinActive == false {
            return L("内置屏幕未启用 · 可尝试恢复", "Built-in display inactive · Try restoring")
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
