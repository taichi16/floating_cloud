import AppKit

/// 標點符號與數字小鍵盤處理結果
enum PunctuationHandlingResult {
    /// 無符合符號邏輯，由後續管線處理
    case notHandled
    /// 直接上屏純文字（如數字小鍵盤或 Shift 直通大寫字母）
    case commitRaw(text: String, reason: String)
    /// 插入行內組字符號（如標點符號、雙引號等）
    case insertComposingSymbol(symbol: String)
}

/// 標點符號、數字小鍵盤與修飾鍵直通處理器
final class PunctuationHandler {
    static let shared = PunctuationHandler()
    
    private init() {}
    
    /// 判斷是否為方向鍵或類方向鍵
    func isArrowLike(_ event: NSEvent) -> Bool {
        if (123...126).contains(Int(event.keyCode)) { return true }
        let arrowSet = CharacterSet(charactersIn: String(UnicodeScalar(NSUpArrowFunctionKey)!) + String(UnicodeScalar(NSDownArrowFunctionKey)!) + String(UnicodeScalar(NSLeftArrowFunctionKey)!) + String(UnicodeScalar(NSRightArrowFunctionKey)!))
        if let raw = event.charactersIgnoringModifiers,
           raw.unicodeScalars.contains(where: { arrowSet.contains($0) }) {
            return true
        }
        return false
    }
    
    /// 解析事件對應的符號修飾鍵旗標
    func symbolShortcutModifiers(for event: NSEvent) -> SymbolShortcutModifiers {
        var flags = SymbolShortcutModifiers()
        if event.modifierFlags.contains(.shift) { flags.insert(.shift) }
        if event.modifierFlags.contains(.command) { flags.insert(.command) }
        if event.modifierFlags.contains(.control) { flags.insert(.control) }
        if event.modifierFlags.contains(.option) { flags.insert(.option) }
        if event.modifierFlags.contains(.function) { flags.insert(.function) }
        if event.modifierFlags.contains(.capsLock) { flags.insert(.capsLock) }
        if event.modifierFlags.contains(.numericPad) { flags.insert(.numericPad) }
        if event.modifierFlags.contains(.help) { flags.insert(.help) }
        let knownFlags: NSEvent.ModifierFlags = [
            .shift, .command, .control, .option, .function,
            .capsLock, .numericPad, .help
        ]
        if event.modifierFlags.intersection(knownFlags) != event.modifierFlags {
            flags.insert(.other)
        }
        return flags
    }
    
    /// 處理數字小鍵盤輸入
    func handleNumericPad(event: NSEvent) -> PunctuationHandlingResult {
        guard !isArrowLike(event) else { return .notHandled }
        if symbolShortcutModifiers(for: event) == [.numericPad],
           let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ NumericKeypadInput.allowedCharacters.contains($0) }) {
            return .commitRaw(text: chars, reason: "numericPad")
        }
        return .notHandled
    }
    
    /// 處理直接標點符號映射（如注音鍵盤上的標點）
    func handleDirectPunctuation(event: NSEvent) -> PunctuationHandlingResult {
        guard symbolShortcutModifiers(for: event).isEmpty,
              let chars = event.characters,
              chars.count == 1,
              !isArrowLike(event) else { return .notHandled }
        if let mapped = SymbolCandidates.directPunctuationMap[chars] {
            return .insertComposingSymbol(symbol: mapped)
        }
        return .notHandled
    }
    
    /// 處理 Shift 直通字母輸出
    func handleShiftedPassthrough(event: NSEvent) -> PunctuationHandlingResult {
        guard symbolShortcutModifiers(for: event) == [.shift] else { return .notHandled }
        guard !isArrowLike(event) else { return .notHandled }
        let committed: String?
        if let mapped = qwertyLetterByKeyCode[event.keyCode],
           mapped.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            committed = mapped.uppercased()
        } else if let rawChars = event.charactersIgnoringModifiers?.lowercased(),
                  rawChars.count == 1,
                  rawChars.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) && !CharacterSet.controlCharacters.contains($0) }) {
            committed = rawChars.uppercased()
        } else {
            committed = nil
        }
        guard let committed else { return .notHandled }
        return .commitRaw(text: committed, reason: "shiftedPassthrough")
    }
}
