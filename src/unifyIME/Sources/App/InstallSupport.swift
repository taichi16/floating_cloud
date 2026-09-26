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

    func diagnosticProperty(_ source: TISInputSource, _ key: CFString) -> String {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return "nil" }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)) ? "true" : "false"
        }
        if CFGetTypeID(value) == CFStringGetTypeID() { return value as! String }
        return String(describing: value)
    }

    func logTISState(_ stage: String, parents: [TISInputSource], modes: [String: [TISInputSource]]) {
        NSLog("TIS install diagnostic stage=%@ bundleURL=%@ parents=%lu", stage, bundleURL.path, parents.count)
        for source in parents + modes.values.flatMap({ $0 }) {
            NSLog("TIS install source stage=%@ bundle=%@ id=%@ mode=%@ type=%@ enabled=%@ selectable=%@ selected=%@",
                  stage,
                  diagnosticProperty(source, kTISPropertyBundleID),
                  diagnosticProperty(source, kTISPropertyInputSourceID),
                  diagnosticProperty(source, kTISPropertyInputModeID),
                  diagnosticProperty(source, kTISPropertyInputSourceType),
                  diagnosticProperty(source, kTISPropertyInputSourceIsEnabled),
                  diagnosticProperty(source, kTISPropertyInputSourceIsSelectCapable),
                  diagnosticProperty(source, kTISPropertyInputSourceIsSelected))
        }
    }

    // 1. 取得現有所有 TIS 來源；註冊後必須重新查詢，不能沿用舊 handle。
    func matchingSources() -> ([TISInputSource], [String: [TISInputSource]])? {
        guard let sourceList = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        var parents: [TISInputSource] = []
        var modes: [String: [TISInputSource]] = [:]
        for src in sourceList {
            let bundlePtr = TISGetInputSourceProperty(src, kTISPropertyBundleID)
            let sourceBundleID = bundlePtr != nil
                ? Unmanaged<CFString>.fromOpaque(bundlePtr!).takeUnretainedValue() as String
                : ""
            guard sourceBundleID == bundleID else { continue }

            let typePtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceType)
            let type = typePtr != nil
                ? Unmanaged<CFString>.fromOpaque(typePtr!).takeUnretainedValue() as String
                : ""
            if type == (kTISTypeKeyboardInputMode as String) {
                let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
                let modeID = idPtr != nil
                    ? Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String
                    : ""
                modes[modeID, default: []].append(src)
            } else {
                parents.append(src)
            }
        }
        return (parents, modes)
    }

    guard var matches = matchingSources() else {
        NSLog("%@", "Cannot retrieve TIS input source list.")
        return 1
    }
    var matchingParents = matches.0
    var matchingModes = matches.1
    logTISState("before-registration", parents: matchingParents, modes: matchingModes)

    let isRegistered = !matchingParents.isEmpty || !matchingModes.isEmpty
    if !isRegistered {
        NSLog("%@", "Registering input source \(bundleID) at \(bundleURL.absoluteString)")
        guard InputSourceHelper.registerInputSource(at: bundleURL) else {
            NSLog("%@", "Cannot register input source \(bundleID).")
            return 1
        }
        guard let refreshed = matchingSources() else {
            NSLog("%@", "Cannot retrieve TIS input source list after registration.")
            return 1
        }
        matches = refreshed
        matchingParents = matches.0
        matchingModes = matches.1
        logTISState("after-registration", parents: matchingParents, modes: matchingModes)
    } else {
        NSLog("%@", "Input source \(bundleID) already registered in TIS, skipping duplicate registration.")
    }

    // 2. 對於 Parent：若有多個，停用舊的，只保留最新 1 個
    let parentSource: TISInputSource?
    if let lastParent = matchingParents.last {
        parentSource = lastParent
        for redundant in matchingParents.dropLast() {
            NSLog("%@", "Disabling redundant parent source...")
            if InputSourceHelper.inputSourceEnabled(for: redundant),
               TISDisableInputSource(redundant) != noErr { return 1 }
        }
    } else {
        parentSource = InputSourceHelper.inputSource(for: bundleID)
    }

    guard let parent = parentSource else { return 1 }
    NSLog("%@", "Enabling parent input source \(bundleID).")
    guard InputSourceHelper.enable(inputSource: parent) else { return 1 }
    logTISState("after-parent-enable", parents: [parent], modes: matchingModes)

    // 3. 對於每個 Input Mode：若有多個，停用舊的，只保留最新 1 個
    for modeID in modeIDs {
        let modes = matchingModes[modeID] ?? []
        let modeSource: TISInputSource?
        if let lastMode = modes.last {
            modeSource = lastMode
            for redundant in modes.dropLast() {
                NSLog("%@", "Disabling redundant mode source for \(modeID)...")
                if InputSourceHelper.inputSourceEnabled(for: redundant),
                   TISDisableInputSource(redundant) != noErr { return 1 }
            }
        } else {
            modeSource = InputSourceHelper.inputMode(for: modeID)
        }

        guard let mode = modeSource else { return 1 }
        NSLog("%@", "Enabling input mode \(modeID).")
        guard InputSourceHelper.enable(inputSource: mode) else { return 1 }
        logTISState("after-mode-enable-\(modeID)", parents: [parent], modes: [modeID: [mode]])
    }

    // 4. 持久化至 HIToolbox
    guard InputSourceHelper.persistHIToolboxInputSources(
        parentID: bundleID,
        modeIDs: modeIDs,
        selectedModeID: primaryModeID
    ) else { return 1 }

    // 5. TIS registration and preference propagation can lag behind the API
    // return code. Select only a freshly enumerated mode whose parent is ready.
    func propertyIsTrue(_ source: TISInputSource, _ property: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
    var readyPrimary: TISInputSource?
    let readinessDeadline = Date().addingTimeInterval(10)
    repeat {
        guard let refreshed = matchingSources() else { return 1 }
        let enabledParents = refreshed.0.filter {
            propertyIsTrue($0, kTISPropertyInputSourceIsEnabled)
        }
        let readyModes = (refreshed.1[primaryModeID] ?? []).filter {
            propertyIsTrue($0, kTISPropertyInputSourceIsEnabled)
                && propertyIsTrue($0, kTISPropertyInputSourceIsSelectCapable)
        }
        if enabledParents.count == 1, readyModes.count == 1 {
            readyPrimary = readyModes[0]
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < readinessDeadline

    guard let primary = readyPrimary else {
        NSLog("TIS install readiness timeout bundle=%@ mode=%@", bundleID, primaryModeID)
        return 1
    }
    NSLog("TIS install readiness confirmed bundle=%@ mode=%@", bundleID, primaryModeID)
    NSLog("%@", "Selecting primary input mode \(primaryModeID).")
    let selectStatus = TISSelectInputSource(primary)
    NSLog("TIS install select result mode=%@ status=%d", primaryModeID, selectStatus)
    guard selectStatus == noErr else { return 1 }

    return 0
}

func uninstallInputMethod() -> Int32 {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        NSLog("%@", "Missing bundle identifier.")
        return 1
    }
    NSLog("%@", "Disabling selectable input sources before uninstall for \(bundleID)")

    // 1. 若目前正使用本產品，先切到其他已啟用且可選取的來源。
    guard let sourceList = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
        return 1
    }
    func propertyString(_ source: TISInputSource, _ property: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
       propertyString(current, kTISPropertyBundleID) == bundleID {
        let alternatives = sourceList.filter {
            let selectablePointer = TISGetInputSourceProperty($0, kTISPropertyInputSourceIsSelectCapable)
            let selectable = selectablePointer != nil
                && CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(selectablePointer!).takeUnretainedValue())
            return selectable && propertyString($0, kTISPropertyBundleID) != bundleID
        }
        let fallback = alternatives.first(where: {
            propertyString($0, kTISPropertyInputSourceID) == "com.apple.keylayout.ABC"
        }) ?? alternatives.first
        guard let fallback, TISSelectInputSource(fallback) == noErr else {
            NSLog("%@", "Cannot switch away from the active input method; aborting uninstall.")
            return 1
        }
    }

    // 2. 停用可選取的本產品來源；不可選的 parent 不是使用者輸入模式。
    for src in sourceList {
        let bundlePtr = TISGetInputSourceProperty(src, kTISPropertyBundleID)
        let bID = bundlePtr != nil ? Unmanaged<CFString>.fromOpaque(bundlePtr!).takeUnretainedValue() as String : ""
        let selectablePtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable)
        let selectable = selectablePtr != nil
            && CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(selectablePtr!).takeUnretainedValue())
        if bID == bundleID && selectable && InputSourceHelper.inputSourceEnabled(for: src) {
            NSLog("%@", "Disabling TIS input source: \(src)")
            guard TISDisableInputSource(src) == noErr else { return 1 }
        }
    }

    // 3. 清除 HIToolbox 登錄
    guard InputSourceHelper.unpersistHIToolboxInputSources(parentID: bundleID) else { return 1 }

    return 0
}
