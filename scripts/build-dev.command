#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IME_ROOT="$ROOT/src/unifyIME"
APP="$ROOT/bin/app/全一輸入法.app"
INSTALL="$HOME/Library/Input Methods/全一輸入法.app"
TARGET_IME="全一輸入法"

echo "Building development app..."
zsh "$IME_ROOT/build.sh"

echo "Installing to:"
echo "  $INSTALL"
rm -rf "$INSTALL"
ditto "$APP" "$INSTALL"

echo "Refreshing registration..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL"
killall UnifyIME >/dev/null 2>&1 || true
killall "快捷中文測試" >/dev/null 2>&1 || true
killall TextInputMenuAgent >/dev/null 2>&1 || true
killall cfprefsd >/dev/null 2>&1 || true

echo
echo "Done."
echo "Installed development build:"
echo "  $INSTALL"
echo
echo "IME reloaded."
echo "This flow does not notarize. Use build-release-notarize.command"
echo "when you need system-list / release-level validation."

echo "Enabling and selecting the installed input source..."
"$INSTALL/Contents/MacOS/UnifyIME" install
echo "Input source installation/selection completed."

echo
echo "IME server will be demand-launched by macOS when the input source is selected."
echo "Candidate helper launched (hidden until composition/candidates exist)."
echo "Current input source should now be ${TARGET_IME}; verify the menu label before typing."
