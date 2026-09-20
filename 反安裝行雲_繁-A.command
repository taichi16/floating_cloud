#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="行雲_繁-A.app"
TARGET="$HOME/Library/Input Methods/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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
if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
    let idPtr = TISGetInputSourceProperty(current, kTISPropertyInputSourceID)
    let currentID = idPtr != nil ? (Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String) : ""
    if currentID == targetModeID || currentID == targetBundleID {
        if let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] {
            for s in list {
                let sIdPtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)
                let sId = sIdPtr != nil ? (Unmanaged<CFString>.fromOpaque(sIdPtr!).takeUnretainedValue() as String) : ""
                let isSelectCapablePtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsSelectCapable)
                let isSelectCapable = isSelectCapablePtr != nil ? CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(isSelectCapablePtr!).takeUnretainedValue()) : false
                if isSelectCapable && sId != targetModeID && sId != targetBundleID {
                    TISSelectInputSource(s)
                    break
                }
            }
        }
    }
}

// 1.2 停用所有 XingYunIME TIS 句柄
if let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] {
    for s in list {
        let idPtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)
        let id = idPtr != nil ? (Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String) : ""
        let bPtr = TISGetInputSourceProperty(s, kTISPropertyBundleID)
        let bID = bPtr != nil ? (Unmanaged<CFString>.fromOpaque(bPtr!).takeUnretainedValue() as String) : ""
        if id == targetModeID || id == targetBundleID || bID == targetBundleID {
            TISDisableInputSource(s)
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
CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

// 1.4 清理 com.apple.inputsources 偏好設定（精確比對）
let inputDomain = "com.apple.inputsources" as CFString
let thirdPartyKey = "AppleEnabledThirdPartyInputSources" as CFString
if let list = CFPreferencesCopyAppValue(thirdPartyKey, inputDomain) as? [[String: Any]] {
    let filtered = list.filter { item in
        guard let b = item["Bundle ID"] as? String else { return true }
        return b != targetBundleID
    }
    CFPreferencesSetAppValue(thirdPartyKey, filtered as CFArray, inputDomain)
    CFPreferencesSynchronize(inputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}
'

# 2. 終止背景程序
killall UnifyIME 2>/dev/null || true

# 3. 刪除使用者目錄實體檔案
if [[ -d "$TARGET" ]]; then
    echo "🗑️ 正在刪除應用程式: $TARGET"
    rm -rf "$TARGET"
fi

# 4. 從 LaunchServices 註銷安裝路徑
if [[ -x "$LSREGISTER" ]]; then
    echo "🧹 正在清理 LaunchServices 註冊表..."
    $LSREGISTER -u "$TARGET" 2>/dev/null || true
    $LSREGISTER -gc 2>/dev/null || true
fi

# 5. 重整選單列與輸入法背景管理程序
killall -9 imklaunchagent TextInputMenuAgent TextInputSwitcher 2>/dev/null || true
sleep 1

# 6. 驗證檔案是否已移除
if [[ ! -d "$TARGET" ]]; then
    echo
    echo "=========================================="
    echo "       ✅ 行雲_繁-A 已完成解除安裝"
    echo "=========================================="
    echo "應用程式本體檔案與已知登錄項目已完成清理。"
    echo
    if [[ "${1:-}" != "--force" && "${1:-}" != "-f" ]]; then
        osascript -e 'display notification "行雲_繁-A 已完成解除安裝。" with title "行雲_繁-A" subtitle "移除完成"' 2>/dev/null || true
        osascript -e 'display dialog "行雲_繁-A 應用程式本體已自系統目錄刪除，相關背景服務已嘗試註銷。\n\n【提示】\n若 macOS「系統設定」>「鍵盤」>「文字輸入方式」面板中仍保留歷史項目，點選後按「-」號即可完成移除。" with title "行雲_繁-A" buttons {"完成"} default button "完成" with icon note' 2>/dev/null || true
    fi
else
    echo
    echo "❌ 移除未完成，檔案仍殘留："
    echo "  - $TARGET"
    exit 1
fi
