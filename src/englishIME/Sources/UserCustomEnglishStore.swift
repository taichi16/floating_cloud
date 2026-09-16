import Foundation

/// 負責載入與監聽使用者個人自訂英文詞庫（免重新編譯、存檔即生效）
public enum UserCustomEnglishStore {
    private static let lock = NSLock()
    private static var cachedWords: [String: String] = [:] // lowercased -> original surface
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
        customDirectory.appendingPathComponent("custom_words.txt")
    }

    /// 確保檔案存在，若無則建立預設範本
    private static func ensureFileExists() {
        let path = customFileUrl.path
        if !FileManager.default.fileExists(atPath: path) {
            let template = """
            # 行雲_繁-A 個人自訂英文詞庫
            # 說明：每行輸入一個單字、縮寫或專有名詞（大小寫皆可）。
            # 儲存此檔案後，輸入法會自動載入，無需重新編譯或重開機。
            KPIs
            Paid
            Over-budget
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

        var newWords: [String: String] = [:]
        if let content = try? String(contentsOf: customFileUrl, encoding: .utf8) {
            for line in content.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                newWords[trimmed.lowercased()] = trimmed
            }
        }

        cachedWords = newWords
        lastModificationDate = modDate
    }

    /// 查詢是否為自訂單字
    public static func customWord(for normalized: String) -> String? {
        reloadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedWords[normalized.lowercased()]
    }

    /// 取得所有自訂單字
    public static func allCustomWords() -> [String: String] {
        reloadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedWords
    }
}
