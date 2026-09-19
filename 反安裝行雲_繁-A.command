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

# 卸載可能已掛載的安裝磁碟
hdiutil info | grep -B 1 -A 5 "行雲" | grep "/dev/disk" | awk '{print $1}' | while read dev; do
    diskutil eject force "$dev" 2>/dev/null || hdiutil detach "$dev" -force 2>/dev/null || true
done

# 2. 精準自偏好設定與 TIS 核心中停用移除，徹底防範幽靈句柄
swift -e '
import Foundation
import CoreFoundation
import Carbon

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

if let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] {
    for s in list {
        let idPtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)
        let id = idPtr != nil ? (Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String) : ""
        if id.contains("XingYunIME") {
            TISDisableInputSource(s)
        }
    }
}
'

# 3. 從 LaunchServices 註銷所有已知副本與正式安裝路徑
for p in "$TARGET" "$DIR/bin/app/$APP_NAME" "$DIR/dist/$APP_NAME" "/Users/taichi/AI/ffloating_cloud_C/bin/app/$APP_NAME"; do
    if [[ -d "$p" ]]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$p" 2>/dev/null || true
    fi
done
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -gc

# 4. 徹底刪除實體檔案
rm -rf "$TARGET"

# 5. 重整選單列與輸入法背景管理進程
killall -9 imklaunchagent TextInputMenuAgent TextInputSwitcher 2>/dev/null || true

echo
echo "=========================================="
echo "        ✅ 行雲_繁-A 已成功移除！"
echo "=========================================="
echo "輸入法已徹底自系統清理完畢，無任何幽靈殘留。"
echo

osascript -e 'display notification "行雲_繁-A 已從系統中徹底移除。" with title "行雲_繁-A 卸載程式" subtitle "移除成功"' 2>/dev/null || true
osascript -e 'display dialog "行雲_繁-A 應用程式已徹底從系統目錄中刪除。" with title "行雲_繁-A 卸載程式" buttons {"完成"} default button "完成" with icon note' 2>/dev/null || true
