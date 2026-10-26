import CoreGraphics
import Darwin
import Foundation
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
    let usableExternalIDs: [CGDirectDisplayID]
}

protocol DisplayBackend: AnyObject {
    var apiAvailable: Bool { get }
    var recoveryPending: Bool { get }
    func snapshot() throws -> DisplaySnapshot
    @discardableResult func markRecoveryPending() -> Bool
    func markRecovered()
    func setBuiltinEnabled(_ enabled: Bool) throws
    func diagnosticText() throws -> String
}

final class DisplayDriver: DisplayBackend {
    private typealias ConfigureEnabled = @convention(c)
        (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32

    private var handles: [UnsafeMutableRawPointer] = []
    private var configureEnabled: ConfigureEnabled?
    private let preferences = UserDefaults(suiteName: "local.ScreenSwitch.recovery")!
    private let pendingKey = "needsRecovery"
    private let builtinKey = "builtinDisplayID"

    var apiAvailable: Bool { configureEnabled != nil }
    var recoveryPending: Bool { preferences.bool(forKey: pendingKey) }

    init() {
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
        var builtin = ids.first { CGDisplayIsBuiltin($0) != 0 }
        // Disabled panels may disappear from the online list. Never trust a
        // remembered ID without checking that CoreGraphics still calls it built-in.
        if builtin == nil,
           let value = preferences.object(forKey: builtinKey) as? NSNumber {
            let remembered = value.uint32Value
            if remembered != kCGNullDirectDisplay, CGDisplayIsBuiltin(remembered) != 0 {
                builtin = remembered
            }
        }
        if let builtin, preferences.object(forKey: builtinKey) as? NSNumber != NSNumber(value: builtin) {
            preferences.set(NSNumber(value: builtin), forKey: builtinKey)
        }
        return DisplaySnapshot(
            onlineIDs: ids,
            builtinID: builtin,
            builtinActive: builtin.map { CGDisplayIsActive($0) != 0 } ?? false,
            usableExternalIDs: ids.filter {
                CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0
                    && CGDisplayIsAsleep($0) == 0
                    && CGDisplayPixelsWide($0) > 0 && CGDisplayPixelsHigh($0) > 0
            }
        )
    }

    @discardableResult
    func markRecoveryPending() -> Bool {
        preferences.set(true, forKey: pendingKey)
        return preferences.synchronize()
    }

    func markRecovered() {
        preferences.removeObject(forKey: pendingKey)
        preferences.synchronize()
    }

    func setBuiltinEnabled(_ enabled: Bool) throws {
        guard let configureEnabled else { throw DisplayFailure.apiUnavailable }
        let before = try snapshot()
        guard let builtin = before.builtinID else { throw DisplayFailure.noBuiltin }
        if !enabled && before.usableExternalIDs.isEmpty { throw DisplayFailure.noExternal }

        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            throw DisplayFailure.transaction(.begin, begin.rawValue)
        }
        var consumed = false
        defer { if !consumed { CGCancelDisplayConfiguration(configuration) } }

        if !enabled {
            // Persist intent before the first mutating API call, including failed
            // transactions whose partial effects cannot be trusted.
            guard markRecoveryPending() else { throw DisplayFailure.recoveryRecord }
        }
        let result = configureEnabled(configuration, builtin, enabled)
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
        let complete = CGCompleteDisplayConfiguration(configuration, .forSession)
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
        \(L("可用外屏 ID", "Usable external display IDs")): \(state.usableExternalIDs)
        \(L("待恢复标记", "Recovery pending")): \(recoveryPending)
        """
    }
}
