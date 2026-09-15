import Carbon
import Foundation

final class InputSourceHelper {
    private static let hitoolboxPreferencesID = "com.apple.HIToolbox" as CFString

    static func allInstalledInputSources(includeAllInstalled: Bool = true) -> [TISInputSource] {
        TISCreateInputSourceList(nil, includeAllInstalled).takeRetainedValue() as! [TISInputSource]
    }

    static func inputSource(for sourceID: String) -> TISInputSource? {
        for source in allInstalledInputSources() {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let value = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
            if String(value) == sourceID { return source }
        }
        return nil
    }

    static func inputMode(for modeID: String) -> TISInputSource? {
        for source in allInstalledInputSources() {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputModeID) else { continue }
            let value = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
            if String(value) == modeID { return source }
        }
        return nil
    }

    static func inputSourceEnabled(for source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { return false }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return value == kCFBooleanTrue
    }

    static func registerInputSource(at url: URL) -> Bool {
        TISRegisterInputSource(url as CFURL) == noErr
    }

    static func enable(inputSource: TISInputSource) -> Bool {
        TISEnableInputSource(inputSource) == noErr
    }

    static func select(inputSource: TISInputSource) -> Bool {
        TISSelectInputSource(inputSource) == noErr
    }

    static func inputSourceSelected(for source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelected) else {
            return false
        }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return value == kCFBooleanTrue
    }

    /// TIS enable/select 可以回傳成功，但在部分 macOS 版本只更新目前程序
    /// 可見的 TIS 狀態，沒有把輸入來源寫入 HIToolbox 的 enabled 清單。
    /// 系統選單實際依賴這份清單；只寫 selected 會產生「看似選取、實際不可用」
    /// 的殘留狀態。因此安裝時保留既有 entries，補齊 parent／mode 的持久狀態。
    @discardableResult
    static func persistHIToolboxInputSources(
        parentID: String,
        modeIDs: [String],
        selectedModeID: String?
    ) -> Bool {
        let enabledKey = "AppleEnabledInputSources" as CFString
        let selectedKey = "AppleSelectedInputSources" as CFString
        let historyKey = "AppleInputSourceHistory" as CFString

        func readEntries(_ key: CFString) -> [[String: Any]] {
            guard let value = CFPreferencesCopyAppValue(key, hitoolboxPreferencesID) as? [[String: Any]] else {
                return []
            }
            return value
        }

        func sourceEntry(bundleID: String, modeID: String?, kind: String) -> [String: Any] {
            var entry: [String: Any] = [
                "Bundle ID": bundleID,
                "InputSourceKind": kind,
            ]
            if let modeID {
                entry["Input Mode"] = modeID
            }
            return entry
        }

        func upsert(
            _ entry: [String: Any],
            into entries: inout [[String: Any]],
            matching bundleID: String,
            modeID: String?
        ) {
            if let index = entries.firstIndex(where: { existing in
                guard existing["Bundle ID"] as? String == bundleID else { return false }
                return (existing["Input Mode"] as? String) == modeID
            }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }

        var enabled = readEntries(enabledKey)
        upsert(
            sourceEntry(bundleID: parentID, modeID: nil, kind: "Keyboard Input Method"),
            into: &enabled,
            matching: parentID,
            modeID: nil
        )
        for modeID in modeIDs {
            upsert(
                sourceEntry(bundleID: parentID, modeID: modeID, kind: "Input Mode"),
                into: &enabled,
                matching: parentID,
                modeID: modeID
            )
        }

        var history = readEntries(historyKey)
        for modeID in modeIDs {
            upsert(
                sourceEntry(bundleID: parentID, modeID: modeID, kind: "Input Mode"),
                into: &history,
                matching: parentID,
                modeID: modeID
            )
        }

        if let selectedModeID {
            let selected = [sourceEntry(bundleID: parentID, modeID: selectedModeID, kind: "Input Mode")]
            CFPreferencesSetAppValue(selectedKey, selected as CFPropertyList, hitoolboxPreferencesID)
        }
        CFPreferencesSetAppValue(enabledKey, enabled as CFPropertyList, hitoolboxPreferencesID)
        CFPreferencesSetAppValue(historyKey, history as CFPropertyList, hitoolboxPreferencesID)
        guard CFPreferencesAppSynchronize(hitoolboxPreferencesID) else { return false }

        let persistedEnabled = readEntries(enabledKey)
        let parentPersisted = persistedEnabled.contains {
            $0["Bundle ID"] as? String == parentID && ($0["Input Mode"] as? String) == nil
        }
        let modesPersisted = modeIDs.allSatisfy { modeID in
            persistedEnabled.contains {
                $0["Bundle ID"] as? String == parentID && ($0["Input Mode"] as? String) == modeID
            }
        }
        return parentPersisted && modesPersisted
    }

    /// 提供卸載與清理時的可逆清理流程，將 UnifyIME 從 HIToolbox 偏好設定中完全清除。
    @discardableResult
    static func unpersistHIToolboxInputSources(parentID: String) -> Bool {
        let enabledKey = "AppleEnabledInputSources" as CFString
        let selectedKey = "AppleSelectedInputSources" as CFString
        let historyKey = "AppleInputSourceHistory" as CFString

        func filterEntries(_ key: CFString) -> [[String: Any]] {
            guard let value = CFPreferencesCopyAppValue(key, hitoolboxPreferencesID) as? [[String: Any]] else {
                return []
            }
            return value.filter { ($0["Bundle ID"] as? String) != parentID }
        }

        let enabled = filterEntries(enabledKey)
        let selected = filterEntries(selectedKey)
        let history = filterEntries(historyKey)

        CFPreferencesSetAppValue(enabledKey, enabled as CFPropertyList, hitoolboxPreferencesID)
        if !selected.isEmpty {
            CFPreferencesSetAppValue(selectedKey, selected as CFPropertyList, hitoolboxPreferencesID)
        }
        CFPreferencesSetAppValue(historyKey, history as CFPropertyList, hitoolboxPreferencesID)
        return CFPreferencesAppSynchronize(hitoolboxPreferencesID)
    }

    static func waitUntilInputSourceEnabled(_ sourceID: String, retries: Int = 20, delay: TimeInterval = 0.25) -> Bool {
        for _ in 0..<max(1, retries) {
            if let source = inputSource(for: sourceID), inputSourceEnabled(for: source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        guard let source = inputSource(for: sourceID) else { return false }
        return inputSourceEnabled(for: source)
    }

    static func waitUntilInputSourceSelected(_ sourceID: String, retries: Int = 20, delay: TimeInterval = 0.25) -> Bool {
        for _ in 0..<max(1, retries) {
            if let source = inputSource(for: sourceID), inputSourceSelected(for: source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        guard let source = inputSource(for: sourceID) else { return false }
        return inputSourceSelected(for: source)
    }

    static func waitUntilInputModeEnabled(_ modeID: String, retries: Int = 20, delay: TimeInterval = 0.25) -> Bool {
        for _ in 0..<max(1, retries) {
            if let source = inputMode(for: modeID), inputSourceEnabled(for: source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        guard let source = inputMode(for: modeID) else { return false }
        return inputSourceEnabled(for: source)
    }

    static func waitUntilInputModeSelected(_ modeID: String, retries: Int = 20, delay: TimeInterval = 0.25) -> Bool {
        for _ in 0..<max(1, retries) {
            if let source = inputMode(for: modeID), inputSourceSelected(for: source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        guard let source = inputMode(for: modeID) else { return false }
        return inputSourceSelected(for: source)
    }
}
