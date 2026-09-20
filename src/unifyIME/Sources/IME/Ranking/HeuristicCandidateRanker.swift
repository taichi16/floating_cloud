import Foundation

struct HeuristicCandidateRanker: UnifiedCandidateRanker {
    private static func isPureHan(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if !((0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)) {
                return false
            }
        }
        return true
    }

    func score(unit: CandidateUnit, context: CandidateSelectionContext) -> Double {
        let rankPenalty = Double(unit.baseRank * 40)
        let spanBonus = Double(context.spanLength * 1000)
        let phraseBonus = unit.surface.count > 1 ? 120.0 : 0.0
        let exactReadingPenalty = unit.surface == context.combinedToken ? 200.0 : 0.0
        let contextBonus = context.precedingValues.isEmpty ? 0.0 : min(Double(unit.surface.count - 1) * 25.0, 75.0)
        let languageBias = unit.languageID == "zh-Hant" ? 20.0 : 0.0
        let hanBias = Self.isPureHan(unit.surface) ? 10.0 : 0.0
        return spanBonus + phraseBonus + contextBonus + languageBias + hanBias - rankPenalty - exactReadingPenalty
    }
}
