import AppKit
import InputMethodKit

private let basicSelectionNotification = Notification.Name("com.vader.unifyime.state")
private let basicSelectionMarker = "[[SEL]]"
private var retainedIMKServer: IMKServer?
private var retainedIMEApplicationDelegate: IMEApplicationDelegate?

struct IMELifecycleFlushReportPolicy {
    static func shouldReport(failureSignature: String, previousFailureSignature: String?) -> Bool {
        !failureSignature.isEmpty && failureSignature != previousFailureSignature
    }
}

enum IMELifecycleFrequencyFlush {
    private static let lock = NSLock()
    private static var lastReportedFailureSignature: String?

    static func flush(source: String) {
        let result = UserFrequencyStore.flushNow()
        let failureSignature = result.failures
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "；")

        if result.isSuccess {
            lock.lock()
            lastReportedFailureSignature = nil
            lock.unlock()
            appendRuntimeTrace(
                "lifecycle.frequencyFlush source=\(source) status=pass attempted=\(result.attemptedLanguageIDs.joined(separator: ","))"
            )
            return
        }

        lock.lock()
        let shouldReport = IMELifecycleFlushReportPolicy.shouldReport(
            failureSignature: failureSignature,
            previousFailureSignature: lastReportedFailureSignature
        )
        if shouldReport {
            lastReportedFailureSignature = failureSignature
        }
        lock.unlock()

        appendRuntimeTrace(
            "lifecycle.frequencyFlush source=\(source) status=fail attempted=\(result.attemptedLanguageIDs.joined(separator: ",")) "
                + "succeeded=\(result.succeededLanguageIDs.joined(separator: ",")) "
                + "failure=\(failureSignature) duplicateSuppressed=\(!shouldReport)"
        )
        if shouldReport {
            NSLog("行雲_繁-A詞頻寫入失敗（%@）：%@", source, failureSignature)
        }
    }
}

/// 正式 IME 程序的最小終止接點；偏好預覽與候選輔助程序各自使用自己的 delegate。
private final class IMEApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        InputSourceHelper.selfHealDeduplicateInputSources()
    }

    func applicationWillTerminate(_: Notification) {
        IMELifecycleFrequencyFlush.flush(source: "applicationWillTerminate")
    }
}

private final class BasicSelectionWindowAppDelegate: NSObject, NSApplicationDelegate {
    private var lastAnchor: CGPoint?
    private var helperPinnedAnchor: CGPoint?

    private func parseBasicCandidates(from text: String) -> ([String], Int) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var candidates: [String] = []
        var selectedIndex = 0
        for line in lines {
            let isSelected = line.contains(basicSelectionMarker)
            let cleaned = line.replacingOccurrences(of: basicSelectionMarker, with: "")
            guard let dot = cleaned.firstIndex(of: ".") else { continue }
            let value = cleaned[cleaned.index(after: dot)...].trimmingCharacters(in: CharacterSet.whitespaces)
            guard !value.isEmpty else { continue }
            if isSelected {
                selectedIndex = candidates.count
            }
            candidates.append(value)
        }
        return (candidates, selectedIndex)
    }

    @objc
    func handleIMEState(_ notification: Notification) {
        let text = notification.userInfo?["text"] as? String ?? ""
        let showCandidates = notification.userInfo?["showCandidates"] as? Bool ?? true
        guard !text.isEmpty else {
            lastAnchor = nil
            helperPinnedAnchor = nil
            BasicCandidatePanelController.shared.hide()
            return
        }

        let anchor: CGPoint?
        if let x = notification.userInfo?["anchorX"] as? CGFloat,
           let y = notification.userInfo?["anchorY"] as? CGFloat {
            anchor = CGPoint(x: x, y: y)
        } else if let x = notification.userInfo?["anchorX"] as? Double,
                  let y = notification.userInfo?["anchorY"] as? Double {
            anchor = CGPoint(x: x, y: y)
        } else {
            anchor = nil
        }
        if let anchor {
            lastAnchor = anchor
        }

        let (candidates, selectedIndex) = parseBasicCandidates(from: text)
        if !showCandidates || candidates.isEmpty {
            helperPinnedAnchor = nil
            BasicCandidatePanelController.shared.hide()
            return
        }
        guard let stableAnchor = anchor ?? lastAnchor ?? helperPinnedAnchor else {
            BasicCandidatePanelController.shared.hide()
            return
        }
        if let anchor {
            helperPinnedAnchor = anchor
        } else if helperPinnedAnchor == nil {
            helperPinnedAnchor = stableAnchor
        }
        BasicCandidatePanelController.shared.show(anchor: helperPinnedAnchor, candidates: candidates, selectedIndex: selectedIndex)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        BasicCandidatePanelController.shared.prewarm()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleIMEState(_:)),
            name: basicSelectionNotification,
            object: nil
        )
        NSApp.setActivationPolicy(.accessory)
    }
}

private func loadSentenceRerankerExample(from path: String) throws -> SentenceRerankerExample {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    return try decoder.decode(SentenceRerankerExample.self, from: data)
}

private func reportCLIError(_ error: Error, path: String) -> Never {
    fputs("error: unable to read or decode '\(path)': \(error.localizedDescription)\n", stderr)
    exit(2)
}

private func loadActionBatchRows(from path: String) throws -> [[String: Any]] {
    let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    let lines = text.split(whereSeparator: \.isNewline)
    guard !lines.isEmpty else { throw NSError(domain: "UnifyIMECLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "input JSONL contains no rows"]) }
    return try lines.enumerated().map { index, line in
        guard let data = line.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "UnifyIMECLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid JSON object at line \(index + 1)"])
        }
        return object
    }
}

private func defaultCLIOutputPath(_ name: String) -> String {
    runtimeTempDir.appendingPathComponent(name).path
}

private func englishBehavior() -> CompositionLanguageBehavior? {
    CompositionLanguageRegistry.targets.first { $0.id == "english-ime" }?.behavior
}

