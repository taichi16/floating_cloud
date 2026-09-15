import Foundation

/// 供輸入事件純路由使用的修飾鍵集合，不依賴 AppKit，方便 CLI 回歸測試。
struct SymbolShortcutModifiers: OptionSet, Hashable {
    let rawValue: UInt

    static let shift = Self(rawValue: 1 << 0)
    static let command = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let option = Self(rawValue: 1 << 3)
    static let function = Self(rawValue: 1 << 4)
    static let capsLock = Self(rawValue: 1 << 5)
    static let numericPad = Self(rawValue: 1 << 6)
    static let help = Self(rawValue: 1 << 7)
    static let other = Self(rawValue: 1 << 8)
}

enum SymbolShortcutDecision: Equatable {
    case passThrough
    case insertComposingSymbol(symbol: String, hasComposition: Bool)
}

/// 標點以單一組字單位保存；顯示形式可替換，來源與位置維持不變。
enum SymbolCandidates {
    static let groups: [[String]] = [
        ["，", "、", ",", "﹐", "﹑"], ["。", "．", ".", "·", "•"],
        ["？", "?", "﹖"], ["！", "!", "﹗"], ["：", ":", "﹕"], ["；", ";", "﹔"],
        ["（", "(", "〔", "【", "〈", "《"], ["）", ")", "〕", "】", "〉", "》"],
        ["「", "『", "“", "‘", "［", "[", "｛", "{"],
        ["」", "』", "”", "’", "］", "]", "｝", "}"],
        ["”", "“", "＂", "\""],
        ["—", "–", "－", "-", "…", "⋯", "＿", "_"],
        ["＝", "=", "≠", "≈", "≡", "≤", "≥"],
        ["＾", "^"],
        ["＋", "+", "±", "×", "÷", "／", "/", "％", "%"],
        ["＠", "@", "＃", "#", "＆", "&", "＊", "*", "＄", "$", "￥", "€", "￡"]
    ]

    static func values(for reading: String) -> [String] {
        guard let group = groups.first(where: { $0.contains(reading) }) else { return [] }
        return [reading] + group.filter { $0 != reading }
    }

    /// 由鍵盤事件產生的字元轉成組字內標點。修飾鍵策略由
    /// `decideShiftedPunctuation` 統一決定，避免在 SessionCtl 內分散判斷。
    static let directPunctuationMap: [String: String] = [
        "?": "？",
        "!": "！",
        "@": "＠",
        "#": "＃",
        "$": "＄",
        "%": "％",
        "^": "＾",
        "&": "＆",
        "*": "＊",
        ":": "：",
        ";": "；",
        "(": "（",
        ")": "）",
        "[": "「",
        "]": "」",
        "{": "『",
        "}": "』",
        "<": "，",
        ">": "。",
        "\"": "”",
        "'": "、",
        "\\": "、"
    ]

    /// Shift 標點是正式輸入路徑。Command／Control／Option／Function 組合
    /// 均保留給 macOS 或前景應用程式，不在輸入法內消耗事件。
    static func decideShiftedPunctuation(
        characters: String?,
        modifiers: SymbolShortcutModifiers,
        hasComposition: Bool
    ) -> SymbolShortcutDecision {
        guard modifiers == [.shift],
              let characters,
              characters.count == 1,
              let symbol = directPunctuationMap[characters] else {
            return .passThrough
        }
        return .insertComposingSymbol(symbol: symbol, hasComposition: hasComposition)
    }

    static func insert(_ symbol: String, state: inout UnifiedCompositionState) {
        guard !values(for: symbol).isEmpty else { return }
        UnifiedCompositionEngine.finalizePendingReadingForCommit(state: &state)
        let index = state.currentCompositionCursorIndex()
        state.readings = state.allReadings
        state.trailingReadings = []
        state.rebaseOverrides(replacing: index..<index, insertedCount: 1, insertedRawInputs: [symbol])
        state.readings.insert(symbol, at: index)
        let key = CompositionSegmentKey(start: index, length: 1, reading: symbol)
        state.segmentOverrides[key] = symbol
        state.explicitLockedKeys.insert(key)
        state.compositionCursorIndex = index + 1
        state.selectedCandidateIndex = 0
        state.rawReadingSymbols = state.readings.joined().map(String.init)
    }
}
