import AppKit
import Darwin

let arguments = Set(CommandLine.arguments.dropFirst())
var allowed: Set<String> = ["--diagnose", "--restore", "--version"]
#if DEBUG
allowed.insert("--check-controller")
allowed.insert("--check-ui")
#endif
if !arguments.isSubset(of: allowed) || arguments.count > 1 {
    fputs(L("用法：ScreenSwitch [--diagnose | --restore | --version]\n没有命令行关屏选项；请在窗口或菜单栏手动操作。\n",
            "Usage: ScreenSwitch [--diagnose | --restore | --version]\nNo command-line disable option. Use the window or menu bar manually.\n"), stderr)
    exit(2)
}

if arguments.contains("--version") {
    print("ScreenSwitch · \(AppVersion.label())")
    exit(0)
}

#if DEBUG
let checkSuite = "local.ScreenSwitch.checks.runtime.\(UUID().uuidString)"
if arguments.contains("--check-controller") || arguments.contains("--check-ui") {
    AppSettings.checkDefaults = UserDefaults(suiteName: checkSuite)!
}
if arguments.contains("--check-controller") {
    MainActor.assumeIsolated { runControllerChecks() }
    AppSettings.checkDefaults?.removePersistentDomain(forName: checkSuite)
    exit(0)
}
if arguments.contains("--check-ui") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let backend = SimulatedDisplay()
        backend.externalCount = 0
        let delegate = AppDelegate(driver: backend)
        delegate.checkControlWindow()
    }
    AppSettings.checkDefaults?.removePersistentDomain(forName: checkSuite)
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

if arguments.contains("--restore") {
    MainActor.assumeIsolated {
        let controller = DisplayController(driver: DisplayDriver())
        controller.onError = { error in
            fputs("\(error.localizedDescription)\n", stderr)
        }
        controller.restore()
        for _ in 0..<Int(DisplayController.recoveryTimeout) {
            Thread.sleep(forTimeInterval: 1)
            controller.refresh()
            if !controller.recoveryPending && controller.snapshot?.builtinActive == true {
                print(L("内置屏幕已恢复。", "Built-in display restored."))
                exit(0)
            }
        }
        fputs("\(controller.message)\n", stderr)
        exit(1)
    }
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
