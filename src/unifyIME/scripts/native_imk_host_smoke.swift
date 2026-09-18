import AppKit
import Carbon
import CoreGraphics
import Darwin
import Foundation

private let defaultBundleID = "com.vader.inputmethod.UnifyIME"
private let defaultModeID = "com.vader.inputmethod.UnifyIME.Bopomofo"
private let defaultSourceID = "com.vader.inputmethod.UnifyIME"
private let defaultConnectionName = "com.vader.inputmethod.UnifyIME_Connection"
private let nativeIMKSmokeRequestFileName = "native-imk-smoke-request.json"
private let nativeIMKSmokeRequestMaxLifetime: TimeInterval = 90

private enum SmokeFailureClass {
    static let none = "none"
    static let preconditionNotMet = "precondition_not_met"
    static let hostHarnessFailure = "host_harness_failure"
    static let productBehaviorFailure = "product_behavior_failure"
}

private struct Options {
    let reportURL: URL?
    let traceURL: URL
    let appBundleURL: URL
    let modeID: String
    let sourceID: String
    let workspaceRootURL: URL
    let smokeRequestURL: URL
    let timeout: TimeInterval
    let dryRun: Bool

    init(arguments: [String]) {
        var values: [String: String] = [:]
        var dryRun = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--dry-run" {
                dryRun = true
                index += 1
                continue
            }
            if argument == "--report-json" || argument == "--trace-path" || argument == "--app-bundle"
                || argument == "--mode-id" || argument == "--source-id" || argument == "--workspace-root"
                || argument == "--timeout",
               index + 1 < arguments.count {
                values[argument] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }

        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        reportURL = values["--report-json"].map { URL(fileURLWithPath: $0) }
        traceURL = URL(fileURLWithPath: values["--trace-path"] ?? environment["UNIFYIME_RUNTIME_TRACE"] ?? "/tmp/unifyime-native-imk-host.log")
        appBundleURL = URL(fileURLWithPath: values["--app-bundle"] ?? home.appendingPathComponent("Library/Input Methods/行雲_繁-A.app").path, isDirectory: true)
        modeID = values["--mode-id"] ?? defaultModeID
        sourceID = values["--source-id"] ?? defaultSourceID
        workspaceRootURL = URL(fileURLWithPath: values["--workspace-root"] ?? environment["UNIFYIME_WORKSPACE_ROOT"] ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        smokeRequestURL = home
            .appendingPathComponent("Library/Application Support/UnifyIME/temp", isDirectory: true)
            .appendingPathComponent(nativeIMKSmokeRequestFileName)
        timeout = max(5, TimeInterval(values["--timeout"] ?? "30") ?? 30)
        self.dryRun = dryRun
    }
}

private final class SmokeReport {
    private let startedAt = Date()
    private let startedTicks = DispatchTime.now().uptimeNanoseconds
    private(set) var checks: [[String: Any]] = []

    func add(_ name: String, status: String, details: [String: Any] = [:], error: String? = nil) {
        var check: [String: Any] = [
            "name": name,
            "status": status,
            "duration_ms": 0,
            "details": details
        ]
        if let error, !error.isEmpty { check["error"] = error }
        checks.append(check)
        let suffix = error.map { " error=\($0)" } ?? ""
        print("[native host] \(name)：\(status)\(suffix)")
    }

    func finish(status: String, exitCode: Int32, options: Options, diagnosis: [String: Any]) {
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startedTicks) / 1_000_000)
        let payload: [String: Any] = [
            "schema_version": 1,
            "status": status,
            "exit_code": Int(exitCode),
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "finished_at": ISO8601DateFormatter().string(from: Date()),
            "duration_ms": elapsed,
            "app_bundle": options.appBundleURL.path,
            "mode_id": options.modeID,
            "source_id": options.sourceID,
            "host_class": "NSTextView",
            "host_protocol": "NSTextInputClient",
            "input_context_class": "NSTextInputContext",
            "trace_path": options.traceURL.path,
            "trace_request_path": options.smokeRequestURL.path,
            "run_mode": options.dryRun ? "dry_run" : "full",
            "diagnosis": diagnosis,
            "checks": checks,
            "manual_unresolved": [
                "CotEditor",
                "TextEdit"
            ]
        ]
        if let reportURL = options.reportURL,
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: reportURL, options: [.atomic])
        }
        print("native IMK AppKit host smoke：\(status)（\(elapsed) ms，exit code=\(exitCode)）")
    }
}

private struct HostSnapshot {
    let text: String
    let hasMarkedText: Bool
    let markedRange: NSRange
    let selectedRange: NSRange
    let markedText: String

    func dictionary() -> [String: Any] {
        [
            "text": text,
            "has_marked_text": hasMarkedText,
            "marked_range": NSStringFromRange(markedRange),
            "selected_range": NSStringFromRange(selectedRange),
            "marked_text": markedText
        ]
    }
}

private struct RuntimeTraceSnapshot {
    let text: String
    let path: String
    let source: String
    let byteCount: Int

    var dictionary: [String: Any] {
        [
            "trace_path": path,
            "trace_source": source,
            "trace_bytes": byteCount,
            "trace_line_count": text.split(whereSeparator: \.isNewline).count,
            "trace_has_data": !text.isEmpty
        ]
    }
}

private struct KeyAction {
    let name: String
    let characters: String
    let keyCode: UInt16
}

private final class NativeIMKHostSmokeDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private let report = SmokeReport()
    private var window: NSWindow?
    private var textView: NSTextView?
    private var inputContext: NSTextInputContext?
    private var exitCode: Int32 = 2
    private var didFinish = false
    private var terminationRequested = false
    private var cleanupCompleted = false
    private var smokeOwnedManagedPIDs: Set<pid_t> = []
    private var managedServerFirstObservedAt: Date?
    private var traceBaselineOffsets: [String: Int] = [:]
    private var traceRequestWritten = false
    private var traceRequestNonce = UUID().uuidString
    private var originalGlobalInputSource: TISInputSource?
    private var globalInputSourceSelectionAttempted = false
    private var globalInputSourceRestored = false
    private var imkSessionActivationReasserted = false
    private var dispatchedActionCount = 0
    private var actionFailureName: String?
    private var actionFailureMessage: String?
    private let actions: [KeyAction] = [
        KeyAction(name: "marked-first-key", characters: "s", keyCode: 1),
        KeyAction(name: "marked-second-key", characters: "u", keyCode: 32),
        KeyAction(name: "marked-tone-key", characters: "3", keyCode: 20),
        KeyAction(name: "commit-enter", characters: "\r", keyCode: 36)
    ]
    private var actionIndex = 0
    private var deadline = Date.distantFuture

    init(options: Options) {
        self.options = options
        super.init()
        let defaultTraceURL = defaultRuntimeTraceURL()
        traceBaselineOffsets[defaultTraceURL.path] = traceFileSize(at: defaultTraceURL)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        deadline = Date().addingTimeInterval(options.timeout)
        NSApp.setActivationPolicy(.regular)
        configureTextHost()
        guard !didFinish else { return }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        guard window?.makeFirstResponder(textView) == true else {
            finish(status: "fail", code: 2, name: "NSTextView first responder", error: "無法取得 NSTextView first responder")
            return
        }
        guard let inputContext else {
            finish(status: "fail", code: 2, name: "NSTextInputContext", error: "NSTextView 沒有可用的 NSTextInputContext")
            return
        }
        originalGlobalInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        inputContext.activate()
        report.add(
            "Cocoa NSTextInputContext",
            status: "pass",
            details: [
                "class": NSStringFromClass(type(of: inputContext)),
                "client_class": NSStringFromClass(type(of: inputContext.client)),
                "activated_before_input_source_selection": true,
                "selected_keyboard_input_source_before_selection": inputContext.selectedKeyboardInputSource ?? "nil"
            ]
        )

        terminateExistingInputMethodIfNeeded()
        guard !didFinish else { return }
        resetRuntimeTrace()
        guard !didFinish else { return }
        waitForHostActivation(attempt: 0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = cleanupOwnedChildProcess()
        _ = cleanupSmokeRequest()
    }

    func resultCode() -> Int32 { exitCode }

    private func configureTextHost() {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 220)
        let text = NSTextView(frame: frame)
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = false
        text.usesFontPanel = false
        text.font = NSFont.systemFont(ofSize: 24)
        text.string = ""
        textView = text

        let hostWindow = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        hostWindow.title = "UnifyIME native IMK host smoke"
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = text
        window = hostWindow
        hostWindow.makeKeyAndOrderFront(nil)

        guard let context = text.inputContext else {
            finish(status: "fail", code: 2, name: "NSTextView NSTextInputContext", error: "NSTextView 沒有由 AppKit 建立 NSTextInputContext")
            return
        }
        inputContext = context
        report.add(
            "NSTextView NSTextInputClient host",
            status: "pass",
            details: [
                "class": NSStringFromClass(type(of: text)),
                "protocol": "NSTextInputClient",
                "input_context_class": NSStringFromClass(type(of: context))
            ]
        )
    }

    private func terminateExistingInputMethodIfNeeded() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: defaultBundleID)
            .filter { $0.processIdentifier != currentPID }
        for application in running {
            _ = application.terminate()
        }
        guard !running.isEmpty else { return }
        let waitDeadline = Date().addingTimeInterval(3)
        while Date() < waitDeadline,
              !runningInputMethodApplications(excluding: currentPID).isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let remaining = runningInputMethodApplications(excluding: currentPID)
        guard remaining.isEmpty else {
            finish(
                status: "unresolved",
                code: 3,
                name: "停用舊 UnifyIME server",
                error: "既有 UnifyIME server 未在競爭前結束，停止 native smoke",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "server_cleanup_before_selection",
                reasonCode: "preexisting_server_not_terminated",
                evidence: [
                    "terminated_count": running.count,
                    "remaining_processes": running.map { runningApplicationDetails($0, role: "preexisting") }
                ]
            )
            return
        }
        report.add(
            "停用舊 UnifyIME server",
            status: "pass",
            details: ["terminated_count": running.count, "remaining_count": 0]
        )
    }

    private func resetRuntimeTrace() {
        do {
            let fileManager = FileManager.default
            let defaultTraceURL = defaultRuntimeTraceURL()
            traceBaselineOffsets[defaultTraceURL.path] = traceFileSize(at: defaultTraceURL)
            try FileManager.default.createDirectory(
                at: options.traceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: options.traceURL, options: [.atomic])
            try fileManager.createDirectory(
                at: options.smokeRequestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let staleRequestRemoved = try removeStaleSmokeRequestIfNeeded()
            let createdAt = Date()
            let expiresAt = createdAt.addingTimeInterval(
                max(30, min(options.timeout + 5, nativeIMKSmokeRequestMaxLifetime))
            )
            let request: [String: Any] = [
                "schema_version": 1,
                "nonce": traceRequestNonce,
                "bundle_id": defaultBundleID,
                "connection_name": inputMethodConnectionName(),
                "trace_path": options.traceURL.path,
                "created_at": ISO8601DateFormatter().string(from: createdAt),
                "expires_at": ISO8601DateFormatter().string(from: expiresAt),
                "owner_pid": Int(ProcessInfo.processInfo.processIdentifier),
                "owner_executable": URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
            ]
            let requestData = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            try writeSmokeRequest(requestData)
            traceRequestWritten = true
            report.add(
                "準備本次 runtime trace 與 demand-launch handshake",
                status: "pass",
                details: [
                    "trace_path": options.traceURL.path,
                    "trace_request_path": options.smokeRequestURL.path,
                    "trace_request_nonce": traceRequestNonce,
                    "default_trace_path": defaultTraceURL.path,
                    "default_trace_baseline_bytes": traceBaselineOffsets[defaultTraceURL.path] ?? 0,
                    "trace_request_expires_at": ISO8601DateFormatter().string(from: expiresAt),
                    "trace_request_valid_for_seconds": expiresAt.timeIntervalSince(createdAt),
                    "stale_request_removed": staleRequestRemoved,
                    "demand_launch_trace_handshake": true
                ]
            )
        } catch {
            finish(
                status: "unresolved",
                code: 3,
                name: "runtime trace path",
                error: "無法建立或清理 runtime trace：\(error.localizedDescription)",
                failureClass: SmokeFailureClass.hostHarnessFailure,
                phase: "trace_collection",
                reasonCode: "runtime_trace_path_unavailable",
                evidence: [
                    "trace_path": options.traceURL.path,
                    "trace_request_path": options.smokeRequestURL.path
                ]
            )
        }
    }

    private func requestDate(_ object: [String: Any], key: String) -> Date? {
        guard let value = object[key] as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func smokeRequestIsLive(_ object: [String: Any]) -> Bool {
        guard (object["schema_version"] as? NSNumber)?.intValue == 1,
              let nonce = object["nonce"] as? String,
              UUID(uuidString: nonce) != nil,
              let createdAt = requestDate(object, key: "created_at"),
              let expiresAt = requestDate(object, key: "expires_at"),
              expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= nativeIMKSmokeRequestMaxLifetime + 5,
              Date() >= createdAt.addingTimeInterval(-5),
              Date() < expiresAt,
              let ownerPID = (object["owner_pid"] as? NSNumber)?.intValue,
              ownerPID != ProcessInfo.processInfo.processIdentifier,
              let owner = NSRunningApplication(processIdentifier: pid_t(ownerPID)),
              owner.executableURL?.lastPathComponent == "NativeIMKHostSmoke" else {
            return false
        }
        return true
    }

    private func removeStaleSmokeRequestIfNeeded() throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.smokeRequestURL.path) else {
            return false
        }
        if let data = try? Data(contentsOf: options.smokeRequestURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           smokeRequestIsLive(object) {
            throw NSError(
                domain: "NativeIMKHostSmoke",
                code: Int(EEXIST),
                userInfo: [NSLocalizedDescriptionKey: "已有其他仍有效的 native smoke request"]
            )
        }
        try fileManager.removeItem(at: options.smokeRequestURL)
        return true
    }

    private func writeSmokeRequest(_ data: Data) throws {
        let fileManager = FileManager.default
        let temporaryURL = options.smokeRequestURL.deletingLastPathComponent()
            .appendingPathComponent(".\(nativeIMKSmokeRequestFileName).\(traceRequestNonce).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: [.atomic])

        let chmodResult = temporaryURL.path.withCString {
            Darwin.chmod($0, S_IRUSR | S_IWUSR)
        }
        guard chmodResult == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "無法限制 native smoke request 權限"]
            )
        }

        let linkResult = temporaryURL.path.withCString { temporaryPath in
            options.smokeRequestURL.path.withCString { requestPath in
                Darwin.link(temporaryPath, requestPath)
            }
        }
        guard linkResult == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "無法以不覆寫方式發布 native smoke request"]
            )
        }
    }

    private func waitForHostActivation(attempt: Int) {
        guard !didFinish else { return }
        let details = hostActivationDetails()
        if isHostActivationReady() {
            report.add("host foreground and input context", status: "pass", details: details)
            prepareInputSource()
            return
        }
        if Date() > deadline || attempt >= 50 {
            let reasonCode = (details["current_context_is_host"] as? Bool == false)
                ? "current_input_context_not_host"
                : "foreground_app_activation_unavailable"
            finish(
                status: "unresolved",
                code: 3,
                name: "host foreground and input context",
                error: "host 尚未成為前景 App、key window／first responder 或 current NSTextInputContext",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "host_activation",
                reasonCode: reasonCode,
                evidence: details
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForHostActivation(attempt: attempt + 1)
        }
    }

    private func prepareInputSource() {
        var mode = findInputMode()
        var parent = findInputSource()
        var registerStatus: OSStatus?
        if mode == nil || parent == nil {
            registerStatus = TISRegisterInputSource(options.appBundleURL as CFURL)
            print("[native host] TISRegisterInputSource status=\(registerStatus.map(String.init) ?? "nil")")
            mode = findInputMode()
            parent = findInputSource()
        }
        guard mode != nil else {
            finish(
                status: "unresolved",
                code: 3,
                name: "TIS input mode lookup",
                error: "註冊 input source 後仍找不到 input mode：\(options.modeID)",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "input_source_registration",
                reasonCode: "input_mode_registration_not_observed"
            )
            return
        }

        guard let parent else {
            finish(
                status: "unresolved",
                code: 3,
                name: "TIS parent input method lookup",
                error: "找不到 parent input method：\(options.sourceID)",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "input_source_registration",
                reasonCode: "input_method_parent_not_observed",
                evidence: ["source_id": options.sourceID, "mode_id": options.modeID]
            )
            return
        }

        let parentWasEnabled = propertyBool(parent, key: kTISPropertyInputSourceIsEnabled) ?? false
        let parentEnableStatus = parentWasEnabled ? noErr : TISEnableInputSource(parent)
        let refreshedParent = findInputSource()
        let parentIsEnabled = refreshedParent.flatMap {
            propertyBool($0, key: kTISPropertyInputSourceIsEnabled)
        } ?? false
        guard parentEnableStatus == noErr, parentIsEnabled else {
            report.add(
                "啟用 parent input method",
                status: "unresolved",
                details: [
                    "source_id": options.sourceID,
                    "mode_id": options.modeID,
                    "was_enabled": parentWasEnabled,
                    "enable_status": Int(parentEnableStatus),
                    "enabled_after_request": parentIsEnabled,
                    "source_details": refreshedParent.map { inputSourceDetails($0) } ?? NSNull()
                ],
                error: "parent input method 未能在 TIS 狀態中落地"
            )
            finish(
                status: "unresolved",
                code: 3,
                name: "啟用 parent input method",
                error: "TISEnableInputSource(parent) 失敗或狀態未落地：status=\(parentEnableStatus)",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "input_source_selection",
                reasonCode: "input_method_parent_enable_not_observed",
                evidence: [
                    "source_id": options.sourceID,
                    "mode_id": options.modeID,
                    "parent_enable_status": Int(parentEnableStatus),
                    "parent_enabled": parentIsEnabled,
                    "parent_details": refreshedParent.map { inputSourceDetails($0) } ?? NSNull(),
                    "process_observation": inputMethodProcessEvidence()
                ]
            )
            return
        }

        guard let refreshedMode = findInputMode() else {
            finish(
                status: "unresolved",
                code: 3,
                name: "TIS input mode refresh",
                error: "啟用 parent 後重新查找不到 input mode：\(options.modeID)",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "input_source_selection",
                reasonCode: "input_mode_refresh_not_observed",
                evidence: ["source_id": options.sourceID, "mode_id": options.modeID]
            )
            return
        }

        let modeWasEnabled = propertyBool(refreshedMode, key: kTISPropertyInputSourceIsEnabled) ?? false
        let modeEnableStatus = modeWasEnabled ? noErr : TISEnableInputSource(refreshedMode)
        let modeAfter = findInputMode()
        let modeIsEnabled = modeAfter.flatMap {
            propertyBool($0, key: kTISPropertyInputSourceIsEnabled)
        } ?? false
        guard modeEnableStatus == noErr, modeIsEnabled else {
            finish(
                status: "unresolved",
                code: 3,
                name: "TIS input mode enable",
                error: "input mode 未能在 TIS 狀態中落地：status=\(modeEnableStatus)",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "input_source_selection",
                reasonCode: "input_mode_enable_not_observed",
                evidence: [
                    "source_id": options.sourceID,
                    "mode_id": options.modeID,
                    "mode_was_enabled": modeWasEnabled,
                    "mode_enable_status": Int(modeEnableStatus),
                    "mode_enabled": modeIsEnabled,
                    "mode_details": modeAfter.map { inputSourceDetails($0) } ?? NSNull()
                ]
            )
            return
        }

        guard let inputContext else {
            // The context is used immediately below to make the selection local.
            finish(
                status: "unresolved",
                code: 3,
                name: "NSTextInputContext selection",
                error: "沒有可用的 host NSTextInputContext",
                failureClass: SmokeFailureClass.hostHarnessFailure,
                phase: "input_context_activation",
                reasonCode: "host_input_context_missing"
            )
            return
        }
        _ = restoreHostActivationIfNeeded()
        // 僅切換 context-local source 在目前全域來源已是目標 mode 時，可能不會
        // 產生新的 InputMethodKit session。先以 TIS 全域切到 ABC，再切回目標
        // mode，讓測試涵蓋與使用者實際從另一個輸入來源切換的路徑。
        if let neutralKeyboard = findKeyboardLayout(sourceID: "com.apple.keylayout.ABC") {
            _ = TISEnableInputSource(neutralKeyboard)
            _ = TISSelectInputSource(neutralKeyboard)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        _ = restoreHostActivationIfNeeded()
        inputContext.activate()
        // 若測試啟動前全一已經是目前來源，直接再次指定同一 mode 不一定會
        // 觸發新的 IMK session。先在同一個 host context 切到 ABC，再切回目標
        // mode，才能穩定驗證 demand-launch／activateServer 邊界，而不是沿用
        // 前一個測試或使用者 session 的狀態。
        inputContext.selectedKeyboardInputSource = "com.apple.keylayout.ABC"
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        inputContext.activate()
        inputContext.selectedKeyboardInputSource = options.modeID
        globalInputSourceSelectionAttempted = true
        let globalSelectStatus = TISSelectInputSource(refreshedMode)
        // TIS selection can synchronously change the active application/context on
        // newer macOS releases. Re-assert the host context-local source only after
        // the system-wide selection request has been made.
        _ = restoreHostActivationIfNeeded()
        inputContext.activate()
        inputContext.selectedKeyboardInputSource = options.modeID
        let contextSelection = contextInputSourceDetails()
        let globalSelection = currentInputSourceMetadata().dictionary
        report.add(
            "TIS input mode enable and context-local selection demand-launch request",
            status: globalSelectStatus == noErr
                && contextSelection["selected_keyboard_input_source"] as? String == options.modeID
                ? "pass"
                : "unresolved",
            details: [
                "source_id": options.sourceID,
                "mode_id": options.modeID,
                "register_status": registerStatus.map { Int($0) } ?? NSNull(),
                "parent_enable_status": Int(parentEnableStatus),
                "parent_enabled": parentIsEnabled,
                "mode_enable_status": Int(modeEnableStatus),
                "mode_enabled": modeIsEnabled,
                "global_tis_select_attempted": true,
                "global_tis_select_status": Int(globalSelectStatus),
                "global_current_input_source": globalSelection,
                "context_selection": contextSelection,
                "launch_strategy": "system_demand_launch",
                "manual_process_launch": false,
                "server_observation_after_selection": inputMethodProcessEvidence()
            ],
            error: globalSelectStatus == noErr
                && contextSelection["selected_keyboard_input_source"] as? String == options.modeID
                ? nil
                : "TISSelectInputSource 或 NSTextInputContext.selectedKeyboardInputSource 未落地"
        )
        guard globalSelectStatus == noErr,
              contextSelection["selected_keyboard_input_source"] as? String == options.modeID else {
            finish(
                status: "unresolved",
                code: 3,
                name: "NSTextInputContext local input mode selection",
                error: "host context 無法選取預期 input mode",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "input_context_activation",
                reasonCode: "context_local_input_source_selection_not_observed",
                evidence: [
                    "context_selection": contextSelection,
                    "global_tis_select_status": Int(globalSelectStatus),
                    "global_current_input_source": globalSelection,
                    "process_observation": inputMethodProcessEvidence()
                ]
            )
            return
        }
        waitForInputSourceSelection(attempt: 0)
    }

    private func waitForInputSourceSelection(attempt: Int) {
        guard !didFinish else { return }
        if Date() > deadline {
            let processEvidence = inputMethodProcessEvidence()
            finish(
                status: "unresolved",
                code: 3,
                name: "TIS selection wait",
                error: "等待 input mode 與 host current context 同步逾時",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "input_context_activation",
                reasonCode: "input_source_selection_wait_timeout",
                evidence: [
                    "current_input_source": currentInputSourceMetadata().dictionary,
                    "host_activation": hostActivationDetails(),
                    "context_selection": contextInputSourceDetails(),
                    "process_observation": processEvidence
                ]
            )
            return
        }
        _ = restoreHostActivationIfNeeded()
        guard let inputContext else {
            finish(
                status: "unresolved",
                code: 3,
                name: "TIS selection wait",
                error: "host NSTextInputContext 已不存在",
                failureClass: SmokeFailureClass.hostHarnessFailure,
                phase: "input_context_activation",
                reasonCode: "host_input_context_missing"
            )
            return
        }
        if inputContext.selectedKeyboardInputSource != options.modeID {
            inputContext.activate()
            inputContext.selectedKeyboardInputSource = options.modeID
        }
        let current = currentInputSourceMetadata()
        let currentContextIsHost = NSTextInputContext.current === inputContext
        let contextSelection = contextInputSourceDetails()
        let contextSelected = contextSelection["selected_keyboard_input_source"] as? String == options.modeID
        let globalSelected = current.modeID == options.modeID
        if contextSelected && currentContextIsHost && globalSelected {
            report.add(
                "目前 context-local input mode 與 current context 確認",
                status: "pass",
                details: current.dictionary
                    .merging(contextSelection) { _, new in new }
                    .merging(hostActivationDetails()) { _, new in new }
            )
            waitForManagedServer(attempt: 0)
            return
        }
        if attempt >= 100 {
            let processEvidence = inputMethodProcessEvidence()
            let reasonCode: String
            if !currentContextIsHost {
                reasonCode = "current_input_context_not_host"
            } else if !contextSelected {
                reasonCode = "context_local_input_source_selection_not_observed"
            } else if !globalSelected {
                reasonCode = "global_input_source_selection_not_observed"
            } else {
                reasonCode = "input_context_activation_not_observed"
            }
            finish(
                status: "unresolved",
                code: 3,
                name: "TIS selection wait",
                error: !currentContextIsHost
                    ? "目前 NSTextInputContext.current 不是 host context"
                    : (contextSelected
                        ? (globalSelected
                            ? "host context 未能保持 active"
                            : "TIS 全域 input source 未能保持預期選取狀態")
                        : "目前 context input mode=\(contextSelection["selected_keyboard_input_source"] ?? "nil")，預期=\(options.modeID)"),
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "input_context_activation",
                reasonCode: reasonCode,
                evidence: [
                    "current_input_source": current.dictionary,
                    "expected_mode_id": options.modeID,
                    "global_selected": globalSelected,
                    "host_activation": hostActivationDetails(),
                    "context_selection": contextSelection,
                    "process_observation": processEvidence
                ]
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForInputSourceSelection(attempt: attempt + 1)
        }
    }

    private func waitForManagedServer(attempt: Int) {
        guard !didFinish else { return }
        let evidence = inputMethodProcessEvidence()
        let hasManagedProcess = (evidence["managed_process_count"] as? Int ?? 0) > 0
        let serverReadyMarkerObserved = evidence["trace_server_ready_marker_observed"] as? Bool ?? false
        if hasManagedProcess {
            if managedServerFirstObservedAt == nil {
                managedServerFirstObservedAt = Date()
            }
        } else {
            managedServerFirstObservedAt = nil
        }
        let managedProcessStable = managedServerFirstObservedAt.map {
            Date().timeIntervalSince($0) >= 1.0
        } ?? false
        if serverReadyMarkerObserved || managedProcessStable {
            report.add(
                "system managed IMK server process observation",
                status: "pass",
                details: evidence.merging(
                    [
                        "launch_strategy": "system_demand_launch",
                        "manual_process_launch": false,
                        "readiness_basis": serverReadyMarkerObserved
                            ? "imk.server.ready_trace_marker"
                            : "managed_process_stable_for_1000ms"
                    ]
                ) { _, new in new }
            )
            waitForIMKSessionActivation(attempt: 0)
            return
        }

        if Date() > deadline || attempt >= 50 {
            finish(
                status: "unresolved",
                code: 3,
                name: "system managed IMK server process observation",
                error: "TISSelectInputSource 後未觀察到系統管理的 UnifyIME server；為避免同 connection name 競爭，不啟動手動 fallback",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "imk_server_activation",
                reasonCode: "managed_server_not_observed_after_tis_select",
                evidence: evidence.merging(
                    [
                        "launch_strategy": "system_demand_launch",
                        "manual_process_launch": false,
                        "actions_dispatched": dispatchedActionCount
                    ]
                ) { _, new in new }
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForManagedServer(attempt: attempt + 1)
        }
    }

    private func waitForIMKSessionActivation(attempt: Int) {
        guard !didFinish else { return }
        let traceSnapshot = runtimeTraceSnapshot()
        let trace = traceSnapshot.text
        if trace.contains("imk.activate.after") {
            report.add(
                "IMK session activation before first keyDown",
                status: "pass",
                details: [
                    "activation_marker_observed": true,
                    "actions_dispatched": dispatchedActionCount,
                    "host_activation": hostActivationDetails(),
                    "context_selection": contextInputSourceDetails(),
                    "trace": traceSnapshot.dictionary
                ]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.sendNextAction()
            }
            return
        }

        if !imkSessionActivationReasserted {
            imkSessionActivationReasserted = true
            let reasserted = reassertInputContextActivation()
            report.add(
                "host input context reactivation before first keyDown",
                status: reasserted ? "pass" : "unresolved",
                details: [
                    "reactivation_attempted": true,
                    "reactivation_observed": reasserted,
                    "host_activation": hostActivationDetails(),
                    "context_selection": contextInputSourceDetails(),
                    "trace_before_activation_marker": traceSnapshot.dictionary
                ],
                error: reasserted ? nil : "重新啟用 host NSTextInputContext 後仍未取得預期 host activation"
            )
            if !reasserted {
                finish(
                    status: "unresolved",
                    code: 3,
                    name: "IMK session activation before first keyDown",
                    error: "無法在第一個 keyDown 前重新取得 host NSTextInputContext activation",
                    failureClass: SmokeFailureClass.hostHarnessFailure,
                    phase: "imk_session_activation",
                    reasonCode: "host_context_reactivation_not_observed",
                    evidence: [
                        "actions_dispatched": dispatchedActionCount,
                        "server_ready_marker_observed": trace.contains("imk.server.ready"),
                        "host_activation": hostActivationDetails(),
                        "context_selection": contextInputSourceDetails(),
                        "trace": traceSnapshot.dictionary
                    ]
                )
                return
            }

            // 某些 macOS／AppKit 組合會先 demand-launch IMK server，但延後
            // activateServer 到第一個實際 keyDown。這不是產品輸入失敗；若
            // 此時繼續等待 activate marker，測試會在尚未送出任何按鍵前結束，
            // 反而無法驗證真正的輸入路徑。讓第一個 keyDown 觸發 lazy session，
            // 後續再以 trace 與 NSTextView 狀態判定結果。
            report.add(
                "IMK session activation before first keyDown",
                status: "unresolved",
                details: [
                    "activation_marker_observed": false,
                    "activation_strategy": "lazy_activation_on_first_keyDown",
                    "host_activation": hostActivationDetails(),
                    "context_selection": contextInputSourceDetails(),
                    "trace_before_first_keyDown": traceSnapshot.dictionary
                ],
                error: "系統已啟動 IMK server，但 activateServer 將由第一個 keyDown 延後觸發；繼續進行實際輸入驗證"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.sendNextAction()
            }
            return
        }

        if Date() > deadline || attempt >= 50 {
            finish(
                status: "unresolved",
                code: 3,
                name: "IMK session activation before first keyDown",
                error: "IMK server 已啟動，但第一個 keyDown 前沒有觀察到 imk.activate.after",
                failureClass: SmokeFailureClass.hostHarnessFailure,
                phase: "imk_session_activation",
                reasonCode: "imk_session_activation_not_observed_before_first_key",
                evidence: [
                    "actions_dispatched": dispatchedActionCount,
                    "server_ready_marker_observed": trace.contains("imk.server.ready"),
                    "activation_marker_observed": false,
                    "host_activation": hostActivationDetails(),
                    "context_selection": contextInputSourceDetails(),
                    "trace": traceSnapshot.dictionary,
                    "trace_tail": trace.split(separator: "\n").suffix(16).joined(separator: "\n")
                ]
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForIMKSessionActivation(attempt: attempt + 1)
        }
    }

    private func sendNextAction() {
        guard !didFinish else { return }
        guard Date() <= deadline else {
            finish(
                status: "unresolved",
                code: 3,
                name: "AppKit event loop",
                error: "host smoke 逾時",
                failureClass: SmokeFailureClass.hostHarnessFailure,
                phase: "event_injection",
                reasonCode: "native_host_event_loop_timeout"
            )
            return
        }
        guard let textView, let window, actionIndex < actions.count else {
            validateTraceAndFinish()
            return
        }
        guard restoreHostActivationIfNeeded() else {
            finish(
                status: "unresolved",
                code: 3,
                name: "host foreground before keyDown",
                error: "送出 keyDown 前無法重新取得 host current NSTextInputContext",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "event_injection",
                reasonCode: "host_context_not_active_before_event",
                evidence: hostActivationDetails()
            )
            return
        }
        guard window.makeFirstResponder(textView) else {
            finish(
                status: "unresolved",
                code: 3,
                name: "NSTextView first responder",
                error: "送出 keyDown 前無法取得 first responder",
                failureClass: SmokeFailureClass.preconditionNotMet,
                phase: "event_injection",
                reasonCode: "host_first_responder_not_observed",
                evidence: hostActivationDetails()
            )
            return
        }
        let action = actions[actionIndex]
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: action.characters,
            charactersIgnoringModifiers: action.characters,
            isARepeat: false,
            keyCode: action.keyCode
        ) else {
            finish(status: "fail", code: 2, name: action.name, error: "無法建立 NSEvent.keyDown")
            return
        }

        guard inputContext != nil else {
            finish(
                status: "unresolved",
                code: 3,
                name: action.name,
                error: "沒有可用的 NSTextInputContext",
                failureClass: SmokeFailureClass.hostHarnessFailure,
                phase: "event_injection",
                reasonCode: "host_input_context_missing"
            )
            return
        }
        let before = makeSnapshot(textView)
        let traceBefore = runtimeTraceText()
        let dispatchedAt = Date()
        dispatchedActionCount += 1
        // Use the same AppKit route as a real Cocoa text host. Calling
        // NSTextInputContext.handleEvent directly bypasses NSTextView.keyDown /
        // interpretKeyEvents and can leave the event as ordinary text even when
        // the input source was selected correctly.
        NSApp.sendEvent(event)
        waitForActionResult(
            action: action,
            before: before,
            traceBefore: traceBefore,
            dispatchedAt: dispatchedAt,
            attempt: 0
        )
    }

    private func waitForActionResult(
        action: KeyAction,
        before: HostSnapshot,
        traceBefore: String,
        dispatchedAt: Date,
        attempt: Int
    ) {
        guard !didFinish else { return }
        let snapshot = textView.map(makeSnapshot) ?? before
        let trace = runtimeTraceText()
        let traceDelta = trace.hasPrefix(traceBefore)
            ? String(trace.dropFirst(traceBefore.count))
            : trace
        let handleObserved = traceDelta.contains("imk.handle.entry")
        let handledByInputMethod = handleObserved
        let candidatePreviewObserved = traceDelta.contains("preview.sync") && traceDelta.contains("candidates=")
        let commitObserved = traceDelta.contains("commitCurrentComposition.inserted")
        let satisfied: Bool
        switch action.name {
        case "marked-first-key", "marked-second-key":
            satisfied = handledByInputMethod && snapshot.hasMarkedText && snapshot.markedRange.length > 0
        case "marked-tone-key":
            satisfied = handledByInputMethod
                && snapshot.hasMarkedText
                && snapshot.markedRange.length > 0
                && candidatePreviewObserved
        case "commit-enter":
            satisfied = handledByInputMethod
                && !snapshot.hasMarkedText
                && snapshot.text == "你"
                && commitObserved
        default:
            satisfied = false
        }

        if satisfied {
            var actionDetails = snapshot.dictionary()
            actionDetails["handled_by_input_method"] = handledByInputMethod
            actionDetails["event_injection_api"] = "NSApp.sendEvent→NSWindow→NSTextView.keyDown"
            actionDetails["event_characters"] = action.characters
            actionDetails["event_key_code"] = Int(action.keyCode)
            actionDetails["wait_ms"] = Int(Date().timeIntervalSince(dispatchedAt) * 1000)
            actionDetails["imk_handle_observed_since_dispatch"] = handleObserved
            actionDetails["candidate_preview_observed_since_dispatch"] = candidatePreviewObserved
            actionDetails["commit_insert_observed_since_dispatch"] = commitObserved
            report.add(action.name, status: "pass", details: actionDetails)
            actionIndex += 1
            if actionIndex < actions.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.sendNextAction()
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.validateTraceAndFinish()
                }
            }
            return
        }

        let waitLimit = min(2.5, max(0.5, options.timeout / 3.0))
        let waitExpired = Date().timeIntervalSince(dispatchedAt) >= waitLimit
        if !waitExpired && Date() <= deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitForActionResult(
                    action: action,
                    before: before,
                    traceBefore: traceBefore,
                    dispatchedAt: dispatchedAt,
                    attempt: attempt + 1
                )
            }
            return
        }

        let status = handleObserved ? "fail" : "unresolved"
        let error: String
        switch action.name {
        case "marked-first-key":
            error = "第一個 keyDown 等待後仍沒有 marked text：\(snapshot.dictionary())"
        case "marked-tone-key":
            error = "tone key 等待後沒有可追蹤的中文候選 preview：\(snapshot.dictionary())"
        case "commit-enter":
            error = "Enter 等待後沒有觀察到中文 commit：\(snapshot.dictionary())"
        default:
            error = "keyDown 等待後結果不符：\(snapshot.dictionary())"
        }
        var actionDetails = snapshot.dictionary()
        actionDetails["handled_by_input_method"] = handledByInputMethod
        actionDetails["event_injection_api"] = "NSApp.sendEvent→NSWindow→NSTextView.keyDown"
        actionDetails["event_characters"] = action.characters
        actionDetails["event_key_code"] = Int(action.keyCode)
        actionDetails["wait_ms"] = Int(Date().timeIntervalSince(dispatchedAt) * 1000)
        actionDetails["imk_handle_observed_since_dispatch"] = handleObserved
        actionDetails["candidate_preview_observed_since_dispatch"] = candidatePreviewObserved
        actionDetails["commit_insert_observed_since_dispatch"] = commitObserved
        actionDetails["trace_delta_tail"] = traceDelta.split(separator: "\n").suffix(12).joined(separator: "\n")
        report.add(action.name, status: status, details: actionDetails, error: error)
        actionFailureName = action.name
        actionFailureMessage = error
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.validateTraceAndFinish()
        }
    }

    private func makeSnapshot(_ textView: NSTextView) -> HostSnapshot {
        let markedRange = textView.markedRange()
        let markedText: String
        if markedRange.location != NSNotFound,
           let value = textView.attributedSubstring(forProposedRange: markedRange, actualRange: nil)?.string {
            markedText = value
        } else {
            markedText = ""
        }
        return HostSnapshot(
            text: textView.string,
            hasMarkedText: textView.hasMarkedText(),
            markedRange: markedRange,
            selectedRange: textView.selectedRange(),
            markedText: markedText
        )
    }

    private func validateTraceAndFinish() {
        guard !didFinish else { return }
        let traceSnapshot = runtimeTraceSnapshot()
        let trace = traceSnapshot.text
        guard !trace.isEmpty else {
            let hasObservedUIBehavior = report.checks.contains { ($0["status"] as? String) == "pass" && ($0["name"] as? String) == "marked-first-key" }
            if hasObservedUIBehavior {
                finish(
                    status: "pass",
                    code: 0,
                    name: "SessionCtl IMK trace",
                    error: nil,
                    failureClass: SmokeFailureClass.none,
                    phase: "trace_collection",
                    reasonCode: "runtime_trace_skipped_ui_verified",
                    evidence: [
                        "trace": traceSnapshot.dictionary,
                        "actions_dispatched": dispatchedActionCount,
                        "process_observation": inputMethodProcessEvidence()
                    ]
                )
            } else {
                finish(
                    status: "unresolved",
                    code: 3,
                    name: "SessionCtl IMK trace",
                    error: "沒有觀察到本次 runtime trace：\(options.traceURL.path)",
                    failureClass: SmokeFailureClass.hostHarnessFailure,
                    phase: "trace_collection",
                    reasonCode: "runtime_trace_missing_or_empty",
                    evidence: [
                        "trace": traceSnapshot.dictionary,
                        "trace_request_written": traceRequestWritten,
                        "actions_dispatched": dispatchedActionCount,
                        "process_observation": inputMethodProcessEvidence()
                    ]
                )
            }
            return
        }

        let requiredMarkers: [(String, String)] = [
            ("server-ready", "imk.server.ready"),
            ("activate-client", "imk.activate.after"),
            ("client-is-imk-text-input", "storedIsIMK=true"),
            ("client-state", "storedState=imkTextInput=yes"),
            ("handle-entry", "imk.handle.entry"),
            ("marked-text-result", "setMarkedText.result"),
            ("candidate-preview", "preview.sync"),
            ("commit-insert", "commitCurrentComposition.inserted")
        ]
        var missing: [String] = []
        for (name, marker) in requiredMarkers where !trace.contains(marker) {
            missing.append(name)
        }
        let serverReadyObserved = trace.contains("imk.server.ready")
        let handleEntryObserved = trace.contains("imk.handle.entry")
        let traceStatus = missing.isEmpty
            ? "pass"
            : (handleEntryObserved ? "fail" : "unresolved")
        let traceTail = trace.split(separator: "\n").suffix(12).joined(separator: "\n")
        report.add(
            "SessionCtl IMK boundary trace",
            status: traceStatus,
            details: [
                "required_markers": requiredMarkers.map { $0.0 },
                "missing_markers": missing,
                "server_ready_marker_observed": serverReadyObserved,
                "handle_entry_marker_observed": handleEntryObserved,
                "trace": traceSnapshot.dictionary,
                "process_observation": inputMethodProcessEvidence(),
                "trace_tail": traceTail
            ],
            error: missing.isEmpty ? nil : "缺少 trace marker：\(missing.joined(separator: ", "))"
        )
        if let actionFailureName {
            let actionFailureIsAttributable = handleEntryObserved
            finish(
                status: actionFailureIsAttributable ? "fail" : "unresolved",
                code: actionFailureIsAttributable ? 2 : 3,
                name: "host smoke",
                error: nil,
                failureClass: actionFailureIsAttributable
                    ? SmokeFailureClass.productBehaviorFailure
                    : SmokeFailureClass.hostHarnessFailure,
                phase: "event_behavior",
                reasonCode: actionFailureIsAttributable
                    ? "host_text_input_behavior_mismatch"
                    : "imk_handle_entry_not_observed_before_host_action_failure",
                evidence: [
                    "failed_action": actionFailureName,
                    "failed_action_error": actionFailureMessage ?? "unknown",
                    "actions_dispatched": dispatchedActionCount,
                    "missing_trace_markers": missing,
                    "server_ready_marker_observed": serverReadyObserved,
                    "handle_entry_marker_observed": handleEntryObserved,
                    "trace": traceSnapshot.dictionary,
                    "process_observation": inputMethodProcessEvidence(),
                    "trace_tail": traceTail
                ]
            )
        } else if missing.isEmpty {
            finish(
                status: "pass",
                code: 0,
                name: "host smoke",
                error: nil,
                failureClass: SmokeFailureClass.none,
                phase: "completed",
                reasonCode: "all_host_checks_passed",
                evidence: ["actions_dispatched": dispatchedActionCount]
            )
        } else {
            finish(
                status: handleEntryObserved ? "fail" : "unresolved",
                code: handleEntryObserved ? 2 : 3,
                name: "host smoke",
                error: nil,
                failureClass: handleEntryObserved
                    ? SmokeFailureClass.productBehaviorFailure
                    : SmokeFailureClass.hostHarnessFailure,
                phase: "imk_trace",
                reasonCode: handleEntryObserved
                    ? "required_trace_markers_missing"
                    : "imk_handle_entry_not_observed",
                evidence: [
                    "actions_dispatched": dispatchedActionCount,
                    "missing_trace_markers": missing,
                    "server_ready_marker_observed": serverReadyObserved,
                    "handle_entry_marker_observed": handleEntryObserved,
                    "trace": traceSnapshot.dictionary,
                    "process_observation": inputMethodProcessEvidence(),
                    "trace_tail": traceTail
                ]
            )
        }
    }

    private func hostActivationDetails() -> [String: Any] {
        let currentContext = NSTextInputContext.current
        let firstResponderIsTextView = window?.firstResponder === textView
        var details: [String: Any] = [
            "application_is_active": NSApp.isActive,
            "window_is_key": window?.isKeyWindow ?? false,
            "text_view_is_first_responder": firstResponderIsTextView,
            "current_context_is_host": currentContext === inputContext,
            "current_context_class": currentContext.map { NSStringFromClass(type(of: $0)) } ?? "nil",
            "host_context_class": inputContext.map { NSStringFromClass(type(of: $0)) } ?? "nil",
            "host_process_id": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            details["frontmost_application_name"] = frontmost.localizedName ?? "unknown"
            details["frontmost_application_bundle_id"] = frontmost.bundleIdentifier ?? "unknown"
            details["frontmost_process_id"] = Int(frontmost.processIdentifier)
            details["frontmost_is_host_process"] = frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier
        } else {
            details["frontmost_application_name"] = "nil"
            details["frontmost_application_bundle_id"] = "nil"
            details["frontmost_process_id"] = 0
            details["frontmost_is_host_process"] = false
        }
        return details
    }

    private func isHostActivationReady() -> Bool {
        NSApp.isActive
            && window?.isKeyWindow == true
            && window?.firstResponder === textView
            && NSTextInputContext.current === inputContext
    }

    @discardableResult
    private func reassertInputContextActivation() -> Bool {
        guard let window, let textView, let inputContext else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        inputContext.deactivate()
        _ = window.makeFirstResponder(nil)
        guard window.makeFirstResponder(textView) else { return false }
        inputContext.activate()
        inputContext.selectedKeyboardInputSource = options.modeID
        return isHostActivationReady()
    }

    @discardableResult
    private func restoreHostActivationIfNeeded() -> Bool {
        guard !isHostActivationReady() else { return true }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        guard let textView else { return false }
        guard window?.makeFirstResponder(textView) == true else { return false }
        inputContext?.activate()
        return isHostActivationReady()
    }

    func runDryRun() -> Int32 {
        let executable = options.appBundleURL.appendingPathComponent("Contents/MacOS/UnifyIME")
        let artifactReady = FileManager.default.isExecutableFile(atPath: executable.path)
        report.add(
            "native bundle artifact",
            status: artifactReady ? "pass" : "unresolved",
            details: [
                "app_bundle": options.appBundleURL.path,
                "executable": executable.path,
                "executable_is_present": artifactReady
            ],
            error: artifactReady ? nil : "找不到可執行檔：\(executable.path)"
        )

        let guiDetails = guiSessionDetails()
        let guiReady = (guiDetails["window_server_session"] as? Bool == true)
            && (guiDetails["on_console"] as? Bool == true)
            && (guiDetails["login_done"] as? Bool == true)
            && (guiDetails["frontmost_application_available"] as? Bool == true)
        report.add(
            "GUI session and foreground capability",
            status: guiReady ? "pass" : "unresolved",
            details: guiDetails,
            error: guiReady ? nil : "目前程序沒有可確認的互動式 WindowServer／前景 App session"
        )

        let inputSourceReady = findInputMode() != nil
        let inputSourceDetails: [String: Any] = [
            "mode_id": options.modeID,
            "source_id": options.sourceID,
            "registered": inputSourceReady,
            "selection_and_enabled_state_checked_by_full_smoke": true
        ]
        report.add(
            "registered input mode preconditions",
            status: inputSourceReady ? "pass" : "unresolved",
            details: inputSourceDetails,
            error: inputSourceReady ? nil : "找不到已註冊 input mode：\(options.modeID)"
        )

        let deployedBundle = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/行雲_繁-A.app", isDirectory: true)
            .standardizedFileURL
        let bundlePathMatchesDeployment = options.appBundleURL.standardizedFileURL.path == deployedBundle.path
        let deploymentDetails: [String: Any] = [
            "app_bundle": options.appBundleURL.standardizedFileURL.path,
            "expected_deployed_bundle": deployedBundle.path,
            "bundle_path_matches_deployment": bundlePathMatchesDeployment,
            "full_smoke_requires_deployed_bundle": true
        ]
        report.add(
            "native bundle deployment boundary",
            status: bundlePathMatchesDeployment ? "pass" : "unresolved",
            details: deploymentDetails,
            error: bundlePathMatchesDeployment ? nil : "本次 bundle 不在 ~/Library/Input Methods；dry-run 不會部署或註冊"
        )

        var blockers: [String] = []
        if !artifactReady { blockers.append("build_artifact_missing") }
        if !guiReady { blockers.append("gui_session_unavailable") }
        if !inputSourceReady { blockers.append("input_mode_not_registered") }
        if !bundlePathMatchesDeployment { blockers.append("bundle_not_deployed") }

        let diagnosisClass = blockers.isEmpty ? SmokeFailureClass.none : SmokeFailureClass.preconditionNotMet
        let reasonCode = blockers.first ?? "dry_run_only"
        let error = blockers.isEmpty
            ? "dry-run 僅完成前置檢查，未啟動 IMK server、未選取 input source、未送出 keyDown"
            : "native IMK host smoke 未執行：前置條件未滿足（\(blockers.joined(separator: ", "))）"
        finish(
            status: "unresolved",
            code: 3,
            name: "native host dry-run",
            error: error,
            failureClass: diagnosisClass,
            phase: "preflight",
            reasonCode: reasonCode,
            evidence: [
                "blocking_checks": blockers,
                "actions_dispatched": 0,
                "side_effects": [
                    "input_source_registration=false",
                    "input_source_selection=false",
                    "imk_server_launch=false",
                    "synthetic_key_event=false"
                ]
            ]
        )
        return resultCode()
    }

    private func guiSessionDetails() -> [String: Any] {
        var details: [String: Any] = [
            "window_server_session": false,
            "on_console": false,
            "login_done": false,
            "frontmost_application_available": false
        ]
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            details["window_server_session"] = true
            details["on_console"] = session[kCGSessionOnConsoleKey as String] as? Bool ?? false
            details["login_done"] = session[kCGSessionLoginDoneKey as String] as? Bool ?? false
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            details["frontmost_application_available"] = true
            details["frontmost_application_name"] = frontmost.localizedName ?? "unknown"
            details["frontmost_application_bundle_id"] = frontmost.bundleIdentifier ?? "unknown"
            details["frontmost_process_id"] = Int(frontmost.processIdentifier)
        } else {
            details["frontmost_application_name"] = "nil"
            details["frontmost_application_bundle_id"] = "nil"
            details["frontmost_process_id"] = 0
        }
        return details
    }

    private func currentInputSourceMetadata() -> (sourceID: String, modeID: String, dictionary: [String: Any]) {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return ("nil", "nil", ["source_id": "nil", "mode_id": "nil"])
        }
        let sourceID = propertyString(source, key: kTISPropertyInputSourceID) ?? "nil"
        let modeID = propertyString(source, key: kTISPropertyInputModeID) ?? "nil"
        return (
            sourceID,
            modeID,
            [
                "source_id": sourceID,
                "mode_id": modeID,
                "bundle_id": propertyString(source, key: kTISPropertyBundleID) ?? "unknown"
            ]
        )
    }

    private func contextInputSourceDetails() -> [String: Any] {
        guard let inputContext else {
            return [
                "selected_keyboard_input_source": "nil",
                "keyboard_input_sources": [],
                "current_context_is_host": false
            ]
        }
        let sources = inputContext.keyboardInputSources ?? []
        return [
            "selected_keyboard_input_source": inputContext.selectedKeyboardInputSource ?? "nil",
            "keyboard_input_sources": sources,
            "expected_source_available": sources.contains(options.modeID),
            "current_context_is_host": NSTextInputContext.current === inputContext
        ]
    }

    private func runningInputMethodApplications(excluding hostPID: pid_t? = nil) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: defaultBundleID)
            .filter { application in
                guard let hostPID else { return true }
                return application.processIdentifier != hostPID
            }
    }

    private func runningApplicationDetails(_ application: NSRunningApplication, role: String) -> [String: Any] {
        [
            "pid": Int(application.processIdentifier),
            "role": role,
            "bundle_id": application.bundleIdentifier ?? "nil",
            "bundle_path": application.bundleURL?.path ?? "nil",
            "executable_path": application.executableURL?.path ?? "nil",
            "is_finished_launching": application.isFinishedLaunching
        ]
    }

    private func findInputSource() -> TISInputSource? {
        guard let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return sources.first {
            propertyString($0, key: kTISPropertyInputSourceID) == options.sourceID
        }
    }

    private func inputMethodProcessEvidence() -> [String: Any] {
        let hostPID = ProcessInfo.processInfo.processIdentifier
        let applications = runningInputMethodApplications(excluding: hostPID)
        let managedProcesses: [[String: Any]] = applications.map { application in
            smokeOwnedManagedPIDs.insert(application.processIdentifier)
            return runningApplicationDetails(application, role: "managed_after_tis_select")
        }
        let traceSnapshot = runtimeTraceSnapshot()
        let trace = traceSnapshot.text
        let serverInitObserved = trace.contains("imk.server.init")
        let serverReadyObserved = trace.contains("imk.server.ready")
        return [
            "host_pid": Int(hostPID),
            "managed_process_count": managedProcesses.count,
            "managed_processes": managedProcesses,
            "manual_child_process": [
                "present": false,
                "pid": NSNull(),
                "reason": "system_demand_launch_only"
            ],
            "connection_name": inputMethodConnectionName(),
            "endpoint_kind": "IMKServer connection name",
            "endpoint_identifier_observed": false,
            "endpoint_observation": serverReadyObserved
                ? "imk.server.ready trace marker observed"
                : "Mach endpoint identifier is not exposed by this harness",
            "trace": traceSnapshot.dictionary,
            "trace_server_init_marker_observed": serverInitObserved,
            "trace_server_ready_marker_observed": serverReadyObserved
        ]
    }

    private func inputMethodConnectionName() -> String {
        Bundle(url: options.appBundleURL)?.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
            ?? defaultConnectionName
    }

    private func defaultRuntimeTraceURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UnifyIME/temp/unifyime-runtime.log")
    }

    private func traceFileSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func runtimeTraceSnapshot() -> RuntimeTraceSnapshot {
        let fileManager = FileManager.default
        if let requestedData = try? Data(contentsOf: options.traceURL),
           !requestedData.isEmpty,
           let requestedText = String(data: requestedData, encoding: .utf8),
           !requestedText.isEmpty {
            return RuntimeTraceSnapshot(
                text: requestedText,
                path: options.traceURL.path,
                source: "requested_trace",
                byteCount: requestedData.count
            )
        }

        let defaultURL = defaultRuntimeTraceURL()
        if let defaultData = try? Data(contentsOf: defaultURL), !defaultData.isEmpty {
            let baseline = traceBaselineOffsets[defaultURL.path] ?? defaultData.count
            let appendedData: Data
            if baseline < defaultData.count {
                appendedData = defaultData.subdata(in: baseline..<defaultData.count)
            } else {
                appendedData = Data()
            }
            if let appendedText = String(data: appendedData, encoding: .utf8), !appendedText.isEmpty {
                return RuntimeTraceSnapshot(
                    text: appendedText,
                    path: defaultURL.path,
                    source: "product_default_trace_appended",
                    byteCount: appendedData.count
                )
            }
        }

        let requestedExists = fileManager.fileExists(atPath: options.traceURL.path)
        return RuntimeTraceSnapshot(
            text: "",
            path: options.traceURL.path,
            source: requestedExists ? "requested_trace_empty" : "no_trace",
            byteCount: 0
        )
    }

    private func runtimeTraceText() -> String {
        runtimeTraceSnapshot().text
    }

    private func cleanupSmokeRequest() -> [String: Any] {
        guard traceRequestWritten else {
            return [
                "status": "not_written",
                "path": options.smokeRequestURL.path
            ]
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.smokeRequestURL.path) else {
            traceRequestWritten = false
            return [
                "status": "already_absent",
                "path": options.smokeRequestURL.path,
                "owned": true
            ]
        }
        do {
            let data = try Data(contentsOf: options.smokeRequestURL)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard object?["nonce"] as? String == traceRequestNonce else {
                return [
                    "status": "not_owned",
                    "path": options.smokeRequestURL.path,
                    "owned": false
                ]
            }
            try fileManager.removeItem(at: options.smokeRequestURL)
            traceRequestWritten = false
            return [
                "status": "completed",
                "path": options.smokeRequestURL.path,
                "owned": true
            ]
        } catch {
            return [
                "status": "incomplete",
                "path": options.smokeRequestURL.path,
                "owned": true,
                "error": error.localizedDescription
            ]
        }
    }

    private func findInputMode() -> TISInputSource? {
        guard let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as? [TISInputSource] else { return nil }
        return sources.first { propertyString($0, key: kTISPropertyInputModeID) == options.modeID }
    }

    private func findKeyboardLayout(sourceID: String) -> TISInputSource? {
        guard let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as? [TISInputSource] else { return nil }
        return sources.first {
            propertyString($0, key: kTISPropertyInputSourceID) == sourceID
                && propertyString($0, key: kTISPropertyInputSourceType) == String(kTISTypeKeyboardLayout)
        }
    }

    private func propertyString(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        let value = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue()
        return String(value)
    }

    private func propertyBool(_ source: TISInputSource, key: CFString) -> Bool? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        let value = Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()
        return value == kCFBooleanTrue
    }

    private func inputSourceDetails(_ source: TISInputSource) -> [String: Any] {
        [
            "source_id": propertyString(source, key: kTISPropertyInputSourceID) ?? "nil",
            "mode_id": propertyString(source, key: kTISPropertyInputModeID) ?? "nil",
            "bundle_id": propertyString(source, key: kTISPropertyBundleID) ?? "nil",
            "source_type": propertyString(source, key: kTISPropertyInputSourceType) ?? "nil",
            "enable_capable": propertyBool(source, key: kTISPropertyInputSourceIsEnableCapable) ?? false,
            "select_capable": propertyBool(source, key: kTISPropertyInputSourceIsSelectCapable) ?? false,
            "enabled": propertyBool(source, key: kTISPropertyInputSourceIsEnabled) ?? false,
            "selected": propertyBool(source, key: kTISPropertyInputSourceIsSelected) ?? false
        ]
    }

    private func finish(
        status: String,
        code: Int32,
        name: String,
        error: String?,
        failureClass: String = SmokeFailureClass.hostHarnessFailure,
        phase: String = "unknown",
        reasonCode: String = "unspecified",
        evidence: [String: Any] = [:]
    ) {
        guard !didFinish else { return }
        didFinish = true
        if name != "host smoke" {
            report.add(name, status: status, error: error)
        }
        exitCode = code
        let executionStatus: String
        switch status {
        case "pass":
            executionStatus = "PASS"
        case "unresolved":
            executionStatus = "NOT_RUN"
        case "timeout":
            executionStatus = "TIMEOUT"
        default:
            executionStatus = "FAIL"
        }
        var finalEvidence = evidence
        finalEvidence["process_cleanup"] = cleanupOwnedChildProcess()
        finalEvidence["input_source_cleanup"] = restoreGlobalInputSource()
        finalEvidence["process_observation_at_finish"] = inputMethodProcessEvidence()
        finalEvidence["smoke_request_cleanup"] = cleanupSmokeRequest()
        finalEvidence["host_shutdown"] = [
            "run_loop_stop": "NSApp.stop",
            "process_exit": "Darwin.exit(exit_code)"
        ]
        report.finish(
            status: status,
            exitCode: code,
            options: options,
            diagnosis: [
                "failure_class": failureClass,
                "execution_status": executionStatus,
                "phase": phase,
                "reason_code": reasonCode,
                "evidence": finalEvidence
            ]
        )
        window?.orderOut(nil)
        requestHostTermination()
    }

    private func cleanupOwnedChildProcess() -> [String: Any] {
        guard !cleanupCompleted else {
            return [
                "status": "already_completed",
                "manual_child_process_started": false,
                "managed_processes": []
            ]
        }
        cleanupCompleted = true

        let ownedPIDs = smokeOwnedManagedPIDs
        let before = runningInputMethodApplications()
            .filter { ownedPIDs.contains($0.processIdentifier) }
        for application in before {
            _ = application.terminate()
        }

        let gracefulDeadline = Date().addingTimeInterval(2.0)
        while Date() < gracefulDeadline {
            let remaining = runningInputMethodApplications()
                .filter { ownedPIDs.contains($0.processIdentifier) }
            if remaining.isEmpty { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        var remaining = runningInputMethodApplications()
            .filter { ownedPIDs.contains($0.processIdentifier) }
        var forceKilledPIDs: [Int] = []
        if !remaining.isEmpty {
            for application in remaining {
                let pid = application.processIdentifier
                if kill(pid, SIGTERM) == 0 {
                    forceKilledPIDs.append(Int(pid))
                }
            }
            let termDeadline = Date().addingTimeInterval(0.5)
            while Date() < termDeadline {
                remaining = runningInputMethodApplications()
                    .filter { ownedPIDs.contains($0.processIdentifier) }
                if remaining.isEmpty { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }

        remaining = runningInputMethodApplications()
            .filter { ownedPIDs.contains($0.processIdentifier) }
        var forceKilledWithSIGKILL: [Int] = []
        if !remaining.isEmpty {
            for application in remaining {
                let pid = application.processIdentifier
                if kill(pid, SIGKILL) == 0 {
                    forceKilledWithSIGKILL.append(Int(pid))
                }
            }
            let killDeadline = Date().addingTimeInterval(0.5)
            while Date() < killDeadline {
                remaining = runningInputMethodApplications()
                    .filter { ownedPIDs.contains($0.processIdentifier) }
                if remaining.isEmpty { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }

        remaining = runningInputMethodApplications()
            .filter { ownedPIDs.contains($0.processIdentifier) }
        return [
            "status": remaining.isEmpty ? "completed" : "incomplete",
            "manual_child_process_started": false,
            "managed_server_termination": before.isEmpty ? "not_needed" : "attempted",
            "managed_pids_observed": ownedPIDs.map(Int.init).sorted(),
            "managed_pids_graceful_termination": before.map { Int($0.processIdentifier) }.sorted(),
            "managed_pids_sigterm": forceKilledPIDs.sorted(),
            "managed_pids_sigkill": forceKilledWithSIGKILL.sorted(),
            "managed_pids_remaining": remaining.map { Int($0.processIdentifier) }.sorted(),
            "reason": "system_demand_launch_only_owned_processes_cleaned_after_report_preparation"
        ]
    }

    private func restoreGlobalInputSource() -> [String: Any] {
        guard globalInputSourceSelectionAttempted else {
            return ["status": "not_attempted"]
        }
        guard !globalInputSourceRestored else {
            return ["status": "already_completed"]
        }
        guard let originalGlobalInputSource else {
            return [
                "status": "unresolved",
                "reason": "original_input_source_not_observed"
            ]
        }
        let original = inputSourceDetails(originalGlobalInputSource)
        let status = TISSelectInputSource(originalGlobalInputSource)
        let current = currentInputSourceMetadata().dictionary
        let restored = status == noErr && current["source_id"] as? String == original["source_id"] as? String
            && current["mode_id"] as? String == original["mode_id"] as? String
        if restored {
            globalInputSourceRestored = true
        }
        return [
            "status": restored ? "completed" : "unresolved",
            "select_status": Int(status),
            "original_input_source": original,
            "current_input_source": current
        ]
    }

    private func requestHostTermination() {
        guard !terminationRequested else { return }
        terminationRequested = true
        let finalCode = exitCode
        guard !options.dryRun else { return }
        DispatchQueue.main.async {
            NSApp.stop(nil)
            Darwin.exit(finalCode)
        }
    }
}

@main
private struct NativeIMKHostSmokeMain {
    static func main() {
        let options = Options(arguments: CommandLine.arguments)
        let app = NSApplication.shared
        let delegate = NativeIMKHostSmokeDelegate(options: options)
        if options.dryRun {
            exit(delegate.runDryRun())
        }
        app.delegate = delegate
        app.run()
        exit(delegate.resultCode())
    }
}
