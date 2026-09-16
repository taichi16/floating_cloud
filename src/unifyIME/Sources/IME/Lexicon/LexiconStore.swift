import Foundation

private let lexiconRecallLimit = 20

struct LexiconStore {
    /// Parsed phrase statistics are immutable after construction. Keeping one
    /// reference in the process cache lets all predictors share the same
    /// read-only dictionaries instead of retaining one value copy per caller.
    final class PhraseContextStats {
        let surfaceWeights: [String: Double]
        let readingCandidateCounts: [String: Int]
        let readingBestLengths: [String: Int]

        init(
            surfaceWeights: [String: Double],
            readingCandidateCounts: [String: Int],
            readingBestLengths: [String: Int]
        ) {
            self.surfaceWeights = surfaceWeights
            self.readingCandidateCounts = readingCandidateCounts
            self.readingBestLengths = readingBestLengths
        }

        static let empty = PhraseContextStats(
            surfaceWeights: [:],
            readingCandidateCounts: [:],
            readingBestLengths: [:]
        )
    }

    struct PhraseContextStatsCacheSnapshot {
        let loaded: Bool
        let parseCount: Int
        let cacheHitCount: Int
        let surfaceCount: Int
        let readingCount: Int
    }

    private static let toneMarks = CharacterSet(charactersIn: "ˇˋˊ˙")
    private static let allowedCandidatePunctuation = CharacterSet(charactersIn: "，。、！？：；（）「」『』《》〈〉—…．·")
    private static let bopomofoKeyRows = [
        Array("1234567890-"),
        Array("qwertyuiop"),
        Array("asdfghjkl;"),
        Array("zxcvbnm,./")
    ]
    private static let bopomofoKeyToSymbol: [Character: Character] = [
        "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ",
        "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ",
        "e": "ㄍ", "d": "ㄎ", "c": "ㄏ",
        "r": "ㄐ", "f": "ㄑ", "v": "ㄒ",
        "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
        "y": "ㄗ", "h": "ㄘ", "n": "ㄙ",
        "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
        "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ",
        "9": "ㄞ", "o": "ㄟ", "l": "ㄠ", ".": "ㄡ",
        "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ",
        "-": "ㄦ",
        "3": "ˇ", "4": "ˋ", "6": "ˊ", "7": "˙"
    ]
    final class SharedLexiconCore {
        let phraseCandidateMap: [String: [String]]
        let stats: PhraseContextStats
        let baseCommonCharacterMap: [String: [String]]
        let baseReadingPrefixes: Set<String>
        let version: String

        init(
            phraseCandidateMap: [String: [String]],
            stats: PhraseContextStats,
            baseCommonCharacterMap: [String: [String]],
            baseReadingPrefixes: Set<String>,
            version: String
        ) {
            self.phraseCandidateMap = phraseCandidateMap
            self.stats = stats
            self.baseCommonCharacterMap = baseCommonCharacterMap
            self.baseReadingPrefixes = baseReadingPrefixes
            self.version = version
        }
    }

    private static let bopomofoNeighborMap = buildBopomofoNeighborMap()
    private static let candidateCacheLock = NSLock()
    private static let candidateCacheCapacity = 512
    private static var candidateCache: [String: [String]] = [:]
    private static var candidateCacheOrder: [String] = []

    private static let coreLock = NSLock()
    private static var cachedCore: SharedLexiconCore?
    private static var phraseContextStatsParseCount = 0
    private static var phraseContextStatsCacheHitCount = 0

    let overrideCharacterMap: [String: [String]]
    let phraseCandidateMap: [String: [String]]
    let commonCharacterMap: [String: [String]]
    let readingPrefixes: Set<String>

    private static func resourceURL(named name: String, ext: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: ext) {
            return bundled
        }

        let fm = FileManager.default
        let relativePath = "Resources/\(name).\(ext)"
        var candidates: [URL] = []

