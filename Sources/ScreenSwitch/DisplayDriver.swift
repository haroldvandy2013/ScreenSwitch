import CoreGraphics
import Darwin
import Foundation
import OSLog
import ScreenSwitchCore

enum DisplayStep {
    case begin, restore, disable, commit

    var title: String {
        switch self {
        case .begin: return L("开始显示配置", "Begin display configuration")
        case .restore: return L("恢复内置屏幕", "Restore built-in display")
        case .disable: return L("关闭内置屏幕", "Disable built-in display")
        case .commit: return L("提交显示配置", "Commit display configuration")
        }
    }
}

enum DisplayFailure: LocalizedError {
    case apiUnavailable
    case enumeration(Int32)
    case invalidDisplayState(CGDirectDisplayID)
    case noBuiltin
    case noExternal
    case transaction(DisplayStep, Int32)
    case notRestored
    case recoveryRecord
    case callback(Int32)
    case disableUnavailable
    case disableNotApplied
    case quitCancelled

    var errorDescription: String? {
        switch self {
        case .apiUnavailable:
            return L("当前系统未提供 CGSConfigureDisplayEnabled，无法安全控制内置屏幕。",
                     "CGSConfigureDisplayEnabled is unavailable. Built-in display control is disabled.")
        case .enumeration(let code):
            return L("无法读取显示器列表（CoreGraphics \(code)）。",
                     "Cannot read the display list (CoreGraphics \(code)).")
        case .invalidDisplayState(let id):
            return L("显示器 \(id) 的系统状态无效，不能确认内屏已恢复，也不会向无效显示器提交配置。",
                     "Display \(id) returned invalid state. Restoration is not confirmed, and no configuration will be submitted to an invalid display.")
        case .noBuiltin:
            return L("无法识别内置屏幕。请打开笔记本屏幕，或重新启动 macOS 后重试。",
                     "Cannot identify the built-in display. Open the lid or restart macOS and try again.")
        case .noExternal:
            return L("没有处于活动状态的外接显示器，已拒绝关闭内置屏幕。",
                     "No active external display. The built-in display will not be disabled.")
        case .transaction(let step, let code):
            return L("\(step.title)失败（CoreGraphics \(code)）。私有接口可能不兼容此系统。",
                     "\(step.title) failed (CoreGraphics \(code)). The private API may be incompatible with this system.")
        case .notRestored:
            return L("尚未确认内置屏幕恢复。请重新接入外屏并使用“恢复内置屏幕”；必要时重新启动 Mac。",
                     "Restoration is not confirmed. Reconnect the external monitor and choose Restore built-in display. Restart the Mac if necessary.")
        case .recoveryRecord:
            return L("无法保存恢复记录，已拒绝关闭内置屏幕。请检查当前用户的偏好设置目录是否可写。",
                     "Cannot save recovery state. Disabling is blocked. Check that your user preferences directory is writable.")
        case .callback(let code):
            return L("无法注册底层显示变化回调（\(code)），仍使用系统通知和每秒安全检查。",
                     "Cannot register the display callback (\(code)). System notifications and one-second safety checks remain active.")
        case .disableUnavailable:
            return L("当前不能关闭内置屏幕：请确认外接显示器已连接、唤醒且正在显示桌面。",
                     "Cannot disable the built-in display now. Connect and wake an external monitor displaying a usable desktop.")
        case .disableNotApplied:
            return L("接口返回后内置屏幕仍在输出，关屏未成功。已请求恢复，不会用调暗或黑色窗口代替。",
                     "The built-in display is still active. Disabling failed and restoration was requested. Dimming or black windows are not used as substitutes.")
        case .quitCancelled:
            return L("尚未确认内置屏幕恢复，已取消退出并继续尝试恢复。请接回外屏，必要时重新启动 Mac。",
                     "Restoration is not confirmed. Quit was cancelled and recovery retries continue. Reconnect the external monitor or restart the Mac if necessary.")
        }
    }
}

