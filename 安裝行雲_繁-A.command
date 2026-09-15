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
codesign --force --sign - --timestamp=none "$TARGET" 2>/dev/null || true

# 3. 向 macOS 核心註冊並重整選單
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"
killall TextInputMenuAgent TextInputSwitcher 2>/dev/null || true

echo "=========================================="
echo "        🎉 行雲_繁-A 安裝部署完成！"
echo "=========================================="
echo "應用程式已成功部署至您的輸入法目錄。"
echo

osascript -e 'display notification "行雲_繁-A 已成功部署至系統輸入法目錄。" with title "行雲_繁-A" subtitle "安裝成功"' 2>/dev/null || true
osascript -e 'display dialog "行雲_繁-A 安裝部署完成！\n\n已成功放置於 ~/Library/Input Methods/。\n若右上角輸入法選單尚未出現，請至「系統設定」>「鍵盤」>「文字輸入」新增即可。" with title "行雲_繁-A 安裝程式" buttons {"完成"} default button "完成" with icon note' 2>/dev/null || true
