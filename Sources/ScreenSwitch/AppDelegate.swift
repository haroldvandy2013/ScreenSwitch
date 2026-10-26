import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let driver: DisplayBackend
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
    private var languagePopup: NSPopUpButton?
    private var displaySleepCheckbox: NSButton?
    private var displaySleepMenuItem: NSMenuItem?
    private var localizedWindowText: [() -> Void] = []

    init(driver: DisplayBackend = DisplayDriver()) {
        self.driver = driver
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        installStatusMenu()
        controller.onChange = { [weak self] in self?.updateMenu() }
        controller.onError = { [weak self] error in self?.showError(error) }
        controller.onRestored = { [weak self] in self?.finishQuitIfNeeded() }
        controller.start()
        showControlWindow()
    }

    private func languageMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "语言 / Language", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (index, language) in AppLanguage.allCases.enumerated() {
            let option = menu.addItem(
                withTitle: language == .chinese ? "简体中文" : "English",
                action: #selector(selectMenuLanguage(_:)), keyEquivalent: ""
            )
            option.target = self
            option.tag = index
            option.state = AppSettings.shared.language == language ? .on : .off
        }
        item.submenu = menu
        return item
    }

    private func installStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L("ScreenSwitch · 内置屏幕开关", "ScreenSwitch · Built-in display"), action: nil, keyEquivalent: "")
        descriptionItem = menu.addItem(withTitle: controller.message, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: L("显示控制窗口", "Show control window"), action: #selector(showControlWindow), keyEquivalent: "")
        show.target = self
        toggleItem = menu.addItem(withTitle: L("关闭内置屏幕", "Turn off built-in display"), action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        let restore = menu.addItem(withTitle: L("恢复内置屏幕", "Restore built-in display"), action: #selector(restore), keyEquivalent: "r")
        restore.keyEquivalentModifierMask = [.command, .option]
        restore.target = self
        menu.addItem(.separator())
        displaySleepMenuItem = menu.addItem(
            withTitle: L("熄屏时自动恢复内置屏幕", "Restore built-in display on screen sleep"),
            action: #selector(toggleDisplaySleepRecovery), keyEquivalent: ""
        )
        displaySleepMenuItem?.target = self
        displaySleepMenuItem?.state = AppSettings.shared.restoreOnDisplaySleep ? .on : .off
        menu.addItem(languageMenu())
        let help = menu.addItem(withTitle: L("使用与安全说明…", "Usage and safety…"), action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        let diagnostic = menu.addItem(withTitle: L("复制只读诊断", "Copy read-only diagnostics"), action: #selector(copyDiagnostic), keyEquivalent: "")
        diagnostic.target = self
        let quit = menu.addItem(withTitle: L("恢复屏幕并退出", "Restore and quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let show = appMenu.addItem(
            withTitle: L("显示控制窗口", "Show control window"), action: #selector(showControlWindow), keyEquivalent: "0"
        )
        show.target = self
        appMenu.addItem(languageMenu())
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(
            withTitle: L("恢复屏幕并退出 ScreenSwitch", "Restore and quit ScreenSwitch"), action: #selector(quit), keyEquivalent: "q"
        )
        quit.target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    @objc private func selectMenuLanguage(_ sender: NSMenuItem) {
        setLanguage(AppLanguage.allCases[sender.tag])
    }

    @objc private func selectWindowLanguage(_ sender: NSPopUpButton) {
        setLanguage(AppLanguage.allCases[sender.indexOfSelectedItem])
    }

    @objc private func toggleDisplaySleepRecovery() {
        AppSettings.shared.restoreOnDisplaySleep.toggle()
        updateMenu()
    }

    private func setLanguage(_ language: AppLanguage) {
        AppSettings.shared.language = language
        installApplicationMenu()
        installStatusMenu()
        localizedWindowText.forEach { $0() }
        languagePopup?.selectItem(at: AppLanguage.allCases.firstIndex(of: language)!)
        controlWindow?.title = L("ScreenSwitch · 内置屏幕开关", "ScreenSwitch · Built-in display")
        updateMenu()
    }

    @objc private func showControlWindow() {
        if controlWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = L("ScreenSwitch · 内置屏幕开关", "ScreenSwitch · Built-in display")
            window.isReleasedWhenClosed = false
            let title = NSTextField(labelWithString: "内置屏幕开关")
            localizedWindowText.append { title.stringValue = L("内置屏幕开关", "Built-in display") }
            title.font = .boldSystemFont(ofSize: 22)
            let status = NSTextField(wrappingLabelWithString: controller.message)
            status.font = .systemFont(ofSize: 14)
            status.setAccessibilityIdentifier("displayStatus")
            windowStatus = status
            let detail = NSTextField(wrappingLabelWithString: "")
            localizedWindowText.append {
                detail.stringValue = L(
                    "连接并唤醒外接显示器后，才能关闭内置屏幕。\n异常退出后，重新打开 ScreenSwitch 会优先尝试恢复内屏。",
                    "Connect and wake an external monitor before turning off this display.\nAfter a crash, reopen ScreenSwitch to attempt recovery first."
                )
            }
            detail.textColor = .secondaryLabelColor
            let toggle = NSButton(title: toggleItem.title, target: self, action: #selector(self.toggle))
            toggle.bezelStyle = .rounded
            toggle.controlSize = .large
            toggle.setAccessibilityIdentifier("displayToggle")
            windowToggle = toggle
            let restore = NSButton(title: "恢复内置屏幕", target: self, action: #selector(self.restore))
            localizedWindowText.append { restore.title = L("恢复内置屏幕", "Restore built-in display") }
            restore.bezelStyle = .rounded
            let buttons = NSStackView(views: [toggle, restore])
            buttons.orientation = .horizontal
            buttons.spacing = 12
            let help = NSButton(title: "使用与安全说明", target: self, action: #selector(showHelp))
            localizedWindowText.append { help.title = L("使用与安全说明", "Usage and safety") }
            help.bezelStyle = .rounded
            let quit = NSButton(title: "恢复屏幕并退出", target: self, action: #selector(self.quit))
            localizedWindowText.append { quit.title = L("恢复屏幕并退出", "Restore and quit") }
            quit.bezelStyle = .rounded
            let footer = NSStackView(views: [help, quit])
            footer.orientation = .horizontal
            footer.spacing = 12
            let languageLabel = NSTextField(labelWithString: "语言 / Language")
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ["简体中文", "English"])
            popup.selectItem(at: AppLanguage.allCases.firstIndex(of: AppSettings.shared.language)!)
            popup.target = self
            popup.action = #selector(selectWindowLanguage(_:))
            popup.setAccessibilityIdentifier("languageSelector")
            languagePopup = popup
            let languages = NSStackView(views: [languageLabel, popup])
            languages.orientation = .horizontal
            languages.spacing = 12
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleDisplaySleepRecovery))
            checkbox.setAccessibilityIdentifier("restoreOnDisplaySleep")
            localizedWindowText.append {
                checkbox.title = L("熄屏时自动恢复内置屏幕", "Restore built-in display on screen sleep")
                checkbox.toolTip = L(
                    "默认关闭。勾选后，显示器熄屏时尝试恢复内屏输出；不发送唤醒电脑的命令，唤醒后不再自动关闭内屏。",
                    "Off by default. When checked, display sleep triggers a restoration attempt. No computer-wake command is sent; waking never turns the panel off again."
                )
            }
            displaySleepCheckbox = checkbox
            let stack = NSStackView(views: [title, status, detail, buttons, footer, languages, checkbox])
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
                    stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
                    status.widthAnchor.constraint(equalTo: stack.widthAnchor),
                    detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
                ])
            }
            window.center()
            controlWindow = window
            localizedWindowText.forEach { $0() }
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
        controller.recoverOnReopen()
        showControlWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func updateMenu() {
        descriptionItem.title = controller.message
        let needsRestore = controller.recoveryPending || controller.snapshot?.builtinActive == false
        toggleItem.title = needsRestore
            ? L("恢复内置屏幕", "Restore built-in display")
            : L("关闭内置屏幕", "Turn off built-in display")
        toggleItem.state = controller.recoveryPending ? .on : .off
        toggleItem.isEnabled = !controller.busy && (needsRestore ? controller.apiAvailable : controller.canDisable)
        windowStatus?.stringValue = controller.message
        windowToggle?.title = toggleItem.title
        windowToggle?.isEnabled = toggleItem.isEnabled
        let restoreOnSleep = AppSettings.shared.restoreOnDisplaySleep
        displaySleepCheckbox?.state = restoreOnSleep ? .on : .off
        displaySleepMenuItem?.state = restoreOnSleep ? .on : .off
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
            alert.messageText = L("关闭内置屏幕，只在外接显示器上工作？", "Turn off the built-in display and use only the external monitor?")
            alert.informativeText = L("""
            这会尝试真正停用内屏桌面输出，不是调暗。键盘和触摸板不作更改。

            此功能使用 Apple 未公开支持的接口，M3 Pro / Max 上的实际关屏与恢复效果需自行确认。请保持笔记本打开，先确保外屏能显示桌面。

            拔掉最后一个可用外屏将触发恢复；若恢复失败，可接回外屏，或重新启动 Mac。
            """, """
            This attempts to disable the built-in desktop output, not dim it. Keyboard and trackpad settings are unchanged.

            This uses an unsupported Apple API. Actual disabling and restoration on M3 Pro / Max require hardware verification. Keep the lid open and ensure the external monitor shows a usable desktop.

            Unplugging the last usable external monitor triggers a restoration attempt. If it fails, reconnect the monitor or restart the Mac.
            """)
            alert.addButton(withTitle: L("取消", "Cancel"))
            alert.addButton(withTitle: L("关闭内置屏幕", "Turn off built-in display"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { controller.disable() }
        }
    }

    @objc private func restore() { controller.restore() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = L("ScreenSwitch 使用与安全说明", "ScreenSwitch usage and safety")
        alert.informativeText = L("""
        连接并唤醒外屏后，点击“关闭内置屏幕”。外屏必须正在输出桌面；不建议把 AirPlay、虚拟屏或远程桌面当作唯一外屏。

        拔线、休眠及正常退出时会尝试恢复。外屏重接或唤醒后不会自动关屏。请勿同时使用其他显示器禁用工具。

        “熄屏时自动恢复内置屏幕”默认关闭，只有勾选后才在显示器熄屏时尝试恢复内屏输出。它不重启电脑，也不发送唤醒命令；实际亮屏行为取决于系统。系统休眠、拔线和退出时的安全恢复不受此选项影响。

        如异常黑屏：接回外屏；重新打开 ScreenSwitch（优先尝试恢复），或选择“恢复内置屏幕”；尝试合盖再开盖；仍无效请重新启动 Mac。强制退出、崩溃、系统或驱动故障时，自动恢复不能保证。

        不需要管理员权限，不修改 SIP、亮度或全局电源设置。私有接口可用不等于硬件兼容；首次操作前请阅读 README.md。
        """, """
        Connect and wake an external monitor showing a usable desktop before turning off the built-in display. Do not rely on AirPlay, virtual displays or remote desktops as the only external display.

        Restoration is attempted on unplug, sleep and normal quit. Reconnection or wake never automatically turns the display off. Avoid other display-disabling utilities.

        Restore built-in display on screen sleep is off by default. Enable it to attempt restoration when displays sleep. It does not reboot the Mac or send wake commands; actual screen illumination depends on macOS. System-sleep, unplug and quit recovery remain enabled regardless of this option.

        If the screen goes black: reconnect the monitor; reopen ScreenSwitch to attempt recovery first, or choose Restore built-in display; try closing and reopening the lid; restart the Mac if necessary. Recovery is not guaranteed after crashes, force quit, system or driver failures.

        No administrator access, SIP, brightness or global power changes are needed. A private API being available does not establish hardware compatibility.
        """)
        alert.addButton(withTitle: L("知道了", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func copyDiagnostic() {
        do {
            let text = try driver.diagnosticText()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        guard !alertVisible else { return }
        alertVisible = true
        // Present outside display callbacks to avoid nested display transactions.
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("屏幕操作未完成", "Display operation incomplete")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("知道了", "OK"))
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
            self.showError(DisplayFailure.quitCancelled)
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
        let originalLanguage = AppSettings.shared.language
        let originalRestoreOnSleep = AppSettings.shared.restoreOnDisplaySleep
        defer {
            AppSettings.shared.language = originalLanguage
            AppSettings.shared.restoreOnDisplaySleep = originalRestoreOnSleep
        }
        AppSettings.shared.language = .chinese
        AppSettings.shared.restoreOnDisplaySleep = false
        applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        precondition(controlWindow?.isVisible == true, "Control window must be visible on launch")
        precondition(NSApp.activationPolicy() == .regular, "Dock entry must be present")
        precondition(windowToggle?.title == toggleItem.title, "Window and menu must share the same action state")
        precondition(windowToggle?.isEnabled == toggleItem.isEnabled, "Window must preserve menu safety gating")
        if controller.snapshot?.usableExternalIDs.isEmpty == true {
            precondition(windowToggle?.isEnabled == false, "No external must prevent disabling")
        }
        precondition(windowToggle?.title == "关闭内置屏幕", "Initial UI must be Chinese")
        precondition(displaySleepCheckbox?.state == .off, "Optional restoration must start unchecked")
        precondition(displaySleepMenuItem?.state == .off, "Menu must reflect unchecked preference")
        displaySleepCheckbox?.performClick(nil)
        precondition(AppSettings().restoreOnDisplaySleep, "Checkbox selection must persist")
        precondition(displaySleepMenuItem?.state == .on, "Menu must follow the checkbox")
        toggleDisplaySleepRecovery()
        precondition(displaySleepCheckbox?.state == .off, "Menu toggle must update the checkbox")
        if let backend = driver as? SimulatedDisplay {
            precondition(backend.calls.isEmpty, "Changing the option alone must not alter displays")
        }
        languagePopup?.selectItem(at: 1)
        selectWindowLanguage(languagePopup!)
        precondition(windowToggle?.title == "Turn off built-in display", "Window language selector must translate actions")
        precondition(controlWindow?.title == "ScreenSwitch · Built-in display", "Window title must translate")
        precondition(controller.message == "Connect and wake an external monitor first", "Status must translate immediately")
        precondition(windowToggle?.isEnabled == false, "Switching language must not bypass display safety")
        precondition(toggleItem.title == windowToggle?.title, "Menu and window must use the same language")
        precondition(displaySleepCheckbox?.title == "Restore built-in display on screen sleep", "Option must translate")
        precondition(displaySleepMenuItem?.title == displaySleepCheckbox?.title, "Both option entries must translate")
        controlWindow?.contentView?.layoutSubtreeIfNeeded()
        if let content = controlWindow?.contentView {
            func checkLayout(_ view: NSView) {
                for child in view.subviews {
                    if !(child is NSButton), !(child is NSPopUpButton) {
                        checkLayout(child)
                    }
                    let frame = content.convert(child.bounds, from: child)
                    precondition(frame.maxX <= content.bounds.maxX + 1, "English controls must not overflow the window")
                    precondition(frame.minX >= -1 && frame.minY >= -1, "Controls must stay inside the window")
                }
            }
            checkLayout(content)
        }
        precondition(AppSettings().language == .english, "Language must persist across settings instances")
        let languageItem = NSMenuItem()
        languageItem.tag = 0
        selectMenuLanguage(languageItem)
        precondition(windowToggle?.title == "关闭内置屏幕", "Menu selector must switch back to Chinese")
        precondition(languagePopup?.indexOfSelectedItem == 0, "Window selector must follow menu language")
        if let backend = driver as? SimulatedDisplay {
            backend.externalCount = 1
            controller.refresh()
            precondition(windowToggle?.isEnabled == true, "External monitor enables the manual action")
            controller.disable()
            precondition(windowToggle?.title == "恢复内置屏幕", "Off state must offer restoration")
            languagePopup?.selectItem(at: 1)
            selectWindowLanguage(languagePopup!)
            precondition(windowToggle?.title == "Restore built-in display", "Off-state action translates")
            precondition(windowStatus?.stringValue == "Built-in display off · External display in use", "Off-state status translates")
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
            precondition(backend.calls == [false, true], "Reopening the running single app must restore the panel")
            precondition(windowToggle?.title == "Turn off built-in display", "Restored state reflects in the window")
            precondition(applicationShouldTerminate(NSApp) == .terminateNow, "Confirmed restored panel allows normal quit")
            backend.externalCount = 0
            controller.refresh()
            setLanguage(.chinese)
        }
        controlWindow?.close()
        precondition(!applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing window must not stop safety checks")
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        precondition(controlWindow?.isVisible == true, "Dock/Finder reopen must restore the window")
        controller.stop()
        controlWindow?.close()
        print("PASS: simulated UI launch, Chinese default, live bilingual switching, persistence, shared safety state, close and reopen; no real driver instantiated.")
    }
    #endif
}
