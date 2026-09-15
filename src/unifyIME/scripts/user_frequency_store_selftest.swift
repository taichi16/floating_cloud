import Foundation
import Darwin

// 僅供獨立測試編譯使用；正式測試一開始就會改用唯一的暫存目錄。
let fastChIMEDataDir = URL(
    fileURLWithPath: "/private/tmp/unifyime-user-frequency-default-not-used",
    isDirectory: true
)

private struct UserFrequencyTestFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class FlushResultBox {
    private let lock = NSLock()
    private var storedResult: UserFrequencyFlushResult?

    func store(_ result: UserFrequencyFlushResult) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }

    func load() -> UserFrequencyFlushResult? {
        lock.lock()
        let result = storedResult
        lock.unlock()
        return result
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw UserFrequencyTestFailure(message: message)
    }
}

private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func writeReport(_ report: [String: Any], to path: URL?) {
    guard let path,
          let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else {
        return
    }
    try? FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
    )
    try? data.write(to: path, options: [.atomic])
}

@main
struct UserFrequencyStoreSelfTest {
    static func main() {
        let startedAt = iso8601Now()
        let startedTicks = DispatchTime.now().uptimeNanoseconds
        let arguments = CommandLine.arguments
        let reportPath: URL? = {
            guard let index = arguments.firstIndex(of: "--report-json"), arguments.indices.contains(index + 1) else {
                return nil
            }
            return URL(fileURLWithPath: arguments[index + 1])
        }()
        let fileManager = FileManager.default
        let storageDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("unifyime-user-frequency-\(UUID().uuidString)", isDirectory: true)
        let storageFile = storageDirectory.appendingPathComponent("user_freq_v2_zh-Hant.tsv")
        var checks: [[String: Any]] = []
        var overallStatus = "pass"

        defer {
            UserFrequencyStore.setWriteHookForTesting(nil)
            UserFrequencyStore.resetStorageForTesting()
            try? fileManager.removeItem(at: storageDirectory)
        }

        do {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true, attributes: nil)
            UserFrequencyStore.configureStorageForTesting(directory: storageDirectory)

            func runCheck(_ name: String, _ body: () throws -> Void) {
                let checkStart = DispatchTime.now().uptimeNanoseconds
                var status = "pass"
                var errorText = ""
                do {
                    try body()
                } catch {
                    status = "fail"
                    errorText = error.localizedDescription
                    overallStatus = "fail"
                }
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - checkStart) / 1_000_000)
                var result: [String: Any] = [
                    "name": name,
                    "status": status,
                    "duration_ms": elapsed
                ]
                if !errorText.isEmpty {
                    result["error"] = errorText
                }
                checks.append(result)
                print("[B 測試] \(name)：\(status)（\(elapsed) ms）")
                if !errorText.isEmpty {
                    print("[B 測試] 錯誤：\(errorText)")
                }
            }

            runCheck("首次寫入") {
                UserFrequencyStore.record(languageID: "zh-Hant", reading: "ㄋㄧ", surface: "你")
                let result = UserFrequencyStore.flushNow()
                try require(result.isSuccess, "首次 flush 應成功")
                try require(result.attemptedLanguageIDs == ["zh-Hant"], "首次 flush 應嘗試 zh-Hant")
                try require(fileManager.fileExists(atPath: storageFile.path), "首次寫入應建立詞頻檔")
                let text = try String(contentsOf: storageFile, encoding: .utf8)
                try require(text.contains("ㄋㄧ\t你\t1"), "首次寫入內容不正確")
            }

            runCheck("累計與候選排序") {
                UserFrequencyStore.record(languageID: "zh-Hant", reading: "ㄋㄧ", surface: "你")
                UserFrequencyStore.record(languageID: "zh-Hant", reading: "ㄋㄧ", surface: "你")
                UserFrequencyStore.record(languageID: "zh-Hant", reading: "ㄋㄧ", surface: "妳")
                let result = UserFrequencyStore.flushNow()
                try require(result.isSuccess, "累計 flush 應成功")
                try require(UserFrequencyStore.frequency(languageID: "zh-Hant", reading: "ㄋㄧ", surface: "你") == 3, "詞頻累計應為 3")
                try require(UserFrequencyStore.frequency(languageID: "zh-Hant", reading: "ㄋㄧ", surface: "妳") == 1, "第二候選詞頻應為 1")
                try require(UserFrequencyStore.boost(languageID: "zh-Hant", reading: "ㄋㄧ", candidates: ["妳", "你", "您"]) == ["你", "妳", "您"], "候選排序不正確")
            }

            runCheck("重新載入") {
                UserFrequencyStore.resetStorageForTesting()
                UserFrequencyStore.configureStorageForTesting(directory: storageDirectory)
                let values = UserFrequencyStore.frequencyMap(languageID: "zh-Hant", reading: "ㄋㄧ")
                try require(values["你"] == 3 && values["妳"] == 1, "重新載入後詞頻不正確")
            }

            runCheck("寫入失敗保留 dirty 並可重試") {
                UserFrequencyStore.setWriteFailureForTesting(true)
                UserFrequencyStore.record(languageID: "zh-Hant", reading: "ㄏㄠˇ", surface: "好")
                let failed = UserFrequencyStore.flushNow()
                try require(!failed.isSuccess, "注入失敗時 flush 不應成功")
                try require(failed.failures["zh-Hant"] != nil, "失敗結果應包含 zh-Hant")
                try require(UserFrequencyStore.latestStorageError()?.contains("注入") == true, "寫入錯誤應可追蹤")
                UserFrequencyStore.setWriteFailureForTesting(false)
                let retried = UserFrequencyStore.flushNow()
                try require(retried.isSuccess, "解除注入後 flush 應可重試成功")
                try require(UserFrequencyStore.frequency(languageID: "zh-Hant", reading: "ㄏㄠˇ", surface: "好") == 1, "重試後詞頻不正確")
            }

            runCheck("快速連續更新") {
                UserFrequencyStore.resetStorageForTesting()
                UserFrequencyStore.configureStorageForTesting(directory: storageDirectory)
                for _ in 0..<64 {
                    UserFrequencyStore.record(languageID: "zh-Hant", reading: "ㄅ", surface: "快")
                }
                let result = UserFrequencyStore.flushNow()
                try require(result.isSuccess, "快速連續更新 flush 應成功")
                try require(UserFrequencyStore.frequency(languageID: "zh-Hant", reading: "ㄅ", surface: "快") == 64, "快速連續更新遺失次數")
            }

            runCheck("flush 中途更新不覆蓋新選取") {
                UserFrequencyStore.resetStorageForTesting()
                UserFrequencyStore.configureStorageForTesting(directory: storageDirectory)
                UserFrequencyStore.record(languageID: "zh-Hant", reading: "ㄆ", surface: "甲")

                let writeEntered = DispatchSemaphore(value: 0)
                let continueWrite = DispatchSemaphore(value: 0)
                let flushCompleted = DispatchSemaphore(value: 0)
                let resultBox = FlushResultBox()
                UserFrequencyStore.setWriteHookForTesting {
                    writeEntered.signal()
                    _ = continueWrite.wait(timeout: .now() + .seconds(5))
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    resultBox.store(UserFrequencyStore.flushNow())
                    flushCompleted.signal()
                }
                try require(writeEntered.wait(timeout: .now() + .seconds(5)) == .success, "未進入受控寫入時序")
                UserFrequencyStore.record(languageID: "zh-Hant", reading: "ㄆ", surface: "乙")
                continueWrite.signal()
                try require(flushCompleted.wait(timeout: .now() + .seconds(5)) == .success, "受控 flush 未完成")
                UserFrequencyStore.setWriteHookForTesting(nil)

                try require(resultBox.load()?.isSuccess == true, "第一個快照寫入應成功")
                let retry = UserFrequencyStore.flushNow()
                try require(retry.isSuccess, "新選取留下的 dirty 應可再次 flush")
                UserFrequencyStore.resetStorageForTesting()
                UserFrequencyStore.configureStorageForTesting(directory: storageDirectory)
                let values = UserFrequencyStore.frequencyMap(languageID: "zh-Hant", reading: "ㄆ")
                try require(values["甲"] == 1 && values["乙"] == 1, "flush 中途的新選取不可遺失")
            }
        } catch {
            overallStatus = "fail"
            checks.append([
                "name": "測試初始化",
                "status": "fail",
                "duration_ms": 0,
                "error": error.localizedDescription
            ])
            print("[B 測試] 初始化失敗：\(error.localizedDescription)")
        }

        let exitCode: Int32 = overallStatus == "pass" ? 0 : 1
        let finishedAt = iso8601Now()
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startedTicks) / 1_000_000)
        writeReport([
            "status": overallStatus,
            "exit_code": exitCode,
            "started_at": startedAt,
            "finished_at": finishedAt,
            "duration_ms": elapsed,
            "storage_isolated": true,
            "checks": checks
        ], to: reportPath)
        print("B 使用者詞頻獨立測試：\(overallStatus)（\(elapsed) ms）")
        exit(exitCode)
    }
}
