#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="行雲_繁-A.app"
INSTALL_DIR="$HOME/Library/Input Methods/$APP_NAME"
SRC_DIR="$DIR/src/unifyIME"
BIN_APP="$DIR/bin/app/$APP_NAME"
DIST_APP="$DIR/dist/$APP_NAME"
LOCAL_APP="$DIR/$APP_NAME"

echo "=========================================="
echo "         行雲_繁-A - 自動安裝程式         "
echo "=========================================="
echo

# 0. 先關閉系統設定，避免 Apple SwiftUI 快取衝突
killall "System Settings" >/dev/null 2>&1 || true
killall "KeyboardSettings" >/dev/null 2>&1 || true

# 1. 檢查並定位安裝來源
SOURCE_APP=""
if [[ -d "$LOCAL_APP" ]]; then
    SOURCE_APP="$LOCAL_APP"
elif [[ -d "$DIST_APP" ]]; then
    SOURCE_APP="$DIST_APP"
elif [[ -d "$BIN_APP" ]]; then
    SOURCE_APP="$BIN_APP"
elif [[ -f "$DIR/build.command" ]]; then
    echo "🔨 正在建置最新版本的 行雲_繁-A..."
    "$DIR/build.command"
    if [[ -d "$LOCAL_APP" ]]; then
        SOURCE_APP="$LOCAL_APP"
    elif [[ -d "$DIST_APP" ]]; then
        SOURCE_APP="$DIST_APP"
    elif [[ -d "$BIN_APP" ]]; then
        SOURCE_APP="$BIN_APP"
    fi
fi

if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
    echo "❌ 找不到 $APP_NAME 安裝來源。"
    osascript -e 'display alert "行雲_繁-A 安裝失敗" message "找不到應用程式安裝來源，請確認檔案完整。" as critical' 2>/dev/null || true
    exit 1
fi

echo "📦 使用安裝來源: $SOURCE_APP"

# 2. 部署至 ~/Library/Input Methods
echo "📂 正在安裝至系統輸入法目錄: $INSTALL_DIR"
mkdir -p "$HOME/Library/Input Methods"

# 若已有舊版，先清理至垃圾桶備份
if [[ -d "$INSTALL_DIR" ]]; then
    echo "🔄 偵測到現有版本，正在移至垃圾桶備份..."
    TRASH_DEST="$HOME/.Trash/行雲_繁-A_備份_$(date +%Y%m%d%H%M%S).app"
    mv "$INSTALL_DIR" "$TRASH_DEST" 2>/dev/null || rm -rf "$INSTALL_DIR"
fi

ditto "$SOURCE_APP" "$INSTALL_DIR"
codesign --force --sign - --timestamp=none "$INSTALL_DIR" >/dev/null 2>&1 || true

# 3. 註冊至 LaunchServices
echo "⚙️ 正在註冊輸入法至 macOS..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR"

# 4. 重新整理輸入法服務進程
echo "🔄 正在重啟輸入法服務..."
killall UnifyIME >/dev/null 2>&1 || true
killall TextInputMenuAgent >/dev/null 2>&1 || true
killall TextInputSwitcher >/dev/null 2>&1 || true
killall cfprefsd >/dev/null 2>&1 || true

# 5. 啟用並選取輸入法 (包含自動句柄去重與單一守護)
echo "✨ 正在啟用 行雲_繁-A..."
if [[ -x "$INSTALL_DIR/Contents/MacOS/UnifyIME" ]]; then
    "$INSTALL_DIR/Contents/MacOS/UnifyIME" install || true
fi

echo
echo "=========================================="
echo "        🎉 行雲_繁-A 安裝完成！"
echo "=========================================="
echo "目前已成功安裝並啟用 行雲_繁-A。"
echo "您可在右上角選單列看到薄荷青「行雲」圖標。"
echo

osascript -e 'display notification "行雲_繁-A 已成功安裝並啟用！" with title "行雲_繁-A" subtitle "安裝成功"' 2>/dev/null || true
osascript -e 'display dialog "行雲_繁-A 安裝完成！\n\n已成功載入並套用薄荷青「行雲」視覺。\n若選單列尚未切換，可直接按 Control + 空白鍵 或在右上角輸入法選單中選取。" with title "行雲_繁-A 安裝程式" buttons {"完成"} default button "完成" with icon note' 2>/dev/null || true
