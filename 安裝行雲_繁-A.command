#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="行雲_繁-A.app"
TARGET="$HOME/Library/Input Methods/$APP_NAME"
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
    "$DIR/build.command"
    if [[ -d "$DIR/dist/$APP_NAME" ]]; then
        SRC_APP="$DIR/dist/$APP_NAME"
    elif [[ -d "$DIR/bin/app/$APP_NAME" ]]; then
        SRC_APP="$DIR/bin/app/$APP_NAME"
    fi
fi

echo "=========================================="
echo "         行雲_繁-A - 應用程式安裝         "
echo "=========================================="
echo "📦 來源: $SRC_APP"
echo "📂 目標: $TARGET"
echo

# 1. 結束執行中進程並清理舊版
killall UnifyIME 2>/dev/null || true
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

# 3. 向 macOS LaunchServices 核心註冊
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"

# 4. 精準寫入 AppleEnabledInputSources 並透過 TIS 啟用（排他性單一啟用，自動剔除舊句柄）
swift -e '
import Foundation
import CoreFoundation
import Carbon

let domain = "com.apple.HIToolbox" as CFString
let key = "AppleEnabledInputSources" as CFString

if let currentVal = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] {
    let targetItem: [String: Any] = [
        "Bundle ID": "com.vader.inputmethod.XingYunIME",
        "Input Mode": "com.vader.inputmethod.XingYunIME.Bopomofo",
        "InputSourceKind": "Input Mode"
    ]
    var filtered = currentVal.filter { item in
        guard let b = item["Bundle ID"] as? String else { return true }
        return !b.contains("XingYunIME")
    }
    filtered.append(targetItem)
    CFPreferencesSetAppValue(key, filtered as CFArray, domain)
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

let inputDomain = "com.apple.inputsources" as CFString
let thirdPartyKey = "AppleEnabledThirdPartyInputSources" as CFString
if let currentVal = CFPreferencesCopyAppValue(thirdPartyKey, inputDomain) as? [[String: Any]] {
    let targetItem: [String: Any] = [
        "Bundle ID": "com.vader.inputmethod.XingYunIME",
        "InputSourceKind": "Keyboard Input Method"
    ]
    var filtered = currentVal.filter { item in
        guard let b = item["Bundle ID"] as? String else { return true }
        return !b.contains("XingYunIME")
    }
    filtered.append(targetItem)
    CFPreferencesSetAppValue(thirdPartyKey, filtered as CFArray, inputDomain)
    CFPreferencesSynchronize(inputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

if let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] {
    var bopomofoSources: [TISInputSource] = []
    for s in list {
        let idPtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)
        let id = idPtr != nil ? (Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String) : ""
        if id == "com.vader.inputmethod.XingYunIME.Bopomofo" {
            bopomofoSources.append(s)
        } else if id == "com.vader.inputmethod.XingYunIME" {
            TISDisableInputSource(s)
        }
    }
    if let latest = bopomofoSources.last {
        for old in bopomofoSources.dropLast() {
            TISDisableInputSource(old)
        }
        TISEnableInputSource(latest)
        TISSelectInputSource(latest)
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

osascript -e 'display notification "行雲_繁-A 已成功啟用！" with title "行雲_繁-A" subtitle "安裝成功"' 2>/dev/null || true
osascript -e 'display dialog "行雲_繁-A 安裝完成！\n\n已成功啟用並加入輸入法選單，您可直接切換使用。" with title "行雲_繁-A 安裝程式" buttons {"完成"} default button "完成" with icon note' 2>/dev/null || true