private func buildChineseProbeInputPayload(sentence: String, reverseMap: [String: [String]]) -> [String: Any]? {
    let chars = Array(sentence)
    var index = 0
    var allReadings: [String] = []
    var rowKeys: [String] = []
    var keyTokens: [String] = []
    var keySequenceParts: [String] = []

    func appendPhoneticRun(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let readings = CompositionLanguageRegistry.primary.reverseReadings(for: text, reverseMap: reverseMap) else { return false }
        let sequence = CompositionLanguageRegistry.primary.keySequence(for: readings)
        let groupedTokens = sequence.split(separator: " ").map(String.init).filter { !$0.isEmpty && !$0.contains("?") }
        guard !groupedTokens.isEmpty else { return false }
        allReadings.append(contentsOf: readings)
        keySequenceParts.append(contentsOf: groupedTokens)
        keyTokens.append(contentsOf: groupedTokens)
        rowKeys.append(contentsOf: groupedTokens.map { "raw:\($0)" })
        rowKeys.append("enter")
        return true
    }

    while index < chars.count {
        let scalarText = String(chars[index])

        if chars[index].isWhitespace {
            rowKeys.append("space")
            keySequenceParts.append("<space>")
            index += 1
            continue
        }

        if scalarText.utf8.count == 1, let byte = scalarText.utf8.first,
           byte >= 48 && byte <= 57, NumericKeypadInput.keyCodes[scalarText] != nil {
            rowKeys.append("keypad:\(scalarText)")
            keyTokens.append("keypad:\(scalarText)")
            keySequenceParts.append("<keypad:\(scalarText)>")
            index += 1
            continue
        }

        if SessionCtl.directPunctuationMap.keys.contains(scalarText) || "，。！？；：、（）〔〕【】《》「」『』…—﹐“”".contains(chars[index]) {
            rowKeys.append("punct:\(scalarText)")
            index += 1
            continue
        }

        if let scalar = scalarText.unicodeScalars.first,
           scalar.isASCII,
           CharacterSet.letters.contains(scalar),
           scalar.properties.isUppercase {
            rowKeys.append("shift:\(scalarText.lowercased())")
            index += 1
            continue
        }

        var resolved = false
        for end in stride(from: chars.count, through: index + 1, by: -1) {
            let run = String(chars[index..<end])
            guard appendPhoneticRun(run) else { continue }
            index = end
            resolved = true
            break
        }
        if !resolved {
            return nil
        }
    }

    return [
        "sentence": sentence,
        "resolved": true,
        "readings": allReadings,
        "key_sequence": keySequenceParts.joined(separator: " "),
        "key_tokens": keyTokens,
        "row_keys": rowKeys,
    ]
}

private func buildEnglishProbeInputPayload(sentence: String) -> [String: Any]? {
    guard let englishBehavior = englishBehavior() else { return nil }
    let chars = Array(sentence)
    var index = 0
    var allReadings: [String] = []
    var rowKeys: [String] = []
    var keyTokens: [String] = []
    var keySequenceParts: [String] = []

    func appendEnglishRun(_ text: String) -> Bool {
        let normalizedWords = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedWords.isEmpty else { return false }

        var firstWord = true
        for word in normalizedWords {
            guard let readings = englishBehavior.reverseReadings(for: word, reverseMap: [:]),
                  !readings.isEmpty else { return false }
            let sequence = englishBehavior.keySequence(for: readings)
            guard !sequence.isEmpty else { return false }
            if !firstWord {
                rowKeys.append("space")
                keySequenceParts.append("<space>")
            }
            firstWord = false
            allReadings.append(contentsOf: readings)
            keyTokens.append(sequence)
            keySequenceParts.append(sequence)
            rowKeys.append("raw:\(sequence)")
        }
        rowKeys.append("enter")
        return true
    }

    while index < chars.count {
        let scalarText = String(chars[index])

        if chars[index].isWhitespace {
            rowKeys.append("space")
            keySequenceParts.append("<space>")
            index += 1
            continue
        }

        if scalarText.utf8.count == 1, let byte = scalarText.utf8.first,
           byte >= 48 && byte <= 57, NumericKeypadInput.keyCodes[scalarText] != nil {
            rowKeys.append("keypad:\(scalarText)")
            keyTokens.append("keypad:\(scalarText)")
            keySequenceParts.append("<keypad:\(scalarText)>")
            index += 1
            continue
        }

        if SessionCtl.directPunctuationMap.keys.contains(scalarText) || "，。！？；：、（）〔〕【】《》「」『』…—﹐“”".contains(chars[index]) {
            rowKeys.append("punct:\(scalarText)")
            index += 1
            continue
        }

        if let scalar = scalarText.unicodeScalars.first,
           scalar.isASCII, CharacterSet.letters.contains(scalar), scalar.properties.isUppercase {
            rowKeys.append("shift:\(scalarText.lowercased())")
            index += 1
            continue
        }

        if let scalar = scalarText.unicodeScalars.first,
           scalar.isASCII,
           (CharacterSet.letters.contains(scalar) || scalarText == "'" || scalarText == "-") {
            let start = index
            var end = index
            while end < chars.count {
                let current = String(chars[end])
                guard let currentScalar = current.unicodeScalars.first,
                      currentScalar.isASCII, !currentScalar.properties.isUppercase,
                      (CharacterSet.letters.contains(currentScalar) || current == "'" || current == "-") else {
                    break
                }
                end += 1
            }
            let run = String(chars[start..<end])
            guard appendEnglishRun(run) else { return nil }
            index = end
            continue
        }

        return nil
    }

    return [
        "sentence": sentence,
        "resolved": true,
        "readings": allReadings,
        "key_sequence": keySequenceParts.joined(separator: " "),
        "key_tokens": keyTokens,
        "row_keys": rowKeys,
    ]
}

private func buildProbeInputPayload(sentence: String, reverseMap: [String: [String]]) -> [String: Any]? {
    let chars = Array(sentence)
    var index = 0
    var allReadings: [String] = []
    var rowKeys: [String] = []
    var keyTokens: [String] = []
    var keySequenceParts: [String] = []

    func appendPhoneticRun(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let readings = CompositionLanguageRegistry.primary.reverseReadings(for: text, reverseMap: reverseMap) else { return false }
        let sequence = CompositionLanguageRegistry.primary.keySequence(for: readings)
        let groupedTokens = sequence.split(separator: " ").map(String.init).filter { !$0.isEmpty && !$0.contains("?") }
        guard !groupedTokens.isEmpty else { return false }
        allReadings.append(contentsOf: readings)
        keySequenceParts.append(contentsOf: groupedTokens)
        keyTokens.append(contentsOf: groupedTokens)
        rowKeys.append(contentsOf: groupedTokens.map { "raw:\($0)" })
        rowKeys.append("enter")
        return true
    }

    func appendEnglishRun(_ text: String) -> Bool {
        let normalizedWords = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedWords.isEmpty else { return false }
        guard let englishBehavior = englishBehavior() else { return false }

        var firstWord = true
        for word in normalizedWords {
            guard let readings = englishBehavior.reverseReadings(for: word, reverseMap: [:]),
                  !readings.isEmpty else { return false }
            let sequence = englishBehavior.keySequence(for: readings)
            guard !sequence.isEmpty else { return false }
            if !firstWord {
                rowKeys.append("space")
                keySequenceParts.append("<space>")
            }
            firstWord = false
            allReadings.append(contentsOf: readings)
            keyTokens.append(sequence)
            keySequenceParts.append(sequence)
            rowKeys.append("raw:\(sequence)")
        }
        rowKeys.append("enter")
        return true
    }

    while index < chars.count {
        let scalarText = String(chars[index])

        if chars[index].isWhitespace {
            rowKeys.append("space")
            keySequenceParts.append("<space>")
            index += 1
            continue
        }

        if scalarText.utf8.count == 1, let byte = scalarText.utf8.first,
           byte >= 48 && byte <= 57, NumericKeypadInput.keyCodes[scalarText] != nil {
            rowKeys.append("keypad:\(scalarText)")
            keyTokens.append("keypad:\(scalarText)")
            keySequenceParts.append("<keypad:\(scalarText)>")
            index += 1
            continue
        }

        if SessionCtl.directPunctuationMap.keys.contains(scalarText) || "，。！？；：、（）〔〕【】《》「」『』…—﹐“”".contains(chars[index]) {
            rowKeys.append("punct:\(scalarText)")
            index += 1
            continue
        }

        if let scalar = scalarText.unicodeScalars.first,
           scalar.isASCII, CharacterSet.letters.contains(scalar), scalar.properties.isUppercase {
            rowKeys.append("shift:\(scalarText.lowercased())")
            index += 1
            continue
        }

        if let scalar = scalarText.unicodeScalars.first,
           scalar.isASCII,
           (CharacterSet.letters.contains(scalar) || scalarText == "'" || scalarText == "-") {
            let start = index
            var end = index
            while end < chars.count {
                let current = String(chars[end])
                guard let currentScalar = current.unicodeScalars.first,
                      currentScalar.isASCII, !currentScalar.properties.isUppercase,
                      (CharacterSet.letters.contains(currentScalar) || current == "'" || current == "-") else {
                    break
                }
                end += 1
            }
            let run = String(chars[start..<end])
            guard appendEnglishRun(run) else { return nil }
            index = end
            continue
        }

        var resolved = false
        for end in stride(from: chars.count, through: index + 1, by: -1) {
            let run = String(chars[index..<end])
            guard appendPhoneticRun(run) else { continue }
            index = end
            resolved = true
            break
        }
        if !resolved {
            return nil
        }
    }

    return [
        "sentence": sentence,
        "resolved": true,
        "readings": allReadings,
        "key_sequence": keySequenceParts.joined(separator: " "),
        "key_tokens": keyTokens,
        "row_keys": rowKeys,
    ]
}

