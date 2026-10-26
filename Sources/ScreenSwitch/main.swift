import AppKit
import Darwin

let arguments = Set(CommandLine.arguments.dropFirst())
var allowed: Set<String> = ["--diagnose", "--restore"]
#if DEBUG
allowed.insert("--check-controller")
allowed.insert("--check-ui")
#endif
if !arguments.isSubset(of: allowed) || arguments.count > 1 {
    fputs("用法：ScreenSwitch [--diagnose | --restore]\n没有命令行关屏选项；请在菜单栏手动操作。\n", stderr)
    exit(2)
}

#if DEBUG
if arguments.contains("--check-controller") {
    MainActor.assumeIsolated { runControllerChecks() }
    exit(0)
}
if arguments.contains("--check-ui") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        delegate.checkControlWindow()
    }
    exit(0)
}
#endif

if arguments.contains("--diagnose") {
    do {
        print(try DisplayDriver().diagnosticText())
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--restore") || Bundle.main.bundleIdentifier == "local.ScreenSwitch.restore" {
    let driver = DisplayDriver()
    var restoreError: Error = DisplayFailure.notRestored
    if !driver.markRecoveryPending() {
        fputs("无法保存恢复记录；仍将尝试开启内置屏幕。\n", stderr)
    }
    for _ in 0..<5 {
        do {
            try driver.setBuiltinEnabled(true)
            Thread.sleep(forTimeInterval: 1)
            if try driver.snapshot().builtinActive {
                driver.markRecovered()
                print("内置屏幕已恢复。")
                exit(0)
            }
            restoreError = DisplayFailure.notRestored
        } catch {
            restoreError = error
            fputs("恢复重试：\(error.localizedDescription)\n", stderr)
            Thread.sleep(forTimeInterval: 1)
        }
    }
    fputs("\(restoreError.localizedDescription)\n", stderr)
    if !arguments.contains("--restore") {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法确认内置屏幕恢复"
        alert.informativeText = restoreError.localizedDescription
        alert.runModal()
    }
    exit(1)
}

let app = NSApplication.shared
if let identifier = Bundle.main.bundleIdentifier,
   let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    existing.activate(options: [.activateAllWindows])
    exit(0)
}
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
