#!/bin/zsh
# Builds dist/Folga.app (release, arm64).
#   SIGN_IDENTITY="-"   forces ad-hoc signing
#   NOTARIZE=1          notarizes with Apple and staples the ticket (keychain profile "folga",
#                       created once with: xcrun notarytool store-credentials folga ...)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/Folga.app
VERSION=${VERSION:-1.0.0}

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/Folga

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Folga"
strip -x "$APP/Contents/MacOS/Folga"

if [[ ! -f scripts/.icon/AppIcon.icns ]]; then
  mkdir -p scripts/.icon/AppIcon.iconset
  swift scripts/make-icon.swift scripts/.icon/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s scripts/.icon/icon_1024.png --out scripts/.icon/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) scripts/.icon/icon_1024.png --out scripts/.icon/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns scripts/.icon/AppIcon.iconset -o scripts/.icon/AppIcon.icns
fi
cp scripts/.icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Folga</string>
  <key>CFBundleDisplayName</key><string>Folga</string>
  <key>CFBundleIdentifier</key><string>dev.victor.folga</string>
  <key>CFBundleExecutable</key><string>Folga</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>O Folga usa o Finder para esvaziar a Lixeira quando você pede.</string>
  <key>NSHumanReadableCopyright</key><string>Uso pessoal.</string>
</dict>
</plist>
PLIST

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2; exit}')}
IDENTITY=${IDENTITY:--}
ZIP="dist/Folga-${VERSION}-arm64.zip"
rm -f "$ZIP"

if [[ "${NOTARIZE:-0}" == "1" ]]; then
  [[ "$IDENTITY" == "-" ]] && { echo "Notarizar exige um certificado Developer ID."; exit 1; }
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Enviando para a Apple (leva alguns minutos)..."
  xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-folga}" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # Re-zip so the download carries the stapled ticket.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute -vv "$APP"
  echo "OK: $APP notarizado. Download: $ZIP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP" 2>/dev/null || codesign --force --sign - "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "OK: $APP ($(du -sh "$APP" | cut -f1)) assinado com: $IDENTITY"
fi