private func printJSONObjectLine(_ object: [String: Any]) -> Int32 {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let json = String(data: data, encoding: .utf8) else {
        print("{\"resolved\":false}")
        return 2
    }
    print(json)
    return 0
}

private func symbolShortcutProbe() -> Int32 {
    let cases: [(name: String, characters: String?, modifiers: SymbolShortcutModifiers, hasComposition: Bool, expected: String)] = [
        ("shift-question-empty", "?", [.shift], false, "insert:？:empty"),
        ("shift-question-composing", "?", [.shift], true, "insert:？:composition"),
        ("shift-exclamation", "!", [.shift], false, "insert:！:empty"),
        ("shift-colon", ":", [.shift], false, "insert:：:empty"),
        ("shift-quote-empty", "\"", [.shift], false, "insert:”:empty"),
        ("shift-quote-composing", "\"", [.shift], true, "insert:”:composition"),
        ("no-modifier-question", "?", [], false, "passThrough"),
        ("shift-command", "?", [.shift, .command], false, "passThrough"),
        ("shift-control", "?", [.shift, .control], false, "passThrough"),
        ("shift-option", "?", [.shift, .option], false, "passThrough"),
        ("shift-function", "?", [.shift, .function], false, "passThrough"),
        ("shift-caps-lock", "?", [.shift, .capsLock], false, "passThrough"),
        ("shift-numeric-pad", "?", [.shift, .numericPad], false, "passThrough"),
        ("shift-unknown-modifier", "?", [.shift, .other], false, "passThrough"),
        ("shift-letter", "a", [.shift], false, "passThrough"),
        ("shift-multiple-characters", "?!", [.shift], false, "passThrough"),
        ("shift-no-characters", nil, [.shift], false, "passThrough")
    ]

    func label(_ decision: SymbolShortcutDecision) -> String {
        switch decision {
        case .passThrough:
            return "passThrough"
        case let .insertComposingSymbol(symbol, hasComposition):
            return "insert:\(symbol):\(hasComposition ? "composition" : "empty")"
        }
    }

    var passed = 0
    var failures: [String] = []
    var details: [[String: Any]] = []
    for testCase in cases {
        let actual = label(SymbolCandidates.decideShiftedPunctuation(
            characters: testCase.characters,
            modifiers: testCase.modifiers,
            hasComposition: testCase.hasComposition
        ))
        let isPassed = actual == testCase.expected
        if isPassed {
            passed += 1
        } else {
            failures.append(testCase.name)
        }
        details.append([
            "name": testCase.name,
            "expected": testCase.expected,
            "actual": actual,
            "status": isPassed ? "pass" : "fail"
        ])
    }

    print("A 符號修飾鍵純邏輯 probe：\(passed)/\(cases.count) 通過")
    return printJSONObjectLine([
        "status": failures.isEmpty ? "pass" : "fail",
        "native_imk": "unresolved_manual",
        "passed": passed,
        "total": cases.count,
        "failures": failures,
        "cases": details
    ])
}

