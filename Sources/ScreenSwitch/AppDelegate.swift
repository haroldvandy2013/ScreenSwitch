import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let driver = DisplayDriver()
    private lazy var controller = DisplayController(driver: driver)
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var descriptionItem: NSMenuItem!
    private var waitingForQuit = false
    private var quitTimeout: DispatchWorkItem?
    private var alertVisible = false
    private var controlWindow: NSWindow?
    private var windowStatus: NSTextField?
    private var windowToggle: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "内置屏幕开关")
        let menu = NSMenu()
        menu.addItem(withTitle: "ScreenSwitch · 内置屏幕开关", action: nil, keyEquivalent: "")
        descriptionItem = menu.addItem(withTitle: "正在读取显示器…", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: "显示控制窗口", action: #selector(showControlWindow), keyEquivalent: "")
        show.target = self
        toggleItem = menu.addItem(withTitle: "关闭内置屏幕", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        let restore = menu.addItem(withTitle: "恢复内置屏幕", action: #selector(restore), keyEquivalent: "r")
        restore.keyEquivalentModifierMask = [.command, .option]
        restore.target = self
        menu.addItem(.separator())
        let help = menu.addItem(withTitle: "使用与安全说明…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        let diagnostic = menu.addItem(withTitle: "复制只读诊断", action: #selector(copyDiagnostic), keyEquivalent: "")
        diagnostic.target = self
        let quit = menu.addItem(withTitle: "恢复屏幕并退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        controller.onChange = { [weak self] in self?.updateMenu() }
        controller.onError = { [weak self] text in self?.showError(text) }
        controller.onRestored = { [weak self] in self?.finishQuitIfNeeded() }
        controller.start()
        showControlWindow()
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let show = appMenu.addItem(
            withTitle: "显示控制窗口", action: #selector(showControlWindow), keyEquivalent: "0"
        )
        show.target = self
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(
            withTitle: "恢复屏幕并退出 ScreenSwitch", action: #selector(quit), keyEquivalent: "q"
        )
        quit.target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    @objc private func showControlWindow() {
        if controlWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "ScreenSwitch · 内置屏幕开关"
            window.isReleasedWhenClosed = false
            let title = NSTextField(labelWithString: "内置屏幕开关")
            title.font = .boldSystemFont(ofSize: 22)
            let status = NSTextField(wrappingLabelWithString: controller.message)
            status.font = .systemFont(ofSize: 14)
            status.setAccessibilityIdentifier("displayStatus")
            windowStatus = status
            let detail = NSTextField(wrappingLabelWithString:
                "连接并唤醒外接显示器后，才能关闭内置屏幕。\n关闭窗口后仍会运行；点击 Dock 图标可再次打开。"
            )
            detail.textColor = .secondaryLabelColor
            let toggle = NSButton(title: toggleItem.title, target: self, action: #selector(self.toggle))
            toggle.bezelStyle = .rounded
            toggle.controlSize = .large
            toggle.setAccessibilityIdentifier("displayToggle")
            windowToggle = toggle
            let restore = NSButton(title: "恢复内置屏幕", target: self, action: #selector(self.restore))
            restore.bezelStyle = .rounded
            let buttons = NSStackView(views: [toggle, restore])
            buttons.orientation = .horizontal
            buttons.spacing = 12
            let help = NSButton(title: "使用与安全说明", target: self, action: #selector(showHelp))
            help.bezelStyle = .rounded
            let quit = NSButton(title: "恢复屏幕并退出", target: self, action: #selector(self.quit))
            quit.bezelStyle = .rounded
            let footer = NSStackView(views: [help, quit])
            footer.orientation = .horizontal
            footer.spacing = 12
            let stack = NSStackView(views: [title, status, detail, buttons, footer])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false
            if let content = window.contentView {
                content.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                    stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                    stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                    stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
                ])
            }
            window.center()
            controlWindow = window
        }
        updateMenu()
        controlWindow?.deminiaturize(nil)
        if let window = controlWindow,
           !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
        controlWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func updateMenu() {
        descriptionItem.title = controller.message
        let needsRestore = controller.recoveryPending || controller.snapshot?.builtinActive == false
        toggleItem.title = needsRestore ? "恢复内置屏幕" : "关闭内置屏幕"
        toggleItem.state = controller.recoveryPending ? .on : .off
        toggleItem.isEnabled = !controller.busy && (needsRestore ? controller.apiAvailable : controller.canDisable)
        windowStatus?.stringValue = controller.message
        windowToggle?.title = toggleItem.title
        windowToggle?.isEnabled = toggleItem.isEnabled
        statusItem.button?.image = NSImage(
            systemSymbolName: controller.recoveryPending ? "display" : "laptopcomputer",
            accessibilityDescription: controller.message
        )
        statusItem.button?.toolTip = controller.message
    }

    @objc private func toggle() {
        if controller.recoveryPending || controller.snapshot?.builtinActive == false {
            controller.restore()
        } else {
            let alert = NSAlert()
            alert.messageText = "关闭内置屏幕，只在外接显示器上工作？"
            alert.informativeText = """
            这会尝试真正停用内屏桌面输出，不是调暗。键盘和触摸板不作更改。

            此功能使用 Apple 未公开支持的接口，M3 Pro / Max 上的实际关屏与恢复效果需自行确认。请保持笔记本打开，先确保外屏能显示桌面。

            拔掉最后一个可用外屏将触发恢复；若恢复失败，可接回外屏，或重新启动 Mac。
            """
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "关闭内置屏幕")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { controller.disable() }
        }
    }

    @objc private func restore() { controller.restore() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "ScreenSwitch 使用与安全说明"
        alert.informativeText = """
        连接并唤醒外屏后，点击“关闭内置屏幕”。外屏必须正在输出桌面；不建议把 AirPlay、虚拟屏或远程桌面当作唯一外屏。

        拔线、休眠及正常退出时会尝试恢复。外屏重接或唤醒后不会自动关屏。请勿同时使用其他显示器禁用工具。

        如异常黑屏：接回外屏；运行随附的“恢复内置屏幕.app”；尝试合盖再开盖；仍无效请重新启动 Mac。强制退出、崩溃、系统或驱动故障时，自动恢复不能保证。

        不需要管理员权限，不修改 SIP、亮度或全局电源设置。私有接口可用不等于硬件兼容；首次操作前请阅读 README.md。
        """
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func copyDiagnostic() {
        do {
            let text = try driver.diagnosticText()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } catch { showError(error.localizedDescription) }
    }

    private func showError(_ text: String) {
        guard !alertVisible else { return }
        alertVisible = true
        // Present outside display callbacks to avoid nested display transactions.
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "屏幕操作未完成"
            alert.informativeText = text
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            self?.alertVisible = false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingForQuit { return .terminateLater }
        guard controller.recoveryPending else { return .terminateNow }
        waitingForQuit = true
        controller.restore()
        if !controller.recoveryPending {
            waitingForQuit = false
            return .terminateNow
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.waitingForQuit else { return }
            self.waitingForQuit = false
            NSApp.reply(toApplicationShouldTerminate: false)
            self.showError("尚未确认内置屏幕恢复，已取消退出并继续尝试恢复。请接回外屏，必要时重新启动 Mac。")
        }
        quitTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
        return .terminateLater
    }

    private func finishQuitIfNeeded() {
        guard waitingForQuit else { return }
        // reply must happen after applicationShouldTerminate has returned terminateLater.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.waitingForQuit else { return }
            self.quitTimeout?.cancel()
            self.waitingForQuit = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { controller.stop() }

    #if DEBUG
    func checkControlWindow() {
        applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        precondition(controlWindow?.isVisible == true, "Control window must be visible on launch")
        precondition(NSApp.activationPolicy() == .regular, "Dock entry must be present")
        precondition(windowToggle?.title == toggleItem.title, "Window and menu must share the same action state")
        precondition(windowToggle?.isEnabled == toggleItem.isEnabled, "Window must preserve menu safety gating")
        if controller.snapshot?.usableExternalIDs.isEmpty == true {
            precondition(windowToggle?.isEnabled == false, "No external must prevent disabling")
        }
        controlWindow?.close()
        precondition(!applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing window must not stop safety checks")
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        precondition(controlWindow?.isVisible == true, "Dock/Finder reopen must restore the window")
        controller.stop()
        controlWindow?.close()
        print("PASS: control window launch, Dock mode, shared safety state, close and reopen; no disable action invoked.")
    }
    #endif
}
