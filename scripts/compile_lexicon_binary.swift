import Foundation

print("Compiling lexicon TSV into binary cache...")
let start = Date()

var weighted = [String: [(phrase: String, weight: Double)]]()
var surfaceWeights = [String: Double]()
var readingCandidateCounts = [String: Int]()
var readingBestLengths = [String: Int]()
var readingPrefixes = Set<String>()

let phraseURL = URL(fileURLWithPath: "src/unifyIME/Resources/phrase_map.tsv")
guard let pData = try? Data(contentsOf: phraseURL), let pText = String(data: pData, encoding: .utf8) else {
    fatalError("Cannot read phrase_map.tsv")
}

for line in pText.split(whereSeparator: \.isNewline) {
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

var phraseCandidateMap = [String: [String]]()
phraseCandidateMap.reserveCapacity(weighted.count)
for (reading, entries) in weighted {
    phraseCandidateMap[reading] = entries
        .sorted { $0.weight > $1.weight }
        .map(\.phrase)
}

var baseCommonCharacterMap = [String: [String]]()
let commonURL = URL(fileURLWithPath: "src/unifyIME/Resources/common_map.tsv")
if let cData = try? Data(contentsOf: commonURL), let cText = String(data: cData, encoding: .utf8) {
    for line in cText.split(whereSeparator: \.isNewline) {
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

let payload: [String: Any] = [
    "version": 1,
    "phraseCandidateMap": phraseCandidateMap,
    "surfaceWeights": surfaceWeights,
    "readingCandidateCounts": readingCandidateCounts,
    "readingBestLengths": readingBestLengths,
    "baseCommonCharacterMap": baseCommonCharacterMap,
    "baseReadingPrefixes": Array(readingPrefixes)
]

let binData = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
let destURL = URL(fileURLWithPath: "src/unifyIME/Resources/lexicon_core.bin")
try binData.write(to: destURL)

let elapsed = Date().timeIntervalSince(start)
print("Successfully compiled lexicon_core.bin at \(destURL.path)")
print("Size: \(binData.count / 1024) KB, Entries: \(phraseCandidateMap.count), Elapsed: \(String(format: "%.2f", elapsed))s")
