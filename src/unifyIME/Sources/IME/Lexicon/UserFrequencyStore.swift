import Foundation

/// 詞頻寫入結果。失敗語言會保留 dirty 狀態，下一次 flush 可重試。
struct UserFrequencyFlushResult {
    let attemptedLanguageIDs: [String]
    let succeededLanguageIDs: [String]
    let failures: [String: String]

    var isSuccess: Bool { failures.isEmpty }
}

/// 依語言保存使用者詞頻，追蹤每個「讀音 → 文字」組合的選取次數。
/// 每種語言使用 App 支援目錄下獨立的 TSV 檔案；英文目標不納入追蹤。
enum UserFrequencyStore {
    private static let stateLock = NSLock()
    private static let flushLock = NSLock()
    /// languageID → (reading → [(surface, 次數)])。
    private static var cache: [String: [String: [(surface: String, count: Int)]]] = [:]
    private static var dirty: Set<String> = []
    private static var mutationGeneration: [String: UInt64] = [:]
    private static var cacheRevisionValue: UInt64 = 0
    private static var pendingFlush: DispatchWorkItem?
    private static var storageDirectory = fastChIMEDataDir
    private static var injectWriteFailure = false
    private static var writeHookForTesting: (() -> Void)?
    private static var lastFlushResult: UserFrequencyFlushResult?
    private static var lastStorageError: String?

    private struct FlushSnapshot {
        let languageID: String
        let data: [String: [(surface: String, count: Int)]]
        let generation: UInt64
        let directory: URL
        let injectWriteFailure: Bool
    }

    private enum StoreError: LocalizedError {
        case injectedWriteFailure

        var errorDescription: String? {
            switch self {
            case .injectedWriteFailure:
                return "測試注入的詞頻寫入失敗"
            }
        }
    }

    // MARK: - 公開 API

    /// 記錄一次使用者選取；應在候選確認後呼叫。
    static func record(languageID: String, reading: String, surface: String) {
        guard shouldTrack(languageID) else { return }
        let key = reading.lowercased()
        stateLock.lock()
        var langMap = cache[languageID] ?? loadFromDisk(languageID: languageID)
        var entries = langMap[key] ?? []
        if let idx = entries.firstIndex(where: { $0.surface == surface }) {
            entries[idx].count += 1
        } else {
            entries.append((surface: surface, count: 1))
        }
        langMap[key] = entries
        cache[languageID] = langMap
        dirty.insert(languageID)
        mutationGeneration[languageID, default: 0] += 1
        cacheRevisionValue &+= 1
        stateLock.unlock()
        scheduleFlush()
    }

    /// 回傳候選的使用者詞頻；數值越高代表選取次數越多，沒有紀錄時回傳 0。
    static func frequency(languageID: String, reading: String, surface: String) -> Int {
        guard shouldTrack(languageID) else { return 0 }
        return frequencyMap(languageID: languageID, reading: reading)[surface] ?? 0
    }

    /// 批次查詢指定讀音的 [文字: 次數]，只取得一次鎖。
    static func frequencyMap(languageID: String, reading: String) -> [String: Int] {
        guard shouldTrack(languageID) else { return [:] }
        let key = reading.lowercased()
        stateLock.lock()
        if cache[languageID] == nil {
            cache[languageID] = loadFromDisk(languageID: languageID)
        }
        let entries = cache[languageID]?[key] ?? []
        stateLock.unlock()
        return Dictionary(entries.map { ($0.surface, $0.count) }, uniquingKeysWith: max)
    }

    /// 回傳會影響候選排序的使用者詞頻 revision；供程序內唯讀預測快取建立安全 key。
    static func cacheRevision() -> UInt64 {
        stateLock.lock()
        let revision = cacheRevisionValue
        stateLock.unlock()
        return revision
    }

    /// 依使用者偏好重新排列候選；有詞頻者按次數遞減，其餘保留原順序。
    static func boost(languageID: String, reading: String, candidates: [String]) -> [String] {
        let freqMap = frequencyMap(languageID: languageID, reading: reading)
        guard !freqMap.isEmpty else { return candidates }
        let (boosted, rest) = candidates.reduce(into: ([(String, Int)](), [String]())) { result, c in
            if let freq = freqMap[c] {
                result.0.append((c, freq))
            } else {
                result.1.append(c)
            }
        }
        let sorted = boosted.sorted { $0.1 > $1.1 }.map(\.0)
        return sorted + rest
    }