struct DisplaySnapshot {
    let onlineIDs: [CGDirectDisplayID]
    let builtinID: CGDirectDisplayID?
    let builtinActive: Bool
    let builtinAsleep: Bool
    // Sleeping panels remain available for unplug safety, but cannot authorize disabling.
    let availableExternalIDs: [CGDirectDisplayID]
    let usableExternalIDs: [CGDirectDisplayID]
    let externalDisplaysAsleep: Bool
    let ignoredVirtualIDs: [CGDirectDisplayID]
}

struct DisplayReading {
    let id: CGDirectDisplayID
    let builtin: Int32
    let active: Int32
    let online: Int32
    let asleep: Int32
    let vendor: UInt32
    let model: UInt32
    let width: Int
    let height: Int

    var flagsValid: Bool {
        [builtin, active, online, asleep].allSatisfy { $0 == 0 || $0 == 1 }
    }

    var identityValid: Bool {
        vendor != UInt32.max && model != UInt32.max && width > 0 && height > 0
    }

    var knownVirtual: Bool {
        // macOS's fallback virtual display identifies itself as "unkn"/"virt".
        vendor == 0x756e6b6e && model == 0x76697274
    }

    func permitsConfiguration(enabled: Bool, listedOnline: Bool, historicalRecoveryTarget: Bool) -> Bool {
        if flagsValid && identityValid {
            return builtin == 1 && !knownVirtual
        }
        // A disabled internal panel can disappear from CoreGraphics after unplug.
        // Only enabling a recorded offline target may bypass failed queries.
        return enabled && historicalRecoveryTarget && !listedOnline && !knownVirtual
            && builtin != 0
    }

    var description: String {
        "id=\(id) builtin=\(builtin) active=\(active) online=\(online) asleep=\(asleep) vendor=\(String(vendor, radix: 16)) model=\(String(model, radix: 16)) size=\(width)x\(height) valid=\(flagsValid && identityValid) virtual=\(knownVirtual)"
    }
}

extension DisplaySnapshot {
    init(onlineIDs: [CGDirectDisplayID], activeIDs: [CGDirectDisplayID], readings: [DisplayReading],
         verifiedBuiltin: CGDirectDisplayID?, rememberedBuiltin: CGDirectDisplayID?, recoveryAuthorized: Bool) {
        self.onlineIDs = onlineIDs
        let online = Set(onlineIDs)
        let active = Set(activeIDs)
        let identifiedBuiltin = readings.first {
            online.contains($0.id) && $0.builtin == 1 && $0.identityValid
        }?.id
        let cached = verifiedBuiltin ?? rememberedBuiltin
        let cachedReading = readings.first { $0.id == cached }
        let cachedIdentityConfirmed = cachedReading.map { $0.builtin == 1 && $0.identityValid } ?? false
        // A historical target may be used for recovery, never as proof of activity.
        // Reject an ID reused by an online non-built-in display.
        let canUseCached: Bool
        if let cached {
            canUseCached = cachedIdentityConfirmed
                || (!online.contains(cached) && (verifiedBuiltin != nil || recoveryAuthorized))
        } else {
            canUseCached = false
        }
        let target = identifiedBuiltin ?? (canUseCached ? cached : nil)
        builtinID = target
        let internalReading = readings.first { $0.id == target }
        builtinActive = internalReading.map {
            online.contains($0.id) && active.contains($0.id)
                && $0.flagsValid && $0.identityValid && $0.builtin == 1
                && $0.online == 1 && $0.active == 1
        } ?? false
        builtinAsleep = internalReading?.asleep == 1
        let external = readings.filter {
            online.contains($0.id) && $0.builtin == 0 && $0.online == 1
                && $0.flagsValid && $0.identityValid && !$0.knownVirtual
        }
        let available = external.filter {
            ($0.active == 1 && active.contains($0.id)) || $0.asleep == 1
        }
        availableExternalIDs = available.map(\.id)
        usableExternalIDs = external.filter {
            $0.active == 1 && active.contains($0.id) && $0.asleep == 0
        }.map(\.id)
        externalDisplaysAsleep = !available.isEmpty && available.allSatisfy { $0.asleep == 1 }
        ignoredVirtualIDs = readings.filter { online.contains($0.id) && $0.knownVirtual }.map(\.id)
    }
}

