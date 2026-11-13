#!/bin/zsh
# Builds "Velum.app". With --install, also replaces the copy in ~/Applications and relaunches it.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Velum"
BUNDLE="build/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"

swift build -c release
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp .build/release/Velum "$BUNDLE/Contents/MacOS/Velum"
cp .build/release/velumctl "$BUNDLE/Contents/MacOS/velumctl"   # T1: link it into your PATH (README)
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"; fi
# The optional Google sign-in's OAuth client, kept out of git. Without it the sign-in isn't offered (see README).
if [[ -f Resources/GoogleOAuthClient.plist ]]; then cp Resources/GoogleOAuthClient.plist "$BUNDLE/Contents/Resources/"; fi
# A stable local identity keeps macOS's Accessibility permission across rebuilds (see Scripts/sign.sh).
Scripts/sign.sh "$BUNDLE"
echo "Built $BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Velum 2>/dev/null && sleep 0.7 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$BUNDLE" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
