#!/bin/zsh
set -euo pipefail

APP_NAME="行雲_繁-A.app"
INSTALL_DIR="$HOME/Library/Input Methods/$APP_NAME"

echo "=========================================="
echo "         行雲_繁-A - 反安裝程式           "
echo "=========================================="
echo

# 1. 彈出確認視窗
CONFIRM=$(osascript -e '
try
    display dialog "確定要反安裝「行雲_繁-A」嗎？\n\n此操作將從系統輸入法中移除 行雲_繁-A 並清除相關註冊設定。" with title "行雲_繁-A 反安裝程式" buttons {"取消", "確定移除"} default button "取消" with icon caution
    return "OK"
on error
    return "CANCEL"
end try
' 2>/dev/null || echo "OK")

if [[ "$CONFIRM" == *"CANCEL"* ]]; then
    echo "操作已取消。"
    exit 0
fi

echo "🧹 正在反安裝 行雲_繁-A..."

# 2. 清除 HIToolbox 登錄
if [[ -x "$INSTALL_DIR/Contents/MacOS/UnifyIME" ]]; then
    echo "⚙️ 正在清除系統輸入來源註冊紀錄..."
    "$INSTALL_DIR/Contents/MacOS/UnifyIME" uninstall 2>/dev/null || true
fi

# 3. 終止執行中進程
echo "🛑 正在終止輸入法進程..."
killall UnifyIME >/dev/null 2>&1 || true

# 4. 從 LaunchServices 註銷
if [[ -d "$INSTALL_DIR" ]]; then
    echo "📋 正在從 LaunchServices 註銷..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$INSTALL_DIR" 2>/dev/null || true
fi

# 5. 移至垃圾桶
if [[ -d "$INSTALL_DIR" ]]; then
    echo "🗑️ 正在移除 $INSTALL_DIR ..."
    TRASH_DEST="$HOME/.Trash/行雲_繁-A_已反安裝_$(date +%Y%m%d%H%M%S).app"
    mv "$INSTALL_DIR" "$TRASH_DEST" 2>/dev/null || rm -rf "$INSTALL_DIR"
fi

# 6. 重新整理輸入法選單進程
echo "🔄 正在重整系統選單..."
killall TextInputMenuAgent >/dev/null 2>&1 || true
killall TextInputSwitcher >/dev/null 2>&1 || true
killall cfprefsd >/dev/null 2>&1 || true

echo
echo "=========================================="
echo "        ✅ 行雲_繁-A 已成功移除！"
echo "=========================================="
echo

osascript -e 'display dialog "行雲_繁-A 已成功從您的系統中移除。" with title "行雲_繁-A 反安裝程式" buttons {"完成"} default button "完成" with icon note' 2>/dev/null || true
