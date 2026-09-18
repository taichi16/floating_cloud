import AppKit
import Carbon
import InputMethodKit

// MARK: - Client Resolution Policy

enum IMKClientResolutionDecision: Equatable {
    case callback
    case storedFallback
    case unavailable
}

/// IMK callback 的 client 應屬於目前 controller 的單一輸入 session。
/// callback 缺少 client 時，只有在 session 仍活躍且 controller client 識別一致時才可 fallback。
enum IMKClientResolutionPolicy {
    static func decide(
        sessionIsActive: Bool,
        callbackProvided: Bool,
        callbackIsIMKTextInput: Bool,
        callbackSessionID: String?,
        activeSessionID: String?,
        storedSessionID: String?
    ) -> IMKClientResolutionDecision {
        guard sessionIsActive,
              let activeSessionID,
              !activeSessionID.isEmpty else {
            return .unavailable
        }

        if callbackProvided, callbackIsIMKTextInput {
            guard callbackSessionID == activeSessionID else { return .unavailable }
            return .callback
        }

        guard !callbackProvided,
              !callbackIsIMKTextInput,
              storedSessionID == activeSessionID else {
            return .unavailable
        }
        return .storedFallback
    }
}

// MARK: - Application Shortcut Policy

enum IMKApplicationShortcutDecision: Equatable {
    case continueInputMethod
    case passThrough
    case commitCompositionThenPassThrough
}

/// Command／Control／Option 等 application modifier 絕不在輸入法內消耗。
/// 有組字時先嘗試提交，再回傳 false 讓前景 App 繼續處理原快捷鍵。
enum IMKApplicationShortcutPolicy {
    private static let applicationModifiers: SymbolShortcutModifiers = [
        .command, .control, .option, .help, .other
    ]

    static func decide(
        modifiers: SymbolShortcutModifiers,
        hasComposition: Bool
    ) -> IMKApplicationShortcutDecision {
        guard !modifiers.intersection(applicationModifiers).isEmpty else {
            return .continueInputMethod
        }
        return hasComposition ? .commitCompositionThenPassThrough : .passThrough
    }
}

// MARK: - Replacement Range Policy

/// IMKTextInput 的 replacementRange 統一由此策略產生，避免把 marked text 內部座標
/// 或另一個 client 的 range 傳給目前輸入 session。
enum IMKReplacementRangePolicy {
    static let currentInsertionPoint = NSRange(location: NSNotFound, length: 0)

    static func forMarkedTextUpdate() -> NSRange {
        currentInsertionPoint
    }

    static func forClearingMarkedText(_ markedRange: NSRange) -> NSRange {
        isUsableDocumentRange(markedRange) ? markedRange : currentInsertionPoint
    }

    static func forCommit(_ markedRange: NSRange) -> NSRange {
        isUsableDocumentRange(markedRange) ? markedRange : currentInsertionPoint
    }

    private static func isUsableDocumentRange(_ range: NSRange) -> Bool {
        range.location != NSNotFound
            && range.length != NSNotFound
            && range.location >= 0
            && range.length >= 0
    }
}

// MARK: - IMK Client Transport Layer

/// 負責與 `IMKTextInput` / `NSTextInputClient` 進行所有底層文字與幾何交互。
/// 封裝安全邊界（越界防禦、64-bit 溢位防護、非破壞性清空、候選窗幾何定位）。
final class IMKClientTransport {
    static let shared = IMKClientTransport()

    private init() {}

    /// 取得目前輸入框的標記文字範圍並轉為安全的 commit replacementRange
    func currentMarkedRange(for client: IMKTextInput) -> NSRange {
        IMKReplacementRangePolicy.forCommit(client.markedRange())
    }

    /// 安全提交已確認文字至客戶端
    func insertText(
        _ text: String,
        replacementRange: NSRange = IMKReplacementRangePolicy.currentInsertionPoint,
        using client: IMKTextInput,
        sessionID: String = ""
    ) {
        guard !text.isEmpty else { return }
        client.insertText(text, replacementRange: replacementRange)
        appendRuntimeTrace("transport.insertText session=\(sessionID) replacementRange=\(NSStringFromRange(replacementRange)) text=\(text)")
    }

