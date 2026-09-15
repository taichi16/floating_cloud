import Foundation
import Carbon

private func declaredInputModeIDs(in bundle: Bundle) -> [String] {
    guard let component = bundle.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [String: Any],
          let modeList = component["tsInputModeListKey"] as? [String: Any] else {
        return []
    }
    return modeList.keys.sorted()
}

func installInputMethod() -> Int32 {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        NSLog("%@", "Missing bundle identifier.")
        return 1
    }
    let bundleURL = Bundle.main.bundleURL
    let modeIDs = declaredInputModeIDs(in: Bundle.main)
    guard let primaryModeID = modeIDs.first else {
        NSLog("%@", "No input mode declared in \(bundleURL.path).")
        return 1
    }

    // 1. 取得現有所有 TIS 來源，避免重複註冊，並停用重複的多餘 handle
    guard let sourceList = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
        NSLog("%@", "Cannot retrieve TIS input source list.")
        return 1
    }

    var matchingParents: [TISInputSource] = []
    var matchingModes: [String: [TISInputSource]] = [:]

    for src in sourceList {
        let bundlePtr = TISGetInputSourceProperty(src, kTISPropertyBundleID)
        let bID = bundlePtr != nil ? Unmanaged<CFString>.fromOpaque(bundlePtr!).takeUnretainedValue() as String : ""
        guard bID == bundleID else { continue }

        let typePtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceType)
        let type = typePtr != nil ? Unmanaged<CFString>.fromOpaque(typePtr!).takeUnretainedValue() as String : ""

        if type == (kTISTypeKeyboardInputMode as String) {
            let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
            let mID = idPtr != nil ? Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String : ""
            matchingModes[mID, default: []].append(src)
        } else {
            matchingParents.append(src)
        }
    }

    let isRegistered = !matchingParents.isEmpty || !matchingModes.isEmpty
    if !isRegistered {
        NSLog("%@", "Registering input source \(bundleID) at \(bundleURL.absoluteString)")
        guard InputSourceHelper.registerInputSource(at: bundleURL) else {
            NSLog("%@", "Cannot register input source \(bundleID).")
            return 1
        }
    } else {
        NSLog("%@", "Input source \(bundleID) already registered in TIS, skipping duplicate registration.")
    }

    // 2. 對於 Parent：若有多個，停用舊的，只保留最新 1 個
    let parentSource: TISInputSource?
    if let lastParent = matchingParents.last {
        parentSource = lastParent
        for redundant in matchingParents.dropLast() {
            NSLog("%@", "Disabling redundant parent source...")
            TISDisableInputSource(redundant)
        }
    } else {
        parentSource = InputSourceHelper.inputSource(for: bundleID)
    }

    if let parent = parentSource {
        NSLog("%@", "Enabling parent input source \(bundleID).")
        _ = InputSourceHelper.enable(inputSource: parent)
    }

    // 3. 對於每個 Input Mode：若有多個，停用舊的，只保留最新 1 個
    var primaryModeSource: TISInputSource?
    for modeID in modeIDs {
        let modes = matchingModes[modeID] ?? []
        let modeSource: TISInputSource?
        if let lastMode = modes.last {
            modeSource = lastMode
            for redundant in modes.dropLast() {
                NSLog("%@", "Disabling redundant mode source for \(modeID)...")
                TISDisableInputSource(redundant)
            }
        } else {
            modeSource = InputSourceHelper.inputMode(for: modeID)
        }

        if let mode = modeSource {
            NSLog("%@", "Enabling input mode \(modeID).")
            _ = InputSourceHelper.enable(inputSource: mode)
            if modeID == primaryModeID {
                primaryModeSource = mode
            }
        }
    }

    // 4. 持久化至 HIToolbox
    _ = InputSourceHelper.persistHIToolboxInputSources(
        parentID: bundleID,
        modeIDs: modeIDs,
        selectedModeID: primaryModeID
    )

    // 5. 選取主模式
    if let primary = primaryModeSource {
        NSLog("%@", "Selecting primary input mode \(primaryModeID).")
        _ = InputSourceHelper.select(inputSource: primary)
    }

    return 0
}

func uninstallInputMethod() -> Int32 {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        NSLog("%@", "Missing bundle identifier.")
        return 1
    }
    NSLog("%@", "Uninstalling and completely disabling input sources for \(bundleID)")

    // 1. 遍歷 TIS 清單，對該 Bundle ID 的所有 Parent 與 Mode 強制呼叫 TISDisableInputSource
    if let sourceList = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] {
        for src in sourceList {
            let bundlePtr = TISGetInputSourceProperty(src, kTISPropertyBundleID)
            let bID = bundlePtr != nil ? Unmanaged<CFString>.fromOpaque(bundlePtr!).takeUnretainedValue() as String : ""
            if bID == bundleID {
                NSLog("%@", "Disabling TIS input source: \(src)")
                TISDisableInputSource(src)
            }
        }
    }

    // 2. 清除 HIToolbox 登錄
    _ = InputSourceHelper.unpersistHIToolboxInputSources(parentID: bundleID)

    // 3. 清除 com.apple.inputsources 登錄
    let thirdPartyKey = "AppleEnabledThirdPartyInputSources" as CFString
    let inputsourcesPrefsID = "com.apple.inputsources" as CFString
    if let list = CFPreferencesCopyAppValue(thirdPartyKey, inputsourcesPrefsID) as? [[String: Any]] {
        let filtered = list.filter { ($0["Bundle ID"] as? String) != bundleID }
        CFPreferencesSetAppValue(thirdPartyKey, filtered as CFPropertyList, inputsourcesPrefsID)
        CFPreferencesAppSynchronize(inputsourcesPrefsID)
    }

    return 0
}
