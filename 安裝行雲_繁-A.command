#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="行雲_繁-A.app"
TARGET="$HOME/Library/Input Methods/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SRC_APP=""

if [[ -d "$DIR/$APP_NAME" ]]; then
    SRC_APP="$DIR/$APP_NAME"
elif [[ -d "$DIR/dist/$APP_NAME" ]]; then
    SRC_APP="$DIR/dist/$APP_NAME"
elif [[ -d "$DIR/bin/app/$APP_NAME" ]]; then
    SRC_APP="$DIR/bin/app/$APP_NAME"
fi

if [[ -z "$SRC_APP" || ! -d "$SRC_APP" ]]; then
    echo "🔨 正在建置最新版本的 行雲_繁-A..."
    if [[ -x "$DIR/build.command" ]]; then
        "$DIR/build.command"
    elif [[ -x "$DIR/src/unifyIME/build.sh" ]]; then
        "$DIR/src/unifyIME/build.sh"
    fi
    if [[ -d "$DIR/dist/$APP_NAME" ]]; then
        SRC_APP="$DIR/dist/$APP_NAME"
    elif [[ -d "$DIR/bin/app/$APP_NAME" ]]; then
        SRC_APP="$DIR/bin/app/$APP_NAME"
    fi
fi

if [[ -z "$SRC_APP" || ! -d "$SRC_APP" ]]; then
    echo "❌ 找不到可安裝的 $APP_NAME 來源。"
    exit 1
fi

echo "=========================================="
echo "         行雲_繁-A - 應用程式安裝         "
echo "=========================================="
echo "📦 來源: $SRC_APP"
echo "📂 目標: $TARGET"
echo

# 1. 結束執行中進程並清理舊版
killall UnifyIME 2>/dev/null || true

# 檢查是否有已掛載的安裝磁碟，若有則提醒使用者
if hdiutil info 2>/dev/null | grep -q "行雲_繁-A 安裝磁碟"; then
    echo "💡 提示：偵測到「行雲_繁-A 安裝磁碟」掛載中。建議安裝完成後手動推出安裝映像檔，避免系統快取多餘副本。"
fi

rm -rf "$TARGET"
mkdir -p "$HOME/Library/Input Methods"

# 2. 部署應用程式
ditto "$SRC_APP" "$TARGET"
ENTITLEMENTS="$DIR/src/unifyIME/Resources/fastChIME.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$TARGET" 2>/dev/null || true
else
    codesign --force --sign - --timestamp=none "$TARGET" 2>/dev/null || true
fi

# 3. 向 macOS LaunchServices 核心註冊正式路徑並整理資料庫
if [[ -x "$LSREGISTER" ]]; then
    $LSREGISTER -f "$TARGET"
    $LSREGISTER -gc 2>/dev/null || true
fi

# 4. 精準寫入 AppleEnabledInputSources 並透過 TIS 啟用（排他性單一啟用，杜絕重複）
swift -e '
import Foundation
import CoreFoundation
import Carbon

let targetBundleID = "com.vader.inputmethod.XingYunIME"
let targetModeID = "com.vader.inputmethod.XingYunIME.Bopomofo"

// 4.1 清理 com.apple.inputsources (AppleEnabledThirdPartyInputSources 精確比對只留一筆)
let inputDomain = "com.apple.inputsources" as CFString
let thirdPartyKey = "AppleEnabledThirdPartyInputSources" as CFString
if let currentVal = CFPreferencesCopyAppValue(thirdPartyKey, inputDomain) as? [[String: Any]] {
    var filtered = currentVal.filter { item in
        guard let b = item["Bundle ID"] as? String else { return true }
        return b != targetBundleID
    }
    filtered.append([
        "Bundle ID": targetBundleID,
        "InputSourceKind": "Keyboard Input Method"
    ])
    CFPreferencesSetAppValue(thirdPartyKey, filtered as CFArray, inputDomain)
    CFPreferencesSynchronize(inputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

// 4.2 清理 com.apple.HIToolbox (AppleEnabledInputSources 精確比對只留一筆唯一的 Bopomofo Input Mode)
let domain = "com.apple.HIToolbox" as CFString
let key = "AppleEnabledInputSources" as CFString
if let currentVal = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] {
    var filtered = currentVal.filter { item in
        guard let b = item["Bundle ID"] as? String else { return true }
        return b != targetBundleID
    }
    filtered.append([
        "Bundle ID": targetBundleID,
        "Input Mode": targetModeID,
        "InputSourceKind": "Input Mode"
    ])
    CFPreferencesSetAppValue(key, filtered as CFArray, domain)
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

// 4.3 透過 TIS 啟用唯一的最新 Bopomofo mode，並強制停用所有重複或過時句柄
if let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] {
    var bopomofoSources: [TISInputSource] = []
    for s in list {
        let idPtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)
        let id = idPtr != nil ? (Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String) : ""
        if id == targetModeID {
            bopomofoSources.append(s)
        } else if id == targetBundleID {
            TISDisableInputSource(s)
        }
    }
    if let primary = bopomofoSources.last {
        for old in bopomofoSources.dropLast() {
            TISDisableInputSource(old)
        }
        let isEnabledPtr = TISGetInputSourceProperty(primary, kTISPropertyInputSourceIsEnabled)
        let isEnabled = isEnabledPtr != nil ? CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(isEnabledPtr!).takeUnretainedValue()) : false
        if !isEnabled {
            TISEnableInputSource(primary)
        }
        TISSelectInputSource(primary)
    }
}
'

# 5. 啟動 App 並重整選單列
open "$TARGET" 2>/dev/null || true
killall -9 imklaunchagent TextInputMenuAgent TextInputSwitcher 2>/dev/null || true

echo "=========================================="
echo "        🎉 行雲_繁-A 安裝完成！"
echo "=========================================="
echo "已自動啟用並登錄於系統輸入法選單。"
echo

if [[ "${1:-}" != "--force" && "${1:-}" != "-f" ]]; then
    osascript -e 'display notification "行雲_繁-A 已成功啟用！" with title "行雲_繁-A" subtitle "安裝成功"' 2>/dev/null || true
    osascript -e 'display dialog "行雲_繁-A 安裝完成！\n\n已成功啟用並加入輸入法選單，您可直接切換使用。" with title "行雲_繁-A 安裝程式" buttons {"完成"} default button "完成" with icon note giving up after 5' 2>/dev/null || true
fi
