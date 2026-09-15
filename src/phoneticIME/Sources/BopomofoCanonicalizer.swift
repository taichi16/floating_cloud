import Foundation

/// 處理注音符號成分分類、音韻學合法性檢驗、詞庫證據校驗與標準化重排。
/// 中文音節標準結構：聲母（Consonant）-> 介音（Medial）-> 韻母（Final）-> 聲調（Tone）
enum BopomofoCanonicalizer {
    static let initials = CharacterSet(charactersIn: "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ")
    static let medials = Set(["ㄧ", "ㄨ", "ㄩ"])
    static let finals = Set(["ㄚ", "ㄛ", "ㄜ", "ㄝ", "ㄞ", "ㄟ", "ㄠ", "ㄡ", "ㄢ", "ㄣ", "ㄤ", "ㄥ", "ㄦ"])
    static let tones = CharacterSet(charactersIn: "ˊˇˋ˙")

    // 聲母分類
    static let labialInitials = Set(["ㄅ", "ㄆ", "ㄇ", "ㄈ"])
    static let alveolarNonMedialUInitials = Set(["ㄉ", "ㄊ"]) // 不能接 ㄩ
    static let velarInitials = Set(["ㄍ", "ㄎ", "ㄏ"])
    static let palatalInitials = Set(["ㄐ", "ㄑ", "ㄒ"])
    static let retroflexInitials = Set(["ㄓ", "ㄔ", "ㄕ", "ㄖ"])
    static let dentalInitials = Set(["ㄗ", "ㄘ", "ㄙ"])
    static let syllabicInitials = Set(["ㄓ", "ㄔ", "ㄕ", "ㄖ", "ㄗ", "ㄘ", "ㄙ"])

    // 介音可搭配之韻母表
    static let allowedFinalsAfterMedial: [String: Set<String>] = [
        "ㄧ": Set(["ㄚ", "ㄛ", "ㄝ", "ㄠ", "ㄡ", "ㄢ", "ㄣ", "ㄤ", "ㄥ"]),
        "ㄨ": Set(["ㄚ", "ㄛ", "ㄞ", "ㄟ", "ㄢ", "ㄣ", "ㄤ", "ㄥ"]),
        "ㄩ": Set(["ㄝ", "ㄢ", "ㄣ", "ㄥ"])
    ]

    /// 取得注音符號的標準分類位階 (1: 聲母, 2: 介音, 3: 韻母, 4: 聲調)
    static func rank(for scalar: UnicodeScalar) -> Int {
        if initials.contains(scalar) { return 1 }
        let str = String(scalar)
        if medials.contains(str) { return 2 }
        if finals.contains(str) { return 3 }
        if tones.contains(scalar) { return 4 }
        return 99
    }

    /// 解析音節結構為 (initial, medial, final, tone)
    static func parseComponents(_ syllable: String) -> (initial: String?, medial: String?, final: String?, tone: String?)? {
        var initial: String?
        var medial: String?
        var final: String?
        var tone: String?

        for scalar in syllable.unicodeScalars {
            let s = String(scalar)
            let r = rank(for: scalar)
            switch r {
            case 1:
                if initial != nil { return nil } // 重複聲母
                initial = s
            case 2:
                if medial != nil { return nil } // 重複介音
                medial = s
            case 3:
                if final != nil { return nil } // 重複韻母
                final = s
            case 4:
                if tone != nil { return nil } // 重複聲調
                tone = s
            default:
                return nil // 非注音符號
            }
        }
        return (initial, medial, final, tone)
    }

