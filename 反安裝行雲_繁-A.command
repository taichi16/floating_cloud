#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="行雲_繁-A.app"
TARGET="$HOME/Library/Input Methods/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
TARGET_BUNDLE_ID="com.vader.inputmethod.XingYunIME"

echo "=========================================="
echo "       行雲_繁-A - 應用程式解除安裝       "
echo "=========================================="
echo

# 互動確認對話框（若非靜默執行）
if [[ "${1:-}" != "--force" && "${1:-}" != "-f" ]]; then
    CONFIRM=$(osascript -e '
    try
        display dialog "確定要解除安裝「行雲_繁-A」嗎？\n\n此操作將從系統中移除 行雲_繁-A 應用程式本體並清理相關輸入來源登錄。" with title "行雲_繁-A 解除安裝" buttons {"取消", "確定移除"} default button "取消" with icon caution
        return "OK"
    on error
        return "CANCEL"
    end try
    ' 2>/dev/null || echo "OK")

    if [[ "$CONFIRM" == *"CANCEL"* ]]; then
        echo "操作已取消。"
        exit 0
    fi
fi

echo "🧹 正在移除 行雲_繁-A..."

# 1. 切換目前作用中輸入法，避免正在使用該輸入法時無法乾淨卸載
swift -e '
import Foundation
import CoreFoundation
import Carbon

let targetBundleID = "com.vader.inputmethod.XingYunIME"
let targetModeID = "com.vader.inputmethod.XingYunIME.Bopomofo"

// 1.1 若目前正在使用 XingYunIME，先主動切換至其他已啟用的輸入法（如 ABC 等）
guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { exit(1) }
    let idPtr = TISGetInputSourceProperty(current, kTISPropertyInputSourceID)
    let currentID = idPtr != nil ? (Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String) : ""
    if currentID == targetModeID || currentID == targetBundleID {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { exit(1) }
        func sourceID(_ source: TISInputSource) -> String {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
            return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        func selectable(_ source: TISInputSource) -> Bool {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
        }
        let candidates = list.filter { selectable($0) && sourceID($0) != targetModeID && sourceID($0) != targetBundleID }
        let fallback = candidates.first(where: { sourceID($0) == "com.apple.keylayout.ABC" }) ?? candidates.first
        guard let fallback, TISSelectInputSource(fallback) == noErr else {
            fputs("無法切換至其他輸入來源；取消解除安裝。\n", stderr)
            exit(1)
        }
    }

// 1.2 停用所有 XingYunIME TIS 句柄
guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { exit(1) }
for s in list {
        let idPtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)
        let id = idPtr != nil ? (Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String) : ""
        let bPtr = TISGetInputSourceProperty(s, kTISPropertyBundleID)
        let bID = bPtr != nil ? (Unmanaged<CFString>.fromOpaque(bPtr!).takeUnretainedValue() as String) : ""
        let selectablePtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsSelectCapable)
        let selectable = selectablePtr != nil && CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(selectablePtr!).takeUnretainedValue())
        // TIS also returns a non-selectable parent record for the bundle. It is
        // not a user input mode and TISDisableInputSource can fail on that record.
        if selectable && (id == targetModeID || id == targetBundleID || bID == targetBundleID) {
            let enabledPtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsEnabled)
            let enabled = enabledPtr != nil && CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabledPtr!).takeUnretainedValue())
            if enabled && TISDisableInputSource(s) != noErr {
                fputs("停用行雲可選輸入模式失敗：\(id)\n", stderr)
                exit(1)
            }
        }
}

// 1.3 清理 com.apple.HIToolbox 偏好設定（精確比對）
let domain = "com.apple.HIToolbox" as CFString
let keys = ["AppleEnabledInputSources", "AppleSelectedInputSources", "AppleInputSourceHistory"]
for k in keys {
    let key = k as CFString
    if let list = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] {
        let filtered = list.filter { item in
            if let b = item["Bundle ID"] as? String, b == targetBundleID {
                return false
            }
            return true
        }
        CFPreferencesSetAppValue(key, filtered as CFArray, domain)
    }
}
guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
    fputs("同步 com.apple.HIToolbox 偏好設定失敗。\n", stderr)
    exit(1)
}

