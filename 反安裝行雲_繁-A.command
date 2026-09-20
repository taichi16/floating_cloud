#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="行雲_繁-A.app"
TARGET="$HOME/Library/Input Methods/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "=========================================="
echo "         行雲_繁-A - 應用程式卸載         "
echo "=========================================="
echo

# 互動確認對話框（若非靜默執行）
if [[ "${1:-}" != "--force" && "${1:-}" != "-f" ]]; then
    CONFIRM=$(osascript -e '
    try
        display dialog "確定要反安裝「行雲_繁-A」嗎？\n\n此操作將從系統中徹底刪除 行雲_繁-A 應用程式並清除輸入法登錄。" with title "行雲_繁-A 卸載程式" buttons {"取消", "確定移除"} default button "取消" with icon caution
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

# 2. 終止進程
killall UnifyIME 2>/dev/null || true

# 3. 徹底刪除使用者目錄實體檔案
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

# 5. 重整選單列與輸入法背景管理進程
killall -9 imklaunchagent TextInputMenuAgent TextInputSwitcher 2>/dev/null || true
sleep 1

# 6. 驗證是否徹底移除
if [[ ! -d "$TARGET" ]]; then
    echo
    echo "=========================================="
    echo "        ✅ 行雲_繁-A 已成功移除！"
    echo "=========================================="
    echo "應用程式檔案與系統註冊已徹底清理完畢。"
    echo
    if [[ "${1:-}" != "--force" && "${1:-}" != "-f" ]]; then
        osascript -e 'display notification "行雲_繁-A 已從系統中徹底移除。" with title "行雲_繁-A 卸載程式" subtitle "移除成功"' 2>/dev/null || true
        osascript -e 'display dialog "行雲_繁-A 應用程式本體已從系統目錄刪除，背景服務已註銷。\n\n【提示】\n若 macOS「系統設定」>「鍵盤」>「文字輸入」面板中仍留有名稱快取，點選後按「-」號即可完成清除。" with title "行雲_繁-A 卸載程式" buttons {"完成"} default button "完成" with icon note' 2>/dev/null || true
    fi
else
    echo
    echo "❌ 移除未完成，檔案仍殘留："
    echo "  - $TARGET"
    exit 1
fi