private func imkBoundaryProbe() -> Int32 {
    func label(_ decision: IMKClientResolutionDecision) -> String {
        switch decision {
        case .callback:
            return "callback"
        case .storedFallback:
            return "storedFallback"
        case .unavailable:
            return "unavailable"
        }
    }

    func label(_ decision: IMKApplicationShortcutDecision) -> String {
        switch decision {
        case .continueInputMethod:
            return "continueInputMethod"
        case .passThrough:
            return "passThrough"
        case .commitCompositionThenPassThrough:
            return "commitCompositionThenPassThrough"
        }
    }

    let sessionCases: [(name: String, sessionIsActive: Bool, callbackProvided: Bool, callbackIsIMKTextInput: Bool, callbackSessionID: String?, activeSessionID: String?, storedSessionID: String?, expected: String)] = [
        ("callback-same-session", true, true, true, "session-A", "session-A", "session-A", "callback"),
        ("nil-callback-stored-same-session", true, false, false, nil, "session-A", "session-A", "storedFallback"),
        ("non-imk-callback-no-fallback", true, true, false, nil, "session-A", "session-A", "unavailable"),
        ("foreign-imk-callback-no-fallback", true, true, true, "session-B", "session-A", "session-A", "unavailable"),
        ("inactive-no-fallback", false, false, false, nil, "session-A", "session-A", "unavailable"),
        ("stored-session-mismatch", true, false, false, nil, "session-A", "session-B", "unavailable"),
        ("missing-active-session-id", true, false, false, nil, nil, "session-A", "unavailable")
    ]

    let rangeCases: [(name: String, kind: String, input: NSRange, expected: NSRange)] = [
        ("marked-update-uses-current-selection", "update", NSRange(location: 4, length: 2), IMKReplacementRangePolicy.currentInsertionPoint),
        ("clear-valid-marked-range", "clear", NSRange(location: 4, length: 2), NSRange(location: 4, length: 2)),
        ("clear-not-found-marked-range", "clear", NSRange(location: NSNotFound, length: 0), IMKReplacementRangePolicy.currentInsertionPoint),
        ("commit-valid-marked-range", "commit", NSRange(location: 7, length: 3), IMKReplacementRangePolicy.currentInsertionPoint),
        ("commit-not-found-marked-range", "commit", NSRange(location: NSNotFound, length: NSNotFound), IMKReplacementRangePolicy.currentInsertionPoint)
    ]

    let routeCases: [(name: String, modifiers: SymbolShortcutModifiers, hasComposition: Bool, expected: String)] = [
        ("command-empty", [.command], false, "passThrough"),
        ("command-composing", [.command], true, "commitCompositionThenPassThrough"),
        ("control-composing", [.control], true, "commitCompositionThenPassThrough"),
        ("option-empty", [.option], false, "passThrough"),
        ("shift-command-composing", [.shift, .command], true, "commitCompositionThenPassThrough"),
        ("shift-only", [.shift], true, "continueInputMethod"),
        ("function-is-not-application-modifier", [.function], false, "continueInputMethod"),
        ("unknown-modifier-empty", [.other], false, "passThrough")
    ]

    let lifecycleCases: [(name: String, failureSignature: String, previousFailureSignature: String?, expected: Bool)] = [
        ("first-failure-reports", "zh:disk", nil, true),
        ("same-failure-suppressed", "zh:disk", "zh:disk", false),
        ("different-failure-reports", "zh:disk", "en:disk", true),
        ("empty-failure-does-not-report", "", nil, false)
    ]

    var passed = 0
    var total = 0
    var failures: [String] = []
    var details: [[String: Any]] = []

    func record(name: String, expected: String, actual: String) {
        total += 1
        let isPassed = expected == actual
        if isPassed {
            passed += 1
        } else {
            failures.append(name)
        }
        details.append([
            "name": name,
            "expected": expected,
            "actual": actual,
            "status": isPassed ? "pass" : "fail"
        ])
    }

    for testCase in sessionCases {
        let actual = label(IMKClientResolutionPolicy.decide(
            sessionIsActive: testCase.sessionIsActive,
            callbackProvided: testCase.callbackProvided,
            callbackIsIMKTextInput: testCase.callbackIsIMKTextInput,
            callbackSessionID: testCase.callbackSessionID,
            activeSessionID: testCase.activeSessionID,
            storedSessionID: testCase.storedSessionID
        ))
        record(name: "session/\(testCase.name)", expected: testCase.expected, actual: actual)
    }

    for testCase in rangeCases {
        let actual: NSRange
        switch testCase.kind {
        case "update":
            actual = IMKReplacementRangePolicy.forMarkedTextUpdate()
        case "clear":
            actual = IMKReplacementRangePolicy.forClearingMarkedText(testCase.input)
        default:
            actual = IMKReplacementRangePolicy.forCommit(testCase.input)
        }
        record(
            name: "range/\(testCase.name)",
            expected: NSStringFromRange(testCase.expected),
            actual: NSStringFromRange(actual)
        )
    }

    for testCase in routeCases {
        let actual = label(IMKApplicationShortcutPolicy.decide(
            modifiers: testCase.modifiers,
            hasComposition: testCase.hasComposition
        ))
        record(name: "route/\(testCase.name)", expected: testCase.expected, actual: actual)
    }

    for testCase in lifecycleCases {
        let actual = IMELifecycleFlushReportPolicy.shouldReport(
            failureSignature: testCase.failureSignature,
            previousFailureSignature: testCase.previousFailureSignature
        )
        record(name: "lifecycle/\(testCase.name)", expected: String(testCase.expected), actual: String(actual))
    }

    print("IMK 邊界純邏輯 probe：\(passed)/\(total) 通過")
    return printJSONObjectLine([
        "status": failures.isEmpty ? "pass" : "fail",
        "native_imk": "unresolved_manual",
        "scope": "pure_policy_only",
        "passed": passed,
        "total": total,
        "failures": failures,
        "checks": details
    ])
}

