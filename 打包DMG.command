#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="行雲_繁-A.app"
BIN_APP="$DIR/bin/app/$APP_NAME"
DIST_APP="$DIR/dist/$APP_NAME"
DIST_DIR="$DIR/dist"
BUILD_DIR="$DIR/build/.dmg_temp.noindex"
DMG_VOLNAME="行雲_繁-A 安裝磁碟"
DMG_NAME="行雲_繁-A_安裝磁碟.dmg"
OUTPUT_DMG="$DIST_DIR/$DMG_NAME"
DMG_ICON="$DIR/src/unifyIME/Resources/dmg_icon.icns"

echo "=========================================="
echo "         行雲_繁-A - DMG 封裝程式         "
echo "=========================================="
echo

# 1. 確保 App 存在且為最新版本
SOURCE_APP=""
if [[ -d "$DIST_APP" ]]; then
    SOURCE_APP="$DIST_APP"
elif [[ -d "$BIN_APP" ]]; then
    SOURCE_APP="$BIN_APP"
fi

if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
    echo "🔨 尚未偵測到已編譯的 $APP_NAME，開始執行建置..."
    "$DIR/build.command"
    if [[ -d "$DIST_APP" ]]; then
        SOURCE_APP="$DIST_APP"
    elif [[ -d "$BIN_APP" ]]; then
        SOURCE_APP="$BIN_APP"
    fi
fi

if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
    echo "❌ 建置失敗，找不到 $APP_NAME。"
    exit 1
fi

echo "📦 應用程式來源: $SOURCE_APP"

# 確保過去掛載的安裝磁碟已卸載，防止 LaunchServices 索引多餘副本
hdiutil info | grep -B 1 -A 5 "行雲" | grep "/dev/disk" | awk '{print $1}' | while read dev; do
    diskutil eject force "$dev" 2>/dev/null || hdiutil detach "$dev" -force 2>/dev/null || true
done

# 2. 準備打包暫存目錄
echo "📂 正在配置 DMG 映像檔內容結構..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$DIST_DIR"

# 複製 App、安裝與反安裝腳本
ditto "$SOURCE_APP" "$BUILD_DIR/$APP_NAME"
ditto "$DIR/安裝行雲_繁-A.command" "$BUILD_DIR/安裝行雲_繁-A.command"
ditto "$DIR/反安裝行雲_繁-A.command" "$BUILD_DIR/反安裝行雲_繁-A.command"

# 建立 Input Methods 系統目錄替身連結
ln -s "/Library/Input Methods" "$BUILD_DIR/Input Methods (全系統輸入法目錄)"

# 建立說明文件
cat << 'README_EOF' > "$BUILD_DIR/使用說明.txt"
==========================================
        行雲_繁-A 輸入法 安裝指南
==========================================

【一鍵安裝】
直接雙擊本映像檔視窗中的「安裝行雲_繁-A.command」：
✓ 自動安裝至個人輸入法目錄 (~/Library/Input Methods)
✓ 自動完成本機代碼簽名與路徑註冊
✓ 自動啟用輸入法並嘗試切換使用
✓ 若有舊版本會自動覆蓋更新檔案

【一鍵移除（解除安裝）】
直接雙擊本映像檔視窗中的「反安裝行雲_繁-A.command」：
✓ 移除前自動嘗試切換輸入來源，降低程序鎖定風險
✓ 結束常駐背景程序並移除應用程式本體檔案
✓ 若 macOS「系統設定」文字輸入方式面板中仍保留歷史項目，點選後按「-」號即可完成移除。

【手動安裝】
亦可將「行雲_繁-A.app」手動拖曳至「Input Methods (全系統輸入法目錄)」，
然後於「系統設定」>「鍵盤」>「文字輸入方式」新增即可。
README_EOF

# 設定 DMG 自訂磁碟外觀圖標
if [[ -f "$DMG_ICON" ]]; then
    echo "🎨 正在套用磁碟專屬外觀圖標..."
    cp "$DMG_ICON" "$BUILD_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$BUILD_DIR/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$BUILD_DIR" 2>/dev/null || true
fi

# 確保權限
chmod +x "$BUILD_DIR/安裝行雲_繁-A.command"
chmod +x "$BUILD_DIR/反安裝行雲_繁-A.command"

# 3. 封裝為 UDZO 高壓縮率 DMG
echo "💿 正在使用 hdiutil 封裝 DMG 映像檔..."
rm -f "$OUTPUT_DMG"
hdiutil create \
    -volname "$DMG_VOLNAME" \
    -srcfolder "$BUILD_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT_DMG"

# 清理暫存檔
rm -rf "$BUILD_DIR"

echo
echo "=========================================="
echo "       🎉 DMG 映像檔封裝完成！"
echo "=========================================="
echo "檔案位置: $OUTPUT_DMG"
echo "檔案大小: $(du -sh "$OUTPUT_DMG" | cut -f1)"

# 為 .dmg 檔案本身套用 Finder 自訂圖標
if [[ -f "$DMG_ICON" && -f "$OUTPUT_DMG" ]]; then
    swift -e '
    import AppKit
    let args = CommandLine.arguments
    guard args.count >= 3 else { exit(0) }
    let icon = NSImage(contentsOfFile: args[1])
    NSWorkspace.shared.setIcon(icon, forFile: args[2], options: [])
    ' "$DMG_ICON" "$OUTPUT_DMG" 2>/dev/null || true
fi

# 移除 dist/ 中裸露的 .app，只保留 .dmg，防止 macOS LaunchServices 重複掃描
# 注意：必須先呼叫 lsregister -u 註銷路徑，再執行 rm -rf，避免系統註冊表殘留幽靈記錄
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$DIST_APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BIN_APP" 2>/dev/null || true
rm -rf "$DIST_APP" 2>/dev/null || true

echo

if [[ "${CI:-}" != "true" ]]; then
    osascript -e 'display notification "行雲_繁-A DMG 封裝完成！" with title "DMG 打包程式" subtitle "封裝成功"' 2>/dev/null || true
    osascript -e "display dialog \"行雲_繁-A DMG 封裝完成！\n\n已成功產出安裝映像檔：\n$OUTPUT_DMG\" with title \"DMG 封裝程式\" buttons {\"開啟所在目錄\", \"完成\"} default button \"完成\" with icon note" 2>/dev/null || true
fi
