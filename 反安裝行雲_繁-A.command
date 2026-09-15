#!/bin/zsh
set -euo pipefail

APP_NAME="行雲_繁-A.app"
TARGET="$HOME/Library/Input Methods/$APP_NAME"

echo "=========================================="
echo "         行雲_繁-A - 應用程式卸載         "
echo "=========================================="
echo

CONFIRM=$(osascript -e '
try
    display dialog "確定要反安裝「行雲_繁-A」嗎？\n\n此操作將從系統中徹底刪除 行雲_繁-A 應用程式。" with title "行雲_繁-A 卸載程式" buttons {"取消", "確定移除"} default button "取消" with icon caution
    return "OK"
on error
    return "CANCEL"
end try
' 2>/dev/null || echo "OK")

if [[ "$CONFIRM" == *"CANCEL"* ]]; then
    echo "操作已取消。"
    exit 0
fi

echo "🧹 正在移除 行雲_繁-A..."

# 1. 終止進程
killall UnifyIME 2>/dev/null || true

# 2. 精準自偏好設定移除，防止殘留幽靈項目（100% 不影響其他輸入法）
swift -e '
import Foundation
import CoreFoundation

let domain = "com.apple.HIToolbox" as CFString
let keys = ["AppleEnabledInputSources", "AppleSelectedInputSources", "AppleInputSourceHistory"]

for k in keys {
    let key = k as CFString
    if let list = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] {
        let filtered = list.filter { item in
            if let b = item["Bundle ID"] as? String, b.contains("XingYunIME") {
                return false
            }
            return true
        }
        CFPreferencesSetAppValue(key, filtered as CFArray, domain)
    }
}
CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

let inputDomain = "com.apple.inputsources" as CFString
let thirdPartyKey = "AppleEnabledThirdPartyInputSources" as CFString
if let list = CFPreferencesCopyAppValue(thirdPartyKey, inputDomain) as? [[String: Any]] {
    let filtered = list.filter { item in
        if let b = item["Bundle ID"] as? String, b.contains("XingYunIME") {
            return false
        }
        return true
    }
    CFPreferencesSetAppValue(thirdPartyKey, filtered as CFArray, inputDomain)
    CFPreferencesSynchronize(inputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}
'

# 3. 從 LaunchServices 註銷
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$TARGET" 2>/dev/null || true

# 4. 徹底刪除實體檔案
rm -rf "$TARGET"

# 5. 重整選單列
killall TextInputMenuAgent TextInputSwitcher 2>/dev/null || true

echo
echo "=========================================="
echo "        ✅ 行雲_繁-A 已成功移除！"
echo "=========================================="
echo "輸入法已徹底自系統清理完畢，無任何幽靈殘留。"
echo

osascript -e 'display notification "行雲_繁-A 已從系統中徹底移除。" with title "行雲_繁-A 卸載程式" subtitle "移除成功"' 2>/dev/null || true
osascript -e 'display dialog "行雲_繁-A 應用程式已徹底從系統目錄中刪除。" with title "行雲_繁-A 卸載程式" buttons {"完成"} default button "完成" with icon note' 2>/dev/null || true
