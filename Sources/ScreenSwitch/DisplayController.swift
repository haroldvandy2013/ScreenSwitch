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
    private var lastLoggedError: String?
    private(set) var snapshot: DisplaySnapshot?
    private(set) var message = "正在读取显示器…"
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
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
            report("无法注册底层显示变化回调（\(result.rawValue)），仍使用系统通知和每秒安全检查。")
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

    func disable() {
        refresh()
        guard canDisable else {
            onError?("当前不能关闭内置屏幕：请确认外接显示器已连接、唤醒且正在显示桌面。")
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
            report(error.localizedDescription)
            onError?(error.localizedDescription)
            if recoveryWanted { restore() }
            refresh()
        }
    }

    func restore() {
        recoveryWanted = true
        restoreCommandSucceeded = false
        restoreFailureAlerted = false
        if !driver.markRecoveryPending() { report(DisplayFailure.recoveryRecord.localizedDescription) }
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
            report(error.localizedDescription)
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
                    let text = "接口返回后内置屏幕仍在输出，关屏未成功。已请求恢复，不会用调暗或黑色窗口代替。"
                    report(text)
                    onError?(text)
                }
            }

            if recoveryWanted {
                if current.builtinActive && restoreCommandSucceeded {
                    driver.markRecovered()
                    recoveryWanted = false
                    operation = nil
                    lastLoggedError = nil
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
                report(DisplayFailure.notRestored.localizedDescription)
                onError?(DisplayFailure.notRestored.localizedDescription)
                // Keep retrying, but do not repeatedly present modal alerts.
            }
            updateMessage()
        } catch {
            snapshot = nil
            message = error.localizedDescription
            report(error.localizedDescription)
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

    private func updateMessage() {
        if recoveryWanted {
            message = lastLoggedError ?? "正在恢复内置屏幕…"
        } else if case .disabling = operation {
            message = "正在确认内置屏幕已关闭…"
        } else if recoveryPending {
            message = "内置屏幕已关闭 · 外屏工作中"
        } else if !apiAvailable {
            message = "系统接口不可用 · 关屏已禁用"
        } else if snapshot?.builtinID == nil {
            message = "未识别到内置屏幕"
        } else if snapshot?.builtinActive == false {
            message = "内置屏幕未启用 · 可尝试恢复"
        } else if snapshot?.usableExternalIDs.isEmpty != false {
            message = "请先连接并唤醒外接显示器"
        } else {
            message = "内置屏幕已开启 · 可以手动关闭"
        }
    }

    private func report(_ text: String) {
        guard text != lastLoggedError else { return }
        lastLoggedError = text
        logger.error("\(text, privacy: .public)")
    }
}
