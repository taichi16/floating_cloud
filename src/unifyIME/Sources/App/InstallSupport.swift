import Foundation

private func declaredInputModeIDs(in bundle: Bundle) -> [String] {
    guard let component = bundle.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [String: Any],
          let modeList = component["tsInputModeListKey"] as? [String: Any] else {
        return []
    }
    return modeList.keys.sorted()
}

func installInputMethod() -> Int32 {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        NSLog("Missing bundle identifier.")
        return 1
    }
    let bundleURL = Bundle.main.bundleURL
    let modeIDs = declaredInputModeIDs(in: Bundle.main)
    guard let primaryModeID = modeIDs.first else {
        NSLog("No input mode declared in %@.", bundleURL.path)
        return 1
    }

    if InputSourceHelper.inputMode(for: primaryModeID) == nil {
        NSLog("Registering input source %@ at %@", bundleID, bundleURL.absoluteString)
        guard InputSourceHelper.registerInputSource(at: bundleURL) else {
            NSLog("Cannot register input source %@.", bundleID)
            return 1
        }
    }

    // macOS 對輸入法採用「父輸入來源 + 子輸入模式」兩層狀態。
    // 只啟用子模式有時會讓 TISSelectInputSource 回報成功，但父項仍不會出現在
    // 輸入來源選單，結果是使用者看似切換、實際按鍵仍交給上一個輸入法。
    guard let parent = InputSourceHelper.inputSource(for: bundleID) else {
        NSLog("Cannot find parent input source %@ after registration.", bundleID)
        return 1
    }
    NSLog("Enabling parent input source %@.", bundleID)
    guard InputSourceHelper.enable(inputSource: parent),
          InputSourceHelper.waitUntilInputSourceEnabled(bundleID) else {
        NSLog("Input source %@ still not enabled.", bundleID)
        return 2
    }

    for modeID in modeIDs {
        guard let source = InputSourceHelper.inputMode(for: modeID) else {
            NSLog("Cannot find input mode %@ after registration.", modeID)
            return 1
        }
        NSLog("Enabling input mode %@.", modeID)
        guard InputSourceHelper.enable(inputSource: source) else {
            NSLog("Cannot enable input mode %@.", modeID)
            return 1
        }
        guard InputSourceHelper.waitUntilInputModeEnabled(modeID) else {
            NSLog("Input mode %@ still not enabled.", modeID)
            return 2
        }
    }

    guard InputSourceHelper.persistHIToolboxInputSources(
        parentID: bundleID,
        modeIDs: modeIDs,
        selectedModeID: primaryModeID
    ) else {
        NSLog("Input source state was not persisted to HIToolbox.")
        return 2
    }

    guard let primaryMode = InputSourceHelper.inputMode(for: primaryModeID) else {
        NSLog("Cannot find primary input mode %@.", primaryModeID)
        return 1
    }
    NSLog("Selecting input mode %@.", primaryModeID)
    guard InputSourceHelper.select(inputSource: primaryMode) else {
        NSLog("Cannot select input mode %@.", primaryModeID)
        return 1
    }
    let selected = InputSourceHelper.waitUntilInputModeSelected(primaryModeID)
    NSLog(selected ? "Input mode %@ enabled and selected." : "Input mode %@ enabled but not selected.", primaryModeID)
    return selected ? 0 : 2
}

func uninstallInputMethod() -> Int32 {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        NSLog("Missing bundle identifier.")
        return 1
    }
    NSLog("Unpersisting input sources for %@", bundleID)
    _ = InputSourceHelper.unpersistHIToolboxInputSources(parentID: bundleID)
    return 0
}

