import Carbon
import Foundation

struct InputSourceHelper {
    private static let hitoolboxPreferencesID = "com.apple.HIToolbox" as CFString

    static func inputSource(for bundleID: String) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        for source in list {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { continue }
            let value = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
            if String(value) == bundleID { return source }
        }
        return nil
    }

    static func inputMode(for modeID: String) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        for source in list {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
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
            if let modeID = modeID {
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
        // 核心修正：只寫入具體的 Input Mode，絕不寫入 Parent (Keyboard Input Method)！
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

        if let selectedModeID = selectedModeID {
            let selected = [sourceEntry(bundleID: parentID, modeID: selectedModeID, kind: "Input Mode")]
            CFPreferencesSetAppValue(selectedKey, selected as CFPropertyList, hitoolboxPreferencesID)
        }
        CFPreferencesSetAppValue(enabledKey, enabled as CFPropertyList, hitoolboxPreferencesID)
        CFPreferencesSetAppValue(historyKey, history as CFPropertyList, hitoolboxPreferencesID)
        guard CFPreferencesAppSynchronize(hitoolboxPreferencesID) else { return false }

        // 同步寫入 com.apple.inputsources (只寫入 Mode)
        let inputsourcesID = "com.apple.inputsources" as CFString
        let thirdPartyKey = "AppleEnabledThirdPartyInputSources" as CFString
        var thirdParty = (CFPreferencesCopyAppValue(thirdPartyKey, inputsourcesID) as? [[String: Any]]) ?? []
        for modeID in modeIDs {
            upsert(
                sourceEntry(bundleID: parentID, modeID: modeID, kind: "Input Mode"),
                into: &thirdParty,
                matching: parentID,
                modeID: modeID
            )
        }
        CFPreferencesSetAppValue(thirdPartyKey, thirdParty as CFPropertyList, inputsourcesID)
        CFPreferencesAppSynchronize(inputsourcesID)

        let persistedEnabled = readEntries(enabledKey)
        let modesPersisted = modeIDs.allSatisfy { modeID in
            persistedEnabled.contains {
                $0["Bundle ID"] as? String == parentID && ($0["Input Mode"] as? String) == modeID
            }
        }
        return modesPersisted
    }

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
        _ = CFPreferencesAppSynchronize(hitoolboxPreferencesID)

        let inputsourcesID = "com.apple.inputsources" as CFString
        let thirdPartyKey = "AppleEnabledThirdPartyInputSources" as CFString
        if let list = CFPreferencesCopyAppValue(thirdPartyKey, inputsourcesID) as? [[String: Any]] {
            let filtered = list.filter { ($0["Bundle ID"] as? String) != parentID }
            CFPreferencesSetAppValue(thirdPartyKey, filtered as CFPropertyList, inputsourcesID)
            CFPreferencesAppSynchronize(inputsourcesID)
        }
        return true
    }
}
