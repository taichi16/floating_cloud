import Foundation

/// 實體鍵盤鄰近鍵位盲打容錯（Fat-Finger / QWERTY Neighbor Key Correction）
/// 針對大千式標準注音鍵盤的實體幾何距離（Chebyshev / Manhattan Distance = 1）
/// 在使用者手滑按偏鄰近鍵時，智慧推導修正候選字。
public enum FatFingerCorrector {
    
    /// 大千式注音鍵盤實體鄰近鍵對照表（鍵距 = 1）
    /// 包含上下左右與對角線物理相鄰之注音符號
    public static let physicalNeighborMap: [Character: [Character]] = [
        // 數字列 (Row 1)
        "ㄅ": ["ㄉ", "ㄆ"],
        "ㄉ": ["ㄅ", "ˇ", "ㄊ", "ㄆ"],
        "ˇ": ["ㄉ", "ˋ", "ㄍ", "ㄊ"],
        "ˋ": ["ˇ", "ㄓ", "ㄐ", "ㄍ"],
        "ㄓ": ["ˋ", "ˊ", "ㄔ", "ㄐ"],
        "ˊ": ["ㄓ", "˙", "ㄗ", "ㄔ"],
        "˙": ["ˊ", "ㄚ", "ㄧ", "ㄗ"],
        "ㄚ": ["˙", "ㄞ", "ㄛ", "ㄧ"],
        "ㄞ": ["ㄚ", "ㄢ", "ㄟ", "ㄛ"],
        "ㄢ": ["ㄞ", "ㄦ", "ㄣ", "ㄟ"],
        "ㄦ": ["ㄢ", "ㄣ"],

        // QWERTY 列 (Row 2: 同列左右相鄰最優先)
        "ㄆ": ["ㄊ", "ㄅ", "ㄇ", "ㄉ", "ㄋ"],
        "ㄊ": ["ㄆ", "ㄍ", "ㄋ", "ㄉ", "ˇ", "ㄇ", "ㄎ"],
        "ㄍ": ["ㄐ", "ㄊ", "ㄎ", "ˇ", "ˋ", "ㄋ", "ㄑ"],
        "ㄐ": ["ㄍ", "ㄔ", "ㄑ", "ˋ", "ㄓ", "ㄎ", "ㄕ"],
        "ㄔ": ["ㄐ", "ㄗ", "ㄕ", "ㄓ", "ˊ", "ㄑ", "ㄘ"],
        "ㄗ": ["ㄔ", "ㄧ", "ㄘ", "ˊ", "˙", "ㄕ", "ㄨ"],
        "ㄧ": ["ㄗ", "ㄛ", "ㄨ", "˙", "ㄚ", "ㄘ", "ㄜ"],
        "ㄛ": ["ㄧ", "ㄟ", "ㄜ", "ㄚ", "ㄞ", "ㄨ", "ㄠ"],
        "ㄟ": ["ㄛ", "ㄣ", "ㄠ", "ㄞ", "ㄢ", "ㄜ", "ㄤ"],
        "ㄣ": ["ㄟ", "ㄢ", "ㄤ", "ㄦ", "ㄠ"],

        // ASDF 列 (Row 3: 同列左右相鄰最優先)
        "ㄇ": ["ㄋ", "ㄆ", "ㄈ", "ㄊ", "ㄌ"],
        "ㄋ": ["ㄇ", "ㄎ", "ㄊ", "ㄍ", "ㄌ", "ㄈ", "ㄏ"],
        "ㄎ": ["ㄋ", "ㄑ", "ㄍ", "ㄐ", "ㄏ", "ㄌ", "ㄒ"],
        "ㄑ": ["ㄎ", "ㄕ", "ㄐ", "ㄔ", "ㄒ", "ㄏ", "ㄖ"],
        "ㄕ": ["ㄑ", "ㄘ", "ㄔ", "ㄗ", "ㄖ", "ㄒ", "ㄙ"],
        "ㄘ": ["ㄕ", "ㄨ", "ㄗ", "ㄧ", "ㄙ", "ㄖ", "ㄩ"],
        "ㄨ": ["ㄘ", "ㄜ", "ㄧ", "ㄛ", "ㄩ", "ㄙ", "ㄝ"],
        "ㄜ": ["ㄨ", "ㄠ", "ㄛ", "ㄟ", "ㄝ", "ㄩ", "ㄡ"],
        "ㄠ": ["ㄜ", "ㄤ", "ㄟ", "ㄣ", "ㄡ", "ㄝ", "ㄥ"],
        "ㄤ": ["ㄠ", "ㄣ", "ㄥ", "ㄡ"],

        // ZXCV 列 (Row 4: 同列左右相鄰最優先)
        "ㄈ": ["ㄌ", "ㄇ", "ㄋ"],
        "ㄌ": ["ㄈ", "ㄏ", "ㄋ", "ㄎ", "ㄇ"],
        "ㄏ": ["ㄌ", "ㄒ", "ㄎ", "ㄑ", "ㄋ"],
        "ㄒ": ["ㄏ", "ㄖ", "ㄑ", "ㄕ", "ㄎ"],
        "ㄖ": ["ㄒ", "ㄙ", "ㄕ", "ㄘ", "ㄑ"],
        "ㄙ": ["ㄖ", "ㄩ", "ㄘ", "ㄨ", "ㄕ"],
        "ㄩ": ["ㄙ", "ㄝ", "ㄨ", "ㄜ", "ㄘ"],
        "ㄝ": ["ㄩ", "ㄡ", "ㄜ", "ㄠ", "ㄨ"],
        "ㄡ": ["ㄝ", "ㄥ", "ㄠ", "ㄤ", "ㄜ"],
        "ㄥ": ["ㄡ", "ㄤ", "ㄠ"]
    ]

    /// 依據盲打按偏理論，產生距離為 1 且符合音韻結構與詞庫證據的可能讀音
    public static func suggestedReadings(
        for reading: String,
        limitPerPosition: Int = 2,
        totalLimit: Int = 6,
        isPhonotacticallyValid: (String) -> Bool,
        hasEvidence: (String) -> Bool
    ) -> [String] {
        guard !reading.isEmpty else { return [] }
        let chars = Array(reading)
        var candidates: [String] = []

        // 逐一嘗試替換其中 1 個字元為實體鄰近鍵
        for (index, char) in chars.enumerated() {
            guard let neighbors = physicalNeighborMap[char], !neighbors.isEmpty else { continue }
            var perPosCount = 0
            for neighbor in neighbors {
                var mutated = chars
                mutated[index] = neighbor
                let mutatedStr = String(mutated)
                let canonical = BopomofoCanonicalizer.canonicalize(syllable: mutatedStr)

                // 檢查是否合法且有字
                if isPhonotacticallyValid(canonical) && hasEvidence(canonical) {
                    if !candidates.contains(canonical) && canonical != reading {
                        candidates.append(canonical)
                        perPosCount += 1
                        if perPosCount >= limitPerPosition || candidates.count >= totalLimit {
                            break
                        }
                    }
                }
            }
            if candidates.count >= totalLimit {
                break
            }
        }

        return candidates
    }
}
