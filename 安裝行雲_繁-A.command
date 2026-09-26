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

# 僅接受本產品 bundle，並驗證來源簽章；不清理其他同 ID 副本或全域資料庫。
SOURCE_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC_APP/Contents/Info.plist")
if [[ "$SOURCE_BUNDLE_ID" != "com.vader.inputmethod.XingYunIME" ]]; then
    echo "❌ 來源 Bundle ID 不符：$SOURCE_BUNDLE_ID"
    exit 1
fi
if ! codesign --verify --deep --strict "$SRC_APP"; then
    echo "❌ 來源簽章驗證失敗，未安裝。"
    exit 1
fi

# 檢查是否有已掛載的安裝磁碟，若有則提醒使用者
if hdiutil info 2>/dev/null | grep -q "行雲_繁-A 安裝磁碟"; then
    echo "💡 提示：偵測到「行雲_繁-A 安裝磁碟」掛載中。建議安裝完成後手動推出安裝映像檔，避免系統快取多餘副本。"
fi

mkdir -p "${TARGET:h}"
STAGING="${TARGET:h}/.xingyun-install-$$"
BACKUP=""
INSTALL_STARTED=0
rollback_install() {
    local install_exit_code=$?
    if (( install_exit_code != 0 )); then
        if [[ -n "$BACKUP" && -d "$BACKUP/previous" ]]; then
            rm -rf "$TARGET"
            mv "$BACKUP/previous" "$TARGET"
        elif [[ -z "$BACKUP" && "$INSTALL_STARTED" == 0 && -d "$TARGET" ]]; then
            rm -rf "$TARGET"
        elif [[ -z "$BACKUP" && "$INSTALL_STARTED" == 1 ]]; then
            echo "⚠️ 安裝流程失敗；已保留開始註冊的 App，避免刪除系統正在引用的輸入法。請檢查上方錯誤與目前輸入來源狀態。" >&2
        fi
    fi
    [[ ! -d "$STAGING" ]] || rm -rf "$STAGING"
    [[ -z "$BACKUP" || ! -d "$BACKUP" ]] || rmdir "$BACKUP" 2>/dev/null || true
}
trap rollback_install EXIT
rm -rf "$STAGING"

# 2. 部署應用程式
ditto "$SRC_APP" "$STAGING"
codesign --verify --deep --strict "$STAGING"
if [[ -d "$TARGET" ]]; then
    BACKUP="$(mktemp -d "${TARGET:h}/.xingyun-backup.XXXXXX")"
    mv "$TARGET" "$BACKUP/previous"
fi
mv "$STAGING" "$TARGET"

# 3. 向 macOS LaunchServices 核心註冊正式路徑並整理資料庫
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$TARGET"
fi

# 4. 由 App 內唯一的 install 流程重新查詢、啟用並持久化 TIS／HIToolbox 狀態。
INSTALL_BINARY="$TARGET/Contents/MacOS/UnifyIME"
if [[ ! -x "$INSTALL_BINARY" ]]; then
    echo "❌ 安裝檔缺少可執行檔：$INSTALL_BINARY"
    exit 1
fi
INSTALL_STARTED=1
INSTALL_ATTEMPT=1
INSTALL_MAX_ATTEMPTS=3
INSTALL_LOG="$(mktemp "${TMPDIR:-/tmp}/xingyun-install-attempt.XXXXXX")"
while true; do
    if "$INSTALL_BINARY" install >"$INSTALL_LOG" 2>&1; then
        cat "$INSTALL_LOG"
        break
    else
        INSTALL_EXIT_CODE=$?
        cat "$INSTALL_LOG"
        if (( INSTALL_ATTEMPT >= INSTALL_MAX_ATTEMPTS )) || ! /usr/bin/grep -Fq "TIS install readiness timeout" "$INSTALL_LOG"; then
            rm -f "$INSTALL_LOG"
            exit "$INSTALL_EXIT_CODE"
        fi
        echo "⚠️ TIS 尚未完成狀態同步；2 秒後重試安裝（$((INSTALL_ATTEMPT + 1))/$INSTALL_MAX_ATTEMPTS）。"
        (( INSTALL_ATTEMPT += 1 ))
        sleep 2
    fi
done
rm -f "$INSTALL_LOG"
if [[ -n "$BACKUP" ]]; then
    rm -rf "$BACKUP"
    BACKUP=""
fi
trap - EXIT

# 5. 開啟 App；不強制終止共用輸入法服務。
open "$TARGET" 2>/dev/null || true

echo "=========================================="
echo "        🎉 行雲_繁-A 安裝完成！"
echo "=========================================="
echo "已自動啟用並登錄於系統輸入法選單。"
echo

if [[ "${1:-}" != "--force" && "${1:-}" != "-f" ]]; then
    osascript -e 'display notification "行雲_繁-A 已成功啟用！" with title "行雲_繁-A" subtitle "安裝成功"' 2>/dev/null || true
    osascript -e 'display dialog "行雲_繁-A 安裝完成！\n\n已成功啟用並加入輸入法選單，您可直接切換使用。" with title "行雲_繁-A 安裝程式" buttons {"完成"} default button "完成" with icon note giving up after 5' 2>/dev/null || true
fi
