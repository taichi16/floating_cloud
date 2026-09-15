#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="行雲_繁-A.app"
INSTALL_DIR="$HOME/Library/Input Methods/$APP_NAME"
SRC_DIR="$DIR/src/unifyIME"
BIN_APP="$DIR/bin/app/$APP_NAME"

echo "=========================================="
echo "          行雲_繁-A - 自動安裝程式        "
echo "=========================================="
echo

# 1. 檢查並建置最新 Release 版本
if [[ -f "$SRC_DIR/build.sh" ]]; then
    echo "🔨 正在建置最新 Release 版本（包含藍色圖示與所有最佳化）..."
    zsh "$SRC_DIR/build.sh" --release
    SOURCE_APP="$BIN_APP"
elif [[ -d "$BIN_APP" ]]; then
    echo "📦 找到已建置的應用程式..."
    SOURCE_APP="$BIN_APP"
elif [[ -d "$DIR/$APP_NAME" ]]; then
    SOURCE_APP="$DIR/$APP_NAME"
else
    echo "❌ 找不到 $APP_NAME 或原始碼目錄。"
    osascript -e 'display alert "全一輸入法安裝失敗" message "找不到應用程式安裝來源，請確認檔案完整。" as critical' 2>/dev/null || true
    exit 1
fi

# 2. 部署至 ~/Library/Input Methods
echo "📂 正在安裝至系統輸入法目錄: $INSTALL_DIR"
mkdir -p "$HOME/Library/Input Methods"

# 若已有舊版，先清理
if [[ -d "$INSTALL_DIR" ]]; then
    echo "🔄 偵測到現有版本，正在移至垃圾桶備份..."
    TRASH_DEST="$HOME/.Trash/全一輸入法_$(date +%Y%m%d%H%M%S).app"
    mv "$INSTALL_DIR" "$TRASH_DEST" 2>/dev/null || rm -rf "$INSTALL_DIR"
fi

ditto "$SOURCE_APP" "$INSTALL_DIR"
codesign --force --sign - --timestamp=none "$INSTALL_DIR" >/dev/null 2>&1 || true

# 3. 重新整理 LaunchServices
echo "⚙️ 正在註冊輸入法至 macOS..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR"

# 4. 重新啟動相關進程
killall UnifyIME >/dev/null 2>&1 || true
killall TextInputMenuAgent >/dev/null 2>&1 || true
killall cfprefsd >/dev/null 2>&1 || true

# 5. 啟用並選取輸入法
echo "✨ 正在啟用全一輸入法..."
if [[ -x "$INSTALL_DIR/Contents/MacOS/UnifyIME" ]]; then
    "$INSTALL_DIR/Contents/MacOS/UnifyIME" install || true
fi

echo
echo "=========================================="
echo "        🎉 全一輸入法安裝完成！"
echo "=========================================="
echo "目前已切換為全一輸入法，您可在右上角選單列看到全新的藍色 LOGO。"
echo

osascript -e 'display notification "全一輸入法已成功安裝並啟用！" with title "全一輸入法" subtitle "安裝成功"' 2>/dev/null || true
osascript -e 'display dialog "全一輸入法安裝完成！\n\n已成功載入並套用全新藍色圖示。\n若選單列尚未切換，可直接按 Control + 空白鍵 或在右上角輸入法選單中選取。" with title "全一輸入法安裝程式" buttons {"完成"} default button "完成" with icon note' 2>/dev/null || true