    /// 立即寫入目前所有 dirty 語言。
    ///
    /// 寫入維持 atomic；只有在快照寫入期間沒有更新紀錄時，成功寫入才會
    /// 清除 dirty。失敗會保留 dirty，並回傳給呼叫端追蹤或重試。
    @discardableResult
    static func flushNow() -> UserFrequencyFlushResult {
        flushLock.lock()
        defer { flushLock.unlock() }

        stateLock.lock()
        pendingFlush?.cancel()
        pendingFlush = nil
        let snapshots = dirty.sorted().compactMap { languageID -> FlushSnapshot? in
            guard let data = cache[languageID] else { return nil }
            return FlushSnapshot(
                languageID: languageID,
                data: data,
                generation: mutationGeneration[languageID, default: 0],
                directory: storageDirectory,
                injectWriteFailure: injectWriteFailure
            )
        }
        stateLock.unlock()

        var succeeded: [String] = []
        var failures: [String: String] = [:]
        for snapshot in snapshots {
            do {
                invokeWriteHookForTesting()
                try saveToDisk(
                    languageID: snapshot.languageID,
                    data: snapshot.data,
                    directory: snapshot.directory,
                    injectWriteFailure: snapshot.injectWriteFailure
                )
                succeeded.append(snapshot.languageID)
            } catch {
                failures[snapshot.languageID] = error.localizedDescription
            }
        }

        let result = UserFrequencyFlushResult(
            attemptedLanguageIDs: snapshots.map(\.languageID),
            succeededLanguageIDs: succeeded.sorted(),
            failures: failures
        )

        stateLock.lock()
        for snapshot in snapshots where failures[snapshot.languageID] == nil {
            if mutationGeneration[snapshot.languageID, default: 0] == snapshot.generation {
                dirty.remove(snapshot.languageID)
            }
        }
        lastFlushResult = result
        if failures.isEmpty {
            lastStorageError = nil
        } else {
            lastStorageError = failures
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "；")
        }
        stateLock.unlock()
        return result
    }

    /// 回傳最近一次 flush 結果，供診斷或測試查詢；不由產品 UI 直接呼叫。
    static func latestFlushResult() -> UserFrequencyFlushResult? {
        stateLock.lock()
        let result = lastFlushResult
        stateLock.unlock()
        return result
    }

    /// 最近一次讀取或寫入錯誤的文字診斷。
    static func latestStorageError() -> String? {
        stateLock.lock()
        let error = lastStorageError
        stateLock.unlock()
        return error
    }

    // MARK: - 僅供本機測試的儲存控制

    /// 將測試導向獨立暫存目錄；不會讀寫預設的使用者資料目錄。
    static func configureStorageForTesting(directory: URL) {
        stateLock.lock()
        pendingFlush?.cancel()
        pendingFlush = nil
        cache.removeAll()
        dirty.removeAll()
        mutationGeneration.removeAll()
        cacheRevisionValue &+= 1
        storageDirectory = directory
        injectWriteFailure = false
        writeHookForTesting = nil
        lastFlushResult = nil
        lastStorageError = nil
        stateLock.unlock()
    }

    static func setWriteFailureForTesting(_ shouldFail: Bool) {
        stateLock.lock()
        injectWriteFailure = shouldFail
        stateLock.unlock()
    }

    /// 設定寫入前測試鉤子，讓測試可重現 flush 與新選取並行的時序。
    /// 此鉤子不由產品 UI 使用，也不改變正式寫入流程。
    static func setWriteHookForTesting(_ hook: (() -> Void)?) {
        stateLock.lock()
        writeHookForTesting = hook
        stateLock.unlock()
    }

    /// 還原正式儲存位置與記憶體狀態；測試結束時使用。
    static func resetStorageForTesting() {
        stateLock.lock()
        pendingFlush?.cancel()
        pendingFlush = nil
        cache.removeAll()
        dirty.removeAll()
        mutationGeneration.removeAll()
        cacheRevisionValue &+= 1
        storageDirectory = fastChIMEDataDir
        injectWriteFailure = false
        writeHookForTesting = nil
        lastFlushResult = nil
        lastStorageError = nil
        stateLock.unlock()
    }

    // MARK: - 內部實作

    private static let skipLanguageIDs: Set<String> = ["en", "english-ime"]

    private static func shouldTrack(_ languageID: String) -> Bool {
        !skipLanguageIDs.contains(languageID)
    }

    private static func fileURL(for languageID: String, directory: URL) -> URL {
        let safeName = languageID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("user_freq_v2_\(safeName).tsv")
    }

    /// 從磁碟載入；必須在 stateLock 內或由唯一擁有者呼叫。
    private static func loadFromDisk(languageID: String) -> [String: [(surface: String, count: Int)]] {
        let url = fileURL(for: languageID, directory: storageDirectory)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            lastStorageError = "讀取 \(url.path) 失敗：\(error.localizedDescription)"
            return [:]
        }

        var result: [String: [(surface: String, count: Int)]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let reading = String(parts[0])
            let surface = String(parts[1])
            let count = Int(parts[2]) ?? 0
            guard count > 0 else { continue }
            result[reading, default: []].append((surface: surface, count: count))
        }
        return result
    }

    private static func saveToDisk(
        languageID: String,
        data: [String: [(surface: String, count: Int)]],
        directory: URL,
        injectWriteFailure: Bool
    ) throws {
        if injectWriteFailure {
            throw StoreError.injectedWriteFailure
        }

        let fileManager = FileManager.default
        let url = fileURL(for: languageID, directory: directory)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        var lines: [String] = []
        for (reading, entries) in data.sorted(by: { $0.key < $1.key }) {
            for entry in entries.sorted(by: { $0.count > $1.count }) {
                lines.append("\(reading)\t\(entry.surface)\t\(entry.count)")
            }
        }
        let payload = Data(lines.joined(separator: "\n").utf8)
        try payload.write(to: url, options: [.atomic])
    }

    private static func scheduleFlush() {
        stateLock.lock()
        pendingFlush?.cancel()
        let item = DispatchWorkItem {
            _ = flushNow()
        }
        pendingFlush = item
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    private static func invokeWriteHookForTesting() {
        stateLock.lock()
        let hook = writeHookForTesting
        stateLock.unlock()
        hook?()
    }
}