    /// 安全更新組字標記文字（Marked Text）
    func setMarkedText(
        _ marked: NSAttributedString,
        selectionRange: NSRange,
        replacementRange: NSRange = IMKReplacementRangePolicy.forMarkedTextUpdate(),
        using client: IMKTextInput,
        sessionID: String = ""
    ) {
        appendRuntimeTrace("transport.setMarkedText session=\(sessionID) selection=\(NSStringFromRange(selectionRange)) replacementRange=\(NSStringFromRange(replacementRange)) length=\(marked.length)")
        client.setMarkedText(marked, selectionRange: selectionRange, replacementRange: replacementRange)
    }

    /// 防禦性清空組字標記文字（避免在無組字或異常狀態下洗掉使用者其他選區）
    func clearMarkedText(
        using client: IMKTextInput,
        sessionID: String = ""
    ) {
        let empty = NSRange(location: 0, length: 0)
        let currentRange = client.markedRange()
        let replacementRange = IMKReplacementRangePolicy.forClearingMarkedText(currentRange)
        appendRuntimeTrace("transport.clearMarkedText session=\(sessionID) markedRange=\(NSStringFromRange(currentRange)) replacementRange=\(NSStringFromRange(replacementRange))")
        if currentRange.location != NSNotFound && currentRange.length > 0 {
            client.setMarkedText("", selectionRange: empty, replacementRange: replacementRange)
        }
        if let textClient = client as? NSTextInputClient {
            textClient.unmarkText()
        }
    }

    /// 安全取消標記狀態（Unmark）
    func unmarkText(using client: IMKTextInput) {
        if let textClient = client as? NSTextInputClient {
            textClient.unmarkText()
        }
    }

    /// 根據目前游標位置計算候選字視窗在螢幕上的幾何錨點
    func candidateAnchor(for client: IMKTextInput, cursorIndex: Int) -> CGPoint? {
        if let textClient = client as? NSTextInputClient {
            var actual = NSRange(location: NSNotFound, length: 0)
            let targetRange = NSRange(location: max(cursorIndex, 0), length: 0)
            let rect = textClient.firstRect(forCharacterRange: targetRange, actualRange: &actual)
            appendRuntimeTrace("anchor firstRect cursor=\(cursorIndex) target=\(NSStringFromRange(targetRange)) actual=\(NSStringFromRange(actual)) rect=\(NSStringFromRect(rect))")
            if rect.origin != .zero || rect.size != .zero {
                return CGPoint(x: rect.maxX, y: rect.minY)
            }
        }

        var cursorRect = NSRect(x: 0, y: 0, width: 16, height: 16)
        client.attributes(forCharacterIndex: cursorIndex, lineHeightRectangle: &cursorRect)
        appendRuntimeTrace("anchor attrRect cursor=\(cursorIndex) rect=\(NSStringFromRect(cursorRect))")
        if cursorRect.origin != .zero || cursorRect.size != .zero {
            return CGPoint(x: cursorRect.maxX, y: cursorRect.minY)
        }

        var lineHeightRect = NSRect(x: 0, y: 0, width: 16, height: 16)
        var queryIndex = cursorIndex > 0 ? cursorIndex - 1 : 0
        let originalQueryIndex = queryIndex
        while lineHeightRect.origin.x == 0 && lineHeightRect.origin.y == 0 && queryIndex >= 0 {
            client.attributes(forCharacterIndex: queryIndex, lineHeightRectangle: &lineHeightRect)
            queryIndex -= 1
        }
        appendRuntimeTrace("anchor fallbackRect cursor=\(cursorIndex) queryIndex=\(queryIndex) rect=\(NSStringFromRect(lineHeightRect))")
        guard lineHeightRect.origin != .zero || lineHeightRect.size != .zero else { return nil }
        let resolvedIndex = queryIndex + 1
        let skippedCount = max(0, originalQueryIndex - resolvedIndex + 1)
        let inferredX = lineHeightRect.maxX + CGFloat(skippedCount) * fallbackCandidateAdvanceX
        appendRuntimeTrace("anchor fallbackAdvance cursor=\(cursorIndex) resolvedIndex=\(resolvedIndex) skipped=\(skippedCount) inferredX=\(inferredX)")
        return CGPoint(x: inferredX, y: lineHeightRect.minY)
    }
}
