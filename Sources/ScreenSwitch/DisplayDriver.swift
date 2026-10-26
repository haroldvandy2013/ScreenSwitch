import CoreGraphics
import Darwin
import Foundation
import ScreenSwitchCore

enum DisplayFailure: LocalizedError {
    case apiUnavailable
    case enumeration(Int32)
    case noBuiltin
    case noExternal
    case transaction(String, Int32)
    case notRestored
    case recoveryRecord

    var errorDescription: String? {
        switch self {
        case .apiUnavailable:
            return "当前系统未提供 CGSConfigureDisplayEnabled，无法安全控制内置屏幕。"
        case .enumeration(let code):
            return "无法读取显示器列表（CoreGraphics \(code)）。"
        case .noBuiltin:
            return "无法识别内置屏幕。请打开笔记本屏幕，或重新启动 macOS 后重试。"
        case .noExternal:
            return "没有处于活动状态的外接显示器，已拒绝关闭内置屏幕。"
        case .transaction(let step, let code):
            return "\(step)失败（CoreGraphics \(code)）。私有接口可能不兼容此系统。"
        case .notRestored:
            return "尚未确认内置屏幕恢复。请重新接入外屏并使用“恢复内置屏幕”；必要时重新启动 Mac。"
        case .recoveryRecord:
            return "无法保存恢复记录，已拒绝关闭内置屏幕。请检查当前用户的偏好设置目录是否可写。"
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
            throw DisplayFailure.transaction("开始显示配置", begin.rawValue)
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
            throw DisplayFailure.transaction(enabled ? "恢复内置屏幕" : "关闭内置屏幕", result)
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
            throw DisplayFailure.transaction("提交显示配置", complete.rawValue)
        }
    }

    func diagnosticText() throws -> String {
        let state = try snapshot()
        return """
        ScreenSwitch 只读诊断（不会调用显示配置接口）
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        CGSConfigureDisplayEnabled: \(apiAvailable ? "可解析；不代表硬件操作已验证" : "不可用")
        在线显示器 ID: \(state.onlineIDs)
        内置屏幕 ID: \(state.builtinID.map(String.init) ?? "未识别")
        内置屏幕活动: \(state.builtinActive)
        可用外屏 ID: \(state.usableExternalIDs)
        待恢复标记: \(recoveryPending)
        """
    }
}