protocol DisplayBackend: AnyObject {
    var apiAvailable: Bool { get }
    var recoveryPending: Bool { get }
    var disableGuard: Bool { get }
    @discardableResult func setDisableGuard(_ enabled: Bool) -> Bool
    func snapshot() throws -> DisplaySnapshot
    @discardableResult func markRecoveryPending() -> Bool
    func markRecovered()
    func setBuiltinEnabled(_ enabled: Bool) throws
    func diagnosticText() throws -> String
    func restoreSavedConfiguration()
}

final class DisplayDriver: DisplayBackend {
    private let logger = Logger(subsystem: "local.ScreenSwitch", category: "Driver")
    private typealias ConfigureEnabled = @convention(c)
        (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32

    private var handles: [UnsafeMutableRawPointer] = []
    private var configureEnabled: ConfigureEnabled?
    private let preferences = UserDefaults(suiteName: "local.ScreenSwitch.recovery")!
    private let pendingKey = "needsRecovery"
    private let builtinKey = "builtinDisplayID"
    private let guardKey = "manualDisableGuard"
    private var verifiedBuiltin: CGDirectDisplayID?
    private var lastReadings: [DisplayReading] = []
    private var lastRawState: String?
    private var lastHardwareTopology: String?
    private let hardwareDiagnosticsEnabled: Bool

    var apiAvailable: Bool { configureEnabled != nil }
    var recoveryPending: Bool { preferences.bool(forKey: pendingKey) }
    var disableGuard: Bool { preferences.bool(forKey: guardKey) }

    @discardableResult
    func setDisableGuard(_ enabled: Bool) -> Bool {
        preferences.set(enabled, forKey: guardKey)
        let saved = preferences.synchronize()
        DiagnosticLog.shared.write("disable_guard set=\(enabled) persisted=\(saved)")
        return saved
    }

    init(hardwareDiagnosticsEnabled: Bool = true) {
        self.hardwareDiagnosticsEnabled = hardwareDiagnosticsEnabled
        let paths: [String?] = [
            nil,
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            handles.append(handle)
            if let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") {
                configureEnabled = unsafeBitCast(symbol, to: ConfigureEnabled.self)
                break
            }
        }
    }

    deinit {
        for handle in handles.reversed() { dlclose(handle) }
    }