for k in keys {
    let key = k as CFString
    if let list = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]],
       list.contains(where: { ($0["Bundle ID"] as? String) == targetBundleID }) {
        fputs("HIToolbox 偏好設定仍殘留行雲輸入來源。\n", stderr)
        exit(1)
    }
}
'

# 2. 僅註銷使用者安裝的 canonical 路徑；不刪除其他副本或全域重建資料庫。
if [[ -x "$LSREGISTER" && -d "$TARGET" ]]; then
    echo "🧹 正在註銷本機安裝路徑..."
    "$LSREGISTER" -u "$TARGET"
fi

# 3. 移除精確的使用者安裝路徑
if [[ -d "$TARGET" ]]; then
    echo "🗑️ 正在刪除應用程式: $TARGET"
    rm -rf "$TARGET"
fi

# 4. 驗證檔案是否已移除
if [[ ! -d "$TARGET" ]]; then
    THIRD_PARTY_PREF_STATUS="unknown"
    if THIRD_PARTY_PREFS="$(/usr/bin/defaults read com.apple.inputsources AppleEnabledThirdPartyInputSources 2>/dev/null)"; then
        if [[ "$THIRD_PARTY_PREFS" == *"$TARGET_BUNDLE_ID"* ]]; then
            THIRD_PARTY_PREF_STATUS="stale"
        else
            THIRD_PARTY_PREF_STATUS="clear"
        fi
    fi

    echo
    echo "=========================================="
    echo "       ✅ 行雲_繁-A App 本體已移除"
    echo "=========================================="
    echo "使用者安裝路徑與本工具管理的輸入來源項目已處理。"
    if [[ "$THIRD_PARTY_PREF_STATUS" == "stale" ]]; then
        echo "⚠️ Apple 管理的第三方輸入來源偏好仍有行雲記錄；本工具不直接改寫該系統偏好。"
    elif [[ "$THIRD_PARTY_PREF_STATUS" == "unknown" ]]; then
        echo "⚠️ 無法讀回 Apple 管理的第三方輸入來源偏好，清理狀態未確認。"
    else
        echo "Apple 管理的第三方輸入來源偏好未見行雲記錄。"
    fi
    echo
    if [[ "${1:-}" != "--force" && "${1:-}" != "-f" ]]; then
        if [[ "$THIRD_PARTY_PREF_STATUS" == "stale" ]]; then
            NOTIFICATION_TEXT="App 已移除；Apple 管理偏好仍留有行雲記錄。"
            DETAILS_TEXT="已移除目前使用者安裝路徑，但 Apple 管理的第三方輸入來源偏好仍留有行雲記錄；本工具不會改寫該系統偏好。其他位置的手動副本也不在處理範圍內。"
        elif [[ "$THIRD_PARTY_PREF_STATUS" == "unknown" ]]; then
            NOTIFICATION_TEXT="App 已移除；部分系統清理狀態未確認。"
            DETAILS_TEXT="已移除目前使用者安裝路徑，但無法讀回 Apple 管理的第三方輸入來源偏好，因此整體清理狀態未確認。本工具不會改寫該系統偏好；其他位置的手動副本也不在處理範圍內。"
        else
            NOTIFICATION_TEXT="行雲_繁-A 使用者 App 已移除。"
            DETAILS_TEXT="已移除使用者安裝路徑。其他位置的手動副本不在本解除安裝器處理範圍內。若系統設定仍顯示歷史項目，請重新開啟設定確認；此腳本不會重設全域輸入來源資料庫。"
        fi
        osascript -e "display notification \"$NOTIFICATION_TEXT\" with title \"行雲_繁-A\" subtitle \"解除安裝狀態\"" 2>/dev/null || true
        osascript -e "display dialog \"$DETAILS_TEXT\" with title \"行雲_繁-A\" buttons {\"完成\"} default button \"完成\" with icon note" 2>/dev/null || true
    fi
else
    echo
    echo "❌ 移除未完成，檔案仍殘留："
    echo "  - $TARGET"
    exit 1
fi
