import Foundation

/// 負責載入與監聽使用者個人自訂中文詞庫（免重新編譯、存檔即生效）
public enum UserCustomPhraseStore {
    private static let lock = NSLock()
    private static var cachedPhrases: [String: [String]] = [:] // reading -> [phrase]
    private static var lastModificationDate: Date?

    private static var customDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Application Support/行雲_繁-A/CustomLexicon", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static var customFileUrl: URL {
        customDirectory.appendingPathComponent("custom_phrases.txt")
    }

    /// 確保檔案存在，若無則建立預設範本
    private static func ensureFileExists() {
        let path = customFileUrl.path
        if !FileManager.default.fileExists(atPath: path) {
            let template = """
            # 行雲_繁-A 個人自訂中文詞庫
            # 說明：每行輸入「注音讀音 詞語」（以空格或 Tab 分隔）。
            # 儲存此檔案後，輸入法會自動熱載入，無需重新編譯或重開機。
            ㄒㄧㄥˊ ㄩㄣˊ 行雲
            """
            try? template.write(to: customFileUrl, atomically: true, encoding: .utf8)
        }
    }

    /// 檢查是否有新修改並熱載入
    public static func reloadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        ensureFileExists()
        let path = customFileUrl.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return
        }

        if let last = lastModificationDate, last == modDate {
            return
        }

        var newPhrases: [String: [String]] = [:]
        if let content = try? String(contentsOf: customFileUrl, encoding: .utf8) {
            for line in content.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                
                // 拆分讀音與詞語
                let parts: [String]
                if trimmed.contains("\t") {
                    parts = trimmed.split(separator: "\t").map(String.init)
                } else {
                    let comps = trimmed.components(separatedBy: " ")
                    if comps.count >= 2 {
                        let phrase = comps.last!
                        let reading = comps.dropLast().joined(separator: " ")
                        parts = [reading, phrase]
                    } else {
                        parts = comps
                    }
                }
                
                if parts.count >= 2 {
                    let reading = parts[0].trimmingCharacters(in: .whitespaces)
                    let phrase = parts[1].trimmingCharacters(in: .whitespaces)
                    guard !reading.isEmpty, !phrase.isEmpty else { continue }
                    newPhrases[reading, default: []].append(phrase)
                }
            }
        }

        cachedPhrases = newPhrases
        lastModificationDate = modDate
    }

    /// 查詢自訂詞彙
    public static func phrases(for reading: String) -> [String] {
        reloadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedPhrases[reading] ?? []
    }
}
