#!/bin/bash
# Builds "Catalina Player.app" on your Mac. Needs only Apple's free command line tools:
#   xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Catalina Player.app"
case "$(uname -m)" in
  arm64) TARGET="arm64-apple-macos11.0" ;;     # Apple silicon
  *)     TARGET="x86_64-apple-macos10.15" ;;   # Intel, including Catalina Macs
esac

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed yet. Run:  xcode-select --install"
  echo "Then run ./build.sh again."
  exit 1
fi

echo "› Building for $TARGET"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target "$TARGET" Sources/*.swift -o "$APP/Contents/MacOS/CatalinaPlayer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "› Making the icon"
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true   # local signature, so macOS trusts your own build

echo
echo "✓ Built: $APP"
echo "  Install it:  cp -R \"$APP\" /Applications/"
echo "  Or try it:   open \"$APP\""