    func snapshot() throws -> DisplaySnapshot {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        let result = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        guard result == .success else { throw DisplayFailure.enumeration(result.rawValue) }
        ids = Array(ids.prefix(Int(count)))
        var activeIDs = [CGDirectDisplayID](repeating: 0, count: 64)
        var activeCount: UInt32 = 0
        let activeResult = CGGetActiveDisplayList(UInt32(activeIDs.count), &activeIDs, &activeCount)
        guard activeResult == .success else { throw DisplayFailure.enumeration(activeResult.rawValue) }
        activeIDs = Array(activeIDs.prefix(Int(activeCount)))
        let remembered = (preferences.object(forKey: builtinKey) as? NSNumber)
            .map { $0.uint32Value }.flatMap { $0 == kCGNullDirectDisplay ? nil : $0 }
        let queriedIDs = Set(ids + activeIDs + [verifiedBuiltin, remembered].compactMap { $0 }).sorted()
        lastReadings = queriedIDs.map { id in
            DisplayReading(
                id: id, builtin: CGDisplayIsBuiltin(id), active: CGDisplayIsActive(id),
                online: CGDisplayIsOnline(id), asleep: CGDisplayIsAsleep(id),
                vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)
            )
        }
        let rawState = "online=\(ids.sorted()) active=\(activeIDs.sorted()) readings=[\(lastReadings.map(\.description).joined(separator: "; "))]"
        let hardwareTopology = "online=\(ids.sorted()) active=\(activeIDs.sorted())"
        let invalidQuery = lastReadings.contains { !$0.flagsValid || !$0.identityValid }
        if hardwareDiagnosticsEnabled,
           hardwareTopology != lastHardwareTopology || (invalidQuery && (recoveryPending || disableGuard)) {
            let accepted = DisplayHardwareDiagnostics.shared.request(
                reason: hardwareTopology != lastHardwareTopology ? "topology_changed_or_initial" : "invalid_query_during_recovery",
                context: "\(rawState) verifiedBuiltin=\(verifiedBuiltin.map(String.init) ?? "none") rememberedBuiltin=\(remembered.map(String.init) ?? "none") record=\(recoveryPending) guard=\(disableGuard)"
            )
            if accepted { lastHardwareTopology = hardwareTopology }
        }
        if rawState != lastRawState {
            DiagnosticLog.shared.write("raw_display_state \(rawState)")
            logger.notice("Raw display state: \(rawState, privacy: .public)")
            if invalidQuery {
                logger.warning("Invalid display queries cannot confirm recovery; retaining historical targets only for recovery")
                DiagnosticLog.shared.write("WARNING invalid_display_query; recovery cannot be confirmed from invalid values")
            }
            lastRawState = rawState
        }
        let state = DisplaySnapshot(
            onlineIDs: ids, activeIDs: activeIDs, readings: lastReadings,
            verifiedBuiltin: verifiedBuiltin, rememberedBuiltin: remembered,
            recoveryAuthorized: recoveryPending || disableGuard
        )
        if let builtin = state.builtinID, let reading = lastReadings.first(where: { $0.id == builtin }),
           reading.builtin == 1, reading.identityValid {
            verifiedBuiltin = builtin
            if preferences.object(forKey: builtinKey) as? NSNumber != NSNumber(value: builtin) {
                preferences.set(NSNumber(value: builtin), forKey: builtinKey)
            }
        }
        return state
    }

    func restoreSavedConfiguration() {
        DiagnosticLog.shared.write("saved_configuration_restore begin")
        CGRestorePermanentDisplayConfiguration()
        DiagnosticLog.shared.write("saved_configuration_restore returned")
    }

    @discardableResult
    func markRecoveryPending() -> Bool {
        preferences.set(true, forKey: pendingKey)
        let saved = preferences.synchronize()
        logger.notice("Recovery record set; persisted=\(saved)")
        DiagnosticLog.shared.write("recovery_record set=true persisted=\(saved)")
        return saved
    }

    func markRecovered() {
        preferences.removeObject(forKey: pendingKey)
        let saved = preferences.synchronize()
        logger.notice("Recovery record cleared; persisted=\(saved)")
        DiagnosticLog.shared.write("recovery_record set=false persisted=\(saved)")
        if !saved { logger.error("Could not persist recovery record removal") }
    }

    func setBuiltinEnabled(_ enabled: Bool) throws {
        guard let configureEnabled else { throw DisplayFailure.apiUnavailable }
        let before = try snapshot()
        guard let builtin = before.builtinID else { throw DisplayFailure.noBuiltin }
        let remembered = (preferences.object(forKey: builtinKey) as? NSNumber)?.uint32Value
        let historicalRecoveryTarget = (recoveryPending || disableGuard)
            && (verifiedBuiltin == builtin || remembered == builtin)
        guard let reading = lastReadings.first(where: { $0.id == builtin }),
              reading.permitsConfiguration(
                enabled: enabled, listedOnline: before.onlineIDs.contains(builtin),
                historicalRecoveryTarget: historicalRecoveryTarget
              ) else {
            throw DisplayFailure.invalidDisplayState(builtin)
        }
        if !reading.flagsValid || !reading.identityValid {
            DiagnosticLog.shared.write("offline_internal_restore authorized=true builtin=\(builtin) verified=\(verifiedBuiltin == builtin) remembered=\(remembered == builtin) record=\(recoveryPending) guard=\(disableGuard) raw=[\(reading.description)]; enabling only, success still requires stable online/active confirmation")
        }
        logger.notice("Display transaction requested: enabled=\(enabled), builtin=\(builtin), active=\(before.builtinActive), external=\(String(describing: before.availableExternalIDs), privacy: .public), recoveryRecord=\(self.recoveryPending)")
        DiagnosticLog.shared.write("transaction begin enabled=\(enabled) builtin=\(builtin) active=\(before.builtinActive) external=\(before.availableExternalIDs) record=\(recoveryPending)")
        if !enabled {
            guard before.builtinActive else { throw DisplayFailure.disableUnavailable }
            guard !before.usableExternalIDs.isEmpty else { throw DisplayFailure.noExternal }
        }

        var configuration: CGDisplayConfigRef?
        DiagnosticLog.shared.write("transaction CGBegin call")
        let begin = CGBeginDisplayConfiguration(&configuration)
        logger.notice("Begin display configuration: result=\(begin.rawValue)")
        DiagnosticLog.shared.write("transaction CGBegin result=\(begin.rawValue)")
        guard begin == .success, let configuration else {
            throw DisplayFailure.transaction(.begin, begin.rawValue)
        }
        var consumed = false
        defer {
            if !consumed {
                DiagnosticLog.shared.write("transaction CGCancel call")
                let cancelled = CGCancelDisplayConfiguration(configuration)
                DiagnosticLog.shared.write("transaction CGCancel returned result=\(cancelled.rawValue)")
            }
        }

        if !enabled {
            // Persist intent before the first mutating API call, including failed
            // transactions whose partial effects cannot be trusted.
            guard setDisableGuard(true), markRecoveryPending() else { throw DisplayFailure.recoveryRecord }
        }
        DiagnosticLog.shared.write("transaction configure call enabled=\(enabled)")
        let result = configureEnabled(configuration, builtin, enabled)
        DiagnosticLog.shared.write("transaction configure returned result=\(result)")
        logger.notice("Configure builtin enabled=\(enabled): result=\(result)")
        guard result == CGError.success.rawValue else {
            throw DisplayFailure.transaction(
                enabled ? .restore : .disable,
                result
            )
        }
        if !enabled {
            let latest = try snapshot()
            guard latest.builtinID == builtin, !latest.usableExternalIDs.isEmpty else {
                throw DisplayFailure.noExternal
            }
        }
        consumed = true
        DiagnosticLog.shared.write("transaction CGComplete call enabled=\(enabled)")
        let complete = CGCompleteDisplayConfiguration(configuration, .forSession)
        DiagnosticLog.shared.write("transaction CGComplete returned result=\(complete.rawValue)")
        logger.notice("Complete display configuration enabled=\(enabled): result=\(complete.rawValue)")
        guard complete == .success else {
            throw DisplayFailure.transaction(.commit, complete.rawValue)
        }
    }

    func diagnosticText() throws -> String {
        let state = try snapshot()
        return """
        \(L("ScreenSwitch 只读诊断（不会调用显示配置接口）", "ScreenSwitch read-only diagnostics (no display transactions)"))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        CGSConfigureDisplayEnabled: \(apiAvailable ? L("可解析；不代表硬件操作已验证", "available; hardware operation not verified") : L("不可用", "unavailable"))
        \(L("在线显示器 ID", "Online display IDs")): \(state.onlineIDs)
        \(L("内置屏幕 ID", "Built-in display ID")): \(state.builtinID.map(String.init) ?? L("未识别", "unknown"))
        \(L("内置屏幕活动", "Built-in display active")): \(state.builtinActive)
        \(L("内置屏幕熄屏", "Built-in display asleep")): \(state.builtinAsleep)
        \(L("可用外屏 ID（排除已知虚拟屏）", "Available external display IDs (known virtual excluded)")): \(state.availableExternalIDs)
        \(L("可用外屏 ID", "Usable external display IDs")): \(state.usableExternalIDs)
        \(L("已忽略虚拟屏 ID", "Ignored virtual display IDs")): \(state.ignoredVirtualIDs)
        \(L("外屏均已熄屏", "All external displays asleep")): \(state.externalDisplaysAsleep)
        \(L("熄屏时自动恢复", "Restore on display sleep")): \(AppSettings.shared.restoreOnDisplaySleep)
        \(L("待恢复标记", "Recovery pending")): \(recoveryPending)
        \(L("关屏保护标记", "Manual-disable guard")): \(disableGuard)
        \(L("本地日志目录", "Local log directory")): \(DiagnosticLog.directory.path)
        \(L("原始显示状态", "Raw display state")): \(lastRawState ?? "unknown")
        """
    }
}