    /// 嚴格檢查重排後的音節是否符合中文音韻學法則（Phonotactically Valid）
    static func isPhonotacticallyValid(_ syllable: String) -> Bool {
        guard !syllable.isEmpty else { return false }
        guard let (initial, medial, final, _) = parseComponents(syllable) else { return false }

        // 不能為全空
        if initial == nil && medial == nil && final == nil { return false }

        // 1. 兒韻 (ㄦ) 特殊規則：不能有聲母、不能有介音
        if final == "ㄦ" {
            if initial != nil || medial != nil { return false }
            return true
        }

        // 2. 舌面音 (ㄐ, ㄑ, ㄒ) 特殊規則：必須有介音 ㄧ 或 ㄩ，絕不可無介音直接接韻母
        if let ini = initial, palatalInitials.contains(ini) {
            guard let med = medial, med == "ㄧ" || med == "ㄩ" else {
                return false
            }
        }

        // 3. 翹舌音 (ㄓ, ㄔ, ㄕ, ㄖ) 與 平舌音 (ㄗ, ㄘ, ㄙ)：
        // - 絕不可接介音 ㄩ
        // - 絕不可接介音 ㄧ (現代國語無 ㄓㄧ、ㄗㄧ)
        if let ini = initial, (retroflexInitials.contains(ini) || dentalInitials.contains(ini)) {
            if medial == "ㄩ" || medial == "ㄧ" {
                return false
            }
        }

        // 4. 唇音 (ㄅ, ㄆ, ㄇ, ㄈ)：
        // - 絕不可接介音 ㄩ
        // - ㄈ 絕不可接介音 ㄧ
        // - 唇音不與介音 ㄨ 組合帶韻母 (無 ㄅㄨㄚ、ㄅㄨㄢ 等)
        if let ini = initial, labialInitials.contains(ini) {
            if medial == "ㄩ" { return false }
            if ini == "ㄈ" && medial == "ㄧ" { return false }
            if medial == "ㄨ" && final != nil { return false }
        }

        // 5. 舌尖中音 (ㄉ, ㄊ)：絕不可接介音 ㄩ
        if let ini = initial, alveolarNonMedialUInitials.contains(ini) {
            if medial == "ㄩ" { return false }
        }

        // 6. 舌根音 (ㄍ, ㄎ, ㄏ)：絕不可接介音 ㄧ 或 ㄩ
        if let ini = initial, velarInitials.contains(ini) {
            if medial == "ㄧ" || medial == "ㄩ" { return false }
        }

        // 7. 介音與韻母搭配合法性
        if let med = medial, let fin = final {
            guard let allowed = allowedFinalsAfterMedial[med], allowed.contains(fin) else {
                return false
            }
        }

        // 8. 單獨聲母（無介音且無韻母）：只有成音節聲母 (ㄓ, ㄔ, ㄕ, ㄖ, ㄗ, ㄘ, ㄙ) 可以獨立成字
        if let ini = initial, medial == nil, final == nil {
            return syllabicInitials.contains(ini)
        }

        return true
    }

    /// 將一個可能亂序的單音節字串，重新依照「聲母 -> 介音 -> 韻母 -> 聲調」標準順序重排。
    /// 例如："ㄧㄐㄢˋ" -> "ㄐㄧㄢˋ"，"ㄡㄍˇ" -> "ㄍㄡˇ"
    static func canonicalize(syllable: String) -> String {
        guard syllable.count > 1 else { return syllable }
        let scalars = Array(syllable.unicodeScalars)
        
        let sorted = scalars.sorted { s1, s2 in
            let r1 = rank(for: s1)
            let r2 = rank(for: s2)
            return r1 < r2
        }
        return String(String.UnicodeScalarView(sorted))
    }

    /// 判斷目前字串與即將進來的符號，是否屬於「同一個單字的快鍵搶拍／亂序組合」。
    /// 雙重驗證：
    /// 1. 音韻學結構與相容性檢查（isPhonotacticallyValid）
    /// 2. 詞庫存在性證據檢查（hasEvidence）
    static func canReorderIntoSingleSyllable(
        current: String,
        incoming: String,
        hasEvidence: ((String) -> Bool)? = nil
    ) -> Bool {
        guard !current.isEmpty, !incoming.isEmpty else { return false }
        guard incoming.unicodeScalars.count == 1, let incomingScalar = incoming.unicodeScalars.first else { return false }
        
        let allCurrent = current.unicodeScalars
        if allCurrent.contains(where: { tones.contains($0) }) { return false }

        let incomingRank = rank(for: incomingScalar)
        guard incomingRank <= 4 else { return false }

        // 統計各類別已有數量
        var initialCount = 0
        var medialCount = 0
        var finalCount = 0
        var toneCount = 0

        for s in allCurrent {
            switch rank(for: s) {
            case 1: initialCount += 1
            case 2: medialCount += 1
            case 3: finalCount += 1
            case 4: toneCount += 1
            default: break
            }
        }

        let structuralMatch: Bool
        switch incomingRank {
        case 1:
            structuralMatch = (initialCount == 0 && medialCount <= 1 && finalCount <= 1)
        case 2:
            structuralMatch = (medialCount == 0)
        case 3:
            structuralMatch = (finalCount == 0)
        case 4:
            structuralMatch = (toneCount == 0)
        default:
            structuralMatch = false
        }
        guard structuralMatch else { return false }

        // 模擬重排結果
        let simulated = canonicalize(syllable: current + incoming)

        // 雙重驗證 1：音韻學合法性
        guard isPhonotacticallyValid(simulated) else {
            return false
        }

        // 雙重驗證 2：詞庫存在性證據（若提供）
        if let hasEvidence = hasEvidence {
            guard hasEvidence(simulated) else {
                return false
            }
        }

        return true
    }
}