        if let executableURL = Bundle.main.executableURL {
            let macOSDir = executableURL.deletingLastPathComponent()
            let contentsDir = macOSDir.deletingLastPathComponent()
            candidates.append(contentsDir.appendingPathComponent(relativePath))
            candidates.append(macOSDir.appendingPathComponent("\(name).\(ext)"))
        }

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(relativePath))
        candidates.append(cwd.appendingPathComponent("src/unifyIME/\(relativePath)"))
        candidates.append(cwd.appendingPathComponent("fastChIME/\(relativePath)"))

        var ancestor = cwd
        for _ in 0..<5 {
            candidates.append(ancestor.appendingPathComponent(relativePath))
            candidates.append(ancestor.appendingPathComponent("fastChIME/\(relativePath)"))
            ancestor.deleteLastPathComponent()
        }

        for candidate in candidates {
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    init(overrideCharacterMap: [String: [String]]) {
        self.overrideCharacterMap = overrideCharacterMap
        let core = Self.sharedCore()
        self.phraseCandidateMap = core.phraseCandidateMap

        if overrideCharacterMap.isEmpty {
            self.commonCharacterMap = core.baseCommonCharacterMap
            self.readingPrefixes = core.baseReadingPrefixes
        } else {
            var map = core.baseCommonCharacterMap
            for (key, overrideValues) in overrideCharacterMap {
                var list = map[key, default: []]
                for value in overrideValues.reversed() {
                    list.removeAll { $0 == value }
                    list.insert(value, at: 0)
                }
                map[key] = list
            }
            self.commonCharacterMap = map

            var prefixes = core.baseReadingPrefixes
            for key in overrideCharacterMap.keys {
                let scalars = Array(key)
                guard scalars.count > 1 else { continue }
                for i in 1..<scalars.count {
                    prefixes.insert(String(scalars.prefix(i)))
                }
            }
            self.readingPrefixes = prefixes
        }
    }

    func resolveCandidates(for buffer: String) -> [String] {
        Self.candidateCacheLock.lock()
        if let cached = Self.candidateCache[buffer] {
            Self.touchCachedReading(buffer)
            Self.candidateCacheLock.unlock()
            return cached
        }
        Self.candidateCacheLock.unlock()

        var merged: [String] = []
        var seen = Set<String>()
        appendCandidates(forReading: buffer, into: &merged, seen: &seen)
        let canonical = BopomofoCanonicalizer.canonicalize(syllable: buffer)
        if canonical != buffer, BopomofoCanonicalizer.isPhonotacticallyValid(canonical), hasCandidates(for: canonical) {
            appendCandidates(forReading: canonical, into: &merged, seen: &seen)
        }
        // 明確聲調（含輕聲）是查詢條件，不能去調、跨調或以近音補字。
        // 未標聲調沿用原本的補候選規則，避免改變尚在輸入中的行為。
        if !containsToneMark(buffer) && !containsToneMark(canonical) {
            if isSingleSyllableReading(buffer), merged.count <= 2 {
                for reading in toneExpandedVariants(for: buffer) {
                    appendCandidates(forReading: reading, into: &merged, seen: &seen, limit: 2)
                    if merged.count >= lexiconRecallLimit { break }
                }
            }
            if isSingleSyllableReading(buffer), merged.count <= 1 {
                for variant in neighborReadingVariants(for: buffer) {
                    appendCandidates(forReading: variant, into: &merged, seen: &seen, limit: 2)
                    if merged.count >= lexiconRecallLimit { break }
                }
            }
        }
        // 盲打按偏容錯（Fat-Finger Neighbor Key Correction）
        if merged.isEmpty || (isSingleSyllableReading(buffer) && merged.count <= 1) {
            let suggestions = FatFingerCorrector.suggestedReadings(
                for: buffer,
                limitPerPosition: 2,
                totalLimit: 6,
                isPhonotacticallyValid: { BopomofoCanonicalizer.isPhonotacticallyValid($0) },
                hasEvidence: { hasCandidates(for: $0) }
            )
            for suggestion in suggestions {
                appendCandidates(forReading: suggestion, into: &merged, seen: &seen, limit: 3)
                if merged.count >= lexiconRecallLimit { break }
            }
        }

        let filtered = merged.filter(Self.isDisplayableCandidate(_:))
        var resolved = filtered.isEmpty ? (merged.isEmpty ? [buffer] : merged) : filtered
        if isSingleSyllableReading(buffer) {
            let singles = resolved.filter { $0.count == 1 }
            let longer = resolved.filter { $0.count > 1 }
            if !singles.isEmpty {
                resolved = singles + longer
            }
        }
        Self.candidateCacheLock.lock()
        Self.storeCachedCandidates(resolved, for: buffer)
        Self.candidateCacheLock.unlock()
        return resolved
    }

    private static func touchCachedReading(_ reading: String) {
        candidateCacheOrder.removeAll { $0 == reading }
        candidateCacheOrder.append(reading)
    }

    private static func storeCachedCandidates(_ candidates: [String], for reading: String) {
        candidateCache[reading] = candidates
        touchCachedReading(reading)
        while candidateCacheOrder.count > candidateCacheCapacity {
            let evicted = candidateCacheOrder.removeFirst()
            candidateCache.removeValue(forKey: evicted)
        }
    }

    func normalizeReading(_ reading: String) -> String {
        reading.unicodeScalars.filter { !Self.toneMarks.contains($0) }.map(String.init).joined()
    }

    func containsToneMark(_ reading: String) -> Bool {
        reading.unicodeScalars.contains { Self.toneMarks.contains($0) }
    }

    func canExtendToLongerPhrase(_ reading: String) -> Bool {
        readingPrefixes.contains(reading)
    }

    func hasCandidates(for reading: String) -> Bool {
        if !(commonCharacterMap[reading] ?? []).isEmpty { return true }
        if !UserCustomPhraseStore.phrases(for: reading).isEmpty { return true }
        if !(phraseCandidateMap[reading] ?? []).isEmpty { return true }
        if !(overrideCharacterMap[reading] ?? []).isEmpty { return true }
        return false
    }

    func hasEvidence(forSyllable reading: String) -> Bool {
        if hasCandidates(for: reading) { return true }
        if !containsToneMark(reading) {
            for tone in ["ˊ", "ˇ", "ˋ", "˙"] {
                if hasCandidates(for: reading + tone) { return true }
            }
        }
        return false
    }

    static func isDisplayableCandidate(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        for scalar in candidate.unicodeScalars {
            let value = scalar.value
            let isCommonHan =
                (0x3400...0x4DBF).contains(value) ||
                (0x4E00...0x9FFF).contains(value)
            if isCommonHan { continue }
            if allowedCandidatePunctuation.contains(scalar) { continue }
            return false
        }
        return true
    }

    static func sharedCore() -> SharedLexiconCore {
        let lexiconVersion = currentLexiconVersion()
        coreLock.lock()
        defer { coreLock.unlock() }

        if let cachedCore, cachedCore.version == lexiconVersion {
            phraseContextStatsCacheHitCount += 1
            return cachedCore
        }

        let core = loadCore(version: lexiconVersion)
        cachedCore = core
        phraseContextStatsParseCount += 1
        return core
    }

    private static func loadCore(version: String) -> SharedLexiconCore {
        if let binURL = resourceURL(named: "lexicon_core", ext: "bin"),
           let binData = try? Data(contentsOf: binURL, options: .mappedIfSafe),
           let payload = try? PropertyListSerialization.propertyList(from: binData, options: [], format: nil) as? [String: Any],
           let phraseCandidateMap = payload["phraseCandidateMap"] as? [String: [String]],
           let surfaceWeights = payload["surfaceWeights"] as? [String: Double],
           let readingCandidateCounts = payload["readingCandidateCounts"] as? [String: Int],
           let readingBestLengths = payload["readingBestLengths"] as? [String: Int],
           let baseCommonCharacterMap = payload["baseCommonCharacterMap"] as? [String: [String]],
           let rawPrefixes = payload["baseReadingPrefixes"] as? [String] {
            let stats = PhraseContextStats(
                surfaceWeights: surfaceWeights,
                readingCandidateCounts: readingCandidateCounts,
                readingBestLengths: readingBestLengths
            )
            return SharedLexiconCore(
                phraseCandidateMap: phraseCandidateMap,
                stats: stats,
                baseCommonCharacterMap: baseCommonCharacterMap,
                baseReadingPrefixes: Set(rawPrefixes),
                version: version
            )
        }

        var weighted = [String: [(phrase: String, weight: Double)]]()
        var surfaceWeights = [String: Double]()
        var readingCandidateCounts = [String: Int]()
        var readingBestLengths = [String: Int]()
        var readingPrefixes = Set<String>()

        if let url = resourceURL(named: "phrase_map", ext: "tsv"),
           let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 2 else { continue }
                let reading = String(parts[0])
                let phrase = String(parts[1])
                guard !reading.isEmpty, !phrase.isEmpty else { continue }

                let rawWeight = parts.count >= 3 ? Double(parts[2]) ?? 0.0 : 0.0
                let statWeight = max(parts.count >= 3 ? Double(parts[2]) ?? 1.0 : 1.0, 1.0)

                var list = weighted[reading, default: []]
                if !list.contains(where: { $0.phrase == phrase }) {
                    list.append((phrase: phrase, weight: rawWeight))
                }
                weighted[reading] = list

                surfaceWeights[phrase] = max(surfaceWeights[phrase] ?? 0.0, statWeight)
                readingCandidateCounts[reading, default: 0] += 1
                readingBestLengths[reading] = max(readingBestLengths[reading] ?? 0, phrase.count)

                let chars = Array(reading)
                if chars.count > 1 {
                    for i in 1..<chars.count {
                        readingPrefixes.insert(String(chars.prefix(i)))
                    }
                }
            }
        }

        var phraseCandidateMap = [String: [String]]()
        phraseCandidateMap.reserveCapacity(weighted.count)
        for (reading, entries) in weighted {
            phraseCandidateMap[reading] = entries
                .sorted { $0.weight > $1.weight }
                .map(\.phrase)
        }

        let stats = PhraseContextStats(
            surfaceWeights: surfaceWeights,
            readingCandidateCounts: readingCandidateCounts,
            readingBestLengths: readingBestLengths
        )

        var baseCommonCharacterMap = [String: [String]]()
        if let url = resourceURL(named: "common_map", ext: "tsv"),
           let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = String(parts[0])
                let value = String(parts[1])
                if !key.isEmpty, !value.isEmpty {
                    var list = baseCommonCharacterMap[key, default: []]
                    if !list.contains(value) {
                        list.append(value)
                    }
                    baseCommonCharacterMap[key] = list

                    let chars = Array(key)
                    if chars.count > 1 {
                        for i in 1..<chars.count {
                            readingPrefixes.insert(String(chars.prefix(i)))
                        }
                    }
                }
            }
        }

        return SharedLexiconCore(
            phraseCandidateMap: phraseCandidateMap,
            stats: stats,
            baseCommonCharacterMap: baseCommonCharacterMap,
            baseReadingPrefixes: readingPrefixes,
            version: version
        )
    }

    static func loadPhraseContextStats() -> PhraseContextStats {
        sharedCore().stats
    }

    static func prewarmPhraseContextStats() {
        _ = sharedCore()
    }

    /// 清除程序級統計快取；正式詞庫為發布後唯讀，主要供詞庫替換的
    /// 開發／測試流程在明確知道內容已變更時使用。既有統計計數不重設。
    static func invalidatePhraseContextStatsCache() {
        coreLock.lock()
        cachedCore = nil
        coreLock.unlock()
    }

    static func phraseContextStatsCacheSnapshot() -> PhraseContextStatsCacheSnapshot {
        coreLock.lock()
        let core = cachedCore
        let snapshot = PhraseContextStatsCacheSnapshot(
            loaded: core != nil,
            parseCount: phraseContextStatsParseCount,
            cacheHitCount: phraseContextStatsCacheHitCount,
            surfaceCount: core?.stats.surfaceWeights.count ?? 0,
            readingCount: core?.stats.readingCandidateCounts.count ?? 0
        )
        coreLock.unlock()
        return snapshot
    }

    /// 以詞庫檔案位置、大小與修改時間識別目前程序可見的詞庫版本。
    /// 資源隨 app 發布時不可變；若開發／測試期間替換資源，下一次讀取會重新解析。
    static func currentLexiconVersion() -> String {
        let fileManager = FileManager.default
        return ["phrase_map", "common_map"].map { name in
            guard let url = resourceURL(named: name, ext: "tsv") else {
                return "\(name)=missing"
            }
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            return "\(name)=\(url.path)|\(size)|\(modified.bitPattern)|\(fileNumber)"
        }.joined(separator: "\u{1F}")
    }

    private func appendCandidates(forReading reading: String, into merged: inout [String], seen: inout Set<String>, limit: Int? = nil) {
        let startCount = merged.count
        let preferPhrasesFirst = reading.count > 1

        if let overrides = overrideCharacterMap[reading], !overrides.isEmpty {
            for value in overrides where !seen.contains(value) {
                seen.insert(value)
                merged.append(value)
                if let limit, merged.count - startCount >= limit { return }
            }
        }
        let customPhrases = UserCustomPhraseStore.phrases(for: reading)
        let candidateSources: [[String]]
        if preferPhrasesFirst {
            candidateSources = [
                customPhrases,
                phraseCandidateMap[reading] ?? [],
                commonCharacterMap[reading] ?? []
            ]
        } else {
            candidateSources = [
                customPhrases,
                commonCharacterMap[reading] ?? [],
                phraseCandidateMap[reading] ?? []
            ]
        }
        for source in candidateSources {
            for value in source where !seen.contains(value) {
                seen.insert(value)
                merged.append(value)
                if let limit, merged.count - startCount >= limit { return }
            }
        }
    }

    private func neighborReadingVariants(for reading: String) -> [String] {
        guard !reading.isEmpty else { return [] }
        let symbols = Array(reading)
        var variants: [String] = []

        for (index, symbol) in symbols.enumerated() {
            guard let neighbors = Self.bopomofoNeighborMap[symbol], !neighbors.isEmpty else { continue }
            for neighbor in neighbors {
                var mutated = symbols
                mutated[index] = neighbor
                let candidate = String(mutated)
                if candidate != reading, !variants.contains(candidate) {
                    variants.append(candidate)
                    if variants.count >= 12 {
                        return variants
                    }
                }
            }
        }

        return variants
    }

    private func toneExpandedVariants(for reading: String) -> [String] {
        guard !reading.isEmpty, !containsToneMark(reading) else { return [] }
        let tones: [Character] = ["ˇ", "ˋ", "ˊ", "˙"]
        return tones.map { reading + String($0) }
    }

    private func isSingleSyllableReading(_ reading: String) -> Bool {
        let symbolCount = reading.filter { char in
            !String(char).unicodeScalars.contains { Self.toneMarks.contains($0) }
        }.count
        return symbolCount > 0 && symbolCount <= 4
    }

    private static func buildBopomofoNeighborMap() -> [Character: [Character]] {
        var result = [Character: [Character]]()

        for (rowIndex, row) in bopomofoKeyRows.enumerated() {
            for (columnIndex, key) in row.enumerated() {
                guard let symbol = bopomofoKeyToSymbol[key] else { continue }
                var neighbors: [Character] = []

                for neighborRow in max(0, rowIndex - 1)...min(bopomofoKeyRows.count - 1, rowIndex + 1) {
                    let rowKeys = bopomofoKeyRows[neighborRow]
                    for neighborColumn in max(0, columnIndex - 1)...min(rowKeys.count - 1, columnIndex + 1) {
                        let neighborKey = rowKeys[neighborColumn]
                        guard neighborKey != key, let neighborSymbol = bopomofoKeyToSymbol[neighborKey] else { continue }
                        if toneMarks.contains(UnicodeScalar(String(neighborSymbol))!) { continue }
                        if !neighbors.contains(neighborSymbol) {
                            neighbors.append(neighborSymbol)
                        }
                    }
                }

                if !toneMarks.contains(UnicodeScalar(String(symbol))!) {
                    result[symbol] = neighbors
                }
            }
        }

        return result
    }
}
