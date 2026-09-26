#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
MODULE_NAME="UnifyIME"
APP_NAME="行雲_繁-A.app"
APP_BUILD_DIR="$WORKSPACE_ROOT/bin/app"
APP_DIR="$APP_BUILD_DIR/$APP_NAME"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
INPUT_METHODS_DIR="$HOME/Library/Input Methods"
INSTALL_DIR="$INPUT_METHODS_DIR/$APP_NAME"
HOST_ARCH="${UNIFYIME_ARCH:-${FASTCHIME_ARCH:-$(uname -m)}}"
MACOS_TARGET="${UNIFYIME_MACOS_TARGET:-${FASTCHIME_MACOS_TARGET:-13.0}}"
DEPLOY_MODE="${UNIFYIME_DEPLOY:-${FASTCHIME_DEPLOY:-0}}"
SKIP_SIGN="${UNIFYIME_SKIP_SIGN:-${FASTCHIME_SKIP_SIGN:-0}}"
SIGN_IDENTITY="${SIGN_IDENTITY:-${UNIFYIME_SIGN_IDENTITY:-${FASTCHIME_SIGN_IDENTITY:--}}}"
SWIFT_CONFIGURATION="${UNIFYIME_SWIFT_CONFIGURATION:-${FASTCHIME_SWIFT_CONFIGURATION:-debug}}"

for arg in "$@"; do
  case "$arg" in
    --deploy)
      DEPLOY_MODE=1
      ;;
    --no-deploy)
      DEPLOY_MODE=0
      ;;
    --skip-sign)
      SKIP_SIGN=1
      ;;
    --sign)
      SKIP_SIGN=0
      ;;
    --arch=*)
      HOST_ARCH="${arg#*=}"
      ;;
    --macos-target=*)
      MACOS_TARGET="${arg#*=}"
      ;;
    --sign-identity=*)
      SIGN_IDENTITY="${arg#*=}"
      ;;
    --release)
      SWIFT_CONFIGURATION="release"
      ;;
    --debug)
      SWIFT_CONFIGURATION="debug"
      ;;
  esac
done

case "$HOST_ARCH" in
  arm64|x86_64)
    ;;
  *)
    echo "Unsupported arch: $HOST_ARCH" >&2
    exit 2
    ;;
esac

case "$SWIFT_CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "Unsupported swift configuration: $SWIFT_CONFIGURATION" >&2
    exit 2
    ;;
esac

TARGET_TRIPLE="$HOST_ARCH-apple-macos$MACOS_TARGET"
SWIFT_FLAGS=()
if [[ "$SWIFT_CONFIGURATION" == "debug" ]]; then
  SWIFT_FLAGS+=(-D DEBUG)
else
  SWIFT_FLAGS+=(-O)
fi

copy_tree_if_exists() {
  local src="$1"
  local dst="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$dst"
  ditto "$src" "$dst"
}

remove_appledouble_files() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  local appledouble
  while IFS= read -r -d '' appledouble; do
    rm -rf "$appledouble"
  done < <(find "$target" -name '._*' -print0)
}

source "$WORKSPACE_ROOT/scripts/dist_common.sh"
clear_project_dist "$WORKSPACE_ROOT"

rm -rf "$APP_BUILD_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR/Base.lproj" "$RES_DIR/en.lproj" "$RES_DIR/zh-Hant.lproj"

SWIFT_SOURCES=("${(@f)$(find "$ROOT/Sources" "$WORKSPACE_ROOT/src/phoneticIME/Sources" "$WORKSPACE_ROOT/src/englishIME/Sources" -name '*.swift' ! -name '._*' | sort)}")

swiftc \
  -parse-as-library \
  -module-name "$MODULE_NAME" \
  -target "$TARGET_TRIPLE" \
  -framework AppKit \
  -framework Carbon \
  -framework CoreML \
  -framework InputMethodKit \
  -framework WebKit \
  "${SWIFT_FLAGS[@]}" \
  "${SWIFT_SOURCES[@]}" \
  -o "$BIN_DIR/$MODULE_NAME"

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# 建置版號只產生一次；介面、安裝程式與發布封裝共同使用。
BUILD_CLOCK="$(TZ=Asia/Taipei date '+%Y%m%d%H%M')"
BUILD_VERSION="1.${BUILD_CLOCK[3,4]}.${BUILD_CLOCK[5,8]}"
BUILD_DISPLAY="$BUILD_VERSION build ${BUILD_CLOCK[9,12]}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUILD_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_CLOCK" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UnifyIMEBuildVersion string $BUILD_DISPLAY" "$APP_DIR/Contents/Info.plist"