func runUnifyIMEAppEntry() {
    if CommandLine.arguments.dropFirst().first == "preferences-preview" {
        let app = NSApplication.shared
        let delegate = PreferencesPreviewAppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "install" {
        exit(installInputMethod())
    }

    if CommandLine.arguments.dropFirst().first == "uninstall" {
        exit(uninstallInputMethod())
    }

    if CommandLine.arguments.dropFirst().first == "training-progress-window" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let first = args.first else {
            print("usage: training-progress-window <output-dir>")
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = TrainingProgressAppDelegate(outputDir: URL(fileURLWithPath: first))
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "basicSelWindow" {
        let app = NSApplication.shared
        let delegate = BasicSelectionWindowAppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "symbol-shortcut-probe" {
        exit(symbolShortcutProbe())
    }

    if CommandLine.arguments.dropFirst().first == "imk-boundary-probe" {
        exit(imkBoundaryProbe())
    }

    if CommandLine.arguments.dropFirst().first == "reading-walk-incremental-probe" {
        SessionCtl.prewarmLexicon()
        exit(SessionCtl.runReadingWalkIncrementalProbe())
    }

    if CommandLine.arguments.dropFirst().first == "phrase-stats-cache-status" {
        SessionCtl.prewarmChinesePredictionRuntime()
        let snapshot = LexiconStore.phraseContextStatsCacheSnapshot()
        exit(printJSONObjectLine([
            "loaded": snapshot.loaded,
            "parse_count": snapshot.parseCount,
            "cache_hit_count": snapshot.cacheHitCount,
            "surface_count": snapshot.surfaceCount,
            "reading_count": snapshot.readingCount,
        ]))
    }

    if CommandLine.arguments.dropFirst().first == "selftest" {
        SessionCtl.prewarmLexicon()
        var args = Array(CommandLine.arguments.dropFirst(2))
        var rounds = 1
        var summaryOnly = false
        var filteredArgs: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--rounds", index + 1 < args.count, let value = Int(args[index + 1]) {
                rounds = max(1, value)
                index += 2
                continue
            }
            if arg == "--summary-only" {
                summaryOnly = true
                index += 1
                continue
            }
            filteredArgs.append(arg)
            index += 1
        }
        args = filteredArgs
        let cases: [SessionCtl.SelfTestCase]
        let useFullSuite: Bool
        if args.first == "short-words" {
            let batchSize = args.dropFirst().first.flatMap(Int.init) ?? 10
            cases = SessionCtl.generateShortWordTestCases(batchSize: batchSize)
            useFullSuite = false
        } else if args.first == "full-single" {
            cases = SessionCtl.generateSingleCharacterTestCases(batchSize: 500)
            useFullSuite = true
        } else if args.first == "full-words" {
            cases = SessionCtl.generateShortWordTestCases(batchSize: 500)
            useFullSuite = true
        } else if args.first == "full-sentences" {
            cases = SessionCtl.generateShortSentenceTestCases(batchSize: 300)
            useFullSuite = true
        } else if args.first == "full-articles" {
            cases = SessionCtl.generateLongArticleTestCases(batchSize: 5, targetChars: 300)
            useFullSuite = true
        } else if args.first == "short-sentences" {
            let batchSize = args.dropFirst().first.flatMap(Int.init) ?? 10
            cases = SessionCtl.generateShortSentenceTestCases(batchSize: batchSize)
            useFullSuite = false
        } else if args.first == "short-article" {
            cases = [SessionCtl.generateShortArticleCase()]
            useFullSuite = false
        } else if args.first == "dynamic" {
            let batchSize = args.dropFirst().first.flatMap(Int.init) ?? 10
            cases = SessionCtl.generateDynamicSelfTestCases(batchSize: batchSize)
            useFullSuite = false
        } else if args.first == "full" {
            cases = SessionCtl.generateFullSelfTestCases()
            useFullSuite = true
        } else if let first = args.first, FileManager.default.fileExists(atPath: first) {
            let text = (try? String(contentsOfFile: first, encoding: .utf8)) ?? ""
            let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
            let sentences = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            cases = sentences.map { SessionCtl.SelfTestCase(sentence: $0, readings: CompositionLanguageRegistry.primary.reverseReadings(for: $0, reverseMap: reverseMap)) }
            useFullSuite = false
        } else if !args.isEmpty {
            let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
            cases = args.map { SessionCtl.SelfTestCase(sentence: $0, readings: CompositionLanguageRegistry.primary.reverseReadings(for: $0, reverseMap: reverseMap)) }
            useFullSuite = false
        } else {
            cases = SessionCtl.defaultSelfTestCases()
            useFullSuite = false
        }
        let selectedCases = useFullSuite ? cases : Array(cases.prefix(10))
        if rounds == 1, !summaryOnly {
            exit(SessionCtl.runSelfTest(cases: selectedCases))
        }

        var passed = 0
        var total = 0
        var failedSentences: [String] = []
        for round in 1...rounds {
            if !summaryOnly {
                print("=== ROUND \(round)/\(rounds) ===")
            }
            for testCase in selectedCases {
                let output = testCase.readings.map(UnifiedCompositionEngine.simulateIncrementalInput(readings:)) ?? "（無法反查讀音）"
                let ok = output == testCase.sentence
                total += 1
                if ok {
                    passed += 1
                } else {
                    failedSentences.append(testCase.sentence)
                    if !summaryOnly {
                        print("FAIL: \(testCase.sentence)")
                        print("輸出: \(output)")
                        print("---")
                    }
                }
            }
        }
        print("主 selftest 總結: \(passed)/\(total) 通過")
        if !failedSentences.isEmpty {
            let uniqueFailures = Array(Set(failedSentences)).sorted()
            print("失敗句子數: \(uniqueFailures.count)")
            if !summaryOnly {
                for sentence in uniqueFailures {
                    print("- \(sentence)")
                }
            }
        }
        exit(passed == total ? 0 : 2)
    }

    if CommandLine.arguments.dropFirst().first == "ime-action-replay" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        exit(imeActionScriptProbe(args))
    }

    if CommandLine.arguments.dropFirst().first == "zh-ime-action-replay" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        exit(imeActionScriptProbe(args))
    }

    if CommandLine.arguments.dropFirst().first == "en-ime-action-replay" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        exit(englishActionScriptProbe(args))
    }

    // 持續程序，每次只接收一段逐鍵操作；測試端可在失敗後停止送入後續段落。
    if CommandLine.arguments.dropFirst().first == "ime-action-stream-replay" {
        while let line = readLine() {
            do {
                guard let data = line.data(using: .utf8),
                      let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "IMEReplay", code: 1)
                }
                _ = imeActionBatchProbe([row], prewarmChinese: true)
            } catch {
                _ = printJSONObjectLine(["error": "無效的逐鍵操作 JSON：\(error)"])
            }
            fflush(stdout)
        }
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "ime-action-batch-replay" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let inputPath = args.first else {
            print("usage: ime-action-batch-replay <input.jsonl>")
            exit(2)
        }
        let rows: [[String: Any]]
        do {
            rows = try loadActionBatchRows(from: inputPath)
        } catch {
            reportCLIError(error, path: inputPath)
        }
        exit(imeActionBatchProbe(rows, prewarmChinese: false))
    }

    if CommandLine.arguments.dropFirst().first == "zh-ime-action-batch-replay" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let inputPath = args.first else {
            print("usage: zh-ime-action-batch-replay <input.jsonl>")
            exit(2)
        }
        let rows: [[String: Any]]
        do {
            rows = try loadActionBatchRows(from: inputPath)
        } catch {
            reportCLIError(error, path: inputPath)
        }
        exit(imeActionBatchProbe(rows, prewarmChinese: true))
    }

    if CommandLine.arguments.dropFirst().first == "en-ime-action-batch-replay" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let inputPath = args.first else {
            print("usage: en-ime-action-batch-replay <input.jsonl>")
            exit(2)
        }
        let rows: [[String: Any]]
        do {
            rows = try loadActionBatchRows(from: inputPath)
        } catch {
            reportCLIError(error, path: inputPath)
        }
        exit(englishActionBatchProbe(rows))
    }

    if CommandLine.arguments.dropFirst().first == "ime-raw-final-replay" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        exit(imeRawFinalProbe(args))
    }

    if CommandLine.arguments.dropFirst().first == "build-raw-input" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard !args.isEmpty else {
            print("usage: build-raw-input <sentence>")
            exit(2)
        }
        let sentence = args.joined(separator: " ")
        let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
        guard let payload = buildProbeInputPayload(sentence: sentence, reverseMap: reverseMap) else {
            print("{\"sentence\":\"\(sentence)\",\"resolved\":false}")
            exit(2)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else {
            print("{\"sentence\":\"\(sentence)\",\"resolved\":false}")
            exit(2)
        }
        print(json)
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "zh-build-raw-input" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard !args.isEmpty else {
            print("usage: zh-build-raw-input <sentence>")
            exit(2)
        }
        let sentence = args.joined(separator: " ")
        let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
        guard let payload = buildChineseProbeInputPayload(sentence: sentence, reverseMap: reverseMap) else {
            print("{\"sentence\":\"\(sentence)\",\"resolved\":false}")
            exit(2)
        }
        _ = printJSONObjectLine(payload)
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "en-build-raw-input" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard !args.isEmpty else {
            print("usage: en-build-raw-input <sentence>")
            exit(2)
        }
        let sentence = args.joined(separator: " ")
        guard let payload = buildEnglishProbeInputPayload(sentence: sentence) else {
            print("{\"sentence\":\"\(sentence)\",\"resolved\":false}")
            exit(2)
        }
        _ = printJSONObjectLine(payload)
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "build-raw-input-batch" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let inputPath = args.first else {
            print("usage: build-raw-input-batch <input.txt>")
            exit(2)
        }
        let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
        let url = URL(fileURLWithPath: inputPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("failed to read \(inputPath)")
            exit(2)
        }
        for sentence in text.split(whereSeparator: \.isNewline).map(String.init).filter({ !$0.isEmpty }) {
            if let payload = buildProbeInputPayload(sentence: sentence, reverseMap: reverseMap) {
                _ = printJSONObjectLine(payload)
            } else {
                _ = printJSONObjectLine([
                    "sentence": sentence,
                    "resolved": false,
                ])
            }
        }
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "zh-build-raw-input-batch" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let inputPath = args.first else {
            print("usage: zh-build-raw-input-batch <input.txt>")
            exit(2)
        }
        let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
        let url = URL(fileURLWithPath: inputPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("failed to read \(inputPath)")
            exit(2)
        }
        for sentence in text.split(whereSeparator: \.isNewline).map(String.init).filter({ !$0.isEmpty }) {
            if let payload = buildChineseProbeInputPayload(sentence: sentence, reverseMap: reverseMap) {
                _ = printJSONObjectLine(payload)
            } else {
                _ = printJSONObjectLine([
                    "sentence": sentence,
                    "resolved": false,
                ])
            }
        }
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "en-build-raw-input-batch" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let inputPath = args.first else {
            print("usage: en-build-raw-input-batch <input.txt>")
            exit(2)
        }
        let url = URL(fileURLWithPath: inputPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("failed to read \(inputPath)")
            exit(2)
        }
        for sentence in text.split(whereSeparator: \.isNewline).map(String.init).filter({ !$0.isEmpty }) {
            if let payload = buildEnglishProbeInputPayload(sentence: sentence) {
                _ = printJSONObjectLine(payload)
            } else {
                _ = printJSONObjectLine([
                    "sentence": sentence,
                    "resolved": false,
                ])
            }
        }
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "english-debug" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        let text = args.joined(separator: " ")
        guard let englishBehavior = CompositionLanguageRegistry.targets.first(where: { $0.id == "english-ime" })?.behavior else {
            print("{\"ok\":false,\"error\":\"english target missing\"}")
            exit(2)
        }
        let reverse = englishBehavior.reverseReadings(for: text, reverseMap: [:])
        let sequence = reverse.map { englishBehavior.keySequence(for: $0) } ?? ""
        let candidates = englishBehavior.resolveCandidates(for: text)
        let payload: [String: Any] = [
            "text": text,
            "reverse": reverse as Any,
            "sequence": sequence,
            "candidates": candidates
        ]
        _ = printJSONObjectLine(payload)
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "multi-span-probe" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let raw = args.first, !raw.isEmpty else {
            print("usage: multi-span-probe <raw-buffer>")
            exit(2)
        }
        let merge = UnifiedCompositionEngine.mergeSpanCoverages(for: raw)
        let payload: [String: Any] = [
            "raw": raw,
            "merged_text": merge.mergedText,
            "covered_raw_length": merge.coveredRawLength,
            "full_coverage": merge.fullCoverage,
            "coverages": merge.coverages.map { coverage in
                [
                    "target": coverage.targetID,
                    "start": coverage.start,
                    "end": coverage.end,
                    "text": coverage.text,
                    "score": coverage.score
                ]
            }
        ]
        _ = printJSONObjectLine(payload)
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "dump-ranker-data" {
        SessionCtl.prewarmLexicon()
        let args = Array(CommandLine.arguments.dropFirst(2))
        let outputPath = args.first ?? defaultCLIOutputPath("unifyime-ranker-data.jsonl")
        let mode = args.dropFirst().first ?? "default"
        let batchSize = args.dropFirst(2).first.flatMap(Int.init) ?? 200

        let cases: [SessionCtl.SelfTestCase]
        let source: String
        let tags: [String]

        if FileManager.default.fileExists(atPath: mode) {
            let text = (try? String(contentsOfFile: mode, encoding: .utf8)) ?? ""
            let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
            let sentences = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            cases = sentences.map { SessionCtl.SelfTestCase(sentence: $0, readings: CompositionLanguageRegistry.primary.reverseReadings(for: $0, reverseMap: reverseMap)) }
            source = "file_\(URL(fileURLWithPath: mode).deletingPathExtension().lastPathComponent)"
            tags = ["file"]
        } else {
            switch mode {
            case "short-words":
                cases = SessionCtl.generateShortWordTestCases(batchSize: batchSize)
                source = "selftest_short_words"
                tags = ["short_word"]
            case "short-sentences":
                cases = SessionCtl.generateShortSentenceTestCases(batchSize: batchSize)
                source = "selftest_short_sentences"
                tags = ["short_sentence"]
            case "dynamic":
                cases = SessionCtl.generateDynamicSelfTestCases(batchSize: batchSize)
                source = "selftest_dynamic"
                tags = ["dynamic"]
            case "article":
                cases = [SessionCtl.generateShortArticleCase()]
                source = "selftest_short_article"
                tags = ["article"]
            default:
                cases = SessionCtl.defaultSelfTestCases()
                source = "selftest_default"
                tags = ["default"]
            }
        }

        let result = SessionCtl.dumpRankerData(cases: cases, source: source, outputPath: outputPath, tags: tags)
        print("dumped_samples=\(result.sampleCount)")
        print("resolved_cases=\(result.resolvedCases)")
        print("total_cases=\(result.totalCases)")
        print("output=\(outputPath)")
        exit(result.sampleCount > 0 ? 0 : 2)
    }

    if CommandLine.arguments.dropFirst().first == "ranker-status" {
        SessionCtl.prewarmLexicon()
        print(SessionCtl.candidateRanker.debugStatus())

        let context = CandidateSelectionContext(
            languageID: SessionCtl.traditionalChineseProvider.languageID,
            allTokens: [
                InputToken(languageID: SessionCtl.traditionalChineseProvider.languageID, rawValue: "ㄋㄧ"),
                InputToken(languageID: SessionCtl.traditionalChineseProvider.languageID, rawValue: "ㄒㄧㄢˋㄗㄞˋ")
            ],
            combinedToken: "ㄒㄧㄢˋㄗㄞˋ",
            spanLength: 1,
            precedingValues: ["你"],
            followingTokens: [],
            focusedToken: "ㄒㄧㄢˋㄗㄞˋ"
        )
        let candidates = ["現在", "西岸在", "現再"]
        let units = candidates.enumerated().map { index, value in
            CandidateUnit(
                languageID: SessionCtl.traditionalChineseProvider.languageID,
                surface: value,
                readingOrToken: "ㄒㄧㄢˋㄗㄞˋ",
                spanStart: 1,
                spanLength: 1,
                providerScore: Double(-index),
                baseRank: index
            )
        }
        let scores = SessionCtl.candidateRanker.scores(units: units, context: context)
        for (unit, score) in zip(units, scores) {
            print("candidate=\(unit.surface) score=\(score)")
        }
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "probe-reading" {
        SessionCtl.prewarmLexicon()
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard !args.isEmpty else {
            print("usage: probe-reading <reading1> [reading2 ...]")
            exit(2)
        }
        let joined = args.joined()
        print("tokens=\(args.joined(separator: " / "))")
        print("joined=\(joined)")
        let exact = CompositionLanguageRegistry.primary.resolveCandidates(for: joined)
        print("exact_candidates=\(exact.joined(separator: " | "))")
        let walked = UnifiedCompositionEngine.resolveWalk(args)
        print("walk_segments=\(walked.map { "\($0.reading)=>\($0.value)" }.joined(separator: " || "))")
        print("walk_output=\(walked.map { $0.value }.joined())")
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "walk-debug" {
        SessionCtl.prewarmLexicon()
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard !args.isEmpty else {
            print("usage: walk-debug <sentence or reading-file-path>")
            exit(2)
        }

        let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
        let sentence = args.joined(separator: " ")
        guard let readings = CompositionLanguageRegistry.primary.reverseReadings(for: sentence, reverseMap: reverseMap) else {
            print("sentence=\(sentence)")
            print("reverse_readings=unavailable")
            exit(2)
        }

        let syllables = readings.flatMap(UnifiedCompositionEngine.splitReadingIntoSyllables)
        let walked = UnifiedCompositionEngine.resolveWalk(syllables)
        print("sentence=\(sentence)")
        print("readings=\(readings.joined(separator: " / "))")
        print("syllables=\(syllables.joined(separator: " / "))")
        for segment in walked {
            let candidates = CompositionLanguageRegistry.primary.resolveCandidates(for: segment.reading)
            print("segment start=\(segment.start) length=\(segment.length) reading=\(segment.reading) value=\(segment.value)")
            print("candidates=\(Array(candidates.prefix(visibleCandidateLimit)).joined(separator: "|"))")
        }
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "sentence-reranker-status" {
        let ranker = CoreMLSentenceReranker()
        print(ranker.debugStatus())
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "sentence-reranker-score" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let path = args.first else {
            print("usage: sentence-reranker-score <example.json>")
            exit(2)
        }
        let example: SentenceRerankerExample
        do {
            example = try loadSentenceRerankerExample(from: path)
        } catch {
            reportCLIError(error, path: path)
        }
        let ranker = CoreMLSentenceReranker()
        let context = example.context ?? SentenceRerankerContext()
        let scored = example.candidates.map { candidate in
            let sentenceScore = ranker.score(path: candidate, context: context)
            return SentenceRerankerScore(
                text: candidate.text,
                localScore: candidate.localScore,
                sentenceScore: sentenceScore,
                finalScore: candidate.localScore + sentenceScore
            )
        }.sorted { $0.finalScore > $1.finalScore }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(scored)
        } catch {
            reportCLIError(error, path: "sentence-reranker-score output")
        }
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "sentence-reranker-probe" {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard let path = args.first else {
            print("usage: sentence-reranker-probe <example.json>")
            exit(2)
        }
        let example: SentenceRerankerExample
        do {
            example = try loadSentenceRerankerExample(from: path)
        } catch {
            reportCLIError(error, path: path)
        }
        let encoder = SentenceFeatureEncoder()
        let context = example.context ?? SentenceRerankerContext()
        for candidate in example.candidates {
            let features = encoder.encode(path: candidate, context: context)
            print("=== \(candidate.text) ===")
            print("local_score=\(candidate.localScore)")
            print("feature_dimension=\(features.count)")
            print(features.map { String(format: "%.6f", $0) }.joined(separator: ","))
        }
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "dump-sentence-reranker-data" {
        SessionCtl.prewarmLexicon()
        let args = Array(CommandLine.arguments.dropFirst(2))
        let outputPath = args.first ?? defaultCLIOutputPath("unifyime-sentence-reranker.jsonl")
        let mode = args.dropFirst().first ?? "default"
        let batchSize = args.dropFirst(2).first.flatMap(Int.init) ?? 100
        let topPaths = args.dropFirst(3).first.flatMap(Int.init) ?? 8
        let topCandidatesPerSpan = args.dropFirst(4).first.flatMap(Int.init) ?? 6

        let cases: [SessionCtl.SelfTestCase]
        let source: String
        let tags: [String]

        if FileManager.default.fileExists(atPath: mode) {
            let text = (try? String(contentsOfFile: mode, encoding: .utf8)) ?? ""
            let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
            let sentences = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            cases = sentences.map { SessionCtl.SelfTestCase(sentence: $0, readings: CompositionLanguageRegistry.primary.reverseReadings(for: $0, reverseMap: reverseMap)) }
            source = "sentence_file_\(URL(fileURLWithPath: mode).deletingPathExtension().lastPathComponent)"
            tags = ["file", "sentence_reranker"]
        } else {
            switch mode {
            case "short-words":
                cases = SessionCtl.generateShortWordTestCases(batchSize: batchSize)
                source = "sentence_short_words"
                tags = ["short_word", "sentence_reranker"]
            case "short-sentences":
                cases = SessionCtl.generateShortSentenceTestCases(batchSize: batchSize)
                source = "sentence_short_sentences"
                tags = ["short_sentence", "sentence_reranker"]
            case "dynamic":
                cases = SessionCtl.generateDynamicSelfTestCases(batchSize: batchSize)
                source = "sentence_dynamic"
                tags = ["dynamic", "sentence_reranker"]
            case "article":
                cases = [SessionCtl.generateShortArticleCase()]
                source = "sentence_short_article"
                tags = ["article", "sentence_reranker"]
            default:
                cases = SessionCtl.defaultSelfTestCases()
                source = "sentence_default"
                tags = ["default", "sentence_reranker"]
            }
        }

        let result = SessionCtl.dumpSentenceRerankerData(
            cases: cases,
            source: source,
            outputPath: outputPath,
            topPaths: topPaths,
            topCandidatesPerSpan: topCandidatesPerSpan,
            tags: tags
        )
        print("dumped_groups=\(result.sampleCount)")
        print("resolved_cases=\(result.resolvedCases)")
        print("total_cases=\(result.totalCases)")
        print("output=\(outputPath)")
        exit(result.sampleCount > 0 ? 0 : 2)
    }

    if CommandLine.arguments.dropFirst().first == "ab-ranker-check" {
        SessionCtl.prewarmLexicon()
        let args = Array(CommandLine.arguments.dropFirst(2))
        let outputPath = args.first ?? defaultCLIOutputPath("unifyime-ranker-ab.json")
        let mode = args.dropFirst().first ?? "default"
        let batchSize = args.dropFirst(2).first.flatMap(Int.init) ?? 20
        let cases: [SessionCtl.SelfTestCase]

        if FileManager.default.fileExists(atPath: mode) {
            let text = (try? String(contentsOfFile: mode, encoding: .utf8)) ?? ""
            let reverseMap = CompositionLanguageRegistry.primary.buildReverseLexicon()
            let sentences = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            cases = sentences.map {
                SessionCtl.SelfTestCase(
                    sentence: $0,
                    readings: CompositionLanguageRegistry.primary.reverseReadings(for: $0, reverseMap: reverseMap)
                )
            }
        } else {
            switch mode {
            case "short-words":
                cases = SessionCtl.generateShortWordTestCases(batchSize: batchSize)
            case "short-sentences":
                cases = SessionCtl.generateShortSentenceTestCases(batchSize: batchSize)
            case "dynamic":
                cases = SessionCtl.generateDynamicSelfTestCases(batchSize: batchSize)
            default:
                cases = SessionCtl.defaultSelfTestCases()
            }
        }

        SessionCtl.dumpRankerAB(cases: cases, outputPath: outputPath)
        print("output=\(outputPath)")
        print("cases=\(cases.count)")
        exit(0)
    }

    if CommandLine.arguments.dropFirst().first == "canonical-probe" {
        SessionCtl.prewarmChinesePredictionRuntime()
        let positiveCases: [(input: String, expectedCanonical: String, expectedChar: String)] = [
            ("ㄧㄐㄢˋ", "ㄐㄧㄢˋ", "見"),
            ("ㄢㄐㄧˋ", "ㄐㄧㄢˋ", "見"),
            ("ㄡㄍˇ", "ㄍㄡˇ", "狗"),
            ("ㄡㄍ", "ㄍㄡ", "溝"),
            ("ㄣㄕ", "ㄕㄣ", "身"),
            ("ㄤㄓ", "ㄓㄤ", "張")
        ]
        var passed = 0
        var total = 0
        print("=== 注音亂序自動正規化容錯測試（正向案例）===")
        for (input, expectedCanonical, expectedChar) in positiveCases {
            total += 1
            let canonical = BopomofoCanonicalizer.canonicalize(syllable: input)
            let candidates = SessionCtl.resolveCandidates(for: input)
            let match = candidates.contains(expectedChar)
            let canonicalMatch = (canonical == expectedCanonical)
            let valid = BopomofoCanonicalizer.isPhonotacticallyValid(canonical)
            let evidence = SessionCtl.hasEvidence(forSyllable: canonical)
            if match && canonicalMatch && valid && evidence {
                print("PASS: 輸入 [\(input)] -> 正規化 [\(canonical)] (合法: \(valid), 證據: \(evidence)) -> 候選命中 [\(expectedChar)]")
                passed += 1
            } else {
                print("FAIL: 輸入 [\(input)] -> 正規化 [\(canonical)] (預期 \(expectedCanonical)) -> 候選命中: \(match), 合法: \(valid), 證據: \(evidence)")
            }
        }

        print("\n=== 音韻合法性與詞庫雙重校驗測試（反向防護案例）===")
        let negativePhonotacticCases: [String] = [
            "ㄅㄦ", // 兒韻不可帶聲母
            "ㄐㄚ", // 舌面音不可直接接開口呼
            "ㄍㄩ", // 舌根音不可接撮口呼
            "ㄈㄧ", // 唇齒音不可接齊齒呼
            "ㄓㄩ", // 翹舌音不可接撮口呼
            "ㄉㄩ", // 舌尖音不可接撮口呼
        ]
        for syllable in negativePhonotacticCases {
            total += 1
            let isValid = BopomofoCanonicalizer.isPhonotacticallyValid(syllable)
            if !isValid {
                print("PASS: 非法音節 [\(syllable)] 正確被音韻規則判定為無效 (isPhonotacticallyValid = false)")
                passed += 1
            } else {
                print("FAIL: 非法音節 [\(syllable)] 未被攔截 (isPhonotacticallyValid = true)")
            }
        }

        let negativeMergeCases: [(current: String, incoming: String, desc: String)] = [
            ("ㄦ", "ㄅ", "ㄦ後接ㄅ（非同一音節，嚴禁重排為ㄅㄦ）"),
            ("ㄚ", "ㄐ", "ㄚ後接ㄐ（非同一音節，嚴禁重排為ㄐㄚ）"),
            ("ㄧ", "ㄍ", "ㄧ後接ㄍ（非同一音節，ㄍ與ㄧ不合，嚴禁重排為ㄍㄧ）"),
        ]
        for c in negativeMergeCases {
            total += 1
            let canReorder = BopomofoCanonicalizer.canReorderIntoSingleSyllable(
                current: c.current,
                incoming: c.incoming,
                hasEvidence: { SessionCtl.hasEvidence(forSyllable: $0) }
            )
            if !canReorder {
                print("PASS: [\(c.current)] + [\(c.incoming)] (\(c.desc)) 正確拒絕合併 (canReorder = false)")
                passed += 1
            } else {
                print("FAIL: [\(c.current)] + [\(c.incoming)] 誤判為可合併 (canReorder = true)")
            }
        }

        print("\n總計結果: \(passed)/\(total) 通過")
        exit(passed == total ? 0 : 1)
    }

    if CommandLine.arguments.dropFirst().first == "fat-finger-probe" {
        SessionCtl.prewarmChinesePredictionRuntime()
        print("=== 鄰近鍵位盲打容錯測試（Fat-Finger Probe）===")
        let testCases: [(typo: String, expectedWord: String, desc: String)] = [
            ("ㄍㄧㄢˋ", "見", "手滑將「ㄐ(r)」按成相鄰鍵「ㄍ(e)」"),
            ("ㄔㄧㄢˋ", "見", "手滑將「ㄐ(r)」按成相鄰鍵「ㄔ(t)」"),
            ("ㄐㄨㄢˋ", "卷", "手滑將「ㄩ(m)」按成相鄰鍵「ㄨ(j)」"),
        ]
        var passed = 0
        for tc in testCases {
            let candidates = SessionCtl.resolveCandidates(for: tc.typo)
            let match = candidates.contains(tc.expectedWord)
            if match {
                print("PASS: 輸入按偏讀音 [\(tc.typo)] (\(tc.desc)) -> 容錯成功命中 [\(tc.expectedWord)] (前5候選: \(Array(candidates.prefix(5))))")
                passed += 1
            } else {
                print("FAIL: 輸入按偏讀音 [\(tc.typo)] -> 未命中 [\(tc.expectedWord)] (前5候選: \(Array(candidates.prefix(5))))")
            }
        }
        print("結果: \(passed)/\(testCases.count) 通過")
        exit(passed == testCases.count ? 0 : 1)
    }

    let bundlePath = Bundle.main.bundleURL.path
    let installedInputMethodsPath = (FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Input Methods", isDirectory: true)
        .path as NSString)

    if CommandLine.arguments.count == 1,
       !(bundlePath as NSString).hasPrefix(installedInputMethodsPath as String) {
        print("行雲_繁-A app test/debug UI 已移除，請改用 CLI selftest。")
        exit(0)
    }

    guard
        let bundleID = Bundle.main.bundleIdentifier,
        let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
    else {
        NSLog("Cannot resolve IMKServer bundle metadata.")
        exit(1)
    }

    appendRuntimeTrace("imk.server.init bundleID=\(bundleID) connection=\(connectionName) bundlePath=\(bundlePath) \(runtimeInputSourceMetadata())")
    guard let server = IMKServer(name: connectionName, bundleIdentifier: bundleID) else {
        NSLog("Cannot initialize IMKServer.")
        exit(1)
    }
    retainedIMKServer = server
    appendRuntimeTrace("imk.server.ready bundleID=\(bundleID) connection=\(connectionName) \(runtimeInputSourceMetadata())")

    SessionCtl.prewarmRuntime(async: true)
    let app = NSApplication.shared
    let lifecycleDelegate = IMEApplicationDelegate()
    retainedIMEApplicationDelegate = lifecycleDelegate
    app.delegate = lifecycleDelegate
    NSApp.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        BasicCandidatePanelController.shared.prewarm()
    }
    NSApp.run()
}

@main
struct UnifyIMEAppMain {
    static func main() {
        runUnifyIMEAppEntry()
    }
}