if [[ ! -f "$ROOT/Resources/Bopomofo.tiff" || ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "==> Generating XingYun brand assets..."
  swift "$WORKSPACE_ROOT/scripts/generate_xingyun_assets.swift"
fi
cp "$ROOT/Resources/Bopomofo.tiff" "$RES_DIR/Bopomofo.tiff"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
fi

if [[ ! -f "$ROOT/Resources/lexicon_core.bin" ]]; then
  echo "==> Pre-compiling binary mmap lexicon..."
  swift "$WORKSPACE_ROOT/scripts/compile_lexicon_binary.swift"
fi
if [[ -f "$ROOT/Resources/lexicon_core.bin" ]]; then
  cp "$ROOT/Resources/lexicon_core.bin" "$RES_DIR/lexicon_core.bin"
fi
cp "$ROOT/Resources/common_map.tsv" "$RES_DIR/common_map.tsv"
cp "$ROOT/Resources/phrase_map.tsv" "$RES_DIR/phrase_map.tsv"
cp "$WORKSPACE_ROOT/lexicons/README.md" "$RES_DIR/Lexicon-Licenses.md"
cp "$ROOT/Resources/IMEConfig.json" "$RES_DIR/IMEConfig.json"
cp "$ROOT/Resources/Base.lproj/InfoPlist.strings" "$RES_DIR/Base.lproj/InfoPlist.strings"
cp "$ROOT/Resources/en.lproj/InfoPlist.strings" "$RES_DIR/en.lproj/InfoPlist.strings"
cp "$ROOT/Resources/zh-Hant.lproj/InfoPlist.strings" "$RES_DIR/zh-Hant.lproj/InfoPlist.strings"
if [[ -d "$ROOT/Resources/Preferences" ]]; then
  mkdir -p "$RES_DIR/Preferences"
  ditto "$ROOT/Resources/Preferences" "$RES_DIR/Preferences"
fi

if [[ -d "$WORKSPACE_ROOT/src/englishIME/Resources" ]]; then
  find "$WORKSPACE_ROOT/src/englishIME/Resources" -type f ! -name '._*' | while read -r resource; do
    cp "$resource" "$RES_DIR/$(basename "$resource")"
  done
fi

copy_tree_if_exists "$ROOT/Resources/Models" "$RES_DIR/Models"
remove_appledouble_files "$APP_DIR"

if [[ "$SKIP_SIGN" != "1" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Resources/fastChIME.entitlements" "$APP_DIR"
  codesign --verify --deep --strict "$APP_DIR"
else
  # 本地開發／封裝永遠強制簽署 ad-hoc 並帶入 entitlements，防止 Mach port 通訊被 macOS 阻斷
  codesign --force --sign - --timestamp=none --entitlements "$ROOT/Resources/fastChIME.entitlements" "$APP_DIR"
  codesign --verify --deep --strict "$APP_DIR"
  echo "Applied local ad-hoc bundle signature (with entitlements)"
fi

if [[ "$DEPLOY_MODE" == "1" && "${UNIFYIME_SKIP_DEPLOY:-${FASTCHIME_SKIP_DEPLOY:-0}}" != "1" ]]; then
  echo "Build mode: deploy"
else
  echo "Build mode: local-only"
fi

echo "Arch: $HOST_ARCH"
echo "Target: $TARGET_TRIPLE"
echo "Swift configuration: $SWIFT_CONFIGURATION"

if [[ "$DEPLOY_MODE" == "1" && "${UNIFYIME_SKIP_DEPLOY:-${FASTCHIME_SKIP_DEPLOY:-0}}" != "1" ]]; then
  echo "Deploying to:"
  echo "  $INSTALL_DIR"
  mkdir -p "$INPUT_METHODS_DIR"
  STAGING="$INPUT_METHODS_DIR/.xingyun-install-$$"
  BACKUP=""
  rollback_deploy() {
    local status=$?
    if (( status != 0 )); then
      if [[ -n "$BACKUP" && -d "$BACKUP/previous" ]]; then
        rm -rf "$INSTALL_DIR"
        mv "$BACKUP/previous" "$INSTALL_DIR"
      elif [[ -z "$BACKUP" && -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
      fi
    fi
    [[ ! -d "$STAGING" ]] || rm -rf "$STAGING"
    [[ -z "$BACKUP" || ! -d "$BACKUP" ]] || rmdir "$BACKUP" 2>/dev/null || true
  }
  trap rollback_deploy EXIT
  rm -rf "$STAGING"
  ditto "$APP_DIR" "$STAGING"
  codesign --verify --deep --strict "$STAGING"
  if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP="$(mktemp -d "$INPUT_METHODS_DIR/.xingyun-backup.XXXXXX")"
    mv "$INSTALL_DIR" "$BACKUP/previous"
  fi
  mv "$STAGING" "$INSTALL_DIR"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR"
  "$INSTALL_DIR/Contents/MacOS/$MODULE_NAME" install
  if [[ -n "$BACKUP" ]]; then
    rm -rf "$BACKUP"
    BACKUP=""
  fi
  trap - EXIT

  open "$INSTALL_DIR" 2>/dev/null || true
  echo "Deployed and launched:"
  echo "  $INSTALL_DIR"
fi

echo "$APP_DIR"
